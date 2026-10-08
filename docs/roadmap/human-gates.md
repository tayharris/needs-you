# Human gates: which agent-workflow events should reach a person

Status (2026-10-08): mostly built and shipped (0.1.2 onward). What's left below is still plan: a deploy-approval CI template, a tmux window marker, auto-mode signals, an Orca automation watchdog, and peeking near a card's target app.

needs-you exists to interrupt a person only when an agent or a job actually needs them. This plan listed the events in agent coding workflows that are real human gates and how to hook each one. Almost all of it is a **sender integration: no wire change**.

## Built, and where it's documented

| Gate | Guide |
|---|---|
| Claude Code `PermissionRequest` with specific titles (plan approval, a question, the program a command runs, the file an edit changes), `StopFailure`, `quota_auto_resume_disabled` | [Claude Code](../guides/claude-code.md) (the same shape for Codex, Copilot, Kimi and Grok in their guides) |
| GitHub notifications poller and the my-PRs pass (review requested, deployment approval, failed CI on your branches, PRs ready to merge, changes requested, conflicts, failing checks) | [GitHub](../guides/github.md) |
| Long jobs: `needs-you run -- <cmd>` (a card on failure, a `done` FYI after a long success) | [Add a sender](../guides/add-a-sender.md#cron-systemd-ci), [AGENT-GUIDE](../AGENT-GUIDE.md#wrapping-a-command-needs-you-run) |
| Previews on the display you're working on, and an edge glow for urgent arrivals | [Mac app](../guides/mac-app.md) (Settings → Alerts → On the work screen) |

Decisions made while building: plan approval is `normal` priority like every agent card (`NEEDS_YOU_AGENT_PRIORITY` changes all of them); the GitHub poller runs on **one** always-on machine; a `ci_activity` card is skipped for the head branch of one of your open PRs, which the PR's checks card covers.

Not gates (don't build): `SubagentStop`, `TaskCompleted`, every `Stop`, every failed check on a branch that isn't yours or `main`, `subscribed` notifications.

## Still plan

### Peek near the card's target

Peeking on the work display is built. Peeking on the display that holds the card's target app (the Orca, iTerm2 or VS Code window from the card's links or `source.agent`) isn't. Same method: `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` gives each window's owner pid and bounds without Screen Recording permission. Pure choice logic goes in `WorkDisplay.swift` with tests.

### Orca automations that crash or never run

Orca's CLI lists scheduled automations (`orca automations ...`). The prompt block's `work:<automation>:failed` key relies on the agent itself, so an automation that crashed or never ran posts nothing. A watchdog from cron would catch it, if `orca automations list --json` reports the last run's time and outcome. Spike that first.

### Build list

1. **Deploy-approval template** (sender-only). `integrations/ci/github-actions.yml`: a commented `notify-approval` job that runs before an environment-gated job, posts `work:<repo>:deploy:<run_id>` with the run link, and a first step in the gated job that resolves it. Docs: `integrations/ci/README.md`.
2. **tmux marker** (sender-only, opt-in). Hook: when `NEEDS_YOU_TMUX_MARK=1` and `TMUX_PANE` is set, `tmux set-option -w -t "$TMUX_PANE" @needs_you 1` on notify, `-u` on resolve. README: the `window-status-format` snippet (`#{?@needs_you,!,}`). Tests: fake `tmux` on `PATH` in the hook harness.
3. **Auto-mode signals** (sender-only, opt-in). `PermissionDenied` → needs/low "Auto mode blocked <tool>: <project>"; with `NEEDS_YOU_AGENT_RISKY=1`, `PreToolUse` on `Bash` whose first word is in a fixed list (`terraform`, `kubectl`, `helm`, `git push --force` detected by argv) and `permission_mode` is `bypassPermissions` → info "Claude ran <word> unattended". Tests: fixture payloads in the hook harness (`tests/hook_case.py`).
4. **Orca watchdog spike**: check `orca automations` output for last-run status; if it has it, a cron script posts `work:orca:<automation>:stale` when an automation hasn't run in 2× its interval. Write up the findings in `integrations/orca/README.md` before building.
