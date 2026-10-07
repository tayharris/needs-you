# Human gates: which agent-workflow events should reach a person

Status: plan, 2026-10-07. Step 6 (work-display peek, edge glow) is built on `tay/focus-tiers`.

needs-you exists to interrupt a person only when an agent or a job actually needs them. This plan lists the events in agent coding workflows (Claude Code, Orca, GitHub, CI and deploys, long jobs) that are real human gates, how to hook each one, and how to make the card visible on the screen where the work is without the panel ever taking focus. Almost everything here is a **sender integration: no wire change**.

## What's covered today

- **Claude Code hooks** (`integrations/claude-code/hooks.json`): `Notification` with `permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input` posts a `needs` card; `UserPromptSubmit`, `PostToolUse`, `Stop` and `SessionEnd` resolve it; a process lease plus a 48 h expiry clean up dead sessions ([stale-items.md](stale-items.md)). Titles are generic ("Claude needs permission: my-repo").
- **Orca automations:** the prompt block (`integrations/orca/README.md`) posts blockers with stable keys, resolves them, and posts `done` run summaries.
- **CI:** `integrations/ci/github-actions.yml` posts on a failed job and resolves on success; `run-or-alert.sh` wraps any command; a systemd `OnFailure=` template.
- **GitHub org webhooks:** planned in [future.md](future.md) (needs a public endpoint or a per-repo workflow).

## Findings

### Claude Code hook events (current docs)

From the [hooks reference](https://code.claude.com/docs/en/hooks), the events that matter for a human gate:

| Event | Fires when | Useful input | Gate? |
|---|---|---|---|
| `PermissionRequest` | A tool call needs a permission decision. Matches on tool name like `PreToolUse`; **includes `ExitPlanMode` (plan approval) and `AskUserQuestion`** | `tool_name`, `tool_input`, `permission_mode`, `requires_user_approval` | **Yes.** Better than `Notification/permission_prompt`: it says *what* is asked, so the title can be "Approve the plan: my-repo" or "Claude wants to run git: my-repo" |
| `Notification` | `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` (used today); also `agent_completed` (a background session finished or failed, only while agent view is open), `quota_auto_resume_fired/_stale/_disabled`, `auth_success`, `elicitation_complete/_response` | `notification_type`, `message` | Yes for today's types; `quota_auto_resume_disabled` (the run stopped on a usage limit and won't resume) is a gate; the others are noise |
| `StopFailure` | The turn ended because of an API error | common fields | **Yes**: the agent silently stopped |
| `PermissionDenied` | Auto mode denied a tool call | tool fields | Sometimes: in auto mode, a denied action often means the agent is stuck or working around a guard. `low` |
| `Stop` | Claude finished responding | | A gate only after a long unattended turn, and `idle_prompt` already covers "finished and waiting" after about a minute |
| `SubagentStop`, `TaskCompleted`, `TeammateIdle`, `PostToolUseFailure` | Subagent or task lifecycle | `agent_type`, `last_assistant_message` | No: progress, not gates. `TeammateIdle` might matter for agent teams later |
| `PreToolUse` | Before any tool call | `tool_input` | Not as an alert: anything risky in a normal permission mode already raises `PermissionRequest`. In `bypassPermissions` mode it's the only signal, see build step 6 |

Hooks can run `async: true` (today's hooks do), so they never delay the session.

`tool_input` can hold secrets (a `curl -H "Authorization: ..."` command, a file being written). Hard rule 3 and AGENT-GUIDE rule 5 apply: the card names the **tool and a safe summary** (for `Bash`, the first word of the command, `git`/`terraform`/`kubectl`; for `Edit`/`Write`, the file's basename), never the full input.

### GitHub

- **The Notifications API is the cheapest complete feed.** `GET /notifications` with `If-Modified-Since` returns `304` when nothing changed, which doesn't count against the rate limit, and `X-Poll-Interval` says how often to poll ([GitHub notifications](https://docs.github.com/en/rest/activity/notifications)). Each thread has a `reason`: `review_requested`, **`approval_requested` (a deployment is waiting for your approval)**, `ci_activity`, `mention`, `assign`, `author`, `security_alert`, `state_change`, `subscribed`. One poller on any sender machine with `gh` logged in (devbox) covers every repo and org Tay is in, with **no webhook and no public endpoint**: it's outbound HTTPS from a tailnet machine. That beats the webhook options in [future.md](future.md) for one person; webhooks stay the answer for team mode.
- **"My PRs" state** is better read directly: `gh pr list --author @me --state open --json number,url,reviewDecision,mergeable,statusCheckRollup,isDraft` (per repo, or `gh search prs --author @me --state open` across repos). That gives: approved and green (act: merge), changes requested, merge conflict (`mergeable: CONFLICTING`), checks failing. Each is a state with a natural resolve (the state goes away).
- **Deployment approvals** (environments with required reviewers): the run waits on "Review deployments" on its run page, and the reviewer gets an `approval_requested` notification, so the notifications poller covers it. A repo can also post from its own workflow (a job before the gated one posts "approve the prod deploy" with the run link; the gated job's first step resolves it), using the existing `github-actions.yml` pattern.
- Check-run and PR deep links are in [linking.md](linking.md).

### Orca

Orca's CLI covers worktrees, terminals (`list`, `read`, `send`, `wait`, `create`, `split`), and scheduled automations (`orca automations ...`) ([Orca CLI](https://www.onorca.dev/docs/cli/overview)). Agent sessions in Orca are Claude Code sessions, so the hook covers their gates (Orca sets `ORCA_TERMINAL_HANDLE`, which turns the hook on). Automations post through the prompt block. What's missing is an automation that **crashed or never ran**: the block's `work:<automation>:failed` key relies on the agent itself. A watchdog (`orca automations` listing last-run status, from cron) would catch it; to spike: does `orca automations list --json` report last run time and outcome?

### Long jobs

`run-or-alert.sh` posts on failure and resolves on success, but never says "your 40-minute build is done". The rule in AGENT-GUIDE is: `done` only for something the person is **waiting on**. A wrapper can tell by duration: a job that took more than N minutes (default 10) posts `done` on success.

### "Visible on the work screen"

What's possible without the panel taking focus (hard rule 2), using public APIs only:

| Idea | How | Permission | Notes |
|---|---|---|---|
| Already true | `collectionBehavior` `.canJoinAllSpaces`, `.fullScreenAuxiliary`: the pill is on every Space and over full-screen apps | none | Keep |
| **Peek on the display where you're working** | `NSWorkspace.shared.frontmostApplication` (pid) + `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` gives each window's owner pid, layer and bounds **without** Screen Recording permission (only window *titles* need it). The display holding the frontmost app's frontmost window is "the work screen"; the arrival preview springs out there, then the pill returns to its home | none | Pure choice logic is testable in Core |
| **Peek near the card's target** | For an Orca/iTerm/VS Code card, find that app's on-screen window bounds the same way and peek on that display | none | Uses the source app from the card's links or `source.agent` |
| **Edge glow for urgent** | A second borderless, click-through window (`ignoresMouseEvents = true`, `canBecomeKey = false`, same collection behaviour, `.statusBar` level) drawing a thin glow along the work display's edge for a few seconds | none | Never key, never main; guarded by a test like `FloatingPanelTests` |
| Which **Space** a window is on | No public API (only private CGS calls) | | Don't: the pill is on every Space anyway |
| **In the terminal itself** (sender-side) | The hook marks the tmux window: `tmux set-option -w -t "$TMUX_PANE" @needs_you 1` and a `window-status-format` snippet shows `!` on that window; resolve clears it | none | Works on remote tmux over SSH, where the Mac can't reach. Opt-in, documented status-line snippet |
| System notification banner | `UNUserNotificationCenter` | user approval | A separate decision about delivery tiers: [focus-tiers.md](focus-tiers.md) |

## Ranking

Value = how often it's a real gate for this owner and how much it costs to miss. Effort in sessions for one implementing agent.

| # | Trigger | Value | Effort | Change |
|---|---|---|---|---|
| 1 | `PermissionRequest` incl. **plan approval** (`ExitPlanMode`) and `AskUserQuestion`, with specific titles | High | 0.5 | Sender-only (hook + `hooks.json`) |
| 2 | **GitHub notifications poller**: review requested, deployment approval requested, CI on my PRs, mentions | High | 1 | Sender-only (new integration) |
| 3 | **My PRs**: approved + green, changes requested, conflicts, failing checks | High | 0.5 (with 2) | Sender-only |
| 4 | `StopFailure` and `quota_auto_resume_disabled`: the agent stopped and won't continue | Medium | 0.25 | Sender-only |
| 5 | **Long job finished**: `needs-you run -- <cmd>` (needs on failure, done on success after N min) | Medium | 0.5 | CLI only, no API |
| 6 | Peek on the work display + edge glow for urgent | Medium | 1 | Mac only |
| 7 | Deploy-approval step template for workflows (for repos whose reviewers aren't you) | Medium | 0.25 | Sender-only (CI template) |
| 8 | tmux window marker | Low–medium | 0.25 | Sender-only |
| 9 | `PermissionDenied` in auto mode; `PreToolUse` FYI for risky commands in bypass mode | Low | 0.5 | Sender-only |
| 10 | Orca automation watchdog | Low until the spike | 0.5 | Sender-only |

Not gates (don't build): `SubagentStop`, `TaskCompleted`, every `Stop`, every failed check on a branch that isn't yours or `main`, `subscribed` notifications.

## Recommendation

Do 1, 4, 2+3 in that order: they're all sender-side, need no API or Mac change, and cover the two places Tay actually gets blocked (an agent waiting for a decision, GitHub waiting for a review or approval). Then 5. Then 6 as part of the next Mac pass, together with [focus-tiers.md](focus-tiers.md), because both decide *how loudly* and *where* a card appears.

Keys follow AGENT-GUIDE rule 1: `agent:<host>:<session-or-handle>` (the hook's existing key, so a `PermissionRequest` card and a later `idle_prompt` card upsert the same item), `work:gh:<owner>/<repo>#<n>:<reason>`, `work:gh:deploy:<owner>/<repo>:<run-id>`, `<context>:<host>:run:<name>`.

## Build list

1. **`PermissionRequest` in the hook** (sender-only). `integrations/claude-code/hooks.json`: add `PermissionRequest` (matcher `.*`) → `needs-you-hook.sh permission`, `async: true`. `needs-you-hook.sh`: new `permission` mode that reads `tool_name`, `requires_user_approval` (skip when false) and a safe summary of `tool_input`. Titles: `ExitPlanMode` → "Approve Claude's plan: <project>" (priority from `NEEDS_YOU_AGENT_PLAN_PRIORITY`, default `normal`); `AskUserQuestion` → "Claude asked a question: <project>"; `Bash` → "Claude wants to run <first word>: <project>"; `Edit`/`Write` → "Claude wants to edit <basename>: <project>"; anything else → "Claude needs permission (<tool>): <project>". Same key as `notify`, so the later `permission_prompt` notification upserts instead of adding a second card; same marker and lease. Never put `tool_input` itself in the body. Tests: extend `tests/test_leases.py`/`tests/test_orca.py`-style hook harness with fixture inputs for each tool, asserting title, key and that no command text beyond the first word appears. Docs: `integrations/claude-code/README.md` event table, `docs/guides/claude-code.md`.
2. **`StopFailure` and quota notifications** (sender-only). `hooks.json`: `StopFailure` → `notify` with a synthetic type; add `quota_auto_resume_disabled` to the `Notification` matcher. Hook titles: "Claude stopped on an API error: <project>", "Claude hit its usage limit: <project>". Resolve paths unchanged (`UserPromptSubmit` clears them). Tests as in 1.
3. **`integrations/github/`: notifications poller** (sender-only). `integrations/github/needs-you-github` (Python stdlib, 3.9; calls `gh api` through `subprocess` with an argv list, so it uses the existing `gh` login and never reads the token itself). Every `X-Poll-Interval` seconds (min 60) from cron or a systemd user timer: `gh api -i /notifications` with `If-Modified-Since` (state in `~/.local/state/needs-you/github.json`). Map: `review_requested` → needs/normal "Review <repo>#<n>: <title>"; `approval_requested` → needs/urgent "Approve the deploy: <repo>"; `ci_activity` → needs/normal only when the subject is a run on a PR you authored or the default branch; `mention`/`assign` → needs/low; others ignored. Links: the PR's `/files`, the run page. Resolve when the thread is no longer unread or the PR closes. Each post via `needs-you add` with `--expires-in 48`. Tests: `tests/test_github.py` with recorded `gh` JSON (fixtures with example orgs only) and a fake `gh`. Docs: `integrations/github/README.md`, `docs/guides/github.md`, a row in `CLAUDE.md`'s repo map. Use the `add-integration` skill.
4. **My-PRs pass in the same poller** (sender-only). Every 5 minutes: `gh search prs --author @me --state open --json repository,number,url,title` then `gh pr view <url> --json reviewDecision,mergeable,statusCheckRollup,isDraft`. States → items: approved + all checks green → needs/normal "Merge <repo>#<n>"; `CHANGES_REQUESTED` → needs/normal; `CONFLICTING` → needs/normal "Resolve conflicts" (link `/pull/<n>/conflicts`); failing checks → needs/normal (link the failing check's `detailsUrl`). Drafts ignored. One key per PR and state; resolve when the state no longer holds. Tests: fixtures in `tests/test_github.py`.
5. **`needs-you run`** (CLI only, no API). `cli/needs-you run [--key K] [--title T] [--done-after MIN] [--context ...] -- <cmd...>`: runs the command (argv, no shell), passes its exit code through, posts `needs` on failure (title from `--title` or "<cmd> failed on <host>"), resolves the key on success, and posts `done` on success if it ran longer than `--done-after` (default 10). Never includes output. `integrations/ci/run-or-alert.sh` becomes a thin wrapper over it (kept for compatibility). Tests: `tests/test_cli.py` (exit codes pass through, offline queueing still exits with the command's code). Docs: AGENT-GUIDE "Posting", `integrations/ci/README.md`.
6. **Built** on `tay/focus-tiers` (Settings → Alerts → On the work screen: previews on the work display by default, edge glow off by default; peeking near a card's target app isn't built). **Work-display peek and urgent edge glow** (Mac only). Core: `mac/Sources/NeedsYouCore/WorkDisplay.swift`, pure: given screens' frames, window records (pid, layer, bounds) and the frontmost pid, return the display to peek on; tests in `WorkDisplayTests.swift` (registered and symlinked). App: `PanelController` asks it on arrival (using `CGWindowListCopyWindowInfo`, no Screen Recording permission) and peeks there; a new `EdgeGlowWindow` (borderless `NSPanel`, `ignoresMouseEvents`, never key or main, all Spaces) for urgent arrivals, with a setting (off / urgent only). Test: extend `FloatingPanelTests` to cover `EdgeGlowWindow`'s `canBecomeKey`/`canBecomeMain`.
7. **Deploy-approval template** (sender-only). `integrations/ci/github-actions.yml`: a commented `notify-approval` job that runs before an environment-gated job, posts `work:<repo>:deploy:<run_id>` with the run link, and a first step in the gated job that resolves it. Docs: `integrations/ci/README.md`.
8. **tmux marker** (sender-only, opt-in). Hook: when `NEEDS_YOU_TMUX_MARK=1` and `TMUX_PANE` is set, `tmux set-option -w -t "$TMUX_PANE" @needs_you 1` on notify, `-u` on resolve. README: the `window-status-format` snippet (`#{?@needs_you,!,}`). Tests: fake `tmux` on `PATH` in the hook harness.
9. **Auto-mode signals** (sender-only, opt-in). `PermissionDenied` → needs/low "Auto mode blocked <tool>: <project>"; with `NEEDS_YOU_AGENT_RISKY=1`, `PreToolUse` on `Bash` whose first word is in a fixed list (`terraform`, `kubectl`, `helm`, `git push --force` detected by argv) and `permission_mode` is `bypassPermissions` → info "Claude ran <word> unattended". Tests as in 1.
10. **Orca watchdog spike**: check `orca automations` output for last-run status; if it has it, a cron script posts `work:orca:<automation>:stale` when an automation hasn't run in 2× its interval. Write up the findings in `integrations/orca/README.md` before building.

## Open decisions

1. Plan approval priority: `normal` (default) or `urgent`? It blocks the whole session, but it's also frequent in plan-heavy workflows.
2. Which machine runs the GitHub poller (one only, or every machine with `gh`, deduped by key)? Recommended: one, the always-on devbox, since keys dedupe anyway.
3. `ci_activity` scope: only your PRs and default branches (recommended), or every workflow you triggered?
