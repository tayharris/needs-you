#!/usr/bin/env bash
# needs-you-version: 0.1.3
# install-kimi-hooks.sh: add the needs-you hooks to Kimi Code CLI's config.toml.
#
#   ./install-kimi-hooks.sh                  ~/.kimi-code/config.toml ($KIMI_CODE_HOME if set)
#   ./install-kimi-hooks.sh --kimi-home DIR  DIR/config.toml
#   ./install-kimi-hooks.sh --uninstall      remove them again
#
# Copies the shared needs-you-hook.sh (integrations/claude-code/) to <kimi home>/hooks/ and
# appends kimi-hooks.toml to config.toml as one block of [[hooks]] tables between two marker
# comments. Python 3.9 has no TOML parser, so the file is edited as text: only that block is
# ever added, replaced or removed, the rest of the file is kept byte for byte, and a backup
# is written before any change. Re-running is safe.
#
# The hooks do nothing until you opt in: NEEDS_YOU_AGENT_ALERTS=1, or a session started by
# Orca ($ORCA_TERMINAL_HANDLE). Kimi Code CLI only (the `kimi` command from kimi-code), not
# the archived Python kimi-cli. See README.md.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/kimi-hooks.toml"
# Next to this script when the invite installer downloaded both; else the repo layout.
HOOK_SRC="$HERE/needs-you-hook.sh"
[ -f "$HOOK_SRC" ] || HOOK_SRC="$HERE/../claude-code/needs-you-hook.sh"

DIR="${KIMI_CODE_HOME:-}"
ACTION="install"
DRY_RUN=0

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --kimi-home DIR     Kimi's home directory (default: \$KIMI_CODE_HOME, else ~/.kimi-code).
                      Kimi reads DIR/config.toml only when it runs with KIMI_CODE_HOME=DIR.
  --uninstall         Remove the needs-you block and the copied hook script
  --dry-run           Show what would change; write nothing
  -h, --help          Show this help
EOF
}

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) shift ;;  # the only scope; accepted for symmetry with install-hooks.sh
    --kimi-home) [ $# -ge 2 ] || die "--kimi-home needs a directory" 2; DIR=$2; shift 2 ;;
    --kimi-home=*) DIR=${1#*=}; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required"
if [ "$ACTION" = install ]; then
  [ -f "$HOOK_SRC" ] || die "missing needs-you-hook.sh (looked next to this script and in ../claude-code)"
  [ -f "$SNIPPET" ] || die "missing kimi-hooks.toml next to this script"
fi

# The default home keeps "$HOME" in the commands, so the block is the same on every machine
# (Kimi runs hook commands through a shell, which expands it). Another home is written out.
# shellcheck disable=SC2016
DEFAULT_PREFIX='"$HOME/.kimi-code/hooks/needs-you-hook.sh"'
if [ -z "$DIR" ] || [ "$DIR" = "$HOME/.kimi-code" ]; then
  DIR="$HOME/.kimi-code"
  PREFIX=$DEFAULT_PREFIX
else
  if [ "$ACTION" = install ] && [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$DIR" 2>/dev/null || die "can't create $DIR"
  fi
  [ -d "$DIR" ] && DIR=$(cd "$DIR" && pwd)
  case "$DIR" in *[\'\"\\\`\$]*) die "--kimi-home can't contain quotes, backslashes, \` or \$" ;; esac
  PREFIX="\"$DIR/hooks/needs-you-hook.sh\""
fi
CONF="$DIR/config.toml"
HOOKS_DIR="$DIR/hooks"
HOOK="$HOOKS_DIR/needs-you-hook.sh"

echo "config:   $CONF"
echo "hook:     $HOOK"

# Another tool's directory: never write or delete through a symlink (it could point anywhere).
for p in "$CONF" "$HOOKS_DIR" "$HOOK"; do
  if [ -L "$p" ]; then
    die "$p is a symlink; not writing through it. Nothing was changed: add kimi-hooks.toml to the file it points to by hand."
  fi
done

# ---- the config block (python3 edits the text; it prints a status line)
python3 - "$ACTION" "$CONF" "$SNIPPET" "$DEFAULT_PREFIX" "$PREFIX" "$DRY_RUN" <<'PY'
import os, re, sys, time

action, conf, snippet, default_prefix, prefix, dry_run = sys.argv[1:7]
dry_run = dry_run == "1"
START = "# needs-you (managed by install-kimi-hooks.sh"
END = "# end needs-you"


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


try:
    with open(conf, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    exists = True
except FileNotFoundError:
    text, exists = "", False
except (OSError, UnicodeDecodeError) as e:
    die("can't read %s (%s); nothing was changed" % (conf, e))

lines = text.splitlines(True)
kept, i, found = [], 0, False
while i < len(lines):
    if lines[i].startswith(START):
        j = i
        while j < len(lines) and lines[j].rstrip("\r\n") != END:
            j += 1
        if j == len(lines):
            die("%s has the start of a needs-you block but no '%s' line; fix it by hand, "
                "nothing was changed" % (conf, END))
        if kept and kept[-1].strip() == "":
            kept.pop()  # the blank line the installer put before the block
        found, i = True, j + 1
        continue
    kept.append(lines[i])
    i += 1
rest = "".join(kept)

if action == "uninstall":
    if not found:
        print("config:   no needs-you block")
        sys.exit(0)
    new = rest
else:
    # [[hooks]] tables can be appended to any TOML file, unless `hooks` is already something
    # else there: a root key (hooks = [...]) or a [hooks] / [hooks.x] table.
    root = True
    for line in rest.splitlines():
        s = line.strip()
        if s.startswith("["):
            if re.match(r"^\[\s*hooks\s*[\].]", s):
                die("%s defines [hooks] as a table; Kimi expects [[hooks]] entries. Nothing was "
                    "changed: add kimi-hooks.toml by hand." % conf)
            root = False
        elif root and re.match(r"^hooks\s*=", s):
            die("%s sets hooks = ... inline; nothing was changed: add the entries from "
                "kimi-hooks.toml to that list by hand." % conf)
    with open(snippet, "r", encoding="utf-8") as fh:
        block = fh.read().replace(default_prefix, prefix)
    if not block.endswith("\n"):
        block += "\n"
    if "needs-you-hook.sh" in rest:
        print("note:     %s has needs-you-hook.sh entries outside the needs-you block; they "
              "are left as they are" % conf)
    new = rest
    if new and not new.endswith("\n"):
        new += "\n"
    new += ("\n" if new.strip() else "") + block
    if not new.strip():
        new = block

if exists and new == text:
    print("config:   already up to date")
    sys.exit(0)
if dry_run:
    print("config:   dry run, would %s the needs-you block in %s"
          % ("remove" if action == "uninstall" else "write", conf))
    sys.exit(0)

os.makedirs(os.path.dirname(conf), exist_ok=True)
mode = 0o600
if exists:
    mode = os.stat(conf).st_mode & 0o777
    bak = "%s.bak-%s-%d" % (conf, time.strftime("%Y%m%d-%H%M%S"), os.getpid())
    fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
tmp = "%s.needs-you.%d" % (conf, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
    fh.write(new)
os.chmod(tmp, mode)
os.replace(tmp, conf)
if action == "uninstall":
    print("config:   removed the needs-you block%s" % (" (backup: config.toml.bak-*)" if exists else ""))
else:
    print("config:   %s the needs-you block%s" % ("updated" if found else "added",
                                                   " (backup: config.toml.bak-*)" if exists else ""))
PY

if [ "$ACTION" = uninstall ]; then
  if [ -f "$HOOK" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "dry run: would delete $HOOK"
    else
      rm -f "$HOOK"
      echo "deleted $HOOK"
      rmdir "$HOOKS_DIR" 2>/dev/null || true
    fi
  fi
  exit 0
fi

if [ -f "$HOOK" ] && cmp -s "$HOOK_SRC" "$HOOK"; then
  echo "hook:     already up to date"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "hook:     dry run, would write $HOOK"
else
  mkdir -p "$HOOKS_DIR"
  tmp=$(mktemp "$HOOKS_DIR/.needs-you.XXXXXX")  # a fresh name, never a planted symlink
  cat "$HOOK_SRC" >"$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$HOOK"
  echo "hook:     installed"
fi

ENV_FILE="${NEEDS_YOU_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}"
echo ""
echo "Next:"
echo "  - Check Kimi accepts the file: kimi doctor (any key Kimi doesn't know makes it refuse the config)."
if [ "$DIR" != "$HOME/.kimi-code" ] && [ "${KIMI_CODE_HOME:-}" != "$DIR" ]; then
  echo "  - Kimi reads $CONF only when it runs with KIMI_CODE_HOME=$DIR."
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
echo "  - Restart running Kimi Code sessions to pick up the change."
