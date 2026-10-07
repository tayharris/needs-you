#!/usr/bin/env bash
# needs-you-hook.sh: Claude Code hook that mirrors "the agent is waiting on
# you" to needs-you.
#
#   needs-you-hook.sh notify    (Notification hook)  -> needs-you add, kind needs
#   needs-you-hook.sh resolve   (Stop, UserPromptSubmit, PostToolUse,
#                                SessionEnd hooks)   -> needs-you resolve
#
# Reads the hook input JSON from stdin (session_id, cwd, message,
# notification_type). Always exits 0 and never prints to stdout, so it can't
# block or steer Claude. Installed by install-hooks.sh.
#
# Off unless one of these is true (so ordinary interactive use stays quiet):
#   NEEDS_YOU_AGENT_ALERTS=1          opt in for this shell/VM
#   ORCA_TERMINAL_HANDLE is set       session started by Orca
# NEEDS_YOU_AGENT_ALERTS=0 turns it off even inside Orca.
#
# Optional settings (environment, or lines in ~/.config/needs-you/env):
#   NEEDS_YOU_AGENT_CONTEXT   work | personal       (default: NEEDS_YOU_DEFAULT_CONTEXT, else work)
#   NEEDS_YOU_AGENT_PRIORITY  urgent | normal | low (default: normal)
#   NEEDS_YOU_AGENT_LINK      "Label=url-template", placeholders {handle},
#                             {session}, {cwd}, {host}. Example:
#                             "VS Code=vscode://file{cwd}". Orca has no terminal
#                             or worktree deep link (1.4.220 opens only
#                             orca://skills/share/<id>), so Orca sessions get
#                             the worktree and an `orca terminal switch`
#                             command in the card body instead.
#   NEEDS_YOU_AGENT_EXPIRY_HOURS  cards expire after this many hours without a
#                             re-post (default 48; 0 = never), a backstop for
#                             a session that dies on a machine that never
#                             runs `needs-you flush` again
#   NEEDS_YOU_ORCA_ENVIRONMENT  on a paired Orca server: the name the Mac's
#                             Orca uses for it (`orca environment list`), so
#                             the switch command gets --environment
#   NEEDS_YOU_BIN             path to the needs-you CLI
#   NEEDS_YOU_HOOK_LOG        file to append debug lines to

# Never fail, never block.
set +e
trap 'exit 0' INT TERM HUP

mode=${1:-}

# Settings may also live in the sender env file (written by setup-sender.sh),
# e.g. NEEDS_YOU_AGENT_ALERTS=1 there opts in every session on this machine.
# The environment wins over the file.
env_file="${NEEDS_YOU_ENV_FILE:-$HOME/.config/needs-you/env}"
file_val() {
  [ -r "$env_file" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$env_file" | tail -n 1 |
    sed -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}
[ -n "${NEEDS_YOU_AGENT_ALERTS+x}" ] || NEEDS_YOU_AGENT_ALERTS=$(file_val NEEDS_YOU_AGENT_ALERTS)

# ---- gate (cheap: no python, no network, for sessions that aren't opted in)
case "${NEEDS_YOU_AGENT_ALERTS:-}" in
  0|false|no|off) exit 0 ;;
  1|true|yes|on) ;;
  *) [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || exit 0 ;;
esac

input=$(cat 2>/dev/null)

[ -n "${NEEDS_YOU_AGENT_CONTEXT:-}" ]  || NEEDS_YOU_AGENT_CONTEXT=$(file_val NEEDS_YOU_AGENT_CONTEXT)
[ -n "${NEEDS_YOU_AGENT_PRIORITY:-}" ] || NEEDS_YOU_AGENT_PRIORITY=$(file_val NEEDS_YOU_AGENT_PRIORITY)
[ -n "${NEEDS_YOU_AGENT_LINK:-}" ]     || NEEDS_YOU_AGENT_LINK=$(file_val NEEDS_YOU_AGENT_LINK)
[ -n "${NEEDS_YOU_BIN:-}" ]            || NEEDS_YOU_BIN=$(file_val NEEDS_YOU_BIN)
[ -n "${NEEDS_YOU_ORCA_ENVIRONMENT:-}" ] || NEEDS_YOU_ORCA_ENVIRONMENT=$(file_val NEEDS_YOU_ORCA_ENVIRONMENT)
[ -n "${NEEDS_YOU_AGENT_EXPIRY_HOURS:-}" ] || NEEDS_YOU_AGENT_EXPIRY_HOURS=$(file_val NEEDS_YOU_AGENT_EXPIRY_HOURS)
export NEEDS_YOU_AGENT_CONTEXT NEEDS_YOU_AGENT_PRIORITY NEEDS_YOU_AGENT_LINK NEEDS_YOU_ORCA_ENVIRONMENT
export NEEDS_YOU_AGENT_EXPIRY_HOURS

log() {
  [ -n "${NEEDS_YOU_HOOK_LOG:-}" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$NEEDS_YOU_HOOK_LOG" 2>/dev/null
}

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80; }

# session_id is a UUID; a sed grab avoids a python start-up on every event.
session_id=$(printf '%s\n' "$input" |
  sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

host=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
host=$(sanitize "${host%%.*}")
id=${ORCA_TERMINAL_HANDLE:-$session_id}
[ -n "$id" ] || { log "no session id or terminal handle; skipping"; exit 0; }
id=$(sanitize "$id")
key="agent:$host:$id"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you/claude-hooks"
marker="$state_dir/$id"

# The Claude process this hook belongs to: the first ancestor that isn't a
# shell (Claude Code may start hooks through `sh -c`). `needs-you flush`
# resolves the card once that pid is gone or reused (different start time).
agent_pid() {
  local p=$PPID n=0 comm
  while [ "$n" -lt 8 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null) || return 0
    case "${comm##*/}" in
      sh|-sh|bash|-bash|dash|zsh|-zsh|env|timeout|nohup) ;;
      *) printf '%s' "$p"; return 0 ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    n=$((n + 1))
  done
}

# Find the CLI. Hooks run with Claude Code's PATH, which may not include
# ~/.local/bin.
cli=${NEEDS_YOU_BIN:-}
if [ -z "$cli" ]; then
  if command -v needs-you >/dev/null 2>&1; then
    cli=$(command -v needs-you)
  elif [ -x "$HOME/.local/bin/needs-you" ]; then
    cli="$HOME/.local/bin/needs-you"
  fi
fi
[ -n "$cli" ] || { log "needs-you CLI not found"; exit 0; }

case "$mode" in
  resolve)
    # Only call the hub if this session actually posted something. Stop and
    # PostToolUse fire constantly; the marker keeps them local and free.
    [ -f "$marker" ] || exit 0
    rm -f "$marker"
    "$cli" resolve --key "$key" </dev/null >/dev/null 2>&1
    log "resolve $key -> $?"
    ;;

  notify)
    command -v python3 >/dev/null 2>&1 || { log "python3 not found"; exit 0; }
    # Build the item from the hook JSON and call the CLI with an argv list
    # (no shell quoting of untrusted text).
    NY_INPUT=$input NY_KEY=$key NY_HOST=$host NY_CLI=$cli NY_ID=$id \
    python3 - <<'PY' >/dev/null 2>&1
import json, os, re, shlex, subprocess
from urllib.parse import quote

try:
    data = json.loads(os.environ.get("NY_INPUT") or "{}")
except Exception:
    data = {}

ntype = str(data.get("notification_type") or "")
message = " ".join(str(data.get("message") or "").split())
cwd = str(data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
project = os.path.basename(project_dir.rstrip("/")) or "claude"
session = str(data.get("session_id") or "")
handle = os.environ.get("ORCA_TERMINAL_HANDLE", "")
# <repoId>::<path>; the path is the readable part.
worktree = os.environ.get("ORCA_WORKTREE_ID", "").split("::", 1)[-1]
host = os.environ["NY_HOST"]

what = {
    "permission_prompt": "Claude needs permission",
    "idle_prompt": "Claude is waiting for you",
    "elicitation_dialog": "Claude needs an answer",
    "elicitation_url_dialog": "Claude needs you to sign in",
    "agent_needs_input": "Agent needs input",
}.get(ntype, "Claude needs you")
title = ("%s: %s" % (what, project))[:100]

home = os.path.expanduser("~")
short_cwd = "~" + cwd[len(home):] if cwd.startswith(home) else cwd
lines = []
if message:
    lines.append(message[:400])
lines.append("`%s` on `%s`" % (short_cwd, host))
links = []
orca_env = os.environ.get("NEEDS_YOU_ORCA_ENVIRONMENT", "")
if handle:
    if worktree and worktree != cwd:
        lines.append("Orca worktree `%s`" % worktree)
    # The Mac app's Terminal button runs the same switch (it validates both values again).
    if re.match(r"^term_[0-9a-f-]{8,64}$", handle):
        url = "needsyou://orca/terminal?handle=" + handle
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", orca_env):
            url += "&environment=" + quote(orca_env, safe="")
        links.append("Terminal=" + url)
    jump = "orca terminal switch%s --terminal %s" % (
        " --environment " + shlex.quote(orca_env) if orca_env else "", shlex.quote(handle))
    lines.append("Jump to its terminal: `%s`" % jump)
elif session:
    lines.append("Session `%s`" % session[:8])
body = "\n\n".join(lines)[:2000]

# No NEEDS_YOU_AGENT_CONTEXT: the CLI uses NEEDS_YOU_DEFAULT_CONTEXT, else work.
context = os.environ.get("NEEDS_YOU_AGENT_CONTEXT") or ""
priority = os.environ.get("NEEDS_YOU_AGENT_PRIORITY") or "normal"
if priority not in ("urgent", "normal", "low"):
    priority = "normal"

args = [
    os.environ["NY_CLI"], "add",
    "--key", os.environ["NY_KEY"],
] + (["--context", context] if context in ("work", "personal") else []) + [
    "--priority", priority,
    "--title", title,
    "--body", body,
    "--agent", "claude-code",
    "--project", project,
]
try:
    expiry = float(os.environ.get("NEEDS_YOU_AGENT_EXPIRY_HOURS") or 48)
except ValueError:
    expiry = 48.0
if expiry > 0:
    args += ["--expires-in", "%g" % expiry]
tmpl = os.environ.get("NEEDS_YOU_AGENT_LINK", "")
if "=" in tmpl:
    label, url = tmpl.split("=", 1)
    needs_handle = "{handle}" in url
    url = (url.replace("{handle}", quote(handle, safe=""))
              .replace("{session}", quote(session, safe=""))
              .replace("{cwd}", quote(cwd)).replace("{host}", quote(host, safe="")))
    if label and url and not (needs_handle and not handle):
        links.append("%s=%s" % (label, url))

def post(links):
    try:
        return subprocess.run(args + [a for l in links for a in ("--link", l)],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=15).returncode
    except Exception:
        return 1

rc = post(links)
if rc == 2 and links and links[0].startswith("Terminal="):
    rc = post(links[1:])  # a hub older than the Terminal link rejects it; post without
raise SystemExit(rc)
PY
    rc=$?
    log "notify $key -> $rc"
    # The CLI queues offline and exits 0, so a down hub still leaves a marker
    # and the later resolve is queued behind the add.
    # The marker is the lease: key, Claude's pid and its start time.
    if [ "$rc" -eq 0 ] && mkdir -p "$state_dir" 2>/dev/null; then
      pid=$(agent_pid)
      start=
      [ -n "$pid" ] && start=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)
      tmp="$state_dir/.$id.$$"
      if [ -n "$start" ]; then
        printf 'key=%s\npid=%s\nstart=%s\n' "$key" "$pid" "$start" >"$tmp"
      else
        printf 'key=%s\n' "$key" >"$tmp"
      fi
      mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp"
    fi
    ;;
esac

exit 0
