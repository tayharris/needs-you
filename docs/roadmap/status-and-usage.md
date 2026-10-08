# Status and usage: Orca connections, "PR shipped" alerts, progress, usage meters

Status: plan. One piece is built: `integrations/claude-code/needs-you-usage`, a Claude Code status line helper that posts a low `info` card past a 5-hour or weekly usage threshold (off by default; see [integrations/claude-code](../../integrations/claude-code/README.md#usage-limit-card-optional)). Everything else here is research and options.

The owner's ask: more Orca connections and suggesting Orca for worktree-heavy setups, config so agents alert when a PR they opened ships, some way to see progress, and a small usage meter (session and weekly, per provider, multiple accounts, "like Orca does").

Confidence marks: **[high]** checked against a primary source or on this machine; **[medium]** from a primary source but not exercised; **[low]** secondhand or inferred.

## 1. Orca

### What exists

- **Agent cards from Orca terminals.** The shared hook switches itself on when `$ORCA_TERMINAL_HANDLE` is set, keys cards `agent:<host>:<handle>`, and adds the worktree (`$ORCA_WORKTREE_ID`), a `needsyou://orca/terminal?handle=…[&environment=…]` **Terminal** link and an `orca terminal switch` command to the body (`integrations/claude-code/needs-you-hook.sh`, `docs/guides/orca.md`). [high]
- **OrcaJump in the Mac app.** `mac/Sources/NeedsYou/OrcaJumpRunner.swift` and `NeedsYouCore/TerminalJump.swift` run `orca terminal switch --terminal <handle> --json [--environment <name>]` from a fixed path, no shell, 5 s timeout; with no environment named it tries each paired one from `orca environment list` (at most 8). The link grammar is mirrored in `LinkPolicy.swift` and the hub. [high]
- **Automations.** `integrations/orca/snippet.md` is the prompt block (installed by `--orca` to `~/.config/needs-you/orca-snippet.md`, kept current by `needs-you update`); `integrations/orca/README.md` has per-automation recipes. [high]
- **Several servers.** One invite with N uses gives each Orca server its own token; `NEEDS_YOU_ORCA_ENVIRONMENT` names the server as the Mac's Orca knows it. [high]
- **Doctor.** `needs-you doctor` prints an `orca` INFO line when `orca` is on `PATH` or the shell is an Orca terminal (handle, worktree id, environment name). [high]

### What the `orca` CLI offers (1.4.205 on this machine; `orca --help`, `orca agent-context --json`, 234 commands)

| Area | Commands | Useful for needs-you | Conf. |
|---|---|---|---|
| Worktrees | `worktree list/show/current/ps/set` | `worktree ps --json` rows carry `status` (`inactive`…), `workspaceStatus` (`in-progress`, `in-review`…), `liveTerminalCount`, `unread`, `lastActivityAt`, `linkedPR`, `linkedIssue`, `linkedLinearIssue`, `hostId`, `branch`, `displayName`, and a terminal `preview` (untrusted text). Its notes say each row names its host and the `scope:` line says which hosts the page covers | [high] (keys observed; values partly) |
| Terminals | `terminal list/show/read/wait --for tui-idle/switch` | `terminal list --json` per worktree; `terminal wait --for tui-idle` is a way to know an agent stopped. The JSON had no rows here (no live terminals), so whether it carries an agent state is unverified | [medium] |
| Agent status hooks | `agent hooks on/off/status` | Orca installs its own status hooks for claude, codex, gemini, cursor, copilot, grok, kimi and more (`agent hooks status` lists them). Orca therefore already knows "working / waiting" per terminal; how it exposes that state on the CLI is unverified | [medium] |
| Environments | `environment add/list/show/rm`, `host list`, `--environment` / `--pairing-code` on most commands | Every read above can target a paired server; `host list` says what each name reaches | [high] |
| Accounts | `account add --agent claude\|codex`, `account list --json` | Orca manages several Claude and Codex logins per host, and `account list --json` returns `result.rateLimits` with a slot per provider (`claude`, `codex`, `gemini`, `grok`, `kimi`, `minimax`, `antigravity`, `opencodeGo`) plus `claudeTarget`/`codexTarget`. All slots were `null` here (no managed accounts), so the inner shape is unverified. The JSON also has account emails: never copy those | [high] keys, [low] values |
| Orchestration | `orchestration ask`, `gate-create/resolve/list`, `task-*` | `gate-create` is Orca's own "decision blocking a task": a natural source for a needs-you card | [medium] |

### (a) Per-worktree agent status

Two shapes, cheapest first:

1. **Doctor and a `needs-you orca` read-only command** (no wire change): run `orca worktree ps --json` (and with `--environment` for each paired environment) and print one line per worktree: host, branch, `workspaceStatus`, live terminals, open needs-you cards keyed to that worktree's terminals. Useful for an agent to orient itself; nothing on the Mac. Cost: small. Value: low-medium.
2. **A status strip in the panel** (see section 2's "status surface"): the Mac app, which already shells out to `orca` for OrcaJump, polls `orca worktree ps --json` every 30-60 s while the panel is open and shows a compact row per active worktree (name, `in-progress`/`in-review`, a dot for "agent waiting" when a card from that terminal is open). No hub involvement, no wire change; it shows only the Mac's own Orca and its paired environments. Cost: medium (Swift UI, a runner like `OrcaJumpRunner`, parsing tolerant of unknown fields, tests). Value: high for Orca users. Risk: `preview` and names are untrusted and must not be rendered as links or markdown.

A card-per-status design (posting `info` per worktree) is not recommended: it turns the inbox into a dashboard and breaks the "only when they need you" rule.

### (b) Suggest Orca when the person runs many worktrees

- **Doctor INFO line** (cheap, no wire change): when `orca` is not on `PATH` and `git worktree list` in the current repo shows 3 or more worktrees, or the hook's state dir shows 3+ live agent sessions on this host, add `orca: INFO 5 worktrees with agents here; Orca can run and switch between them, and needs-you cards then get a Terminal button`. Never a WARN; never posted. Touches `cli/needs-you` (`Doctor.orca`) and `tests/test_doctor.py`.
- **Invite agent prompt / join page**: one optional sentence: "If this machine runs several agents in worktrees, Orca gives each card a jump-to-terminal button; add `--orca` if it's installed." Agent-facing copy, so it changes with the join page and `docs/AGENT-GUIDE.md` together.
- **Installer**: when `orca` is on `PATH` and `--orca` wasn't passed, print one INFO line suggesting it. Already half there (the installer knows the flag).

Owner decision: whether needs-you should recommend a third-party product at all, and with which link.

### (c) Several Orca environments

Today the Mac side is covered (OrcaJump tries each paired environment) and each server names itself with `NEEDS_YOU_ORCA_ENVIRONMENT`. Gaps:

- The server can't learn its own name automatically. Option: the invite (made on the Mac) could carry the environment name when the Mac's Orca lists a matching paired host; needs an invite-field change (API change).
- The status strip in (a2) should loop over `orca environment list` with the same 8-environment cap OrcaJump uses, and label rows by environment.
- Usage meters per Orca host (section 3) would read `orca account list --json` on each host; `account list` rejects `--environment`, so it has to run on the host (a sender-side poller, not the Mac).

## 2. "PR shipped" and progress

### What the GitHub poller covers today

`integrations/github/needs-you-github` (one machine, `gh`, every 5 min) posts review requests, deploy approvals, failed CI, mentions, assignments, and for **your open PRs**: `merge` (approved, green, mergeable), `changes`, `conflict`, `checks`, and **`merged`** (built: a `done` FYI when one of your PRs merges, on by default, `-merged` turns it off). There is no "deployed" FYI. [high]

### Options for "your PR shipped"

1. **Poller reason `merged`** (**built**, on by default; `-merged` in `NEEDS_YOU_GITHUB_REASONS` turns it off): the poller already tracks your open PRs in its state file. When a tracked PR leaves the open list, one GraphQL lookup (`merged`, `mergedAt`) decides it merged, and it posts `done` `<ctx>:gh:owner/repo#20:merged` "Merged owner/repo#20: *title*" (24 h FYI, never counted). Off unless listed in `NEEDS_YOU_GITHUB_REASONS` (`+merged`) or default on: owner decision. No wire change. Cost: small (poller + tests + README table row).
2. **Deploy finished**: `deployment_status` isn't a notification reason, so the poller would need `gh api repos/{o}/{r}/deployments` per watched repo: more calls. Better: CI posts it (`integrations/ci/run-or-alert.sh` style, a `done` at the end of the deploy job). Document as a recipe in `integrations/ci/README.md`. Cost: docs only.
3. **Agent-side config**: `NEEDS_YOU_PR_SHIPPED=1` read by the skill: "after you open a PR, if this is set, …" can't work, because the agent is long gone when the PR merges. Claude Code's status line input has `pr.number/url/review_state`, and the field disappears once the PR merges or closes [high, status line docs]; the usage helper could note "PR seen → gone" but can't tell merged from closed without `gh`. So agent-side is the wrong place; the poller is the right one. One cheap agent-side piece: the skill could tell agents to add `--link "PR=…"` to their `done` card so the poller's later cards and the agent's cards line up.

### Progress without progress cards

`docs/AGENT-GUIDE.md` forbids progress cards, and that rule is what keeps the pill trustworthy. Options:

| Option | What | Wire | Cost | Notes |
|---|---|---|---|---|
| A. `info` with short expiry | Agents post `needs-you info --key …:progress --expires-in 1` and re-post the same key | none | none | Allowed by the API today, but it is exactly what the guide forbids; it shows under Recent and re-animates on content change. Not recommended as a general pattern |
| B. Local status strip (Mac only) | The panel shows Orca worktree rows (1a2) and per-host agent states the app already knows from open hook cards | none | medium | Covers most "what are my agents doing" without senders posting anything new |
| C. A `status` record type on the wire | A new endpoint `PUT /v1/status/<key>` (or `kind: status`) with `label`, `state` (`working`/`waiting`/`idle`/`done`), `progress` 0-100 optional, `expires_at` mandatory and short (≤ 1 h), never counted, never animated, never notified; shown as a one-line strip, capped (e.g. 8 rows) | new endpoint or kind: **ADR + api-change** (hub, CLI `needs-you status`, Swift `HubClient`/`Models`, API.md, replication, tests) | large | The honest version of "progress". Rate-limit per token; replication could skip it (local-only) to keep peers quiet |

Recommendation: B first (no sender changes), then decide on C with an ADR once the strip exists and shows what's missing.

## 3. Usage meters

### Sources, by provider

| Provider | Read-only local source | Session (5 h) | Weekly | Conf. |
|---|---|---|---|---|
| Claude Code | **Status line stdin JSON**: `rate_limits.five_hour` / `seven_day` with `used_percentage` (0-100) and `resets_at` (epoch s); also `spend_limit` behind a Claude apps gateway. Present only for claude.ai Pro/Max (or a gateway with a spend limit) and only after the session's first API response; each window may be absent; dropped once `resets_at` passes. The status line re-runs on events (300 ms debounce), on `refreshInterval`, and when a window's `resets_at` arrives ([code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline)) | yes | yes | [high] |
| Claude Code | `/usage` in the TUI (what CodexBar scrapes through a PTY) | yes | yes | [medium] |
| Claude Code | An OAuth "usage" endpoint used by community tools, called with the token from `~/.claude/.credentials.json` or the macOS Keychain | yes | yes | [low] undocumented; **rejected**: needs-you would read a credential |
| Claude Code | `~/.claude/projects/**/*.jsonl` token counts (what ccusage sums) | estimate only | estimate only | [medium] tokens, not limits: can't give a percentage of a plan |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: `token_count` events carry `rate_limits` = `{limit_id, primary: {used_percent, window_minutes: 300, resets_at}, secondary: {used_percent, window_minutes: 10080, resets_at}, credits, plan_type}` (seen in this machine's April 2026 files; the newest file had none, so not every session/login writes it) | yes | yes | [high] shape, [medium] presence |
| Codex CLI | `/status`; `codex app-server` RPC (CodexBar's preferred source) | yes | yes | [low] secondhand |
| Gemini CLI | `/stats` shows per-session model usage; no local file with plan quota found | no | no | [low] |
| Copilot | Monthly premium requests; GitHub has billing REST endpoints for premium request usage (scope-gated); Copilot CLI shows per-session use | monthly only | no | [low] |
| Cursor | Dashboard only (cookie-authenticated web API used by community tools) | no | no | [low]; **rejected** (cookie) |
| Orca-managed accounts | `orca account list --json` → `result.rateLimits.<provider>` for claude, codex, gemini, grok, kimi, minimax, antigravity, opencodeGo. Orca holds the logins (including cookie-based ones like MiniMax); needs-you would read only the numbers | likely | likely | [high] the slots exist, [low] their shape (all null here) |

How others do multi-account: **Orca** registers each login (`orca account add`, a private browser window for a second account) and reports per-provider limits from its runtime [high for the commands]. **CodexBar** (macOS menu bar) shows a two-bar meter (5 h on top, weekly below) per provider, reading Codex via `codex app-server` or a PTY `/status` and Claude via a PTY `/usage`; sources disagree on whether it also uses browser cookies [low]. **ccusage** sums local JSONL tokens into 5-hour "blocks" and cost; it has no plan limits [medium].

### Design

Principles: numbers only, read locally by the agent's own machine, never credentials, never a token or email to the hub. The agent pushes; needs-you doesn't fetch.

1. **Threshold cards (built, Claude):** `needs-you-usage` wraps the status line, posts a low `info` card at `NEEDS_YOU_USAGE_ALERT_PCT` (weekly: `NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT`), key `agent:<host>:claude-usage[:<account>]:5h|7d`, expiring at the reset, re-posted per 5 points, resolved below the line. `NEEDS_YOU_USAGE_ACCOUNT` separates logins (e.g. one per `CLAUDE_CONFIG_DIR`).
2. **Codex threshold cards** (next, no wire change): the same check on the Codex `Stop` hook path, reading the newest `token_count.rate_limits` from the tail of the session JSONL (the hook already tails Claude transcripts the same way). Touches the shared hook: wait for the questions/choices work to land.
3. **Orca accounts poller** (after checking real `rateLimits` values): `needs-you usage --from orca` run by `flush` every 5 minutes on a host with Orca accounts, the same thresholds per provider and account (label = a hash or the account's Orca id, never the email).
4. **A meter in the pill/panel** (wire change): a small two-bar meter (5 h, weekly) per provider/account next to the count, colour only past the threshold. Needs the numbers on the Mac: either the status record from 2C (`status` key `usage:claude:<account>` with `progress` and `resets_at`), or a dedicated `usage` object. Either is an **ADR + api-change**. Config in Settings: which providers, session vs weekly vs both, thresholds, hide when under N%. Until then the threshold card is the meter.

## 4. Ranked build list

| # | Item | Value | Cost | Wire/ADR | Owner decision |
|---|---|---|---|---|---|
| 1 | Claude usage threshold card (`needs-you-usage`) | medium | small | none | **built**; default thresholds, and whether `--claude-hooks` should install it into `statusLine` (it would wrap any existing one) |
| 2 | GitHub poller `merged` reason → `done` card | high | small | none | **built**, on by default (`-merged` turns it off); the owner can flip the default |
| 3 | Doctor INFO "many worktrees → Orca" + installer hint | low-medium | small | none | recommend Orca by name/link? |
| 4 | Codex usage threshold card from session JSONL | medium | small-medium | none (shared hook) | same thresholds as Claude? |
| 5 | Mac status strip from local Orca (`worktree ps`), all paired environments | high for Orca users | medium | none (app-only) | show it by default when `orca` is present? |
| 6 | `needs-you orca` read-only summary for agents | low-medium | small | none | — |
| 7 | Orca accounts usage poller | medium | medium | none | after verifying `rateLimits` values on a host with managed accounts |
| 8 | Deploy-finished recipe for CI | medium | docs | none | — |
| 9 | `status` records on the wire (progress strip, usage meter, Orca rows from servers) | high | large | **ADR + api-change** | whether needs-you shows anything that isn't "you have to do something" |
| 10 | Pill usage meter with Settings choices | medium | medium after 9 | depends on 9 | providers, session/weekly, thresholds |
| — | Reading OAuth tokens or browser cookies for usage | — | — | — | **not doing**: violates the no-credentials rule |
