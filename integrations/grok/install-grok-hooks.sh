#!/usr/bin/env bash
# needs-you-version: 0.1.3
# install-grok-hooks.sh: add the needs-you hooks to Grok Build (xAI's `grok`).
#
#   ./install-grok-hooks.sh                  ~/.grok/hooks/ ($GROK_HOME/hooks/ if set)
#   ./install-grok-hooks.sh --grok-home DIR  DIR/hooks/
#   ./install-grok-hooks.sh --uninstall      remove them again
#
# Grok loads every *.json in <grok home>/hooks/ and always trusts it. This writes its own
# file there, needs-you.json (grok-hooks.json), next to a copy of the shared
# needs-you-hook.sh (integrations/claude-code/). No other file is edited, and re-running
# is safe. Grok also runs the Claude Code hooks; with this file in place they step aside
# in Grok sessions, so a wait gets one card. The hooks do nothing until you opt in:
# NEEDS_YOU_AGENT_ALERTS=1, or a session started by Orca. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/grok-hooks.json"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

DIR="${GROK_HOME:-$HOME/.grok}"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --grok-home DIR     Grok's home directory (default: \$GROK_HOME, else ~/.grok).
                      Grok reads DIR/hooks only when it runs with GROK_HOME=DIR.
  --uninstall         Remove the needs-you hooks file and the copied hook script
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --grok-home) [ $# -ge 2 ] || die "--grok-home needs a directory" 2; DIR=$2; shift 2 ;;
    --grok-home=*) DIR=${1#*=}; shift ;;
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
    die "$p is a symlink; not writing through it. Nothing was changed: copy grok-hooks.json and needs-you-hook.sh there by hand."
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

[ -f "$SNIPPET" ] || die "missing grok-hooks.json next to this script"
[ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$SNIPPET" 2>/dev/null ||
  die "grok-hooks.json is not valid JSON"

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
echo "  - Check Grok loads it: grok inspect (Hooks), or /hooks in a session."
# An organization's policy can allow only its own hooks.
for f in "$DIR/requirements.toml" /etc/grok/requirements.toml "$DIR/managed_config.toml" /etc/grok/managed_config.toml; do
  if grep -Eqs '^[[:space:]]*(allow_managed_hooks_only|allowManagedHooksOnly)[[:space:]]*=[[:space:]]*true' "$f"; then
    echo "  - $f allows only managed hooks: these won't run on this machine."
  fi
done
if [ "$DIR" != "$HOME/.grok" ] && [ "${GROK_HOME:-}" != "$DIR" ]; then
  echo "  - Grok reads $HOOKS_DIR only when it runs with GROK_HOME=$DIR."
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
echo "  - Restart running Grok sessions to pick up the change."
