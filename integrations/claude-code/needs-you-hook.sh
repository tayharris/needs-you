#!/usr/bin/env bash
# needs-you-version: 0.1.2
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
#            PermissionRequest and Stop (the turn ended) call `notify`.
#   gemini   Gemini CLI (integrations/gemini/, ~/.gemini/settings.json):
#            Notification (ToolPermission) and AfterAgent call `notify`. Gemini
#            waits for every hook, so the hook reads its input and finishes the
#            work in the background.
#   opencode opencode, through integrations/opencode/needs-you.js (a plugin that
#            starts this hook with a small JSON object): PermissionRequest,
#            Question and Stop (the session went idle) call `notify`.
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
# Optional settings (environment, or lines in ~/.config/needs-you/env):
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
#   NEEDS_YOU_AGENT_TURN_CARDS  Codex, Gemini, opencode: 0 = no card when a turn ends,
#                             just approval prompts (default: on)
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
  *) agent=claude ;;
esac

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

# Gemini CLI waits for each hook (and reads its stdout and stderr as JSON): hand
# the work to a background copy with no stdio and return at once. The copy
# starts the lease search from this hook's parent.
if [ "$agent" = gemini ] && [ -z "${NY_HOOK_BG:-}" ]; then
  printf '%s' "$input" | NY_HOOK_BG=1 NY_HOOK_PPID=$PPID bash "$0" "$mode" gemini >/dev/null 2>&1 &
  exit 0
fi

for var in NEEDS_YOU_AGENT_CONTEXT NEEDS_YOU_AGENT_PRIORITY NEEDS_YOU_AGENT_LINK NEEDS_YOU_BIN \
           NEEDS_YOU_ORCA_ENVIRONMENT NEEDS_YOU_AGENT_EXPIRY_HOURS NEEDS_YOU_SSH_ALIAS \
           NEEDS_YOU_CONTEXT_ALERT_PCT NEEDS_YOU_CONTEXT_WINDOW NEEDS_YOU_AGENT_TURN_CARDS; do
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

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80; }

# A plain string field from the hook JSON. A sed grab avoids a python start-up
# on every event; the values read this way are ids and fixed words.
json_str() {
  printf '%s\n' "$input" |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

session_id=$(json_str session_id)

host=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
host=$(sanitize "${host%%.*}")
id=${ORCA_TERMINAL_HANDLE:-$session_id}
[ -n "$id" ] || { log "no session id or terminal handle; skipping"; exit 0; }
id=$(sanitize "$id")
key="agent:$host:$id"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you/claude-hooks"
marker="$state_dir/$id"
ctx_marker="$state_dir/$id.context"

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
lease() {  # fills lease_pid and lease_start once
  [ -z "$lease_pid" ] || return 0
  lease_pid=$(agent_pid)
  [ -n "$lease_pid" ] && lease_start=$(LC_ALL=C ps -o lstart= -p "$lease_pid" 2>/dev/null)
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

# The card builder and the context check share one python program (below).
run_py() {
  command -v python3 >/dev/null 2>&1 || { log "python3 not found"; return 1; }
  lease
  NY_MODE=$1 NY_INPUT=$input NY_KEY=$key NY_HOST=$host NY_CLI=$cli NY_ID=$id \
  NY_MARKER=$marker NY_CTX_MARKER=$ctx_marker NY_STATE=$state_dir \
  NY_PID=$lease_pid NY_START=$lease_start NY_AGENT=$agent \
  python3 - 2>/dev/null <<'PY'
import json, os, re, shlex, subprocess, sys
from urllib.parse import parse_qsl, quote

mode = os.environ.get("NY_MODE", "")
AGENT = os.environ.get("NY_AGENT") if os.environ.get("NY_AGENT") in ("codex", "gemini", "opencode") else "claude"
AGENT_ID = {"codex": "codex", "gemini": "gemini-cli", "opencode": "opencode"}.get(AGENT, "claude-code")
try:
    data = json.loads(os.environ.get("NY_INPUT") or "{}")
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}


def field(name):
    v = data.get(name)
    return v if isinstance(v, str) else ""


def oneline(text, limit):
    return " ".join(str(text or "").split())[:limit]


event = field("hook_event_name")
ntype = field("notification_type")
cwd = field("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
project = os.path.basename(project_dir.rstrip("/")) or "claude"
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
    if (os.environ.get("TERM_PROGRAM") == "vscode" or os.environ.get("VSCODE_IPC_HOOK_CLI")
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
    if platform == "darwin" and not os.environ.get("SSH_CONNECTION"):
        links.append("VS Code=vscode://file" + quote(cwd))  # this is the Mac: the path exists there
    elif SAFE_NAME.match(alias):
        links.append("VS Code=vscode://vscode-remote/ssh-remote+%s%s" % (alias, quote(cwd)))
    return links


def base_args(key, title, body, priority):
    context = os.environ.get("NEEDS_YOU_AGENT_CONTEXT") or ""
    args = [os.environ["NY_CLI"], "add", "--key", key]
    if context in ("work", "personal"):  # else the CLI's NEEDS_YOU_DEFAULT_CONTEXT, else work
        args += ["--context", context]
    # --opt=value: a title, body or project starting with "-" isn't taken for an option
    args += ["--priority", priority, "--title=" + title[:100], "--body=" + body[:2000],
             "--agent", AGENT_ID, "--project=" + project]
    try:
        expiry = float(os.environ.get("NEEDS_YOU_AGENT_EXPIRY_HOURS") or 48)
    except ValueError:
        expiry = 48.0
    if expiry > 0:
        args += ["--expires-in", "%g" % expiry]
    return args


def post(args, links):
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
    if event == "Stop":
        if not turn_cards():
            return None
        return "notify", "Codex is waiting for you", "Codex finished its turn and is waiting for your next message."
    return None


def turn_cards():
    return (os.environ.get("NEEDS_YOU_AGENT_TURN_CARDS") or "").lower() not in ("0", "false", "no", "off")


def gemini_card():
    """(kind, what, msg) for a Gemini CLI hook event, or None for no card. A ToolPermission
    notification's details are Gemini's confirmation: type exec (rootCommand), edit
    (fileName), mcp (serverName, toolName) or info."""
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
        else:
            what = "Gemini needs your approval"
        return "permission", what, "Gemini is waiting for you to approve a tool call."
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
        return "notify", "opencode asked you a question", "opencode is waiting for your answer."
    if event == "Stop":
        if not turn_cards():
            return None
        return "notify", "opencode is waiting for you", "opencode finished its turn and is waiting for your next message."
    return None


def notify():
    priority = agent_priority()
    kind = "notify"
    if AGENT in ("codex", "gemini", "opencode"):
        card = {"codex": codex_card, "gemini": gemini_card, "opencode": opencode_card}[AGENT]()
        if card is None:
            return 3
        kind, what, msg = card
    elif event == "PermissionRequest":
        if data.get("requires_user_approval") is False:
            return 3
        kind = "permission"
        tool = field("tool_name")
        ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
        if tool == "ExitPlanMode":
            what, msg = "Approve Claude's plan", "Claude has a plan ready and is waiting for your approval."
        elif tool == "AskUserQuestion":
            what, msg = "Claude asked you a question", "Claude is waiting for your answer."
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
        err = oneline(field("error_message"), 300)
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
            "agent_needs_input": "Agent needs input",
            "quota_auto_resume_disabled": "Claude hit its usage limit",
        }.get(ntype, "Claude needs you")
        msg = oneline(data.get("message"), 400)
        if ntype == "quota_auto_resume_disabled":
            kind = "failure"
    title = "%s: %s" % (what, project)
    body = "\n\n".join(([msg] if msg else []) + where_lines())
    rc = post(base_args(os.environ["NY_KEY"], title, body, priority), make_links())
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
    case "$(json_str source)" in
      clear|compact|resume)
        # A new conversation in the same Claude process: cards from before it
        # (the old session id after /clear, a full context before compaction)
        # no longer apply. Find them by the lease's process.
        lease
        if [ -n "$lease_pid" ] && [ -d "$state_dir" ]; then
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
    ;;

  notify)
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
