# Server hubs (optional)

needs-you has three parts: **the Needs You app** on your Mac shows alerts, **a hub** stores
them, and **senders** post them ([App, hubs and senders](guides/concepts.md)). The app has a hub
built in, which is all most setups need. This page is about the other place a hub can run: a
**server hub**, the same hub, always on, on a Linux server you run. Add one when:

- you want items to land somewhere while the Mac sleeps (otherwise they wait in each sender's outbox until it wakes), or
- you run many servers, or senders that can't wait (CI with short-lived runners).

A hub is one Python file (`hub/needs_you_hub.py`, standard library and SQLite only) on stock
`python3` 3.9+ (Ubuntu 22.04+, Debian 12+, macOS). Hubs replicate every write to each other,
the app's built-in hub included once a server [joins it](#with-the-apps-built-in-hub), so a sender, the
Mac or an invite link can use any of them. The wire contract is in [API.md](API.md).

## Two hubs in 10 minutes

You need two always-on Linux machines with systemd and Tailscale (MagicDNS on), called
`hub-a` and `hub-b` below, and this repo cloned on each. Everything installs under your home
directory; no root except one `loginctl` command.

**1. Hub A, with a new peer secret:**

```bash
git clone <this repo> ~/needs-you && cd ~/needs-you
./scripts/install-hub.sh --user --peer http://hub-b.example.ts.net:8765 --generate-peer-secret
```

It prints the peer secret once. Save it to a file on hub B (over the tailnet, e.g.
`ssh hub-b 'umask 077; cat > ~/ny-secret'`, then paste), and keep it out of git and chat logs.

**2. Hub B, with A as its peer and the same secret:**

```bash
git clone <this repo> ~/needs-you && cd ~/needs-you
./scripts/install-hub.sh --user --peer http://hub-a.example.ts.net:8765 \
  --peer-secret-file ~/ny-secret --no-invite
rm ~/ny-secret
```

**3. Linger.** If the installer says lingering is off, run the command it prints on each hub,
so the hub keeps running after you log out and starts at boot:

```bash
sudo loginctl enable-linger "$USER"
```

**4. The first invite.** Hub A printed an owner invite (`needsyou://connect?...`). Open it on
the Mac and NeedsYou.app adds the hub. Then make a link for your servers on either hub:

```bash
needs-you-admin invite create my-servers --role sender --uses 5 --ttl 72
```

It prints the join URL, the one-liner, and a prompt to paste to an agent. Each machine that
redeems the link gets its own token and is told about both hubs (`NEEDS_YOU_URLS`), so it
fails over between them.

**5. Check replication:**

```bash
curl -s http://hub-b.example.ts.net:8765/v1/health        # stats, no token needed
needs-you-admin token list                                   # on hub B: tokens made on A show up
```

With a token, `/v1/health` also lists each peer's `outbox_pending`, `last_push_ok`,
`last_pull_ok` and `last_error`. A healthy pair has `outbox_pending` 0 and a recent
`last_pull_ok`. `skipped_push` and `skipped_pull` count replicated items one side couldn't
read (usually a hub running an older version than its peer: upgrade it), with the last one in
`last_skipped`; replication carries on past them, and the hub that skipped them applies them
at its next start once it can read them. The hub's log names each one. A non-null `blocked`
means a **token or invite** record (a revocation, say) one side can't read: those are never
skipped, so replication in that direction waits for it (the log says `BLOCKED`). Upgrade the
older hub; replication then resumes by itself.

### With the app's built-in hub

A server joins the app's built-in hub with a **peer invite**: a one-use link the Mac makes, which
the server redeems for the pair's own replication secret. Nothing to copy by hand, and the
secret never shows on a screen ([ADR 0012](adr/0012-mac-hub-peers.md)).

**1. On the Mac**, make the link: **Settings → Built-in hub → Always-on hub → Add an always-on
hub** shows the command to run on the server (and copies it). The Mac must be on the tailnet;
the link lasts an hour. From a terminal on the Mac instead:

```bash
python3 /Applications/NeedsYou.app/Contents/Resources/hub/needs_you_admin.py \
  --db ~/Library/Application\ Support/NeedsYou/hub.db \
  --public-url http://<this-mac>.<tailnet>.ts.net:8765 invite create my-server --role peer
```

**2. On the server** (Linux with systemd, python3 and Tailscale), the command Settings showed:

```bash
(curl -fsSL https://github.com/tayharris/needs-you/releases/download/vX.Y.Z/install-hub.sh \
  && echo 'http://<this-mac>.<tailnet>.ts.net:8765/join/nyi_...') | sudo bash -s -- --join -
```

The link goes to the installer on its stdin, after the script (`--join -`), so the invite code
is in no command line: not in `ps`, and not in the command sudo logs. Run it in bash or zsh.

`vX.Y.Z` is the release the Mac app runs. The installer comes from that GitHub release, and so
does all the code it installs: it downloads the release's server tarball for its own version,
checks it against the release's `SHA256SUMS` and `release-manifest.json` (and, when `gh` is
installed, that manifest's build provenance; without `gh` it talks to GitHub's own hosts over
https only), refuses a tarball for any other version, and installs nothing if a check fails or
GitHub can't be reached. The Mac's hub supplies only the link: no code comes from it, so a hub
can't make a server install anything else. It installs and starts a system-wide hub, pairs it
with the Mac's hub, and prints no secret. A development build of the app has no matching
release: install from a checkout then. From a checkout (or the release's server tarball),
`echo '<link>' | ./scripts/install-hub.sh --user --join -` does the same as your user (or run it
without the `echo` and paste the link when it asks). Run as root, a
checkout is first copied to a private directory, refusing symlinks and anything another user
could write (the files or any directory above them), and only that copy is installed. On a server
that already runs a hub (alone, or in a mesh with its own `peer_secret`), run
`echo '<link>' | needs-you-admin peer join -` instead; the running hub picks it up within 5 seconds and
its other peers are left as they are.

Then:

- Every item posted to either hub shows on both, with its question and answer: an answer
  clicked on the Mac reaches a sender that asked through the server, and the other way round.
- Sender invites made on the Mac list both URLs (`hub_urls`), so those senders fail over to
  the server while the Mac sleeps, and the Mac catches up when it wakes (within seconds: a hub
  that notices it slept retries at once).
- Settings shows the server's state (connected, last sync, behind by N changes). Or:
  `needs-you-admin peer list` on the server, `GET /v1/peers` with the owner token.
- To stop: **Remove** in Settings (or `DELETE /v1/peers/<hub id>`) and
  `needs-you-admin peer remove <mac hub id>` on the server. Removing deletes that pair's secret.

The server's `public_url` must be its MagicDNS name (the installer's default with Tailscale),
so the Mac reaches it by name whatever its tailnet IP. The Mac's hub is named the same way.

A Mac that sleeps for days still learns what was resolved meanwhile: a closed item's text is
purged a day after it closed, but a text-free tombstone stays for 30 days ([housekeeping](#housekeeping)),
and the Mac's hub pulls it when it wakes. Only after 30 days away can an item resolved on the
server stay open on the Mac until you close it.

Joining one server to another works the same way: `needs-you-admin invite create hub-b --role
peer` on one, the command it prints (`install-hub.sh --join -`, or `needs-you-admin peer join -`,
with the link on stdin) on the other.

A pairing can't be taken over: a peer invite redeemed with the URL or hub id of a hub that is
already paired is refused (`409`), and so is a join whose answer names another paired hub. To
pair the same hub again, or under a new URL, remove it first (**Remove** in Settings,
`needs-you-admin peer remove`), then make a new peer invite. Both sides accept a peer only at
`https`, or plain `http` to a tailnet name or address (or loopback).

## What `install-hub.sh --user` sets up

| Path | What |
|---|---|
| `~/.local/share/needs-you/` | The code: `hub/`, `cli/` and the Claude Code files the hub serves at `/dl/` |
| `~/.config/needs-you/hub.json` | Config, mode 600 (holds the peer secret) |
| `~/.local/state/needs-you/hub.db` | SQLite database (WAL, incremental auto-vacuum) |
| `~/.config/systemd/user/needs-you-hub.service` | `systemctl --user` unit, `Restart=always` |
| `~/.local/bin/needs-you-admin` | The admin tool, preset to this config |

Options:

| Option | Default | Meaning |
|---|---|---|
| `--user` | system install | Install for the current user (recommended). |
| `--bind ADDR` | `127.0.0.1` + `tailscale ip -4` | Listen addresses, repeatable or comma-separated. `0.0.0.0`/`::` are refused. |
| `--port N` | `8765` | TCP port. |
| `--hub-id ID` | `hostname -s` | Unique per hub (letters, digits, `.`, `_`, `-`). |
| `--public-url URL` | `http://<MagicDNS name>:PORT` | How others reach this hub. Used in invite links and `hub_urls`. |
| `--peer URL` | none | Another hub's public URL. Repeatable; replaces the peer list. |
| `--peer-secret-file F` | | The shared replication secret, from a file. |
| `--peer-secret S` | | The same, inline (visible in `ps`; prefer the file). |
| `--generate-peer-secret` | | Make a new secret and print it once. |
| `--join -` | | Pair with the hub that made this peer invite ([above](#with-the-apps-built-in-hub)), reading its link from stdin. No owner invite is printed. `--join LINK` works too, but puts the code in `ps` and sudo's log. |
| `--reconfigure` | off | Rebuild the config from defaults + flags (keeps the secret). |
| `--no-start` | off | Install files and config only. |
| `--no-invite` | off | Don't print the first owner invite. |

Re-running upgrades in place: the code and unit are replaced, the config is kept with only the
flags you passed applied to it, the database is untouched, and the service restarts. The owner
invite is printed only when the config is first created.

Logs go to the journal only (`journalctl --user -u needs-you-hub -f`); the hub writes no log
files.

## System-wide install (alternative)

```bash
sudo ./scripts/install-hub.sh --peer http://hub-b.example.ts.net:8765 --generate-peer-secret
```

Same options without `--user`. It creates a `needs-you` system user and uses
`/opt/needs-you` (code), `/etc/needs-you/hub.json` (config, 640 `root:needs-you`),
`/var/lib/needs-you/hub.db`, the sandboxed unit `/etc/systemd/system/needs-you-hub.service`
(read-only system, no home access, no capabilities, syscall filter), and the wrapper
`/usr/local/bin/needs-you-admin`, which runs the admin tool as `needs-you`. Logs:
`journalctl -u needs-you-hub`.

## Config reference

`hub.json` is plain JSON (see `deploy/hub.example.json`). Every key can also be set by a flag
on `needs_you_hub.py`, so no file is required: the named flags below, or
`--set KEY=VALUE` for anything else (VALUE is parsed as JSON when it can be).

| Key | Flag | Default | Meaning |
|---|---|---|---|
| `bind` | `--bind` (repeatable, or commas) | `127.0.0.1` | Listen addresses. `0.0.0.0`/`::` need `allow_any_interface`. |
| `port` | `--port` | 8765 | |
| `public_url` | `--public-url` | first bind address | The URL others use. Put the MagicDNS name here. |
| `db` | `--db` | `needs-you-hub.db` | SQLite path. |
| `hub_id` | `--hub-id` | short hostname | Unique per hub; LWW tie-break and self-peer detection. |
| `peers` | `--peer` (repeatable) | `[]` | Peer public URLs: used for replication and handed to senders as `hub_urls`. |
| `peer_secret` / `peer_secret_file` | `--peer-secret-file` | | Required (16+ chars) when `peers` is set. Also `$NEEDS_YOU_PEER_SECRET`. |
| `owner_token_file` | `--owner-token-file` | | On start, make sure an owner token with the secret in this file exists (the Mac app uses this). |
| `owner_token_name` | `--owner-token-name` | `this-mac` | Its name. A changed secret replaces the old one. |
| `parent_pid` | `--parent-pid` | | Exit cleanly when that process is gone (checked every 2 s). |
| `install_dir` | `--install-dir` | the directory above `hub/` | Where `/dl/` files are read from (`cli/`, `integrations/claude-code/`). |
| `text_retention_hours` | | 24 | A closed or expired item's text (title, body, links, steps, question, answer, source) is purged this long after it closed; a tombstone stays. 0 keeps the text until the item is deleted. |
| `retention_days` | `--retention-days` | 30 | Closed and expired items (tombstones by then) older than this are deleted. 0 keeps them forever. |
| `freebind` | `--freebind` | false | Linux: bind before tailscaled has the address. The installer sets it. |
| `allow_any_interface` | `--allow-any-interface` | false | Allow `0.0.0.0` / `::`. |
| `allowed_hosts` | `--allowed-host` (repeatable) | `[]` | Extra `Host` names the hub answers to, besides IP literals, `localhost`, bind names, `public_url`, and this machine's host and MagicDNS names. Anything else is a 421 (DNS-rebinding protection, [API.md](API.md#conventions)). Also `$NEEDS_YOU_HUB_ALLOWED_HOSTS` (comma-separated), which is how to set it for the Mac app's hub (`launchctl setenv NEEDS_YOU_HUB_ALLOWED_HOSTS name`, then restart the app). `*` turns the check off. |
| `quiet` | `--quiet` | false | No access log. |
| `access_log` | | true | One stderr line per request. Invite codes in `/join/` paths (and anything shaped like a code or token) are replaced with `<code>`/`<redacted>`, and control characters are escaped. |
| `max_open_per_token` | | 60 | Volume guard. |
| `max_connections` / `request_read_seconds` | | 128 / 10 | Connections served at once, across all binds (kept 64 under the file descriptor limit). When full, a connection open longer than `request_read_seconds` (a slow request, or an answer its client stopped reading; never a reader's `/v1/stream`) is closed to make room; otherwise new ones are closed at once. |
| `default_expiry_hours` | | 24 | Expiry for `done`/`info` items without `expires_at`. |
| `maintenance_seconds` | | 600 | Purge + WAL checkpoint + incremental vacuum interval. |
| `vacuum_hours` | | 24 | How often a full `VACUUM` may run (only when over 25% is free). |
| `redeem_fail_limit` / `redeem_fail_window_seconds` | | 10 / 600 | Failed invite redeems per client IP before `429`. |
| `answer_rate_limit` / `answer_rate_window_seconds` | | 30 / 60 | Answers (`POST /v1/items/{id}/answer`, counted whether taken or not) per token before `429`. |
| `answer_read_rate_limit` | | 120 | Reads of an answer (`GET /v1/items/answer`) per token per `answer_rate_window_seconds` before `429`. |
| `answer_waits_per_token` | | 4 | Long polls of `GET /v1/items/answer` one token may hold open at once. |
| `post_rate_limit` / `post_rate_window_seconds` | | 120 / 60 | Posts (`POST /v1/items`, re-posts included) per token before `429 rate_limited` with `Retry-After`; a sender stuck in a loop (ADR 0010). 0 = off. |
| `anti_entropy_seconds` | | 60 | How often each peer is pulled. |
| `outbox_poll_seconds` | | 2 | Outbox check interval without a wake-up. |
| `retry_base_seconds` / `retry_max_seconds` | | 1 / 300 | Push backoff. |
| `peer_timeout_seconds` | | 5 | Per request to a peer. |

Restart after editing: `systemctl --user restart needs-you-hub` (or `sudo systemctl restart
needs-you-hub`).

### Use the MagicDNS name, not the IP

Everything that talks to a hub uses its `public_url`, a MagicDNS name over plain http such as
`http://hub-a.example.ts.net:8765`, not `http://100.x.y.z:8765`. The Mac app only allows plain
http to `*.ts.net` and local names, and the name survives the tailnet IP changing. Traffic is
still encrypted by WireGuard. The IP belongs only in `bind`.

## Invites and tokens

```bash
needs-you-admin invite create my-server --role sender --uses 3 --ttl 72   # servers and agents
needs-you-admin invite create mac --role owner                            # a Mac app
needs-you-admin invite list            # live invites: uses left, expiry
needs-you-admin invite revoke my-server
needs-you-admin token list             # name, role, state, open items
needs-you-admin token revoke my-server-build-1
needs-you-admin token add ci-myrepo --role sender                          # a bare token, printed once
needs-you-admin invite create hub-b --role peer       # another hub joins this one (one use, 1 h)
echo '<peer invite link>' | needs-you-admin peer join -   # this hub joins another
needs-you-admin peer list                              # peers: config and invite, never secrets
needs-you-admin peer remove hub-b                      # by hub id, URL or name (invite peers)
```

Roles: `sender` posts and resolves; `reader` reads, resolves and dismisses; `owner` is a reader
that can also create invites (the Mac app). Codes and tokens are stored as sha256 hashes and
printed once. Revoking an invite doesn't revoke tokens it already minted. A `peer` invite is
for another hub, not a machine: it stays on this hub (it isn't replicated) and mints no token.

The admin tool writes straight to the database (safe while the hub runs, thanks to WAL) and
queues the change for replication, so an invite or token made on one hub works on all of
them within seconds. A link from one hub can be redeemed on any; see
[API.md](API.md#invite-replication) for the small double-spend window.

## Housekeeping

The hub keeps itself small and keeps little: a closed item's text (title, body, links, steps,
question, answer, source) is purged `text_retention_hours` (24) after it closed, leaving a
tombstone (id, key, status, times, origin hub) so peers and clients that were away still learn it
closed; tombstones are deleted after `retention_days` (30). The purge runs on the hub's own clock,
a peer's copy can't bring purged text back, freed space is overwritten (`secure_delete`), and the
backups made before a migration (`hub.db.bak-N`) are purged the same way. Stale peer
outbox rows after 7 days, dead invites after a day, with a WAL checkpoint and incremental
vacuum every 10 minutes and a full `VACUUM` at most daily. Replicated records older than the
cutoff are refused, so a peer can't bring purged items back. `GET /v1/health` shows
`db_bytes`, item counts and outbox depth.

## Resource use

Measured 2026-10-07. The Mac numbers are the running app and its bundled hub on an Apple
Silicon MacBook Pro (macOS 15, Python 3.9), after a day of normal use. The server numbers are
a throwaway hub on a desktop Linux machine (8-core AMD Ryzen, Python 3.12, no peers).

| What | Measured | How |
|---|---|---|
| Mac app, idle | 0.4% of one core (0.46 s of CPU in 120 s), 55 MB memory footprint | `ps` CPU time over two idle minutes; `footprint` |
| Mac's hub, idle | 0.2% of one core (0.21 s in 120 s), 27 MB footprint | same |
| Mac's `hub.db` | 0.9 MB with 138 items (0.2 MB database + 0.7 MB WAL) | `ls` |
| Server hub, idle | under 0.1% of one core (0.03%), 33 MB RSS | `/proc` CPU time over 60 s |
| 1,000 posts, one after another | 1.2 s (about 850 a second); 1.1 ms median, 2.2 ms p99; hub at 77% of one core during the burst; RSS 33 to 34 MB | `POST /v1/items` over urllib |
| Database growth | about 600 bytes per item (realistic title, body, one link); the WAL reached 4.8 MB during the burst and is truncated at the next maintenance pass | file size after `wal_checkpoint(TRUNCATE)` |
| Mac poll, nothing new | 82 bytes, 1 ms | `GET /v1/items?since=` |
| Mac full poll, 1,000 open items | 630 KB, 36 ms | `GET /v1/items?status=open` |
| `needs-you add` | about 120 ms per call (Python start-up and imports), the same when failing over from a refused hub or queuing offline (210 bytes per queued request) | wall time of 20 calls |

Nothing else runs: no Docker, no database server, no pip packages, no cloud account. Network
use is a poll every 30 seconds (`NEEDS_YOU_POLL_SECONDS`), a full snapshot every 10th poll,
and one `/v1/stream` connection that carries a 15-second ping when idle. Peered hubs push
writes as they happen and pull each peer once a minute. Disk stays bounded by the
[housekeeping](#housekeeping) above and by `max_open_per_token` (60 open items per sender
token); a failover that waits on an unreachable (not refused) hub costs up to
`NEEDS_YOU_TIMEOUT` (3 s) per hub.

## Upgrading

Upgrades never lose config or data.

```bash
cd ~/needs-you && git pull && ./scripts/install-hub.sh --user     # or: sudo ./scripts/install-hub.sh
```

- **Code** in `~/.local/share/needs-you` (or `/opt/needs-you`) is replaced in place, and the
  service is restarted.
- **Config** (`hub.json`) is kept. Only the flags you pass on the re-run are applied to it; new
  config keys have defaults, so an old file keeps working unchanged.
- **Database:** the schema is versioned (`PRAGMA user_version`). On start, a hub that finds an
  older schema first copies the database with SQLite's online backup API to
  `hub.db.bak-<old version>` (mode 600; the newest 2 backups are kept), then applies the
  missing migrations, each in its own transaction. Migrations only add tables, columns and
  indexes; they never drop or rewrite rows. Databases from before versioning (version 0) are
  adopted as-is and also converted to incremental auto-vacuum. A hub refuses to open a
  database written by a *newer* version and exits without touching it, so a rollback can't
  corrupt data: restore the matching `hub.db.bak-<n>` (with the hub stopped) if you need to go
  back.
- **Tokens and invites** live in the database, so they survive. Senders keep their
  `~/.config/needs-you/env` and outbox; both formats are unchanged (an env file with only
  `NEEDS_YOU_URL` still works). Update senders with `needs-you update` ([guides/updates.md](guides/updates.md)).
- **Peered hubs:** upgrade all of them (and the Mac app) together when moving from a version
  without invites. Older hubs ignore invite records and refuse a replication batch that
  contains an `owner` token, so they fall behind until upgraded. Nothing is lost: the outbox
  retries for up to 7 days, and anti-entropy catches up after that.
- **Item steps (schema 3):** a hub without them accepts replicated items and drops their
  `steps`. When it later resolves, dismisses or marks such an item seen, the upgraded hubs keep
  their steps; only a re-post that changes the title, body or priority on the old hub clears
  them. Upgrade peers together to avoid the gap.
- **Item question (schema 7):** the same for an agent's `question` ([API.md](API.md)): a hub
  without it drops the field from replicated items, and keeps nothing to hand back; the
  upgraded hubs keep theirs through its resolves and seen marks. An older hub refuses a
  database at schema 7 (it backs up before migrating), so upgrade every hub together.
- **Answers (schema 8):** the same for an item's `answer`, `answered_at` and `answered_by`
  ([API.md](API.md#post-v1itemsidanswer-reader)): a hub without them drops them from replicated
  items, and the upgraded hubs keep theirs through its resolves and seen marks. Upgrade every
  hub together.
- **Peer links (schema 9):** a new local table for peers joined by a peer invite; nothing that
  replicates changes. A hub refuses a peer invite from a hub with an older schema
  (`peer_outdated`), so upgrade the server before joining it to a newer Mac app.
- **Short retention (schema 10):** a `purged_at` column, and two defaults change: a closed item's
  text goes after `text_retention_hours` (24), tombstones after `retention_days` (now 30, was 7).
  A `hub.json` written by an older installer says `"retention_days": 7`: tombstones then go
  after 7 days; set 30 (or delete the line) to keep them as long as the new default. A hub up to
  0.2.1 skips the tombstones it receives (their title is empty) and keeps its own copy's text.

## Operations
- **Backup:** `sqlite3 ~/.local/state/needs-you/hub.db ".backup $HOME/hub-$(date +%F).db"`
  (safe while running), or `python3 -c "import sqlite3; s=sqlite3.connect('$HOME/.local/state/needs-you/hub.db'); s.backup(sqlite3.connect('$HOME/hub-backup.db'))"`
  where the `sqlite3` CLI isn't installed. With two or more hubs, each is a live backup of the
  others.
- **A hub dies:** senders and the Mac fail over to the other hubs on their own. To replace it,
  install a fresh hub with the same `--public-url` and peers (or a new name, then update the
  peers on the others). An empty database pulls everything from its peers; its new `epoch`
  makes the peers re-pull from it from the start. Tokens and invites come back with the rest.
- **A hub was off for longer than `retention_days`:** stop it, delete its `hub.db*` files, and
  start it empty, so it can't push stale open versions of items the others resolved and purged.
- **Removing a peer:** one that joined by a peer invite: `needs-you-admin peer remove <hub id>`
  on both sides (its secret is deleted, so it can't replicate with this hub any more). One in
  `peers`: take it out on the others (`install-hub.sh --user --peer ...` with the remaining
  ones) and restart; queued rows for it are dropped at start-up.
- **Moving a hub:** keep the MagicDNS name, or update `peers` on the other hubs. Senders pick up
  new URLs when they re-run an invite with `--force`, or by editing `NEEDS_YOU_URLS`.
- **Clocks:** keep hubs on NTP (systemd-timesyncd is enough); replication is last-writer-wins
  on timestamps.
- **ACL (optional):** tag hubs `tag:needs-you` and allow `tcp:8765` to them only from your
  devices and tagged servers. Hubs must reach each other on that port too.

## Development

```bash
python3 hub/needs_you_hub.py --db /tmp/ny.db --owner-token-file <(echo dev-owner-token-123456)
python3 hub/needs_you_admin.py --db /tmp/ny.db invite create me
/usr/bin/python3 -m unittest discover -s tests    # also with macOS /usr/bin/python3 (3.9)
```

Code must stay Python 3.9-compatible and standard-library only: `from __future__ import
annotations`, no `match`, no runtime `X | Y` unions, no `tomllib`.
