#!/usr/bin/env bash
# What the app shows at launch (LaunchOpen, PanelGeometry.launchPlacement), on this Mac's
# real displays, from a throwaway test copy next to a running real app.
#
#   mac/scripts/launch-test.sh [placements.json] [out-dir]   # default out: dist/launch-test
#
# placements.json: a `panelPlacements` value to seed (the JSON PlacementBook stores, e.g.
# from `defaults export app.needsyou.mac - | plutil -extract panelPlacements raw -`, base64
# decoded). Without one, the pill starts at the default corner.
#
# Three runs, each ~20 s with the test copy's pill on screen, then quit (SIGTERM to the PID
# this script started; nothing else is touched):
#   1. person: a launch by the person with the seeded placement: the panel opens once, then
#      closes by itself (launch-1-open.png, launch-2-after.png, and log lines);
#   2. setting-off: Open the panel when Needs You starts off: pill only;
#   3. gone-display: the placement moved to a display that isn't connected: the pill falls
#      back to the default corner, and the log says why.
# Isolated like screenshots.sh: bundle id app.needsyou.mac.launchtest, no URL scheme, its
# own defaults suite (deleted afterwards), a temp support dir, demo mode (no hub), no
# global shortcut (NEEDS_YOU_LAUNCH_SNAPSHOT_DIR). PNGs are drawn with cacheDisplay: no
# Screen Recording permission is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

SEED="${1:-}"
OUT="${2:-dist/launch-test}"
ID=app.needsyou.mac.launchtest
SUITE="$ID.$$"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}"/needsyou-launch.XXXXXX)" && pwd -P)"
APP="$T/dist/NeedsYou.app"
PID=""

cleanup() {
  set +e
  [[ -n "$PID" ]] && kill -TERM "$PID" 2>/dev/null
  sleep 1
  for domain in "$SUITE" "$ID"; do
    defaults delete "$domain" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  rm -rf "$T"
}
trap cleanup EXIT

echo "==> building a test copy ($ID)"
NEEDS_YOU_BUNDLE_ID="$ID" NEEDS_YOU_NO_URL_SCHEME=1 NEEDS_YOU_DIST="$T/dist" scripts/bundle.sh > "$T/build.log" 2>&1 \
  || { tail -20 "$T/build.log"; exit 1; }

seed() {   # seed <placements json file or ""> <openPanelAtLaunch bool>
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  if [[ -n "$1" ]]; then
    /usr/bin/python3 -I - "$1" "$T/seed.plist" <<'EOF'
import plistlib, sys
data = open(sys.argv[1], "rb").read().strip()
plistlib.dump({"panelPlacements": data}, open(sys.argv[2], "wb"))
EOF
    defaults import "$SUITE" "$T/seed.plist"
  fi
  defaults write "$SUITE" openPanelAtLaunch -bool "$2"
  defaults write "$SUITE" pillSize large
}

mkdir -p "$OUT"
run() {   # run <name>
  mkdir -p "$T/$1" "$T/support"
  NEEDS_YOU_DEMO=1 NEEDS_YOU_DEMO_INJECT_SECONDS=0 NEEDS_YOU_LAUNCH_SNAPSHOT_DIR="$T/$1" \
  NEEDS_YOU_SUPPORT_DIR="$T/support" NEEDS_YOU_DEFAULTS_SUITE="$SUITE" NEEDS_YOU_HUB_LOOPBACK_ONLY=1 \
    "$APP/Contents/MacOS/NeedsYou" > "$T/$1.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 80); do
    [[ -f "$T/$1/launch-2-after.png" ]] && break
    sleep 0.5
  done
  sleep 1
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
  PID=""
  grep -E "NeedsYou: (launch|pill on|the saved pill|the panel opened)" "$T/$1.log" | sed 's/^.*NeedsYou\[[0-9:a-f]*\] /  /' | tee "$OUT/$1.log"
  for f in "$T/$1"/*.png; do [[ -f "$f" ]] && cp "$f" "$OUT/$1-$(basename "$f")"; done
  return 0
}

echo "==> 1. launched by the person, seeded placement"
seed "$SEED" true
run person
echo "==> 2. Open the panel when Needs You starts: off"
seed "$SEED" false
run setting-off
if [[ -n "$SEED" ]]; then
  echo "==> 3. the placement's display isn't connected"
  /usr/bin/python3 -I - "$SEED" "$T/gone.json" <<'EOF'
import json, sys
book = json.load(open(sys.argv[1]))
for entry in book.get("entries", {}).values():
    entry["placement"]["screenID"] = "99999,0,2560x1440"
json.dump(book, open(sys.argv[2], "w"))
EOF
  seed "$T/gone.json" true
  run gone-display
fi
echo "==> wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
