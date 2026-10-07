#!/usr/bin/env bash
# Upgrade test: install v1, configure it, update to v2 with scripts/install.sh, check that
# nothing was lost, then roll back. Never touches the real app or its data:
#
#   - bundle id app.needsyou.mac.upgradetest, no needsyou:// scheme (so it can't be
#     confused with, or quit as, the real app)
#   - installs into a temp dir with --dest (never /Applications)
#   - NEEDS_YOU_SUPPORT_DIR: hub.db, owner.token and tokens.json in the temp dir
#   - NEEDS_YOU_DEFAULTS_SUITE: a throwaway defaults suite, deleted afterwards
#   - NEEDS_YOU_HUB_PORT: the test hub on a free high port (never 8765/8766), loopback only
#     (NEEDS_YOU_HUB_LOOPBACK_ONLY=1: no tailnet address, no Local Network prompt)
#   - no Keychain, no signing identities: builds are ad-hoc signed
#   - quits with SIGTERM (--quit-with term), so no AppleScript runs. UPGRADE_TEST_OSASCRIPT=1
#     exercises install.sh's default AppleScript quit instead (still only the test bundle id).
#
#   mac/scripts/upgrade-test.sh
#   KEEP=1 mac/scripts/upgrade-test.sh     # keep the temp dir for a look afterwards
#
# While it runs, a test copy's pill and menu bar icon show for a few seconds.
set -euo pipefail
cd "$(dirname "$0")/.."

ID=app.needsyou.mac.upgradetest
SUITE="$ID.$$"
# Resolved (/var → /private/var) so process paths match what pgrep sees.
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}"/needsyou-upgrade.XXXXXX)" && pwd -P)"
DEST="$T/Applications"
APP="$DEST/NeedsYou.app"
SUPPORT="$T/support"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
FAILS=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
note() { echo "  note  $*"; }

case "$DEST" in /Applications*|"") echo "refusing: bad test dir $DEST" >&2; exit 1 ;; esac

cleanup() {
  set +e
  for app in "$APP" "$APP.previous"; do
    pids="$(pgrep -f "^$app/Contents/MacOS/NeedsYou( |$)")"
    [[ -n "$pids" ]] && kill -TERM $pids 2>/dev/null
  done
  sleep 1
  pkill -f "needs_you_hub.py.*$SUPPORT" 2>/dev/null
  for app in "$APP" "$APP.previous" "$T/v1/NeedsYou.app" "$T/v2/NeedsYou.app"; do
    [[ -d "$app" ]] && "$LSREGISTER" -u "$app" >/dev/null 2>&1
  done
  for domain in "$SUITE" "$ID"; do
    defaults delete "$domain" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

# A free high port for the test hub.
PORT=""
for _ in $(seq 1 50); do
  p=$((20000 + RANDOM % 20000))
  [[ $p == 8765 || $p == 8766 ]] && continue
  if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then PORT=$p; break; fi
done
[[ -n "$PORT" ]] || { echo "error: no free port found" >&2; exit 1; }
HUB="http://127.0.0.1:$PORT"

QUIT=(--quit-with term)
[[ "${UPGRADE_TEST_OSASCRIPT:-0}" == 1 ]] && QUIT=()

echo "==> temp dir $T, hub port $PORT, defaults suite $SUITE"
mkdir -p "$DEST" "$SUPPORT"
export NEEDS_YOU_SUPPORT_DIR="$SUPPORT" NEEDS_YOU_DEFAULTS_SUITE="$SUITE"
export NEEDS_YOU_HUB_PORT="$PORT" NEEDS_YOU_HUB_LOOPBACK_ONLY=1 NEEDS_YOU_POLL_SECONDS=5
export NEEDS_YOU_BUNDLE_ID="$ID" NEEDS_YOU_NO_URL_SCHEME=1

echo "==> building v1 (0.9.0) and v2 (0.9.1)"
NEEDS_YOU_VERSION=0.9.0 NEEDS_YOU_DIST="$T/v1" scripts/bundle.sh > "$T/build1.log" 2>&1 || { tail -20 "$T/build1.log"; exit 1; }
NEEDS_YOU_VERSION=0.9.1 NEEDS_YOU_DIST="$T/v2" scripts/bundle.sh > "$T/build2.log" 2>&1 || { tail -20 "$T/build2.log"; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$T/v1/NeedsYou.app/Contents/Info.plist")" == "$ID" ]] \
  || { echo "error: test build has the wrong bundle id" >&2; exit 1; }

echo "==> seeding prefs as an older build would have left them"
# A remote hub (connection refused at once, on loopback), an unknown key from "the future",
# no prefsVersion (pre-versioning prefs), and its token in tokens.json.
defaults write "$SUITE" userName upgrade-tester
defaults write "$SUITE" hubURLs -array "http://127.0.0.1:9"
defaults write "$SUITE" someFutureKey -string keep-me
cat > "$SUPPORT/tokens.json" <<'EOF'
{"version": 1, "hubs": {"http://127.0.0.1:9": {"token": "remote-token-123", "role": "reader"}}}
EOF
chmod 600 "$SUPPORT/tokens.json"; chmod 700 "$SUPPORT"
TOKENS_BEFORE="$(cat "$SUPPORT/tokens.json")"

echo "==> install + launch v1"
scripts/install.sh --app "$T/v1/NeedsYou.app" --dest "$DEST" "${QUIT[@]+"${QUIT[@]}"}"

for _ in $(seq 1 100); do [[ -s "$SUPPORT/owner.token" ]] && break; sleep 0.1; done
HUB_UP=0
for _ in $(seq 1 100); do curl -sf "$HUB/v1/health" >/dev/null && { HUB_UP=1; break; }; sleep 0.2; done
[[ $HUB_UP == 1 ]] && pass "v1's hub is up on $HUB" || fail "v1's hub didn't start (see: log show --last 2m --predicate 'subsystem == \"app.needsyou.mac\"')"
OWNER_BEFORE="$(cat "$SUPPORT/owner.token" 2>/dev/null || true)"
INVITE_ID=""
if [[ $HUB_UP == 1 ]]; then
  INVITE_ID="$(curl -sf -X POST -H "Authorization: Bearer $OWNER_BEFORE" -H 'Content-Type: application/json' \
    -d '{"name":"upgrade-box","role":"sender","uses":1,"ttl_hours":1}' "$HUB/v1/invites" \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
fi
DB_INODE="$(stat -f %i "$SUPPORT/hub.db" 2>/dev/null || echo none)"
V1_PIDS="$(pgrep -f "^$APP/Contents/MacOS/NeedsYou( |$)" || true)"

# The update runs the copy of install.sh inside the installed v1, as the in-app updater
# does (from a copy outside the bundle, since the bundle is moved during the swap).
BUNDLED="$APP/Contents/Resources/scripts/install.sh"
[[ -x "$BUNDLED" ]] && pass "install.sh is bundled at Contents/Resources/scripts/" || fail "no bundled install.sh"
cp "$BUNDLED" "$T/install-from-app.sh"

echo "==> update to v2 with the bundled install.sh"
"$T/install-from-app.sh" --app "$T/v2/NeedsYou.app" --dest "$DEST" --record-rollback "$T/updates" "${QUIT[@]+"${QUIT[@]}"}"

echo "==> checks"
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$V" == 0.9.1 ]] && pass "installed version is 0.9.1" || fail "installed version is $V"
[[ -d "$APP.previous" ]] && pass "previous version kept at NeedsYou.app.previous" || fail "no .previous"
V2_PIDS="$(pgrep -f "^$APP/Contents/MacOS/NeedsYou( |$)" || true)"
[[ -n "$V2_PIDS" ]] && pass "v2 is running" || fail "v2 isn't running"
for pid in $V1_PIDS; do
  kill -0 "$pid" 2>/dev/null && fail "v1 (pid $pid) is still running" || pass "v1 (pid $pid) quit"
done
HUBS="$(pgrep -f "needs_you_hub.py.*$SUPPORT" | wc -l | tr -d ' ')"
[[ "$HUBS" == 1 ]] && pass "exactly one hub process (v1's stopped cleanly)" || fail "$HUBS hub processes"

[[ "$(defaults read "$SUITE" userName 2>/dev/null)" == upgrade-tester ]] && pass "prefs: userName kept" || fail "prefs: userName lost"
defaults read "$SUITE" hubURLs 2>/dev/null | grep -q "127.0.0.1:9" && pass "prefs: hub list kept" || fail "prefs: hub list lost"
[[ "$(defaults read "$SUITE" someFutureKey 2>/dev/null)" == keep-me ]] && pass "prefs: unknown key kept" || fail "prefs: unknown key deleted"
PV="$(defaults read "$SUITE" prefsVersion 2>/dev/null || echo 0)"
[[ "$PV" -ge 3 ]] && pass "prefsVersion = $PV" || fail "prefsVersion is $PV"

[[ "$(stat -f %Lp "$SUPPORT")" == 700 ]] && pass "support dir is mode 700" || fail "support dir mode $(stat -f %Lp "$SUPPORT")"
[[ "$(cat "$SUPPORT/tokens.json" 2>/dev/null)" == "$TOKENS_BEFORE" ]] && pass "tokens.json unchanged" || fail "tokens.json changed or missing"
[[ "$(stat -f %Lp "$SUPPORT/tokens.json")" == 600 ]] && pass "tokens.json is mode 600" || fail "tokens.json mode $(stat -f %Lp "$SUPPORT/tokens.json")"
[[ -n "$OWNER_BEFORE" && "$(cat "$SUPPORT/owner.token" 2>/dev/null)" == "$OWNER_BEFORE" ]] && pass "owner.token unchanged" || fail "owner.token changed or missing"
[[ "$(stat -f %Lp "$SUPPORT/owner.token" 2>/dev/null)" == 600 ]] && pass "owner.token is mode 600" || fail "owner.token mode"

if [[ $HUB_UP == 1 ]]; then
  [[ "$(stat -f %i "$SUPPORT/hub.db" 2>/dev/null)" == "$DB_INODE" ]] && pass "hub.db is the same file (not recreated)" || fail "hub.db was replaced"
  UP2=0
  for _ in $(seq 1 100); do curl -sf "$HUB/v1/health" >/dev/null && { UP2=1; break; }; sleep 0.2; done
  [[ $UP2 == 1 ]] && pass "v2's hub is up" || fail "v2's hub didn't come up"
  if [[ -n "$INVITE_ID" ]]; then
    curl -sf -H "Authorization: Bearer $OWNER_BEFORE" "$HUB/v1/invites" | grep -q "$INVITE_ID" \
      && pass "hub data survived (invite made on v1 is listed by v2's hub)" || fail "hub data lost"
  else
    note "couldn't create an invite on v1; skipped the hub data check"
  fi
fi

echo "==> rollback"
scripts/install.sh --rollback --dest "$DEST" --record-rollback "$T/updates" "${QUIT[@]+"${QUIT[@]}"}"
[[ "$(cat "$T/updates/rolled-back-version" 2>/dev/null)" == 0.9.1 ]] && pass "rollback recorded 0.9.1 for the updater to skip" || fail "rolled-back-version not written"
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$V" == 0.9.0 ]] && pass "rolled back to 0.9.0" || fail "after rollback the version is $V"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP.previous/Contents/Info.plist")" == 0.9.1 ]] \
  && pass "0.9.1 kept as .previous" || fail "0.9.1 not kept"
[[ -n "$(pgrep -f "^$APP/Contents/MacOS/NeedsYou( |$)" || true)" ]] && pass "0.9.0 is running again" || fail "0.9.0 isn't running"
[[ "$(defaults read "$SUITE" userName 2>/dev/null)" == upgrade-tester ]] && pass "prefs survive a rollback" || fail "prefs lost on rollback"
[[ "$(defaults read "$SUITE" prefsVersion 2>/dev/null)" == "$PV" ]] && pass "prefsVersion not lowered" || fail "prefsVersion changed on rollback"
[[ "$(cat "$SUPPORT/owner.token" 2>/dev/null)" == "$OWNER_BEFORE" ]] && pass "owner.token survives a rollback" || fail "owner.token changed on rollback"

echo
if [[ $FAILS == 0 ]]; then echo "upgrade test passed"; else echo "upgrade test: $FAILS failure(s)"; fi
exit $(( FAILS > 0 ))
