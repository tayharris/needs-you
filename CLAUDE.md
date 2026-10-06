# needs-you: contributor guide for agents

needs-you is one inbox for "you have to do something". The product goal is AI-first: **give AI agents the tools to set themselves up and to alert people only when they actually need them, routed to where they need to act.** Senders (agents, servers, CI) post items; the Mac app shows them in a floating pill. By default the hub runs inside the Mac app; optional always-on server hubs replicate for redundancy. Machines and agents join with invite links.

The agent-facing entry points are first-class product surface, not docs afterthoughts. Treat changes to them like API changes:

- `docs/AGENT-GUIDE.md`: the sender contract (when to post, keys, rules).
- `integrations/claude-code/skill/needs-you/SKILL.md`: the Claude skill senders install.
- `integrations/claude-code/` hooks: "agent is waiting" cards.
- Invite flow: the Mac app's "Invite a machine" agent prompt, the hub's join page and the `curl` one-liner (in progress, see below).

## Repo map

| Path | What |
|---|---|
| `hub/needs_you_hub.py` | The hub: HTTP + SQLite, peer replication. One file, stdlib only |
| `hub/needs_you_admin.py` | Token admin (`token add/list/revoke`), writes the DB directly |
| `cli/needs-you` | Sender CLI: one Python file, offline outbox, hub failover |
| `mac/` | `NeedsYou.app` (SwiftPM). `NeedsYouCore` = testable logic, `NeedsYou` = AppKit/SwiftUI app |
| `scripts/` | `install-hub.sh` (systemd hub), `setup-sender.sh` (sender machine) |
| `deploy/` | systemd unit, example hub config, admin wrapper |
| `integrations/` | `claude-code/` (hooks, skill), `orca/` (prompt blocks), `ci/` (Actions, cron, systemd) |
| `tests/` | Python `unittest` suite for hub, CLI, validation, replication |
| `docs/` | `API.md` (wire contract), `HUB.md`, `AGENT-GUIDE.md`, `PLAN.md` (design + decisions), `guides/` |
| `docs/adr/` | Architecture decision records |
| `docs/roadmap/` | Plans only, nothing implemented |
| `site/` | Static landing page (Cloudflare Pages, no build) |
| `.claude/skills/` | Project skills: `test-all`, `smoke-e2e`, `api-change`, `add-integration`, `release` |

## Build and test

```bash
/usr/bin/python3 -m unittest discover -s tests      # hub + CLI; use the system 3.9 on macOS
mac/scripts/test.sh                                  # NeedsYouCore tests (XCTest, or MiniXCTest without Xcode)
mac/scripts/bundle.sh                                # release build -> mac/dist/NeedsYou.app, ad-hoc signed
NEEDS_YOU_DEMO=1 mac/dist/NeedsYou.app/Contents/MacOS/NeedsYou &   # run with fixture items, no hub
python3 -m http.server -d site 8000                  # preview the site
```

Run the hub locally: `python3 hub/needs_you_hub.py --bind 127.0.0.1 --port 8765 --db /tmp/ny.db` and mint a token with `python3 hub/needs_you_admin.py --db /tmp/ny.db token add me`. The `smoke-e2e` skill does a full round trip.

New Swift test classes must be registered in `mac/Sources/NeedsYouSelfTest/main.swift` and symlinked there (see `mac/README.md`).

## Hard rules

1. **Python is stdlib-only and 3.9-compatible** (`/usr/bin/python3` on macOS). `from __future__ import annotations`; no `match`, no runtime `X | Y` unions, no `tomllib`. No pip, no new dependencies anywhere (Swift packages included) without an ADR.
2. **The panel never takes focus or activates the app.** `FloatingPanel` keeps `canBecomeKey`/`canBecomeMain` false and `FloatingPanelTests` guards it. No text fields or focusable views in the panel. Only an explicit user click on Settings may activate the app.
3. **Tokens are never logged, printed (except once at mint), committed, or put in item text.** The hub stores sha256 only. The same goes for peer secrets and invite codes.
4. **Hubs bind loopback or the tailnet only.** Never `0.0.0.0`/`::` by default; the hub refuses them unless explicitly overridden.
5. **No personal hostnames or tailnet names outside `docs/PLAN.md`.** Use `hub-a.example.ts.net`, `<tailnet>`, `devbox`.
6. **API changes update everything in one change:** `docs/API.md`, the hub, the CLI if it's affected, the Mac client (`mac/Sources/NeedsYouCore/HubClient.swift`, `Models.swift`), and tests. Unknown fields stay ignored both ways. Use the `api-change` skill.
7. **Link scheme allow-list** (`https`, `orca`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`) is enforced in both the hub and `LinkPolicy.swift`. Change both or neither.
8. Senders must never fail the caller's job: the CLI exits 0 when it queues, and hooks always exit 0.

## In flux

Invites are being built on `tay/hub-invites-cleanup` and `tay/mac-connect-invites` (an `owner` role, `/v1/invites`, `/v1/invites/redeem`, `needsyou://connect?hub=…&code=…` and `http://<hub>/join/<code>` links, the hub embedded in the app). Read the code on `main` before relying on any of these names.

## Git

- Branches: `tay/<slug>` (or `tay/ACME-1234-slug` when there's a ticket). Use a name you're given byte for byte.
- One worktree per branch. Don't push or open PRs unless asked.
- Commit in small, reviewable chunks. End every commit message with the trailer:

  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```

  (use the exact model name your harness gives you).
- No LICENSE file yet: the license is chosen at public launch. Don't add one.
