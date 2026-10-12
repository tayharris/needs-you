# Agent hooks and pollers: what exists, what we use, what to add next

Status: research, 2026-10-12 (against `main` at 0.5.1). Nothing here is built. It does three things: lists what each integration in `integrations/` uses today, checks each agent's current hook surface against its official docs, and ranks the next agent integrations, hook improvements and pollers. Earlier research this builds on: [integrations-next.md](integrations-next.md) (the five agents shipped in 0.1.5), [work-alerts.md](work-alerts.md) (ticket and ops pollers, the generic poller) and [questions.md](questions.md) (answering from cards).

**How the claims were checked.** Every vendor fact links to the vendor's docs, source or changelog, fetched on 2026-10-12. Many vendor pages carry no date or version; where a version is given, it's the vendor's. Anything marked **(unverified)** comes from a third-party page, our inference from source, or a search excerpt we couldn't open. Check those before building on them. Nothing in this pass was run live.

## 1. What we integrate today

Every agent integration shares `integrations/claude-code/needs-you-hook.sh`. Its modes: `notify` puts up the waiting card, `resolve` takes it down, `start` clears earlier cards after a clear or resume, `end` clears the session's card, and `ask` is the synchronous answer path. There is one card per session, keyed `agent:<host>:<id>`.

| Agent | Events we use | Events that exist and we don't use | Tested version (README) |
|---|---|---|---|
| **Claude Code** | `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `quota_auto_resume_disabled`), `PermissionRequest` (two entries: async `notify`, plus synchronous `ask` for `AskUserQuestion`), `StopFailure`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `SessionStart`, `SessionEnd`. Usage card and meter come from the status line (`needs-you-usage`) | `Notification` `agent_completed`, `auth_success`, `elicitation_complete`, `elicitation_response`, `quota_auto_resume_fired`, `quota_auto_resume_stale`; `PermissionDenied`, `SubagentStart`/`SubagentStop`, `TaskCreated`/`TaskCompleted`/`TeammateIdle`, `PreCompact`/`PostCompact`, `Elicitation`/`ElicitationResult`, `PostToolBatch`, `MessageDisplay`, `UserPromptExpansion`, `Setup`, `InstructionsLoaded`, `ConfigChange`, `CwdChanged`/`FileChanged`, `DirectoryAdded`, `WorktreeCreate`/`WorktreeRemove`, `Pre`/`PostModelSwitch` | current |
| **Codex CLI** | `PermissionRequest`, `PreToolUse` (`request_user_input`), `Stop`, `UserPromptSubmit`, `PostToolUse`, `Interrupt`, `SessionStart`, `SessionEnd`. Usage card and meter come from `rate_limits` in the rollout file | `PreCompact`/`PostCompact`, `SubagentStart`/`SubagentStop`. There are no idle, error or notification hooks | 0.159+ |
| **Gemini CLI** | `Notification` (`ToolPermission`), `BeforeTool` (`ask_user`), `AfterAgent`, `BeforeAgent`, `AfterTool`, `SessionStart`, `SessionEnd` | `PreCompress`, `BeforeModel`/`AfterModel`, `BeforeToolSelection`. **Personal plans moved to Antigravity CLI** (see 2.1) | 0.63 |
| **Copilot CLI** | `notification` (`permission_prompt`, `elicitation_dialog`), `agentStop`, `userPromptSubmitted`, `postToolUse`, `postToolUseFailure`, `sessionEnd` | `errorOccurred`, `notification` `agent_idle`/`agent_completed`/`shell_completed`/`shell_detached_completed`, `subagentStart`/`subagentStop`, `preCompact`, `sessionStart`, `permissionRequest`/`preToolUse` (they gate, so we avoid them on purpose), `userPromptTransformed`, `preMcpToolCall` | 1.0.93 |
| **Cursor** | `stop`, `beforeSubmitPrompt`, `sessionEnd` | `afterAgentResponse` (`text`), `preCompact` (`context_usage_percent`), `subagentStop`, `postToolUseFailure` (`failure_type`), the `sessionEnd` fields `error_message` and `final_status`, `sessionStart`, `afterAgentThought`, `after*Execution`, `afterFileEdit`, `workspaceOpen`. There is still no approval event | no live run |
| **Cline** | file hooks `TaskComplete`, `TaskError` (CLI), `UserPromptSubmit`, `TaskCancel`, `TaskStart`, `TaskResume`, `SessionShutdown` (CLI) | **`Notification` (VS Code extension, March 2026)**: `user_attention` with `waitingForUserInput`. Also `PreCompact`, `PreToolUse`/`PostToolUse` | CLI 3.0.69 |
| **opencode** | `permission.asked`, `question.asked`, `session.status` (idle/busy), `session.idle`, `permission.replied`, `question.replied`/`rejected`, `session.deleted`; `shell.env` | **`session.status` `retry`** (provider retry, with a message and a link), **`session.error`** (`ProviderAuthError`, `APIError{statusCode}`, `ContextOverflowError`, …), `session.compacted`, `todo.updated`. The **OpenCode 2 plugin API** is coming | 1.18.35 (source) |
| **Kimi Code** | `PermissionRequest`, `PreToolUse` (`AskUserQuestion`), `Stop`, `StopFailure`, `PermissionResult`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `Interrupt`, `SessionStart`, `SessionEnd` | `Notification` (background tasks only, e.g. `task.completed`), `SubagentStart`/`SubagentStop`, `PreCompact`/`PostCompact`, `TurnStarted`, `UserPromptQueued`, `TaskStarted`, `SessionHeartbeat` | 2.1.1 |
| **Grok Build** | `Notification` (`permission_prompt`, `idle_prompt`), `StopFailure`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `StopCancelled`, `SessionStart`, `SessionEnd` | `PermissionDenied`, `SubagentStart`/`SubagentStop`, `PreCompact`/`PostCompact`, `Notification` `task_complete`. `Stop` and `PreToolUse` gate, so we avoid them on purpose | current |
| **Aider** | `--notifications-command` | Nothing new: Aider still has no hook system | 0.86.2 |
| **MCP** (`integrations/mcp/`) | `needs_you_add`, `needs_you_resolve`, `needs_you_doctor` tools | n/a | |
| **Orca** | Claude hooks plus prompt blocks for automations; Orca accounts usage poller | n/a | |
| **Pollers** | GitHub (notifications, my PRs, merged, Projects, Dependabot), Linear, Jira, expiry (certs, RDAP, key dates), CI wrappers (`needs-you run`, `run-or-alert.sh`, systemd `OnFailure=`, Actions) | | |

## 2. Agent hook surfaces, checked

Columns: (a) waiting for input or idle, (b) permission needed, (c) turn finished, (d) error, rate limit or usage limit. "New" means added since our integration, or not in our README.

### 2.1 Agents we already integrate

| Agent | (a) waiting | (b) permission | (c) finished | (d) error / limit | New since our integration |
|---|---|---|---|---|---|
| Claude Code | `Notification` `idle_prompt`, `agent_needs_input` | `PermissionRequest`, `Notification` `permission_prompt` | `Stop` (`last_assistant_message`, 2.1.47) | `StopFailure` (`error`: `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown`); `Notification` `quota_auto_resume_*`; status line `rate_limits.five_hour`/`seven_day`, and `spend_limit` (2.1.251) with `used_usd`/`limit_usd`/`period` (2.1.284) | `quota_auto_resume_fired`/`_stale`, `elicitation_complete`/`_response`, `agent_completed` (2.1.198), `PostCompact` (2.1.76), `PermissionDenied` (2.1.89), `TeammateIdle`/`TaskCompleted` (2.1.33). Since 2.1.288, `idle_prompt` doesn't fire while background agents run. Changelog versions are undated |
| Codex CLI | none | `PermissionRequest` | `Stop` (`last_assistant_message`), legacy `notify` (`agent-turn-complete`) | none in hooks (rate limits only from the rollout file, as we read today) | Hooks GA 2026-05-14. `PreCompact`/`PostCompact` (third-party says v0.129, around 2026-05-07; **unverified**), `SubagentStart`/`SubagentStop`. Async hooks run at most 8 at a time |
| Gemini CLI | none | `Notification` `ToolPermission` | `AfterAgent` | none | No change to the event list (docs updated 2026-04-10). But Google moved personal plans to **Antigravity CLI**: Gemini CLI stopped serving Google AI Pro/Ultra and free Code Assist users on **2026-06-18**. Code Assist Standard/Enterprise and paid API keys keep it |
| Copilot CLI | `notification` `agent_idle` (background agents) | `notification` `permission_prompt`, `permissionRequest` (gate) | `agentStop` | **`errorOccurred`** (`error{message,name}`, `errorContext`: `model_call`, `tool_execution`, `system`, `user_input`; `recoverable`), `sessionEnd` `reason: error` | `errorOccurred` (version undated), `preCompact` 1.0.5, `subagentStart` 1.0.7, `permissionRequest` 1.0.16, HTTP hooks 1.0.35, `preMcpToolCall` 1.0.51 (changelog only), `sessionEnd` once per turn in `-p` (1.0.78), `sessionEnd` on `/clear` (1.0.85). The newest is 1.0.95, 2026-10-09 |
| Cursor | none | **none** (`ask` is a decision a hook returns, not an event) | `stop`, `afterAgentResponse` (`text`) | `stop` `status: error`; `sessionEnd` `reason: error` plus `error_message`; `postToolUseFailure` `failure_type: permission_denied`. No rate-limit type | `afterAgentResponse`, `preCompact` with `context_usage_percent`, `subagentStop`, `workspaceOpen` (dates **unverified**). Forum reports say `conversation_id` is sometimes empty (**unverified**) |
| Cline | **`Notification` `user_attention`** (`waitingForUserInput: true`, from `Task.ask`) | the same `user_attention`: approvals go through `Task.ask` (our reading of the source; **unverified** live) | `TaskComplete`, `Notification` `task_complete` | `TaskError` (CLI/SDK only) | `Notification` added to the **VS Code extension only** (PR #9699, 2026-03-06; #9909 in v3.74.0). The CLI/SDK file hooks don't have it. The hooks docs page is now a stub pointing at SDK plugins |
| opencode | `session.status` idle, `session.idle` | `permission.asked` (v1 bus name `permission.updated`) | idle | **`session.status` `retry`** `{attempt, message, next, action{reason, provider, title, message, link}}`, **`session.error`** | v1.19.0 (2026-10-11) adds `opencode upgrade --major` to **OpenCode 2**. The `dev` branch has a new plugin API (`Plugin.define({setup})`); whether v1 `event` plugins still load is **unverified** |
| Kimi Code | none (its `Notification` is for background tasks) | `PermissionRequest` | `Stop` | `StopFailure` (the docs list no error values) | `TurnStarted`, `UserPromptQueued`, `TaskStarted`, `SessionHeartbeat` (0.32.0, 2026-08-04). Open issue #2455: `PermissionRequest` doesn't fire for `ask` rules in yolo mode |
| Grok Build | `Notification` `idle_prompt` | `Notification` `permission_prompt` | `Notification` `task_complete`; `Stop` (gate) | `StopFailure` (`rate_limit`, `authentication_failed`, `invalid_request`, `server_error`, `max_output_tokens`, `unknown`); `StopCancelled` (`user_interrupt`, `permission_rejected`, `permission_cancelled`, `max_turns`, `no_progress`) | `PermissionDenied`, `Pre`/`PostCompact`, HTTP hooks. docs.x.ai lists 14 events without `StopCancelled`; the repo's user guide (CLI 1.0.45, 2026-09-29) lists 15 and is the more detailed |
| Aider | `--notifications-command` | (same; it doesn't say which) | (same) | none | none. The last release is v0.86.0 (2025-08-09) |

### 2.2 Agents we don't integrate

| Agent | (a) | (b) | (c) | (d) | Mechanism | Fit for us |
|---|---|---|---|---|---|---|
| **Antigravity CLI** (`agy`, Gemini CLI's successor for personal plans) | `Stop` `fullyIdle` | none (only `PreToolUse`, which gates: `allow`/`deny`/`ask`) | `Stop` (`terminationReason`) | `Stop` `error`, `PostToolUse` `error` | Command hooks: `~/.gemini/config/hooks.json`, `.agents/hooks.json`, and CLI-only `~/.gemini/antigravity-cli/settings.json`. camelCase payload: `conversationId`, `workspacePaths`, `transcriptPath`, `modelName`. 30 s default timeout; `Stop` can return `decision: "continue"` | **Medium**: finished and error cards only. A forum report says `Stop`/`PostToolUse` never fired in IDE 1.107.0 on Windows (**unverified** for the CLI) |
| **Factory Droid** | `Notification` `idle_prompt` | `Notification` `permission_prompt` | `Stop`, `SubagentStop` | `SubagentStop` `task_error` only | Claude-shaped command hooks in `~/.factory/hooks.json`; same payload keys (`session_id`, `transcript_path`, `cwd`, `notification_type`). Exit 2 blocks; 60 s default; no async flag documented | **Easy**: nearly our Claude path |
| **Qwen Code** | `Notification` `idle_prompt` | `PermissionRequest`, `Notification` `permission_prompt` | `Stop` (`last_assistant_message`) | `StopFailure` (`rate_limit`, `authentication_failed`, `billing_error`, `server_error`, `max_output_tokens`, `loop_detected`, …) | Claude-shaped `hooks` key in `~/.qwen/settings.json`; `async: true` supported (at most 10); docs first committed 2026-03-26 | **Easy**: the closest match to our Claude path of any agent |
| **Kiro** (IDE 1.0 / CLI V3) | none | none | `Stop` | none | `.kiro/hooks/*.json`, `~/.kiro/hooks/`. On `Stop`, exit 1 means "keep going". Stdin fields for `Stop` aren't documented | **Easy**, but only a finished card |
| **Auggie CLI** | none | none (`Notification` appears in a table but isn't documented) | `Stop` (`agent_stop_cause`) | none | `~/.augment/settings.json`; synchronous, so it must background; the script must end in `.sh`; `conversation_id`, `workspace_roots` | **Easy**, finished card only |
| **Windsurf / Devin Desktop** (Cascade) | none | none | `post_cascade_response` (async) | none | `~/.codeium/windsurf/hooks.json`; `trajectory_id`; only pre-hooks block | **Medium**, finished card only |
| **Goose** | none | none | `Stop` (`last_assistant_message`) | `PostToolUseFailure` (tool only) | Hooks only inside a plugin (`~/.agents/plugins/<name>/hooks/hooks.json`); blog post 2026-05-14 | **Medium** (plugin packaging) |
| **Amp** | `thread.state` `idle` | `thread.state` `awaiting-approval` | `agent.end` (`status: done`) | `agent.end` `status: error` | TS/JS plugin (`~/.config/amp/plugins/`, Bun). Said to be experimental and to need `PLUGINS=all` (**unverified**). No shell hooks | **Medium**: the only non-Claude agent here with an approval *state* we could watch |
| **Warp** (own agent) | built-in only | built-in | built-in | built-in | No user hooks. Warp *consumes* other agents' hooks (its Claude plugin prints OSC 777) | **None** |
| **Zed** agent panel | `agent.notify_when_agent_waiting` (OS notification only) | same | `play_sound_when_agent_done` | none | No hooks. External agents over ACP keep their own hooks (**unverified** per adapter); an ACP proxy is possible | **None** directly |
| **Continue** (`cn`) | (code only) | (code only) | (code only) | (code only) | PR #11029 (2026-03-04) added Claude-compatible hooks that **read `~/.claude/settings.json`**. On `main` (2026-07-20) nothing fires them yet (source read, **unverified** live) | **None** today. **A risk**: once wired up, our Claude hooks would run inside `cn` |
| **Roo Code** | | | | | Shut down 2026-05-15; repo archived | **None** |
| **JetBrains Junie** | | | | | `SessionStart` hook only | **None** |

## 3. Summary table

Effort: S under a day, M a few days, L a week or more. Value: how often the missing card would matter to someone using that agent or tool.

| Agent / tool | What exists | What we use | Gap | Effort | Value |
|---|---|---|---|---|---|
| Claude Code | 33 events, rich `Notification` types, `StopFailure`, status line `rate_limits`/`spend_limit` | 10 events, 6 notification types, status line | Quota card never resolved by `quota_auto_resume_fired`; elicitation cards not resolved by `elicitation_complete`; context card not resolved at `PostCompact`; `overloaded`/`server_error`/`invalid_request` fall into the generic "API error" title; transcript parsing where `last_assistant_message` would do; no `spend_limit` card | S | High |
| Codex CLI | 12 events, no error or idle hooks | 8 + rollout `rate_limits` | `PostCompact` could clear a context card, but Codex hooks carry no context numbers (the rollout's `token_count` might; **unverified**); still no API-error card | S–M | Medium |
| Gemini CLI → Antigravity CLI | Antigravity: 5 events, `Stop` with `fullyIdle`/`error` | Gemini CLI hooks only | Personal users lost Gemini CLI on 2026-06-18; our Gemini integration doesn't reach `agy` | M | High |
| Copilot CLI | 15 events incl. `errorOccurred` | 6 | No error card (`errorOccurred` with `recoverable: false`, `sessionEnd` `reason: error`) | S | Medium |
| Cursor | 21 events, no approval event | 3 | Error text on `sessionEnd`; `afterAgentResponse` text would allow "Cursor asks: …"; `preCompact` `context_usage_percent` could feed a context card | S | Medium |
| Cline | VS Code `Notification` (`user_attention`) | Task* file hooks | **No approval cards in VS Code** although the hook now exists | S | High |
| opencode | Rich bus, `retry` status, `session.error`, OpenCode 2 | 10 events | No rate-limit or provider-error card; OpenCode 2 compatibility unknown | S–M | High |
| Kimi Code | 20 events | 11 | Background-task `Notification`, compaction; issue #2455 (note in guide) | S | Low |
| Grok Build | 15 events | 8 | `StopCancelled` `permission_rejected` already resolves; `StopFailure` titles miss `invalid_request`/`server_error`/`max_output_tokens`; `PermissionDenied` unused | S | Low |
| Aider | notifications command | it | none possible | — | — |
| Factory Droid | Claude-shaped hooks | — | No integration | S | Medium |
| Qwen Code | Claude-shaped hooks + `StopFailure` | — | No integration | S | Medium |
| Kiro, Auggie, Windsurf, Goose | `Stop`-type hook only | — | Finished cards only | S each | Low–medium |
| Amp | Plugin API with `awaiting-approval` | — | No integration; plugin API experimental | M | Medium |
| Continue `cn` | Reads `~/.claude/settings.json` hooks (not fired yet) | (would run ours) | Our hook must detect `cn` and step aside, as it does for Cursor | S | Medium (defensive) |
| Warp, Zed, Junie, Roo | no usable hooks | — | — | — | — |
| GitLab | Todos API (`read_api`) | — | No poller | S | High (for GitLab users) |
| Sentry | Issues API (`event:read`) | — | No poller | S | High |
| Uptime: Healthchecks.io, UptimeRobot, Better Stack | Read-only keys | — | No poller | S each | Medium–high |
| Stripe disputes | Restricted key, Disputes: Read | — | No poller | S | Medium (rare, costly to miss) |
| Deploys: Vercel, Cloudflare Pages/Workers Builds, Fly, Netlify | REST APIs | — | No poller | S each | Medium |
| PagerDuty | Incidents and on-call APIs | — | Skipped in work-alerts.md ("they already page") | S | Low for us |
| Opsgenie | **End of sale 2025-06-04, shut off 2027-04-05** | — | Don't build | — | — |
| Slack, Google Calendar, IMAP, Bitbucket, AWS Budgets, K8s/Docker, Home Assistant | see section 5 | — | Credential or link problems | M–L | Low–medium |

## 4. Top 10, in order

### 1. Cline: approval and question cards from the VS Code `Notification` hook

- **Why:** Cline is our lowest-fidelity agent ("finished tasks only"). Since 2026-03-06 the VS Code extension runs a `Notification` hook whose `notification.event` is `user_attention` and whose `waitingForUserInput` is true when `Task.ask` waits. Command and tool approvals go through `Task.ask`.
- **Plan:**
  - `integrations/cline/install-cline-hooks.sh`: write a `Notification` hook file (same marker scheme).
  - `needs-you-hook.sh`: add a `cline_card()` branch.
    - `user_attention` with `waitingForUserInput` posts `--event approval`, or `question` when `notification.source` says so. Titles come from `notification.source`/`sourceType` only: never `message`, which may hold a command line. Map known sources to "Cline wants to run a command" or "Cline wants to edit a file"; anything else is "Cline needs you".
    - `task_complete`: nothing, since `TaskComplete` already posts.
  - The existing `UserPromptSubmit`/`TaskCancel` resolve stays. Approvals need a resolve too: `PostToolUse` (now unused) is the candidate.
  - Docs: `docs/guides/cline.md`, the README's fidelity line, `tests/test_cline.py` with payloads from `hooks.proto`.
- **Risks:**
  - The CLI/SDK file hooks don't have `Notification`, so the fidelity differs by host and the guide must say so.
  - The `Task.ask` coverage is read from source, not seen live. Check first that an approval prompt fires it and what `source` reads.
  - `messageTruncated` suggests `message` can be long: keep it out of the card.

### 2. Antigravity CLI (the Gemini CLI successor)

- **Why:** Gemini CLI stopped serving personal plans on 2026-06-18 ([Google](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)). Personal users of our Gemini integration now get nothing. Enterprise and API-key users keep Gemini CLI, so keep that integration too.
- **Plan:**
  - Add `integrations/antigravity/`: `antigravity-hooks.json`, `install-antigravity-hooks.sh` (merge into `~/.gemini/config/hooks.json`; refuse symlinks; back up the file).
  - Add a `notify antigravity` card in the hook:
    - `Stop` with `fullyIdle: true` and no `error`: "Antigravity finished".
    - `Stop` with `error`: "Antigravity stopped on an error", `--event failed`, error code only.
  - Resolve on `PreInvocation` (the next model call, cheap after the marker check).
  - Add `--agent antigravity`, the invite flag, `needs-you update` and `doctor` lines, a guide, and tests.
  - Don't register `PreToolUse`: it decides.
- **Risks:**
  - No approval or idle signal, so this is finished and error cards only.
  - The camelCase payload has no `session_id` or `cwd`: key on `conversationId`, project from `workspacePaths[0]`.
  - Google's post lists Hooks among the features Antigravity keeps, but its event names differ from Gemini CLI's; check whether `agy` also reads our Gemini entries in `~/.gemini/settings.json` (a double post) (**unverified**).
  - A forum report says `Stop` didn't fire in one IDE build. Run it live before shipping.

### 3. Claude Code: use what we already receive

All in `needs-you-hook.sh` and `integrations/claude-code/hooks.json`, plus `tests/test_hook*.py`, the Claude README and the guide.

- **Quota card:** extend the `Notification` matcher with `quota_auto_resume_fired|quota_auto_resume_stale|elicitation_complete|elicitation_response|auth_success`, and route them to `resolve`:
  - `quota_auto_resume_fired` resolves the "usage limit" card.
  - The elicitation types resolve an elicitation card. Today it waits for the next prompt or tool.
  - `auth_success` resolves the `elicitation_url_dialog`/sign-in card.
- **Context card:** add `PostCompact` → resolve `agent:<host>:<id>:context` at once. Today it waits for the next `Stop`.
- **`StopFailure` titles:** add `overloaded` ("Claude's API is overloaded"), `server_error`, `invalid_request` and `unknown`. Consider *not* paging for `overloaded`: Claude retries those, and it may be transient. That's for the owner to decide.
- **Turn text:** `Stop` carries `last_assistant_message` (2.1.47). Use it in `stop` mode and store the question tail for the following `idle_prompt` card, instead of reading the transcript tail. That's cheaper, and it fixes the case where the transcript lags. Keep the transcript read as the fallback for older versions.
- **Spend limit:** `needs-you-usage` can read `rate_limits.spend_limit` (`used_usd`, `limit_usd`, `period`; 2.1.251/2.1.284) for a "Claude spend 90% of $X" card and a third meter bar. Meter labels go through the status record, so there's no API change.
- **Background agents:** `agent_completed` (agent view only) could post a low `done` card. Optional.
- **Risks:**
  - The changelog is undated, and older Claude versions ignore unknown `notification_type` matcher values (harmless).
  - The hook's `NOTIFICATION_EVENTS` map needs the new types.
  - Hooks still running at `-p` teardown are killed: that's fine for resolves.

### 4. opencode: rate-limit and error cards, and OpenCode 2

- **Why:** opencode has no usage-limit card today. `session.status` `retry` carries `message`, `next` (the retry time) and an `action` with `reason`, `provider`, `title`, `link`. `session.error` names `ProviderAuthError` and `APIError{statusCode}`.
- **Plan:**
  - `integrations/opencode/needs-you.js`:
    - On `retry` past the second attempt, start `notify opencode` with `{kind: "retry", provider, reason, next}` and no `message` text. The hook titles it "opencode is retrying: <provider> rate limit", `--event failed`, expiring at `next`.
    - On `session.error` of `ProviderAuthError`: "opencode needs you to sign in to <provider>". On `APIError` with a non-retryable status: "opencode stopped on an API error".
    - `busy`/idle clears it (the existing resolve).
  - The `action.link` would be a bring-forward link only when it's `https` and passes the allow-list; otherwise drop it.
  - Separately, install OpenCode 2 in a scratch `HOME` and check the plugin still loads (`event` hook, `shell.env`, `client._client` for answers). If it doesn't, ship a v2 plugin next to the v1 one.
- **Risks:**
  - `retry` fires on transient overloads too: threshold it.
  - The v2 API is on `dev` only and could change.
  - The answer path (`POST /question/{id}/reply`) may move in v2.

### 5. Factory Droid and Qwen Code

- **Why:** both have Claude-shaped command hooks with `Notification` `permission_prompt`/`idle_prompt` and `Stop`. Qwen also has `PermissionRequest`, `StopFailure` with `rate_limit`, `last_assistant_message` and `async: true`. That gives full fidelity for very little code.
- **Plan:** use the `add-integration` skill for each.
  - `integrations/droid/` (`~/.factory/hooks.json`) and `integrations/qwen/` (`hooks` in `~/.qwen/settings.json`), each with a JSON fragment and a merge installer modelled on `install-codex-hooks.sh`.
  - Hook: `droid` and `qwen` agent names that reuse the Claude card code with their titles.
  - Invite flags, `doctor`, `update`, `uninstall-hooks`, guides, tests.
- **Risks:**
  - Droid documents no async flag, so background the hook as in `gemini` mode.
  - Qwen's project hooks load only in trusted folders: user-level only.
  - Check whether either also reads `~/.claude/settings.json` (Cursor does). If so, the agent-detection guard from Cursor applies.
  - Droid sends a `Notification` on a cancelled turn instead of `Stop`.

### 6. A guard for agents that run our Claude hooks

- **Why:** Continue's `cn` loads hooks from `~/.claude/settings.json` (code added 2026-03-04, not fired yet), as Cursor already does, and Warp's Claude plugin sits next to ours. When `cn` starts firing them, our Claude hook would post "Claude …" cards for `cn` sessions, and its `Stop`/`UserPromptSubmit` would clear the wrong cards.
- **Plan:**
  - In `needs-you-hook.sh`, generalise the Cursor check ("payload has `cursor_version`, no agent argument → exit"). Fingerprint the payload, and the parent process name as a fallback, for `cn`/Continue.
  - Add a test with a `cn`-shaped payload.
  - A `doctor` line when `~/.continue/` exists.
- **Risks:** `cn`'s payload shape isn't final. Revisit when Continue ships hook dispatch.

### 7. Copilot CLI and Cursor: error cards and turn text

- **Copilot plan:**
  - Add `errorOccurred` to `integrations/copilot/copilot-hooks.json` → `notify copilot`.
    - `recoverable: false` and `errorContext: model_call` posts "Copilot stopped on an error" (`--event failed`; never `stack` or `message`, only `error.name`).
    - Recoverable ones post nothing.
  - `sessionEnd` with `reason: error` keeps the card instead of resolving it.
- **Cursor plan:**
  - `afterAgentResponse` → store the reply's question tail, so `stop` can title "Cursor asks: …". This mirrors Codex `last_assistant_message`, with the same redaction.
  - `sessionEnd` with `reason: error` → "Cursor stopped on an error". Only the reason goes on the card, not `error_message`, unless redacted and clamped like Claude's.
  - `preCompact` with `context_usage_percent` → optional low context card. It fires only at compaction, so it's weaker than Claude's.
- **Files:** the two hooks JSON files, the hook, the two READMEs and guides, `tests/test_copilot.py`, `tests/test_cursor.py`.
- **Risks:**
  - Cursor reads stdout as an answer for every hook: `afterAgentResponse` needs `{}` printed first like the others.
  - The empty-`conversation_id` forum report (**unverified**) would break keys; fall back to `session_id`.
  - Copilot's `errorOccurred` version is undated.

### 8. A generic poller plus GitLab To-Dos

- **Why:** [work-alerts.md](work-alerts.md) mechanism A (`needs-you poll`) is still the right base. GitLab's To-Do List API (`GET /api/v4/todos?state=pending`, `read_api`) covers review requests, assignments, failed pipelines, mentions and `approval_required` in one call. GitLab marks most of them done by itself, so the resolve comes free. It's the GitLab twin of the GitHub poller.
- **Plan:**
  - Write `integrations/gitlab/needs-you-gitlab` as a dedicated script copying `needs-you-github`'s lifecycle: stable key `<ctx>:gl:<project>!<iid>:<action>`, a 3× interval expiry, `poller-failing` card, card cap.
  - Configuration: `NEEDS_YOU_GITLAB_URL` for self-managed, the token in a mode-600 file (or `glab auth token` when `glab` is logged in).
  - Card link: the to-do's `target_url`.
  - Plus a cron line, systemd timer, LaunchAgent, guide and tests against a fake HTTP server.
- **Risks:**
  - Self-managed versions differ, so check `action_name` values against a live instance.
  - `target.title` is untrusted: clean, redact and truncate it as the Linear poller does.

### 9. Sentry and the uptime pack (Healthchecks.io, UptimeRobot, Better Stack)

- **Why:** these are "something broke that you need to know about today", the core use case, and each has a read-only credential and a clean down/up resolve.
  - **Sentry:** `GET /api/0/organizations/<org>/issues/?query=is:unresolved assigned:me` with `event:read`. The `assigned:me` query syntax is **unverified** on that page. Card link: `permalink`.
  - **Healthchecks.io:** `GET /api/v3/checks/` with a read-only key. `status == "down"`; key on `unique_key`.
  - **UptimeRobot:** read-only API key. v2 `getMonitors` with `statuses=8-9`; the v3 paths are **unverified**.
  - **Better Stack:** `GET /api/v3/incidents?resolved=false`; read-only token **unverified**.
- **Plan:** build these as the first configs of the generic poller (work-alerts.md mechanism A) if that lands first; otherwise as one `integrations/ops/needs-you-ops` script with a provider per section. Keys like `<ctx>:sentry:<org>:<issue id>` and `<ctx>:uptime:<provider>:<check id>`.
  - Down is `urgent`, Sentry is `normal`.
  - Resolve when the check is up or the issue is no longer listed.
- **Risks:**
  - A Sentry org with many unassigned issues: query only `assigned:me` (plus an opt-in `assigned:#team`).
  - Uptime monitors flap: require two polls down before posting.
  - Free text (`cause`, `culprit`) stays off the card.

### 10. Stop-only agents: Kiro, Auggie, Windsurf, Goose

- **Why:** each gives only "the turn finished". That still covers the most common wait, and each is a small installer around the existing hook.
- **Plan:**
  - Use the `add-integration` skill for each, finished cards only, with the fidelity line up front as in Cursor's README.
  - Event per agent:
    - **Kiro:** `Stop` in `~/.kiro/hooks/needs-you.json`. Must exit 0: exit 1 continues the turn.
    - **Auggie:** `Stop` in `~/.augment/settings.json`. Synchronous, so background it; the script name must end in `.sh`.
    - **Windsurf:** `post_cascade_response` (async) in `~/.codeium/windsurf/hooks.json`, keyed on `trajectory_id`.
    - **Goose:** a plugin `~/.agents/plugins/needs-you/hooks/hooks.json` with `Stop`.
  - Resolve on each agent's prompt-submit event where one exists (Kiro `UserPromptSubmit`, Goose and Windsurf `pre_user_prompt` (**unverified**)), else on the next `Stop` or by expiry, as Aider does.
- **Risks:**
  - No approval cards: say so.
  - Stdin fields for Kiro's `Stop` aren't documented: run live first.
  - A `windsurf://` link would need an allow-list change in both the hub and `LinkPolicy.swift` (hard rule 7). Use `app/activate` with the bundle id instead.

**Just below the line:**
- **Amp:** a plugin watching `thread.state` `awaiting-approval` and `agent.end`. It's the only non-Claude-shaped agent with an approval state, but its plugin API is experimental.
- **Stripe disputes:** a restricted key with Disputes: Read; `evidence_details.due_by` gives the priority.
- **A deploy-failure pack:** Vercel `GET /v7/deployments?target=production&state=ERROR`, Cloudflare Pages `latest_stage.status`, Fly machines `state: failed`.
- **Codex:** `PostCompact` → resolve a future Codex context card.
- **Grok:** `StopFailure` titles for the remaining codes.

## 5. Pollers: the rest of the list

| Source | Endpoint | Resolve | Auth, minimal scope | Verdict |
|---|---|---|---|---|
| PagerDuty | `GET /incidents?user_ids[]=<me>&statuses[]=triggered&statuses[]=acknowledged`; `GET /oncalls?user_ids[]=<me>&since=…&until=…` | incident leaves the list | REST key, or OAuth `incidents.read`; 960 req/min | work-alerts.md says skip: PagerDuty already pages. An "on-call starts in 30 min" card is the one new thing it could add |
| Opsgenie | — | — | — | **Don't build**: end of sale 2025-06-04, shut off 2027-04-05 (Atlassian). Its successors are Jira Service Management and Compass |
| Bitbucket Cloud | per-repo `GET /2.0/repositories/<ws>/<repo>/pullrequests?state=OPEN`; reviewer filter **unverified** | PR not open, or approved | API token (Basic; **app passwords removed 2026-07-28**) | Skip until asked: per-repo fan-out |
| Slack | `search.messages` (user token, `search:read`, Tier 2, marked legacy); DMs via `conversations.history` (`im:history`) | a reply from me after `ts` | Own Slack app with a user token. Since 2025-05-29, non-Marketplace *distributed* apps get Tier 1 on `conversations.history`; internal apps keep Tier 3 | Agent recipe (work-alerts.md mechanism C), not a poller |
| Google Calendar | `events.list?timeMin=now&timeMax=now+10m&singleEvents=true` | event started | OAuth (`calendar.events.readonly`, **unverified** as narrowest), or the secret iCal address (bearer secret; no stdlib RRULE parser) | Skip: the calendar already reminds |
| IMAP from VIPs | `imaplib` `SEARCH UNSEEN FROM …` | `\Seen` | Gmail personal: app password (full mailbox). Workspace OAuth-only since 2025-03-14; Microsoft basic auth gone | Skip: no read-only credential |
| AWS Budgets | `DescribeBudgets` | spend under limit | `AWSBudgetsReadOnlyAccess`; SigV4 in stdlib (about 60 lines) or the `aws` CLI | Later, M |
| Kubernetes / Docker | `kubectl get jobs -A -o json` (`Failed` condition); `docker ps -a --filter status=exited` | job gone or succeeded | RBAC `get/list jobs`; the docker socket is root-equivalent | Recipe with `needs-you run`, not a poller: no https link |
| Home Assistant | `GET /api/states/<entity>` | state OK | Long-lived token = full admin; persistent notifications left the states API in 2023.6 | Recipe only |
| Netlify | `GET /api/v1/sites/<id>/deploys` (newest production) | newer deploy ready | PAT with no read-only scope | In the deploy pack only with a warning, or skip |

Every poller follows the existing lifecycle and rules: stdlib only, a read-only token in a mode-600 file, never logged (hard rule 3); titles only from vendor text, cleaned and redacted; `https` links that pass the allow-list.

## 6. Smaller improvements to existing hooks

- **Kimi:** add issue #2455 to the guide (`PermissionRequest` doesn't fire for `ask` rules in yolo mode). `Notification` `task.completed` covers background tasks only: leave it.
- **Grok:** `StopCancelled` `permission_rejected` already resolves. `permission_cancelled` could also resolve the permission card explicitly. Add titles for `invalid_request`, `server_error` and `max_output_tokens`.
- **Codex:** the legacy `notify` gained nothing; `tui.notifications` accepts `approval-requested`, but only for the TUI's own alerts. Nothing to change.
- **Gemini CLI:** the guide should say personal plans moved to Antigravity CLI (2026-06-18) and point at item 2 when it ships.
- **Copilot:** `notification` `agent_idle`/`agent_completed` are background agents; keep ignoring them unless background-agent cards are wanted.
- **Usage cards beyond Claude and Codex:** of the agents checked, no hook carries usage numbers. The rate-limit signals are Claude `StopFailure`/`quota_auto_resume_*`, Qwen and Grok `StopFailure` `rate_limit`, and opencode `retry`. Item 3 and item 4 cover the two we have.
- **Bring-forward links:** no new link scheme is needed for anything in the top 10. New agents use `app/activate` with a bundle id from the existing lists. Windsurf's, Kiro's and Antigravity's bundle ids would need adding to `TERMINAL_APPS`/`EDITOR_APPS` and `AppActivation.allowedApps` together (`tests/test_link_mirror.py` checks they match). The ids are **unverified**.

## Sources

Agents (fetched 2026-10-12):

- Claude Code hooks: https://code.claude.com/docs/en/hooks; status line: https://code.claude.com/docs/en/statusline; changelog (2.1.296 newest, undated): https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
- Codex hooks: https://developers.openai.com/codex/hooks (now redirects to https://learn.chatgpt.com/docs/hooks); config: https://learn.chatgpt.com/docs/config-file/config-advanced; changelog: https://learn.chatgpt.com/docs/changelog. Third-party (unverified) on compaction hooks: https://codex.danielvaughan.com/2026/05/07/codex-cli-v0129-hooks-browser-compaction-hooks-runtime-management/
- Gemini CLI hooks reference: https://geminicli.com/docs/hooks/reference/ and https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md; transition to Antigravity CLI (2026-05-19): https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/
- Antigravity hooks: https://antigravity.google/docs/hooks; forum report on `Stop` not firing: https://discuss.ai.google.dev/t/stop-and-posttooluse-hooks-in-agents-hooks-json-never-fire-antigravity-ide-1-107-0-windows/178288
- Copilot CLI hooks reference: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference; changelog: https://github.com/github/copilot-cli/blob/main/changelog.md
- Cursor hooks: https://cursor.com/docs/hooks; forum (unverified) on empty `conversation_id`: https://forum.cursor.com/t/cursor-hooks-intermittently-emit-empty-conversation-id-session-id-on-tool-execution-events/167095
- Cline: https://docs.cline.bot/customization/hooks (stub), https://docs.cline.bot/sdk/plugins; source https://github.com/cline/cline (`apps/vscode/proto/cline/hooks.proto`, `sdk/packages/core/src/hooks/hook-file-config.ts`); PR https://github.com/cline/cline/pull/9699
- opencode plugins: https://opencode.ai/docs/plugins; v1.19.0 release: https://github.com/anomalyco/opencode/releases/tag/v1.19.0
- Kimi Code hooks: https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html; changelog: https://www.kimi.com/code/docs/en/kimi-code-cli/release-notes/changelog.html
- Grok Build hooks: https://docs.x.ai/build/features/hooks; repo user guide: https://github.com/xai-org/grok-build (`crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md`)
- Aider notifications: https://aider.chat/docs/usage/notifications.html; history: https://github.com/Aider-AI/aider/blob/main/HISTORY.md
- Factory Droid hooks: https://docs.factory.com/cli/configuration/hooks-guide; changelog: https://docs.factory.com/changelog/1-10.md
- Qwen Code hooks: https://github.com/QwenLM/qwen-code/blob/main/docs/users/features/hooks.md
- Kiro hooks: https://kiro.dev/docs/hooks/, CLI V3 migration: https://kiro.dev/docs/cli/v3/hooks-migration/
- Auggie hooks: https://docs.augmentcode.com/cli/hooks.md
- Windsurf / Devin Desktop hooks: https://docs.devin.ai/desktop/cascade/hooks
- Goose hooks: https://goose-docs.ai/docs/guides/context-engineering/hooks/, blog: https://goose-docs.ai/blog/2026/05/14/goose-hooks
- Amp plugin API: https://ampcode.com/manual/plugin-api; settings: https://ampcode.com/docs/cli/settings
- Warp and Claude Code: https://docs.warp.dev/agent-platform/third-party-agents/claude-code, https://github.com/warpdotdev/claude-code-warp
- Zed: https://zed.dev/docs/ai/agent-panel, https://zed.dev/docs/ai/external-agents
- Continue: https://github.com/continuedev/continue (PR #11029)
- Roo Code shutdown notice: https://roocodeinc.github.io/Roo-Code/
- Junie hooks: https://junie.jetbrains.com/docs/junie-cli-hooks.html

Pollers:

- Sentry issues: https://docs.sentry.io/api/events/list-an-organizations-issues/, rate limits: https://docs.sentry.io/api/ratelimits/
- PagerDuty incidents: https://docs.pagerduty.com/developer/api/reference/rest/incidents/list-incidents, limits: https://docs.pagerduty.com/developer/rest-api-rate-limits
- Opsgenie migration: https://www.atlassian.com/software/opsgenie/migration
- GitLab To-Do List API: https://docs.gitlab.com/api/todos/, merge requests: https://docs.gitlab.com/api/merge_requests/, token scopes: https://docs.gitlab.com/security/tokens/access_token_scopes/
- Bitbucket app password deprecation: https://www.atlassian.com/blog/bitbucket/bitbucket-cloud-enters-phase-2-of-app-password-deprecation
- Slack `search.messages`: https://docs.slack.dev/reference/methods/search.messages; rate-limit changes: https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps, https://docs.slack.dev/changelog/2025/06/03/rate-limits-clarity
- Google Calendar `events.list`: https://developers.google.com/workspace/calendar/api/v3/reference/events/list; secret iCal address: https://support.google.com/calendar/answer/37648
- Vercel deployments: https://vercel.com/docs/rest-api/reference/endpoints/deployments/list-deployments
- Netlify API: https://docs.netlify.com/api/get-started
- Fly machine states: https://www.fly.io/docs/machines/machine-states/, read-only tokens: https://fly.io/docs/flyctl/tokens-create-readonly/
- Cloudflare Pages deployments: https://developers.cloudflare.com/api/operations/pages-deployment-get-deployments, Workers Builds: https://developers.cloudflare.com/workers/ci-cd/builds/api-reference/
- AWS Budgets: https://docs.aws.amazon.com/goto/WebAPI/budgets/DescribeBudgets, policy: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBudgetsReadOnlyAccess.md
- Stripe restricted keys: https://docs.stripe.com/keys/restricted-api-keys, https://docs.stripe.com/keys-best-practices
- Home Assistant REST: https://developers.home-assistant.io/docs/api/rest/, auth: https://developers.home-assistant.io/docs/auth_api
- Gmail app passwords: https://support.google.com/mail/answer/185833; Workspace OAuth transition: https://knowledge.workspace.google.com/admin/sync/transition-from-less-secure-apps-to-oauth
- UptimeRobot API v3: https://uptimerobot.com/api/v3/
- Better Stack incidents: https://betterstack.com/docs/uptime/api/list-all-incidents/
- Healthchecks.io API: https://healthchecks.io/docs/api/
