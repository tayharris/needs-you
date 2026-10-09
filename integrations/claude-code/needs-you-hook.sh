#!/usr/bin/env bash
# needs-you-version: 0.2.1
# needs-you-hook.sh: Claude Code hook that mirrors "the agent is waiting on
# you" to needs-you.
#
#   needs-you-hook.sh notify    Notification, PermissionRequest, StopFailure
#                               -> needs-you add (kind needs)
#   needs-you-hook.sh resolve   UserPromptSubmit, PostToolUse -> needs-you resolve
#   needs-you-hook.sh stop      Stop: resolve, then the context-usage check
#   needs-you-hook.sh start     SessionStart: after /clear, compact or /resume,
#                               resolve this process's earlier cards
#   needs-you-hook.sh end       SessionEnd: resolve the session's cards
#   needs-you-hook.sh ask       PermissionRequest for AskUserQuestion (a synchronous entry):
#                               the question card; when the card can answer it, wait for the
#                               click and print Claude's decision (ADR 0009 B3; off with
#                               NEEDS_YOU_ANSWER_TIMEOUT=0)
#
# A second argument names the agent. Default: claude.
#   codex    OpenAI Codex CLI (integrations/codex/, ~/.codex/hooks.json):
#            PermissionRequest, PreToolUse for request_user_input (a question) and
#            Stop (the turn ended) call `notify`.
#   gemini   Gemini CLI (integrations/gemini/, ~/.gemini/settings.json):
#            Notification (ToolPermission), BeforeTool for ask_user (a question) and
#            AfterAgent call `notify`. Gemini waits for every hook, so the hook reads
#            its input and finishes the work in the background.
#   opencode opencode, through integrations/opencode/needs-you.js (a plugin that
#            starts this hook with a small JSON object): PermissionRequest,
#            Question and Stop (the session went idle) call `notify`.
#   copilot  GitHub Copilot CLI (integrations/copilot/, ~/.copilot/hooks/):
#            notification (permission_prompt, elicitation_dialog) and agentStop
#            call `notify`. Its payload names the session `sessionId`. Copilot
#            waits for most hooks, so like gemini the work runs in the background.
#   grok     Grok Build (integrations/grok/, ~/.grok/hooks/needs-you.json):
#            Notification permission_prompt / idle_prompt (sent as
#            notificationType) and StopFailure call `notify`; Stop posts nothing
#            (idle_prompt is the "waiting for you" card). Grok also runs the Claude
#            Code hooks from ~/.claude/settings.json (on by default), so $GROK_HOOK_EVENT
#            makes any call a grok one, and one card per wait: when needs-you's own
#            Grok hooks file is installed, the Claude hooks do nothing in Grok;
#            without it they post as Grok (their Stop resolves, with no context
#            check: Grok's transcript isn't Claude's). Subagent sessions post
#            nothing. Grok waits for its hooks, so the work goes to a background copy.
#   kimi     Kimi Code CLI (integrations/kimi/, [[hooks]] in ~/.kimi-code/config.toml):
#            PermissionRequest, PreToolUse for AskUserQuestion, Stop (the turn
#            ended) and StopFailure call `notify`. Kimi awaits most hooks and kills
#            a hook's process group when it runs past its timeout, so the work goes
#            to a background copy in a session of its own.
#   cursor   Cursor (integrations/cursor/, ~/.cursor/hooks.json): stop (status
#            completed or error) calls `notify`, beforeSubmitPrompt `resolve`,
#            sessionEnd `end`. The session is conversation_id. Cursor reads a hook's
#            stdout as its answer: this prints {"continue":true} in resolve mode (only
#            beforeSubmitPrompt runs it) and {} otherwise, then works in the background.
#            Cursor also runs the Claude Code hooks; given a Cursor payload they exit.
#   cline    Cline (integrations/cline/, executables in ~/Documents/Cline/Hooks/, which
#            pass the event name as a third argument): TaskComplete and TaskError call
#            `notify`, UserPromptSubmit and TaskCancel `resolve`, TaskStart and
#            TaskResume `start` (clears the cards of earlier tasks in the same Cline),
#            SessionShutdown `end`. The session is taskId. Background work, as Cline
#            in VS Code waits for its hooks.
#   aider    Aider's --notifications-command: one `notify` each time Aider waits for
#            the person after an LLM reply. No payload, and stdin is the terminal, so
#            it is never read. The session is the Aider process; the card goes when
#            Aider exits (the lease) or expires (NEEDS_YOU_AIDER_EXPIRY_HOURS, default 1).
#
# Reads the hook input JSON from stdin. The card says where the session runs:
# the tmux pane (session:window.pane), the terminal app, VS Code or Cursor (with the
# workspace Claude Code is connected to), or SSH, and links to it where
# it can (VS Code folder, Remote-SSH window, the VS Code Claude tab, the Orca
# terminal, the Mac terminal tab: below). Always exits 0 and never prints to stdout, so it can't block or
# steer Claude, with one exception: `ask` prints the answer the person clicked on the card, as
# Claude's decision for that question. Installed by install-hooks.sh.
#
# Off unless one of these is true (so ordinary interactive use stays quiet):
#   NEEDS_YOU_AGENT_ALERTS=1          opt in for this shell/VM
#   ORCA_TERMINAL_HANDLE is set       session started by Orca
# NEEDS_YOU_AGENT_ALERTS=0 turns it off even inside Orca.
#
# Optional settings (environment, or lines in the sender env file: the same
# file the CLI reads, $NEEDS_YOU_CONFIG or $XDG_CONFIG_HOME/needs-you/env,
# by default ~/.config/needs-you/env; NEEDS_YOU_ENV_FILE overrides it here):
#   NEEDS_YOU_AGENT_CONTEXT   work | personal       (default: NEEDS_YOU_DEFAULT_CONTEXT, else work)
#   NEEDS_YOU_AGENT_PRIORITY  urgent | normal | low (default: normal)
#   NEEDS_YOU_AGENT_LINK      "Label=url-template", placeholders {handle},
#                             {session}, {cwd}, {host}. Example:
#                             "VS Code=vscode://file{cwd}". Unset: the hook
#                             picks editor links itself (below). "none": no
#                             editor links. Orca has no terminal or worktree
#                             deep link (1.4.220 opens only
#                             orca://skills/share/<id>), so Orca sessions get
#                             a needsyou://orca/terminal link and an
#                             `orca terminal switch` command in the body.
#   LC_NEEDS_YOU_TERM         on an SSH host: which Mac terminal tab holds the
#                             connection, as the link's query (for example
#                             "app=iterm&session=<UUID>"), set in the Mac's
#                             shell and carried by ssh's default SendEnv LC_*.
#                             On the Mac itself the hook reads TERM_PROGRAM,
#                             TMUX_PANE, WEZTERM_PANE, ITERM_SESSION_ID or the
#                             tty instead. Either way the card gets a Terminal
#                             link, needsyou://terminal/focus?app=...
#                             (not alongside the Orca one: Orca wins)
#   NEEDS_YOU_SSH_ALIAS       the name the Mac's ~/.ssh/config (or VS Code
#                             Remote-SSH) uses for this host; on a host other
#                             than the Mac it adds a Remote-SSH folder link
#   NEEDS_YOU_AGENT_EXPIRY_HOURS  cards expire after this many hours without a
#                             re-post (default 48; 0 = never), a backstop for
#                             a session that dies on a machine that never
#                             runs `needs-you flush` again
#   NEEDS_YOU_CONTEXT_ALERT_PCT  post a low-priority card suggesting /compact
#                             or /clear once the session's context is this
#                             full, in percent (default 80; 0 = off)
#   NEEDS_YOU_CONTEXT_WINDOW  the context window in tokens (default 200000,
#                             or 1000000 for a [1m] model)
#   NEEDS_YOU_ORCA_ENVIRONMENT  on a paired Orca server: the name the Mac's
#                             Orca uses for it (`orca environment list`), so
#                             the switch command gets --environment
#   NEEDS_YOU_AGENT_TURN_CARDS  Codex, Gemini, opencode, Copilot, Grok, Kimi: 0 = no card when a turn ends,
#                             just approval prompts (default: on)
#   NEEDS_YOU_TURN_TEXT       0 = a finished turn's card is the old "<Agent> is waiting for
#                             you: <project>", with no session name in any title (default: "<Agent>
#                             finished: <session name> (<project>)", or "<Agent> asks: <question>"
#                             when the turn's last message ends on a question; agent text is
#                             redacted, cleaned and clamped)
#   NEEDS_YOU_AGENT_QUESTIONS  0 = a question card says only "<Agent> asked you a
#                             question" and a plan card shows no plan text (default:
#                             the question, its choices as steps and the plan's first
#                             lines, cleaned, token-shaped text redacted, clamped)
#   NEEDS_YOU_USAGE_ALERT_PCT, NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT, NEEDS_YOU_USAGE_ACCOUNT
#                             Codex: on Stop, a low `info` card once its 5-hour or weekly
#                             limit is this full (the same settings and card as
#                             needs-you-usage for Claude), read from the newest
#                             token_count rate_limits in the session file. Off unless set
#   NEEDS_YOU_BIN             path to the needs-you CLI
#   NEEDS_YOU_HOOK_LOG        file to append debug lines to

# Never fail, never block.
set +e
trap 'exit 0' INT TERM HUP

mode=${1:-}
case "${2:-}" in
  codex) agent=codex ;;
  gemini) agent=gemini ;;
  opencode) agent=opencode ;;
  grok) agent=grok ;;
  copilot) agent=copilot ;;
  cursor) agent=cursor ;;
  cline) agent=cline ;;
  aider) agent=aider ;;
  kimi) agent=kimi ;;
  *) agent=claude ;;
esac
# Grok Build runs the Claude hooks as they are: it names itself only in the environment.
# One card per wait: with needs-you's own Grok hooks installed, those handle Grok, and the
# Claude hooks (any other argument) step aside.
if [ -n "${GROK_HOOK_EVENT:-}" ]; then
  [ "${2:-}" != grok ] && [ -f "${GROK_HOME:-$HOME/.grok}/hooks/needs-you.json" ] && exit 0
  agent=grok
fi
# Cline's hook files name their event in a third argument (kept for the background copy).
[ "$agent" = cline ] && { NY_EVENT=${NY_EVENT:-${3:-}}; export NY_EVENT; }

# Cursor reads every hook's stdout as its answer, and a beforeSubmitPrompt answer says whether
# the prompt goes on. Answer first, before anything below can exit: "continue" in resolve mode
# (only beforeSubmitPrompt runs it), an empty answer otherwise. Never a decision hook.
if [ "$agent" = cursor ] && [ -z "${NY_HOOK_BG:-}" ]; then
  if [ "$mode" = resolve ]; then printf '{"continue":true}\n'; else printf '{}\n'; fi
fi

# Settings may also live in the sender env file (written by setup-sender.sh),
# e.g. NEEDS_YOU_AGENT_ALERTS=1 there opts in every session on this machine.
# The environment wins over the file. Found the way the CLI finds it
# (NEEDS_YOU_CONFIG, else $XDG_CONFIG_HOME/needs-you/env, else ~/.config/...),
# so `--alerts` on a machine with XDG_CONFIG_HOME set isn't silently ignored.
env_file="${NEEDS_YOU_ENV_FILE:-${NEEDS_YOU_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/needs-you/env}}"
file_val() {  # as the CLI reads it: spaces around "=", the value trimmed (a CRLF file too)
  [ -r "$env_file" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=[[:space:]]*//p" "$env_file" |
    tail -n 1 | sed -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'\$/\1/" -e 's/^"\(.*\)"$/\1/'
}
[ -n "${NEEDS_YOU_AGENT_ALERTS+x}" ] || NEEDS_YOU_AGENT_ALERTS=$(file_val NEEDS_YOU_AGENT_ALERTS)

# ---- gate (cheap: no python, no network, for sessions that aren't opted in)
case "${NEEDS_YOU_AGENT_ALERTS:-}" in
  0|false|no|off) exit 0 ;;
  1|true|yes|on) ;;
  *) [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || exit 0 ;;
esac

# Aider gives its notifications command no input, and its stdin is the terminal: reading it
# would swallow what the person types. Its session is the Aider process: the first ancestor
# that isn't a shell (Aider runs the command through `sh -c`), found now, while that shell is
# still there, and handed to the background copy as the lease's starting point.
if [ "$agent" = aider ]; then
  input=
  p=${NY_HOOK_PPID:-$PPID}
  n=0
  while [ "$n" -lt 8 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null) || { p=; break; }
    case "${comm##*/}" in
      sh|-sh|bash|-bash|dash|zsh|-zsh|env|timeout|nohup) p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') ;;
      *) break ;;
    esac
    n=$((n + 1))
  done
  if [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; then
    input="{\"session_id\":\"aider-$p\"}"
    NY_HOOK_PPID=$p
  else
    exit 0
  fi
elif { : 3<&0; } 2>/dev/null; then  # (not `<&0`: bash takes 0<&0 as a no-op)
  input=$(cat 2>/dev/null)
else
  # stdin closed: $(cat) would get its own pipe's read end as fd 0 and wait on itself forever.
  input=
fi

# A plain string field at the top level of the hook JSON (ids and fixed words). A flat
# payload (one object) is read with a sed grab, which avoids a python start-up on every
# event. One with nested objects (tool_input, an MCP tool's arguments) can carry the same
# key inside: python reads the top-level fields once, so a nested session_id never becomes
# the session.
top_fields=
top_read=0
json_str() {
  case "$input" in
    *'{'*'{'*)
      if [ "$top_read" = 0 ]; then
        top_read=1
        top_fields=$(printf '%s' "$input" | python3 -c 'import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
for k, v in (d.items() if isinstance(d, dict) else ()):
    if isinstance(v, str) and re.match(r"^[A-Za-z0-9_]+$", k):
        print("%s=%s" % (k, re.sub(r"[\x00-\x1f\x7f]", " ", v)))' 2>/dev/null)
      fi
      printf '%s\n' "$top_fields" | sed -n "s/^$1=//p" | head -n 1 ;;
    *)
      printf '%s\n' "$input" |
        sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1 ;;
  esac
}

# Cursor runs the Claude Code hooks from ~/.claude/settings.json as well (Stop,
# UserPromptSubmit, SessionStart, SessionEnd). Its payloads carry cursor_version and
# conversation_id, which Claude Code's never do. The cursor hooks handle Cursor; here a Stop
# would clear the card they just posted (same conversation id), so step aside.
if [ "$agent" = claude ] && [ -n "$(json_str cursor_version)$(json_str conversation_id)" ]; then
  exit 0
fi

# A Grok subagent's session is the parent session's work: its waits show up there.
if [ "$agent" = grok ] && [ -n "$(json_str subagentType)" ]; then
  exit 0
fi

# Gemini CLI, Copilot CLI, Grok and Kimi wait for each hook (and Gemini and Copilot read its
# stdout as JSON): hand the work to a background copy with no stdio and return at once.
# The copy starts the lease search from this hook's parent. Grok and Kimi start a hook as
# `sh -c '<command>'` in a process group of its own, which is gone by the time the copy
# looks, so name the shell's parent (the agent) instead; and they kill that whole group when
# a hook runs past its timeout, so the copy starts a session of its own (setsid; macOS has
# no setsid binary, perl does it there).
if { [ "$agent" = gemini ] || [ "$agent" = copilot ] || [ "$agent" = grok ] || [ "$agent" = kimi ] ||
     [ "$agent" = cursor ] || [ "$agent" = cline ] || [ "$agent" = aider ]; } &&
   [ -z "${NY_HOOK_BG:-}" ]; then
  parent=${NY_HOOK_PPID:-$PPID}
  if [ -z "${NY_HOOK_PPID:-}" ]; then
    pcomm=$(ps -o comm= -p "$parent" 2>/dev/null)
    case "${pcomm##*/}" in
      sh|-sh|bash|-bash|dash|zsh|-zsh) parent=$(ps -o ppid= -p "$parent" 2>/dev/null | tr -d ' ') ;;
    esac
  fi
  if command -v setsid >/dev/null 2>&1; then
    detach=(setsid)
  elif command -v perl >/dev/null 2>&1; then
    detach=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV')
  else
    detach=()
  fi
  printf '%s' "$input" | NY_HOOK_BG=1 NY_HOOK_PPID=${parent:-$PPID} "${detach[@]}" bash "$0" "$mode" "$agent" \
    >/dev/null 2>&1 &
  exit 0
fi

for var in NEEDS_YOU_AGENT_CONTEXT NEEDS_YOU_AGENT_PRIORITY NEEDS_YOU_AGENT_LINK NEEDS_YOU_BIN \
           NEEDS_YOU_ORCA_ENVIRONMENT NEEDS_YOU_AGENT_EXPIRY_HOURS NEEDS_YOU_SSH_ALIAS \
           NEEDS_YOU_CONTEXT_ALERT_PCT NEEDS_YOU_CONTEXT_WINDOW NEEDS_YOU_AGENT_TURN_CARDS \
           NEEDS_YOU_AIDER_EXPIRY_HOURS NEEDS_YOU_AGENT_QUESTIONS NEEDS_YOU_ANSWER_TIMEOUT \
           NEEDS_YOU_USAGE_ALERT_PCT NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT NEEDS_YOU_USAGE_ACCOUNT \
           NEEDS_YOU_TURN_TEXT; do
  if [ -z "${!var:-}" ]; then
    val=$(file_val "$var")
    printf -v "$var" '%s' "$val"
  fi
  export "${var?}"
done

log() {
  [ -n "${NEEDS_YOU_HOOK_LOG:-}" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$NEEDS_YOU_HOOK_LOG" 2>/dev/null
}

# A name for a file (markers, the card key): never "." or "..", so a leading dot becomes _.
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80 | sed 's/^\./_/'; }

session_id=$(json_str session_id)
[ -n "$session_id" ] || session_id=$(json_str sessionId)  # Copilot CLI
[ -n "$session_id" ] || session_id=$(json_str conversation_id)  # Cursor
[ -n "$session_id" ] || session_id=$(json_str taskId)  # Cline
# A Cline subagent's run isn't one the person waits on.
[ "$agent" = cline ] && [ -n "$(json_str parent_agent_id)" ] && exit 0

host=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
host=$(sanitize "${host%%.*}")
id=${ORCA_TERMINAL_HANDLE:-$session_id}
[ -n "$id" ] || { log "no session id or terminal handle; skipping"; exit 0; }
id=$(sanitize "$id")
key="agent:$host:$id"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you/claude-hooks"
marker="$state_dir/$id"
ctx_marker="$state_dir/$id.context"
# Open `needs` items the agent itself posted from this session (`needs-you add` records them
# here, `needs-you resolve` removes them; one file per key: key=, expires=<epoch>). The
# session is named as here: the Orca handle, else the agent's session id, which Claude Code,
# Codex and (through the plugin) opencode also give the agent's commands. Gemini CLI doesn't,
# so the CLI notes its items under pid-<the Gemini process> with start=, matched to the lease.
items_base="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you/session-items"
items_dir="$items_base/$id"

# items_open DIR [START]: an unexpired record in DIR (with START: only one for that process).
items_open() {
  [ -d "$1" ] || return 1
  local f exp now st
  now=$(date +%s)
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    exp=$(sed -n 's/^expires=//p' "$f" 2>/dev/null | head -n 1)
    case "$exp" in ''|*[!0-9]*) continue ;; esac
    [ "$exp" -gt "$now" ] || continue
    if [ -n "${2:-}" ]; then
      st=$(sed -n 's/^start=//p' "$f" 2>/dev/null | head -n 1)
      [ "$st" = "$2" ] || continue
    fi
    return 0
  done
  return 1
}

# The lease's start time with runs of blanks squeezed, as the CLI records it.
lease_start_norm() {
  local IFS=' '
  set -f
  # shellcheck disable=SC2086
  set -- $lease_start
  set +f
  printf '%s' "$*"
}

# own_item_open: true while the agent's own blocker for this session is open and unexpired.
# Read-only; the CLI prunes expired records.
own_item_open() {
  case "$id" in .|..) ;; *) items_open "$items_dir" && return 0 ;; esac
  # Gemini: the items of the agent process this hook belongs to (ps only when there are any).
  set -- "$items_base"/pid-*
  [ -e "$1" ] || return 1
  lease
  [ -n "$lease_pid" ] || return 1
  items_open "$items_base/pid-$lease_pid" "$(lease_start_norm)"
}

# The Claude process this hook belongs to: the first ancestor that isn't a
# shell (Claude Code may start hooks through `sh -c`). `needs-you flush`
# resolves the card once that pid is gone or reused (different start time).
agent_pid() {
  local p=${NY_HOOK_PPID:-$PPID} n=0 comm
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
lease_pid=
lease_start=
lease_start_utc=
lease() {  # fills lease_pid, lease_start and lease_start_utc once
  [ -z "$lease_pid" ] || return 0
  lease_pid=$(agent_pid)
  [ -n "$lease_pid" ] && lease_start=$(LC_ALL=C ps -o lstart= -p "$lease_pid" 2>/dev/null)
  # ps prints local time, and `needs-you flush` may run in another TZ (cron's): start_utc
  # is what it compares (start= stays for older CLIs and this hook's own matching).
  [ -n "$lease_start" ] && lease_start_utc=$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$lease_pid" 2>/dev/null)
  [ -n "$lease_start" ] || lease_pid=
}

# write_marker FILE KEY [EXTRA LINE]: the marker is the lease: key, Claude's
# pid and its start time (plus what posted it).
write_marker() {
  mkdir -p "$state_dir" 2>/dev/null || return 0
  lease
  local tmp="$state_dir/.${1##*/}.$$"
  {
    printf 'key=%s\n' "$2"
    [ -n "$lease_start" ] && printf 'pid=%s\nstart=%s\n' "$lease_pid" "$lease_start"
    [ -n "$lease_start_utc" ] && printf 'start_utc=%s\n' "$lease_start_utc"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
  } >"$tmp" 2>/dev/null
  mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp"
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

# resolve_marker FILE [FALLBACK KEY]: resolve the card a marker stands for.
# No marker, no network call: Stop and PostToolUse fire constantly.
resolve_marker() {
  [ -f "$1" ] || return 0
  local k
  k=$(sed -n 's/^key=//p' "$1" 2>/dev/null | head -n 1)
  [ -n "$k" ] || k=${2:-}
  rm -f "$1"
  [ -n "$k" ] || return 0
  if [ "${resolve_bg:-}" = 1 ]; then
    ( "$cli" resolve --key "$k" ) </dev/null >/dev/null 2>&1 &
    log "resolve $k (background)"
    return 0
  fi
  "$cli" resolve --key "$k" </dev/null >/dev/null 2>&1
  log "resolve $k -> $?"
}

# A card being posted. The marker is written once the post is done, so a reply in the terminal
# while the CLI is still posting (a slow or hanging hub, the 2 s wait before a turn-end card)
# would find no marker, and the card would arrive after the reply and stay. So `notify` and
# `ask` leave $state_dir/.pending.<id>.<pid> while they post, every resolve removes them, and a
# post that finds its own gone resolves the card it just made.
pending=
begin_post() {
  mkdir -p "$state_dir" 2>/dev/null || return 0
  pending="$state_dir/.pending.$id.$$"
  printf 'event=%s\n' "$(json_str hook_event_name)" >"$pending" 2>/dev/null || { pending=; return 0; }
  trap '[ -n "$pending" ] && rm -f "$pending"' EXIT
}
# cancel_posts [stop]: the person answered. A Stop keeps a StopFailure card being posted (it
# stays until the next prompt).
cancel_posts() {
  local f
  for f in "$state_dir/.pending.$id".*; do
    [ -f "$f" ] || continue
    [ "${1:-}" = stop ] && grep -qs '^event=StopFailure$' "$f" && continue
    rm -f "$f"
  done
}
# end_post: after the marker is written. A resolve that came while posting found no marker:
# resolve the card now. (A resolve after the marker write finds the marker itself.)
end_post() {
  [ -n "$pending" ] || return 1
  if [ ! -e "$pending" ]; then
    pending=
    log "$mode $key: answered while the card was posting"
    resolve_marker "$marker" "$key"
    return 0
  fi
  rm -f "$pending"
  pending=
  return 1
}

# How long to wait for an answer from the card, in seconds: NEEDS_YOU_ANSWER_TIMEOUT (default
# 600), within 30..3600 (the python side gives the question the same expiry).
answer_timeout() {
  local t=${NEEDS_YOU_ANSWER_TIMEOUT:-600}
  case "$t" in ''|*[!0-9]*) t=600 ;; esac
  [ "$t" -lt 30 ] && t=30
  [ "$t" -gt 3600 ] && t=3600
  printf '%s' "$t"
}

# The card builder and the context check share one python program (below). The program comes
# on stdin; the hook input goes on fd 3 as a here-string, not in the environment, where one
# variable is capped at about 128 KB (a big plan would post no card). Bash backs a here-string
# with a pipe or a temp file it unlinks at once, so nothing is left behind if the hook is killed.
run_py() {
  command -v python3 >/dev/null 2>&1 || { log "python3 not found"; return 1; }
  lease
  NY_MODE=$1 NY_KEY=$key NY_HOST=$host NY_CLI=$cli NY_ID=$id \
  NY_MARKER=$marker NY_CTX_MARKER=$ctx_marker NY_STATE=$state_dir \
  NY_PID=$lease_pid NY_START=$lease_start NY_START_UTC=$lease_start_utc NY_AGENT=$agent \
  python3 - 2>/dev/null 3<<<"$input" <<'PY'
import hashlib, json, os, re, shlex, subprocess, sys, time
from urllib.parse import parse_qsl, quote

mode = os.environ.get("NY_MODE", "")
AGENTS = ("codex", "gemini", "opencode", "copilot", "grok", "kimi", "cursor", "cline", "aider")
AGENT = os.environ.get("NY_AGENT") if os.environ.get("NY_AGENT") in AGENTS else "claude"
AGENT_ID = {"codex": "codex", "gemini": "gemini-cli", "opencode": "opencode",
            "copilot": "copilot-cli", "grok": "grok", "kimi": "kimi-code", "cursor": "cursor", "cline": "cline",
            "aider": "aider"}.get(AGENT, "claude-code")
try:
    with os.fdopen(3, "rb") as _fh:
        # Bytes that aren't UTF-8 become U+FFFD: the hub refuses unpaired surrogates.
        data = json.loads(_fh.read(16 * 1024 * 1024).decode("utf-8", "replace").strip() or "{}")
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
if not isinstance(data.get("session_id"), str) and isinstance(data.get("sessionId"), str):
    data["session_id"] = data["sessionId"]  # Copilot CLI's camelCase payloads
if not isinstance(data.get("cwd"), str):
    # Cursor and Cline name the project only as their workspace roots (a Cursor user hook
    # runs in ~/.cursor, so its cwd is no help).
    _roots = data.get("workspace_roots") or data.get("workspaceRoots")
    if isinstance(_roots, list) and _roots and isinstance(_roots[0], str):
        data["cwd"] = _roots[0]


def field(name):
    v = data.get(name)
    return v if isinstance(v, str) else ""


event = field("hook_event_name")
ntype = field("notification_type") or field("notificationType")  # Grok: camelCase only
cwd = field("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
# Text the hub refuses (control and bidi characters, a source field over 100 characters)
# would lose the card: a folder name can hold anything.
_UNPRINTABLE_RE = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")
project = _UNPRINTABLE_RE.sub("", os.path.basename(project_dir.rstrip("/")))[:100].strip() or "claude"
session = field("session_id")
handle = os.environ.get("ORCA_TERMINAL_HANDLE", "")
# <repoId>::<path>; the path is the readable part.
worktree = os.environ.get("ORCA_WORKTREE_ID", "").split("::", 1)[-1]
host = os.environ["NY_HOST"]
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$")


def read_marker(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                k, sep, v = line.rstrip("\n").partition("=")
                if sep:
                    out[k] = v
    except (OSError, UnicodeDecodeError):
        pass
    return out


# TERM_PROGRAM values -> the terminal's name (a value not here shows as itself when it looks
# like a name). Inside tmux TERM_PROGRAM is "tmux": the outer terminal is a best guess.
TERM_NAMES = {"iTerm.app": "iTerm", "Apple_Terminal": "Terminal", "ghostty": "Ghostty",
              "WezTerm": "WezTerm", "WarpTerminal": "Warp", "Hyper": "Hyper", "Tabby": "Tabby",
              "zed": "Zed", "rio": "Rio", "kitty": "kitty", "alacritty": "Alacritty",
              "Alacritty": "Alacritty", "Jetbrains.Fleet": "Fleet", "JetBrains-JediTerm": "JetBrains"}
TERM_APP_NAMES = {"iterm": "iTerm", "terminal": "Terminal", "wezterm": "WezTerm", "ghostty": "Ghostty"}


def terminal_name():
    """The terminal app the session runs in ("" if unknown), from the environment only."""
    env = os.environ
    tp = env.get("TERM_PROGRAM", "")
    if tp in ("vscode", "tmux", "screen"):
        tp = ""
    if tp in TERM_NAMES:
        return TERM_NAMES[tp]
    if env.get("KITTY_WINDOW_ID"):
        return "kitty"
    if env.get("ALACRITTY_WINDOW_ID") or env.get("ALACRITTY_SOCKET"):
        return "Alacritty"
    host = tmux_host()  # iTerm, WezTerm, Ghostty, Terminal from their own variables
    if host:
        return TERM_APP_NAMES[host]
    if env.get("SSH_CONNECTION"):
        # ssh forwards LC_*: the Mac's tab, as needs-you's own LC_NEEDS_YOU_TERM names it
        m = re.match(r"^app=([a-z]{1,16})(?:&|$)", env.get("LC_NEEDS_YOU_TERM", ""))
        if m and m.group(1) in TERM_APP_NAMES:
            return TERM_APP_NAMES[m.group(1)]
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]{0,23}", tp):
        return tp[:-4] if tp.endswith(".app") else tp
    return ""


IDE_NAMES = (("cursor", "Cursor"), ("windsurf", "Windsurf"), ("vscodium", "VSCodium"),
             ("visual studio code", "VS Code"), ("vscode", "VS Code"), ("vs code", "VS Code"))


def ide_workspace():
    """(IDE name, workspace folder name) of the editor Claude Code is connected to, else ("", "").
    The VS Code extension gives its terminals and its panel CLAUDE_CODE_SSE_PORT, and the editor
    writes <config dir>/ide/<port>.lock (Claude Code 2.1.294 reads workspaceFolders and ideName
    from it). Only those two are read; the file's auth token is never touched."""
    port = os.environ.get("CLAUDE_CODE_SSE_PORT", "")
    if AGENT != "claude" or not re.fullmatch(r"[0-9]{1,5}", port):
        return "", ""
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    try:
        with open(os.path.join(base, "ide", port + ".lock"), encoding="utf-8") as fh:
            d = json.loads(fh.read(256 * 1024))
    except Exception:
        return "", ""
    if not isinstance(d, dict):
        return "", ""
    raw = d.get("ideName") if isinstance(d.get("ideName"), str) else ""
    ide = next((label for k, label in IDE_NAMES if k in raw.lower()), "")
    folders = d.get("workspaceFolders") if isinstance(d.get("workspaceFolders"), list) else []
    ws = ""
    if folders and isinstance(folders[0], str):
        ws = _clean_name(re.split(r"[/\\]", folders[0].rstrip("/\\"))[-1], 40).replace("`", "'")
    return ide, ws


def where_lines():
    """Where the session runs, so a card from a tmux pane on a VM says which one."""
    home = os.path.expanduser("~")
    short_cwd = "~" + cwd[len(home):] if cwd.startswith(home + "/") or cwd == home else cwd
    short_cwd = _UNPRINTABLE_RE.sub("", short_cwd.replace("\t", " "))
    lines, where = [], []
    pane = os.environ.get("TMUX_PANE", "")
    tmux_target = ""
    if os.environ.get("TMUX") and re.match(r"^%[0-9]+$", pane):
        try:
            tmux_target = subprocess.run(
                ["tmux", "display-message", "-p", "-t", pane, "#S:#I.#P"], stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=2).stdout.strip()[:80]
        except Exception:
            tmux_target = ""
        if tmux_target:
            where.append("tmux `%s`" % tmux_target)
    ide, workspace = ide_workspace()
    term = terminal_name()
    if AGENT == "cursor":
        where.append("Cursor")
    elif (os.environ.get("TERM_PROGRAM") == "vscode" or os.environ.get("VSCODE_IPC_HOOK_CLI")
            or os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-vscode"):
        ide = ide or ("Cursor" if os.environ.get("CURSOR_TRACE_ID") else "VS Code")
        where.append("%s `%s`" % (ide, workspace) if workspace else ide)
    elif term and tmux_target:
        where[-1] += " in " + term
    elif os.environ.get("SSH_CONNECTION") and not tmux_target:
        where.append("SSH" + (" from " + term if term else ""))
    elif term:
        where.append(term)
    lines.append("`%s` on `%s`%s" % (short_cwd, host, ", " + ", ".join(where) if where else ""))
    orca_env = os.environ.get("NEEDS_YOU_ORCA_ENVIRONMENT", "")
    if handle:
        if worktree and worktree != cwd:
            lines.append("Orca worktree `%s`" % worktree)
        jump = "orca terminal switch%s --terminal %s" % (
            " --environment " + shlex.quote(orca_env) if orca_env else "", shlex.quote(handle))
        lines.append("Jump to its terminal: `%s`" % jump)
    elif AGENT == "aider" and session.startswith("aider-"):
        lines.append("Aider process `%s`" % session[6:])
    elif session:
        lines.append("Session `%s`" % session[:8])
    return lines


# ---------------------------------------------------------------- terminal link
# needsyou://terminal/focus?app=<app>&<id> (docs/API.md). The same rules as the Mac
# app's TerminalJump: exactly these parameters, each value matching its pattern. Values
# are ids only (a pane number, a session UUID, a tty), never anything secret.
TERM_PARAMS = {"wezterm": ("pane",), "tmux": ("pane", "target", "host"),
               "iterm": ("session", "tty"), "terminal": ("tty",), "ghostty": ()}
TERM_VALUE = {
    "pane": r"[0-9]{1,6}",
    "target": r"[A-Za-z0-9_][A-Za-z0-9_-]{0,63}:[0-9]{1,4}\.[0-9]{1,4}",
    "session": r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
    "tty": r"/dev/ttys[0-9]{1,4}",
    "host": r"iterm|terminal|wezterm|ghostty",
}


def terminal_url(params):
    """The link for a dict of parameters, or "" if they aren't exactly a valid set."""
    app = params.get("app", "")
    allowed = TERM_PARAMS.get(app)
    if allowed is None or set(params) - {"app"} - set(allowed):
        return ""
    ids = [k for k in allowed if k != "host" and k in params]
    if len(ids) != (0 if app == "ghostty" else 1):
        return ""
    for k in ids + (["host"] if "host" in params else []):
        if not re.fullmatch(TERM_VALUE[k], params[k] or "", re.ASCII):
            return ""
    query = ["app=" + app] + ["%s=%s" % (k, params[k]) for k in ids]
    if "host" in params:
        query.append("host=" + params["host"])
    return "needsyou://terminal/focus?" + "&".join(query)


def claude_tty():
    t = os.environ.get("NEEDS_YOU_HOOK_TTY")  # tests
    if t is None and os.environ.get("NY_PID"):
        try:
            t = subprocess.run(["ps", "-o", "tty=", "-p", os.environ["NY_PID"]], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            t = ""
    t = t or ""
    return t if t.startswith("/dev/") else "/dev/" + t if t else ""


def tmux_host():
    """The terminal the local tmux runs in, from what its server inherited (best effort)."""
    env = os.environ
    if env.get("ITERM_SESSION_ID") or env.get("LC_TERMINAL") == "iTerm2":
        return "iterm"
    if env.get("WEZTERM_PANE") or env.get("WEZTERM_EXECUTABLE"):
        return "wezterm"
    if env.get("GHOSTTY_RESOURCES_DIR") or env.get("TERM_PROGRAM") == "ghostty":
        return "ghostty"
    if env.get("TERM_PROGRAM") == "Apple_Terminal":
        return "terminal"
    return ""


def terminal_link():
    """The Mac terminal tab this session runs in, or ""."""
    env = os.environ
    platform = env.get("NEEDS_YOU_HOOK_PLATFORM") or sys.platform
    if env.get("SSH_CONNECTION") or platform != "darwin":
        # Remote: only the Mac can name its tab (LC_NEEDS_YOU_TERM, forwarded by ssh).
        raw = env.get("LC_NEEDS_YOU_TERM", "")
        if not raw or len(raw) > 300:
            return ""
        try:
            pairs = parse_qsl(raw, keep_blank_values=True, strict_parsing=True)
        except ValueError:
            return ""
        params = dict(pairs)
        return terminal_url(params) if len(params) == len(pairs) else ""
    term = env.get("TERM_PROGRAM", "")
    if term == "vscode" or env.get("CLAUDE_CODE_ENTRYPOINT") == "claude-vscode":
        return ""  # the VS Code links cover it
    pane = env.get("TMUX_PANE", "")
    if env.get("TMUX") and re.fullmatch(r"%[0-9]{1,6}", pane):
        params = {"app": "tmux", "pane": pane[1:]}
        host = tmux_host()
        if host:
            params["host"] = host
        return terminal_url(params)
    if re.fullmatch(r"[0-9]{1,6}", env.get("WEZTERM_PANE", "")):
        return terminal_url({"app": "wezterm", "pane": env["WEZTERM_PANE"]})
    iterm = env.get("ITERM_SESSION_ID", "")
    if iterm:
        return terminal_url({"app": "iterm", "session": iterm.split(":", 1)[-1]})
    if term == "Apple_Terminal":
        return terminal_url({"app": "terminal", "tty": claude_tty()})
    if term == "ghostty":
        return terminal_url({"app": "ghostty"})
    return ""


def make_links():
    links = []
    orca_env = os.environ.get("NEEDS_YOU_ORCA_ENVIRONMENT", "")
    # The Mac app's Terminal button runs the Orca switch (it validates both values again).
    if handle and re.match(r"^term_[0-9a-f-]{8,64}$", handle):
        url = "needsyou://orca/terminal?handle=" + handle
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", orca_env):
            url += "&environment=" + quote(orca_env, safe="")
        links.append("Terminal=" + url)
    elif not handle:
        # Otherwise the Mac terminal tab (the app validates it again before it runs anything).
        term = terminal_link()
        if term:
            links.append("Terminal=" + term)
    tmpl = os.environ.get("NEEDS_YOU_AGENT_LINK", "").strip()
    if tmpl.lower() == "none":
        return links
    if "=" in tmpl:
        label, url = tmpl.split("=", 1)
        needs_handle = "{handle}" in url
        url = (url.replace("{handle}", quote(handle, safe=""))
                  .replace("{session}", quote(session, safe=""))
                  .replace("{cwd}", quote(cwd)).replace("{host}", quote(host, safe="")))
        if label and url and not (needs_handle and not handle):
            links.append("%s=%s" % (label, url))
        return links
    # No template: the deepest editor links this machine can name.
    # The VS Code extension's own tab (URI handler from the Claude Code VS Code docs).
    if (AGENT == "claude" and os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-vscode"
            and re.match(r"^[A-Za-z0-9-]{8,64}$", session)):
        links.append("Claude=vscode://anthropic.claude-code/open?session=" + session)
    if not cwd.startswith("/"):
        return links
    platform = os.environ.get("NEEDS_YOU_HOOK_PLATFORM") or sys.platform
    alias = os.environ.get("NEEDS_YOU_SSH_ALIAS", "")
    editor, scheme = ("Cursor", "cursor") if AGENT == "cursor" else ("VS Code", "vscode")
    if platform == "darwin" and not os.environ.get("SSH_CONNECTION"):
        links.append("%s=%s://file%s" % (editor, scheme, quote(cwd)))  # this is the Mac: the path exists there
    elif SAFE_NAME.match(alias):
        links.append("%s=%s://vscode-remote/ssh-remote+%s%s" % (editor, scheme, alias, quote(cwd)))
    return links


def base_args(key, title, body, priority):
    context = os.environ.get("NEEDS_YOU_AGENT_CONTEXT") or ""
    args = [os.environ["NY_CLI"], "add", "--key", key]
    if context in ("work", "personal"):  # else the CLI's NEEDS_YOU_DEFAULT_CONTEXT, else work
        args += ["--context", context]
    # --opt=value: a title, body or project starting with "-" isn't taken for an option
    args += ["--priority", priority, "--title=" + title[:100], "--body=" + body[:2000],
             "--agent", AGENT_ID, "--project=" + project]
    # Aider has no "the person answered" event: its card lasts an hour unless re-posted.
    name, default = (("NEEDS_YOU_AIDER_EXPIRY_HOURS", 1.0) if AGENT == "aider"
                     else ("NEEDS_YOU_AGENT_EXPIRY_HOURS", 48.0))
    try:
        expiry = float(os.environ.get(name) or default)
    except ValueError:
        expiry = default
    if expiry > 0:
        args += ["--expires-in", "%g" % expiry]
    return args


QUESTION_POSTED = [None]  # the `question` field the last post carried (None: the steps form)

# The variables by which the CLI tells it runs inside an agent's session (its agent_session),
# and notes a `needs` item it posts as that agent's own blocker. The hook's card isn't one:
# noted, it would hold back the next waiting card (own_item_open) whenever it is closed other
# than by this hook's resolve (from the Mac, by expiry). Claude Code gives its hooks
# CLAUDECODE and CLAUDE_CODE_SESSION_ID.
SESSION_VARS = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_SESSION_ID", "CODEX_THREAD_ID",
                "NEEDS_YOU_AGENT_SESSION", "GEMINI_CLI", "ORCA_TERMINAL_HANDLE")


def cli_env():
    env = {k: v for k, v in os.environ.items() if k not in SESSION_VARS}
    if env.get("TERM") == "dumb":  # Kimi's commands (the CLI takes it for one)
        del env["TERM"]
    return env


def post(args, links, steps=None, asked=None, steps_body=None):
    """Post the card. With `asked` (a question card): with its `question` field, and if the
    CLI or hub refuses that (an older one), again with the choices as steps and `steps_body`."""
    if asked is not None and asked.question:
        rc = post(args + ["--question-json=" + json.dumps(asked.question, ensure_ascii=False)], links)
        if rc != 2:
            QUESTION_POSTED[0] = asked.question if rc == 0 else None
            return rc
        args = [("--body=" + (steps_body or "")[:MAX_BODY]) if a.startswith("--body=") else a for a in args]
        steps = asked.steps
    elif asked is not None:
        steps = asked.steps
    if steps:
        args = args + ["--steps-json=" + json.dumps(steps[:MAX_STEPS], ensure_ascii=False)]

    def run(ls):
        try:
            return subprocess.run(args + [a for l in ls for a in ("--link", l)],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=15, env=cli_env()).returncode
        except Exception:
            return 1
    rc = run(links)
    # A hub older than one of the app's needsyou:// actions rejects the item (400, exit 2);
    # post again without them so the card still arrives.
    plain = [l for l in links if not l.partition("=")[2].lower().startswith("needsyou://")]
    if rc == 2 and len(plain) < len(links):
        rc = run(plain)
    # Still refused: likely a link outside the hub's allowed shapes (a custom
    # NEEDS_YOU_AGENT_LINK such as an extension's vscode:// handler, docs/API.md "Links").
    # The card matters more than its buttons, so post it once more without links.
    if rc == 2 and plain:
        rc = run([])
    # A CLI or hub that refuses the steps: the question is in the body, post without them.
    if rc == 2 and steps:
        return post([a for a in args if not a.startswith("--steps-json=")], links)
    return rc


def agent_priority():
    p = os.environ.get("NEEDS_YOU_AGENT_PRIORITY") or "normal"
    return p if p in ("urgent", "normal", "low") else "normal"


# ---------------------------------------------------------------- tool summaries
# tool_input can hold secrets (a curl header, a file's content), so a card names
# the tool plus at most a program name or a file's basename, never the input.
WRAPPERS = ("sudo", "env", "command", "time", "nohup", "exec", "nice", "timeout", "xargs")


def command_word(cmd):
    if not isinstance(cmd, str):
        return ""
    first = cmd.strip().split("\n", 1)[0][:500]
    try:
        words = shlex.split(first)
    except ValueError:
        words = first.split()
    for w in words[:12]:
        if "=" in w or w.startswith("-") or w in WRAPPERS or w.isdigit():
            continue
        w = os.path.basename(w)
        return w if re.match(r"^[A-Za-z][A-Za-z0-9._+-]{0,31}$", w) else ""
    return ""


def file_name(path):
    if not isinstance(path, str):
        return ""
    name = os.path.basename(path.rstrip("/"))
    return name if re.match(r"^[A-Za-z0-9._+-]{1,64}$", name) and name not in (".", "..") else ""


def tool_label(tool):
    m = re.match(r"^mcp__([A-Za-z0-9_-]{1,40})__([A-Za-z0-9_-]{1,40})$", tool)
    if m:
        return "%s %s" % (m.group(1), m.group(2))
    return tool if re.match(r"^[A-Za-z][A-Za-z0-9_.-]{0,39}$", tool) else "a tool"


# ---------------------------------------------------------------- questions
# A question the agent asks goes on the card (ADR 0009, phase A): the question in the title and
# body, each choice as a read-only step. Text from the agent can quote code or env, so it is
# cleaned (no control or bidi characters), anything token-shaped is redacted, then clamped.
# NEEDS_YOU_AGENT_QUESTIONS=0 keeps the old cards ("<Agent> asked you a question", no text).
MAX_TITLE, MAX_BODY, MAX_STEPS, MAX_STEP = 100, 2000, 10, 200  # the hub's limits
QUESTION_BUDGET = 1200  # of the body, for the question text: the "where" lines follow it
# The hub's limits for the `question` field (docs/API.md)
MAX_QUESTIONS, MAX_OPTIONS = 4, 8
MAX_QUESTION_HEADER, MAX_QUESTION_TEXT, MAX_OPTION_LABEL = 30, 500, 80
_BAD_CHARS = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f­؜᠎​-‏ -‮"
                        "⁠-⁩﻿]")
# --- needs-you redaction (begin) ---
# Token-shaped text in anything untrusted that reaches a card becomes "[redacted]". The same
# block, byte for byte, is in integrations/claude-code/needs-you-hook.sh, cli/needs-you,
# integrations/mcp/needs_you_mcp.py and integrations/github/needs-you-github
# (tests/test_redaction.py checks). Best effort: a secret that looks like a word isn't caught.
# Every pattern runs in linear time on any input (tests/test_redaction.py times them): each one
# starts on a literal and never backtracks over a run it has to give back.
REDACTED = "[redacted]"
# A %XX escape before a key (x%3Dghp_..., %22ghp_...) counts as a word's start.
_SECRET_RAW = re.compile(r"(?:\b|(?<=%[0-9A-Fa-f]{2}))"
                         r"(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_\w{16,}|sk-[A-Za-z0-9_-]{16,}"
                         r"|xox[abpr]-[\w-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16}|ny[ip]?_[A-Za-z0-9_-]{8,}"
                         r"|glpat-[\w-]{16,}|AIza[\w-]{30,}|[sr]k_(?:live|test)_\w{16,}|npm_\w{30,}"
                         r"|hf_\w{30,}|glptt-[\w-]{16,}|xapp-[\w-]{10,}|ya29\.[\w-]{20,})")
# A webhook URL whose path is its secret: the host and the path's start stay.
_WEBHOOK = re.compile(r"(hooks\.slack\.com/(?:services|workflows|triggers)/"
                      r"|discord(?:app)?\.com/api/(?:v\d+/)?webhooks/)[\w/-]+")
# A JWT: the whole run is taken greedily, then checked (a failed match never rescans the run).
_JWT_RUN = re.compile(r"\beyJ[\w.-]+")
_JWT = re.compile(r"eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]*")
# A name ending in a secret's keyword, then its value (`:`, `=`, `=>`, or URL-encoded %3A/%3D).
# Only the keyword is matched, never the name's prefix (PGPASSWORD, X_API_KEY, client_secret).
# Keywords other than "password" start a word or follow _ or - (DB_PASS, not bypass).
_SECRET_KV = re.compile(r"(?i)(password|(?<![a-z0-9])(?:passwd|pwd|pw|pass(?:phrase)?|token|secret"
                        r"|(?:api|access|secret|private)[_-]?key|auth|credentials?|sig(?:nature)?))"
                        r"([\"']?\s*(?:=>|[:=]|%3[ad])\s*)(\"[^\"]*\"|'[^']*'|\S+)")
# A command line's --password VALUE (with a space): _flag() checks the keyword ends a --flag.
_SECRET_FLAG = re.compile(r"(?i)(?<=-)(password|passwd|token|secret|api-key)([ \t]+)(?!-)(\S+)")
_SECRET_AUTH = re.compile(r"(?i)\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+/=-]{8,}")
_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?"
                  r"(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\Z)", re.S)
_LONG_HEX = re.compile(r"\b[0-9A-Fa-f]{32,}\b")
_LONG_RUN = re.compile(r"[A-Za-z0-9+/_=-]{40,}")
_SPACES = re.compile(r"(\s+)")


def _long_run(m):
    s = m.group(0)
    # base64-ish: digits and both cases, few separators (not a path or a branch name)
    if (len(re.findall(r"[-_/]", s)) <= 3 and re.search(r"[0-9]", s) and re.search(r"[a-z]", s)
            and re.search(r"[A-Z]", s)):
        return REDACTED
    return s


def _jwt(m):
    j = _JWT.match(m.group(0))
    return REDACTED + m.group(0)[j.end():] if j else m.group(0)


def _flag(m):
    i = m.start()
    while i > 0 and (m.string[i - 1].isalnum() or m.string[i - 1] in "-_"):
        i -= 1
    if m.string.startswith("--", i):
        return m.group(1) + m.group(2) + REDACTED
    return m.group(0)


def _url_creds(word):
    """scheme://user:<password>@host in one whitespace-free word: the password runs to the last
    "@" before the query, so one holding "/" or "@" goes whole (a path's "@" may go with it)."""
    parts = word.split("://")
    for i in range(1, len(parts)):
        seg = parts[i]
        end = len(seg)
        for c in "?#":
            k = seg.find(c)
            if 0 <= k < end:
                end = k
        at = seg.rfind("@", 0, end)
        colon = seg.find(":", 0, at)
        if at > 0 and 0 <= colon < at - 1 and "/" not in seg[:colon]:
            parts[i] = seg[:colon + 1] + REDACTED + seg[at:]
    return "://".join(parts)


def redact(text):
    text = _PEM.sub(REDACTED, text)
    if "://" in text:
        text = "".join(_url_creds(w) if "://" in w else w for w in _SPACES.split(text))
    text = _WEBHOOK.sub(lambda m: m.group(1) + REDACTED, text)
    text = _SECRET_RAW.sub(REDACTED, text)
    text = _JWT_RUN.sub(_jwt, text)
    text = _SECRET_KV.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)
    text = _SECRET_FLAG.sub(_flag, text)
    text = _SECRET_AUTH.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)
    text = _LONG_HEX.sub(REDACTED, text)
    return _LONG_RUN.sub(_long_run, text)
# --- needs-you redaction (end) ---


def clamp(text, limit):
    return text if len(text) <= limit else text[:max(0, limit - 1)].rstrip() + "…"


def one_line(value, limit):
    """Agent text for a title or a step: one line, cleaned, redacted, clamped."""
    if not isinstance(value, str):
        return ""
    return clamp(" ".join(redact(_BAD_CHARS.sub(" ", value)).split()), limit)


# [label](url) and ![alt](url): agent text is data (prompt injection can write it), so a link in
# it shows its URL instead of a label over it.
_MD_LINK = re.compile(r"!?\[([^\[\]\n]*)\]\(\s*<?([^()\s<>]*)>?(?:\s+\"[^\"]*\")?\s*\)")


def text_block(value, limit, max_lines=8):
    """Agent text for the body: up to max_lines non-blank lines, cleaned, redacted, clamped.
    Markdown headings become bold lines, code fences go (the card renders inline markdown
    only) and links show their URL."""
    if not isinstance(value, str):
        return ""
    lines, more = [], False
    for raw in redact(value.replace("\r\n", "\n").replace("\t", "    ")).split("\n"):
        line = _MD_LINK.sub(lambda m: "%s (%s)" % (m.group(1), m.group(2)) if m.group(1) else m.group(2),
                            " ".join(_BAD_CHARS.sub(" ", raw).split()))
        if not line or re.match(r"^(```|~~~)", line):
            continue
        if len(lines) == max_lines:
            more = True
            break
        h = re.match(r"^#{1,6}\s+(.+)$", line)
        lines.append("**%s**" % h.group(1).strip("*# ") if h else line.replace("```", "'''"))
    out = "\n".join(lines)
    if more and len(out) < limit:
        out += "\n…"
    return clamp(out, limit)


def questions_from(raw):
    """[(header, question, [(label, description)], multi)] from a list of question objects
    (Claude/Kimi AskUserQuestion, opencode's question.asked): unknown shapes are skipped."""
    out = []
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list):
        return out
    for q in raw[:20]:
        if isinstance(q, str):
            q = {"question": q}
        if not isinstance(q, dict):
            continue
        text = next((q[k] for k in ("question", "text", "prompt", "message") if isinstance(q.get(k), str)), "")
        header = q.get("header") if isinstance(q.get("header"), str) else ""
        opts = []
        raw_opts = q.get("options") if isinstance(q.get("options"), list) else []
        for o in raw_opts[:50]:
            if isinstance(o, str):
                o = {"label": o}
            if not isinstance(o, dict):
                continue
            label = next((o[k] for k in ("label", "value", "title") if isinstance(o.get(k), str)), "")
            desc = o.get("description") if isinstance(o.get("description"), str) else ""
            if label.strip():
                opts.append((label, desc))
        if not opts and q.get("type") == "yesno":  # Gemini's yes/no question
            opts = [("Yes", ""), ("No", "")]
        multi = any(q.get(k) is True for k in ("multiSelect", "multi_select", "multiple"))
        if text.strip() or opts:
            out.append((header, text, opts, multi))
    return out


def questions_on():
    return (os.environ.get("NEEDS_YOU_AGENT_QUESTIONS") or "").lower() not in ("0", "false", "no", "off")


def share(counts, budget):
    """How many options of each question fit in `budget` steps, dealt one at a time in turn."""
    taken = [0] * len(counts)
    while budget > 0 and any(t < c for t, c in zip(taken, counts)):
        for i, c in enumerate(counts):
            if budget > 0 and taken[i] < c:
                taken[i] += 1
                budget -= 1
    return taken


class Asked(object):
    """A question card's structured part: the item's `question` field (docs/API.md), and for a
    CLI or hub that refuses it, the choices as steps with the body that goes with them."""

    def __init__(self, question, steps, steps_msg):
        self.question, self.steps, self.steps_msg = question, steps, steps_msg


def answer_timeout():
    """NEEDS_YOU_ANSWER_TIMEOUT: how long a sender waits for an answer from the card (s)."""
    try:
        t = int(os.environ.get("NEEDS_YOU_ANSWER_TIMEOUT") or 600)
    except ValueError:
        t = 600
    return min(max(t, 30), 3600)


def answerable_as_is(questions, field):
    """Only a question the card can show whole may be answered from it: every question kept,
    each with 1-8 options, and every label exactly as the agent wrote it (not cut, cleaned or
    redacted), so the labels the person clicks are the agent's own."""
    if not field or len(field["items"]) != len(questions):
        return False
    for (header, text, opts, _), item in zip(questions, field["items"]):
        if not opts or len(opts) != len(item["options"]):
            return False
        if any(label != o["label"] for (label, _), o in zip(opts, item["options"])):
            return False
        # Two choices with one label: the answer (labels only) can't say which was clicked.
        if len(set(label for label, _ in opts)) != len(opts):
            return False
        # The question, its header and each choice's description reach the card whole too
        # (only cleaned): never answered from a card that showed part of what was asked.
        if not (shown_whole(text, MAX_QUESTION_TEXT, True) and shown_whole(header, MAX_QUESTION_HEADER)
                and all(shown_whole(desc, MAX_STEP) for _, desc in opts)):
            return False
    return True


def shown_whole(value, limit, block=False):
    """Is agent text shown on the card as written: nothing redacted, cut or left out?"""
    if not isinstance(value, str) or not value.strip():
        return True
    if redact(value) != value:
        return False
    if block:
        # The card drops fence lines and renders inline markdown, where a link shows only its
        # text: either would show the person something other than what the agent asked.
        if re.search(r"(?m)^\s*(```|~~~)", value) or "](" in value:
            return False
        return text_block(value, limit) == text_block(value, 1 << 30, 1 << 30)
    return one_line(value, limit) == one_line(value, 1 << 30)


def question_field(questions, qid="", answerable=False):
    """The `question` field for `questions` (the hub's limits: 4 questions, 8 options), or None.
    With `answerable` (the opencode plugin waits for an answer): marked answerable, with its
    expiry, when the question fits whole (answerable_as_is)."""
    items = []
    for header, text, opts, multi in questions:
        t = text_block(text, MAX_QUESTION_TEXT) or one_line(header, MAX_QUESTION_TEXT)
        if not t or len(items) == MAX_QUESTIONS:
            continue
        item = {"text": t, "multi_select": bool(multi), "options": []}
        h = one_line(header, MAX_QUESTION_HEADER)
        if h:
            item["header"] = h
        for label, desc in opts:
            lb = one_line(label, MAX_OPTION_LABEL)
            if lb and len(item["options"]) < MAX_OPTIONS:
                item["options"].append({"label": lb, "description": one_line(desc, MAX_STEP)})
        items.append(item)
    if not items:
        return None
    out = {"items": items}
    if one_line(qid, 200):
        out["id"] = one_line(qid, 200)
    if answerable and answerable_as_is(questions, out):
        out["answerable"] = True
        out["expires_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + answer_timeout()))
    return out


def question_card(name, questions, qid="", answerable=False):
    """(what, msg, Asked) for a card about `questions`, or None. `name` is the agent
    ("Claude"). The body lists each question's choices (for clients that don't show the
    `question` field); the steps form is only for a CLI or hub that refuses the field."""
    if not questions:
        return None
    multi_q = len(questions) > 1
    first = next((one_line(t, 300) for _, t, _, _ in questions if one_line(t, 300)), "")
    if not first:
        first = one_line(questions[0][0], 80)
    if not first:
        return None
    more = " and %d more" % (len(questions) - 1) if multi_q else ""
    room = MAX_TITLE - len('%s asks ""%s: ' % (name, more)) - min(len(place_label()), 30)
    what = "%s asks “%s”%s" % (name, clamp(first, max(20, room)), more)
    per_q = max(150, QUESTION_BUDGET // len(questions))
    parts = []
    for i, (header, text, opts, multi) in enumerate(questions[:8]):
        h = one_line(header, 60)
        pick = ("choose any" if multi else "choose one") if opts else ""
        label = h or ("Question %d" % (i + 1) if multi_q else "")
        head = " · ".join(x for x in ("**%s**" % label if label else "", pick) if x)
        parts.append("\n".join(x for x in (head, text_block(text, per_q)) if x))
    if len(questions) > 8:
        parts.append("+%d more questions" % (len(questions) - 8))
    tail = "Answer in %s." % name
    steps_msg = clamp("\n\n".join([p for p in parts if p] + [
        "Answer in %s; the choices below are what it offered." % name if any(q[2] for q in questions) else tail]),
        QUESTION_BUDGET + 200)
    # The body with each question's choices listed under it, as far as the budget goes.
    room = max(120, (QUESTION_BUDGET + 200) // min(len(questions), 8)) - 10
    listed = []
    for part, (_, _, opts, _) in zip(parts, questions[:8]):
        lines = [part] if part else []
        size = len(part)
        for n, (label, desc) in enumerate(opts):
            d = one_line(desc, 120)
            line = clamp("- " + one_line(label, MAX_OPTION_LABEL) + (" \u2014 " + d if d else ""), 160)
            if size + len(line) + 1 > room:
                lines.append("- +%d more" % (len(opts) - n))
                break
            lines.append(line)
            size += len(line) + 1
        listed.append("\n".join(lines))
    listed += parts[len(listed):]  # "+N more questions"
    msg = clamp("\n\n".join([p for p in listed if p] + [tail]), QUESTION_BUDGET + 400)
    field_ = question_field(questions, qid, answerable)
    if field_ and field_.get("answerable"):
        msg = clamp(msg[:-len(tail)] + "Pick here or answer in %s." % name, QUESTION_BUDGET + 400) \
            if msg.endswith(tail) else msg
    return what, msg, Asked(field_, choice_steps(name, questions), steps_msg)


def choice_steps(name, questions):
    """Each question's options as read-only steps ("Label — description"), prefixed with the
    question's header when there are several, dealt in turn when they don't all fit."""
    counts = [len(q[2]) for q in questions]
    total = sum(counts)
    taken = share(counts, total if total <= MAX_STEPS else MAX_STEPS - 1)
    steps = []
    for (header, _, opts, _), n in zip(questions, taken):
        prefix = (one_line(header, 40) + ": ") if len(questions) > 1 and one_line(header, 40) else ""
        for label, desc in opts[:n]:
            text = prefix + one_line(label, 120)
            d = one_line(desc, MAX_STEP)
            if d:
                text += " — " + d
            steps.append({"text": clamp(text, MAX_STEP)})
    if total > len(steps):
        steps.append({"text": "+%d more choices in %s" % (total - len(steps), name)})
    return steps


def plan_card(name, plan):
    """(what, msg) for a plan waiting for approval: its first lines, cleaned and redacted."""
    what = "%s wants approval for a plan" % name
    lines = text_block(plan, 900, max_lines=12) if questions_on() else ""
    tail = "Approve or reject it in %s." % name
    return what, ("%s\n\n%s" % (lines, tail)) if lines else "%s has a plan ready. %s" % (name, tail)


# ---------------------------------------------------------------- finished turns and names
# A turn that ended is a "finished" card, unless the agent's final message ends on a question
# to the person: then an "asks" card with that question. The title also names the session
# (Claude Code's /rename name or auto title, a Codex thread name, Kimi's and opencode's
# session titles). All of it is agent text: redacted as a whole first, then cut, cleaned and
# clamped. NEEDS_YOU_TURN_TEXT=0 keeps the old "<Agent> is waiting for you: <project>" cards.
TITLE = [None]  # a card's whole title, when it isn't "<what>: <where>"
_NAME = []  # session_name(), worked out once


def turn_text_on():
    return (os.environ.get("NEEDS_YOU_TURN_TEXT") or "").lower() not in ("0", "false", "no", "off")


def _redacted_tail(text, limit=200000):
    """The end of `text`, redacted. A cut at the front drops the partial word there, so a
    token cut in two can't slip past the patterns."""
    text = text.replace("\r\n", "\n")
    if len(text) > limit:
        text = text[-limit:]
        text = text.split(None, 1)[1] if len(text.split(None, 1)) == 2 else ""
    return redact(text)


def turn_question(text):
    """(question, paragraph) when a turn's final message ends on a question to the person, else
    ("", ""). Conservative: only the message's last line counts, it must end with "?" (closing
    quotes or markdown aside), and a message that ends in code or a table is never a question.
    The question is the last sentence or sentences of that line that end it: from the end of the
    last sentence that doesn't end in "?"."""
    if not isinstance(text, str) or "?" not in text[-2000:]:
        return "", ""
    # A line's closing "?" is kept out of the redaction (`token=x?` would take it along).
    end_q = r"(\?+)(?=[\"'”’)\]*_` \t]*$)"
    text = re.sub(r"(\S)" + end_q, "\\1 \x00\\2", text[-250000:], flags=re.M)
    text = _redacted_tail(text).replace(" \x00", "").replace("\x00", "")
    paras = [p for p in re.split(r"\n[ \t]*\n", text) if p.strip()]
    if not paras:
        return "", ""
    para = paras[-1]
    lines = [l for l in para.split("\n") if l.strip()]
    last = lines[-1]
    if (re.match(r"^\s*(```|~~~|\|)", last) or re.match(r"^( {4}|\t)", last)
            or any(re.match(r"^\s*(```|~~~)", l) for l in lines)):
        return "", ""
    line = re.sub(r"^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d{1,3}[.)]\s+)+", "", last).strip()
    core = line.rstrip("\"'”’)]*_` ")
    if not core.endswith("?"):
        return "", ""
    # From after the last ". " or "! " (a statement before the question).
    m = None
    for m in re.finditer(r"[.!](?:[\"'”’)\]*_`]*)\s+", core):
        pass
    q = core[m.end():] if m else core
    q = re.sub(r"(\*\*|__)", "", q).strip()
    if len(q) < 3 or not re.search(r"[A-Za-z0-9]", q):
        return "", ""
    return q, para


def _clean_name(value, limit=60):
    """A session name for a title: one line, cleaned, clamped; none if it holds anything
    token-shaped (a name with a secret in it isn't worth showing in part)."""
    if not isinstance(value, str):
        return ""
    name = " ".join(_BAD_CHARS.sub(" ", value).split())
    if not name or redact(name) != name:
        return ""
    return clamp(name, limit)


def claude_last_text(path):
    """The text of the turn's final assistant message in a Claude Code transcript (what the
    terminal shows last), or "": a main-thread assistant entry's text blocks. Anything else
    first (a tool call, a prompt, an interruption, a synthetic or error message) means none."""
    if not path or not os.path.isfile(path):
        return ""
    for size in (256 * 1024, 2 * 1024 * 1024):
        try:
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                end = fh.tell()
                start = max(0, end - size)
                fh.seek(start)
                buf = fh.read(end - start)
        except OSError:
            return ""
        lines = buf.split(b"\n")
        if start > 0:
            lines = lines[1:]
        for raw in reversed(lines):
            if b'"assistant"' not in raw and b'"user"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except Exception:
                continue
            if not isinstance(d, dict) or d.get("isSidechain") or d.get("type") not in ("assistant", "user"):
                continue
            m = d.get("message") if isinstance(d.get("message"), dict) else {}
            if d["type"] == "user":
                if d.get("isMeta"):
                    continue
                return ""  # a prompt, a tool result or an interruption came after the last text
            if m.get("model") == "<synthetic>" or d.get("isApiErrorMessage"):
                return ""
            content = m.get("content")
            if isinstance(content, str):
                return content
            if not isinstance(content, list):
                return ""
            texts = [c.get("text") for c in content if isinstance(c, dict) and c.get("type") == "text"
                     and isinstance(c.get("text"), str)]
            return "\n\n".join(texts)
        if start == 0:
            break
    return ""


TITLE_SCAN_MAX = 64 * 1024 * 1024  # bytes of transcript read for titles on one card, at most


def title_cache_path():
    sid = re.sub(r"^\.", "_", re.sub(r"[^A-Za-z0-9._-]", "_", session)[:80])  # as the shell's sanitize
    return os.path.join(os.environ["NY_STATE"], ".title-" + sid) if sid else ""


def read_title_cache():
    path = title_cache_path()
    try:
        with open(path, encoding="utf-8") as fh:
            c = json.loads(fh.read(64 * 1024))
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def write_title_cache(c):
    path = title_cache_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        # private: the names are the session's own words, as in the transcript
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600),
                       "w", encoding="utf-8") as fh:
            json.dump(c, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def prompt_title():
    """UserPromptSubmit (the `title` mode): remember the session_title Claude Code sends with a
    prompt (live on 2.1.294 after /rename), for the session's later cards."""
    if AGENT != "claude" or not field("session_title"):
        return 0
    c = read_title_cache()
    if c.get("prompt") != field("session_title")[:500]:
        c["prompt"] = field("session_title")[:500]
        write_title_cache(c)
    return 0


def claude_title(path):
    """The session's name: the latest /rename name (a custom-title transcript line, live on
    2.1.294), else the session_title of the latest prompt, else the latest auto title (ai-title).
    The titles can be anywhere in the transcript, so what was found is kept in the state dir
    (.title-<session>) with the byte offset read up to: a card reads only what Claude appended
    since, and the whole file at most once (up to 64 MB)."""
    c = read_title_cache()
    custom, auto = c.get("custom"), c.get("auto")
    if path and os.path.isfile(path):
        try:
            size = os.path.getsize(path)
            offset = c.get("offset") if c.get("path") == path else None
            with open(path, "rb") as fh:
                # The file's first 4 KB tell the same transcript from one rewritten in its place.
                head = hashlib.sha1(fh.read(4096)).hexdigest()
                if (not isinstance(offset, int) or offset < 0 or offset > size
                        or (offset > 0 and c.get("head") != head)):
                    offset, custom, auto = 0, None, None  # a new or rewritten transcript: from the top
                buf = b""
                if offset < size:
                    fh.seek(offset)
                    buf = fh.read(min(size - offset, TITLE_SCAN_MAX))
            if buf:
                done = buf.rfind(b"\n") + 1  # complete lines only; a line being written waits
                for raw in buf[:done].split(b"\n"):
                    if b'-title"' not in raw[:40]:
                        continue
                    try:
                        d = json.loads(raw)
                    except Exception:
                        continue
                    if not isinstance(d, dict):
                        continue
                    if d.get("type") == "custom-title" and isinstance(d.get("customTitle"), str):
                        custom = d["customTitle"][:500]
                    elif d.get("type") == "ai-title" and isinstance(d.get("aiTitle"), str):
                        auto = d["aiTitle"][:500]
                if len(buf) == TITLE_SCAN_MAX and done == 0:
                    done = len(buf)  # one huge line: skip it rather than read it again
                c.update(path=path, offset=offset + done, head=head, custom=custom, auto=auto)
                write_title_cache(c)
        except OSError:
            pass
    for name in (custom, c.get("prompt"), auto):
        if isinstance(name, str) and name.strip():
            return name.strip()
    return ""


def codex_title():
    """A Codex thread's name (/rename): the newest line for this session in
    $CODEX_HOME/session_index.jsonl ({"id", "thread_name", "updated_at"}; codex 0.161 source)."""
    if not session:
        return ""
    path = os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "session_index.jsonl")
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            end = fh.tell()
            fh.seek(max(0, end - 1024 * 1024))
            lines = fh.read().split(b"\n")
    except OSError:
        return ""
    for raw in reversed(lines):
        if session.encode("utf-8", "replace") not in raw:
            continue
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("id") == session and isinstance(d.get("thread_name"), str):
            return d["thread_name"]
    return ""


def session_name():
    """The session's name, cleaned (or ""): the payload's session_title (Kimi, the opencode
    plugin, Claude's prompt events), else what the agent keeps on disk."""
    if not _NAME:
        name = ""
        if turn_text_on():
            try:
                name = _clean_name(field("session_title"))
                if not name and AGENT == "claude":
                    name = _clean_name(claude_title(field("transcript_path")))
                if not name and AGENT == "codex":
                    name = _clean_name(codex_title())
            except Exception:
                name = ""
        _NAME.append(name)
    return _NAME[0]


def place_label():
    """Where the card is from, for its title: "<session name> (<project>)", or the project."""
    name = session_name()
    return "%s (%s)" % (name, project) if name and name.lower() != project.lower() else project


def card_title(what):
    """"<what>: <session name> (<project>)", the name cut to fit the hub's title limit."""
    title = "%s: %s" % (what, place_label())
    name = session_name()
    if len(title) <= MAX_TITLE or place_label() == project:
        return title
    room = MAX_TITLE - len("%s:  ()" % what) - len(project)
    if room >= 12:
        return "%s: %s (%s)" % (what, clamp(name, room), project)
    return clamp("%s: %s" % (what, name), MAX_TITLE)


def turn_card(name, text, legacy_what, legacy_msg):
    """(kind, what, msg) for a finished turn: "<Agent> asks: <question>" when its final message
    `text` ends on a question, else "<Agent> finished". With NEEDS_YOU_TURN_TEXT=0, the old
    card (legacy_what, legacy_msg)."""
    if not turn_text_on():
        return "notify", legacy_what, legacy_msg
    q, para = turn_question(text)
    if q:
        where = place_label()
        if len(where) > 40:
            where = clamp(session_name(), 40) if session_name() else clamp(project, 40)
        head = "%s asks: " % name
        room = max(30, MAX_TITLE - len(head) - len(" · ") - len(where))
        TITLE[0] = clamp("%s%s · %s" % (head, one_line(q, room), where), MAX_TITLE)
        body = text_block(para, 600, max_lines=6)
        return "notify", "%s asks" % name, ((body + "\n\n") if body else "") + \
            "%s ended its turn on this question; your reply continues it." % name
    return "notify", "%s finished" % name, "%s finished its turn; your next message continues it." % name


# ---------------------------------------------------------------- notify
PATCH_FILE = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+)$", re.M)


def codex_card():
    """(kind, what, msg) for a Codex hook event, or None for no card."""
    if event == "PermissionRequest":
        tool = field("tool_name")
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        if tool in ("Bash", "shell", "exec_command", "local_shell"):
            word = command_word(ti.get("command") if isinstance(ti.get("command"), str) else "")
            what = "Codex wants to run %s" % word if word else "Codex wants to run a command"
        elif tool == "apply_patch":
            cmd = ti.get("command") if isinstance(ti.get("command"), str) else ""
            names = [file_name(m.strip()) for m in PATCH_FILE.findall(cmd[:200000])]
            names = [n for n in names if n]
            if len(names) == 1:
                what = "Codex wants to edit %s" % names[0]
            elif names:
                what = "Codex wants to edit %d files" % len(set(names))
            else:
                what = "Codex wants to edit files"
        else:
            what = "Codex needs permission for %s" % tool_label(tool)
        return "permission", what, "Codex is asking to use %s." % tool_label(tool)
    if event == "PreToolUse":
        # request_user_input (Plan mode): no PermissionRequest for it, but PreToolUse has it all.
        if field("tool_name") != "request_user_input":
            return None
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        asked = (question_card("Codex", questions_from(ti.get("questions")), field("tool_use_id"))
                 if questions_on() else None)
        if asked:
            return ("question",) + asked
        return "question", "Codex asked you a question", "Codex is waiting for your answer."
    if event == "Stop":
        if not turn_cards():
            return None
        return turn_card("Codex", field("last_assistant_message"), "Codex is waiting for you",
                         "Codex finished its turn and is waiting for your next message.")
    return None


def turn_cards():
    return (os.environ.get("NEEDS_YOU_AGENT_TURN_CARDS") or "").lower() not in ("0", "false", "no", "off")


def gemini_card():
    """(kind, what, msg[, steps]) for a Gemini CLI hook event, or None for no card. A
    ToolPermission notification's details are Gemini's confirmation: type exec (rootCommand),
    edit (fileName), mcp (serverName, toolName), info, ask_user or exit_plan_mode. An ask_user
    confirmation carries no question; BeforeTool (matcher ^ask_user$) has it in tool_input."""
    if event == "Notification":
        if ntype != "ToolPermission":
            return None
        d = data.get("details") if isinstance(data.get("details"), dict) else {}
        t = d.get("type")
        if t == "exec":
            word = command_word(d.get("rootCommand") if isinstance(d.get("rootCommand"), str) else "")
            what = "Gemini wants to run %s" % word if word else "Gemini wants to run a command"
        elif t == "edit":
            name = file_name(d.get("fileName") or d.get("filePath"))
            what = "Gemini wants to edit %s" % name if name else "Gemini wants to edit a file"
        elif t == "mcp":
            server = d.get("serverName") if isinstance(d.get("serverName"), str) else ""
            tool = d.get("toolName") if isinstance(d.get("toolName"), str) else ""
            what = "Gemini needs permission for %s" % tool_label("mcp__%s__%s" % (server, tool))
        elif t == "info":
            what = "Gemini wants to fetch a page"
        elif t == "ask_user":
            return None  # its BeforeTool hook posted the question with its choices
        elif t == "exit_plan_mode":
            what = "Gemini wants approval for a plan"
        else:
            what = "Gemini needs your approval"
        return "permission", what, "Gemini is waiting for you to approve a tool call."
    if event == "BeforeTool":
        if field("tool_name") != "ask_user":
            return None
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        asked = question_card("Gemini", questions_from(ti.get("questions"))) if questions_on() else None
        if asked:
            return ("question",) + asked
        return "question", "Gemini asked you a question", "Gemini is waiting for your answer."
    if event == "AfterAgent":
        if not turn_cards():
            return None
        # prompt_response: the turn's final answer (Gemini CLI source)
        return turn_card("Gemini", field("prompt_response"), "Gemini is waiting for you",
                         "Gemini finished its turn and is waiting for your next message.")
    return None


def opencode_card():
    """(kind, what, msg) for an event the opencode plugin forwards, or None. A permission
    request carries opencode's permission name and its patterns (for bash, the command; for
    edits, the paths): the card takes at most the program or a basename from them."""
    if event == "PermissionRequest":
        perm = field("tool_name")
        pats = data.get("patterns") if isinstance(data.get("patterns"), list) else []
        first = pats[0] if pats and isinstance(pats[0], str) else ""
        if perm == "bash":
            word = command_word(first)
            what = "opencode wants to run %s" % word if word else "opencode wants to run a command"
        elif perm in ("edit", "write", "patch"):
            name = file_name(first)
            what = "opencode wants to edit %s" % name if name else "opencode wants to edit a file"
        elif perm == "webfetch":
            what = "opencode wants to fetch a page"
        elif perm == "external_directory":
            what = "opencode wants to use a folder outside the project"
        else:
            what = "opencode needs permission for %s" % tool_label(perm)
        return "permission", what, "opencode is waiting for you to allow or deny it."
    if event == "Question":
        # The plugin sets `answerable` when it will wait for the card's answer (ADR 0009 B2).
        asked = (question_card("opencode", questions_from(data.get("questions")), field("question_id"),
                               answerable=data.get("answerable") is True)
                 if questions_on() else None)
        if asked:
            return ("question",) + asked
        return "question", "opencode asked you a question", "opencode is waiting for your answer."
    if event == "Stop":
        if not turn_cards():
            return None
        # The plugin sends the last assistant text it saw for the session.
        return turn_card("opencode", field("last_assistant_message"), "opencode is waiting for you",
                         "opencode finished its turn and is waiting for your next message.")
    return None


def grok_card():
    """(kind, what, msg) for a Grok Build hook event, or None. Its Notification carries no
    tool name, so a permission card can't say what for. Stop posts nothing: idle_prompt,
    about a minute later and only if the person hasn't typed, is the "waiting" card."""
    if event == "Notification":
        if ntype == "permission_prompt":
            return "permission", "Grok needs permission", "Grok is waiting for you to approve a tool call."
        if ntype == "idle_prompt":
            # An open permission card says more than "waiting"; keep it.
            if not turn_cards() or read_marker(os.environ["NY_MARKER"]).get("kind") == "permission":
                return None
            # idle_prompt carries no text of the turn (its Stop does, but isn't a card)
            return turn_card("Grok", "", "Grok is waiting for you",
                             "Grok finished its turn and is waiting for your next message.")
        return None
    if event == "StopFailure":
        # errorDetails is free text from the API; the card takes only the error code's meaning.
        what = {"rate_limit": "Grok hit a rate limit",
                "authentication_failed": "Grok needs you to sign in again",
                "billing_error": "Grok stopped on a billing problem"}.get(field("error"), "Grok stopped on an error")
        err = one_line(field("error_message"), 300)
        return "failure", what, ((err + "\n\n") if err else "") + \
            "The turn ended and won't continue on its own; send a message to retry."
    return None


def kimi_card():
    """(kind, what, msg) for a Kimi Code hook event, or None. A PermissionRequest carries the
    tool, its input and Kimi's display of it (display.command is the whole command line; the
    action text and the session title can hold anything): the card takes at most the program
    or a file's basename."""
    tool = field("tool_name")
    ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if event == "PermissionRequest":
        d = data.get("display") if isinstance(data.get("display"), dict) else {}
        if tool in ("Bash", "Shell") or (isinstance(d.get("command"), str) and not tool):
            cmd = d.get("command") if isinstance(d.get("command"), str) else ti.get("command")
            word = command_word(cmd)
            what = "Kimi wants to run %s" % word if word else "Kimi wants to run a command"
        elif tool in ("Write", "Edit", "StrReplaceFile", "WriteFile", "MultiEdit"):
            name = file_name(ti.get("path") or ti.get("file_path"))
            what = "Kimi wants to edit %s" % name if name else "Kimi wants to edit a file"
        elif tool in ("FetchURL", "WebFetch"):
            what = "Kimi wants to fetch a page"
        elif tool == "ExitPlanMode":
            # The plan is in display (read from the plan file), with the options the agent offers
            # (2-3, besides Kimi's own Reject and Revise) when there is more than one.
            what, msg = plan_card("Kimi", d.get("plan") or ti.get("plan"))
            opts = questions_from([{"options": d.get("options") or ti.get("options")}]) if questions_on() else []
            steps = choice_steps("Kimi", opts)
            return "permission", what, msg, steps
        else:
            what = "Kimi needs permission for %s" % tool_label(tool)
        return "permission", what, "Kimi is waiting for you to approve or reject it."
    if event == "PreToolUse":
        # Kimi approves AskUserQuestion by itself, so there is no PermissionRequest for it.
        if tool == "AskUserQuestion":
            asked = (question_card("Kimi", questions_from(ti.get("questions")), field("tool_call_id"))
                     if questions_on() else None)
            if asked:
                return ("question",) + asked
            return "question", "Kimi asked you a question", "Kimi is waiting for your answer."
        return None
    if event == "Stop":
        if not turn_cards():
            return None
        # Kimi's Stop carries no text of the turn (source), only session_title
        return turn_card("Kimi", "", "Kimi is waiting for you",
                         "Kimi finished its turn and is waiting for your next message.")
    if event == "StopFailure":
        err = one_line(field("error_message"), 300)
        return "failure", "Kimi stopped on an error", ((err + "\n\n") if err else "") + \
            "The turn ended and won't continue on its own; send a message to retry."
    return None


def copilot_card():
    """(kind, what, msg) for a Copilot CLI hook event, or None. A notification's message
    can hold the whole command line or URL ("Run command: <cmd>", "Fetch URL: <url>"): the
    card takes at most the program. agentStop has no notification_type."""
    if ntype == "permission_prompt":
        msg = field("message")
        if msg.startswith("Run command: "):
            word = command_word(msg[len("Run command: "):])
            what = "Copilot wants to run %s" % word if word else "Copilot wants to run a command"
        elif msg.startswith("Fetch URL: "):
            what = "Copilot wants to fetch a page"
        else:
            what = "Copilot needs your approval"
        return "permission", what, "Copilot is waiting for you to allow or deny it."
    if ntype == "elicitation_dialog":
        # An MCP server's request for input: the message is its question (no choices here).
        msg = field("message")
        asked = (question_card("Copilot", questions_from([msg]))
                 if questions_on() and msg != "Information requested" else None)
        if asked:
            return ("question",) + asked
        return "question", "Copilot asked you a question", "Copilot is waiting for your answer."
    if not ntype and "stopReason" in data:
        if not turn_cards():
            return None
        return turn_card("Copilot", "", "Copilot is waiting for you",
                         "Copilot finished its turn and is waiting for your next message.")
    return None


def cursor_card():
    """(kind, what, msg) for a Cursor stop hook, or None. Cursor has no hook for "waiting for
    approval", so this is the only card: the agent's turn ended (or failed)."""
    if event != "stop":
        return None
    status = field("status")
    if status == "completed":
        if not turn_cards():
            return None
        return turn_card("Cursor", "", "Cursor finished",
                         "Cursor's agent finished its turn and is waiting for your next message.")
    if status == "error":
        return "failure", "Cursor stopped on an error", "The agent's turn ended on an error; send a message to retry."
    return None  # aborted: the person stopped it, so they are right there


def cline_card():
    """(kind, what, msg) for a Cline hook file (the event is its name), or None. Cline runs no
    hook when it waits for an approval, so a finished task is the only waiting signal.
    TaskComplete's payload holds the agent's final text: never in a card."""
    ev = os.environ.get("NY_EVENT", "")
    if ev == "TaskError":
        return ("failure", "Cline stopped on an error",
                "The task ended on an error and won't continue on its own; send a message to retry.")
    if ev == "TaskComplete":
        if not turn_cards():
            return None
        # VS Code's TaskComplete holds the agent's final text (taskMetadata.result): only a
        # question it ends on reaches the card.
        tc = data.get("taskComplete") if isinstance(data.get("taskComplete"), dict) else {}
        meta = tc.get("taskMetadata") if isinstance(tc.get("taskMetadata"), dict) else {}
        return turn_card("Cline", meta.get("result") if isinstance(meta.get("result"), str) else "",
                         "Cline finished", "Cline finished the task and is waiting for your next message.")
    return None


def aider_card():
    """Aider says only that it is waiting: for the next message or a yes/no question."""
    if not turn_cards():
        return None
    if not turn_text_on():
        return ("notify", "Aider is waiting for you",
                "Aider replied and is waiting for you: an answer to its question, or your next message.")
    # No payload: Aider may also be waiting on a yes/no question of its own, so the body says so.
    return ("notify", "Aider finished",
            "Aider finished its reply and is waiting for you: your next message, or an answer to its question.")


def notify():
    rc, kind = notify_card()
    if rc == 0:
        sys.stdout.write(kind)
    return rc


# Set by ask(): the id and answerability of the AskUserQuestion card it posts.
ASK = {"qid": "", "answerable": False}


def notify_card():
    """(rc, kind): post the card for this hook event (rc 3: no card for it)."""
    priority = agent_priority()
    kind = "notify"
    steps = []
    asked = None
    if AGENT in ("codex", "gemini", "opencode", "copilot", "grok", "kimi", "cursor", "cline", "aider"):
        card = {"codex": codex_card, "gemini": gemini_card, "opencode": opencode_card,
                "copilot": copilot_card, "grok": grok_card, "kimi": kimi_card, "cursor": cursor_card,
                "cline": cline_card, "aider": aider_card}[AGENT]()
        if card is None:
            return 3, kind
        kind, what, msg = card[:3]
        steps = card[3] if len(card) > 3 else []
        if isinstance(steps, Asked):
            asked, steps = steps, []
    elif event == "PermissionRequest":
        if data.get("requires_user_approval") is False:
            return 3, kind
        kind = "permission"
        tool = field("tool_name")
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        if tool == "ExitPlanMode":
            what, msg = plan_card("Claude", ti.get("plan"))
        elif tool == "AskUserQuestion":
            card = (question_card("Claude", questions_from(ti.get("questions")), ASK["qid"], ASK["answerable"])
                    if questions_on() else None)
            what, msg, asked = card or ("Claude asked you a question", "Claude is waiting for your answer.", None)
        elif tool in ("Bash", "PowerShell"):
            word = command_word(ti.get("command"))
            what = "Claude wants to run %s" % word if word else "Claude wants to run a command"
            msg = "Claude is asking to use %s." % tool
        elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            name = file_name(ti.get("file_path") or ti.get("notebook_path"))
            what = "Claude wants to edit %s" % name if name else "Claude wants to edit a file"
            msg = "Claude is asking to use %s." % tool
        else:
            what = "Claude needs permission for %s" % tool_label(tool)
            msg = "Claude is asking to use %s." % tool_label(tool)
    elif event == "StopFailure":
        kind = "failure"
        et = field("error_type")
        what = {
            "rate_limit": "Claude hit a rate limit",
            "authentication_failed": "Claude needs you to sign in again",
            "oauth_org_not_allowed": "Claude needs you to sign in again",
            "cloud_credential_error": "Claude's cloud credentials failed",
            "billing_error": "Claude stopped on a billing problem",
            "account_on_hold": "Claude stopped: account on hold",
            "max_output_tokens": "Claude stopped at its output limit",
            "model_not_found": "Claude stopped: model not found",
        }.get(et, "Claude stopped on an API error")
        err = one_line(field("error_message"), 300)
        msg = ((err + "\n\n") if err else "") + "The turn ended and won't continue on its own; send a message to retry."
    else:
        prior = read_marker(os.environ["NY_MARKER"]).get("kind")
        # A PermissionRequest card is more specific than the generic prompt notifications
        # that follow it; keep it.
        if prior == "permission" and ntype in ("permission_prompt", "idle_prompt"):
            return 3, kind
        what = {
            "permission_prompt": "Claude needs permission",
            "idle_prompt": "Claude is waiting for you",
            "elicitation_dialog": "Claude needs an answer",
            "elicitation_url_dialog": "Claude needs you to sign in",
            "agent_needs_input": "Claude needs your input",
            "quota_auto_resume_disabled": "Claude hit its usage limit",
        }.get(ntype, "Claude needs you")
        msg = one_line(data.get("message"), 400)
        if ntype == "quota_auto_resume_disabled":
            kind = "failure"
        elif ntype == "idle_prompt" and turn_text_on():
            # About a minute after any turn ended: finished, or a question it ended on (the
            # transcript's last assistant text; the notification itself has none).
            kind, what, msg = turn_card("Claude", claude_last_text(field("transcript_path")), what, msg)
    title = TITLE[0] or card_title(what)
    body = "\n\n".join(([msg] if msg else []) + where_lines())
    steps_body = "\n\n".join(([asked.steps_msg] if asked else []) + where_lines())
    rc = post(base_args(os.environ["NY_KEY"], title, body, priority), make_links(), steps, asked, steps_body)
    return rc, kind


# ---------------------------------------------------------------- answers (Claude Code)
# ADR 0009 B3. Claude Code runs the `ask` entry (PermissionRequest, matcher AskUserQuestion)
# synchronously and reads its stdout as a decision, while its own question dialog shows: an
# `allow` with `updatedInput` (the tool input, plus `answers`: question text -> label, a
# multi-select's labels joined with ", ") answers the question. Measured on Claude Code
# 2.1.294: the dialog doesn't wait for this hook, and when the person answers there first,
# Claude goes on and ignores what the hook prints later.


def answers_on():
    """Answering from the card: off with NEEDS_YOU_ANSWER_TIMEOUT=0 (or off) and with
    NEEDS_YOU_AGENT_QUESTIONS=0 (no question on the card at all)."""
    v = (os.environ.get("NEEDS_YOU_ANSWER_TIMEOUT") or "").strip().lower()
    return questions_on() and v not in ("0", "off", "no", "false")


def claude_answerable(raw):
    """Can an answer from the card be handed to Claude exactly? Claude's own shape only: 1-4
    questions, each with its text (the answer's key: no two the same) and options with
    distinct labels; a multi-select's labels free of ", " (Claude joins them with it). The
    card must also show every question and label as written (question_field checks that)."""
    if not isinstance(raw, list) or not 0 < len(raw) <= MAX_QUESTIONS:
        return False
    texts = []
    for q in raw:
        if not isinstance(q, dict) or not isinstance(q.get("question"), str) or not q["question"].strip():
            return False
        opts = q.get("options")
        if not isinstance(opts, list) or not 0 < len(opts) <= MAX_OPTIONS:
            return False
        labels = [o.get("label") if isinstance(o, dict) else None for o in opts]
        if any(not isinstance(l, str) or not l.strip() for l in labels) or len(set(labels)) != len(labels):
            return False
        if q.get("multiSelect") is True and any(", " in l for l in labels):
            return False
        # The card says "choose any" for these too, but Claude reads only multiSelect.
        if q.get("multiSelect") is not True and any(q.get(k) is True for k in ("multi_select", "multiple")):
            return False
        texts.append(q["question"])
    return len(set(texts)) == len(texts)


def ask():
    """Claude's AskUserQuestion: post its card, answerable when it can be answered exactly.
    Prints "answerable <question id>" when the card waits for the click, else "permission"."""
    if AGENT != "claude" or event != "PermissionRequest" or field("tool_name") != "AskUserQuestion":
        return 3
    ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    ASK["qid"] = "claude-" + os.urandom(12).hex()
    ASK["answerable"] = answers_on() and claude_answerable(ti.get("questions"))
    rc, kind = notify_card()
    if rc != 0:
        return rc
    # Only a card posted answerable waits (question_field also refuses labels it had to cut or
    # redact; an older CLI or hub gets the steps form, which can't be answered).
    waits = (QUESTION_POSTED[0] or {}).get("answerable") is True
    sys.stdout.write("answerable %s" % ASK["qid"] if waits else kind)
    return 0


def reply():
    """Claude's decision for the answer `needs-you answer-wait` printed (NY_ANSWER) to the
    question NY_QID, or nothing when it doesn't fit that question exactly: the same question,
    one entry per question, only offered labels, no repeats, one for a single choice."""
    ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    raw = ti.get("questions")
    if field("tool_name") != "AskUserQuestion" or not claude_answerable(raw):
        return 0
    try:
        got = json.loads(os.environ.get("NY_ANSWER") or "")
    except ValueError:
        return 0
    qid = os.environ.get("NY_QID") or ""
    if not isinstance(got, dict) or not qid or got.get("question_id") != qid:
        return 0
    sel = got.get("answers")
    if not isinstance(sel, list) or len(sel) != len(raw):
        return 0
    answers = {}
    for q, s in zip(raw, sel):
        picked = s.get("selected") if isinstance(s, dict) else None
        labels = [o["label"] for o in q["options"]]
        if (not isinstance(picked, list) or not picked
                or any(not isinstance(p, str) or p not in labels for p in picked)
                or len(set(picked)) != len(picked) or (q.get("multiSelect") is not True and len(picked) != 1)):
            return 0
        answers[q["question"]] = ", ".join(l for l in labels if l in picked)
    updated = dict(ti)
    updated["answers"] = answers
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {"behavior": "allow", "updatedInput": updated}}}, ensure_ascii=False) + "\n")
    return 0


# ---------------------------------------------------------------- context
USAGE_KEYS = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


def transcript_usage(path):
    """(tokens, model) from the newest main-thread assistant message, reading only the
    tail of the transcript. (0, "") right after a compaction; None if unknown."""
    if not path or not os.path.isfile(path):
        return None
    for size in (256 * 1024, 2 * 1024 * 1024):
        try:
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                end = fh.tell()
                start = max(0, end - size)
                fh.seek(start)
                buf = fh.read(end - start)
        except OSError:
            return None
        lines = buf.split(b"\n")
        if start > 0:
            lines = lines[1:]  # partial first line
        for raw in reversed(lines):
            if b'"usage"' not in raw and b"compact_boundary" not in raw:
                continue
            try:
                d = json.loads(raw)
            except Exception:
                continue
            if not isinstance(d, dict):
                continue
            if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
                return 0, ""
            if d.get("type") != "assistant" or d.get("isSidechain"):
                continue
            m = d.get("message")
            u = m.get("usage") if isinstance(m, dict) else None
            if not isinstance(u, dict):
                continue
            model = m.get("model") if isinstance(m.get("model"), str) else ""
            if model == "<synthetic>":
                continue
            try:
                return sum(int(u.get(k) or 0) for k in USAGE_KEYS), model
            except (TypeError, ValueError):
                continue
        if start == 0:
            break
    return None


def model_names(transcript_model):
    names = [transcript_model, os.environ.get("ANTHROPIC_MODEL", "")]
    sid = re.sub(r"[^A-Za-z0-9._-]", "_", session)[:80]
    if sid:
        try:
            with open(os.path.join(os.environ["NY_STATE"], ".model-" + sid), encoding="utf-8") as fh:
                names.append(fh.read(200))
        except OSError:
            pass
    try:
        with open(os.path.expanduser("~/.claude/settings.json"), encoding="utf-8") as fh:
            m = json.loads(fh.read(1024 * 1024)).get("model")
        if isinstance(m, str):
            names.append(m)
    except Exception:
        pass
    return names


def context_window(used, transcript_model):
    try:
        w = int(float(os.environ.get("NEEDS_YOU_CONTEXT_WINDOW") or 0))
    except ValueError:
        w = 0
    if w > 0:
        return w
    if any("[1m]" in n.lower() for n in model_names(transcript_model)):
        return 1000000
    if used > 200000:  # usage can't exceed the window, so this is a 1M session
        return 1000000
    return 200000


def context():
    marker = os.environ["NY_CTX_MARKER"]
    try:
        threshold = float(os.environ.get("NEEDS_YOU_CONTEXT_ALERT_PCT") or 80)
    except ValueError:
        threshold = 80.0
    usage = transcript_usage(field("transcript_path"))
    if usage is None and threshold > 0:
        return 0  # can't tell; leave any card as it is
    used, model = usage or (0, "")
    window = context_window(used, model)
    pct = int(used * 100 // window)
    prior = read_marker(marker)
    if threshold <= 0 or pct < threshold:
        if prior or os.path.exists(marker):
            try:
                os.remove(marker)
            except OSError:
                pass
            key = prior.get("key") or os.environ["NY_KEY"] + ":context"
            try:
                subprocess.run([os.environ["NY_CLI"], "resolve", "--key", key], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            except Exception:
                pass
        return 0
    try:
        if abs(int(prior.get("pct", "")) - pct) < 5:
            return 0  # posted already at about this level; don't re-announce every turn
    except ValueError:
        pass
    key = os.environ["NY_KEY"] + ":context"
    title = card_title("Claude's context is %d%% full" % pct)
    msg = ("This session has used about %dk of its %dk-token context (%d%%). Run `/compact` to "
           "summarize and keep going, or `/clear` to start fresh if the next task is unrelated."
           % (used // 1000, window // 1000, pct))
    body = "\n\n".join([msg] + where_lines())
    rc = post(base_args(key, title, body, "low"), make_links())
    if rc == 0:
        os.makedirs(os.path.dirname(marker), exist_ok=True)
        tmp = "%s.%d.tmp" % (marker, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("key=%s\n" % key)
            if os.environ.get("NY_PID") and os.environ.get("NY_START"):
                fh.write("pid=%s\nstart=%s\n" % (os.environ["NY_PID"], os.environ["NY_START"]))
                if os.environ.get("NY_START_UTC"):
                    fh.write("start_utc=%s\n" % os.environ["NY_START_UTC"])
            fh.write("pct=%d\n" % pct)
        os.replace(tmp, marker)
    return rc


# ---------------------------------------------------------------- Codex usage
# The same card as integrations/claude-code/needs-you-usage, from what Codex writes to its
# session file: `token_count` events carry `rate_limits` = {limit_id, primary: {used_percent,
# window_minutes: 300, resets_at}, secondary: {... 10080 ...}, plan_type, ...}. Only those
# numbers are read; no credentials, no network but the CLI's post.
USAGE_WINDOWS = (("primary", "5h", "5-hour", 5.0), ("secondary", "7d", "weekly", 24.0))
USAGE_STEP = 5  # re-post only when the percentage moved this many points


def codex_rate_limits(path):
    """The newest `rate_limits` of Codex's own limit (limit_id "codex" or none) in the tail
    of the session file, or None."""
    if not path or not os.path.isfile(path):
        return None
    for size in (256 * 1024, 2 * 1024 * 1024):
        try:
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                end = fh.tell()
                start = max(0, end - size)
                fh.seek(start)
                buf = fh.read(end - start)
        except OSError:
            return None
        lines = buf.split(b"\n")
        if start > 0:
            lines = lines[1:]  # partial first line
        for raw in reversed(lines):
            if b'"rate_limits"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except Exception:
                continue
            p = d.get("payload") if isinstance(d, dict) else None
            if not isinstance(p, dict) or p.get("type") != "token_count":
                continue
            rl = p.get("rate_limits")
            if isinstance(rl, dict) and rl.get("limit_id") in (None, "codex"):
                return rl
        if start == 0:
            break
    return None


def usage_windows(rl):
    out = {}
    for name, short, _, _ in USAGE_WINDOWS:
        w = rl.get(name)
        if not isinstance(w, dict):
            continue
        try:
            pct = float(w.get("used_percent"))
        except (TypeError, ValueError):
            continue
        try:
            resets = int(w.get("resets_at") or 0)
        except (TypeError, ValueError):
            resets = 0
        out[short] = {"pct": max(0, min(100, int(pct))), "resets_at": resets}
    return out


def usage_pct(name):
    try:
        v = float(os.environ.get(name) or 0)
    except ValueError:
        return 0.0
    return v if 0 < v <= 100 else 0.0


def codex_usage():
    account = os.environ.get("NEEDS_YOU_USAGE_ACCOUNT") or ""
    if not re.match(r"^[A-Za-z0-9._-]{0,40}$", account):
        account = ""
    path = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                        "needs-you", "usage", "codex%s.json" % ("-" + account if account else ""))
    five = usage_pct("NEEDS_YOU_USAGE_ALERT_PCT")
    weekly_raw = os.environ.get("NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT")
    weekly = five if weekly_raw in (None, "") else usage_pct("NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT")
    thresholds = {"5h": five, "7d": weekly}
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
        state = state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        state = {}
    if not five and not weekly and not state:
        return 0
    rl = codex_rate_limits(field("transcript_path"))
    seen = usage_windows(rl) if rl else {}
    now = time.time()
    changed = False
    for _, short, label, fallback_h in USAGE_WINDOWS:
        key = "agent:%s:codex-usage%s:%s" % (host, ":" + account if account else "", short)
        prior = state.get(short)
        cur = seen.get(short)
        thr = thresholds[short]
        if cur is not None and 0 < cur["resets_at"] <= now:
            cur = {"pct": 0, "resets_at": cur["resets_at"]}  # that window has reset since
        if cur is None and thr:
            continue  # no numbers this time (an API key login, or none written yet)
        if not thr or cur is None or cur["pct"] < thr:
            if prior is not None:
                try:
                    subprocess.run([os.environ["NY_CLI"], "resolve", "--key", key], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                except Exception:
                    pass
                state.pop(short, None)
                changed = True
            continue
        if (isinstance(prior, dict) and prior.get("resets_at") == cur["resets_at"]
                and abs(int(prior.get("pct", -100)) - cur["pct"]) < USAGE_STEP):
            continue
        when = ""
        if cur["resets_at"] > now:
            when = time.strftime("%H:%M" if cur["resets_at"] - now < 20 * 3600 else "%a %H:%M",
                                 time.localtime(cur["resets_at"]))
        title = "Codex %s limit %d%% used%s" % (label, cur["pct"], ": resets " + when if when else "")
        if account:
            title += " (%s)" % account
        body = ("This Codex account has used %d%% of its %s limit across every session, as Codex "
                "records it in its session file. Pace the work, move it to a smaller model, or plan "
                "around the reset%s." % (cur["pct"], label, " at " + when if when else ""))
        hours = (cur["resets_at"] - now) / 3600.0 if cur["resets_at"] > now else fallback_h
        args = [os.environ["NY_CLI"], "add", "--kind", "info", "--priority", "low", "--key", key,
                "--title=" + title, "--body=" + body, "--agent", AGENT_ID,
                "--expires-in", "%.2f" % max(0.05, hours)]
        if os.environ.get("NEEDS_YOU_AGENT_CONTEXT") in ("work", "personal"):
            args += ["--context", os.environ["NEEDS_YOU_AGENT_CONTEXT"]]
        try:
            rc = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=15).returncode
        except Exception:
            rc = 1
        if rc == 0:
            state[short] = cur
            changed = True
    if changed:
        if state:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            tmp = "%s.%d.tmp" % (path, os.getpid())
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(state, fh)
            os.replace(tmp, path)
        else:
            try:
                os.remove(path)
            except OSError:
                pass
    return 0


try:
    rc = {"notify": notify, "context": context, "ask": ask, "reply": reply,
          "codex_usage": codex_usage, "title": prompt_title}.get(mode, lambda: 0)()
except Exception:
    rc = 1
raise SystemExit(rc)
PY
}

case "$mode" in
  resolve)
    # Codex's Interrupt hook is synchronous with a 1-3 s limit: don't wait on the hub.
    [ "$agent" = codex ] && resolve_bg=1
    cancel_posts
    resolve_marker "$marker" "$key"
    # Claude's UserPromptSubmit names the session (session_title, after /rename): keep it for
    # the session's cards, so they needn't search the transcript for it.
    case "$agent:$input" in
      claude:*'"session_title"'*) run_py title >/dev/null ;;
    esac
    ;;

  stop)
    # A StopFailure card stays until the next prompt: the turn ended on an error.
    cancel_posts stop
    grep -qs '^kind=failure$' "$marker" || resolve_marker "$marker" "$key"
    [ "$agent" = grok ] && exit 0  # its transcript isn't Claude's: no context card
    case "${NEEDS_YOU_CONTEXT_ALERT_PCT:-}" in
      0|0.0|off|no|false) resolve_marker "$ctx_marker" ;;
      *) run_py context >/dev/null; log "context $key -> $?" ;;
    esac
    ;;

  start)
    # Remember the model (the transcript has no [1m] suffix) for the context check.
    model=$(json_str model)
    if [ "$agent" = claude ] && [ -n "$model" ] && [ -n "$session_id" ] && mkdir -p "$state_dir" 2>/dev/null; then
      printf '%s' "$model" | cut -c1-200 >"$state_dir/.model-$(sanitize "$session_id")" 2>/dev/null
      find "$state_dir" \( -name '.model-*' -o -name '.title-*' \) -mtime +7 -exec rm -f {} + 2>/dev/null
    fi
    # Cline: a task starts or resumes (a new task has a new taskId): the finished cards of
    # earlier tasks in the same Cline (the lease's process) no longer apply.
    [ "$agent" = cline ] && resolve_marker "$marker"
    case "$agent:$(json_str source)" in
      *:clear|*:compact|*:resume|cline:*)
        # A new conversation in the same Claude process: cards from before it
        # (the old session id after /clear, a full context before compaction)
        # no longer apply. Find them by the lease's process.
        lease
        # Codex (0.159+) runs hooks from one app-server daemon shared by every Codex
        # session of the user, so its pid names no single session: resolve only this
        # session's own card (compaction keeps the id). After /clear the old session's
        # SessionEnd, which the daemon sends when it unloads the thread, clears its card.
        if [ -n "$lease_pid" ] && ps -o args= -p "$lease_pid" 2>/dev/null | grep -q ' app-server\( \|$\)'; then
          resolve_marker "$marker"
        elif [ -n "$lease_pid" ] && [ -d "$state_dir" ]; then
          for f in "$state_dir"/*; do
            [ -f "$f" ] || continue
            if [ "$(sed -n 's/^pid=//p' "$f" 2>/dev/null)" = "$lease_pid" ] &&
               [ "$(sed -n 's/^start=//p' "$f" 2>/dev/null)" = "$lease_start" ]; then
              resolve_marker "$f"
            fi
          done
        fi
        resolve_marker "$ctx_marker"
        ;;
    esac
    ;;

  end)
    cancel_posts
    if [ "$agent" = codex ]; then
      # Codex runs SessionEnd synchronously with a 1-3 s limit: resolve in the
      # background (the CLI queues if no hub answers; flush reaps the lease if
      # this is cut short).
      resolve_bg=1
      resolve_marker "$marker" "$key"
    else
      resolve_marker "$marker" "$key"
      resolve_marker "$ctx_marker"
      [ -n "$session_id" ] && rm -f "$state_dir/.model-$(sanitize "$session_id")" "$state_dir/.title-$(sanitize "$session_id")"
    fi
    # The session is over, so nothing of its waits on input any more. (The agent's own items
    # stay open on the hub until it, or a later run, resolves them.)
    case "$id" in .|..) ;; *) rm -rf "$items_dir" ;; esac
    if { [ "$agent" = gemini ] || [ "$agent" = kimi ]; } && [ -d "$items_base" ]; then
      lease
      [ -n "$lease_pid" ] && rm -rf "$items_base/pid-$lease_pid"
    fi
    ;;

  answer-wait)
    # The opencode plugin, after posting an answerable question card: wait for the person's
    # click on the card and print the answer (the CLI's JSON) for the plugin to hand to
    # opencode. Nothing on a timeout, an error or a card closed without an answer: the plugin
    # then answers nothing. Never picks or invents an answer.
    NEEDS_YOU_WATCH_PID=$$ "$cli" answer-wait --key "$key" --timeout "$(answer_timeout)" </dev/null 2>/dev/null
    log "answer-wait $key -> $?"
    ;;

  ask)
    # Claude Code's AskUserQuestion, from a synchronous PermissionRequest entry of its own
    # (ADR 0009 B3). Post the question card, and when the card can answer it exactly, wait for
    # the person's click and print Claude's decision with the answer: the only thing this hook
    # ever prints. Claude shows its own dialog meanwhile, and the first answer wins: one given
    # in the terminal resolves the card (PostToolUse, else Stop), which ends the wait. Nothing
    # is printed on a timeout, an error or an answer that doesn't fit the question.
    [ "$agent" = claude ] || exit 0
    lease
    begin_post
    posted=$(run_py ask)
    rc=$?
    log "ask $key -> $rc ${posted%% *}"
    case "$rc" in 0|1) ;; *) exit 0 ;; esac  # 1: maybe posted (see notify)
    write_marker "$marker" "$key" "kind=permission"
    end_post && exit 0  # answered in the terminal meanwhile: nothing to wait for
    [ "$rc" -eq 0 ] || exit 0
    case "$posted" in "answerable "?*) ;; *) exit 0 ;; esac
    NY_QID=${posted#answerable }
    # NEEDS_YOU_WATCH_PID: the CLI stops waiting once this hook is gone (Claude kills it when
    # the session quits or it stops waiting), not an hour later.
    NY_ANSWER=$(NEEDS_YOU_WATCH_PID=$$ "$cli" answer-wait --key "$key" --timeout "$(answer_timeout)" \
      </dev/null 2>/dev/null)
    rc=$?
    log "ask answer-wait $key -> $rc"
    [ "$rc" -eq 0 ] && [ -n "$NY_ANSWER" ] || exit 0
    export NY_QID NY_ANSWER
    run_py reply
    ;;

  notify)
    begin_post
    # One card for one wait: when the agent has posted its own blocker from this session (the
    # skill), the generic "waiting for input" card would only repeat it. Permission prompts,
    # questions and errors still post: they are a different thing to act on.
    # The same wait in each agent: Claude's idle / needs-input notifications, and the "turn
    # ended" card of Codex (Stop), Gemini (AfterAgent), opencode (Stop: session idle),
    # Copilot (agentStop: no event name or notification type), Grok (idle_prompt, sent
    # as notificationType) and Kimi (Stop).
    ntype=$(json_str notification_type)
    [ -n "$ntype" ] || ntype=$(json_str notificationType)
    # Codex's turn ended: the usage-limit card (off unless NEEDS_YOU_USAGE_ALERT_PCT or
    # NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT is set; with neither, python starts only to clear a card
    # it posted before). Before the turn card, which may be skipped below.
    if [ "$agent" = codex ] && [ "$(json_str hook_event_name)" = Stop ]; then
      usage_glob=("${XDG_STATE_HOME:-$HOME/.local/state}"/needs-you/usage/codex*.json)
      if [ -n "$NEEDS_YOU_USAGE_ALERT_PCT$NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT" ] || [ -f "${usage_glob[0]}" ]; then
        run_py codex_usage >/dev/null
        log "codex usage $host -> $?"
      fi
    fi
    # A question card the turn ended under no longer applies: the question was answered (its
    # PostToolUse resolves first) or never shown (Codex refuses request_user_input outside Plan
    # mode after its PreToolUse ran; Kimi's auto mode denies AskUserQuestion). Clear it here, so
    # it doesn't outlive the turn when no "waiting" card replaces it.
    case "$agent:$(json_str hook_event_name)" in
      codex:Stop|kimi:Stop|gemini:AfterAgent)
        grep -qs '^kind=question$' "$marker" && resolve_marker "$marker" "$key" ;;
    esac
    case "$agent:$ntype:$(json_str hook_event_name)" in
      claude:idle_prompt:*|claude:agent_needs_input:*|grok:idle_prompt:*|kimi::Stop|codex::Stop|opencode::Stop|gemini::AfterAgent|copilot::)
        if own_item_open; then
          log "notify $key -> skipped: the agent's own item for this session is open"
          exit 0
        fi
        ;;
    esac
    # The same for Cursor's stop, Cline's TaskComplete and Aider (one card per wait).
    case "$agent:$(json_str hook_event_name)${NY_EVENT:-}" in
      cursor:stop|cline:TaskComplete|aider:)
        if own_item_open; then
          log "notify $key -> skipped: the agent's own item for this session is open"
          exit 0
        fi
        ;;
    esac
    # `copilot -p` ends its turn, ends the session and exits within a moment: wait that
    # moment before a turn-end card (no notification type), so the lease below finds it gone.
    if [ "$agent" = copilot ] && [ -z "$(json_str notification_type)" ]; then
      sleep "${NY_COPILOT_TURN_WAIT:-2}"
    fi
    # So do `cursor-agent -p` and a one-shot `cline "task"`.
    if [ "$agent" = cursor ] || [ "$agent" = cline ]; then
      sleep "${NY_TURN_WAIT:-2}"
    fi
    # The same for `kimi -p`, which exits a moment after its Stop hook.
    if [ "$agent" = kimi ] && [ "$(json_str hook_event_name)" = Stop ]; then
      sleep "${NY_KIMI_TURN_WAIT:-2}"
    fi
    # Take the lease now, before the post (run_py runs in a subshell, and the agent may exit
    # while the CLI posts). `opencode run` goes idle and exits at once: with the agent
    # already gone nobody is waiting, and a card without a lease would stay for 48 hours.
    lease
    if { [ "$agent" = opencode ] || [ "$agent" = copilot ] || [ "$agent" = kimi ] || [ "$agent" = cursor ] ||
         [ "$agent" = cline ] || [ "$agent" = aider ]; } && [ -z "$lease_pid" ]; then
      log "notify $key -> skipped: $agent has exited"
      exit 0
    fi
    # Build the item from the hook JSON and call the CLI with an argv list
    # (no shell quoting of untrusted text). Prints what posted it.
    kind=$(run_py notify)
    rc=$?
    log "notify $key -> $rc"
    # The CLI queues offline and exits 0, so a down hub still leaves a marker
    # and the later resolve is queued behind the add. A post that didn't finish (1: the CLI
    # cut off at the hook's limit, its request maybe on the hub already or still in the
    # outbox, to go out with the next run) leaves one too: resolving a card that never came
    # costs a request, a card nobody resolves stays for days.
    case "$rc" in
      0|1) write_marker "$marker" "$key" "kind=${kind:-notify}"; end_post ;;
    esac
    ;;
esac

exit 0
