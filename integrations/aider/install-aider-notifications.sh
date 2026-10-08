#!/usr/bin/env bash
# needs-you-version: 0.2.1
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
out, inside, found = [], False, False
for line in lines:
    s = line.rstrip("\r\n")
    if s == BEGIN:
        inside, found = True, True
        continue
    if inside:
        if s == END:
            inside = False
        continue
    out.append(line)
if inside:
    by_hand("it has the needs-you start marker but no end marker")
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
    new = rest + ("" if not rest or rest.endswith("\n") else "\n") + block
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
