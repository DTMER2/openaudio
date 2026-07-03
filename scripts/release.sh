#!/bin/bash
# release.sh
#
# Phase 4 distribution pipeline (docs/requirements.md §9, NF-SE2):
#
#   1. Build OpenAudio.app (xcodebuild, Release) signed with Developer ID
#      Application + hardened runtime + secure timestamp.
#   2. Build the HAL driver signed the same way.
#   3. Wrap both in a signed installer pkg:
#        - driver -> /Library/Audio/Plug-Ins/HAL + coreaudiod restart (postinstall)
#        - app    -> /Applications
#   4. Notarize with notarytool and staple the ticket.
#
# Prerequisites (one-time):
#   - "Developer ID Application" / "Developer ID Installer" certs in the keychain.
#   - Notarization credentials stored under a keychain profile:
#       xcrun notarytool store-credentials openaudio-notary \
#           --key /path/to/AuthKey_XXXXXXXXXX.p8 \
#           --key-id XXXXXXXXXX \
#           --issuer <issuer-uuid>
#     (App Store Connect > Users and Access > Integrations > App Store Connect API)
#
# Usage:
#   scripts/release.sh                  # full pipeline incl. notarization
#   scripts/release.sh --skip-notarize  # build + sign + pkg only
#
# Overridable via environment: TEAM_ID, APP_IDENTITY, PKG_IDENTITY,
# NOTARY_PROFILE, VERSION.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/build/release"
OUT="$REPO/build"

TEAM_ID="${TEAM_ID:-J7TC5N99UN}"
APP_IDENTITY="${APP_IDENTITY:-Developer ID Application: waraku kobayashi ($TEAM_ID)}"
PKG_IDENTITY="${PKG_IDENTITY:-Developer ID Installer: waraku kobayashi ($TEAM_ID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-openaudio-notary}"
# Keep VERSION in sync with MARKETING_VERSION in project.yml.
VERSION="${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$REPO/project.yml" | head -1)}"
VERSION="${VERSION:-1.0.0}"

SKIP_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

FINAL_PKG="$OUT/OpenAudio-$VERSION.pkg"

echo "==> OpenAudio $VERSION  (team $TEAM_ID)"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# ---------------------------------------------------------------- 1. App
echo "==> Regenerating Xcode project (xcodegen)..."
(cd "$REPO" && xcodegen generate --quiet)

echo "==> Building OpenAudio.app (Release, Developer ID)..."
XCLOG="$BUILD/xcodebuild.log"
if ! xcodebuild -project "$REPO/OpenAudio.xcodeproj" \
    -scheme OpenAudio -configuration Release \
    -destination "generic/platform=macOS" \
    SYMROOT="$BUILD/xcode" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$APP_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build >"$XCLOG" 2>&1; then
    tail -40 "$XCLOG" >&2
    echo "error: xcodebuild failed (full log: $XCLOG)" >&2
    exit 1
fi

APP="$BUILD/xcode/Release/OpenAudio.app"
[[ -d "$APP" ]] || { echo "error: app not found at $APP" >&2; exit 1; }

# ---------------------------------------------------------------- 2. Driver
echo "==> Building OpenAudioDriver.driver (Developer ID)..."
make -C "$REPO/Driver" clean >/dev/null
make -C "$REPO/Driver" CODESIGN_IDENTITY="$APP_IDENTITY"
DRIVER="$REPO/Driver/build/OpenAudioDriver.driver"

# ---------------------------------------------------------------- 3. Verify
echo "==> Verifying signatures..."
codesign --verify --strict --deep "$APP"
codesign --verify --strict "$DRIVER"
# NB: capture output before grep -q — under pipefail, grep -q closing the
# pipe early makes codesign exit via SIGPIPE and fails the whole pipeline.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
grep -q "audio-input" <<<"$ENTITLEMENTS" \
    || { echo "error: app is missing the audio-input entitlement" >&2; exit 1; }
# get-task-allow is a debug entitlement; the notary service rejects it.
if grep -q "get-task-allow" <<<"$ENTITLEMENTS"; then
    echo "error: app has the debug get-task-allow entitlement" >&2
    exit 1
fi
# The notary service also rejects binaries without the hardened runtime.
for bin in "$APP" "$DRIVER"; do
    SIGINFO="$(codesign -d -vv "$bin" 2>&1)"
    grep -qE 'flags=0x[0-9a-f]+\(.*runtime' <<<"$SIGINFO" \
        || { echo "error: hardened runtime not enabled on $bin" >&2; exit 1; }
done

# ---------------------------------------------------------------- 4. Pkgs
echo "==> Building component pkgs..."
DRIVER_ROOT="$BUILD/driver-root"
mkdir -p "$DRIVER_ROOT/Library/Audio/Plug-Ins/HAL"
cp -R "$DRIVER" "$DRIVER_ROOT/Library/Audio/Plug-Ins/HAL/"

pkgbuild --root "$DRIVER_ROOT" \
    --install-location / \
    --scripts "$REPO/scripts/pkg" \
    --identifier com.openaudio.pkg.driver \
    --version "$VERSION" \
    --ownership recommended \
    "$BUILD/driver.pkg" >/dev/null

# Stage the app and pin BundleIsRelocatable=false: with relocation on
# (the --component default), Installer follows Spotlight to any existing
# copy with the same bundle ID (e.g. a dev build) instead of /Applications.
APP_ROOT="$BUILD/app-root"
mkdir -p "$APP_ROOT"
cp -R "$APP" "$APP_ROOT/"
pkgbuild --analyze --root "$APP_ROOT" "$BUILD/app-components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD/app-components.plist"

pkgbuild --root "$APP_ROOT" \
    --component-plist "$BUILD/app-components.plist" \
    --install-location /Applications \
    --identifier com.openaudio.pkg.app \
    --version "$VERSION" \
    "$BUILD/app.pkg" >/dev/null

echo "==> Building signed distribution pkg..."
cat > "$BUILD/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>OpenAudio $VERSION</title>
    <options customize="never" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.4"/></allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="app"/>
        <line choice="driver"/>
    </choices-outline>
    <choice id="app" title="OpenAudio">
        <pkg-ref id="com.openaudio.pkg.app"/>
    </choice>
    <choice id="driver" title="OpenAudio Audio Driver">
        <pkg-ref id="com.openaudio.pkg.driver"/>
    </choice>
    <pkg-ref id="com.openaudio.pkg.app">app.pkg</pkg-ref>
    <pkg-ref id="com.openaudio.pkg.driver">driver.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild --distribution "$BUILD/distribution.xml" \
    --package-path "$BUILD" \
    --sign "$PKG_IDENTITY" \
    "$FINAL_PKG"

# ---------------------------------------------------------------- 5. Notarize
if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    echo ""
    echo "Built (NOT notarized): $FINAL_PKG"
    echo "Notarize later with:"
    echo "  xcrun notarytool submit \"$FINAL_PKG\" --keychain-profile $NOTARY_PROFILE --wait"
    echo "  xcrun stapler staple \"$FINAL_PKG\""
    exit 0
fi

echo "==> Submitting to Apple notary service (profile: $NOTARY_PROFILE)..."
if ! xcrun notarytool submit "$FINAL_PKG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "error: notarization failed. Inspect with:" >&2
    echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

echo "==> Stapling ticket..."
xcrun stapler staple "$FINAL_PKG"

echo "==> Gatekeeper assessment..."
spctl --assess -vv --type install "$FINAL_PKG"

echo ""
echo "Done: $FINAL_PKG"
