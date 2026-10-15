#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ARCH="${1:-$(uname -m)}"
case "$BUILD_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$BUILD_ARCH" >&2; exit 64 ;; esac
APP_VERSION="$(tr -d '\r\n' < VERSION)"
if ! [[ "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'VERSION must contain MAJOR.MINOR.PATCH\n' >&2
    exit 64
fi
swift build -c release --triple "$BUILD_ARCH-apple-macosx14.0"
BIN_PATH="$(swift build -c release --triple "$BUILD_ARCH-apple-macosx14.0" --show-bin-path)"
APP="$PWD/build/ChiikawaPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/ChiikawaPet" "$APP/Contents/MacOS/ChiikawaPet"
cp mac/Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
cp -R "$BIN_PATH/ChiikawaPet_ChiikawaPet.bundle" "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp assets/NOTICE.md "$APP/Contents/Resources/ARTWORK-NOTICE.md"
codesign --force --sign - "$APP"
printf '\n앱 생성: %s\n' "$APP"
