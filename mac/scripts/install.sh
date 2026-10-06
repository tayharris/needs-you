#!/usr/bin/env bash
# Install or update Needs You without losing config.
#
#   mac/scripts/install.sh                build (scripts/bundle.sh), then install/update
#   mac/scripts/install.sh --app PATH     install an already built NeedsYou.app
#   mac/scripts/install.sh --rollback     swap back to the previous version
#   options:
#     --dest DIR          install into DIR instead of /Applications (testing)
#     --no-launch         don't relaunch afterwards
#     --quit-with term    quit with SIGTERM instead of asking the app to quit (tests; the
#                         app handles SIGTERM like Quit, so its hub still stops cleanly)
#
# What it does:
#   1. Copies the new app next to the old one with `ditto` (same volume), so the swap is
#      a rename.
#   2. Quits the running app gracefully by bundle id (it stops its local hub cleanly),
#      waits for the process to exit, and only then falls back to SIGTERM.
#   3. Moves the old app to NeedsYou.app.previous (not an .app, so Launch Services ignores
#      it) and the new one into place. If the new version doesn't stay running, the old
#      one is put back.
#   4. Relaunches in the background (`open -g`): no focus steal.
#
# The path, bundle id and name stay the same, so these carry over: the login item
# (SMAppService), UserDefaults (app.needsyou.mac, migrated forward by `prefsVersion`
# and never pruned), and ~/Library/Application Support/NeedsYou (hub.db, owner.token,
# tokens.json). No Keychain is involved.
#
# NEEDS_YOU_* variables in the environment are passed to the relaunched app (`open --env`),
# which scripts/upgrade-test.sh uses to keep everything in temp dirs.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=/Applications
APP_SRC=""
ROLLBACK=0
LAUNCH=1
QUIT_WITH=app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_SRC="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --quit-with) QUIT_WITH="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$QUIT_WITH" in app|term) ;; *) echo "--quit-with must be app or term" >&2; exit 2 ;; esac

NAME=NeedsYou.app
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"   # real path, as the running process reports it
TARGET="$DEST/$NAME"
PREVIOUS="$DEST/$NAME.previous"

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
running_pids() { pgrep -f "^$1/Contents/MacOS/NeedsYou( |$)" || true; }
wait_gone() {   # $1 = app path, $2 = tenths of a second
  for _ in $(seq 1 "$2"); do
    [[ -z "$(running_pids "$1")" ]] && return 0
    sleep 0.1
  done
  return 1
}

quit_app() {
  local app="$1" id pids
  [[ -d "$app" ]] || return 0
  pids="$(running_pids "$app")"
  [[ -n "$pids" ]] || return 0
  id="$(plist "$app" CFBundleIdentifier)"
  if [[ "$QUIT_WITH" == app ]]; then
    echo "==> quitting the running app ($id)"
    # Only sent while it's running, so this never launches it just to quit it.
    osascript -e "if application id \"$id\" is running then tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    wait_gone "$app" 150 && return 0
    echo "    still running after 15 s; sending SIGTERM"
  else
    echo "==> stopping the running app with SIGTERM"
  fi
  kill -TERM $pids 2>/dev/null || true
  wait_gone "$app" 100 && return 0
  echo "    still running after 10 s; sending SIGKILL (its hub exits on its own when the app is gone)"
  kill -KILL $pids 2>/dev/null || true
  wait_gone "$app" 50 && return 0
  echo "error: the app didn't quit (pids: $pids)" >&2
  return 1
}

# The app's bundled hub normally exits with the app (--parent-pid), but a hub started by an
# older build can outlive it and keep port 8765. Stop any hub still running from this bundle.
stop_bundle_hubs() {
  local app="$1" pids i
  pids="$(pgrep -f "^.*[Pp]ython.* $app/Contents/Resources/hub/needs_you_hub\.py" || true)"
  [[ -n "$pids" ]] || return 0
  echo "==> stopping the old app's hub (pids: $(echo $pids))"
  kill -TERM $pids 2>/dev/null || true
  for i in $(seq 1 50); do
    pgrep -f "$app/Contents/Resources/hub/needs_you_hub\.py" >/dev/null || return 0
    sleep 0.1
  done
  kill -KILL $pids 2>/dev/null || true
}

launch_app() {
  local app="$1"
  local env_args=()
  while IFS='=' read -r k v; do
    [[ "$k" == NEEDS_YOU_* ]] && env_args+=(--env "$k=$v")
  done < <(env)
  echo "==> launching in the background"
  open -g ${env_args[@]+"${env_args[@]}"} "$app"
  # "Launched OK" = up within 5 s and still running 3 s later.
  for _ in $(seq 1 50); do
    [[ -n "$(running_pids "$app")" ]] && break
    sleep 0.1
  done
  sleep 3
  [[ -n "$(running_pids "$app")" ]]
}

if [[ $ROLLBACK == 1 ]]; then
  [[ -d "$PREVIOUS" ]] || { echo "error: no previous version at $PREVIOUS" >&2; exit 1; }
  [[ -d "$TARGET" ]] || { echo "error: nothing installed at $TARGET" >&2; exit 1; }
  quit_app "$TARGET"; stop_bundle_hubs "$TARGET"
  echo "==> rolling back: $(plist "$TARGET" CFBundleShortVersionString) → $(plist "$PREVIOUS" CFBundleShortVersionString)"
  SWAP="$DEST/.$NAME.swap.$$"
  mv "$TARGET" "$SWAP"
  mv "$PREVIOUS" "$TARGET"
  mv "$SWAP" "$PREVIOUS"
  if [[ $LAUNCH == 1 ]]; then
    launch_app "$TARGET" || { echo "error: the rolled-back app didn't stay running" >&2; exit 1; }
  fi
  echo "==> done (run --rollback again to return to the newer version)"
  exit 0
fi

if [[ -z "$APP_SRC" ]]; then
  scripts/bundle.sh
  APP_SRC="${NEEDS_YOU_DIST:-dist}/$NAME"
fi
[[ -d "$APP_SRC" ]] || { echo "error: no app at $APP_SRC" >&2; exit 1; }
APP_SRC="$(cd "$APP_SRC" && pwd -P)"
[[ "$APP_SRC" != "$TARGET" ]] || { echo "error: --app is the installed copy itself" >&2; exit 1; }
codesign --verify --strict "$APP_SRC"
if [[ -d "$TARGET" && "$(plist "$TARGET" CFBundleIdentifier)" != "$(plist "$APP_SRC" CFBundleIdentifier)" ]]; then
  echo "error: $TARGET has bundle id $(plist "$TARGET" CFBundleIdentifier), the new app has $(plist "$APP_SRC" CFBundleIdentifier)" >&2
  exit 1
fi

# Stage first (same volume, so the swap below is a rename), then stop the old one.
STAGED="$DEST/.$NAME.new.$$"
rm -rf "$STAGED"
trap 'rm -rf "$STAGED"' EXIT
echo "==> staging $APP_SRC ($(plist "$APP_SRC" CFBundleShortVersionString))"
ditto "$APP_SRC" "$STAGED"
codesign --verify --strict "$STAGED"

quit_app "$TARGET"; stop_bundle_hubs "$TARGET"
if [[ -d "$TARGET" ]]; then
  rm -rf "$PREVIOUS"
  mv "$TARGET" "$PREVIOUS"
fi
mv "$STAGED" "$TARGET"
trap - EXIT
echo "==> installed $TARGET ($(plist "$TARGET" CFBundleShortVersionString))"

if [[ $LAUNCH == 1 ]] && ! launch_app "$TARGET"; then
  echo "error: the new version didn't stay running" >&2
  if [[ -d "$PREVIOUS" ]]; then
    echo "==> restoring the previous version"
    quit_app "$TARGET" || true; stop_bundle_hubs "$TARGET"
    FAILED="$DEST/.$NAME.failed.$$"
    mv "$TARGET" "$FAILED"
    mv "$PREVIOUS" "$TARGET"
    rm -rf "$FAILED"
    launch_app "$TARGET" || true
  fi
  exit 1
fi
if [[ -d "$PREVIOUS" ]]; then
  echo "==> done. Previous version kept at $PREVIOUS (scripts/install.sh --rollback)"
else
  echo "==> done"
fi
