#!/usr/bin/env bash
# run-or-alert.sh: run a command; if it fails, post a needs-you item; if it
# succeeds, resolve that item. For cron jobs, systemd timers and scripts.
#
#   run-or-alert.sh --key personal:hub-b:backup --title "hub-b backup failed" \
#     [--context personal] [--priority urgent] [--link "Logs=https://..."] \
#     [--agent cron:backup] [--project hub-b] -- /usr/local/bin/backup.sh --nightly
#
# Exits with the command's own exit code, so cron/systemd still see failures.
# The item body says which command failed and its exit code; it never includes
# the command's output (that's where secrets leak). Link to your logs instead.
#
# Needs the needs-you CLI (scripts/setup-sender.sh). Set NEEDS_YOU_BIN if cron
# can't find it on PATH.

set -u

key="" title="" context="" priority="normal" agent="" project=""
links=()
while [ $# -gt 0 ]; do
  case "$1" in
    --key) key=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --context) context=$2; shift 2 ;;
    --priority) priority=$2; shift 2 ;;
    --link) links+=(--link "$2"); shift 2 ;;
    --agent) agent=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "run-or-alert: unknown option $1 (did you forget --?)" >&2; exit 2 ;;
  esac
done
[ -n "$key" ] && [ $# -gt 0 ] || { echo "usage: run-or-alert.sh --key KEY --title TITLE [opts] -- command [args]" >&2; exit 2; }

# Default context follows the key prefix: personal:* -> personal, else work.
if [ -z "$context" ]; then
  case "$key" in personal:*) context=personal ;; *) context=work ;; esac
fi

host=$(hostname -s 2>/dev/null || hostname); host=${host%%.*}
[ -n "$title" ] || title="$(basename "$1") failed on $host"
[ -n "$agent" ] || agent="cron:$(basename "$1")"

cli=${NEEDS_YOU_BIN:-$(command -v needs-you 2>/dev/null || echo "$HOME/.local/bin/needs-you")}

"$@"
rc=$?

if [ -x "$cli" ]; then
  if [ "$rc" -eq 0 ]; then
    "$cli" resolve --key "$key" >/dev/null 2>&1
  else
    extra=()
    [ -n "$project" ] && extra=(--project "$project")
    "$cli" add --key "$key" --context "$context" --priority "$priority" \
      --title "$title" \
      --body "\`$(basename "$1")\` exited $rc on \`$host\` at $(date '+%Y-%m-%d %H:%M %Z')." \
      ${links[@]+"${links[@]}"} --agent "$agent" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1
  fi
else
  echo "run-or-alert: needs-you CLI not found ($cli); no alert sent" >&2
fi

exit "$rc"
