#!/usr/bin/env bash
# needs-you-version: 0.5.0
# install-cline-hooks.sh: add the needs-you hooks to Cline (the VS Code extension and the CLI).
#
#   ./install-cline-hooks.sh                        ~/Documents/Cline/Hooks/
#   ./install-cline-hooks.sh --cline-hooks-dir DIR  DIR instead
#   ./install-cline-hooks.sh --uninstall            remove them again
#
# A Cline hook is an executable named after its event, with no extension, in Cline's hooks
# directory. This writes a small one for each event it uses (TaskComplete, TaskError,
# UserPromptSubmit, TaskCancel, TaskStart, TaskResume, SessionShutdown) that runs a copy of
# the shared needs-you-hook.sh kept in ~/.config/needs-you/cline/hooks/. A hook file of
# your own is never replaced. Re-running is safe. The hooks do nothing until you opt in:
# NEEDS_YOU_AGENT_ALERTS=1, or a session started by Orca. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

CLINE_HOOKS="$HOME/Documents/Cline/Hooks"
HOOK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/cline/hooks"
ACTION="install"
DRY_RUN=0

# <event>:<hook mode>. TaskComplete is the waiting signal: Cline runs no hook when it asks
# for an approval.
EVENTS="TaskComplete:notify TaskError:notify UserPromptSubmit:resolve TaskCancel:resolve
TaskStart:start TaskResume:start SessionShutdown:end"

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --cline-hooks-dir DIR  Cline's global hooks directory (default: ~/Documents/Cline/Hooks)
  --uninstall            Remove the needs-you hook files and the copied hook script
  --dry-run              Show what would change; write nothing
  -h, --help             Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --cline-hooks-dir) [ $# -ge 2 ] || die "--cline-hooks-dir needs a directory" 2; CLINE_HOOKS=$2; shift 2 ;;
    --cline-hooks-dir=*) CLINE_HOOKS=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

HOOK="$HOOK_DIR/needs-you-hook.sh"
echo "hooks:    $CLINE_HOOKS/<event>"
echo "hook:     $HOOK"

# Never write or delete through a symlink (it could point anywhere).
for p in "$CLINE_HOOKS" "$HOOK_DIR" "$HOOK"; do
  [ -L "$p" ] && die "$p is a symlink; not writing through it. Nothing was changed."
done
for ev in $EVENTS; do
  [ -L "$CLINE_HOOKS/${ev%%:*}" ] && die "$CLINE_HOOKS/${ev%%:*} is a symlink; not writing through it. Nothing was changed."
done
case "$HOOK" in *"'"*) die "the hook path $HOOK has a ' in it; can't write a hook file for it" ;; esac

# ours FILE: a hook file this installer wrote.
ours() { grep -qs '^# needs-you: ' "$1" && grep -qs 'needs-you-hook.sh' "$1"; }

if [ "$ACTION" = uninstall ]; then
  for ev in $EVENTS; do
    f="$CLINE_HOOKS/${ev%%:*}"
    [ -f "$f" ] && ours "$f" || continue
    if [ "$DRY_RUN" -eq 1 ]; then echo "dry run: would delete $f"; else rm -f "$f"; echo "deleted $f"; fi
  done
  if [ -f "$HOOK" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then echo "dry run: would delete $HOOK"; else rm -f "$HOOK"; echo "deleted $HOOK"; fi
  fi
  [ "$DRY_RUN" -eq 1 ] || rmdir "$HOOK_DIR" "$(dirname "$HOOK_DIR")" 2>/dev/null || true
  exit 0
fi

[ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"

# A TaskComplete of your own: without ours there's no card at all, so stop here.
if [ -e "$CLINE_HOOKS/TaskComplete" ] && ! ours "$CLINE_HOOKS/TaskComplete"; then
  die "$CLINE_HOOKS/TaskComplete is your own hook; not replacing it. Nothing was changed: make it also pass its input to '$HOOK' notify cline TaskComplete"
fi

put() {  # put CONTENT_FILE DEST MODE NAME
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

TMPF=$(mktemp)
trap 'rm -f "$TMPF"' EXIT
put "$HOOK_SRC" "$HOOK" 755 hook
skipped=""
for ev in $EVENTS; do
  name=${ev%%:*}
  mode=${ev#*:}
  f="$CLINE_HOOKS/$name"
  if [ -e "$f" ] && ! ours "$f"; then
    skipped="$skipped $name"
    continue
  fi
  cat >"$TMPF" <<EOF
#!/bin/sh
# needs-you: Cline $name hook, written by install-cline-hooks.sh (needs-you uninstall-hooks --cline removes it)
hook='$HOOK'
[ -x "\$hook" ] || exit 0
exec "\$hook" $mode cline $name
EOF
  put "$TMPF" "$f" 755 "$name"
done

ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
echo ""
echo "Next:"
if [ -n "$skipped" ]; then
  echo "  - Kept your own hook files:$skipped. Their needs-you step is skipped, so a card may"
  echo "    stay until it expires; add '$HOOK' <mode> cline <event> to them to fix that."
fi
cat <<'EOF'
  - Cline runs no hook when it waits for your approval: you get a card when a task
    finishes (or stops on an error), not when it asks to run something.
  - In VS Code, Cline's "Enable Hooks" setting must be on (it is by default).
EOF
if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
  echo "  - Alerts are on for every agent session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
else
  cat <<'EOF'
  - The hooks stay quiet until opted in: NEEDS_YOU_AGENT_ALERTS=1 as a line in
    ~/.config/needs-you/env (the invite installer's --alerts writes it). VS Code starts
    hooks from the editor, so a variable in your shell profile may not reach them.
EOF
fi
if [ "${NEEDS_YOU_INSTALLER:-}" != 1 ]; then
  cat <<'EOF'
  - They call the needs-you CLI; check `needs-you --help` works here (an invite
    link's installer, or scripts/setup-sender.sh, installs it).
EOF
fi
