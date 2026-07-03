#!/bin/bash
# build-app.sh
# Assemble a runnable OpenAudio.app bundle from the OpenAudioApp executable
# (docs/plan.md Phase 3). Release build + Info.plist (LSUIElement, TCC usage
# strings) + ad-hoc code signature. Formal Developer ID signing / notarization
# is Phase 4. An .icns icon is optional and omitted gracefully for v1.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/Tools"
BUILD="$REPO/build"
APP="$BUILD/OpenAudio.app"
PRODUCT="OpenAudioApp"

echo "==> Building $PRODUCT (release)..."
swift build -c release --package-path "$PKG" --product "$PRODUCT"

BIN="$(swift build -c release --package-path "$PKG" --product "$PRODUCT" --show-bin-path)/$PRODUCT"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"

# App icon: compile the Icon Composer source (Tools/App/icon.icon) with actool.
# Produces icon.icns (Dock/Finder) + Assets.car (macOS 26 tinting). Skipped
# gracefully if actool or the source is unavailable.
ICON_SRC="$REPO/Tools/App/icon.icon"
HAS_ICON=0
if command -v actool >/dev/null 2>&1 && [[ -d "$ICON_SRC" ]]; then
    echo "==> Compiling app icon..."
    actool "$ICON_SRC" \
        --compile "$APP/Contents/Resources" \
        --app-icon icon \
        --output-partial-info-plist "$BUILD/icon-partial.plist" \
        --platform macosx --minimum-deployment-target 14.4 \
        --target-device mac \
        --output-format human-readable-text >/dev/null 2>&1 \
        && HAS_ICON=1 || echo "    (icon compilation failed; continuing without one)"
fi
ICON_KEYS=""
if [[ "$HAS_ICON" == "1" ]]; then
    ICON_KEYS='    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundleIconName</key>
    <string>icon</string>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OpenAudio</string>
    <key>CFBundleDisplayName</key>
    <string>OpenAudio</string>
    <key>CFBundleIdentifier</key>
    <string>jp.coremedica.openaudio</string>
    <key>CFBundleExecutable</key>
    <string>OpenAudioApp</string>
$ICON_KEYS
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>OpenAudio captures audio from the apps you choose so it can route, monitor, and record them.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenAudio uses your microphone or audio interface as an input source when you select one.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing..."
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - "$APP"

echo "==> Verifying signature..."
codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

echo ""
echo "Built: $APP"
echo "Launch with:  open \"$APP\""
