#!/usr/bin/env bash
# needs-you-version: 0.5.0
# install-aider-notifications.sh: have Aider post a needs-you card when it waits for you.
#
#   ./install-aider-notifications.sh                 ~/.aider.conf.yml
#   ./install-aider-notifications.sh --conf FILE     FILE instead
#   ./install-aider-notifications.sh --uninstall     remove it again
#
# Aider runs its notifications command each time it waits for you after an LLM reply. This
# copies the shared needs-you-hook.sh to ~/.config/needs-you/aider/hooks/ and adds a marked
# block to ~/.aider.conf.yml that turns notifications on and points them at it. The file is
# changed only when that is safe: it isn't a symlink, it is a plain YAML mapping, and it sets
# neither key itself. Otherwise nothing is written there and the lines to add are printed
# (exit 4). Re-running is safe. The card does nothing until you opt in:
# NEEDS_YOU_AGENT_ALERTS=1. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

CONF="$HOME/.aider.conf.yml"
HOOK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/aider/hooks"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --conf FILE   Aider's config file (default: ~/.aider.conf.yml)
  --uninstall   Remove the needs-you block and the copied hook script
  --dry-run     Show what would change; write nothing
  -h, --help    Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --conf) [ $# -ge 2 ] || die "--conf needs a file" 2; CONF=$2; shift 2 ;;
    --conf=*) CONF=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
HOOK="$HOOK_DIR/needs-you-hook.sh"
for p in "$HOOK_DIR" "$HOOK"; do
  [ -L "$p" ] && die "$p is a symlink; not writing through it. Nothing was changed."
done
# The command as Aider's shell sees it: $HOME keeps the file the same on every machine.
case "$HOOK" in
  "$HOME"/*) CMD="\"\$HOME/${HOOK#"$HOME"/}\" notify aider" ;;
  *) CMD="\"$HOOK\" notify aider" ;;
esac
case "$HOOK" in *[\'\"\\\`\$]*) die "the hook path $HOOK has quotes, backslashes, \` or \$ in it" ;; esac

echo "config:   $CONF"
echo "hook:     $HOOK"

# ---- the marked block (python3 does the file; exit 4: not safe to change, lines printed)
set +e
python3 - "$CONF" "$CMD" "$ACTION" "$DRY_RUN" <<'PY'
import os, re, sys, tempfile, time

path, cmd, action, dry_run = sys.argv[1:5]
dry_run = dry_run == "1"
BEGIN = "# needs-you (managed by install-aider-notifications.sh; do not edit between these markers)"
END = "# end needs-you"
# In the block when the file's last line had no newline: the uninstall takes out the one added.
NO_EOL = "# (the file had no newline at its end)"
block = "%s\nnotifications: true\nnotifications-command: '%s'\n%s\n" % (BEGIN, cmd.replace("'", "''"), END)


def by_hand(why):
    print("%s: %s, so it was not changed." % (path, why))
    if action == "install":
        print("Add these two lines to it yourself (or pass them as --notifications "
              "--notifications-command):\n")
        print("notifications: true\nnotifications-command: '%s'\n" % cmd.replace("'", "''"))
    sys.exit(4)


if os.path.islink(path):
    by_hand("it is a symlink")
text = ""
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8", newline="") as fh:  # CRLF stays CRLF
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        by_hand("it can't be read as UTF-8 text")
lines = text.splitlines(keepends=True)
# Our block, start to end, wherever it is.
out, inside, found, no_eol, at = [], False, False, False, 0
for line in lines:
    s = line.rstrip("\r\n")
    if s == BEGIN:
        inside, found, at = True, True, len(out)
        continue
    if inside:
        if s == END:
            inside = False
        no_eol = no_eol or s == NO_EOL
        continue
    out.append(line)
if inside:
    by_hand("it has the needs-you start marker but no end marker")
if no_eol and at == len(out) and out and out[-1].endswith("\n"):
    out[-1] = out[-1][:-1]  # the newline the install added to the last line
rest = "".join(out)
if action == "install":
    meaningful = [l for l in rest.splitlines() if l.strip() and not l.lstrip().startswith("#")]
    if meaningful and (meaningful[0].lstrip()[:1] in "{[-" or
                       any(l.startswith(("---", "...")) for l in meaningful)):
        by_hand("it isn't a plain YAML mapping")
    for l in meaningful:
        m = re.match(r"^(notifications|notifications-command)\s*:", l)
        if m:
            by_hand("it already sets %s" % m.group(1))
    if not rest or rest.endswith("\n"):
        new = rest + block
    else:
        new = rest + "\n" + block.replace("\n", "\n" + NO_EOL + "\n", 1)
else:
    new = rest
if new == text or (action == "uninstall" and not found):
    print("aider.conf.yml: already up to date, not rewritten")
    sys.exit(0)
if dry_run:
    print("aider.conf.yml: dry run, would %s the needs-you block" % ("write" if action == "install" else "remove"))
    sys.exit(0)
d = os.path.dirname(os.path.abspath(path))
if text:
    backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    n = 0
    while True:
        try:
            bfd = os.open(backup if not n else "%s.%d" % (backup, n), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            n += 1
    with os.fdopen(bfd, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    mode = os.stat(path).st_mode & 0o777
elif os.path.exists(path):
    mode = os.stat(path).st_mode & 0o777  # an empty file of the person's: its mode stays
else:
    mode = 0o644
if action == "uninstall" and not new.strip():
    os.remove(path)  # it held only our block
    print("aider.conf.yml: removed (it held only the needs-you block)")
    sys.exit(0)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".aider.conf.", suffix=".yml")
with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
    fh.write(new)
os.chmod(tmp, mode)
os.replace(tmp, path)
print("aider.conf.yml: %s" % ("needs-you block written" if action == "install" else "needs-you block removed"))
PY
rc=$?
set -e
[ "$rc" -eq 0 ] || [ "$rc" -eq 4 ] || exit "$rc"

# ---- backups (uninstall): delete the ones that hold only needs-you's part; any with the
# person's own settings in them stay
if [ "$ACTION" = "uninstall" ] && [ "$DRY_RUN" -eq 0 ]; then
  python3 - "$CONF" <<'PY'
import os, sys
# needs-you-backups:begin (the same in cli/needs-you and each installer; tests/test_uninstall_backups.py checks)
def only_needs_you(text):
    """Would restoring this backup bring back nothing of the person's? True when all it holds
    is needs-you's own part (hooks running needs-you-hook.sh, the needs-you MCP server, a
    needs-you marked block) in an otherwise empty or defaults-only ({}, {"version": 1}) file."""
    import json
    marks = (("# needs-you (managed by install-", "# end needs-you"),
             ("# >>> needs-you MCP server", "# <<< needs-you MCP server"),
             ("<!-- needs-you:begin", "<!-- needs-you:end"))
    out, end = [], None
    for line in text.splitlines(True):
        if end is None:
            end = next((e for b, e in marks if line.startswith(b)), None)
            if end is None:
                out.append(line)
        elif line.startswith(end):
            end = None
    if end is not None:
        return False
    rest = "".join(out)
    if not rest.strip():
        return True
    try:
        doc = json.loads(rest)
    except ValueError:
        return False
    if not isinstance(doc, dict):
        return False
    doc = dict(doc)

    def ours(h):
        return isinstance(h, dict) and "needs-you-hook.sh" in str(h.get("command", ""))
    hooks = doc.pop("hooks", {})
    if not isinstance(hooks, dict):
        return False
    for groups in hooks.values():
        if not isinstance(groups, list):
            return False
        for g in groups:  # a group of hooks, or one flat entry (Cursor)
            if not (ours(g) or (isinstance(g, dict) and isinstance(g.get("hooks"), list) and g["hooks"]
                                and all(ours(h) for h in g["hooks"]))):
                return False
    for key in ("mcpServers", "mcp"):
        servers = doc.pop(key, {})
        if not isinstance(servers, dict) or any(k != "needs-you" or "needs-you-mcp" not in json.dumps(v)
                                                for k, v in servers.items()):
            return False
    return doc in ({}, {"version": 1})


def ny_backups(path):
    """The backups of this config file that hold only needs-you's part (only_needs_you): the
    installers' <name>.bak-<date>-<time>[-<pid>][.<n>], regular files of this user's next to
    the file (or the file its symlink points to). Uninstall deletes them; every backup with
    anything of the person's in it stays."""
    import os, re, stat
    found = []
    for p in sorted({os.path.abspath(path), os.path.realpath(path)}):
        d, base = os.path.split(p)
        pat = re.compile(re.escape(base) + r"\.bak-\d{8}-\d{6}(-\d+)?(\.\d+)?$")
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            b = os.path.join(d, n)
            if not pat.match(n) or b in found:
                continue
            try:
                fd = os.open(b, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
                with os.fdopen(fd, "rb") as fh:
                    st = os.fstat(fh.fileno())
                    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 1 << 20:
                        continue
                    text = fh.read().decode("utf-8")
            except (OSError, ValueError):
                continue
            if only_needs_you(text):
                found.append(b)
    return found
# needs-you-backups:end

gone = 0
for b in ny_backups(sys.argv[1]):
    try:
        os.remove(b)
        gone += 1
    except OSError:
        pass
if gone:
    print("backups:  deleted %d that held only needs-you's part" % gone)
PY
fi

# ---- hook script
if [ "$ACTION" = uninstall ]; then
  if [ -f "$HOOK" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "hook: dry run, would delete $HOOK"
    else
      rm -f "$HOOK"
      rmdir "$HOOK_DIR" "$(dirname "$HOOK_DIR")" 2>/dev/null || true
      echo "hook: removed"
    fi
  fi
  exit "$rc"
fi
[ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "hook: dry run, would copy $HOOK_SRC"
elif [ -f "$HOOK" ] && cmp -s "$HOOK_SRC" "$HOOK"; then
  echo "hook: already up to date"
else
  mkdir -p "$HOOK_DIR"
  tmp_hook=$(mktemp "$HOOK_DIR/.needs-you-hook.XXXXXX")
  cat "$HOOK_SRC" >"$tmp_hook"
  chmod 755 "$tmp_hook"
  mv -f "$tmp_hook" "$HOOK"
  echo "hook: installed"
fi

ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
echo ""
echo "Next:"
cat <<'EOF'
  - Aider says only that it is waiting, never what for, and nothing when you answer: the
    card stays until Aider exits (the 5-minute `needs-you flush` notices) or for an hour
    (NEEDS_YOU_AIDER_EXPIRY_HOURS), and the next wait updates it.
  - A .aider.conf.yml in a repo, or AIDER_NOTIFICATIONS_COMMAND, overrides this one.
EOF
if grep -Eqs "^[[:space:]]*(export[[:space:]]+)?NEEDS_YOU_AGENT_ALERTS=['\"]?(1|true|yes|on)['\"]?[[:space:]]*$" "$ENV_FILE"; then
  echo "  - Alerts are on for every agent session here (NEEDS_YOU_AGENT_ALERTS=1 in $ENV_FILE)."
else
  cat <<'EOF'
  - The card stays quiet until opted in: NEEDS_YOU_AGENT_ALERTS=1 in your shell profile,
    or as a line in ~/.config/needs-you/env for every session on this machine (the
    invite installer's --alerts writes that line).
EOF
fi
if [ "${NEEDS_YOU_INSTALLER:-}" != 1 ]; then
  cat <<'EOF'
  - It calls the needs-you CLI; check `needs-you --help` works here (an invite link's
    installer, or scripts/setup-sender.sh, installs it).
EOF
fi
echo "  - Restart running Aider sessions to pick up the change."
exit "$rc"
