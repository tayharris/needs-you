#!/usr/bin/env bash
# Build NeedsYou in release mode and assemble mac/dist/NeedsYou.app, ad-hoc signed.
#
#   mac/scripts/bundle.sh            build + bundle + sign
#   mac/scripts/install.sh           build, then install/update /Applications/NeedsYou.app
#   NEEDS_YOU_DEMO=1 mac/dist/NeedsYou.app/Contents/MacOS/NeedsYou &   demo mode
#     (`open` doesn't pass environment variables; run the binary directly)
#
# Signing is ad-hoc (`codesign -s -`). Developer ID signing is on the roadmap
# (docs/roadmap/distribution.md). The app keeps no secrets in the Keychain, so an ad-hoc
# signature changing on every build costs nothing there.
#
# Overrides (scripts/upgrade-test.sh uses them to build throwaway copies):
#   NEEDS_YOU_VERSION=x.y.z        CFBundleShortVersionString (default: the repo's VERSION file)
#   NEEDS_YOU_DIST=dir             output directory (default mac/dist)
#   NEEDS_YOU_BUNDLE_ID=id         another bundle id (its own defaults domain; can't be
#                                  mistaken for, or quit as, the real app)
#   NEEDS_YOU_NO_URL_SCHEME=1      don't register needsyou:// (a test copy mustn't take it)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=NeedsYou
DIST="${NEEDS_YOU_DIST:-dist}"
APP="$DIST/$APP_NAME.app"
VERSION="${NEEDS_YOU_VERSION:-$(tr -d '[:space:]' < ../VERSION)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${NEEDS_YOU_BUNDLE_ID:-app.needsyou.mac}"

echo "==> swift build -c release"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ "$BUNDLE_ID" != app.needsyou.mac ]]; then
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
fi
if [[ "${NEEDS_YOU_NO_URL_SCHEME:-0}" == 1 ]]; then
  plutil -remove CFBundleURLTypes "$APP/Contents/Info.plist"
fi
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

if [[ -d "$REPO/integrations/codex" ]]; then
  mkdir -p "$RES/integrations/codex"
  cp "$REPO/integrations/codex/install-codex-hooks.sh" "$REPO/integrations/codex/codex-hooks.json" \
    "$RES/integrations/codex/"
fi

if [[ -f "$REPO/integrations/orca/snippet.md" ]]; then
  mkdir -p "$RES/integrations/orca"
  cp "$REPO/integrations/orca/snippet.md" "$RES/integrations/orca/snippet.md"
fi

# The in-app updater runs this copy of install.sh (swap, keep .previous, relaunch, roll back
# if the new version doesn't stay running), so it must be inside the signed bundle.
mkdir -p "$RES/scripts"
cp scripts/install.sh "$RES/scripts/install.sh"
chmod 755 "$RES/scripts/install.sh"

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> done: $(cd "$DIST" && pwd)/$APP_NAME.app ($VERSION build $BUILD, $BUNDLE_ID)"
