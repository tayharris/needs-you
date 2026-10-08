# Questions and choices: what each agent's hooks carry

Status: research, 2026-10-08. Phase A of [ADR 0009](../adr/0009-questions-on-cards.md) is built from it (the question, its choices as read-only steps and a plan's first lines on the card, for Claude Code, Codex, Gemini CLI, opencode, Kimi Code and Copilot's MCP elicitations). Phase B1 (the `question` field, option rows on the Mac), B2 (answers from the card, for opencode and any sender using `needs-you answer-wait`) and B3 (Claude Code, through `PermissionRequest`, after the live check below) are built.

When an agent asks the person something, what does a hook see, and can a hook answer? Every claim is tagged with its source and a confidence:

- **live**: captured from the agent running against a fake model server, with a temporary HOME and temporary config, nothing of the real HOME touched.
- **src**: read in the agent's source at the version named.
- **bin**: strings in the installed binary.
- **docs**: the agent's official docs.

Confidence is high, medium or low. Captured payloads are in [`tests/fixtures/questions/`](../../tests/fixtures/questions/).

## Summary

| Agent | Question tool | Hook that carries the question | Text? | Choices? | Can a hook answer? |
|---|---|---|---|---|---|
| Claude Code 2.1.293 | `AskUserQuestion` (1–4 questions, 2–4 options) | `PreToolUse` and `PermissionRequest` (`tool_input.questions`); we use `PermissionRequest` | yes | yes, with descriptions, `multiSelect` | **yes**: `PermissionRequest` `allow` + `updatedInput.answers`, the dialog still shown (live, 2.1.294; built, B3) |
| Claude Code, plan approval | `ExitPlanMode` | `PermissionRequest` (`tool_input.plan`, `planFilePath`) | the plan | no | yes, the same way; never done for plans |
| Claude Code, MCP elicitation | MCP `elicitation/create` | `Notification` `elicitation_dialog` (`message`); the `Elicitation` event has `requested_schema` | message only | in the schema (not installed) | yes, `Elicitation` hook `action` + `content` |
| Codex CLI 0.161.0 | `request_user_input` (Plan mode only; 1–3 questions, 2–3 options) | `PreToolUse` (no `PermissionRequest`) | yes | yes, with descriptions, single choice | no |
| Gemini CLI 0.65 nightly | `ask_user` (1–4 questions; choice, text or yes/no) | `BeforeTool` (`tool_input.questions`); the `ToolPermission` notification has none | yes | yes, with descriptions, `multiSelect` | no |
| opencode 1.18.35 | `question` (also plan exit) | `question.asked` bus event (plugin) | yes | yes, with descriptions, `multiple` | **yes**: `POST /question/{id}/reply` (plugin) |
| Copilot CLI 1.0.63 | `ask_user` (`question`, `choices: string[]`) | `preToolUse` (not installed); `elicitation_dialog` is MCP only, `message` | `preToolUse`: yes; notification: MCP message | `preToolUse`: labels only | no (SDK only) |
| Kimi Code 2.0.0 | `AskUserQuestion` (1–4 questions, 2–4 options) | `PreToolUse` (auto-approved: no `PermissionRequest`) | yes | yes, with descriptions, `multi_select` | no |
| Kimi Code, plan approval | `ExitPlanMode` | `PermissionRequest` (`display.plan`, `display.options`) | the plan | the plan options | no |
| Grok Build 1.0.46 | none found | `Notification` has only a generic `message` | no | no | no |
| Cursor | `AskQuestion` | none: it fires no hook (a known bug) | no | no | no |
| Cline (SDK builds) | `ask_question` (`question`, `options: string[]`, 2–5) | `PreToolUse` (not installed: Cline has no approval hooks we use) | yes | labels only, as a JSON string | no |
| Aider | `confirm_ask` (Yes/No/All/Skip/Don't ask) | the notifications command gets nothing | no | no | no |

## Claude Code

Version 2.1.293 ([docs](https://code.claude.com/docs/en/hooks), binary `~/.local/share/claude/versions/2.1.293`, live).

**`AskUserQuestion` input** [live, high]:

```json
{"questions": [
  {"question": "Which database should we use?", "header": "Database",
   "options": [{"label": "Postgres", "description": "Relational, robust"},
               {"label": "SQLite", "description": "Embedded, simple"}],
   "multiSelect": false},
  {"question": "Which features?", "header": "Features",
   "options": [{"label": "Auth", "description": "Login"}, "..."], "multiSelect": true}]}
```

- 1–4 questions, 2–4 options each; options may also have `preview`. Header "max 12 chars" [bin, medium].
- Optional top-level `answers` (question text → label, multi-select labels comma-joined), `annotations`, `metadata` [bin, high]. The model never sets `answers` [docs, high].
- A flagged "extended" variant adds `title` and per-question `kind` (`choice`/`text`/`number`), `placeholder`, `min`/`max` and so on; a text question has no options [bin, medium]. The hook handles a question without options (no steps).
- The TUI adds its own free-text "Other"; it is not in the input [live, high].

**Events, in order** [live, high]:

1. `PreToolUse` with `tool_input` and `tool_use_id`.
2. `PermissionRequest` with the same `tool_input` (no `tool_use_id`) and `permission_mode`. **It fires for `AskUserQuestion` and `ExitPlanMode`**, so the installed `PermissionRequest` hook already sees the questions: no new registration (B3 later gave `AskUserQuestion` a synchronous entry of its own, to answer it).
3. About 6 s later, `Notification` `permission_prompt` with `"message": "Claude needs your permission"` (for a plan: "Claude Code needs your approval for the plan"). No question text. The hook keeps the more specific `PermissionRequest` card.

After a person answers, `PostToolUse` has `tool_input.answers` and `tool_response` [live, high].

**`ExitPlanMode`** [bin + live, high]: the model's own `plan`/`planFilePath` are dropped; Claude Code injects `{plan, planFilePath}` from the plan file on disk when there is one (markdown). In the live run the fake model wrote no plan file, so `tool_input` was `{}` (the hook then says "Claude has a plan ready").

**MCP elicitation** [bin + docs, high]: `Notification` with `notification_type` `elicitation_dialog` carries `message` and optional `title`. The separate `Elicitation` hook event (not installed) has `mcp_server_name`, `message`, `mode` (`form`/`url`), `url`, `elicitation_id`, `requested_schema`; `ElicitationResult` has `action` and `content`.

Notification types seen [docs + bin]: `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled`.

**Can a hook answer?** Yes [live, high]. A `PreToolUse` hook that prints

```json
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
  "updatedInput": {"questions": ["...unchanged..."],
                   "answers": {"Which database should we use?": "SQLite", "Which features?": "Export"}}}}
```

skips the dialog; the transcript shows "User answered Claude's questions", and neither `PermissionRequest` nor `Notification` fires.

- `allow` alone isn't enough: for `AskUserQuestion` and `ExitPlanMode` the dialog still shows unless `updatedInput` comes with it [docs + bin, high].
- `updatedInput` replaces the whole input, so `questions` must be echoed back. Answers are validated: keys must be the question text, labels the option labels (multi-select capped at the option count + 1) [bin, medium].
- Deny and ask rules still win over a hook's allow [bin, high].
- `PermissionRequest` can return `decision: {behavior: "allow", updatedInput}`; for these tools `allow` without `updatedInput` falls through to the dialog [bin, medium]. Answering through it works [live, high]: see **Answering through `PermissionRequest`** below.
- `Elicitation` hooks answer an MCP elicitation with `{action: "accept" | "decline" | "cancel", content}` [docs + bin, high].

**Timing** [live, high]: the dialog **waits for `PreToolUse`**: with a 6 s sleep the screen showed "running PreToolUse hook" and no dialog. A hook cut off by its `timeout` (default 600 s for command hooks [docs]) has its output discarded and the normal dialog appears. So a hook that holds `PreToolUse` open to wait for a remote answer freezes the terminal: the person can't answer there meanwhile. `PermissionRequest` doesn't (next section).

**Answering through `PermissionRequest`** (Claude Code 2.1.294, fake model server, temp HOME, a synchronous `PermissionRequest` hook):

- The dialog **doesn't wait** for it [live, high]: with the hook sleeping 10 s, the question dialog was on screen at 3 s, usable as always.
- When the hook then prints `{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow", "updatedInput": {"questions": [...unchanged...], "answers": {"<question text>": "<label>"}}}}}`, Claude takes it as the answer [live, high]: the TUI shows "User answered Claude's questions: … Allowed by PermissionRequest hook" and the model gets "Your questions have been answered: …". `PostToolUse` and `Stop` follow as after a terminal answer.
- A multi-select answer is the labels joined with ", " ("Auth, Export") [live, high], as the TUI writes it.
- When the person answers in the terminal first, Claude goes on at once (`PostToolUse`, `Stop` within a second) and **doesn't kill the hook**: it ran to its end 20 s later and its output was ignored; the model got only the terminal's answer [live, high]. So the hook must stop waiting by itself: the `resolve` on `PostToolUse` closes the card, which ends `needs-you answer-wait` (exit 4).
- The `Notification` `permission_prompt` about 6 s later still comes [live, high]; the `ask` card's marker (kind `permission`) keeps it from replacing the card.
- Built as the hook's `ask` mode (B3). End to end with the installed hooks, a real hub and the reader token's `POST /v1/items/{id}/answer` [live, high]: the card was answerable 0.9 s after the prompt, the click reached Claude ("Postgres", "Auth, Search"), and the card was resolved by the `PostToolUse` that followed; with an answer in the terminal instead, the wait ended in the same second.

**Safe:** posting the card from `PermissionRequest` (async, prints nothing); waiting in a synchronous `PermissionRequest` hook for an answer from the card (the dialog stays usable; the first answer wins). **Unsafe:** a long synchronous `PreToolUse` wait; auto-approving `ExitPlanMode` (it also changes the permission mode).

## Codex CLI

Version 0.161.0 (source tag `rust-v0.161.0`, live with a fake Responses server and a temp `CODEX_HOME`).

**`request_user_input`** [src `core/src/tools/handlers/request_user_input_spec.rs`, high]: `{questions: [{id, header, question, options: [{label, description}]}]}`, all required; "prefer 1, at most 3" questions, header ≤ 12 characters, 2–3 mutually exclusive options; **no multi-select**. The TUI adds "None of the above" and a notes field [live]. A question without options is rejected.

**Where it works** [src, high]: on by default, but only in **Plan mode**; `[features] default_mode_request_user_input = true` (under development) allows it in Default mode. In `codex exec` it fails ("not supported in exec mode") [bin, medium].

**Events** [live, high]: `PreToolUse` fires; `PermissionRequest` doesn't.

```json
{"session_id": "01a1199c-…", "turn_id": "01a1199c-…", "hook_event_name": "PreToolUse", "model": "gpt-5.5",
 "permission_mode": "default", "tool_name": "request_user_input",
 "tool_input": {"questions": [{"id": "db_choice", "header": "Database",
   "question": "Which database should the service use?",
   "options": [{"label": "Postgres (Recommended)", "description": "Mature, already used by the team."},
               {"label": "SQLite", "description": "Zero ops, single file."}]}]},
 "tool_use_id": "call_q1"}
```

After the answer, `PostToolUse` with `tool_response` `{"answers": {"db_choice": {"answers": ["Postgres (Recommended)"]}}}`, then `Stop`. `permission_mode` stays `"default"` in Plan mode.

**Trap** [live, high]: in Default mode the model is still offered the tool; if it calls it, `PreToolUse` fires, then the call is refused ("unavailable in Default mode"): no question is shown and no `PostToolUse` follows, only `Stop`. The hook resolves a question card on `Stop` for this reason.

**Matchers** [src `hooks/src/engine/matcher.rs`, high]: a matcher of only letters, digits, `_` and `|` is an exact name list; anything else is a regex. We register `request_user_input`. A new hook entry has to be trusted once in `/hooks`.

MCP elicitation raises a client event and fires no hook [src `core/src/session/mcp.rs`, high]. Plan approval ("Implement this plan?") is a TUI popup after the turn, not a tool: only `Stop` [src `tui/src/chatwidget/plan_implementation.rs`, high].

**Can a hook answer?** No [src `hooks/src/events/pre_tool_use.rs`, high]. `PreToolUse` can deny (the reason goes to the model as a tool error) or `allow` with `updatedInput` (rewrites the questions); no answer path. Answers come only from the client (`Op::UserInputAnswer`). Default hook timeout 600 s.

## Gemini CLI

Source 0.65.0 nightly (`google-gemini/gemini-cli`), not run live.

**`ask_user`** [src `packages/core/src/tools/ask-user.ts`, high]: `{questions: [{question, header, type: "choice" | "text" | "yesno", options?: [{label, description}], multiSelect?, placeholder?}]}`, 1–4 questions; a choice question has 2–4 options plus an automatic "Other". Denied in non-interactive mode [src `policy/policies/non-interactive.toml`, high].

**Events** [src `scheduler/scheduler.ts`, `hooks/hookSystem.ts`, high]:

- `BeforeTool`: `{session_id, transcript_path, cwd, hook_event_name, timestamp, tool_name: "ask_user", tool_input: {questions}}`. Runs before policy and confirmation; Gemini waits for it. **This is the one with the question**; we register it with matcher `^ask_user$` (Gemini matchers are regexes, src `hooks/hookPlanner.ts`).
- `Notification` `ToolPermission` for `ask_user`: `message: "Tool requires confirmation"`, `details: {type: "ask_user", title: "Ask User"}`; the questions are dropped. The hook posts nothing for it (the `BeforeTool` card stands).

A yes/no question has no options; the hook shows Yes and No as its choices.

Plan approval: `exit_plan_mode` (`plan_filename`), a confirmation of type `exit_plan_mode` with `planPath`; the notification has only the generic message [src `tools/tools.ts`, high]. The card says "Gemini wants approval for a plan", no plan text.

**Can a hook answer?** No [src `hooks/types.ts`, high]: `decision` (block/deny/ask), `reason`, `continue` and `hookSpecificOutput.tool_input`; denying hands the model "Tool execution blocked".

## opencode

Source 1.18.35, not run live.

**`question` tool** [src `packages/schema/src/v1/question.ts`, `opencode/src/tool/question.ts`, high]: `{questions: [{question, header, options: [{label, description}], multiple?}]}`; header "max 30 chars" (a description, not enforced). Enabled for the app, CLI and desktop clients or with `OPENCODE_ENABLE_QUESTION_TOOL`.

**`question.asked`** [src `question/index.ts`, high]: `{id: "que_…", sessionID, questions: [{question, header, options, multiple?, custom?}], tool?: {messageID, callID}}` (`custom` defaults to true: "Type your own answer"). Plugins get it from the `event` hook. `question.replied`: `{sessionID, requestID, answers: string[][]}`; `question.rejected`: `{sessionID, requestID}`. The plugin now passes `question`, `header`, `options` (`label`, `description`) and `multiple` to the hook, each cut to a fixed length.

Plan exit (`plan_exit`) asks through the same service: header "Build Agent", options Yes/No, `custom: false` [src `tool/plan.ts`, high], so it arrives as a question card.

**Can a plugin answer?** Yes [src `server/routes/instance/httpapi/groups/question.ts`, high]: `POST /question/{requestID}/reply` with `{"answers": [["Label"], …]}` (one array of labels per question, in order); `POST /question/{requestID}/reject`; `GET /question`. The plugin's `client` is the v1 SDK, which has no question methods, so a plugin would `fetch` against `PluginInput.serverUrl`. First reply wins; the server doesn't check the labels against the options.

## GitHub Copilot CLI

`@github/copilot` 1.0.63 (`app.js`, the last npm release with readable JS; 1.0.93 ships a compressed binary) and the [hooks reference](https://docs.github.com/en/copilot/reference/hooks-configuration).

**`ask_user`** [src app.js 1.0.63, high]: `{question, choices?: string[], allowFreeform?: bool}`; plain-string choices, no descriptions. SDK clients get `user_input.requested` and answer with `session.respondToUserInput` (an SDK interface, not a hook).

**Events**:

- `notification` `elicitation_dialog` [src 1.0.63, high]: fired only by an MCP server's `requestElicitation`, with `message = elicitation.message ?? "Information requested"` and `title: "Information requested"`. No options. The hook puts the message on the card as the question (and the plain card for the fallback text).
- `ask_user` fires no notification in 1.0.63 [src, high]; whether 1.0.93 does is unknown [low]. The integration README's "question" card was observed with 1.0.93, so a live check is due.
- `preToolUse` sees `toolName`/`toolArgs` (`tool_name`/`tool_input`), so it has the question and choices [docs, high]. **Not registered**: until 1.0.93's behavior is checked live, a second card source could race the notification on the same key.

Plan approval: `exit_plan_mode` with `{summary, planContent, actions, recommendedAction}` [src, medium]; no hook registered for it.

**Can a hook answer?** No [docs, high]: `preToolUse` returns `permissionDecision`, `permissionDecisionReason`, `modifiedArgs`.

## Kimi Code CLI

Installed 2.0.0 (`~/.kimi-code/bin/kimi`), source `MoonshotAI/kimi-code` at 21406fb, live with a fake chat server and a temp HOME.

**`AskUserQuestion`** [src `agent/tools/ask-user-question/ask-user-question.ts`, high]: 1–4 `questions`, each `{question, header?, options, multi_select?}`; header ≤ 12 characters; 2–4 options `{label, description?}`. `tool_input` is the model's raw arguments: missing `header`, `multi_select` or `description` stay missing [live, high] (the TUI shows "Q2"; the card says "Question 2").

**Events** [live, high]: `PreToolUse` (auto-approved, so no `PermissionRequest`):

```json
{"hook_event_name": "PreToolUse", "session_id": "session_0157e278-…", "client_type": "kimi_code_cli",
 "session_title": "please ask me", "tool_name": "AskUserQuestion",
 "tool_input": {"questions": [
   {"question": "Which database should the service use?", "header": "Database",
    "options": [{"label": "Postgres (Recommended)", "description": "Mature, already used by the team."},
                {"label": "SQLite", "description": "Zero ops, single file."}]},
   {"question": "Which extras do you want?", "multi_select": true,
    "options": [{"label": "Metrics"}, {"label": "Tracing", "description": "OpenTelemetry"}]}]},
 "tool_call_id": "call_AskUserQuestion_1"}
```

`PostToolUse` then has `tool_output` with the answers keyed by question text. In `auto` permission mode the tool is denied by policy [src, high]; whether `PreToolUse` fires first there is unverified [low] (the hook resolves a question card on `Stop` either way).

**`ExitPlanMode`** [src + live, high]: `tool_input` is `{options?: [{label, description?}]}` (1–3; Approve, Reject, Reject and Exit and Revise are reserved), **no `plan`**. In plan mode a `PermissionRequest` follows with `display: {kind: "plan_review", plan, path, options}` (`options` only when there are 2 or more). The card shows `display.plan`'s first lines and the options as steps. `PermissionResult` has `decision` and `selected_label`.

**Can a hook answer?** No [src `agentExternalHooksService.ts`, `runHook.ts`, high]: `PermissionRequest`/`PermissionResult` are fire-and-forget; `PreToolUse` can only deny. A hook that times out (default 30 s) or fails counts as allow.

## Grok Build

1.0.46 ([docs](https://docs.x.ai/build/features/hooks), the repo's own captures in `tests/test_grok.py`). No `PermissionRequest` event; its `Notification` has `notificationType` and a generic `message` ("Waiting for your next prompt") [repo, medium]. No documented ask-user tool [docs, low]. `PreToolUse` has `toolName`/`toolInput` and can only deny (default timeout 5 s) [docs, medium]. Nothing to show today.

## Cursor

[Hooks docs](https://cursor.com/docs/agent/hooks): no hook for questions or notifications; `preToolUse` output `permission`, `user_message`, `agent_message`, `updated_input` ("ask" accepted, not enforced) [docs, high]. The `AskQuestion` tool fires no hooks at all, and `preToolUse`/`postToolUse` don't fire in Plan mode; Cursor staff called it a bug ([forum 152230](https://forum.cursor.com/t/askquestion-tool-does-not-trigger-cursor-hooks/152230), [161836](https://forum.cursor.com/t/cursor-cli-askquestion-tool-skips-pretooluse-and-posttooluse-hooks/161836)) [medium]. No route to the question text.

## Cline

Source: VS Code 4.1.23 / CLI 3.0.69, both on the SDK.

**`ask_question`** [src `sdk/packages/core/src/extensions/tools/schemas.ts`, high]: `{question: string, options: string[]}` (2–5, no descriptions, one question); "equivalent to classic `ask_followup_question`".

**`PreToolUse`** [src `core/src/hooks/subprocess.ts`, `apps/vscode/src/sdk/hooks-adapter.ts`, high]: `preToolUse: {toolName, parameters: Record<string, string>}`; non-string values are JSON-encoded, so `parameters.options` is a string like `'["A","B"]'`. The SDK/CLI payload also has `tool_call: {id, name, input}` with the array. Blocking: VS Code waits up to 30 s, the SDK 120 s. **Not registered**: it runs for every tool call, and it's unknown which Cline hook fires when the person answers (the card's resolve); a live check comes first.

**Can a hook answer?** No: `cancel`, `errorMessage`, `contextModification`, `review`, `overrideInput` [src, high].

## Aider

Source `aider/io.py` [src, high]: `confirm_ask(question, default, subject, explicit_yes_required, group, allow_never)` prompts `(Y)es/(N)o` plus `/(A)ll`, `/(S)kip all` and `/(D)on't ask again`; `prompt_ask` is free text. The `--notifications-command` runs with no arguments, no stdin and no question text. No hook API; only `--yes-always` answers.

## What phase A does with this

- **Shown**: Claude Code (`PermissionRequest` for `AskUserQuestion` and `ExitPlanMode`), Codex (`PreToolUse` for `request_user_input`, new registration), Gemini (`BeforeTool` for `ask_user`, new registration), opencode (`question.asked` through the plugin), Kimi (`PreToolUse` for `AskUserQuestion`, `PermissionRequest` for `ExitPlanMode`), Copilot (`elicitation_dialog` message).
- **Not shown, needs a live check first**: Copilot's `ask_user` through `preToolUse`; Cline's `ask_question` through `PreToolUse`; Claude Code's `Elicitation` event (its `requested_schema` enums could become choices).
- **Not possible today**: Grok, Cursor, Aider.

## Answering: what's possible and safe

| Agent | Path | Blocks the terminal while waiting? | Safe for phase B? |
|---|---|---|---|
| Claude Code | `PreToolUse` `allow` + `updatedInput.answers` | **yes**: the dialog waits for the hook | only with a short `timeout`, and the person can't answer locally meanwhile |
| Claude Code | `PermissionRequest` `decision.behavior: allow` + `updatedInput.answers` | no: the dialog shows while the hook waits, and a terminal answer wins (live, 2.1.294) | **yes**: built (B3) |
| Claude Code | `Elicitation` `action` + `content` (MCP) | the dialog waits | same trade-off as `PreToolUse` |
| opencode | plugin `POST /question/{id}/reply` | no: the plugin answers out of band, the TUI shows the question meanwhile | **yes**: the best fit |
| Everyone else | none (deny-with-reason only) | | no |

Rules for any answer path: never answer a permission prompt or a plan approval, never pick a default or answer on timeout, only labels the agent offered (no free text from the card), and only after an explicit click on the Mac.

## Turn ends: the last message and the session's name

Research for "finished" vs "asks" turn cards and session names in titles (built: the hook's `turn_card`, `session_name`). Tags as above. A turn card says **<Agent> asks: <question>** only when the hook has the turn's final text and its last line ends with "?" (outside code or a table); otherwise **<Agent> finished**.

| Agent | Turn-end event the card comes from | Final text | Session name |
|---|---|---|---|
| Claude Code 2.1.294 | `Notification` `idle_prompt` (about 60 s later; its payload has only `message`, `transcript_path`) | the transcript's last main-thread assistant entry's `text` blocks [live, high]. `Stop` also carries `last_assistant_message` [live, high], but the card isn't posted from `Stop` | `/rename` appends `{"type":"custom-title","customTitle":...}` once [live, high]; the auto title is `{"type":"ai-title","aiTitle":...}`, appended again on later turns [live, high]. `UserPromptSubmit` carries `session_title` after a rename [live, high]; `Stop` and `Notification` don't |
| Codex CLI 0.161.0 | `Stop` | `last_assistant_message` (nullable) [src `hooks/src/schema.rs`, high] | `/rename` appends `{"id","thread_name","updated_at"}` to `$CODEX_HOME/session_index.jsonl`, newest line wins [src `rollout/src/session_index.rs` + live, high]; `id` is the hook's `session_id` |
| Gemini CLI 0.65 nightly | `AfterAgent` | `prompt_response` [src, high] | none found [low] |
| opencode 1.18.35 | `session.idle` / `session.status` idle (plugin) | none in the event; the plugin keeps the latest assistant message's text from `message.updated` (role) and `message.part.updated` (`type: "text"`) [src `sdk/js/src/gen/types.gen.ts`, medium] | `session.updated` `info.title`; the placeholder is `New session - <date>` [src `session/session.ts`, high] |
| Kimi Code 2.0.0 | `Stop` | none: `stopHookActive` and the session facts only [src `agentExternalHooksService.ts`, high] | `session_title` on every event once the session has one (custom or generated) [live 2.1.1 + src, high] |
| Copilot CLI 1.0.63 | `agentStop` | none (`stopReason`, `transcriptPath`) [src, high] | none found [low] |
| Grok Build 1.0.46 | `Notification` `idle_prompt` | none in `idle_prompt`; `Stop` has `lastAssistantMessage` [live], but Stop isn't registered | none found [low] |
| Cursor | `stop` | none (`status`, `transcript_path` in an undocumented format) [docs, medium] | none [docs] |
| Cline (VS Code) | `TaskComplete` | `taskComplete.taskMetadata.result` [src, medium] | none found [low] |
| Aider | the notifications command | none (no payload) [src, high] | none |

Not done, needs more: Grok's question would need a `Stop` registration that stashes it for `idle_prompt`; Copilot's `events.jsonl` and Cursor's transcript may hold the final text but their formats weren't checked.

**Where:** the card's where line adds the terminal app from the environment (`TERM_PROGRAM`: `iTerm.app`, `Apple_Terminal`, `ghostty`, `WezTerm`, `WarpTerminal`, ...; `KITTY_WINDOW_ID`, `ALACRITTY_WINDOW_ID`; inside tmux, `TERM_PROGRAM` is `tmux`, so the outer terminal is guessed from inherited variables; over SSH, `LC_TERMINAL` or `LC_NEEDS_YOU_TERM`). For Claude Code in an editor, the workspace: the VS Code extension sets `CLAUDE_CODE_SSE_PORT`, and Claude Code 2.1.294 reads `workspaceFolders` and `ideName` from `<config dir>/ide/<port>.lock` [bin, medium]; the hook reads those two fields and never the lock's `authToken`. Other agents in a VS Code terminal: the environment doesn't name the workspace.
