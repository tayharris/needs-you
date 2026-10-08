#!/usr/bin/env bash
# Move test: Settings → Move to Applications, end to end, on a test copy. A copy in a
# "Downloads" folder, then one on a mounted disk image, moves itself to a temp
# "Applications" folder, quits, and the moved copy comes back up with the same settings,
# hub data and a working hub. Never touches the real app or its data:
#
#   - bundle id app.needsyou.mac.movetest, no needsyou:// scheme. NEEDS_YOU_MOVE_DEST and
#     NEEDS_YOU_MOVE_NOW are honoured only by a build whose bundle id isn't the real one
#     (AppMovePlan.destinationOverride), so this can't move or replace /Applications/NeedsYou.app
#   - the destination is a temp dir (never /Applications); the login item is never touched
#     (LoginItemPolicy only acts on a copy that recorded one)
#   - NEEDS_YOU_SUPPORT_DIR, NEEDS_YOU_DEFAULTS_SUITE, NEEDS_YOU_HUB_PORT (a free high port,
#     loopback only): as in upgrade-test.sh
#   - no quarantine flag is set (that would show a Gatekeeper prompt)
#
#   mac/scripts/move-test.sh
#   KEEP=1 mac/scripts/move-test.sh     # keep the temp dir for a look afterwards
#
# While it runs, a test copy's pill and menu bar icon show for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."

ID=app.needsyou.mac.movetest
SUITE="$ID.$$"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}"/needsyou-move.XXXXXX)" && pwd -P)"
DEST="$T/Applications"
APP="$DEST/NeedsYou.app"
DL="$T/Downloads"
SUPPORT="$T/support"
VOL="NeedsYouMoveTest$$"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
FAILS=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }

case "$DEST" in /Applications*|"") echo "refusing: bad test dir $DEST" >&2; exit 1 ;; esac

pids_of() { pgrep -f "^$1/Contents/MacOS/NeedsYou( |$)" || true; }
stop_app() {
  local pids
  pids="$(pids_of "$1")"
  [[ -n "$pids" ]] && kill -TERM $pids 2>/dev/null
  for _ in $(seq 1 50); do [[ -z "$(pids_of "$1")" ]] && return 0; sleep 0.1; done
  return 1
}

cleanup() {
  set +e
  for app in "$APP" "$DL/NeedsYou.app" "/Volumes/$VOL/NeedsYou.app"; do stop_app "$app"; done
  pkill -f "needs_you_hub.py.*$SUPPORT" 2>/dev/null
  [[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1
  for app in "$APP" "$DL/NeedsYou.app" "$T/dist/NeedsYou.app"; do
    [[ -d "$app" ]] && "$LSREGISTER" -u "$app" >/dev/null 2>&1
  done
  for domain in "$SUITE" "$ID"; do
    defaults delete "$domain" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

PORT=""
for _ in $(seq 1 50); do
  p=$((20000 + RANDOM % 20000))
  [[ $p == 8765 || $p == 8766 ]] && continue
  if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then PORT=$p; break; fi
done
[[ -n "$PORT" ]] || { echo "error: no free port found" >&2; exit 1; }
HUB="http://127.0.0.1:$PORT"

echo "==> temp dir $T, hub port $PORT, defaults suite $SUITE"
mkdir -p "$DL" "$SUPPORT"
export NEEDS_YOU_SUPPORT_DIR="$SUPPORT" NEEDS_YOU_DEFAULTS_SUITE="$SUITE"
export NEEDS_YOU_HUB_PORT="$PORT" NEEDS_YOU_HUB_LOOPBACK_ONLY=1 NEEDS_YOU_POLL_SECONDS=5
export NEEDS_YOU_BUNDLE_ID="$ID" NEEDS_YOU_NO_URL_SCHEME=1

echo "==> building the test copy"
NEEDS_YOU_DIST="$T/dist" scripts/bundle.sh > "$T/build.log" 2>&1 || { tail -20 "$T/build.log"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$T/dist/NeedsYou.app/Contents/Info.plist")" == "$ID" ]] \
  || { echo "error: test build has the wrong bundle id" >&2; exit 1; }
ditto "$T/dist/NeedsYou.app" "$DL/NeedsYou.app"

defaults write "$SUITE" userName move-tester
defaults write "$SUITE" someFutureKey -string keep-me

hub_up() { for _ in $(seq 1 100); do curl -sf "$HUB/v1/health" >/dev/null && return 0; sleep 0.2; done; return 1; }
wait_moved() {   # $1 = source app: gone, and the moved copy running
  for _ in $(seq 1 200); do
    [[ -z "$(pids_of "$1")" && -n "$(pids_of "$APP")" ]] && return 0
    sleep 0.1
  done
  return 1
}
launch_moving() {   # $1 = app to launch with the test move trigger
  open -g --env NEEDS_YOU_MOVE_DEST="$DEST" --env NEEDS_YOU_MOVE_NOW=1 \
    --env NEEDS_YOU_SUPPORT_DIR="$SUPPORT" --env NEEDS_YOU_DEFAULTS_SUITE="$SUITE" \
    --env NEEDS_YOU_HUB_PORT="$PORT" --env NEEDS_YOU_HUB_LOOPBACK_ONLY=1 --env NEEDS_YOU_POLL_SECONDS=5 "$1"
}
check_moved() {   # $1 = where it came from (a label)
  [[ -d "$APP" ]] && pass "$1: copied to the test Applications folder" || fail "$1: no copy at $APP"
  codesign --verify --deep --strict "$APP" 2>/dev/null && pass "$1: the copy's signature verifies" || fail "$1: the copy's signature doesn't verify"
  [[ -z "$(ls -A "$DEST" | grep -v '^NeedsYou.app$' || true)" ]] && pass "$1: no staging leftovers" || fail "$1: leftovers in $DEST: $(ls -A "$DEST")"
  [[ "$(defaults read "$SUITE" userName 2>/dev/null)" == move-tester ]] && pass "$1: prefs kept" || fail "$1: prefs lost"
  [[ "$(defaults read "$SUITE" someFutureKey 2>/dev/null)" == keep-me ]] && pass "$1: unknown pref kept" || fail "$1: unknown pref lost"
  [[ -n "$OWNER" && "$(cat "$SUPPORT/owner.token" 2>/dev/null)" == "$OWNER" ]] && pass "$1: owner.token unchanged" || fail "$1: owner.token changed"
  [[ "$(stat -f %i "$SUPPORT/hub.db" 2>/dev/null)" == "$DB_INODE" ]] && pass "$1: hub.db is the same file" || fail "$1: hub.db replaced"
  hub_up && pass "$1: the moved copy's hub is up" || fail "$1: no hub after the move"
  pgrep -f "$APP/Contents/Resources/hub/needs_you_hub\.py" >/dev/null \
    && pass "$1: the hub runs from the moved copy's bundle" || fail "$1: the hub isn't the moved copy's"
  [[ "$(pgrep -f "needs_you_hub.py.*$SUPPORT" | wc -l | tr -d ' ')" == 1 ]] && pass "$1: exactly one hub" || fail "$1: hub count wrong"
  curl -sf -H "Authorization: Bearer $OWNER" "$HUB/v1/invites" | grep -q "$INVITE_ID" \
    && pass "$1: hub data survived (the invite is still listed)" || fail "$1: hub data lost"
}

echo "==> 0. run the Downloads copy once (no move) and leave some hub data"
open -g --env NEEDS_YOU_SUPPORT_DIR="$SUPPORT" --env NEEDS_YOU_DEFAULTS_SUITE="$SUITE" \
  --env NEEDS_YOU_HUB_PORT="$PORT" --env NEEDS_YOU_HUB_LOOPBACK_ONLY=1 "$DL/NeedsYou.app"
for _ in $(seq 1 100); do [[ -s "$SUPPORT/owner.token" ]] && break; sleep 0.1; done
hub_up && pass "the Downloads copy's hub is up" || fail "the Downloads copy's hub didn't start"
OWNER="$(cat "$SUPPORT/owner.token" 2>/dev/null || true)"
INVITE_ID="$(curl -sf -X POST -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' \
  -d '{"name":"move-box","role":"sender","uses":1,"ttl_hours":1}' "$HUB/v1/invites" \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
[[ -n "$INVITE_ID" ]] || fail "couldn't make an invite on the Downloads copy's hub"
DB_INODE="$(stat -f %i "$SUPPORT/hub.db" 2>/dev/null || echo none)"
stop_app "$DL/NeedsYou.app"
for _ in $(seq 1 50); do pgrep -f "needs_you_hub.py.*$SUPPORT" >/dev/null || break; sleep 0.1; done

echo "==> 1. from Downloads"
launch_moving "$DL/NeedsYou.app"
if wait_moved "$DL/NeedsYou.app"; then pass "Downloads copy quit; the copy in Applications is running"; else fail "the move didn't relaunch"; fi
[[ -d "$DL/NeedsYou.app" ]] && pass "the Downloads copy is left in place" || fail "the Downloads copy is gone"
check_moved Downloads

echo "==> 2. an existing copy isn't replaced without confirmation"
stop_app "$APP"
INODE="$(stat -f %i "$APP/Contents/MacOS/NeedsYou")"
launch_moving "$DL/NeedsYou.app"
sleep 6
[[ "$(stat -f %i "$APP/Contents/MacOS/NeedsYou")" == "$INODE" ]] && pass "the existing copy is untouched" || fail "the existing copy was replaced"
[[ -n "$(pids_of "$DL/NeedsYou.app")" ]] && pass "the Downloads copy keeps running (Settings asks)" || fail "the Downloads copy quit"
stop_app "$DL/NeedsYou.app"
rm -rf "$APP"

echo "==> 3. from a disk image"
mkdir -p "$T/dmg"
ditto "$T/dist/NeedsYou.app" "$T/dmg/NeedsYou.app"
ln -s /Applications "$T/dmg/Applications"
hdiutil create -quiet -volname "$VOL" -srcfolder "$T/dmg" -format UDZO "$T/test.dmg"
hdiutil attach -quiet -nobrowse -readonly "$T/test.dmg"
[[ -d "/Volumes/$VOL/NeedsYou.app" ]] || fail "the disk image didn't mount at /Volumes/$VOL"
[[ -L "/Volumes/$VOL/Applications" ]] && pass "the disk image has the Applications link" || fail "no Applications link"
launch_moving "/Volumes/$VOL/NeedsYou.app"
if wait_moved "/Volumes/$VOL/NeedsYou.app"; then pass "disk image copy quit; the copy in Applications is running"; else fail "the move from the disk image didn't relaunch"; fi
check_moved "Disk image"
hdiutil detach -quiet "/Volumes/$VOL" && pass "the disk image ejects after the move" || fail "the disk image is still busy"

echo
if [[ $FAILS == 0 ]]; then echo "move test passed"; else echo "move test: $FAILS failure(s)"; fi
exit $(( FAILS > 0 ))
