# Next agent integrations: Kimi Code, Grok Build, Cline, Cursor, Aider

Status: research, 2026-10-07. GitHub Copilot CLI, researched separately, is supported now ([guide](../guides/copilot.md)), and so are Cursor ([guide](../guides/cursor.md)), Cline ([guide](../guides/cline.md)) and Aider ([guide](../guides/aider.md)), built from this page; their guides say what changed from the plan here. Kimi Code and Grok Build are not built yet.

The existing agent integrations (Claude Code, Codex, Gemini CLI, opencode) all share `integrations/claude-code/needs-you-hook.sh`: a **waiting card** goes up when the agent asks for approval or input or ends its turn (`notify`), and comes down when the person answers or the agent moves on (`resolve`), when a conversation is replaced (`start`), or when the session ends (`end`). There is one card per wait, keyed `agent:<host>:<session id>`. The hook always exits 0, never prints to stdout, and backgrounds itself where the agent waits on hooks. This page checks five more agents against that model, using their docs, their source, and live runs where possible.

How each claim was checked, and its confidence:

- **live**: run in a throwaway `HOME` against a local stub model server on loopback, with a hook that dumped stdin and env. The binaries were downloaded into a scratch directory; nothing was installed globally. High confidence.
- **source**: read in the agent's source at the commit listed. High confidence for that version.
- **docs**: official docs only. Medium confidence.
- **forum**: vendor forum or third-party reports. Low confidence.

## Ranking

| # | Agent | Waiting signal | Resume signal | Session id | Fidelity | Value | Notes |
|---|---|---|---|---|---|---|---|
| 1 | **Kimi Code CLI** | `PermissionRequest` (live), `Stop` (live), `PreToolUse` matcher `AskUserQuestion` | `PermissionResult`, `UserPromptSubmit`, `PostToolUse`, `Interrupt`, `SessionEnd` | `session_id` (snake_case, live) | Same as Codex or better | High | The closest match to our model. `Stop`/`PreToolUse`/`UserPromptSubmit` are awaited, so the hook must background itself, like the Gemini path |
| 2 | **Grok Build** (xAI `grok`) | `Notification` `permission_prompt` (docs), `idle_prompt` (live, about 60 s after the turn), `Stop` reason `end_turn` (live), `StopFailure` | `UserPromptSubmit`, `PostToolUse`, `StopCancelled`, `SessionEnd` (live) | `session_id` **and** `sessionId` (live) | High | High, **and urgent**: Grok already runs our Claude hooks (below) | No `PermissionRequest` event. Fix the misattribution first |
| 3 | **Cline** (VS Code extension and `cline` CLI) | `TaskComplete` only (source) | `UserPromptSubmit`, `TaskStart`, `TaskResume`, `TaskCancel`, `SessionShutdown` (CLI) | `taskId` | Medium: a "finished" card only, no approval card | Medium | Hooks are executables named after the event, in `~/Documents/Cline/Hooks/` |
| 4 | **Cursor** (IDE agent, `cursor-agent` CLI) | `stop` (`status: completed`) | `beforeSubmitPrompt`, `sessionEnd` | `conversation_id` (`session_id` only on session events) | Low: no approval event | Low to medium: the IDE already notifies | Already runs our Claude hooks, harmlessly (below) |
| 5 | **Aider** | `--notifications-command`: one run, no args, no stdin, when Aider waits after an LLM reply (live) | none | none (use the Aider pid + cwd) | Low: the card can't clear on reply | Low | Aider waits for the command (sync `subprocess.run`), so it must background itself |

Suggested order: **Grok's hook detection first** (a small change to the shared hook; it fixes cards that some users already get with the wrong label), then Kimi, Grok's own install, Cline, Cursor, and Aider last.

## Cross-cutting finding: Grok and Cursor already run our Claude hooks

Both tools read Claude Code hook files by default.

- **Grok Build** loads `~/.claude/settings.json` (and `settings.local.json`, plus project `.claude/settings.json` once the folder is trusted). It is on by default and turned off with `[compat.claude] hooks = false` or `GROK_CLAUDE_HOOKS_ENABLED=0` (docs, live: `grok inspect` listed our four supported Claude entries as `user [claude]`, and they fired). Grok skips event names it doesn't know (`PermissionRequest`), and runs `Notification` (with our `permission_prompt|idle_prompt|…` matcher tested against its notification type), `Stop`, `StopFailure`, `UserPromptSubmit`, `PostToolUse`, `SessionStart` and `SessionEnd`.
  - **Result today (inferred from live payloads and the hook source):** a Grok session on a machine with our Claude hooks and alerts on gets a **"Claude needs you"** card about a minute after each turn, keyed by the Grok session id and resolved on the next prompt. It is mislabelled because Grok sends `notificationType` but **no `notification_type`** (live), and the hook runs with `agent=claude`.
  - `stop` mode runs the Claude context check against `transcript_path`, which in Grok is Grok's own `updates.jsonl`, not a Claude transcript. It is probably a no-op, but this isn't verified.
  - The hooks.json `async: true` key is Claude's. Whether Grok honors it is not documented (the live runs only show about 30 ms per hook), so assume Grok waits, with our `timeout: 30`. `Stop` is on the turn's critical path in Grok.
  - **Fix (shared hook, small):** when `GROK_HOOK_EVENT` is in the environment, switch `agent` to `grok` whatever the argument says. Read `notificationType` as well as `notification_type`, and background the work, as the Gemini path does. A separate `~/.grok/hooks/needs-you.json` is then only needed on machines without the Claude hooks. If both are installed, both post the same key, so the card is the same but posted twice; the grok-specific file could skip when `~/.claude/settings.json` holds a `needs-you-hook.sh` entry.
- **Cursor** loads `~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json` when **Settings → Agents → Third-Party Imports → "Include Third-Party Plugins, Skills, and Other Configs"** is on, which is the default (docs). It maps only `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd` and `PreCompact`. `Notification` and `PermissionRequest` are not supported. Our Claude entries therefore only ever run `resolve`, `stop`, `start` and `end`, so **no card is posted**. Cursor's payloads carry `conversation_id`, and `session_id` only on session events, so most runs exit early with "no session id". Harmless, but they cost a hook spawn per prompt and tool call.

## Kimi Code CLI

The current product is **Kimi Code CLI** (`MoonshotAI/kimi-code`, TypeScript, `kimi` command, 2.1.1). The older Python `kimi-cli` (`~/.kimi/config.toml`) is archived ("no longer maintained", per its `pyproject.toml`). It had 13 hook events and **no** `PermissionRequest`, so target Kimi Code only. `kimi migrate` carries legacy hooks over.

**Config** (docs, source): `[[hooks]]` array of tables in `~/.kimi-code/config.toml`, or `$KIMI_CODE_HOME/config.toml` (source: `resolveKimiHome`). An entry allows exactly four keys, `event`, `matcher` (regex), `command` (run with `shell: true`, cwd = the session's project dir) and `timeout` (seconds, 1 to 600, default 30). **Any extra key makes the config fail to load** (docs), so no `_needs_you_version` marker key; use a comment line. Identical `command` strings on one event run once. Plugins can also ship hooks in their manifest (plugin hooks get `KIMI_CODE_HOME` and `KIMI_PLUGIN_ROOT` in their env), which is a possible distribution channel.

```toml
# needs-you (managed by install-kimi-hooks.sh; do not edit between these markers)
[[hooks]]
event = "PermissionRequest"
command = "\"$HOME/.kimi-code/hooks/needs-you-hook.sh\" notify kimi"
timeout = 10

[[hooks]]
event = "Stop"
command = "\"$HOME/.kimi-code/hooks/needs-you-hook.sh\" notify kimi"
timeout = 10
# ... PermissionResult/UserPromptSubmit/PostToolUse/Interrupt -> resolve, SessionStart -> start, SessionEnd -> end
# end needs-you
```

Appending `[[hooks]]` tables at the end of a TOML file is always valid, so the installer can do it without a TOML parser (Python 3.9 has no `tomllib`). It removes its own block by the marker comments. Run `kimi doctor` to validate the result.

**Payload** (live, Kimi Code 2.1.1): JSON on stdin, all keys snake_case (source: `camelToSnake`). Every event has `hook_event_name`, `session_id` (`session_<uuid>`), `cwd` and `client_type` (`kimi_code_cli`), and `session_title` once the session has one.

| Event | Fires | Extra fields (live unless marked) | Blocks? | Our mode |
|---|---|---|---|---|
| `PermissionRequest` | Just before waiting for approval | `id` (`approval_<uuid>`), `agent_id`, `turn_id`, `tool_call_id`, `tool_name` (`Bash`), `action` (`"Running: touch probe.txt"`), `display` {`kind`, `command`, `cwd`, `description`, `language`}, `tool_input` | No, fire-and-forget (source) | `notify` (title from `tool_name` and the first word of `display.command`; never `action` or the full command) |
| `PermissionResult` | Approval answered | As above, plus `decision` (`approved`/`rejected`/`cancelled`/`error`), `scope`, `feedback` | No | `resolve` |
| `Stop` | The turn is about to end | `stop_hook_active` | **Yes**: awaited, and exit 2 or JSON can keep the agent working | `notify` (turn ended; honor `NEEDS_YOU_AGENT_TURN_CARDS`). **Must background and print nothing** |
| `UserPromptSubmit` | The person sends a message | `prompt` (content parts), `is_steer` | **Yes**: awaited; stdout may be appended to context | `resolve`, backgrounded, silent |
| `PostToolUse` / `PostToolUseFailure` | After a tool | `tool_name`, `tool_input`, `tool_call_id`, `tool_output` (2000 chars) / `error` | No | `resolve` |
| `Interrupt` | Esc interrupts the turn (fires instead of `Stop`) | `turn_id`, `reason` (source) | No | `resolve` |
| `StopFailure` | The turn failed on an error | `error_type`, `error_message` (source) | No | `notify` (failure card, as for Claude) |
| `SessionStart` | Start or resume | `source` (`startup`/`resume`), `model`, `profile` | Awaited (source: `waitUntil`) | `start` |
| `SessionEnd` | Exit or archive | `reason` (`exit`/`archive`) | Awaited | `end`. Did not fire when the live TUI was killed with Ctrl-C/SIGTERM, so rely on the lease |
| `PreToolUse` matcher `AskUserQuestion` | The agent asks the person a question (the tool is auto-approved, so no `PermissionRequest`; source: `default-tool-approve.ts`) | `tool_name`, `tool_input`, `tool_call_id` | **Yes**: awaited | `notify` ("Kimi asked you a question"), backgrounded; its `PostToolUse` resolves |
| `SessionHeartbeat` | Every 60 s while the session is alive, only if configured | `uptime_ms` | No | Not needed; it could refresh a lease |

Exit codes (docs, source): 0 allows, 2 blocks blockable events, anything else, a timeout or a crash fails open. Hook processes get their own process group and SIGTERM, then SIGKILL after 100 ms on timeout (source), so the background copy must `setsid`/detach or it is killed with the group. **Gap:** the hook's existing Gemini backgrounding (`&` with stdio closed) may not survive a group kill. Test it.

**Distribution:** single binary via `curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash` (into `~/.kimi-code/bin`, sha256 from a manifest), Homebrew `kimi-code`, or npm `@moonshot-ai/kimi-code` (needs Node 22.19 or later). **Live test: works headless.** `KIMI_CODE_HOME=<tmp>` with a `[providers.x] type = "openai"` entry and `base_url` pointing at a loopback stub, then `kimi -p "…"`, fires `SessionStart`/`UserPromptSubmit`/`TurnStarted`/`PreToolUse`/`PostToolUse`/`Stop`. `-p` uses auto permission, so testing `PermissionRequest` needs the TUI in a pty (done; `Esc` rejected it, and `PermissionResult` then `Stop` followed).

## Grok Build (xAI `grok`)

Not to be confused with the community `superagent-ai/grok-cli` (npm `grok-dev`), which also uses `~/.grok/` but keeps its hooks under `hooks` in `~/.grok/user-settings.json`, with snake_case events and no permission or idle event. Its last commit was in May 2026. Not worth targeting.

**Config** (docs, live): every `~/.grok/hooks/*.json` (or `$GROK_HOME/hooks/`) is loaded and always trusted. Also loaded: `[[hooks.<Event>]]` tables in `~/.grok/config.toml`, project `.grok/hooks/*.json` once the folder is trusted, plugins, and the Claude and Cursor files above. The format is Claude's, with `type` `command` or `http`, plus `timeout` and `env`. The default timeout is **5 s**, and 600 s for `Stop`/`SubagentStop`/`PostToolUse`. Inspect with `grok inspect` and `/hooks`. Per-hook disables live in `~/.grok/disabled-hooks`. `allow_managed_hooks_only` in a managed `requirements.toml` turns user hooks off. `needs-you doctor` should report that.

```json
{
  "hooks": {
    "Notification": [{ "matcher": "permission_prompt|idle_prompt", "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" notify grok", "timeout": 10 }] }],
    "Stop":        [{ "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" notify grok", "timeout": 10 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" resolve grok", "timeout": 10 }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" resolve grok", "timeout": 10 }] }],
    "StopCancelled": [{ "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" resolve grok", "timeout": 10 }] }],
    "SessionEnd":  [{ "hooks": [{ "type": "command", "command": "\"$HOME/.grok/hooks/needs-you-hook.sh\" end grok", "timeout": 2 }] }]
  }
}
```

**Payload** (live, grok 1.0.46): **both** camelCase (`hookEventName` with a snake value, e.g. `stop`; `sessionId`; `cwd`; `workspaceRoot`; `timestamp`; `permissionMode`; `promptId`; `transcriptPath`) **and** Claude aliases (`hook_event_name` with the Pascal value, e.g. `Stop`; `session_id`; `permission_mode`; `transcript_path`; and on tool events `tool_name`/`tool_input`/`tool_use_id`). The aliases are not complete: `Notification` has only `notificationType`, `message` and `level`, with no `notification_type` (live). Env on every hook: `GROK_HOOK_EVENT` (snake event), `GROK_HOOK_NAME`, `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT`, `CLAUDE_PROJECT_DIR` (docs, live).

| Event | Fires | Extra fields | Blocks? | Our mode |
|---|---|---|---|---|
| `Notification` `permission_prompt` | An approval prompt is showing | `notificationType`, `message`, `level` (docs; live only for `idle_prompt`. In live runs `echo` and `touch` were auto-approved as safe, so no prompt appeared) | No | `notify` (title "Grok needs permission"; the tool name is not in this payload, so a richer title would need the preceding `PreToolUse`) |
| `Notification` `idle_prompt` | About **60 s** after the session settles; cancelled if the person types first; also after interrupted or failed turns (docs, live: 60 s after `Stop`) | `notificationType: "idle_prompt"`, `message: "Waiting for your next prompt"`, `level: "info"` | No | `notify` (waiting) |
| `Stop` | The turn ended (`reason: "end_turn"`), **and again at session end** (`reason: "shutdown"`, after `SessionEnd`) | `reason`, `stopHookActive`, `lastAssistantMessage` (never put in a card), `backgroundTasks`, `sessionCrons` | **Yes** (a gate; exit 2 keeps the agent working) | Either `notify` only when `reason == "end_turn"`, or leave `Stop` out and use `idle_prompt` (one card, 60 s later, and none if the person is already typing). Pick one (open question) |
| `StopFailure` | API error | `error` (`rate_limit`, `authentication_failed`, …), `errorDetails` | No | `notify` (failure) |
| `StopCancelled` | Interrupt, declined or dismissed permission, `max_turns`, `no_progress` | `reason`, `cancelledBy`, `cancelTrigger` | No | `resolve` |
| `UserPromptSubmit` | Prompt sent | `prompt`, `promptId` | Yes | `resolve` |
| `PostToolUse` | After a tool (also after an approved prompt) | `toolName`, `toolInput`, `toolResult` (+ `tool_response` alias) | Output is read | `resolve` |
| `SessionStart` | New, resume | `source` (`new` live; docs: `startup`, `resume`, …) | No | `start` |
| `SessionEnd` | Shutdown | `reason` (`shutdown`), `subagentType` for child sessions | No (default limit 1.5 s, `GROK_SESSION_END_HOOKS_TIMEOUT_MS`) | `end`, backgrounded |
| `PermissionDenied` | The permission system denied a call | tool fields | No | Not needed |

Subagent sessions fire too, with `subagentType` set: skip those (docs). Exit codes: 0 allows; 2 denies `PreToolUse`, blocks `Stop` or feeds back on `PostToolUse`; anything else fails open (docs). **Never exit 2.** On `PostToolUse` it would hand stderr to the model.

**Distribution:** native binary via `curl -fsSL https://x.ai/cli/install.sh | bash` (into `~/.grok/bin`, `GROK_HOME` overrides `~/.grok`). **Live test: works headless and in a TUI.** Run with a temp `HOME` and a `[model.stub]` entry in `~/.grok/config.toml` with `base_url` at a loopback OpenAI-compatible stub and `env_key`. No xAI login is needed with a custom model. `grok -p … -m stub` fires session, prompt, tool, `Stop` and `SessionEnd` hooks. `script -qfc "grok -m stub 'prompt'"` gives the TUI and `idle_prompt`. `permission_prompt` still needs a command Grok does not consider safe.

## Cline

Cline has two hook runners that share file names. The **SDK/CLI** runner (`cline` on npm, 3.0.69; `sdk/packages/core/src/hooks/`) and the **VS Code extension** runner (`apps/vscode/src/core/hooks/`, bridged to the SDK in `apps/vscode/src/sdk/hooks-adapter.ts`).

**Config** (source): there is no config file. A hook is an **executable named after the event** in a hooks directory:

- Global: `~/Documents/Cline/Hooks/` (both runners), `~/.cline/hooks/` or `$CLINE_DIR/hooks/` (SDK/CLI), and `--hooks-dir <path>` (CLI).
- Workspace: `.clinerules/hooks/` (both) and `.cline/hooks/` (SDK/CLI).
- Names: `TaskStart`, `TaskResume`, `TaskCancel`, `TaskComplete`, `TaskError` (SDK only), `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `PreCompact` (not wired), `SessionShutdown` (SDK only). The SDK accepts `.sh/.py/.js/…` or no extension. VS Code looks for **no extension** on macOS/Linux (`.ps1` on Windows), so install extension-less files.
- VS Code's "Enable Hooks" setting now defaults to on (`getHooksEnabledSafe(undefined) === true`).

A minimal hook, `~/Documents/Cline/Hooks/TaskComplete` (mode 755):

```bash
#!/bin/sh
exec "$HOME/.config/needs-you/hooks/needs-you-hook.sh" notify cline
```

**Payload** (source; camelCase): `clineVersion`, `hookName`, `timestamp`, **`taskId`** (the conversation id, used as the session id), `workspaceRoots`, `userId`, plus per-event objects. SDK payloads also have `sessionContext.rootSessionId`, `workspaceInfo` (git branch, commit), `agent_id` and `parent_agent_id` (skip when `parent_agent_id` is set: subagent). VS Code `TaskComplete` carries `taskComplete.taskMetadata.result` (the agent's final text: never put it in a card).

| Hook | Fires | Blocks? | Our mode |
|---|---|---|---|
| `TaskComplete` | The run completed (SDK: `afterRun` status `completed`; VS Code: same) | SDK: detached, not awaited. VS Code: awaited, 30 s limit | `notify` ("Cline finished", the only waiting signal) |
| `TaskCancel` | The run was aborted | Same | `resolve` |
| `UserPromptSubmit` / `TaskStart` / `TaskResume` | The person sends a message or starts or resumes a task | `TaskStart`/`TaskResume` may cancel the run via JSON `{"cancel": true}`; `prompt_submit` cannot (SDK) | `resolve` (print nothing; VS Code treats "no JSON" as allow) |
| `TaskError` (SDK) | The run failed | No | `notify` (failure) |
| `SessionShutdown` (SDK) | The CLI session ends | No | `end` |

**Gap:** Cline waits for approvals (`ask` messages) without any hook. VS Code lists a `Notification` hook type, but the adapter marks it "deferred, not wired". So there is no approval card, and a long run that stops on an approval looks "running" until `TaskComplete`.

**Distribution:** VS Code Marketplace / Open VSX extension; CLI `npm install -g cline` (to test, install into a scratch prefix instead). Live test is possible for the CLI with a temp `HOME`/`CLINE_DIR` and an OpenAI-compatible provider pointed at a stub (not done here). The extension needs a VS Code instance.

## Cursor

**Config** (docs): `~/.cursor/hooks.json` (user hooks run from `~/.cursor/`, so use `./hooks/…` paths), `<project>/.cursor/hooks.json`, and enterprise or team files. `{"version": 1, "hooks": {"<event>": [{"command": "...", "timeout": N, "matcher": "..."}]}}`. Cursor watches the file and reloads it.

```json
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "./hooks/needs-you-hook.sh notify cursor", "timeout": 10 }],
    "beforeSubmitPrompt": [{ "command": "./hooks/needs-you-hook.sh resolve cursor", "timeout": 10 }],
    "sessionEnd": [{ "command": "./hooks/needs-you-hook.sh end cursor", "timeout": 10 }]
  }
}
```

**Payload** (docs): every hook gets `conversation_id`, `generation_id`, `model`, `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email` (**personal data: never put it in a card**) and `transcript_path`. Env: `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`, `CLAUDE_PROJECT_DIR`.

| Event | Extra fields | Blocks? | Our mode |
|---|---|---|---|
| `stop` | `status` (`completed`/`aborted`/`error`), `loop_count` | Awaited (its `followup_message` output re-prompts the agent) | `notify` on `completed` (and `error` as a failure card), `resolve` on `aborted`. Print nothing or `{}` |
| `beforeSubmitPrompt` | `prompt`, `attachments` | Can block via `{"continue": false}` | `resolve`. Whether empty output is treated as "continue" is not documented; print `{"continue": true}` to be safe (cursor mode only) |
| `sessionEnd` | `session_id` (= `conversation_id`), `reason` (`completed`/`aborted`/`error`/`window_close`/`user_close`), `duration_ms`, `is_background_agent` | Fire-and-forget | `end` |
| `sessionStart` | `session_id`, `is_background_agent`, `composer_mode` | Fire-and-forget | `start` (optional) |

**Do not register permission hooks** (`preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `subagentStart`). For those, "invalid JSON or a response that doesn't match the hook's schema blocks the action" (docs). Our silent hook would block every tool call. **Gap:** no event for "waiting for approval", so only a turn-finished card. Key by `conversation_id`. Skip `is_background_agent` sessions. Cloud agents never see user hooks.

**Distribution:** desktop app, and the `cursor-agent` CLI. In the CLI, `stop` is reported to fire in `--print` mode, but some events don't fire and one recent build reportedly ran no user hooks at all (forum). A live test needs a Cursor login, because there is no custom-model endpoint to stub. Not done.

## Aider

**Config** (source, docs): `--notifications --notifications-command "<cmd>"`, or `notifications: true` and `notifications-command: <cmd>` in `~/.aider.conf.yml` (also the repo root and cwd), or `AIDER_NOTIFICATIONS=true` and `AIDER_NOTIFICATIONS_COMMAND=…`. **Both** are needed: without `notifications` the command never runs.

**Behaviour** (source `aider/io.py`, live with aider 0.86.2 against a stub through `OPENAI_API_BASE`): after each LLM request (`llm_started()`), the next prompt Aider shows (the main input, `confirm_ask` such as "Run shell command?" or "Add file to the chat?", or `prompt_ask`) runs the command once via `subprocess.run(cmd, shell=True, capture_output=True)`. Aider **waits for it to exit**. The command gets **no arguments and no stdin**, the cwd is Aider's, and the env is inherited (`TMUX_PANE`, `TERM_PROGRAM`, `SSH_*`), so the hook's "where" and terminal links still work. A non-zero exit only prints a warning. Nothing tells the command whether Aider is asking a yes/no question or waiting for a new message, and nothing fires when the person answers.

**Mapping:** `notify aider` with a synthesized `{"hook_event_name":"Stop","session_id":"aider-<pid>","cwd":"$PWD"}` (the pid from walking `$PPID` past the shell). The hook must **background immediately**, or Aider stalls on the network call. Resolve paths are only the lease (`needs-you flush` resolves when the Aider pid exits), the expiry, or the next `notify` updating the same card in place. **Gap:** the card stays up while the person is already typing. Options: a short default `NEEDS_YOU_AGENT_EXPIRY_HOURS` for Aider, or a wrapper (`needs-you run aider …`) that resolves on exit. Low value for the work.

**Distribution:** `pip`/`pipx`/`uv tool install aider-chat` (Python 3.10 to 3.12). Live-testable in a scratch venv (done).

## What the shared hook would need

- New agent names: `kimi`, `grok`, `cline`, `cursor`, `aider`, plus `GROK_HOOK_EVENT` detection when invoked as `claude`.
- Field fallbacks: `notificationType` (Grok), `taskId` (Cline), `conversation_id` (Cursor), with `session_id` first. `hook_event_name` already works for Kimi, Grok and Cursor; Cline uses `hookName`; Aider has none (the hook would synthesize it).
- Backgrounding for every agent whose hooks are awaited (Kimi `Stop`/`UserPromptSubmit`/`PreToolUse`, Grok `Stop`, Cursor `stop`, Cline in VS Code, Aider). It must survive a process-group kill on Kimi's timeout (`setsid` where available; macOS has no `setsid` binary, so use `perl -e 'setsid'` or Python's `os.setsid`). This needs a test.
- Per-agent stdout rules: silent everywhere except Cursor's `beforeSubmitPrompt` (`{"continue": true}`).
- Titles: "Kimi wants to run make", "Grok needs permission", "Grok is waiting for you", "Cline finished", "Cursor finished", "Aider is waiting for you". As today, never the command line, prompt, `lastAssistantMessage`, `result` or `user_email`.
- Installers and `join-install.sh` flags (`--kimi-hooks`, `--grok-hooks`, `--cline-hooks`, `--cursor-hooks`, `--aider`) and `needs-you doctor` and `update` lines, following the Codex and Gemini pattern. These are out of scope here: other changes are in flight on those files.

## Open questions

1. Grok: card on `Stop` (`end_turn`, immediate) or on `idle_prompt` (60 s later, and skipped if the person replies first)? `idle_prompt` matches "only when they actually need you" better, but adds a minute of latency.
2. Grok: whether to rely on the Claude compatibility path when the Claude hooks are installed, or always install `~/.grok/hooks/needs-you.json` and make the Claude-path invocation exit when it sees `GROK_HOOK_EVENT` and the grok file exists.
3. Kimi: whether a backgrounded child survives the hook-timeout process-group kill. This needs a live check with a slow hub.
4. Cursor: whether `beforeSubmitPrompt` with empty output blocks the prompt. This needs a live check (requires a login).
5. Cline: whether the CLI's detached `TaskComplete` still runs when the CLI exits right after a one-shot task.

## Sources

Revisions checked: kimi-code `21406fb` (2026-09-30) and binary 2.1.1; legacy kimi-cli `9ab1286`; grok binary 1.0.46 (docs page dated 2026-07-02; the full hook reference also ships inside the binary); cline `faf05ef` (2026-10-07); aider `5dc9490` and 0.86.2; Cursor docs as of 2026-10-07.

- Kimi Code hooks doc: https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/customization/hooks.md
- Kimi Code plugin hooks: https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/customization/plugins.md
- Kimi Code source: https://github.com/MoonshotAI/kimi-code/tree/main/packages/agent-core-v2/src/features/externalHooks (`agent/agentExternalHooksService.ts`, `session/sessionExternalHooksService.ts`, `internal/matchHooks.ts`, `internal/runHook.ts`), `packages/agent-core-v2/src/agent/toolApproval/toolApprovalService.ts`, `packages/agent-core-v2/src/app/bootstrap/bootstrap.ts`
- Kimi Code install and CLI: https://github.com/MoonshotAI/kimi-code#install, https://github.com/MoonshotAI/kimi-code/blob/main/docs/en/reference/kimi-command.md, https://code.kimi.com/kimi-code/install.sh
- Legacy kimi-cli (archived): https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/hooks/config.py
- Grok Build hooks: https://docs.x.ai/build/features/hooks
- Grok Build settings: https://docs.x.ai/build/settings, https://docs.x.ai/build/settings/reference
- Grok Build overview and install: https://docs.x.ai/build/overview, https://x.ai/cli/install.sh
- Community grok-cli (not targeted): https://github.com/superagent-ai/grok-cli/blob/main/src/hooks/types.ts
- Cursor hooks: https://cursor.com/docs/hooks
- Cursor third-party (Claude) hooks: https://cursor.com/docs/reference/third-party-hooks
- Cursor CLI hook reports (forum): https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316, https://forum.cursor.com/t/hooks-afteragentresponse-afteragentthought-not-firing-in-headless-cli/156220, https://forum.cursor.com/t/hooks-not-firing-cannot-have-guardrails/168407
- Cline file hooks: https://github.com/cline/cline/blob/main/sdk/packages/core/src/hooks/hook-file-config.ts, https://github.com/cline/cline/blob/main/sdk/packages/core/src/hooks/hook-file-hooks.ts, https://github.com/cline/cline/blob/main/sdk/packages/shared/src/hooks/events.ts, https://github.com/cline/cline/blob/main/sdk/packages/shared/src/storage/paths.ts, https://github.com/cline/cline/blob/main/sdk/examples/hooks/README.md
- Cline VS Code hooks: https://github.com/cline/cline/blob/main/apps/vscode/src/core/hooks/utils.ts, https://github.com/cline/cline/blob/main/apps/vscode/src/core/hooks/hook-factory.ts, https://github.com/cline/cline/blob/main/apps/vscode/src/sdk/hooks-adapter.ts, https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts
- Cline CLI: https://github.com/cline/cline/blob/main/apps/cli/README.md
- Aider notifications: https://github.com/Aider-AI/aider/blob/main/aider/io.py, https://github.com/Aider-AI/aider/blob/main/aider/args.py, https://aider.chat/docs/config/options.html, https://aider.chat/docs/config/aider_conf.html
