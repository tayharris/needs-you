#!/usr/bin/env bash
# needs-you-version: 0.3.0
# install-gemini-hooks.sh: add the needs-you hooks to Gemini CLI's settings.json.
#
#   ./install-gemini-hooks.sh                  ~/.gemini/settings.json
#   ./install-gemini-hooks.sh --gemini-dir DIR    DIR/settings.json
#   ./install-gemini-hooks.sh --uninstall      remove them again
#
# Copies the shared needs-you-hook.sh (integrations/claude-code/) to <dir>/hooks/, backs
# up settings.json before changing it, and merges with python3 (no jq). Re-running is safe:
# existing needs-you entries are replaced, every other setting and hook is kept, and an
# unchanged file is not rewritten. A settings.json with comments (Gemini allows them) is
# left alone: merge gemini-hooks.json by hand.
#
# The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a session started by
# Orca ($ORCA_TERMINAL_HANDLE). See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/gemini-hooks.json"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

GEMINI_DIR=""
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --gemini-dir DIR    Gemini CLI's user directory (default: ~/.gemini)
  --uninstall         Remove the needs-you hooks (and the copied hook script)
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --gemini-dir) [ $# -ge 2 ] || die "--gemini-dir needs a directory" 2; GEMINI_DIR=$2; shift 2 ;;
    --gemini-dir=*) GEMINI_DIR=${1#*=}; shift ;;
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

# The command written into settings.json. The default directory uses $HOME so the same
# file works on every machine; Gemini runs hook commands through a shell, which expands it.
# shellcheck disable=SC2016
if [ -z "$GEMINI_DIR" ] || [ "$GEMINI_DIR" = "$HOME/.gemini" ]; then
  GEMINI_DIR="$HOME/.gemini"
  CMD_PREFIX='"$HOME/.gemini/hooks/needs-you-hook.sh"'
else
  mkdir -p "$GEMINI_DIR" 2>/dev/null || die "can't create $GEMINI_DIR"
  GEMINI_DIR=$(cd "$GEMINI_DIR" && pwd)
  case "$GEMINI_DIR" in *[\"\\\`\$]*) die "--gemini-dir can't contain quotes, backslashes, \` or \$" ;; esac
  CMD_PREFIX="\"$GEMINI_DIR/hooks/needs-you-hook.sh\""
fi
SETTINGS="$GEMINI_DIR/settings.json"
HOOKS_DIR="$GEMINI_DIR/hooks"

echo "settings: $SETTINGS"
echo "hook:     $HOOKS_DIR/needs-you-hook.sh"

# ---- merge (python3 does the JSON; it prints a status line)
python3 - "$SETTINGS" "$SNIPPET" "$CMD_PREFIX" "$ACTION" "$DRY_RUN" <<'PY'
import json, os, sys, tempfile, time, difflib

path, snippet_path, cmd_prefix, action, dry_run = sys.argv[1:6]
dry_run = dry_run == "1"
MARK = "needs-you-hook.sh"
SNIPPET_PREFIX = '"$HOME/.gemini/hooks/needs-you-hook.sh"'



def created(path, mark=None):
    """needs-you's record of the agent config files its installers made (`created_files` in
    its update.json, which `needs-you uninstall-hooks` reads too): mark=True adds path, False
    drops it. Returns whether path was recorded. Best effort: never fails the install."""
    import json, tempfile
    d = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
                     "needs-you")
    p, real = os.path.join(d, "update.json"), os.path.realpath(path)
    try:
        with open(p, encoding="utf-8") as fh:
            st = json.load(fh)
        st = st if isinstance(st, dict) else {}
    except (OSError, ValueError):
        st = {}
    files = [f for f in st.get("created_files") or [] if isinstance(f, str)]
    was = any(os.path.realpath(f) == real for f in files)
    if mark is not None and mark != was:
        st["created_files"] = [f for f in files if os.path.realpath(f) != real] + ([real] if mark else [])
        try:
            os.makedirs(d, mode=0o700, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".update.")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(st, fh, sort_keys=True)
            os.replace(tmp, p)
        except OSError:
            pass
    return was

def ours(hook):
    return isinstance(hook, dict) and MARK in str(hook.get("command", ""))


# Another agent's config: never write through a symlink (it could point anywhere), and
# treat the file as data only.
if os.path.islink(path):
    sys.exit("error: %s is a symlink; not writing through it. Nothing was changed: merge gemini-hooks.json "
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
            sys.exit("error: %s is not plain JSON (%s; comments aren't supported here). Nothing was "
                     "changed: merge gemini-hooks.json into it by hand." % (path, e))
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
removed = False  # did we take anything out (only then may an event or "hooks" go)
for event in list(hooks):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    new_groups, touched = [], False
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            kept = [h for h in group["hooks"] if not ours(h)]
            if len(kept) != len(group["hooks"]):
                touched = True
                if not kept:
                    continue
                group = dict(group, hooks=kept)
        new_groups.append(group)
    removed = removed or touched
    if new_groups or not touched:
        hooks[event] = new_groups
    else:
        del hooks[event]  # it held only ours

# 2. Add ours back (install only), after any existing groups.
if action == "install":
    for event, groups in snippet.items():
        for group in groups:
            group = json.loads(json.dumps(group))
            for h in group["hooks"]:
                h["command"] = h["command"].replace(SNIPPET_PREFIX, cmd_prefix)
            hooks.setdefault(event, []).append(group)

if hooks or (not removed and "hooks" in doc):  # (an empty one of the person's own stays)
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
    print("settings: already up to date, not rewritten")
    sys.exit(0)
if dry_run:
    old = (original_text or "").splitlines(keepends=True)
    sys.stdout.writelines(difflib.unified_diff(old, new_text.splitlines(keepends=True), path, path + " (new)"))
    print("settings: dry run, nothing written")
    sys.exit(0)

# A file an installer made goes again once the uninstall leaves only defaults in it; one
# that was there before stays.
if action == "uninstall" and doc in ({}, {"version": 1}) and created(path):
    os.remove(path)
    created(path, False)
    print("settings: needs-you hooks removed; deleted %s (needs-you created it)" % path)
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
    print("settings: backed up to %s" % backup)
    mode = os.stat(real).st_mode & 0o777
else:
    mode = 0o644
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(new_text)
os.chmod(tmp, mode)
os.replace(tmp, real)
if action == "install" and original_text is None:
    created(path, True)
print("settings: %s" % ("needs-you hooks installed" if action == "install" else "needs-you hooks removed"))

# hooksConfig.enabled = false turns every hook off.
hc = doc.get("hooksConfig")
if action == "install" and isinstance(hc, dict) and hc.get("enabled") is False:
    print("warning: hooksConfig.enabled is false in %s: no hook runs until it's true" % path)
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
  echo "  - Restart running Gemini CLI sessions (or run /hooks to see them)."
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "hook: dry run, would remove $HOOKS_DIR/needs-you-hook.sh"
  elif grep -qs 'needs-you-hook.sh' "$SETTINGS"; then
    echo "hook: kept $HOOKS_DIR/needs-you-hook.sh ($SETTINGS still uses it)"
  elif [ -f "$HOOKS_DIR/needs-you-hook.sh" ]; then
    rm -f "$HOOKS_DIR/needs-you-hook.sh"
    rmdir "$HOOKS_DIR" 2>/dev/null || true
    echo "hook: removed"
  fi
fi
