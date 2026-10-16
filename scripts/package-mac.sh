#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ARCH="${1:-$(uname -m)}"
./scripts/build-app.sh "$BUILD_ARCH"
APP_VERSION="$(tr -d '\r\n' < VERSION)"
DESTINATION="$PWD/build/release/mac/$APP_VERSION"
mkdir -p "$DESTINATION"
DMG_FILE="$DESTINATION/ChiikawaPet-$APP_VERSION-mac-$BUILD_ARCH.dmg"
TOOLS_DIR="$PWD/build/dmg-tools"
if [[ ! -x "$TOOLS_DIR/bin/python" ]]; then
    python3 -m venv "$TOOLS_DIR"
fi
"$TOOLS_DIR/bin/python" -c \
    'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "DMG packaging requires Python 3.10 or newer.")'
"$TOOLS_DIR/bin/python" -m pip install --disable-pip-version-check \
    --only-binary=:all: -r scripts/requirements-mac.txt

# The background TIFF already includes its Retina representation.
"$TOOLS_DIR/bin/python" -m dmgbuild --no-hidpi \
    -s scripts/dmg-settings.py -D "repo_root=$PWD" \
    "Chiikawa Pet $APP_VERSION" \
    "$DMG_FILE"

VERIFY_MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true; rmdir "$VERIFY_MOUNT"' EXIT
hdiutil attach "$DMG_FILE" -readonly -nobrowse -mountpoint "$VERIFY_MOUNT"
# FinderInfo changes after signing can invalidate an otherwise launchable app.
codesign --verify --deep --strict "$VERIFY_MOUNT/ChiikawaPet.app"
test "$(readlink "$VERIFY_MOUNT/Applications")" = "/Applications"
test -s "$VERIFY_MOUNT/.DS_Store"
test -s "$VERIFY_MOUNT/.background.tiff"
hdiutil detach "$VERIFY_MOUNT"
rmdir "$VERIFY_MOUNT"
trap - EXIT
