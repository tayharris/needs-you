# Running a needs-you hub

The hub is one Python file (`hub/needs_you_hub.py`) using only the standard library and
SQLite. Nothing is installed besides the files themselves: it runs on the stock `python3` of
Ubuntu 22.04+ / Debian 12+ (and macOS `/usr/bin/python3` 3.9 for development). The wire
contract is in `API.md`.

## Requirements

- Linux with systemd, `/usr/bin/python3` 3.9 or newer (with the built-in `sqlite3` module).
- Tailscale, logged in to your tailnet. The hub listens **only** on its tailnet IP.
- Always on. Run 2–3 hubs on different machines if you want it to survive one going down.

## Install one hub

```bash
git clone <this repo> ~/needs-you && cd ~/needs-you
sudo ./scripts/install-hub.sh
```

`install-hub.sh` options:

| Option | Default | Meaning |
|---|---|---|
| `--bind ADDR` | `tailscale ip -4` | Address to listen on. `0.0.0.0`/`::` are refused. |
| `--port N` | `8765` | TCP port. |
| `--hub-id ID` | `hostname -s` | This hub's unique name (letters, digits, `.`, `_`, `-`). Must differ on every hub. |
| `--peer URL` | none | Another hub, e.g. `http://linux-box.example.ts.net:8765`. Repeat for each peer. |
| `--peer-secret S` | generated | Shared replication secret, identical on every hub. |
| `--peer-secret-file F` | | Read the secret from a file (keeps it out of shell history and `ps`). |
| `--reconfigure` | off | Rewrite `/etc/needs-you/hub.json` even if it exists (keeps the existing secret unless you pass one). |
| `--no-start` | off | Install but don't enable/start the service. |

What it sets up:

| Path | What |
|---|---|
| `/opt/needs-you/hub/` | `needs_you_hub.py`, `needs_you_admin.py` |
| `/etc/needs-you/hub.json` | Config, mode 640 `root:needs-you` (holds the peer secret) |
| `/var/lib/needs-you/hub.db` | SQLite database (WAL), owned by `needs-you`, mode 600 |
| `/etc/systemd/system/needs-you-hub.service` | The unit (from `deploy/needs-you-hub.service`) |
| `/usr/local/bin/needs-you-admin` | Wrapper that runs the admin tool as the `needs-you` user |

The service runs as the unprivileged system user `needs-you` with `Restart=always` and
systemd sandboxing (read-only system, no home access, no capabilities, syscall filter, only
`/var/lib/needs-you` writable). Re-running the installer upgrades the code and unit in place
and never touches the database.

Check it:

```bash
systemctl status needs-you-hub
journalctl -u needs-you-hub -f
curl -s http://$(tailscale ip -4):8765/v1/health
```

### Use the MagicDNS name, not the IP

Everything that talks to a hub (the `needs-you` CLI, the Mac app, `curl`, and peer hubs)
should use the hub's **MagicDNS name over plain http**:

```
http://hub-d.example.ts.net:8765
```

not `http://100.x.y.z:8765`. The Mac app only allows plain-http connections to `*.ts.net`
and local names (App Transport Security), so a raw `100.x` URL won't work there. MagicDNS
names also survive a hub's tailnet IP changing. Traffic is still encrypted by WireGuard
inside the tailnet. The hub itself must *bind* to an IP; that's the only place the IP goes.

## Config reference (`/etc/needs-you/hub.json`)

See `deploy/hub.example.json`.

| Key | Default | Meaning |
|---|---|---|
| `bind` | **required** | Listen address (tailnet IP). `0.0.0.0`, `::` and empty are refused unless `allow_any_interface` is true / `--allow-any-interface` is passed. |
| `port` | 8765 | |
| `db` | `needs-you-hub.db` | SQLite path. The installer uses `/var/lib/needs-you/hub.db`. |
| `hub_id` | short hostname | Unique per hub. Used as the LWW tie-break and to detect self-peering. |
| `freebind` | false | Linux: set `IP_FREEBIND` so the hub can start before tailscaled has the IP up. The installer sets it to true. |
| `peers` | `[]` | Peer hub base URLs (MagicDNS names). Don't list the hub itself (harmless if you do: it's detected and skipped). |
| `peer_secret` | | Required (≥ 16 chars) when `peers` is non-empty. Also read from `peer_secret_file` or `$NEEDS_YOU_PEER_SECRET`. |
| `max_open_per_token` | 60 | Volume guard. |
| `default_expiry_hours` | 24 | Expiry for `done`/`info` items without `expires_at`. |
| `anti_entropy_seconds` | 60 | How often each peer is pulled. |
| `outbox_poll_seconds` | 2 | How often the outbox is checked without a wake-up (picks up admin-tool changes). |
| `retry_base_seconds` / `retry_max_seconds` | 1 / 300 | Push backoff. |
| `peer_timeout_seconds` | 5 | Per request to a peer. |
| `access_log` | true | One stderr line per request (goes to the journal). |

Command-line flags `--bind`, `--port`, `--db`, `--hub-id` and `--allow-any-interface`
override the file. Restart after editing: `sudo systemctl restart needs-you-hub`.

## Tokens

```bash
needs-you-admin token add mac --role reader          # the Mac app: read and patch only
needs-you-admin token add devbox              # a sender (default role)
needs-you-admin token add ci-hub-b --role sender
needs-you-admin token list                           # name, role, active/revoked, open items
needs-you-admin token revoke devbox           # by name or id
```

`add` prints the token **once**; only its sha256 is stored. Give each machine (and each
project with its own CI) its own sender token, so one can be revoked alone. Without the
wrapper, the same thing is
`sudo -u needs-you python3 /opt/needs-you/hub/needs_you_admin.py token add <name> --role sender|reader`
(it reads `/etc/needs-you/hub.json` by default; `--config` / `--db` override).

The admin tool writes straight to the database, which is safe while the hub runs (SQLite WAL).
With peers configured, the change is queued in the outbox and the running hub replicates it,
so a token added on any hub works on all of them within a few seconds.

## Multi-hub setup (2–3 machines)

Each hub keeps a full copy. Writes to any hub are pushed to the others; each hub also pulls
from the others every minute, so one that was down catches up when it returns. Senders and
the Mac list several hubs and use the first that answers.

1. **First hub** (say `hub-d`): install without peers to get a generated secret, or pick one:

   ```bash
   python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > /tmp/ny-secret   # once
   sudo ./scripts/install-hub.sh --peer-secret-file /tmp/ny-secret \
     --peer http://linux-box.example.ts.net:8765 \
     --peer http://hub-b.example.ts.net:8765
   ```

2. **Copy the secret** to the other machines (scp over the tailnet, then delete it from /tmp)
   and install each with the *other* hubs as peers:

   ```bash
   # on linux-box
   sudo ./scripts/install-hub.sh --peer-secret-file /tmp/ny-secret \
     --peer http://hub-d.example.ts.net:8765 \
     --peer http://hub-b.example.ts.net:8765
   # on hub-b
   sudo ./scripts/install-hub.sh --peer-secret-file /tmp/ny-secret \
     --peer http://hub-d.example.ts.net:8765 \
     --peer http://linux-box.example.ts.net:8765
   ```

   If a hub is already installed, add `--reconfigure` to rewrite its peer list.

3. **Mint tokens on any one hub.** They replicate:

   ```bash
   needs-you-admin token add mac --role reader
   ```

4. **Check replication** with a token from step 3 on each hub:

   ```bash
   curl -s -H "Authorization: Bearer $TOKEN" http://linux-box.example.ts.net:8765/v1/health
   ```

   `peers[]` shows each peer's `outbox_pending`, `last_push_ok`, `last_pull_ok` and
   `last_error`. A healthy mesh has `outbox_pending` 0 and recent `last_pull_ok` everywhere.

5. **Point clients at all hubs**, in the same order everywhere (so a sender's add and later
   resolve normally land on the same hub):

   ```
   # ~/.config/needs-you/env on each sending machine
   NEEDS_YOU_URLS=http://hub-d.example.ts.net:8765,http://linux-box.example.ts.net:8765,http://hub-b.example.ts.net:8765
   NEEDS_YOU_TOKEN=<this machine's sender token>
   ```

   Give the Mac app the same hubs in the same order (it fails over to the next one).

Optional Tailscale ACL: tag hubs `tag:needs-you` and allow `tcp:8765` to them only from your
devices and tagged servers. Hubs need to reach each other on that port too.

### How conflicts resolve (short version)

- Per item id, the version with the later `updated_at` wins (ties: higher `hub_id`). Keep hub
  clocks on NTP (systemd-timesyncd is enough).
- If two hubs both create an item for the same key before hearing of each other, the item with
  the lower id survives with the freshest content, and the other is closed as resolved with
  `superseded_by`. Details are in `API.md`.

## Operations

- **Backup:** `sqlite3 /var/lib/needs-you/hub.db ".backup /path/hub-$(date +%F).db"` (or just
  rely on the other hubs: a fresh hub with an empty DB pulls everything from its peers).
- **Replacing a hub's disk / DB:** delete the DB and restart. Its new `epoch` tells peers to
  re-pull from it from the start, and it pulls everything from them.
- **Removing a peer:** take it out of `peers` on the others and restart them; queued outbox rows
  for peers no longer configured are dropped at start-up.
- **Moving a hub:** change its MagicDNS target, or update `NEEDS_YOU_URLS` on senders and the
  Mac app.
- **Upgrading:** `git pull && sudo ./scripts/install-hub.sh`.
- **Logs:** `journalctl -u needs-you-hub`. Each request is one line; replication errors show up
  in `/v1/health` `peers[].last_error`.

## Development

```bash
python3 hub/needs_you_admin.py --db /tmp/ny.db token add me --role sender
python3 hub/needs_you_hub.py --bind 127.0.0.1 --port 8765 --db /tmp/ny.db
python3 -m unittest discover -s tests          # also run it with /usr/bin/python3 (3.9) on macOS
```

Code must stay Python 3.9-compatible and standard-library only: `from __future__ import
annotations`, no `match`, no runtime `X | Y` unions, no `tomllib`.
