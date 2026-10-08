#!/usr/bin/env bash
# needs-you-version: 0.2.1
# install-copilot-hooks.sh: add the needs-you hooks to GitHub Copilot CLI.
#
#   ./install-copilot-hooks.sh                    ~/.copilot/hooks/ ($COPILOT_HOME/hooks/ if set)
#   ./install-copilot-hooks.sh --copilot-home DIR   DIR/hooks/
#   ./install-copilot-hooks.sh --uninstall        remove them again
#
# Copilot CLI loads every *.json in <copilot home>/hooks/ at startup. This writes its own
# file there, needs-you.json (copilot-hooks.json), next to a copy of the shared
# needs-you-hook.sh (integrations/claude-code/). No other file is edited, and re-running
# is safe. The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a session
# started by Orca ($ORCA_TERMINAL_HANDLE). See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/copilot-hooks.json"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

DIR="${COPILOT_HOME:-$HOME/.copilot}"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --copilot-home DIR  Copilot's home directory (default: \$COPILOT_HOME, else ~/.copilot).
                      Copilot reads DIR/hooks only when it runs with COPILOT_HOME=DIR.
  --uninstall         Remove the needs-you hooks file and the copied hook script
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --copilot-home) [ $# -ge 2 ] || die "--copilot-home needs a directory" 2; DIR=$2; shift 2 ;;
    --copilot-home=*) DIR=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

HOOKS_DIR="$DIR/hooks"
CONF="$HOOKS_DIR/needs-you.json"
HOOK="$HOOKS_DIR/needs-you-hook.sh"

echo "hooks:    $CONF"
echo "hook:     $HOOK"

# Another tool's directory: never write or delete through a symlink (it could point anywhere).
for p in "$HOOKS_DIR" "$CONF" "$HOOK"; do
  if [ -L "$p" ]; then
    die "$p is a symlink; not writing through it. Nothing was changed: copy copilot-hooks.json and needs-you-hook.sh there by hand."
  fi
done

if [ "$ACTION" = uninstall ]; then
  for p in "$CONF" "$HOOK"; do
    [ -f "$p" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "dry run: would delete $p"
    else
      rm -f "$p"
      echo "deleted $p"
    fi
  done
  [ "$DRY_RUN" -eq 1 ] || rmdir "$HOOKS_DIR" 2>/dev/null || true
  exit 0
fi

[ -f "$SNIPPET" ] || die "missing copilot-hooks.json next to this script"
[ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$SNIPPET" 2>/dev/null ||
  die "copilot-hooks.json is not valid JSON"

put() {  # put SRC DEST MODE NAME
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    echo "$4: already up to date"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$4: dry run, would write $2"
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  local tmp
  tmp=$(mktemp "$(dirname "$2")/.needs-you.XXXXXX")  # a fresh name, never a planted symlink
  cat "$1" >"$tmp"
  chmod "$3" "$tmp"
  mv -f "$tmp" "$2"
  echo "$4: installed"
}
put "$HOOK_SRC" "$HOOK" 755 hook
put "$SNIPPET" "$CONF" 644 needs-you.json

ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
echo ""
echo "Next:"
# Hooks can be switched off as a whole in Copilot's settings.
for f in "$DIR/settings.json" "$DIR/config.json"; do
  if grep -Eqs '"disableAllHooks"[[:space:]]*:[[:space:]]*true' "$f"; then
    echo "  - $f has \"disableAllHooks\": true: remove it, or no hook runs."
  fi
done
if [ "$DIR" != "$HOME/.copilot" ] && [ "${COPILOT_HOME:-}" != "$DIR" ]; then
  echo "  - Copilot reads $HOOKS_DIR only when it runs with COPILOT_HOME=$DIR."
fi
if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
  echo "  - Alerts are on for every agent session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
else
  cat <<'EOF'
  - The hooks stay quiet until opted in: NEEDS_YOU_AGENT_ALERTS=1 in your shell
    profile, or as a line in ~/.config/needs-you/env for every session on this
    machine (the invite installer's --alerts writes that line). Sessions started by
    Orca are opted in already.
EOF
fi
if [ "${NEEDS_YOU_INSTALLER:-}" != 1 ]; then
  cat <<'EOF'
  - They call the needs-you CLI; check `needs-you --help` works here (an invite
    link's installer, or scripts/setup-sender.sh, installs it).
EOF
fi
echo "  - Restart running Copilot CLI sessions to pick up the change."
