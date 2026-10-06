# Quickstart (about 15 minutes)

End to end: two hubs, the Mac app, one sender machine, then Claude Code alerts. Every step can be re-run safely.

What you need:

- A [Tailscale](https://tailscale.com) tailnet with your Mac and two always-on Linux or macOS machines on it (VMs are fine). MagicDNS on.
- `python3` 3.9+ and `curl` on the hubs and senders. Stock Ubuntu and macOS already have both; there is nothing to `pip` or `brew` install.
- This repo cloned on each machine you set up (or copy the files you need).

```
 senders (VMs, agents, CI)           hubs (2, always on)            your Mac
 needs-you CLI / curl  ──POST──►  hub-a ◄──replicate──► hub-b  ◄──poll── NeedsYou.app
                                  (tries hub-a, then hub-b; queues if both are down)
```

## 1. Hubs (5 min)

On **each** of the two hub machines (we'll call them `hub-a` and `hub-b`):

```bash
git clone <this repo> needs-you && cd needs-you
sudo ./scripts/install-hub.sh
```

The installer sets up `hub/needs_you_hub.py` as a systemd service listening only on the machine's tailnet address (port 8765 by default) and tells each hub about its peer, so writes replicate both ways. [HUB.md](../HUB.md) has the flags, the peer setup, and where data lives.

Check from any tailnet machine:

```bash
curl -fsS http://hub-a.<your-tailnet>.ts.net:8765/v1/health
curl -fsS http://hub-b.<your-tailnet>.ts.net:8765/v1/health
```

### Mint tokens

Each sender machine (and each CI repo) gets its own token, plus one read/patch token for the Mac. Mint them with the admin tool on a hub; it adds the token to every hub, so it works for failover too:

```bash
needs_you_admin.py token add mac        # the Mac's read/patch token (see HUB.md for the role flag)
needs_you_admin.py token add devbox     # one per sender machine
```

Keep the printed tokens somewhere safe for the next steps. Never commit one or copy it between machines.

## 2. Mac app (3 min)

Build and install `NeedsYou.app` as described in [mac/README.md](../../mac/README.md), launch it, and open **Settings**:

- **Hub URLs:** `http://hub-a.<tailnet>.ts.net:8765, http://hub-b.<tailnet>.ts.net:8765`
- **Token:** the `mac` token (it's stored in the Keychain).

You'll see a faint pill in a corner of the screen. That's the idle state. Details: [mac-app.md](mac-app.md).

## 3. First sender (3 min)

On the machine that should send alerts (a VM, the devbox, a CI runner):

```bash
cd needs-you
./scripts/setup-sender.sh
```

It installs the `needs-you` CLI to `~/.local/bin`, asks for the hub URLs and this machine's token (hidden), writes `~/.config/needs-you/env` (mode 600), checks both hubs, and offers to post a test item. Say yes: an `info` card appears under **Recent** on the Mac.

Now a real one:

```bash
needs-you add --key "personal:$(hostname -s):hello" --context personal \
  --title "Say hi back to $(hostname -s)" --body "This is a **needs** item. It raises the count."
```

The pill springs out with the title, then settles to `1`. Clear it from the sender side:

```bash
needs-you resolve --key "personal:$(hostname -s):hello"
```

(It's `--context personal` so it shows outside work hours too. Work items show on weekdays 7:00–18:00 by default.)

More: [add-a-sender.md](add-a-sender.md).

## 4. Claude Code alerts (3 min)

On the sender machine where you run Claude Code:

```bash
integrations/claude-code/install-hooks.sh          # adds hooks to ~/.claude/settings.json (backed up first)
mkdir -p ~/.claude/skills && cp -R integrations/claude-code/skill/needs-you ~/.claude/skills/
```

The hooks are quiet until you opt in. Try it:

```bash
NEEDS_YOU_AGENT_ALERTS=1 claude
```

Ask Claude to do something that needs a permission prompt (or just leave it waiting). A card "Claude needs permission: <repo>" appears; it clears when you answer. Sessions started by Orca are opted in automatically.

More: [claude-code.md](claude-code.md) and, for Orca automations, [orca.md](orca.md).

## Done

- Something didn't show up? [troubleshooting.md](troubleshooting.md).
- Writing alerts from your own scripts or agents: give them [AGENT-GUIDE.md](../AGENT-GUIDE.md).
