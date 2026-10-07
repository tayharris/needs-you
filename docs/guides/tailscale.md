# Tailscale

needs-you hubs never listen on the open network: only on `127.0.0.1` and the machine's [Tailscale](https://tailscale.com) address. So for a server, VM or CI runner to reach the hub in your Mac app, both need to be on the same tailnet. This page sets that up from scratch and checks it. (Agents on the Mac itself need none of this; they use `127.0.0.1`.)

The examples use `my-mac` for the Mac, `devbox` for a Linux server and `<tailnet>` for your tailnet's name, so the Mac's address is `my-mac.<tailnet>.ts.net` (for example `my-mac.example.ts.net`).

## 1. Install Tailscale

**On the Mac:** install the Tailscale app from [tailscale.com/download](https://tailscale.com/download) (or the Mac App Store), open it and sign in. The app's command-line tool is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; the commands below write it as `tailscale`.

**On each Linux machine:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up            # prints a login URL; open it and sign in to the same account
```

Sign every machine in to the same tailnet (the same account or organization).

## 2. Turn on MagicDNS and find your tailnet name

MagicDNS gives each machine a name like `devbox.<tailnet>.ts.net`. It's on by default for new tailnets; check in the [admin console](https://login.tailscale.com/admin/dns) under **DNS**, which also shows the tailnet name (`<tailnet>.ts.net`).

On any machine:

```bash
tailscale status                                   # every machine on the tailnet, with its 100.x address
tailscale status --json | grep '"DNSName"' | head -n 1   # this machine's full name, e.g. "devbox.example.ts.net."
tailscale ip -4                                    # this machine's tailnet address (100.64.0.0/10)
```

## 3. How the hubs use it

**The Mac app's hub** listens on `127.0.0.1:8765` and, whenever Tailscale is up, also on the Mac's tailnet address. There's no switch: the app finds the Tailscale CLI by itself (the app bundle, `/usr/local/bin`, `/opt/homebrew/bin`), reads the address and the MagicDNS name, and restarts its hub when they change. **Settings… → Your inbox** shows the URL servers use under **From your other machines (Tailscale)**, `http://my-mac.<tailnet>.ts.net:8765` (the tailnet IP if MagicDNS is off), with a **Copy** button. Invite links use the same URL. Without Tailscale it says other machines can't reach the hub, and invite links point at `127.0.0.1`.

The first time another machine connects, macOS may ask whether `python3` may accept incoming connections: click **Allow**. (Ad-hoc signed builds may ask again after an update.)

**A server hub** ([HUB.md](../HUB.md)): `scripts/install-hub.sh` binds `127.0.0.1` plus `tailscale ip -4` and advertises `http://<MagicDNS name>:8765`, unless you pass `--bind ADDR` or `--public-url URL`. The hub itself (`hub/needs_you_hub.py --bind ...`) defaults to `127.0.0.1` only and refuses `0.0.0.0` or `::` without `--allow-any-interface`. With `"freebind": true` in its config, it can bind the tailnet address before `tailscaled` has brought it up at boot.

## 4. Check reachability

From the server, before any invite:

```bash
tailscale status | grep my-mac                       # the Mac is listed and not "offline"
tailscale ping my-mac                                # a pong over the tailnet
curl -sS --max-time 5 http://my-mac.<tailnet>.ts.net:8765/v1/health
```

The last line should print JSON with `"ok":true`. `/v1/health` needs no token. Then run the invite's one-liner ([quickstart.md](quickstart.md) step 3), and afterwards `needs-you doctor`, which checks every hub URL in `~/.config/needs-you/env` with this machine's token.

| You get | It means |
|---|---|
| `Could not resolve host` | MagicDNS is off, or this machine isn't signed in to the tailnet. Use the 100.x address meanwhile. |
| A timeout | The Mac is asleep or offline, Tailscale is down on the Mac, the macOS firewall blocked `python3`, or an access rule blocks port 8765 (below). |
| `Connection refused` | The Mac is reachable, but its hub isn't listening on the tailnet address: check **Settings… → Your inbox** (is **Run hub on this Mac** on, and does **From your other machines (Tailscale)** show the `ts.net` name?). |

More in [troubleshooting.md](troubleshooting.md#a-sender-cant-reach-the-hub).

## 5. Access rules and tags

With Tailscale's default policy (every machine can reach every other), there's nothing to do. With a restrictive policy, allow senders to reach the Mac (and any server hubs) on `tcp:8765`, and let the Mac and the server hubs reach each other on `tcp:8765` too (the Mac polls server hubs, and hubs replicate). For example, with servers tagged `tag:server`:

```json
{
  "tagOwners": { "tag:server": ["autogroup:admin"] },
  "hosts": { "my-mac": "100.64.0.10" },
  "acls": [
    { "action": "accept", "src": ["tag:server"], "dst": ["my-mac:8765"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:server:8765"] }
  ]
}
```

Use the Mac's real address from `tailscale ip -4`, and merge these rules into your existing policy rather than replacing it. Tag servers (`sudo tailscale up --advertise-tags=tag:server`) rather than the Mac: a tagged machine stops belonging to your user. CI runners that join with the Tailscale GitHub Action get their tag from the OAuth client ([integrations/ci](../../integrations/ci/README.md)).

## A machine without Tailscale

**An SSH tunnel.** If you can SSH from the Mac to the machine, forward the machine's `127.0.0.1:8765` back to the Mac's hub:

```bash
# on the Mac
ssh -R 8765:127.0.0.1:8765 devbox
```

Then, in that SSH session, run the invite's one-liner with the join link's host swapped for `127.0.0.1:8765`, and pass `--hub` so the machine saves that URL:

```bash
curl -fsSL http://127.0.0.1:8765/join/nyi_.../install.sh | bash -s -- --yes --hub http://127.0.0.1:8765
```

Port 8765 must be free on that machine (no hub of its own there). Items post while the tunnel is up; the rest of the time the CLI queues them (exit 0, so jobs don't fail), and the 5-minute flush sends them the next time you're connected. To bring the tunnel up with every SSH login, add `RemoteForward 8765 127.0.0.1:8765` under `Host devbox` in the Mac's `~/.ssh/config`.

**An https URL.** Any hub reachable over `https` works too (for example a server hub behind your own reverse proxy); give senders that URL. The Mac app connects to plain `http` hubs only on `*.ts.net`, `.local` and `localhost` names and IP addresses; anything else must be `https`. Keep the hub itself on loopback behind the proxy.

**An always-on server hub on the tailnet** helps when the Mac is often asleep or off the tailnet: senders post there and it replicates to the Mac ([HUB.md](../HUB.md)).
