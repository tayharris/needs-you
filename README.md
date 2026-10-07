# needs-you

One inbox for "you have to do something". AI agents, servers and CI post an item when they're blocked on you; your Mac shows it in a small floating pill, with a link to where you act, and it disappears once it's handled.

Open source, [Apache-2.0](LICENSE). **Status: early preview (0.1.x).**

## Get started

Trying it out? Start with **[the tester guide](docs/guides/testers.md)**: download, first run and how to report problems, on one page.

Words used below: the **hub** is the small service that stores items (the Mac app runs one for you, so your Mac is the hub); a **sender** is any machine or agent that posts items, with only the `needs-you` command, no app; your **tailnet** is your private [Tailscale](docs/guides/tailscale.md) network, which lets other machines reach the Mac. Reader, owner, server hub and the rest: [Words](docs/guides/concepts.md).

1. **Download** the latest release from the repository's [Releases page](https://github.com/tayharris/needs-you/releases) (macOS 14 or later): `NeedsYou-X.Y.Z.dmg` (open it and drag `NeedsYou.app` to `/Applications`), or `NeedsYou-X.Y.Z-macos.zip` (unzip, then drag). `SHA256SUMS` on the same page checks either: `shasum -a 256 -c SHA256SUMS`.
2. **First launch.** The app is ad-hoc signed, not notarized, so macOS blocks it once. On macOS 14 and earlier: right-click `NeedsYou.app` → **Open** → **Open**. On macOS 15 and later: double-click it, then **System Settings → Privacy & Security → Open Anyway**. The release notes have the full steps (firewall prompt, managed Macs). The built-in hub needs `/usr/bin/python3` from Apple's Command Line Tools; if Settings says Python 3 isn't available, run `xcode-select --install` and reopen the app.
3. **Connect a machine.** Right-click the pill (the small, faint shape at the top right of the screen) → **Settings…** → **Connect a machine** (under **Inbox and machines** in the sidebar) → **Create invite**, then click **Agent prompt** and paste it into Claude Code (on this Mac or any server on your tailnet), or click **Shell one-liner** and run it there. The machine installs the `needs-you` CLI and posts a test card.

Next:

- [Quickstart](docs/guides/quickstart.md): the whole setup, step by step.
- [Claude Code alerts everywhere](docs/guides/claude-code-everywhere.md): one copy-paste path to "my Claude sessions alert my Mac", on the Mac, over SSH, in tmux, VS Code Remote-SSH and Orca.
- [Tailscale](docs/guides/tailscale.md): connecting servers to the Mac.
- [Claude Code](docs/guides/claude-code.md), [Orca](docs/guides/orca.md) and [GitHub](docs/guides/github.md) integrations.
- [AGENT-GUIDE.md](docs/AGENT-GUIDE.md): the rules agents follow when they post.

To build from source instead: `mac/scripts/bundle.sh` (see [mac/README.md](mac/README.md)).

## Goal

needs-you is AI-first. It gives AI agents the tools to set themselves up (hand an agent an invite link and it installs and configures itself) and to alert a person only when they actually need that person, routed to where they act: a deep link to the ticket, the PR or the Orca terminal. Humans stay in the loop without watching terminals.

Roadmap: [docs/roadmap/](docs/roadmap/). Design decisions: [docs/adr/](docs/adr/).

## How it works, in three steps

1. **Install the Mac app.** `NeedsYou.app` is a small floating panel that all but disappears when nothing is waiting, and it runs its own hub (a tiny HTTP + SQLite service). Nothing else to set up.
2. **Connect Claude Code on the Mac.** Right-click the pill → **Settings…** → **Connect a machine** → **Create invite**, copy the **Agent prompt**, and paste it into Claude Code: *"Set up needs-you alerts on this machine: read &lt;link&gt; and follow it."* The agent reads the link, installs the `needs-you` CLI, and from then on posts when it's blocked on you.
3. **Connect servers over Tailscale.** Same thing on any VM, devbox or CI runner: paste the prompt into its agent, or run the one-liner the link gives you. One link can set up several machines; each gets its own revocable token.

```
 agents, CI, cron          needs-you CLI                 your Mac
 on servers or the Mac ──► (fails over, queues  ──────►  NeedsYou.app
                            while the Mac sleeps)        └─ its own hub (HTTP + SQLite)
                                                             ▲
                         optional: always-on server hubs ────┘ replicate
```

Items sent while the Mac sleeps are queued on the sender and delivered when it wakes (each sender retries every 5 minutes). If you'd rather never wait, add one or two always-on [server hubs](docs/HUB.md) that replicate with the Mac.

**[Quickstart](docs/guides/quickstart.md)** walks through all of it.

## Sending, in one minute

```bash
needs-you add --key "work:ACME-123:deploy-approval" --priority urgent \
  --title "ACME-123: approve the prod deploy" --body "Staging is green; the PR has the diff." \
  --link "PR=https://github.com/example/app/pull/42"

needs-you resolve --key "work:ACME-123:deploy-approval"     # once it's handled
```

Re-posting the same key updates the item instead of stacking duplicates, and the sender clears it once it's handled. The rules agents follow are in [AGENT-GUIDE.md](docs/AGENT-GUIDE.md).

## Guides

| Guide | For |
|---|---|
| [Testers](docs/guides/testers.md) | Invited testers: access, install, first run, reporting problems |
| [Quickstart](docs/guides/quickstart.md) | The Mac app, local Claude Code, servers |
| [Words](docs/guides/concepts.md) | Hub, sender, reader, owner, invite link, server hub, tailnet, and the Settings page for each |
| [Mac app](docs/guides/mac-app.md) | Installing and using `NeedsYou.app` |
| [Add a sender](docs/guides/add-a-sender.md) | Invite links, the installer's options, CI and cron |
| [Claude Code](docs/guides/claude-code.md) | Hooks for "agent is waiting", plus a skill |
| [Claude Code everywhere](docs/guides/claude-code-everywhere.md) | Alerts from local, SSH, tmux, VS Code Remote-SSH and Orca sessions |
| [Tailscale](docs/guides/tailscale.md) | Putting the Mac and servers on one tailnet, checking reachability |
| [Orca](docs/guides/orca.md) | Orca agents and automations, on one or many servers |
| [GitHub](docs/guides/github.md) | Review requests, deploy approvals, failed CI and your PRs' state, from one poller |
| [Server hubs](docs/HUB.md) | Optional always-on hubs, two-hub setup, backups |
| [Troubleshooting](docs/guides/troubleshooting.md) | When an item doesn't show up |
| [Keeping up to date](docs/guides/updates.md) | The Mac app updating itself, `needs-you update` on senders, `scripts/rollout.sh` |

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

Reference: [AGENT-GUIDE.md](docs/AGENT-GUIDE.md) (the sender contract), [API.md](docs/API.md) (the HTTP API), [ADRs](docs/adr/README.md) (design decisions, starting with [0007](docs/adr/0007-founding-design.md)).

## Config

- **Hubs** are configured by a JSON text file (Python's standard library reads it; no YAML dependency) or entirely by command-line flags, plus the admin CLI `needs_you_admin.py` for tokens and invites.
- **The Mac app** holds its own list of hubs and runs its own hub; you never edit a file on the Mac.
- **Senders** keep `~/.config/needs-you/env` (hub URLs and a token), written for them by the invite installer.
- **No hub web UI, by design.** The `/join/<code>` pages (Markdown for agents, plus an install script) are the only browser-friendly surface.
- **Network:** Tailscale is recommended (hubs listen on loopback and the tailnet IP, never on all interfaces), but any `https` URL works. Plain `http` is only for tailnet names and local addresses.

## Requirements

- Mac: macOS 14 or later with `/usr/bin/python3` (the Command Line Tools). Tailscale if servers should reach it.
- Senders and server hubs: `bash`, `curl` and `python3` 3.9+, stock on macOS and Ubuntu 22.04+. No pip, no brew, no build step.

## Repo layout

```
needs-you/
├── hub/            needs_you_hub.py, needs_you_admin.py, join-install.sh (the invite installer)
├── cli/            needs-you: the sender CLI, one Python file
├── mac/            NeedsYou.app (Swift/SwiftUI), which runs hub/ as a child process
├── scripts/        install-hub.sh (server hubs), setup-sender.sh (manual sender setup)
├── integrations/   claude-code/ (hooks, skill), orca/ (prompt snippets), ci/ (Actions, cron, systemd), github/ (poller)
├── deploy/         systemd units and an example hub config
└── docs/           guides/, AGENT-GUIDE.md, API.md, HUB.md, roadmap/, adr/
```

## Future

- **GitHub org webhooks** (for example, alerts for every repo in a GitHub org): today, use the Tailscale GitHub Action to join the tailnet from a workflow and post with the CLI ([integrations/ci](integrations/ci/README.md)). Later, possibly Tailscale Funnel exposing only a narrow `/hooks` path on one hub.
