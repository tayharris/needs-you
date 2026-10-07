# Roadmap

Mostly plans. Each file's status line says what exists; `ci-cd.md` phases 1–2 are built. Each plan lists concrete steps, the files it would add, and its open decisions. Design decisions that are already made live in [../adr/](../adr/).

| Plan | What |
|---|---|
| [ci-cd.md](ci-cd.md) | GitHub Actions: Python tests (Ubuntu + macOS system python3.9), Mac build and tests, shellcheck; tag → release packages, checksums, GitHub Release; signing and notarization; one `VERSION` file; changelog |
| [distribution.md](distribution.md) | Release zip, Homebrew tap, `curl \| bash` server install, Gatekeeper and SentinelOne notes for ad-hoc builds, updates |
| [site-deploy.md](site-deploy.md) | Cloudflare Pages for `site/`, domain options, docs hosting |
| [ai-first.md](ai-first.md) | The AI-first product goal: repo structure review, `protocol/` spec and conformance suite, MCP server, `needs-you doctor`, routing |
| [ios-widget.md](ios-widget.md) | iPhone companion app and widgets: reaching a hub from a phone, refresh and push options, shared Swift core, opening the right app |
| [sharing-checklist.md](sharing-checklist.md) | What's done to share the repo, what waits on decisions (license, visibility, history, bundle id, Developer ID), and license options |
| [fresh-user-test-plan.md](fresh-user-test-plan.md) | Install from a release on a second Mac or user account: Gatekeeper, no Command Line Tools, firewall, Invite and Access |
| [friends-message.md](friends-message.md) | Draft message inviting testers, with the links they need ([testers.md](../guides/testers.md) is their install page) |
| [doc-test-findings.md](doc-test-findings.md) | The 2026-10-06 doc walk-through and the bugs it found (fixed) |
| [future.md](future.md) | GitHub org webhooks, Discord/Slack fallback for urgent items, team mode, in-app help and onboarding, jumping to an agent's terminal from a card |
| [launch-prep.md](launch-prep.md) | Next up: the minimal site, a repo ready to install from (DMG, README, guides, open source and donate links), and the Mac UI pass (settings, panel size, alert brightness, hotkey) |
| [stale-items.md](stale-items.md) | Cards that outlive their sender (killed sessions, missed resolves): process leases, expiry backstops, app-side dismiss |
| [linking.md](linking.md) | Cards that open exactly where you act: VS Code/Cursor (local, Remote-SSH, the Claude tab), terminal tab jumps (iTerm2, Terminal, WezTerm, tmux), Claude Code links, GitHub/Slack/Jira/Linear; the link security model |
| [rollout-updates.md](rollout-updates.md) | Mac app auto-update gated on a published, passing release; senders updating from their hub (`needs-you update`, `/dl/manifest.json`); per-machine versions; `rollout.sh` fallback |
| [human-gates.md](human-gates.md) | Which agent-workflow events deserve a card (Claude Code `PermissionRequest` and plan approval, GitHub notifications and my PRs, long jobs) and showing cards on the work display |
| [focus-tiers.md](focus-tiers.md) | Delivery tiers (interrupt, ambient, later), in-app focus and macOS Focus filters, bypass rules, banners vs. the pill |

Related decision in progress: [ADR 0004: an always-on hub](../adr/0004-always-on-hub.md) (Proposed). The phone widget and GitHub webhooks both depend on it.

## Licensing

Apache-2.0 (`LICENSE`). The repo is private for now and is planned to go open source as a non-profit project; what's left before that is in [sharing-checklist.md](sharing-checklist.md).
