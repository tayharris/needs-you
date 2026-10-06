# Roadmap

Mostly plans. Each file's status line says what exists; `ci-cd.md` phases 1–2 are built. Each plan lists concrete steps, the files it would add, and its open decisions. Design decisions that are already made live in [../adr/](../adr/) and [../PLAN.md](../PLAN.md).

| Plan | What |
|---|---|
| [ci-cd.md](ci-cd.md) | GitHub Actions: Python tests (Ubuntu + macOS system python3.9), Mac build and tests, shellcheck; tag → release packages, checksums, GitHub Release; signing and notarization; one `VERSION` file; changelog |
| [distribution.md](distribution.md) | Release zip, Homebrew tap, `curl \| bash` server install, Gatekeeper and SentinelOne notes for ad-hoc builds, updates |
| [site-deploy.md](site-deploy.md) | Cloudflare Pages for `site/`, domain options, docs hosting |
| [ai-first.md](ai-first.md) | The AI-first product goal: repo structure review, `protocol/` spec and conformance suite, MCP server, `needs-you doctor`, routing |
| [ios-widget.md](ios-widget.md) | iPhone companion app and widgets: reaching a hub from a phone, refresh and push options, shared Swift core, opening the right app |
| [sharing-checklist.md](sharing-checklist.md) | What's done to share the repo, what waits on decisions (license, visibility, history, bundle id, Developer ID), and license options |
| [fresh-user-test-plan.md](fresh-user-test-plan.md) | Install from a release on a second Mac or user account: Gatekeeper, no Command Line Tools, firewall, Invite and Access |
| [doc-test-findings.md](doc-test-findings.md) | The 2026-10-06 doc walk-through and the bugs it found (fixed) |
| [future.md](future.md) | GitHub org webhooks, Discord/Slack fallback for urgent items, team mode, in-app help and onboarding |

Related decision in progress: [ADR 0004: an always-on hub](../adr/0004-always-on-hub.md) (Proposed). The phone widget and GitHub webhooks both depend on it.

## Licensing

Open-source license TBD at public launch; options and a suggestion are in [sharing-checklist.md](sharing-checklist.md#license-options). The repo is private for now and is planned to go open source as a non-profit project. There is deliberately no LICENSE file yet; don't add one until the license is chosen.
