#!/usr/bin/env bash
# install-hooks.sh: add the needs-you hooks to a Claude Code settings.json.
#
#   ./install-hooks.sh                      user level: ~/.claude/settings.json
#   ./install-hooks.sh --project [DIR]      project level: DIR/.claude/settings.json (default DIR: .)
#   ./install-hooks.sh --project DIR --local   DIR/.claude/settings.local.json (not committed)
#   ./install-hooks.sh --uninstall [...]    remove them again
#
# Copies needs-you-hook.sh next to the settings (…/.claude/hooks/), backs up
# the settings file before changing it, and merges with python3 (no jq).
# Re-running is safe: existing needs-you entries are replaced, nothing else is
# touched, and an unchanged file is not rewritten.
#
# The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a
# session started by Orca ($ORCA_TERMINAL_HANDLE). See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK_SRC="$HERE/needs-you-hook.sh"
SNIPPET="$HERE/hooks.json"

SCOPE="user"
PROJECT_DIR=""
LOCAL=0
SETTINGS=""
HOOKS_DIR=""
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --user              User level (default): ~/.claude/settings.json
  --project [DIR]     Project level: DIR/.claude/settings.json (DIR defaults to .)
  --local             With --project: use settings.local.json instead
  --settings FILE     Explicit settings file (hook script goes to FILE's dir/hooks/)
  --uninstall         Remove the needs-you hooks (and the copied hook script)
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) SCOPE="user"; shift ;;
    --project)
      SCOPE="project"
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then PROJECT_DIR=$2; shift; fi
      shift ;;
    --project=*) SCOPE="project"; PROJECT_DIR=${1#*=}; shift ;;
    --local) LOCAL=1; shift ;;
    --settings) [ $# -ge 2 ] || die "--settings needs a value" 2; SCOPE="file"; SETTINGS=$2; shift 2 ;;
    --settings=*) SCOPE="file"; SETTINGS=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
if [ "$ACTION" = "install" ]; then  # uninstall needs neither file
  [ -f "$HOOK_SRC" ] || die "missing $HOOK_SRC"
  [ -f "$SNIPPET" ] || die "missing $SNIPPET"
fi

# The command string written into settings.json. User level uses $HOME so the
# same settings work on every machine; project level uses $CLAUDE_PROJECT_DIR
# so a committed .claude/settings.json works for everyone who clones the repo.
# The $VARS are literal on purpose: Claude Code's shell expands them later.
# shellcheck disable=SC2016
case "$SCOPE" in
  user)
    SETTINGS="$HOME/.claude/settings.json"
    HOOKS_DIR="$HOME/.claude/hooks"
    CMD_PREFIX='"$HOME/.claude/hooks/needs-you-hook.sh"'
    ;;
  project)
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR=.
    [ -d "$PROJECT_DIR" ] || die "no such directory: $PROJECT_DIR"
    PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
    if [ "$LOCAL" -eq 1 ]; then
      SETTINGS="$PROJECT_DIR/.claude/settings.local.json"
    else
      SETTINGS="$PROJECT_DIR/.claude/settings.json"
    fi
    HOOKS_DIR="$PROJECT_DIR/.claude/hooks"
    CMD_PREFIX='"$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh"'
    ;;
  file)
    SETTINGS_DIR=$(cd "$(dirname "$SETTINGS")" 2>/dev/null && pwd) || die "no such directory: $(dirname "$SETTINGS")"
    SETTINGS="$SETTINGS_DIR/$(basename "$SETTINGS")"
    HOOKS_DIR="$SETTINGS_DIR/hooks"
    CMD_PREFIX="\"$HOOKS_DIR/needs-you-hook.sh\""
    ;;
esac

echo "settings: $SETTINGS"
echo "hook:     $HOOKS_DIR/needs-you-hook.sh"

# ---- merge (python3 does the JSON; it prints a status line)
python3 - "$SETTINGS" "$SNIPPET" "$CMD_PREFIX" "$ACTION" "$DRY_RUN" <<'PY'
import json, os, sys, tempfile, time, difflib

settings_path, snippet_path, cmd_prefix, action, dry_run = sys.argv[1:6]
dry_run = dry_run == "1"
MARK = "needs-you-hook.sh"
USER_SNIPPET_PREFIX = '"$HOME/.claude/hooks/needs-you-hook.sh"'

def ours(hook):
    return isinstance(hook, dict) and MARK in str(hook.get("command", ""))

# Load current settings. Missing or empty file = {}. Invalid JSON = stop.
original_text = None
settings = {}
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        original_text = f.read()
    if original_text.strip():
        try:
            settings = json.loads(original_text)
        except json.JSONDecodeError as e:
            sys.exit("error: %s is not valid JSON (%s); fix it first, nothing was changed" % (settings_path, e))
    if not isinstance(settings, dict):
        sys.exit("error: %s does not contain a JSON object; nothing was changed" % settings_path)

snippet = {}
if action == "install":
    with open(snippet_path, encoding="utf-8") as f:
        snippet = json.load(f)["hooks"]

hooks = settings.get("hooks")
if hooks is None:
    hooks = {}
if not isinstance(hooks, dict):
    sys.exit("error: \"hooks\" in %s is not an object; nothing was changed" % settings_path)

# 1. Remove every existing needs-you hook, from every event, leaving other
#    hooks (and their groups) exactly as they were.
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
                    continue  # the group only held our hook
                group = dict(group, hooks=kept)
        new_groups.append(group)
    if new_groups:
        hooks[event] = new_groups
    else:
        del hooks[event]

# 2. Add ours back (install only).
if action == "install":
    for event, groups in snippet.items():
        for group in groups:
            group = json.loads(json.dumps(group))
            for h in group["hooks"]:
                h["command"] = h["command"].replace(USER_SNIPPET_PREFIX, cmd_prefix)
            hooks.setdefault(event, []).append(group)

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

new_text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"

if original_text is not None and original_text.strip():
    try:
        unchanged = json.loads(original_text) == settings
    except Exception:
        unchanged = False
else:
    unchanged = action == "uninstall" and not settings

if unchanged:
    print("settings: already up to date, not rewritten")
    sys.exit(0)

if dry_run:
    old = (original_text or "").splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(old, new_text.splitlines(keepends=True),
                                               settings_path, settings_path + " (new)"))
    print("settings: dry run, nothing written")
    sys.exit(0)

# Write through symlinks (dotfile managers), keep the file's mode, and
# replace atomically. Back up first.
real = os.path.realpath(settings_path)
os.makedirs(os.path.dirname(real), exist_ok=True)
if original_text is not None:
    backup = "%s.bak-%s" % (real, time.strftime("%Y%m%d-%H%M%S"))
    with open(backup, "w", encoding="utf-8") as f:
        f.write(original_text)
    print("settings: backed up to %s" % backup)
    mode = os.stat(real).st_mode & 0o777
else:
    mode = 0o644
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(new_text)
os.chmod(tmp, mode)
os.replace(tmp, real)
print("settings: %s" % ("needs-you hooks installed" if action == "install" else "needs-you hooks removed"))
PY

# ---- hook script
if [ "$ACTION" = "install" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would copy $HOOK_SRC"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ] && cmp -s "$HOOK_SRC" "$HOOKS_DIR/needs-you-hook.sh"; then
    echo "hook: already up to date"
  else
    mkdir -p "$HOOKS_DIR"
    cp "$HOOK_SRC" "$HOOKS_DIR/needs-you-hook.sh.tmp"
    chmod 755 "$HOOKS_DIR/needs-you-hook.sh.tmp"
    mv -f "$HOOKS_DIR/needs-you-hook.sh.tmp" "$HOOKS_DIR/needs-you-hook.sh"
    echo "hook: installed"
  fi
  ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
  echo ""
  echo "Next:"
  if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
    echo "  - Alerts are on for every Claude Code session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
  else
    cat <<'EOF'
  - The hooks stay quiet until opted in. Either run Claude from Orca, or set
    NEEDS_YOU_AGENT_ALERTS=1 (in your shell profile, or as a line in
    ~/.config/needs-you/env to opt in every session on this machine; the
    invite installer's --alerts writes that line).
EOF
  fi
  # The invite installer sets NEEDS_YOU_INSTALLER=1: it has just installed the CLI.
  if [ "${NEEDS_YOU_INSTALLER:-}" != 1 ]; then
    cat <<'EOF'
  - They call the needs-you CLI; check `needs-you --help` works here (an invite
    link's installer, or scripts/setup-sender.sh, installs it).
EOF
  fi
  cat <<'EOF'
  - Restart Claude Code sessions (or open /hooks) to pick up the change.
EOF
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would remove $HOOKS_DIR/needs-you-hook.sh"
  elif grep -qs 'needs-you-hook.sh' "$(dirname "$HOOKS_DIR")/settings.json" "$(dirname "$HOOKS_DIR")/settings.local.json"; then
    echo "hook: kept $HOOKS_DIR/needs-you-hook.sh (another settings file next to it still uses it)"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ]; then
    rm -f "$HOOKS_DIR/needs-you-hook.sh"
    rmdir "$HOOKS_DIR" 2>/dev/null || true
    echo "hook: removed"
  fi
fi
