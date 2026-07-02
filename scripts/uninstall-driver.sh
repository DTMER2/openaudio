#!/bin/bash
#
# uninstall-driver.sh
#
# Removes the OpenAudio HAL driver bundle and restarts coreaudiod.
#
# Requires root (sudo).

set -euo pipefail

BUNDLE_NAME="OpenAudioDriver.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALLED_BUNDLE="${HAL_DIR}/${BUNDLE_NAME}"

usage() {
    cat <<EOF
Usage: sudo $0

Removes ${INSTALLED_BUNDLE} and restarts coreaudiod.
EOF
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "error: this script must be run as root." >&2
    echo >&2
    usage >&2
    exit 1
fi

if [[ -d "${INSTALLED_BUNDLE}" ]]; then
    echo "Removing ${INSTALLED_BUNDLE}"
    rm -rf "${INSTALLED_BUNDLE}"
else
    echo "Nothing to remove: ${INSTALLED_BUNDLE} not present."
fi

echo "Restarting coreaudiod"
# On newer macOS, SIP blocks kickstart of coreaudiod; killall + launchd respawn
# is the supported fallback.
if ! launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null; then
    echo "kickstart blocked by SIP; falling back to killall"
    killall coreaudiod
fi

echo "Done."
