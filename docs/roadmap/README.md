# Roadmap

Plans, and the record of plans that are built. Each file's status line says what exists on `main` (as of 2026-10-09, release 0.3.0). Once a plan is built, how it works for users lives in the [guides](../guides/); the plan keeps only what's still to do. Design decisions that are already made live in [../adr/](../adr/).

**Choosing what's next:** [next-big-item.md](next-big-item.md) compares the always-on hub, the iPhone widget, the Focus filter and GitHub webhooks, and recommends one, with a first plan. The owner decides.

## Plans with work left

| Plan | Status | What's left |
|---|---|---|
| [next-big-item.md](next-big-item.md) | Its recommendation is built (0.3.0) | The four candidates compared; the pick, peering the Mac's hub with an always-on hub (ADR 0004 phases 1–2, [ADR 0012](../adr/0012-mac-hub-peers.md)), shipped in 0.3.0. Left: the iPhone widget, the Focus filter, GitHub webhooks |
| [status-and-usage.md](status-and-usage.md) | Mostly built in 0.3.0: usage meters (status records), the ORCA panel section, `needs-you orca`, Claude and Codex usage cards, the "PR merged" card | The Orca accounts usage poller, the progress strip from status records (deferred by ADR 0011), a deploy-finished CI recipe |
| [ios-widget.md](ios-widget.md) | Plan | iPhone app and widgets: reaching a hub from a phone, refresh and push, shared Swift core |
| [future.md](future.md) | Plans | GitHub org webhooks, Discord/Slack fallback for urgent items, team mode, in-app help and onboarding, keyboard navigation in the open panel |
| [ai-first.md](ai-first.md) | MCP server and `doctor` built | A machine-readable API spec, a conformance suite, the repo moves, routing |
| [focus-tiers.md](focus-tiers.md) | Steps 1–8 built | The macOS Focus filter (spike first), the Interrupt sound, one sentence in the sender contract |
| [human-gates.md](human-gates.md) | Mostly built | A deploy-approval CI template, a tmux marker, auto-mode signals, an Orca watchdog, peeking near a card's target |
| [linking.md](linking.md) | Steps 1–9 built | `claude-cli` links (opt-in), Ghostty and VS Code spikes, remote tmux; the link security model |
| [rollout-updates.md](rollout-updates.md) | Items 1–14 built | An automatic updater for server hubs |
| [ci-cd.md](ci-cd.md) | Phases 1–2 built | Signing and notarization (needs a Developer ID) |
| [distribution.md](distribution.md) | Releases published | Homebrew tap, a `curl \| bash` server install from a release, Developer ID |
| [site-deploy.md](site-deploy.md) | Live at needsyou.app | Turning on the `site.yml` deploy |
| [sharing-checklist.md](sharing-checklist.md) | Public | Developer ID, self-hosted runners on a public repo, a fresh-user run |
| [launch-prep.md](launch-prep.md) | Mostly built | A donate link, repo topics and a social preview image |
| [fresh-user-test-plan.md](fresh-user-test-plan.md) | Not run yet | Install from a release on a second Mac or user account |
| [questions.md](questions.md) | Phases A and B built | What each agent's hooks carry when it asks a question, and which can answer. [ADR 0009](../adr/0009-questions-on-cards.md) phase B (the `question` field, answering from the card, typed "Other" answers) is built; left: agents whose hooks can't take an answer |

## Done, kept for the record

| Plan | What |
|---|---|
| [stale-items.md](stale-items.md) | Cards that outlive their sender: process leases, expiry backstops, the age badge and Dismiss All |
| [integrations-next.md](integrations-next.md) | Research behind the Kimi Code, Grok Build, Cursor, Cline and Aider integrations (all shipped in 0.1.5) |
| [doc-test-findings.md](doc-test-findings.md) | The 2026-10-06 doc walk-through and the bugs it found (fixed) |
| [friends-message.md](friends-message.md) | Draft message inviting testers ([testers.md](../guides/testers.md) is their install page) |

## Checklists for the owner

| Plan | What |
|---|---|
| [test-plan-2026-10-08.md](test-plan-2026-10-08.md) | After 0.1.4: preview layout, hub restart, real-model agent checks (Codex, Gemini, opencode, Copilot, Kimi, Grok, Cursor, Cline, Aider), `--mcp`, `--agent-instructions`, the site demo |
| [test-plan-2026-10-07.md](test-plan-2026-10-07.md) | The first Mac session after 2026-10-07: panel and alert settings, stale cards, focus tiers, updates, GitHub gates, the terminal jump, the DMG |

Related decision in progress: [ADR 0004: an always-on hub](../adr/0004-always-on-hub.md) (Proposed; phases 1–2 are built as [ADR 0012](../adr/0012-mac-hub-peers.md)). The phone widget and GitHub webhooks both depend on it.

## Licensing

Apache-2.0 (`LICENSE`). The repo is public on GitHub.
