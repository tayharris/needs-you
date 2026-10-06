# Quickstart

Four steps; only the first is required. Every step can be re-run safely until the invite link expires, even after its uses are spent (a machine that's already set up doesn't spend another).

```
 Claude Code / Orca on the Mac ──► 127.0.0.1 ──┐
                                               ├──► NeedsYou.app (panel + its own hub)
 servers, VMs, CI ──── Tailscale ──────────────┘          ▲
                                                           │ optional: replicate
                                         always-on server hubs (HUB.md)
```

## 1. Install the Mac app (it runs its own hub)

Build or download `NeedsYou.app` ([mac-app.md](mac-app.md), [mac/README.md](../../mac/README.md)), move it to `/Applications` and open it. The app starts its own hub as a child process: SQLite in your Library folder, listening on `127.0.0.1:8765` (and on your Mac's tailnet address if Tailscale is running). There are no tokens to mint and no config files to edit.

A faint pill appears in a corner of the screen. That's the idle state.

## 2. Local Claude Code (2 minutes)

Make an invite: right-click the pill → **Settings…**, then in the **Invite a machine** section enter a machine name, keep the role **Sender**, set **Uses** and **Expires after**, and click **Create invite**. The app shows the join link and two copy buttons, **Agent prompt** and **Shell one-liner**. The agent prompt reads:

```
Set up needs-you alerts on this machine: read http://my-mac.example.ts.net:8765/join/nyi_... and follow it.
```

The link uses the Mac's MagicDNS name while Tailscale is running, and `http://127.0.0.1:8765` when it isn't. Either works for an agent on the Mac itself.

Paste that into Claude Code on the Mac. The agent reads the page, picks the options that fit (Claude Code hooks, the skill, Orca snippets), and runs the one-line installer. It installs the `needs-you` CLI in `~/.local/bin`, saves a token of its own in `~/.config/needs-you/env`, and posts a test `info` card (`setup:<host>:test`), which shows under **Recent** in the panel.

To do it yourself instead, paste the **Shell one-liner** and add the options you want:

```bash
curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes --claude-hooks user --skill
```

The installer prints a `Note:` if `~/.local/bin` isn't on your `PATH` (it isn't by default on macOS). Add it before going on, or `needs-you` below is "command not found":

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && exec zsh
```

Try a real item. It appears in the panel, then goes away when you resolve it:

```bash
needs-you add --key "personal:test:hello" --context personal --title "Say hi back"
needs-you resolve --key "personal:test:hello"
```

The hooks stay quiet until opted in (`NEEDS_YOU_AGENT_ALERTS=1`, or any session Orca starts); see [claude-code.md](claude-code.md).

**On the Mac itself,** the installer lists `http://127.0.0.1:8765` first in `~/.config/needs-you/env` (the hub sees the redeem come from its own machine), then the MagicDNS name, so local agents keep posting while Tailscale is down. Check with `grep NEEDS_YOU_URLS ~/.config/needs-you/env`.

## 3. Servers over Tailscale (2 minutes each)

Install [Tailscale](https://tailscale.com) on the Mac and the servers, with MagicDNS on. There's no switch in the app: while Tailscale is up, its hub also listens on the Mac's tailnet address, and **Settings… → This Mac** shows the URL servers use. Create an invite with **Uses** set to the number of servers. The link uses the Mac's MagicDNS name, for example `http://my-mac.example.ts.net:8765/join/nyi_...`.

On each server, paste the agent prompt into its agent, or run:

```bash
curl -fsSL http://my-mac.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes
```

Each server gets its own token (named `<invite name>-<hostname>`), so you can revoke one without touching the others: **Settings… → Access** in the app ([add-a-sender.md → Removing a sender](add-a-sender.md#removing-a-sender)).

> **macOS firewall:** the first time a server connects, macOS may ask whether `python3` may accept incoming connections. Allow it; that's the app's hub.

**While the Mac sleeps**, servers can't reach it. Their CLI queues items locally (it still exits 0, so jobs never fail), and the installer adds a 5-minute `needs-you flush` (cron on Linux, a LaunchAgent on macOS). Items arrive within about 5 minutes of the Mac waking.

## 4. Optional: always-on server hubs

If you want alerts to land somewhere even while the Mac sleeps, or you run many servers, add one or two always-on hubs that replicate with the Mac: [HUB.md](../HUB.md). Senders then fail over between them and the Mac.

## Done

- Something didn't show up? [troubleshooting.md](troubleshooting.md).
- Writing alerts from your own scripts or agents: [AGENT-GUIDE.md](../AGENT-GUIDE.md).
- Orca on several servers: [orca.md](orca.md).
