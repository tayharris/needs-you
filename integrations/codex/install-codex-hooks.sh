#!/usr/bin/env bash
# needs-you-version: 0.1.5
# install-codex-hooks.sh: add the needs-you hooks to OpenAI Codex CLI's hooks.json.
#
#   ./install-codex-hooks.sh                 ~/.codex/hooks.json ($CODEX_HOME/hooks.json if set)
#   ./install-codex-hooks.sh --codex-home DIR   DIR/hooks.json
#   ./install-codex-hooks.sh --uninstall     remove them again
#
# Copies the shared needs-you-hook.sh (integrations/claude-code/) to <codex home>/hooks/,
# backs up hooks.json before changing it, and merges with python3 (no jq). Re-running is
# safe: existing needs-you entries are replaced, every other hook (Orca's, your own) is
# kept, and an unchanged file is not rewritten.
#
# Codex runs a new hook only after you trust it: open /hooks in Codex once and trust the
# needs-you entries. The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a
# session started by Orca ($ORCA_TERMINAL_HANDLE). See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/codex-hooks.json"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

CODEX_DIR="${CODEX_HOME:-}"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --codex-home DIR    Codex's home directory (default: \$CODEX_HOME, else ~/.codex)
  --uninstall         Remove the needs-you hooks (and the copied hook script)
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --codex-home) [ $# -ge 2 ] || die "--codex-home needs a directory" 2; CODEX_DIR=$2; shift 2 ;;
    --codex-home=*) CODEX_DIR=${1#*=}; shift ;;
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

# The command written into hooks.json. The default home uses $HOME so the same file works
# on every machine; Codex runs hook commands through a shell, which expands it.
# shellcheck disable=SC2016
if [ -z "$CODEX_DIR" ] || [ "$CODEX_DIR" = "$HOME/.codex" ]; then
  CODEX_DIR="$HOME/.codex"
  CMD_PREFIX='"$HOME/.codex/hooks/needs-you-hook.sh"'
else
  mkdir -p "$CODEX_DIR" 2>/dev/null || die "can't create $CODEX_DIR"
  CODEX_DIR=$(cd "$CODEX_DIR" && pwd)
  case "$CODEX_DIR" in *[\"\\\`\$]*) die "--codex-home can't contain quotes, backslashes, \` or \$" ;; esac
  CMD_PREFIX="\"$CODEX_DIR/hooks/needs-you-hook.sh\""
fi
HOOKS_FILE="$CODEX_DIR/hooks.json"
HOOKS_DIR="$CODEX_DIR/hooks"

echo "hooks:    $HOOKS_FILE"
echo "hook:     $HOOKS_DIR/needs-you-hook.sh"

# ---- merge (python3 does the JSON; it prints a status line)
python3 - "$HOOKS_FILE" "$SNIPPET" "$CMD_PREFIX" "$ACTION" "$DRY_RUN" <<'PY'
import json, os, sys, tempfile, time, difflib

path, snippet_path, cmd_prefix, action, dry_run = sys.argv[1:6]
dry_run = dry_run == "1"
MARK = "needs-you-hook.sh"
SNIPPET_PREFIX = '"$HOME/.codex/hooks/needs-you-hook.sh"'


def ours(hook):
    return isinstance(hook, dict) and MARK in str(hook.get("command", ""))


# Another agent's config: never write through a symlink (it could point anywhere), and
# treat the file as data only.
if os.path.islink(path):
    sys.exit("error: %s is a symlink; not writing through it. Nothing was changed: merge codex-hooks.json "
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

# 1. Remove every needs-you hook from every event; other hooks stay exactly as they were.
for event in list(hooks):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    new_groups = []
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            kept = [h for h in group["hooks"] if not ours(h)]
            if len(kept) != len(group["hooks"]):
                if not kept:
                    continue
                group = dict(group, hooks=kept)
        new_groups.append(group)
    if new_groups:
        hooks[event] = new_groups
    else:
        del hooks[event]

# 2. Add ours back (install only), after any existing groups so their positions (and the
#    trust Codex recorded for them) don't move.
if action == "install":
    for event, groups in snippet.items():
        for group in groups:
            group = json.loads(json.dumps(group))
            for h in group["hooks"]:
                h["command"] = h["command"].replace(SNIPPET_PREFIX, cmd_prefix)
            hooks.setdefault(event, []).append(group)

if hooks:
    doc["hooks"] = hooks
else:
    doc.pop("hooks", None)

new_text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
if original_text is not None and original_text.strip():
    try:
        unchanged = json.loads(original_text) == doc
    except Exception:
        unchanged = False
else:
    unchanged = action == "uninstall" and not doc

if unchanged:
    print("hooks.json: already up to date, not rewritten")
    sys.exit(0)
if dry_run:
    old = (original_text or "").splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(old, new_text.splitlines(keepends=True), path, path + " (new)"))
    print("hooks.json: dry run, nothing written")
    sys.exit(0)

real = path
os.makedirs(os.path.dirname(real), exist_ok=True)
if original_text is not None:
    # O_EXCL: a backup name that already exists (or is a planted symlink) is never written.
    backup = "%s.bak-%s" % (real, time.strftime("%Y%m%d-%H%M%S"))
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
    mode = os.stat(real).st_mode & 0o777
else:
    mode = 0o644
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".hooks.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(new_text)
os.chmod(tmp, mode)
os.replace(tmp, real)
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
  - Codex skips hooks you haven't trusted. Start Codex, open /hooks, and trust the
    needs-you entries (once; re-running this installer keeps them trusted unless the
    entries change).
EOF
  # [features] hooks = false turns every hook off.
  if [ -f "$CODEX_DIR/config.toml" ] &&
     awk '/^[[:space:]]*\[/ { s = $0 } s ~ /^[[:space:]]*\[features\]/ && /^[[:space:]]*hooks[[:space:]]*=[[:space:]]*false/ { f = 1 } END { exit !f }' "$CODEX_DIR/config.toml"; then
    echo "  - $CODEX_DIR/config.toml has hooks = false under [features]: remove it, or no hook runs."
  fi
  if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
    echo "  - Alerts are on for every Codex and Claude Code session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
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
  echo "  - Restart running Codex sessions to pick up the change."
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would remove $HOOKS_DIR/needs-you-hook.sh"
  elif grep -qs 'needs-you-hook.sh' "$HOOKS_FILE" "$CODEX_DIR/config.toml"; then
    echo "hook: kept $HOOKS_DIR/needs-you-hook.sh (something in $CODEX_DIR still uses it)"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ]; then
    rm -f "$HOOKS_DIR/needs-you-hook.sh"
    rmdir "$HOOKS_DIR" 2>/dev/null || true
    echo "hook: removed"
  fi
fi
