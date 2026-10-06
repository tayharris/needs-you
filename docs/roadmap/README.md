# Roadmap

Plans only: nothing in this folder is implemented. Each plan lists concrete steps, the files it would add, and its open decisions. Design decisions that are already made live in [../adr/](../adr/) and [../PLAN.md](../PLAN.md).

| Plan | What |
|---|---|
| [ci-cd.md](ci-cd.md) | GitHub Actions: Python tests (Ubuntu + macOS system python3.9), Mac build and tests, shellcheck; tag → release packages, checksums, GitHub Release; signing and notarization; one `VERSION` file; changelog |
| [distribution.md](distribution.md) | Release zip, Homebrew tap, `curl \| bash` server install, Gatekeeper and SentinelOne notes for ad-hoc builds, updates |
| [site-deploy.md](site-deploy.md) | Cloudflare Pages for `site/`, domain options, docs hosting |
| [ai-first.md](ai-first.md) | The AI-first product goal: repo structure review, `protocol/` spec and conformance suite, MCP server, `needs-you doctor`, routing |
| [ios-widget.md](ios-widget.md) | iPhone companion app and widgets: reaching a hub from a phone, refresh and push options, shared Swift core, opening the right app |
| [future.md](future.md) | GitHub org webhooks, Discord/Slack fallback for urgent items, team mode, in-app help and onboarding |

Related decision in progress: [ADR 0004: an always-on hub](../adr/0004-always-on-hub.md) (Proposed). The phone widget and GitHub webhooks both depend on it.

## Licensing

Open-source license TBD at public launch. The repo is private for now and is planned to go open source as a non-profit project. There is deliberately no LICENSE file yet; don't add one until the license is chosen.
