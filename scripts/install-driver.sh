#!/bin/bash
#
# install-driver.sh
#
# Installs the OpenAudio HAL driver bundle into the system HAL plugin
# directory and restarts coreaudiod so the virtual device appears.
#
# Requires root (sudo).

set -euo pipefail

BUNDLE_NAME="OpenAudioDriver.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_BUNDLE="${REPO_ROOT}/Driver/build/${BUNDLE_NAME}"

usage() {
    cat <<EOF
Usage: sudo $0

Installs ${BUNDLE_NAME} to ${HAL_DIR} and restarts coreaudiod.
Build the bundle first with:  make -C Driver
EOF
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: this script must be run as root." >&2
    echo >&2
    usage >&2
    exit 1
fi

if [[ ! -d "${SOURCE_BUNDLE}" ]]; then
    echo "error: driver bundle not found at ${SOURCE_BUNDLE}" >&2
    echo "       run 'make -C Driver' first." >&2
    exit 1
fi

echo "Installing ${BUNDLE_NAME} -> ${HAL_DIR}"
mkdir -p "${HAL_DIR}"
rm -rf "${HAL_DIR:?}/${BUNDLE_NAME}"
cp -R "${SOURCE_BUNDLE}" "${HAL_DIR}/${BUNDLE_NAME}"

echo "Fixing ownership to root:wheel"
chown -R root:wheel "${HAL_DIR}/${BUNDLE_NAME}"

echo "Restarting coreaudiod"
# On newer macOS, SIP blocks kickstart of coreaudiod; killall + launchd respawn
# is the supported fallback.
if ! launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "kickstart blocked by SIP; falling back to killall"
    killall coreaudiod
fi

echo "Done. Look for 'OpenAudio 16ch' in Audio MIDI Setup."
