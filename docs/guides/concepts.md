# App, hubs and senders

needs-you has three parts. Each has one name, used the same way in Settings, on the site and in every guide.

| Part | What it does | Where it runs | You install it with |
|---|---|---|---|
| **The Needs You app** | Shows your alerts: the pill and the panel. It reads them from a hub; it doesn't post them. | Your Mac (macOS 14+) | The `.dmg` or `.zip` from the Releases page |
| **A hub** | Stores alerts and hands them to the app. Also makes invite links and keeps the list of connected machines. One Python file, SQLite, standard library only. | **Built into the app** (on by default), and optionally on **a server you run** | Nothing for the built-in hub; `scripts/install-hub.sh` for a server hub ([HUB.md](../HUB.md)) |
| **Senders** | Post alerts when something needs you, and clear them once it's handled. They can't read your alerts. | Any machine where agents or jobs run: your Mac, a devbox, a CI runner | An invite link: the agent prompt or the shell one-liner |

So the thing on your Mac that shows alerts is **the app**. The **hub** is where alerts are stored; the app has one built in, which is why there's nothing else to set up. Senders don't need the app, only the `needs-you` command.

## How it fits together

```
 where agents and jobs run               your Mac
 ┌──────────────────────────┐            ┌────────────────────────────────────┐
 │ senders                  │   post     │ the Needs You app                  │
 │  needs-you CLI           │ ─────────► │   built-in hub (stores alerts)     │
 │  agent hooks, MCP server │            │        │                           │
 │  CI, cron, GitHub poller │            │        ▼                           │
 └──────────────────────────┘            │   pill and panel (show alerts)     │
              │                          └────────────────────────────────────┘
              │ or post to                               ▲
              ▼                                          │ reads
     server hub (optional, always on) ───────────────────┘
```

Senders post to a hub over HTTP. The app reads from one hub at a time: the first in its list that answers, the built-in hub first. A sender lists one or more hubs and tries each in turn; if none answers (the Mac is asleep, say), it keeps the alert in a local outbox and sends it later, so a job never fails because of needs-you.

## Where the hub runs: three setups

| Setup | How | Today |
|---|---|---|
| **Built-in hub only** (the default) | Nothing to do: **Settings → Built-in hub → Run hub on this Mac** is on. Servers reach it over [Tailscale](tailscale.md). | Works. While the Mac sleeps, senders queue alerts and deliver them within about 5 minutes of it waking. |
| **Server hub only** | Set up a hub on a server ([HUB.md](../HUB.md)), join it from **Settings → Other hubs (advanced)** with an owner link from it, make sender invites on it, and turn off **Run hub on this Mac**. | Works. Alerts land while the Mac sleeps; the app shows them when it wakes. |
| **Both, kept in step** | The built-in hub and a server hub replicate every alert both ways, so senders can post to either. | Works. **Settings → Built-in hub → Always-on hub** makes a one-use peer invite, and one command on the server (`curl … \| sudo bash -s -- --join <link>`) installs a hub and pairs it with the built-in one. Invites made on the Mac then list both, so senders fail over to the server while the Mac sleeps, and the Mac catches up when it wakes. [HUB.md](../HUB.md#with-the-apps-built-in-hub) |

Most people need only the first. The idle hub uses under 1% of one CPU core and about 30 MB of memory ([measured](../HUB.md#resource-use)).

## Senders

Everything that posts is a sender, and all of it is built on one file, the `needs-you` command:

- **The `needs-you` CLI**: `needs-you add`, `resolve`, `run` (alert when a long job fails or finishes), `doctor`, `update`. It keeps the hub URLs and its token in `~/.config/needs-you/env`.
- **Agent hooks**: Claude Code, Codex, Gemini CLI, opencode, Copilot CLI, Kimi Code, Grok Build, Cursor, Cline and Aider post "agent is waiting" cards and clear them when you answer ([Claude Code](claude-code.md) and the other guides).
- **The MCP server**, for agents with MCP but no shell ([MCP server](mcp.md)).
- **CI, cron and scripts** ([Add a sender](add-a-sender.md#cron-systemd-ci)), **Orca** automations ([Orca](orca.md)) and the **GitHub poller** ([GitHub](github.md)).

One invite link installs the CLI and, with the options you pick, the hooks, the skill or the MCP server.

## Other words

| Word | What it is | In the app |
|---|---|---|
| **Token** | What a machine uses to talk to a hub. Each machine gets its own, with one role, and you can revoke it. The hub stores only a hash of it. | Listed in **Settings → Machines** |
| **Sender** (role) | Can post and resolve alerts, nothing else. Every sender machine gets this role. | **Connect a machine** → *A server or agent that sends alerts* |
| **Reader** (role) | Another Mac with the app that shows the same alerts from the same hub. It can't connect machines. | **Connect a machine** → *Another Mac that shows the same alerts* |
| **Owner** (role) | A reader that can also make invite links and revoke machines. The app is the owner of its built-in hub. Give it to other Macs only if they're yours. | **Connect a machine** → *Another Mac that can also connect machines (advanced)* |
| **Peer** | Another hub this hub replicates with (not a token). A server joins the built-in hub with a one-use **peer invite**, which gives that pair its own secret; server hubs can also share one peer secret set by hand. | **Settings → Built-in hub → Always-on hub**; [HUB.md](../HUB.md#with-the-apps-built-in-hub) |
| **Invite link** | Sets up one or more machines, each with its own token. For a sender it's `http://<hub>/join/<code>` (an agent reads it, or you run its one-liner); for another Mac it's a connect link, `needsyou://connect?…`. It works a set number of times, then expires. | Made in **Connect a machine**; joined in **Other hubs (advanced)**; listed and revoked in **Machines** |
| **Machines** | Every sender and Mac that can use your hub, with its role, CLI version and open items. | **Settings → Machines** |
| **Tailnet** | Your private [Tailscale](tailscale.md) network. It lets servers reach the built-in hub (`http://<name>.<tailnet>.ts.net:8765`) without opening it to the internet. | **Built-in hub → Addresses** |

## The Settings pages, by task

The sidebar group **Hubs and machines** has four pages:

| You want to | Page |
|---|---|
| Check the built-in hub is running, copy its address, or turn it off | **Built-in hub** |
| Set up a sender (a server or agent machine) or another Mac | **Connect a machine** (menu: **Connect a Machine…**) |
| See which senders and Macs are connected, revoke one or a link | **Machines** (only with an owner token) |
| Use a server hub or someone else's hub, or add a hub by URL and token | **Other hubs (advanced)** |

Older builds called these pages Your inbox (before that, This Mac), Invite a machine, Access, and Join a hub plus Hubs (manual), under a group called Inbox and machines.
