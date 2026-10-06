#!/usr/bin/env bash
# Build NeedsYou in release mode and assemble mac/dist/NeedsYou.app, ad-hoc signed.
#
#   mac/scripts/bundle.sh            build + bundle + sign
#   open mac/dist/NeedsYou.app       run it (uses Settings for the hub)
#   NEEDS_YOU_DEMO=1 mac/dist/NeedsYou.app/Contents/MacOS/NeedsYou &   demo mode
#     (`open` doesn't pass environment variables; run the binary directly)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=NeedsYou
DIST=dist
APP="$DIST/$APP_NAME.app"
VERSION="${NEEDS_YOU_VERSION:-0.2.0}"
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

# The hub that runs inside the app, plus what it hands to joining machines (/dl).
# Contents/Resources mirrors the repo layout (hub/, cli/, integrations/claude-code/) so
# the hub finds its siblings the same way in the repo and in the bundle.
echo "==> bundling the local hub"
REPO=..
RES="$APP/Contents/Resources"
for f in hub/needs_you_hub.py hub/needs_you_admin.py hub/join-install.sh cli/needs-you; do
  if [[ ! -f "$REPO/$f" ]]; then
    echo "error: $REPO/$f is missing (the local hub needs it)" >&2
    exit 1
  fi
  mkdir -p "$RES/$(dirname "$f")"
  cp "$REPO/$f" "$RES/$f"
done
chmod 755 "$RES/hub/needs_you_hub.py" "$RES/hub/needs_you_admin.py" "$RES/hub/join-install.sh" "$RES/cli/needs-you"
if [[ -d "$REPO/integrations/claude-code" ]]; then
  mkdir -p "$RES/integrations"
  # No caches or editor droppings in the bundle.
  rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude '.DS_Store' \
    "$REPO/integrations/claude-code/" "$RES/integrations/claude-code/"
else
  echo "warning: $REPO/integrations/claude-code not found; joiners won't get the Claude Code files" >&2
fi

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> done: $(pwd)/$APP ($VERSION build $BUILD)"
