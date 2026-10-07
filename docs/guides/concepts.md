# Words

The few words needs-you uses, and where each lives in the Mac app.

The short version: **your Mac is the hub.** A hub is a small SQLite database behind a tiny web server: one Python file that needs only the standard library. The Mac app runs one, so there's nothing else to install. **Senders** (servers, CI, agents) post to it with the `needs-you` command, also one Python file: it tries each hub in turn, and if none answers (the Mac is asleep, say) it keeps the alert in a local outbox and sends it later. **Server hubs** are optional: the same hub, always on, on a Linux server, for redundancy, so alerts land while the Mac sleeps. Most people don't need one. It's all light: the idle hub uses under 1% of one CPU core and about 30 MB of memory ([measured](../HUB.md#resource-use)).

```
 servers, CI, agents ──(needs-you command)──►  your Mac: the hub (Settings → Your inbox)  ──►  the pill
                                                  ▲
           optional: always-on server hubs ───────┘  (set up from the command line, HUB.md)
```

| Word | What it is | In the app |
|---|---|---|
| **Hub** | Holds your alerts: a small SQLite database behind a tiny web server, one Python file (standard library only). The Mac app runs one for you, so your Mac is the hub; you don't install anything. | **Settings → Your inbox** (**Run hub on this Mac**, on by default) |
| **Sender** | Any machine or agent that sends alerts: a server, a CI job, a cron script, Claude Code. It doesn't need the Mac app, only the `needs-you` command (one Python file), which a link installs. If no hub answers, it keeps the alert in a local outbox and sends it later. It can send but can't see your alerts. | **Settings → Connect a machine** → *A server or agent that sends alerts* |
| **Reader** (another Mac) | Another Mac with the app that shows the same alerts as yours. It can't connect other machines. | **Connect a machine** → *Another Mac that shows the same alerts* |
| **Owner** | A Mac that can also make links and revoke machines. Your own Mac is the owner of its hub. Give it to other Macs only if they're yours. | **Connect a machine** → *Another Mac that can also connect machines (advanced)* |
| **Invite link** / **connect link** | A link that sets up one or more machines. For a sender it's `http://<hub>/join/<code>` (an agent reads it, or you run its one-liner); for another Mac it's `needsyou://connect?…`. It works a set number of times, then expires. Each machine it sets up gets its own token you can revoke. | Made in **Connect a machine**; joined in **Other hubs (advanced)**; listed and revoked in **Machines** |
| **Machines** | Every machine that can use your hub, with its role, CLI version and open items. | **Settings → Machines** |
| **Server hub** | Optional, for redundancy: the same hub, always on, on a Linux server or VM, copying every write to and from your Mac, so alerts land while your Mac sleeps. Set up from the command line with `scripts/install-hub.sh`; there's no app screen for it. Most people don't need one: senders queue alerts while the Mac sleeps. | [HUB.md](../HUB.md); join it from **Other hubs (advanced)** |
| **Tailnet** | Your private [Tailscale](tailscale.md) network. It lets servers reach the hub on your Mac (`http://<name>.<tailnet>.ts.net:8765`) without opening it to the internet. | **Your inbox → Addresses** |

## The Settings pages, by task

| You want to | Page |
|---|---|
| Check the hub on this Mac is running, copy its address | **Your inbox** |
| Set up a server, an agent or another Mac | **Connect a machine** (menu: **Connect a Machine…**) |
| See who's connected, revoke a machine or a link | **Machines** (only with an owner token) |
| See alerts from someone else's hub, add a server hub, or add a hub by URL and token | **Other hubs (advanced)** |

Older builds called these pages This Mac, Invite a machine, Access, and Join a hub plus Hubs (manual).
