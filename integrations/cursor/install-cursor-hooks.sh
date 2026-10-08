#!/usr/bin/env bash
# needs-you-version: 0.1.5
# install-cursor-hooks.sh: add the needs-you hooks to Cursor's user hooks.json.
#
#   ./install-cursor-hooks.sh                  ~/.cursor/hooks.json
#   ./install-cursor-hooks.sh --cursor-dir DIR   DIR/hooks.json (tests; Cursor reads ~/.cursor)
#   ./install-cursor-hooks.sh --uninstall      remove them again
#
# Copies the shared needs-you-hook.sh (integrations/claude-code/) to <dir>/hooks/, backs up
# hooks.json before changing it, and merges with python3 (no jq). Re-running is safe:
# existing needs-you entries are replaced, every other hook is kept, and an unchanged file
# is not rewritten. Only stop, beforeSubmitPrompt and sessionEnd: never a permission hook
# (Cursor blocks the action when one of those prints nothing). Cursor reloads hooks.json
# on its own. The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/cursor-hooks.json"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

CURSOR_DIR="$HOME/.cursor"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --cursor-dir DIR    Cursor's user directory (default: ~/.cursor)
  --uninstall         Remove the needs-you hooks (and the copied hook script)
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --cursor-dir) [ $# -ge 2 ] || die "--cursor-dir needs a directory" 2; CURSOR_DIR=$2; shift 2 ;;
    --cursor-dir=*) CURSOR_DIR=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
if [ "$ACTION" = "install" ]; then
  [ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
  [ -f "$SNIPPET" ] || die "missing $SNIPPET"
fi

HOOKS_FILE="$CURSOR_DIR/hooks.json"
HOOKS_DIR="$CURSOR_DIR/hooks"

echo "hooks:    $HOOKS_FILE"
echo "hook:     $HOOKS_DIR/needs-you-hook.sh"

# Another tool's directory: never write or delete through a symlink (it could point anywhere).
for p in "$HOOKS_DIR" "$HOOKS_DIR/needs-you-hook.sh"; do
  if [ -L "$p" ]; then
    die "$p is a symlink; not writing through it. Nothing was changed: copy needs-you-hook.sh there by hand."
  fi
done

# ---- merge (python3 does the JSON; it prints a status line)
python3 - "$HOOKS_FILE" "$SNIPPET" "$ACTION" "$DRY_RUN" <<'PY'
import json, os, sys, tempfile, time, difflib

path, snippet_path, action, dry_run = sys.argv[1:5]
dry_run = dry_run == "1"
MARK = "needs-you-hook.sh"


def ours(hook):
    return isinstance(hook, dict) and MARK in str(hook.get("command", ""))


if os.path.islink(path):
    sys.exit("error: %s is a symlink; not writing through it. Nothing was changed: merge cursor-hooks.json "
             "into the file it points to by hand." % path)

original_text = None
doc = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            original_text = f.read()
    except UnicodeDecodeError:
        sys.exit("error: %s isn't UTF-8 text; nothing was changed" % path)
    if original_text.strip():
        try:
            doc = json.loads(original_text)
        except json.JSONDecodeError as e:
            sys.exit("error: %s is not valid JSON (%s); fix it first, nothing was changed" % (path, e))
    if not isinstance(doc, dict):
        sys.exit("error: %s does not contain a JSON object; nothing was changed" % path)

snippet = {}
if action == "install":
    with open(snippet_path, encoding="utf-8") as f:
        snippet = json.load(f)["hooks"]

hooks = doc.get("hooks")
if hooks is None:
    hooks = {}
if not isinstance(hooks, dict):
    sys.exit("error: \"hooks\" in %s is not an object; nothing was changed" % path)

# 1. Remove every needs-you entry from every event (Cursor's entries are flat: {command, ...});
#    other hooks stay exactly as they were.
for event in list(hooks):
    entries = hooks[event]
    if not isinstance(entries, list):
        continue
    kept = [h for h in entries if not ours(h)]
    if len(kept) != len(entries):
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

# 2. Add ours back (install only), after the existing entries.
if action == "install":
    for event, entries in snippet.items():
        hooks.setdefault(event, []).extend(json.loads(json.dumps(entries)))

if hooks:
    doc["hooks"] = hooks
    if "version" not in doc:
        doc = dict([("version", 1)] + list(doc.items()))
else:
    doc.pop("hooks", None)

new_text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
if original_text is not None and original_text.strip():
    try:
        unchanged = json.loads(original_text) == doc
    except Exception:
        unchanged = False
else:
    unchanged = action == "uninstall"

if unchanged:
    print("hooks.json: already up to date, not rewritten")
    sys.exit(0)
if dry_run:
    old = (original_text or "").splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(old, new_text.splitlines(keepends=True), path, path + " (new)"))
    print("hooks.json: dry run, nothing written")
    sys.exit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
if original_text is not None:
    # O_EXCL: a backup name that already exists (or is a planted symlink) is never written.
    backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    n = 0
    while True:
        try:
            bfd = os.open(backup if not n else "%s.%d" % (backup, n), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            n += 1
    if n:
        backup = "%s.%d" % (backup, n)
    with os.fdopen(bfd, "w", encoding="utf-8") as f:
        f.write(original_text)
    print("hooks.json: backed up to %s" % backup)
    mode = os.stat(path).st_mode & 0o777
else:
    mode = 0o644
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hooks.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(new_text)
os.chmod(tmp, mode)
os.replace(tmp, path)
print("hooks.json: %s" % ("needs-you hooks installed" if action == "install" else "needs-you hooks removed"))
PY

# ---- hook script
if [ "$ACTION" = "install" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would copy $HOOK_SRC"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ] && cmp -s "$HOOK_SRC" "$HOOKS_DIR/needs-you-hook.sh"; then
    echo "hook: already up to date"
  else
    mkdir -p "$HOOKS_DIR"
    tmp_hook=$(mktemp "$HOOKS_DIR/.needs-you-hook.XXXXXX")
    cat "$HOOK_SRC" >"$tmp_hook"
    chmod 755 "$tmp_hook"
    mv -f "$tmp_hook" "$HOOKS_DIR/needs-you-hook.sh"
    echo "hook: installed"
  fi
  ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
  echo ""
  echo "Next:"
  cat <<'EOF'
  - Cursor has no hook for "waiting for your approval": you get a card when the agent
    finishes its turn (or stops on an error), not when it asks to run something.
EOF
  if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
    echo "  - Alerts are on for every agent session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
  else
    cat <<'EOF'
  - The hooks stay quiet until opted in: NEEDS_YOU_AGENT_ALERTS=1 as a line in
    ~/.config/needs-you/env (the invite installer's --alerts writes it). Cursor starts
    hooks from the app, so a variable in your shell profile may not reach them.
EOF
  fi
  if [ "${NEEDS_YOU_INSTALLER:-}" != 1 ]; then
    cat <<'EOF'
  - They call the needs-you CLI; check `needs-you --help` works here (an invite
    link's installer, or scripts/setup-sender.sh, installs it).
EOF
  fi
  echo "  - Cursor picks up hooks.json changes by itself; restart Cursor if no card comes."
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would remove $HOOKS_DIR/needs-you-hook.sh"
  elif grep -qs 'needs-you-hook.sh' "$HOOKS_FILE"; then
    echo "hook: kept $HOOKS_DIR/needs-you-hook.sh (something in $HOOKS_FILE still uses it)"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ]; then
    rm -f "$HOOKS_DIR/needs-you-hook.sh"
    rmdir "$HOOKS_DIR" 2>/dev/null || true
    echo "hook: removed"
  fi
fi
