# needs-you for Claude Code

Two independent pieces. Use either or both, in any repo or VM, with or without Orca.

| Piece | What it does | Install |
|---|---|---|
| **Hooks** | When a Claude Code session stops to ask for permission, approve a plan or answer a question, sits waiting for input, or stops on an API error, a `needs` item appears on your Mac. It's resolved automatically as soon as the session moves again. A low-priority card suggests `/compact` or `/clear` when the context fills up. | `./install-hooks.sh` |
| **Skill** | Teaches the agent when and how to post a specific blocker ("choose A or B for ACME-123") and to resolve it afterwards. | copy `skill/needs-you` to `~/.claude/skills/` |

Shortest setup, and how it works over SSH, in tmux, VS Code Remote-SSH and Orca: [docs/guides/claude-code-everywhere.md](../../docs/guides/claude-code-everywhere.md).

Both call the `needs-you` CLI, so set the machine up as a sender first: an invite link from the Mac app (its installer can add the hooks and the skill too, and turn them on: `--claude-hooks user --skill --alerts`), or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh) ([guide](../../docs/guides/add-a-sender.md)).

## Files

```
integrations/claude-code/
├── hooks.json            the hook config (user-level paths), for reference or hand-merging
├── needs-you-hook.sh     the hook itself: bash + python3, always exits 0
├── install-hooks.sh      merges hooks.json into a settings.json (python3, with a backup)
├── needs-you-usage       optional status line helper: the Mac's usage meter, and a card when a limit runs high
└── skill/needs-you/SKILL.md
```

The same hook serves OpenAI Codex CLI, Gemini CLI, opencode, GitHub Copilot CLI, Kimi Code CLI, Grok Build, Cursor, Cline and Aider when started with a `codex`, `gemini`, `opencode`, `copilot`, `kimi`, `grok`, `cursor`, `cline` or `aider` argument (`needs-you-hook.sh notify codex`): see [integrations/codex](../codex/README.md), [integrations/gemini](../gemini/README.md), [integrations/opencode](../opencode/README.md), [integrations/copilot](../copilot/README.md), [integrations/kimi](../kimi/README.md), [integrations/grok](../grok/README.md), [integrations/cursor](../cursor/README.md), [integrations/cline](../cline/README.md) and [integrations/aider](../aider/README.md). Cursor also runs these Claude Code hooks from `~/.claude/settings.json`; given a Cursor payload they exit at once.

## Hooks

### Install

```bash
# user level: every repo on this machine (~/.claude/settings.json)
integrations/claude-code/install-hooks.sh

# project level: commit .claude/settings.json and .claude/hooks/ so everyone gets it
integrations/claude-code/install-hooks.sh --project /path/to/repo

# project level, just for you (settings.local.json, normally gitignored)
integrations/claude-code/install-hooks.sh --project /path/to/repo --local

# preview, or remove
integrations/claude-code/install-hooks.sh --dry-run
integrations/claude-code/install-hooks.sh --uninstall
```

The installer:

- copies `needs-you-hook.sh` to `~/.claude/hooks/` (or `<repo>/.claude/hooks/`),
- backs up the settings file to `settings.json.bak-<timestamp>` before changing it,
- replaces any earlier needs-you entries and leaves every other setting and hook alone,
- doesn't rewrite the file if nothing changed, so it's safe to run from provisioning scripts,
- writes through a symlinked user-level settings file (dotfile managers) and keeps its mode,
- refuses to touch a settings file that isn't valid JSON,
- records a project install in `~/.local/state/needs-you/claude-projects.json` (and forgets it on `--uninstall`), so `needs-you doctor`, `needs-you update` and `needs-you uninstall-hooks` can find it,
- refuses a project whose `.claude`, `.claude/hooks`, hook script or settings file is a symlink (a repo's `.claude` is untrusted).

**Grok Build** runs these hooks from `~/.claude/settings.json` too (on by default). The hook knows it by `$GROK_HOOK_EVENT`. When needs-you's own Grok hooks are installed (`${GROK_HOME:-~/.grok}/hooks/needs-you.json`, [integrations/grok](../grok/README.md)), these do nothing in a Grok session, so a wait is posted once. Without them, they post for Grok: its cards say Grok ("Grok finished" from `idle_prompt`, "Grok needs permission", source agent `grok`), they read Grok's `notificationType`, skip the context check on `Stop`, and hand the work to a background copy, since Grok waits for its hooks.

**One card for one wait.** `needs-you add` (kind `needs`) run by an agent notes the key in `~/.local/state/needs-you/session-items/<id>/` (one file per key with `key=` and `expires=<epoch>`, at most 48 hours), where `<id>` is the session as the hook names it, sanitized as the hook does: `$ORCA_TERMINAL_HANDLE` (any agent), else Claude Code's `$CLAUDE_CODE_SESSION_ID` (with `$CLAUDECODE` set), Codex's `$CODEX_SESSION_ID` (older Codex: `$CODEX_THREAD_ID`), or `$NEEDS_YOU_AGENT_SESSION`, which any connector can set for its agent's commands (the opencode plugin does, through `shell.env`). Each is the `session_id` that agent's hooks get. Gemini CLI gives its commands no session id (only `GEMINI_CLI=1`), so there the CLI notes the key under `pid-<pid>` of the Gemini process (the first ancestor that isn't a shell, as the hook finds its lease) with its `start=` time, and the hook matches it against its lease. The same for Kimi Code, whose Bash tool runs commands with `TERM=dumb` and no session id: with `TERM=dumb`, a first non-shell ancestor named `kimi` gets the `pid-` note. `notify` skips `idle_prompt` and `agent_needs_input` (and the Codex `Stop`, Gemini `AfterAgent` and opencode `Stop` cards) while an unexpired note exists for its session. `needs-you resolve` and a `done`/`info` with the same key remove the note; `end` removes the session's directory (for Gemini and Kimi, their process's).

`needs-you uninstall-hooks` removes the hooks without this script or a hub (user level, the current directory's project, recorded project installs).

Restart running sessions (or open `/hooks` in Claude Code) to pick up the change.

### Turn it on

The hooks are installed everywhere but do nothing unless the session is opted in, so ordinary interactive use stays quiet:

| Condition | Effect |
|---|---|
| `$ORCA_TERMINAL_HANDLE` is set (Orca started the session) | on |
| `NEEDS_YOU_AGENT_ALERTS=1` in the environment | on |
| `NEEDS_YOU_AGENT_ALERTS=1` as a line in `~/.config/needs-you/env` | on for every session on this machine (good for headless VMs) |
| `NEEDS_YOU_AGENT_ALERTS=0` | off, even inside Orca |

```bash
# just this session
NEEDS_YOU_AGENT_ALERTS=1 claude

# this whole VM (what the invite installer's --alerts writes)
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env
```

### What gets posted

| Claude Code event | Hook mode | Hook action |
|---|---|---|
| `Notification` with `notification_type` `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` or `quota_auto_resume_disabled` | `notify` | `needs-you add` (kind `needs`). A `permission_prompt` or `idle_prompt` doesn't overwrite the more specific `PermissionRequest` card |
| `PermissionRequest` (every tool but `AskUserQuestion`: matcher `^(?!AskUserQuestion$)`) | `notify` | `needs-you add` with a title per tool: plan approval (`ExitPlanMode`), the program a `Bash` call runs, the file an `Edit`/`Write` changes, else the tool's name |
| `PermissionRequest` for `AskUserQuestion` (matcher `AskUserQuestion`, synchronous) | `ask` | `needs-you add` with the question; when the card can answer it exactly, posted answerable, then `needs-you answer-wait` and the person's click printed as Claude's decision (below) |
| `StopFailure` | `notify` | `needs-you add`, titled by `error_type` (rate limit, sign-in, billing, API error, ...) |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | `resolve` | `needs-you resolve`, only if this session posted something. A reply that comes while a card is still being posted (a slow hub) resolves it once it's up |
| `Stop` | `stop` | the same resolve (except an API-error card), then the context check below |
| `SessionStart` | `start` | remembers the model; after `/clear`, compaction or `/resume`, resolves this Claude process's earlier cards |
| `SessionEnd` | `end` | resolves the session's card and its context card |

Settings files written by an older installer call `resolve` for `Stop` and `SessionEnd`; that still works. Re-run the installer to get the new events.

- **Key:** `agent:<short-hostname>:<id>`, where `<id>` is `$ORCA_TERMINAL_HANDLE` if set, else the Claude `session_id`. Characters outside `A-Za-z0-9._-` become `_`. Re-posting the same key updates the item, so a session that asks five times shows one card.
- **Title:** what's needed plus the project, e.g. `Claude wants to run git: my-repo`, `Claude wants approval for a plan: my-repo`, `Claude asks “Which database should we use?”: my-repo`, `Claude finished: Login fix (my-repo)` or `Claude asks: Should I also update the migration? · Login fix (my-repo)`. The project is the basename of `$CLAUDE_PROJECT_DIR` (else `cwd`); the session's name, when it has one, goes before it: the latest `/rename` (a `custom-title` line in the transcript), else the `session_title` of the latest prompt (`UserPromptSubmit`), else Claude's auto title (`ai-title`), read from `transcript_path`. What's found is kept in `~/.local/state/needs-you/claude-hooks/.title-<session>` (private, removed at `SessionEnd`) with the byte offset read up to, so a card reads only what Claude appended since and the transcript is read whole at most once. `tool_input` can hold secrets, so a permission card names the tool and at most the program (the first word of a `Bash` command that isn't a `VAR=value`, a flag or a wrapper like `sudo`, as a basename matching `[A-Za-z][A-Za-z0-9._+-]*`) or the file's basename, never the command line or content.
- **Questions and plans:** an `AskUserQuestion` card has each question under its header in the body with its choices listed, and the same as the item's `question` field ([API.md](../../docs/API.md)); an older CLI without `--question-json` gets the choices as read-only steps (at most 10, `+N more choices` past that); an `ExitPlanMode` card has the plan's first 12 lines. This text is the agent's words to you, not tool input: it is cleaned (no control or bidi characters), anything token-shaped (`ny_`/`nyi_` tokens, `sk-`, `ghp_`, bearer headers, `password=` values, long hex or base64 runs, private keys) becomes `[redacted]`, and it's clamped to the hub's limits. `NEEDS_YOU_AGENT_QUESTIONS=0` keeps it off the card. Its choices are buttons on the Mac when the card can show the question exactly (see `ask` under Guarantees). An MCP server's `elicitation_dialog` message and an API error message are redacted the same way.
- **Finished turns:** `idle_prompt` (about a minute after a turn, none if you type first) reads the transcript's last main-thread assistant text. When its last line ends with "?" (outside code or a table), the card is `Claude asks: <the last sentence or sentences that end it> · <session>` with that paragraph in the body; anything else (a statement, a tool call, an interruption, a synthetic message) is `Claude finished: <session> (<project>)`. The whole text is redacted before it is split or cut, and a name with anything token-shaped in it is left out. `NEEDS_YOU_TURN_TEXT=0` keeps `Claude is waiting for you: my-repo` and no names.
- **Body:** Claude's notification message (trimmed to 400 characters), the working directory and host, where the session runs (the tmux pane as `session:window.pane` and the terminal it runs in, `VS Code` or `Cursor` with the workspace Claude Code is connected to (`<config dir>/ide/<CLAUDE_CODE_SSE_PORT>.lock`: only `workspaceFolders` and `ideName` are read), the terminal app from `TERM_PROGRAM` and similar variables, or `SSH`), and the short session id. In Orca, instead: the worktree path (from `$ORCA_WORKTREE_ID`) and the command that jumps to the terminal, `orca terminal switch --terminal <handle>` (plus `--environment <name>` when `NEEDS_YOU_ORCA_ENVIRONMENT` is set). No prompt text, transcript or tool input is sent.
- **Links:** in Orca, an **Orca** link, `needsyou://orca/terminal?handle=<handle>[&environment=<name>]`, which the Mac app shows as a button that runs the same switch and brings Orca forward, and no editor links (unless `NEEDS_YOU_AGENT_LINK` asks for one): Orca is where the session lives. Outside Orca, a **Terminal** link to the Mac terminal tab, `needsyou://terminal/focus?app=<app>&<id>` (formats in [docs/API.md](../../docs/API.md#post-v1items-sender)):
  - On the Mac: inside tmux, `app=tmux&pane=<n>` from `$TMUX_PANE` plus `host=<iterm|wezterm|ghostty|terminal>` when the environment shows which terminal tmux runs in; else `app=wezterm&pane=$WEZTERM_PANE`; else `app=iterm&session=<UUID>` from `$ITERM_SESSION_ID`; else, in Terminal.app, `app=terminal&tty=/dev/ttys<n>` (the Claude process's tty); else `app=ghostty` in Ghostty. None inside VS Code.
  - Over SSH (or on any host other than the Mac): only from `LC_NEEDS_YOU_TERM`, which the Mac's shell sets and ssh forwards ([setup](../../docs/guides/claude-code-everywhere.md#terminal-button)). The remote's own tmux or WezTerm variables name panes on the remote, so they're never used.
  - Every value is checked against the same patterns the Mac app uses; anything else means no link. They're ids only (a pane number, a session UUID, a tty).

  A hub too old to accept a `needsyou://` link gets the card without it. Without `NEEDS_YOU_AGENT_LINK`, the hook adds editor links itself:
  - `Claude=vscode://anthropic.claude-code/open?session=<id>` when the session runs in the VS Code extension (`CLAUDE_CODE_ENTRYPOINT=claude-vscode`). The URI handler is documented in [Claude Code in VS Code](https://code.claude.com/docs/en/vs-code#launch-a-vs-code-tab-from-other-tools): it focuses the conversation's tab if it's open, else resumes it; the session must belong to the workspace open in the focused window.
  - `VS Code=vscode://file<cwd>` on macOS outside SSH (the folder exists on the Mac).
  - `VS Code=vscode://vscode-remote/ssh-remote+<alias><cwd>` elsewhere, when `NEEDS_YOU_SSH_ALIAS` is set.
  - `NEEDS_YOU_AGENT_LINK` (a template) replaces these; `NEEDS_YOU_AGENT_LINK=none` drops them.
- **Source:** `--agent claude-code --project <project>`; the CLI adds the host. `--event` says what the card is ([source.event](../../docs/API.md#post-v1items-sender)), for the Mac's alert rules ("Treat as urgent only when it asks"): `approval` for a permission prompt or plan, `question` for a question (`AskUserQuestion`, an MCP elicitation, `agent_needs_input`, or a finished turn that ends on one), `finished` for any other finished turn, `failed` for `StopFailure`, the usage limit and an MCP sign-in, `context` for the context card. Every agent the hook serves (Codex, Gemini CLI, opencode, Copilot CLI, Kimi Code, Grok, Cursor, Cline, Aider) gets the same events. A CLI older than `--event` refuses it; the hook then posts without it.

**Context card.** On `Stop`, the hook reads the tail of `transcript_path` (256 KB, then up to 2 MB; never the whole file) for the newest assistant message that isn't a subagent's, and adds its `usage` `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. A `compact_boundary` record after it counts as 0. The window is `NEEDS_YOU_CONTEXT_WINDOW`, else 1,000,000 when a model name has `[1m]` (the `SessionStart` input's `model`, kept in a state file, then `ANTHROPIC_MODEL`, then `model` in `~/.claude/settings.json`; the transcript's model id has no suffix) or the usage is over 200,000, else 200,000. At `NEEDS_YOU_CONTEXT_ALERT_PCT` percent (default 80) or more it posts `agent:<host>:<id>:context`, priority `low`, with the percentage and the `/compact` or `/clear` suggestion, and re-posts only when the percentage moved 5 points. Below the threshold it resolves the card. Claude Code's hook input has no usage field, so this is the only source. The check starts `python3` once per turn in opted-in sessions; `NEEDS_YOU_CONTEXT_ALERT_PCT=0` skips it.

The resolve side keeps a marker file per session in `~/.local/state/needs-you/claude-hooks/`, so `Stop` and `PostToolUse` (which fire constantly) cost a file check and no network call unless there is something to resolve.

A killed session (closed terminal, `kill`, reboot, OOM) never sends `SessionEnd`, so two things clean up after it:

- **Lease:** the marker records the key, the Claude process id and its start time. `needs-you flush`, which the installer schedules every 5 minutes, resolves the card once that process is gone or its pid belongs to a newer process. Markers written by older hooks have no lease and are left alone.
- **Expiry:** each card expires 48 hours after its last post (`NEEDS_YOU_AGENT_EXPIRY_HOURS`), for a machine that never comes back to run the flush. A gated-off event costs about 5 ms of bash and never starts Python.

### Settings

Set these in the environment or as lines in `~/.config/needs-you/env` (the environment wins):

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AGENT_ALERTS` | unset | `1` opts in, `0` opts out (see above) |
| `NEEDS_YOU_AGENT_CONTEXT` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | `work` or `personal` |
| `NEEDS_YOU_AGENT_PRIORITY` | `normal` | `urgent`, `normal` or `low` |
| `NEEDS_YOU_AGENT_LINK` | unset (automatic editor links) | One link instead, `Label=url-template`. Placeholders: `{handle}`, `{session}`, `{cwd}`, `{host}` (URL-encoded). A template using `{handle}` is skipped outside Orca. `none`: no editor links. |
| `LC_NEEDS_YOU_TERM` | unset | On an SSH host: the Mac terminal tab, as the link's query (`app=iterm&session=<UUID>`, `app=wezterm&pane=<n>`, `app=terminal&tty=/dev/ttys<n>`, `app=tmux&pane=<n>[&host=<terminal>]`). Set in the Mac's shell, never on the host |
| `NEEDS_YOU_SSH_ALIAS` | unset | This host's name in the Mac's `~/.ssh/config` / Remote-SSH list; adds the Remote-SSH folder link |
| `NEEDS_YOU_CONTEXT_ALERT_PCT` | `80` | Context card threshold in percent; `0` turns it off |
| `NEEDS_YOU_CONTEXT_WINDOW` | `200000` (`1000000` for `[1m]` models) | Context window in tokens |
| `NEEDS_YOU_AGENT_EXPIRY_HOURS` | `48` | A card expires this many hours after its last post; `0` never expires |
| `NEEDS_YOU_ORCA_ENVIRONMENT` | unset | On a paired Orca server: the name the Mac's Orca gives it (`orca environment list`), so the jump command finds the terminal. Without it, the Mac app's Orca button tries each paired environment in turn. |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | CLI path |
| `NEEDS_YOU_HOOK_LOG` | unset | Append one debug line per call to this file |

Link examples:

```bash
# Orca cards already get an Orca button (needsyou://orca/terminal?...);
# Orca itself has no terminal or worktree deep link (1.4.220).

# On a VM you open with VS Code Remote-SSH: the automatic link needs only the
# SSH host name VS Code on the Mac uses ({cwd} is the session's folder; if the
# window has a different folder open, VS Code opens a new window).
NEEDS_YOU_SSH_ALIAS=devbox

# Cursor instead of VS Code on the Mac
NEEDS_YOU_AGENT_LINK='Cursor=cursor://file{cwd}'
```

### Guarantees

- Every hook exits 0 and writes nothing to stdout, so it can never block a tool call, stop Claude from stopping, or inject text into the conversation. The one exception is `ask`, below.
- Every hook but `ask` is registered with `"async": true` and a 30 s timeout, so Claude never waits on the network. The CLI itself queues to its outbox when no hub answers.
- `ask` (ADR 0009 B3) is synchronous, with a timeout (3660 s) past the longest answer wait. Claude Code shows its own question dialog while it runs (measured on 2.1.294), so nobody waits on it: the person answers in the terminal or on the card, and the first answer wins. Its only output is Claude's decision for a click on the card, `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow", "updatedInput": {<the tool input>, "answers": {"<question>": "<label>"}}}}}` (a "choose any" question's labels joined with ", "; words typed on the Mac after **Other…** in place of a single choice's label, or after a "choose any" question's labels), and only after checking the click against the question: the same question id, one entry per question, only labels Claude offered, one label or the typed words for a single choice, words that are one line of 1-1,000 characters without control characters. The card marks every question `allow_other`, since Claude's dialog always offers "Other". Nothing is printed on a timeout, an error or with `NEEDS_YOU_ANSWER_TIMEOUT=0`. An answer in the terminal resolves the card (`PostToolUse`), which ends the wait at once. Permission prompts and plans are never answered.
- Untrusted text (Claude's message, paths) is passed to the CLI as an argument list from Python, never through shell quoting.

### Doing it by hand

`hooks.json` is the exact block the installer merges, with user-level paths. To install manually: copy `needs-you-hook.sh` to `~/.claude/hooks/`, `chmod +x` it, and merge the `hooks` object into `~/.claude/settings.json`, appending to any event arrays you already have.

### Troubleshooting

```bash
# Simulate a permission prompt (fake session id)
echo '{"session_id":"test-1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify

# ...and its resolve
echo '{"session_id":"test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh resolve
```

If nothing shows up, see [troubleshooting](../../docs/guides/troubleshooting.md#claude-code-hooks).

## Usage meter

With `needs-you-usage` as your status line (installed as below), the Mac app shows Claude's
session (5-hour) and weekly limits as two bars in the panel, and as a hairline meter on the
pill (Settings → Usage). The helper sends both percentages and reset times to the hub as a
quiet **usage status** (`needs-you status set --key usage:claude ...`; [API](../../docs/API.md#status-records-usage-meters)):
never a card, never counted. It goes out when a number changed (at most every 15 s) and every
5 minutes otherwise, detached, so the status line never waits; a status is never queued, so
with no hub reachable nothing is sent. With `NEEDS_YOU_USAGE_ACCOUNT` set the key is
`usage:claude:<account>` and the Mac shows a row per account. `NEEDS_YOU_USAGE_METER=0` turns
the meter off. Codex gets the same meter from its Stop hook ([integrations/codex](../codex/README.md#what-gets-posted)).

## Usage-limit card (optional)

`needs-you-usage` posts one low `info` card when your Claude subscription's 5-hour or weekly limit passes a threshold you set, for example **Claude weekly limit 85% used: resets Thu 09:00**. It is off until you set `NEEDS_YOU_USAGE_ALERT_PCT`.

Its only source is Claude Code's status line input: for claude.ai Pro and Max subscribers, after the session's first response, Claude Code passes `rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at`) to the status line command ([status line docs](https://code.claude.com/docs/en/statusline)). The helper reads those numbers and nothing else: no credentials, no transcript, no network of its own. With an API key there is no `rate_limits`, and it does nothing.

Install it with the invite link's one-liner by adding `--usage` (it goes next to the CLI as `~/.local/bin/needs-you-usage`, and `needs-you update` keeps it current), or from a checkout:

```bash
cp integrations/claude-code/needs-you-usage ~/.local/bin/ && chmod +x ~/.local/bin/needs-you-usage
```

Then make it your status line, wrapping the one you already have (its output passes through unchanged and its exit status is kept). The installer never edits the status line for you:

```json
"statusLine": {"type": "command", "command": "~/.local/bin/needs-you-usage -- ~/.claude/statusline.sh"}
```

With no status line of your own, `~/.local/bin/needs-you-usage --print` shows `5h 23% · 7d 41%`.

Then in `~/.config/needs-you/env`:

| Variable | Default | What |
|---|---|---|
| `NEEDS_YOU_USAGE_ALERT_PCT` | unset (off) | 5-hour threshold in percent |
| `NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT` | the 5-hour value | Weekly threshold; `0` turns the weekly card off |
| `NEEDS_YOU_USAGE_ACCOUNT` | none | A label (letters, digits, `.` `_` `-`) for a machine with more than one Claude login, e.g. per `CLAUDE_CONFIG_DIR`; it goes in the key and the title, and labels the meter. Never an email. In an Orca terminal on an Orca WSL account (its own `CLAUDE_CONFIG_DIR` in Orca's `claude-accounts/<id>/auth`) the label is `orca-<8 hex>` instead, as `needs-you orca usage` labels that account |
| `NEEDS_YOU_USAGE_METER` | on | `0`: don't send the usage meter status |

Codex gets the same card from these settings through its hooks (read from its session file; see [integrations/codex](../codex/README.md#what-gets-posted)).

The card is keyed `agent:<host>:claude-usage[:<account>]:5h` (or `:7d`), so every session on the machine updates the same one. It expires when the window resets, is re-posted only when the percentage moved 5 points, and is resolved when usage is back under the threshold. The post runs detached, so the status line never waits on the hub. State is in `~/.local/state/needs-you/usage/`.

## Skill

```bash
mkdir -p ~/.claude/skills
cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
```

Or put it in one repo at `<repo>/.claude/skills/needs-you/`. Claude loads it when it's blocked on you or finishing something you're waiting for. It's a condensed [`docs/AGENT-GUIDE.md`](../../docs/AGENT-GUIDE.md). If your project uses its own key prefixes (for example `acme:` for work items), say so in the repo's `CLAUDE.md`.
