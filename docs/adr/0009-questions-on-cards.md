# 0009. Questions and choices on cards

- Status: Accepted (2026-10-08): phases A, B1, B2 and B3 (Claude Code, after the live check) built
- Date: 2026-10-08

## Context

When a coding agent asks the person something (Claude Code's `AskUserQuestion`, a plan to
approve, opencode's `question` tool, Kimi's `AskUserQuestion`, an MCP elicitation), the hooks
used to post a card that said only "<Agent> asked you a question". The person had to go to the
terminal to learn **what** was asked before they could decide whether it was urgent. The goal
([0005](0005-ai-first.md)) is to route people to where they act with enough on the card to
decide; a question and its choices are exactly that.

What each agent's hook actually carries is in
[roadmap/questions.md](../roadmap/questions.md). In short: Claude Code (`PermissionRequest`),
Codex (`PreToolUse`), Gemini CLI (`BeforeTool`), opencode (`question.asked`) and Kimi Code
(`PreToolUse`) hand a hook the full question: text, header, choices with descriptions,
single or multiple choice. Claude Code and Kimi also hand over the plan of a plan approval.
Copilot CLI's MCP elicitation hands over a one-line message. Copilot's own `ask_user` and
Cline's `ask_question` are visible only to a pre-tool hook we don't register yet; Grok,
Cursor and Aider show nothing. Only two agents let anything answer: Claude Code (a
`PreToolUse` hook returning `updatedInput.answers`, which holds the terminal dialog back
while it runs) and opencode (a plugin calling `POST /question/{id}/reply`, out of band).

Constraints:

- **The panel never takes focus** ([CLAUDE.md](../../CLAUDE.md) rule 2). Choices can only be
  buttons; a free-text answer can't be typed on the card.
- **Questions can quote anything**: code, env, a token pasted into the chat. Hard rule 3 says
  tokens never go in item text.
- **A sender token can't read the inbox** (`GET /v1/items` is reader-only, by design): a hook
  that wants an answer back has no way to see one today.
- Senders must never fail or block the caller's job (rule 8): a hook that waits for an answer
  must never hold an agent hostage.
- The hub's limits: title 100 characters, body 2,000, at most 10 steps of 200 characters each.

## Decision

Phase A shipped with no API change. Phase B adds the `question` field (B1) and answering (B2, B3).

### Phase A: the question on the card, read-only (built)

1. **Title** names the question: `Claude asks “Which database should we use?”: my-repo`, with
   `and N more` for a multi-question prompt, clamped to the hub's 100 characters.
2. **Body** holds each question's text (up to 8 lines each, about 1,200 characters in all),
   under its header in bold with "choose one" or "choose any", then "Answer in <Agent>; the
   choices below are what it offered." The usual "where" lines (folder, host, tmux, session)
   follow. Multi-question prompts are **one card** (one wait = one card, as everywhere else),
   each sub-question a headed section.
3. **Steps** are the choices, one per option: `Label — description`, prefixed with the
   question's header when there are several questions (`Auth: GitHub — OAuth`). At most 10:
   past that, the options are dealt in turn across the questions (so each question shows some)
   and the tenth step says `+N more choices in <Agent>`.
4. **Plan approval** (`ExitPlanMode` in Claude Code and Kimi) is titled
   `Claude wants approval for a plan` and the body holds the plan's first 12 non-blank lines
   (900 characters, Markdown headings turned into bold lines, code fences dropped), then
   "Approve or reject it in Claude." Kimi's plan options (when it offers 2–3) become steps.
   Gemini's plan confirmation has no plan text, so its card only says what it is.
5. **Every piece of agent text** (question, header, label, description, plan, an MCP
   elicitation's message, an API error message) is cleaned and redacted before it is clamped:
   control, C1, zero-width and bidi characters removed; `ny_…`/`nyi_…` tokens, `sk-…`,
   `ghp_…`/`github_pat_…`, `xox?-…`, `AKIA…`, `glpat-…`, `AIza…`, JWTs, PEM private keys,
   `Bearer`/`Basic`/`token` headers, `password=`/`api_key:`-style values, hex runs of 32+ and
   base64-like runs of 40+ characters become `[redacted]`. Redaction runs before clamping, so
   a cut never leaves half a token that slipped past the pattern.
6. `NEEDS_YOU_AGENT_QUESTIONS=0` (environment or the sender env file) restores the old cards:
   no question text, no choices, no plan text.
7. If the CLI or hub refuses the steps, the card is posted again without them (the question is
   still in the body).

Steps were the only structured, already-replicated place for the choices. Their meaning on
the Mac is "a checklist the person ticks off", which fits choices badly: a tick there is local
and answers nothing. The body says where to answer, and phase B replaces steps with a real
field.

### Phase B: a `question` field and answers by click

1. **Item field** `question` (optional, sender-written, replicated like `steps`):

   ```json
   "question": {
     "id": "toolu_01ABC",                 // the agent's request id; an answer names it
     "items": [{
       "header": "Database",              // <= 30 chars
       "text": "Which database should we use?",   // <= 500 chars
       "options": [{"label": "Postgres", "description": "Durable"}],  // 0-8, label <= 80, description <= 200
       "multi_select": false
     }],                                   // 1-4 items
     "answerable": true,                   // B2: the sender is waiting for an answer
     "expires_at": "2026-10-08T17:04:05Z"  // B2: the sender stops waiting then
   }
   ```

   Same text rules as every field (no control or bidi characters), validated by the hub and
   mirrored in `Models.swift`. Unknown fields stay ignored both ways. `steps` stays for
   to-do lists; a hook that sends `question` stops sending the choices as steps and lists
   them in the body instead (for clients that don't show the field yet). B1 (built on
   `tay/question-field`) has `id` and `items`; `answerable` and `expires_at` come with B2.
   Options may be empty (a free-text question, as Gemini and Claude's extended form allow).
2. **Answer** `POST /v1/items/{id}/answer` (reader or owner token; the Mac app):
   `{"question_id": "toolu_01ABC", "content_updated_at": "...", "answers": [{"selected": ["Postgres"]}]}`.
   The hub accepts it only while the item is open, `answerable`, not expired, the
   `question_id` matches and `content_updated_at` is the version the person saw (409
   otherwise: the question changed under them). Labels must be among the item's options: no
   free text, ever. First answer wins; a second gets 409. The answer is stored on the item
   (`answer`, `answered_at`, `answered_by` token name), replicated (LWW like the rest of the
   item), and the item stays open until the sender resolves it.
3. **Reading the answer** `GET /v1/items/answer?key=<key>` (sender token): only the token
   that posted the item may read its answer (the hub records the posting token's id on the
   item; a peer-replicated item records the peer's). This keeps "a sender can't read the
   inbox": it can read back one field of its own item. Long-poll up to 25 s, then 204.
4. **Waiting never blocks the terminal.** The sender waits only where the agent shows its own
   question at the same time, so the person can always answer there instead:
   - **opencode first.** The plugin is a long-lived process and answers out of band: on
     `question.asked` it posts the card with `question`, then runs
     `needs-you answer-wait --key K --timeout 600` (a new CLI command that long-polls
     step 3); on an answer it calls opencode's `POST /question/{id}/reply` with the labels.
     `question.replied` or `question.rejected` (the person answered in the TUI) stops the
     wait and resolves the card. First answer wins on opencode's side too.
   - **Claude Code second, after a live check.** A `PreToolUse` hook that waits holds the
     dialog back (measured), so it can't be used. The candidate is the `PermissionRequest`
     hook returning `decision: {behavior: "allow", updatedInput: {questions, answers}}`; it
     ships only if a live capture shows the dialog stays usable while that hook waits. If
     not, Claude Code stays phase A. (The live check passed: B3 below.)
   - Codex, Gemini, Kimi, Copilot, Cline, Grok, Cursor and Aider have no answer path: phase A.
   The wait ends at the first of: an answer, the agent's own answer or rejection event, the
   item resolved, or the timeout (no answer is sent then).
5. **Never auto-answer a permission prompt.** Answers exist only for questions (choices the
   agent offered), never for tool permission, plan approval or MCP sign-in. The hook never
   picks a default, never answers on timeout, and never sends an answer it didn't get from an
   explicit click on the Mac.
6. **The panel never takes focus.** Each option is a button on the card (multi-select:
   toggle buttons plus one Send). Clicking one sends the answer without activating the app
   or making the panel key. Free text ("Other") is not offered on the card: the card's
   button says "Answer in the terminal" and the Terminal link does the rest.
7. **Which token may answer:** any `reader` or `owner` token of the inbox (the person's Macs).
   Sender tokens can't answer, so one compromised agent machine can't answer another agent's
   question. The answer endpoint is rate-limited like PATCH.

**Recommended phase B**, in this order, each a separate change through the `api-change` skill:

- **B1:** the `question` field (hub, CLI `--question-json`, Mac model, `API.md`, replication),
  posted by every phase A hook instead of choices-as-steps, and rendered read-only by the Mac
  as option rows (no tick boxes). No answering yet. This alone fixes the checklist mismatch.
- **B2:** `POST /v1/items/{id}/answer`, `GET /v1/items/answer` (poster only, long-poll), CLI
  `needs-you answer-wait`, option buttons on the Mac, and the opencode plugin answering
  through `POST /question/{id}/reply`. opencode is the only agent where an answer from the card
  never competes with a blocked terminal. Built on `tay/question-answers`. As built: PATCH has
  no rate limit to copy, so answers have their own (30 a minute per token), and reads of an
  answer too (120 a minute, at most 4 long polls open per token). A re-post by another token
  clears the answer, so only the token that asked reads it. The opencode reply was checked
  against opencode 1.18.35's source (the `question` HttpApi group: `POST
  /question/:requestID/reply` with `{"answers": [[label, ...], ...]}`); the plugin sends it
  through its own SDK client (in-process when opencode runs without a port). Not yet run
  against a live opencode.
- **B3:** Claude Code through `PermissionRequest`, only after a live capture shows its dialog
  stays usable while the hook waits. **Built** on `tay/claude-answers` after the live check
  (Claude Code 2.1.294, fake model server, temp HOME; [roadmap/questions.md](../roadmap/questions.md#claude-code)):
  the dialog is on screen while a synchronous `PermissionRequest` hook waits; an `allow` with
  `updatedInput: {<the tool input>, answers: {"<question>": "<label>"}}` (a multi-select's
  labels joined with ", ") is taken as the person's answer; and an answer in the terminal
  first wins, with the hook left running and its later output ignored. As built: a second
  `PermissionRequest` entry, matcher `AskUserQuestion`, synchronous, runs the hook's `ask` mode
  (post the card, `needs-you answer-wait`, print the decision); the `notify` entry's matcher
  `^(?!AskUserQuestion$)` keeps it from posting a second card for the same question (Claude
  Code tests a matcher that isn't a plain list of names as a JavaScript RegExp, checked in
  2.1.294). The terminal's answer resolves the card (`PostToolUse`), which ends the wait
  (`answer-wait` exits 4). A card is answerable only when it shows every question and label
  exactly and the answer can be keyed back unambiguously (no two questions alike, no ", " in a
  multi-select label); the hook checks the click against the question again before printing.

## Consequences

- Phase A: the person sees the question and the choices on the card and can decide from the
  pill. Codex and Gemini get one new hook registration each (Codex asks to trust it once in
  `/hooks`). Question and plan text now leave the machine (redacted and clamped); before, only a
  fixed title did. `NEEDS_YOU_AGENT_QUESTIONS=0` is the opt-out, and the agent guides say so.
- Phase A's choices render as a checklist with tick boxes on the Mac, and the card offers
  "All steps done" once all are ticked. That reads oddly for choices; the body says where to
  answer. A Mac-side tweak (no tick box for an item whose agent posted choices) is possible
  without an API change but is left to phase B, which replaces the steps.
- Redaction is best effort. Token-shaped text is caught; a secret that looks like a word is
  not. The question text is the agent's own words to the person, not tool input, so the risk
  is lower than for commands, which the hooks still never send.
- Phase B is an API change (the `api-change` skill): hub, CLI (`needs-you add --question-json`,
  `needs-you answer-wait`), Mac client, `API.md`, replication and tests together, plus a hub
  schema migration. It adds the first path by which a sender reads anything back from the
  hub; the scope (one field of one item, the poster's own) is the security boundary to review.
- An answer from the card can race an answer in the terminal; the agent takes whichever
  arrives first, and the hook's late answer is ignored by the agent.

## Amendment (2026-10-08): an answerable question's labels must differ

A security review found that an answerable question could offer two options with the same
label (for example two "Yes" options with different descriptions). An answer carries labels
only, so the sender couldn't tell which one the person clicked, and could act on the other.
The hooks already refused to post such a card answerable; now the hub refuses it too:
`POST /v1/items` answers `400` with the repeated option's `question.items[i].options[j].label`
when `answerable` is true and a question repeats a label. A read-only question may still
repeat one, and different questions may share labels.

This tightens validation, so it is a breaking change for a sender that posted such a
question: no sender in this repo did (the hooks keep those cards read-only), and the CLI
reports the `400` (exit 2). A replicated record with such a question from an older hub loses
its question, like any question this hub would refuse.
