#!/usr/bin/env bash
# Update needs-you on several sender machines over SSH, in parallel, and print a table.
# The fallback to the normal path (each sender's own `needs-you update`): for machines
# that are rarely online when their hub is, right after a release, or to check a fleet.
#
#   scripts/rollout.sh [--hosts FILE] [--check] [-j N] [host ...]
#
#   host ...       SSH host aliases (as in ~/.ssh/config), e.g. devbox
#   --hosts FILE   one alias per line (# comments and blank lines ignored); default
#                  ~/.config/needs-you/hosts when no hosts are given
#   --check        report what would change (needs-you update --check); change nothing
#   -j N           at most N hosts at once (default 8)
#
# Per host it runs, with `ssh -o BatchMode=yes -o ConnectTimeout=10`:
#   needs-you --json update [--check]; needs-you doctor --json
# A host without the CLI is reported as such: set it up with an invite link from the Mac
# app (this script never copies tokens). Exit 0 when every host updated (or was current)
# and its doctor found no FAIL, 1 otherwise.
set -euo pipefail

die() { printf 'rollout: %s\n' "$*" >&2; exit 2; }

HOSTS_FILE=""
CHECK=0
JOBS=8
HOSTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) [ $# -ge 2 ] || die "--hosts needs a file"; HOSTS_FILE=$2; shift 2 ;;
    --hosts=*) HOSTS_FILE=${1#*=}; shift ;;
    --check) CHECK=1; shift ;;
    -j) [ $# -ge 2 ] || die "-j needs a number"; JOBS=$2; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) die "-j must be a positive number" ;; esac

if [ ${#HOSTS[@]} -eq 0 ]; then
  [ -n "$HOSTS_FILE" ] || HOSTS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/hosts"
  [ -f "$HOSTS_FILE" ] || die "no hosts given and no $HOSTS_FILE (one SSH alias per line)"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] && HOSTS+=("$line")
  done <"$HOSTS_FILE"
fi
[ ${#HOSTS[@]} -gt 0 ] || die "no hosts"
for h in "${HOSTS[@]}"; do
  # An alias, never an option or a wildcard that ssh would read as something else.
  printf '%s' "$h" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$' || die "not a host alias: $h"
done

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

UPDATE_ARGS="update"
[ "$CHECK" -eq 1 ] && UPDATE_ARGS="update --check"
# Runs on the remote host. ~/.local/bin is where the installer puts the CLI, and a
# non-interactive SSH shell often lacks it on PATH.
# shellcheck disable=SC2016
REMOTE='PATH="$HOME/.local/bin:$PATH"; command -v needs-you >/dev/null 2>&1 || { echo NEEDS_YOU_MISSING; exit 0; }; needs-you --json '"$UPDATE_ARGS"' 2>/dev/null; echo NEEDS_YOU_SPLIT; needs-you doctor --json 2>/dev/null; exit 0'

run_host() {
  local host=$1 i=$2
  if ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "$REMOTE" >"$OUT/$i.out" 2>"$OUT/$i.err"; then
    echo ok >"$OUT/$i.status"
  else
    echo ssh >"$OUT/$i.status"
  fi
}

i=0
for h in "${HOSTS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.2; done
  run_host "$h" "$i" &
  i=$((i + 1))
done
wait

python3 - "$OUT" "$CHECK" "${HOSTS[@]}" <<'PY'
import json, os, sys
out, check, hosts = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
rows, bad = [], 0
for i, host in enumerate(hosts):
    def read(ext):
        try:
            with open(os.path.join(out, "%d.%s" % (i, ext)), encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except OSError:
            return ""
    status, text = read("status").strip(), read("out")
    cli = hook = skill = "-"
    doctor = "-"
    if status != "ok":
        err = (read("err").strip().splitlines() or ["ssh failed"])[-1]
        result = "unreachable: " + err[:60]
        bad += 1
    elif "NEEDS_YOU_MISSING" in text:
        result = "no needs-you CLI (set it up with an invite link)"
        bad += 1
    else:
        up_text, _, doc_text = text.partition("NEEDS_YOU_SPLIT")
        try:
            up = json.loads(up_text.strip().splitlines()[-1])
        except (ValueError, IndexError):
            up = {}
        try:
            doc = json.loads(doc_text.strip())
        except ValueError:
            doc = {}
        if not up:
            result = "update gave no answer (CLI older than 0.1.2? run needs-you self-update)"
            bad += 1
        elif not up.get("ok"):
            result = "failed: " + "; ".join(up.get("errors") or ["?"])[:70]
            bad += 1
        elif check:
            ch = [c["file"] for c in up.get("changes") or []]
            result = ("would update " + ", ".join(ch)) if ch else "up to date"
        else:
            ap = up.get("applied") or []
            result = ("updated " + ", ".join(ap)) if ap else "up to date"
        cli = doc.get("version") or up.get("cli") or "-"
        for c in doc.get("checks") or []:
            if c.get("check") == "update":
                d = c.get("detail", "")
                for part in d.split(";"):
                    part = part.strip()
                    if part.startswith("hook "):
                        hook = part[5:]
                    elif part.startswith("skill "):
                        skill = part[6:]
        if doc:
            doctor = "ok" if doc.get("ok") else "FAIL"
            if not doc.get("ok"):
                bad += 1
    rows.append((host, cli, hook, skill, doctor, result))
head = ("host", "cli", "hook", "skill", "doctor", "result")
widths = [max(len(str(r[k])) for r in rows + [head]) for k in range(5)]
for r in [head] + rows:
    print("  ".join(str(r[k]).ljust(widths[k]) for k in range(5)) + "  " + r[5])
print("%d host%s, %d with problems" % (len(rows), "" if len(rows) == 1 else "s", bad))
sys.exit(1 if bad else 0)
PY
