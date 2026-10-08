# Quickstart

Three parts: **the Needs You app** on your Mac shows alerts in the pill; **a hub** stores them (the app has one built in, so there's nothing else to run); **senders**, the `needs-you` command and the agent hooks built on it, post them from any machine where agents or jobs run. Senders don't need the app; an invite link installs them. The words are explained under [Words](#words) at the end.

Four steps; only the first is required. Every step can be re-run safely until the invite link expires, even after its uses are spent (a machine that's already set up doesn't spend another).

```
 Claude Code / Orca on the Mac ──► 127.0.0.1 ──┐
                                               ├──► NeedsYou.app (pill + built-in hub)
 servers, VMs, CI ──── Tailscale ──────────────┘          ▲
                                                           │ optional: the app reads them
                                         always-on server hubs (HUB.md)
```

## 1. Install the Mac app (its hub is built in)

Download `NeedsYou-X.Y.Z.dmg` (or `NeedsYou-X.Y.Z-macos.zip`) from the repository's **Releases** page, drag `NeedsYou.app` to `/Applications` and open it. The app is ad-hoc signed, so macOS blocks the first launch: right-click → **Open** on macOS 14 and earlier, or **System Settings → Privacy & Security → Open Anyway** on macOS 15 and later ([mac-app.md](mac-app.md)). To build it yourself: [mac/README.md](../../mac/README.md).

The app starts its built-in hub as a child process (**Settings… → Built-in hub → Run hub on this Mac**, on by default): SQLite in `~/Library/Application Support/NeedsYou/hub.db`, listening on `127.0.0.1:8765` (and on your Mac's tailnet address if Tailscale is running). There are no tokens to mint and no config files to edit. The hub runs on `/usr/bin/python3`; if Settings says *Python 3 isn't available on this Mac*, run `xcode-select --install`, then quit and reopen the app.

A faint pill appears in a corner of the screen. That's the idle state. Until something posts, it reads `Nothing needs you · 1 setup tip`: click it for a **Connect your first agent or machine** card whose **Copy agent prompt** button does step 2 in one click (it makes a one-use invite and copies the prompt). Later tips cover Tailscale and the Claude Code hooks; each goes away once it's done, or when you dismiss it ([setup tips](mac-app.md#setup-tips)).

## 2. Local Claude Code as a sender (2 minutes)

Make an invite: right-click the pill → **Settings…**, then on the **Connect a machine** page (under **Hubs and machines** in the sidebar; the menu bar menu's **Connect a Machine…** opens it too) keep *A server or agent that sends alerts*, enter a machine name, set **Uses** and **Expires after**, and click **Create invite**. The app shows the join link and two copy buttons, **Agent prompt** and **Shell one-liner**. The agent prompt reads:

```
Set up needs-you alerts on this machine: read http://my-mac.example.ts.net:8765/join/nyi_... and follow it. If this machine runs Claude Code, use --claude-hooks user --skill --alerts. [...] Then run ~/.local/bin/needs-you doctor and, for each WARN or FAIL line, run the next step printed under it, or tell me if it needs me. If the installer says the link is unknown, expired or used up, ask me for a new one.
```

The link uses the Mac's MagicDNS name while Tailscale is running, and `http://127.0.0.1:8765` when it isn't. Either works for an agent on the Mac itself.

Paste that into Claude Code on the Mac. The agent reads the page, picks the options that fit (Claude Code hooks, the skill, Orca snippets), and runs the one-line installer. It installs the `needs-you` CLI in `~/.local/bin`, saves a token of its own in `~/.config/needs-you/env`, and posts a test `info` card (`setup:<host>:test`), which shows under **Recent** in the panel.

To do it yourself instead, paste the **Shell one-liner** and add the options you want:

```bash
curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes --claude-hooks user --skill --alerts
```

The installer puts `~/.local/bin` on your `PATH` with one line in your shell profile (`~/.zshrc` for zsh; `--no-path` prints the line instead). Open a new terminal tab so `needs-you` is found, then `needs-you doctor` checks the setup (config, hubs, token, hooks, skill, flush schedule) and prints a fix for anything wrong.

Try a real item. It appears in the panel, then goes away when you resolve it:

```bash
needs-you add --key "personal:test:hello" --context personal --title "Say hi back"
needs-you resolve --key "personal:test:hello"
```

`--alerts` turns the hooks on for every Claude Code session on this machine; without it they stay quiet (except in sessions Orca starts). Restart open Claude Code sessions to pick up the hooks. More, including SSH, tmux and VS Code Remote-SSH: [claude-code-everywhere.md](claude-code-everywhere.md).

**On the Mac itself,** the installer lists `http://127.0.0.1:8765` first in `~/.config/needs-you/env` (the hub sees the redeem come from its own machine), then the MagicDNS name, so local agents keep posting while Tailscale is down. Check with `grep NEEDS_YOU_URLS ~/.config/needs-you/env`.

## 3. Servers as senders, over Tailscale (2 minutes each)

Install [Tailscale](https://tailscale.com) on the Mac and the servers, with MagicDNS on ([tailscale.md](tailscale.md) walks through it). There's no switch in the app: while Tailscale is up, the built-in hub also listens on the Mac's tailnet address, and **Settings… → Built-in hub** shows the URL servers use. Create an invite with **Uses** set to the number of servers. The link uses the Mac's MagicDNS name, for example `http://my-mac.example.ts.net:8765/join/nyi_...`.

On each server, paste the agent prompt into its agent, or run:

```bash
curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes
```

Each server gets its own token (named `<invite name>-<hostname>`), so you can revoke one without touching the others: **Settings… → Machines** in the app ([add-a-sender.md → Removing a sender](add-a-sender.md#removing-a-sender)).

> **macOS firewall:** the first time a server connects, macOS may ask whether `python3` may accept incoming connections. Allow it; that's the app's built-in hub.

**While the Mac sleeps**, servers can't reach it. Their CLI queues items locally (it still exits 0, so jobs never fail), and the installer adds a 5-minute `needs-you flush` (cron on Linux, a LaunchAgent on macOS). Items arrive within about 5 minutes of the Mac waking.

## 4. Optional: a server hub

If you want alerts to land somewhere even while the Mac sleeps, or you run many servers, add one or two always-on hubs: [HUB.md](../HUB.md). They're set up on a server from the command line (`scripts/install-hub.sh`); there's no app screen for them. The Mac joins one with a link in **Settings… → Other hubs (advanced)**. Today server hubs replicate only with each other, not with the built-in hub (that's being built), and invites made on the Mac list only the Mac's URL, so senders that should fail over to a server hub need an invite made on it ([HUB.md](../HUB.md#with-the-apps-built-in-hub)). To use only a server hub, turn off **Run hub on this Mac**: the app then shows the server hub's alerts ([the three setups](concepts.md#where-the-hub-runs-three-setups)).

## Done

- Something didn't show up? [troubleshooting.md](troubleshooting.md).
- Writing alerts from your own scripts or agents: [AGENT-GUIDE.md](../AGENT-GUIDE.md).
- Orca on several servers: [orca.md](orca.md).
- Claude Code over SSH, tmux or VS Code Remote-SSH: [claude-code-everywhere.md](claude-code-everywhere.md).

## Words

- **The Needs You app:** shows your alerts on the Mac (the pill and the panel).
- **Hub:** stores your alerts and hands them to the app. The app has one built in: **Settings → Built-in hub**. A **server hub** is the same hub, always on, on a server you run; optional ([HUB.md](../HUB.md)).
- **Sender:** a server, CI job, script or agent that posts alerts with the `needs-you` command (agent hooks and the MCP server use it too). No app needed.
- **Reader (another Mac):** a second Mac with the app that shows the same alerts.
- **Owner:** a Mac that can also connect and revoke machines. Yours is the owner of its built-in hub.
- **Invite link / connect link:** sets up machines; made in **Connect a machine**, listed and revoked in **Machines**.
- **Tailnet:** your private [Tailscale](tailscale.md) network, so servers can reach the Mac.

The full table, with where each lives in Settings: [App, hubs and senders](concepts.md).
