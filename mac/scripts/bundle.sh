#!/usr/bin/env bash
# Build NeedsTay in release mode and assemble mac/dist/NeedsTay.app, ad-hoc signed.
#
#   mac/scripts/bundle.sh            build + bundle + sign
#   open mac/dist/NeedsTay.app       run it (uses Settings for the hub)
#   NEEDS_TAY_DEMO=1 mac/dist/NeedsTay.app/Contents/MacOS/NeedsTay &   demo mode
#     (`open` doesn't pass environment variables; run the binary directly)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=NeedsTay
DIST=dist
APP="$DIST/$APP_NAME.app"
VERSION="${NEEDS_TAY_VERSION:-0.2.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> swift build -c release"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> done: $(pwd)/$APP ($VERSION build $BUILD)"
