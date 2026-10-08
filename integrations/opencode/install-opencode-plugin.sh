#!/usr/bin/env bash
# needs-you-version: 0.1.4
# install-opencode-plugin.sh: add the needs-you plugin to opencode.
#
#   ./install-opencode-plugin.sh                   ~/.config/opencode ($XDG_CONFIG_HOME/opencode)
#   ./install-opencode-plugin.sh --config-dir DIR   another opencode config directory
#   ./install-opencode-plugin.sh --uninstall       remove it again
#
# Copies needs-you.js to <dir>/plugins/ (opencode loads every .js there at startup) and
# the shared needs-you-hook.sh (integrations/claude-code/) to <dir>/hooks/. No config file
# is edited. The plugin does nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a
# session started by Orca. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_SRC="$HERE/needs-you-opencode.js"
[ -f "$PLUGIN_SRC" ] || PLUGIN_SRC="$HERE/needs-you.js"
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
ACTION="install"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;
    --config-dir) [ $# -ge 2 ] || die "--config-dir needs a directory" 2; DIR=$2; shift 2 ;;
    --config-dir=*) DIR=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" 2 ;;
  esac
done

PLUGIN="$DIR/plugins/needs-you.js"
HOOK="$DIR/hooks/needs-you-hook.sh"

put() {  # put SRC DEST MODE
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    echo "$(basename "$2"): already up to date"
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  local tmp
  tmp=$(mktemp "$(dirname "$2")/.needs-you.XXXXXX")  # a fresh name, never a planted symlink
  cat "$1" >"$tmp"
  chmod "$3" "$tmp"
  mv -f "$tmp" "$2"
  echo "$(basename "$2"): installed in $(dirname "$2")"
}

if [ "$ACTION" = uninstall ]; then
  rm -f "$PLUGIN" "$HOOK"
  rmdir "$DIR/plugins" "$DIR/hooks" 2>/dev/null || true
  echo "removed the needs-you plugin from $DIR"
  exit 0
fi

[ -f "$PLUGIN_SRC" ] || die "missing needs-you.js next to this script"
[ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
put "$PLUGIN_SRC" "$PLUGIN" 644
put "$HOOK_SRC" "$HOOK" 755

ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
echo ""
echo "Next:"
if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
  echo "  - Alerts are on for every agent session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
else
  cat <<'EOF'
  - The plugin stays quiet until opted in: NEEDS_YOU_AGENT_ALERTS=1 in your shell
    profile, or as a line in ~/.config/needs-you/env for every session on this machine
    (the invite installer's --alerts writes that line).
EOF
fi
echo "  - Restart opencode to load the plugin."
