#!/usr/bin/env bash
# needs-you-version: 0.1.5
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
# the tmux pane (session:window.pane), VS Code, or SSH, and links to it where
# it can (VS Code folder, Remote-SSH window, the VS Code Claude tab, the Orca
# terminal, the Mac terminal tab: below). Always exits 0 and never prints to stdout, so it can't block or
# steer Claude. Installed by install-hooks.sh.
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
#   NEEDS_YOU_AGENT_QUESTIONS  0 = a question card says only "<Agent> asked you a
#                             question" and a plan card shows no plan text (default:
#                             the question, its choices as steps and the plan's first
#                             lines, cleaned, token-shaped text redacted, clamped)
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
           NEEDS_YOU_AIDER_EXPIRY_HOURS NEEDS_YOU_AGENT_QUESTIONS; do
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
import json, os, re, shlex, subprocess, sys
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
    if AGENT == "cursor":
        where.append("Cursor")
    elif (os.environ.get("TERM_PROGRAM") == "vscode" or os.environ.get("VSCODE_IPC_HOOK_CLI")
            or os.environ.get("CLAUDE_CODE_ENTRYPOINT") == "claude-vscode"):
        where.append("VS Code")
    elif os.environ.get("SSH_CONNECTION") and not tmux_target:
        where.append("SSH")
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


def post(args, links, steps=None, asked=None, steps_body=None):
    """Post the card. With `asked` (a question card): with its `question` field, and if the
    CLI or hub refuses that (an older one), again with the choices as steps and `steps_body`."""
    if asked is not None and asked.question:
        rc = post(args + ["--question-json=" + json.dumps(asked.question, ensure_ascii=False)], links)
        if rc != 2:
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
                                  stderr=subprocess.DEVNULL, timeout=15).returncode
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
_SECRET_RAW = re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_\w{16,}|sk-[A-Za-z0-9_-]{16,}"
                         r"|xox[abpr]-[\w-]{10,}|AKIA[0-9A-Z]{16}|nyi?_[A-Za-z0-9_-]{8,}"
                         r"|glpat-[\w-]{16,}|AIza[\w-]{30,}|eyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]*)")
_SECRET_KV = re.compile(r"(?i)\b((?:\w*[_-])?(?:token|password|passwd|secret|api[_-]?key|access[_-]?key"
                        r"|auth|credentials?))(\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|\S+)")
_SECRET_AUTH = re.compile(r"(?i)\b(bearer|basic|token)(\s+)[A-Za-z0-9._~+/=-]{8,}")
_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.S)
_LONG_HEX = re.compile(r"\b[0-9A-Fa-f]{32,}\b")
_LONG_RUN = re.compile(r"[A-Za-z0-9+/_=-]{40,}")
REDACTED = "[redacted]"


def _long_run(m):
    s = m.group(0)
    # base64-ish: digits and both cases, few separators (not a path or a branch name)
    if (len(re.findall(r"[-_/]", s)) <= 3 and re.search(r"[0-9]", s) and re.search(r"[a-z]", s)
            and re.search(r"[A-Z]", s)):
        return REDACTED
    return s


def redact(text):
    text = _PEM.sub(REDACTED, text)
    text = _SECRET_RAW.sub(REDACTED, text)
    text = _SECRET_KV.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)
    text = _SECRET_AUTH.sub(lambda m: m.group(1) + m.group(2) + REDACTED, text)
    text = _LONG_HEX.sub(REDACTED, text)
    return _LONG_RUN.sub(_long_run, text)


def clamp(text, limit):
    return text if len(text) <= limit else text[:max(0, limit - 1)].rstrip() + "…"


def one_line(value, limit):
    """Agent text for a title or a step: one line, cleaned, redacted, clamped."""
    if not isinstance(value, str):
        return ""
    return clamp(" ".join(redact(_BAD_CHARS.sub(" ", value)).split()), limit)


def text_block(value, limit, max_lines=8):
    """Agent text for the body: up to max_lines non-blank lines, cleaned, redacted, clamped.
    Markdown headings become bold lines and code fences go (the card renders inline markdown
    only)."""
    if not isinstance(value, str):
        return ""
    lines, more = [], False
    for raw in redact(value.replace("\r\n", "\n").replace("\t", "    ")).split("\n"):
        line = " ".join(_BAD_CHARS.sub(" ", raw).split())
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


def question_field(questions, qid=""):
    """The `question` field for `questions` (the hub's limits: 4 questions, 8 options), or None."""
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
    return out


def question_card(name, questions, qid=""):
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
    room = MAX_TITLE - len('%s asks ""%s: ' % (name, more)) - min(len(project), 30)
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
    return what, msg, Asked(question_field(questions, qid), choice_steps(name, questions), steps_msg)


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
        return "notify", "Codex is waiting for you", "Codex finished its turn and is waiting for your next message."
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
        return "notify", "Gemini is waiting for you", "Gemini finished its turn and is waiting for your next message."
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
        asked = (question_card("opencode", questions_from(data.get("questions")), field("question_id"))
                 if questions_on() else None)
        if asked:
            return ("question",) + asked
        return "question", "opencode asked you a question", "opencode is waiting for your answer."
    if event == "Stop":
        if not turn_cards():
            return None
        return "notify", "opencode is waiting for you", "opencode finished its turn and is waiting for your next message."
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
            return "notify", "Grok is waiting for you", "Grok finished its turn and is waiting for your next message."
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
        return "notify", "Kimi is waiting for you", "Kimi finished its turn and is waiting for your next message."
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
        return "notify", "Copilot is waiting for you", "Copilot finished its turn and is waiting for your next message."
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
        return "notify", "Cursor finished", "Cursor's agent finished its turn and is waiting for your next message."
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
        return "notify", "Cline finished", "Cline finished the task and is waiting for your next message."
    return None


def aider_card():
    """Aider says only that it is waiting: for the next message or a yes/no question."""
    if not turn_cards():
        return None
    return ("notify", "Aider is waiting for you",
            "Aider replied and is waiting for you: an answer to its question, or your next message.")


def notify():
    priority = agent_priority()
    kind = "notify"
    steps = []
    asked = None
    if AGENT in ("codex", "gemini", "opencode", "copilot", "grok", "kimi", "cursor", "cline", "aider"):
        card = {"codex": codex_card, "gemini": gemini_card, "opencode": opencode_card,
                "copilot": copilot_card, "grok": grok_card, "kimi": kimi_card, "cursor": cursor_card,
                "cline": cline_card, "aider": aider_card}[AGENT]()
        if card is None:
            return 3
        kind, what, msg = card[:3]
        steps = card[3] if len(card) > 3 else []
        if isinstance(steps, Asked):
            asked, steps = steps, []
    elif event == "PermissionRequest":
        if data.get("requires_user_approval") is False:
            return 3
        kind = "permission"
        tool = field("tool_name")
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        if tool == "ExitPlanMode":
            what, msg = plan_card("Claude", ti.get("plan"))
        elif tool == "AskUserQuestion":
            card = question_card("Claude", questions_from(ti.get("questions"))) if questions_on() else None
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
            return 3
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
    title = "%s: %s" % (what, project)
    body = "\n\n".join(([msg] if msg else []) + where_lines())
    steps_body = "\n\n".join(([asked.steps_msg] if asked else []) + where_lines())
    rc = post(base_args(os.environ["NY_KEY"], title, body, priority), make_links(), steps, asked, steps_body)
    if rc == 0:
        sys.stdout.write(kind)
    return rc


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
    title = "Claude's context is %d%% full: %s" % (pct, project)
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


try:
    rc = notify() if mode == "notify" else context() if mode == "context" else 0
except Exception:
    rc = 1
raise SystemExit(rc)
PY
}

case "$mode" in
  resolve)
    # Codex's Interrupt hook is synchronous with a 1-3 s limit: don't wait on the hub.
    [ "$agent" = codex ] && resolve_bg=1
    resolve_marker "$marker" "$key"
    ;;

  stop)
    # A StopFailure card stays until the next prompt: the turn ended on an error.
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
      find "$state_dir" -name '.model-*' -mtime +7 -exec rm -f {} + 2>/dev/null
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
    if [ "$agent" = codex ]; then
      # Codex runs SessionEnd synchronously with a 1-3 s limit: resolve in the
      # background (the CLI queues if no hub answers; flush reaps the lease if
      # this is cut short).
      resolve_bg=1
      resolve_marker "$marker" "$key"
    else
      resolve_marker "$marker" "$key"
      resolve_marker "$ctx_marker"
      [ -n "$session_id" ] && rm -f "$state_dir/.model-$(sanitize "$session_id")"
    fi
    # The session is over, so nothing of its waits on input any more. (The agent's own items
    # stay open on the hub until it, or a later run, resolves them.)
    case "$id" in .|..) ;; *) rm -rf "$items_dir" ;; esac
    if { [ "$agent" = gemini ] || [ "$agent" = kimi ]; } && [ -d "$items_base" ]; then
      lease
      [ -n "$lease_pid" ] && rm -rf "$items_base/pid-$lease_pid"
    fi
    ;;

  notify)
    # One card for one wait: when the agent has posted its own blocker from this session (the
    # skill), the generic "waiting for input" card would only repeat it. Permission prompts,
    # questions and errors still post: they are a different thing to act on.
    # The same wait in each agent: Claude's idle / needs-input notifications, and the "turn
    # ended" card of Codex (Stop), Gemini (AfterAgent), opencode (Stop: session idle),
    # Copilot (agentStop: no event name or notification type), Grok (idle_prompt, sent
    # as notificationType) and Kimi (Stop).
    ntype=$(json_str notification_type)
    [ -n "$ntype" ] || ntype=$(json_str notificationType)
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
    # and the later resolve is queued behind the add.
    [ "$rc" -eq 0 ] && write_marker "$marker" "$key" "kind=${kind:-notify}"
    ;;
esac

exit 0
