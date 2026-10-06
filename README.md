# needs-you

One inbox for **"you have to do something"**, fed by every VM, project, agent and CI job you own, and shown on your Mac as a small floating panel that all but disappears when nothing is waiting.

Automations and agents get blocked on people all the time: a decision, an approval, access they don't have. Usually that ends up in a log file or a ticket comment nobody is watching. With needs-you, anything on your tailnet can post "I need you for X" with one command, re-posting the same problem updates it instead of stacking duplicates, and the sender clears it once it's handled.

- **Hubs:** a tiny HTTP + SQLite service on 2–3 always-on machines that replicate to each other. Python 3 standard library only, so there's nothing to install.
- **Senders:** the `needs-you` CLI (one Python file, with an offline outbox and hub failover) or plain `curl`. Ready-made integrations for Claude Code, Orca, GitHub Actions, cron and systemd.
- **Mac app:** `NeedsYou.app`, a floating panel that shows on every Space and display, including over full-screen apps. It shows the count, cards with links, snooze, work and personal hours, and a start-of-day summary.
- **Tailscale only:** hubs listen on their tailnet address, never on a public port.

```
 senders                                  hubs (always on)                  Mac
 ───────                                  ────────────────                  ───
 VMs, cron, systemd ─┐
 Claude Code hooks ──┤  needs-you CLI     ┌──────────┐   replicate   ┌──────────┐
 Orca automations ───┼─ (fails over, ───► │  hub-a   │ ◄───────────► │  hub-b   │
 GitHub Actions ─────┘   queues offline)  │ HTTP +   │               │ HTTP +   │
                        or curl           │ SQLite   │               │ SQLite   │
                                          └────▲─────┘               └────▲─────┘
                                               └──── polls / SSE, ────────┘
                                                     fails over
                                                         │
                                                  NeedsYou.app (pull only)
```

The Mac only pulls. It can sleep, travel and drop off VPN; senders keep writing to the hubs and the app catches up when it's back.

## Get started

**[Quickstart](docs/guides/quickstart.md)**: two hubs, the Mac app, a first sender and Claude Code alerts, in about 15 minutes.

| Guide | For |
|---|---|
| [Quickstart](docs/guides/quickstart.md) | End-to-end setup |
| [Mac app](docs/guides/mac-app.md) | Installing and using `NeedsYou.app` |
| [Hub](docs/HUB.md) | Running and peering hubs, minting tokens |
| [Add a sender](docs/guides/add-a-sender.md) | A new VM, project or CI repo |
| [Claude Code](docs/guides/claude-code.md) | Hooks for "agent is waiting", plus a skill, in any repo |
| [Orca](docs/guides/orca.md) | Orca agent sessions and automations |
| [Troubleshooting](docs/guides/troubleshooting.md) | When an item doesn't show up |

Reference:

- [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md): the sender contract (when to post, keys, CLI and curl, rules). Give this to anything that should send alerts.
- [docs/API.md](docs/API.md): the HTTP API.
- [docs/PLAN.md](docs/PLAN.md): design decisions and build order.

## Sending, in one minute

```bash
./scripts/setup-sender.sh        # installs the CLI, saves hub URLs + token, checks health

needs-you add --key "personal:hub-b:backup-failed" --context personal --priority urgent \
  --title "hub-b nightly backup failed" --body "restic exit 1 at 03:00. Disk 97% full." \
  --link "Logs=https://hub-b.example.ts.net/logs"

needs-you resolve --key "personal:hub-b:backup-failed"     # once it's fixed
```

## Repo layout

```
needs-you/
├── hub/                    needs_you_hub.py (+ admin tool): HTTP + SQLite, peer replication
├── cli/                    needs-you: the sender CLI, one Python 3 file
├── mac/                    NeedsYou.app (Swift/SwiftUI, NSPanel)
├── scripts/
│   ├── install-hub.sh      set up a hub under systemd
│   └── setup-sender.sh     set up a sender machine
├── integrations/
│   ├── claude-code/        hooks, install-hooks.sh, and a skill
│   ├── orca/               prompt blocks for Orca automations
│   └── ci/                 GitHub Actions, cron and systemd examples
├── deploy/                 service files for the hub
└── docs/
    ├── guides/             task-oriented guides (start here)
    ├── AGENT-GUIDE.md      sender contract
    ├── API.md              HTTP API
    ├── HUB.md              hub operations
    └── PLAN.md             design
```

## Requirements

- A Tailscale tailnet.
- Hubs and senders: `python3` 3.9+ and `curl` (stock on Ubuntu and macOS). Nothing else.
- Mac: macOS with Tailscale running. Building the app needs Xcode or the Swift toolchain; see [mac/README.md](mac/README.md).

## Rules of thumb for senders

Post only when you're blocked on a person, when something they're waiting on finished (`done`), or when something broke that they need to know today. Use stable keys, put the action in the title, link to where they act, resolve what you post, and never send secrets. The full list is in [AGENT-GUIDE.md](docs/AGENT-GUIDE.md#rules).
