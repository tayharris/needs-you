# 0012. The Mac's hub peers with always-on hubs, set up by a peer invite

- Status: Accepted by the owner (2026-10-08), in effect once merged
- Date: 2026-10-08
- Builds [0004](0004-always-on-hub.md) phases 1–2 on [0003](0003-peer-replication.md)

## Context

The Mac app runs its own hub ([0001](0001-hub-in-mac-app.md)) and starts it with no peers.
Server hubs replicate only with each other, so "add an always-on server hub so alerts land
while the Mac sleeps" doesn't work with the Mac's own hub: invites made on the Mac list only
the Mac, and items posted to a server hub never reach the Mac's hub
([next-big-item.md](../roadmap/next-big-item.md)).

Replication today needs two things on every hub: the peer's URL in `peers`, and one shared
`peer_secret` for the whole mesh, both in `hub.json` and set by hand
(`install-hub.sh --peer URL --peer-secret-file F`). The Mac's hub has no config file, its
tailnet address changes, it sleeps for hours, and a person shouldn't copy a secret between
machines.

Constraints: peer secrets are secrets (hard rule 3: never logged, printed or put in a card);
hubs bind loopback or the tailnet only (rule 4); Python stdlib only (rule 2); the panel takes
no focus and gets nothing new (rule 2 of the app).

## Decision

### 1. A peer invite

`POST /v1/invites` (owner) and `needs-you-admin invite create NAME --role peer` accept
`role: "peer"`. A peer invite:

- has exactly **one use** (`uses` other than 1 is a 400) and a **short life**: `ttl_hours`
  defaults to 1 and may be at most 24;
- is **local to the hub that made it**. It names that hub, so it isn't replicated (an older
  hub would also fail closed on the unknown role and hold replication, see API.md);
- has a `join_url` and an `install_command` (`(curl -fsSL https://github.com/<repo>/releases/download/v<hub version>/install-hub.sh && echo '<join_url>') | sudo bash -s -- --join -`), no
  `needsyou://` link, and its `/join/<code>` page says what to run on the server. Its
  `/join/<code>/install.sh` is the failing script (exit 1, "use install-hub.sh --join -").

Any hub can make one: the Mac (Settings, or `POST /v1/invites` with its owner token) to add a
server, or a server (`needs-you-admin`) to add another server without copying the mesh secret.

### 2. Redeeming it: a pairwise secret, stored in the database

The joining hub sends `POST /v1/invites/redeem` with
`{"code", "host", "peer": {"url": <its public_url>, "hub_id": <its id>, "schema": <its schema>}}`.
The inviting hub checks the code first (`404`, counted against the client IP like any failed
redeem), then the `peer` object (`400`), refuses its own `hub_id` or URL (`409 self`), a URL or `hub_id` that already belongs to
another link (`409 conflict`: re-pairing goes through a removal, so a redeem can't take over a
link) and a joining hub whose `schema` is below its own (`409 peer_outdated`). None of those
spend the use.
Then it mints a fresh **pairwise secret** (`nyp_` + 256 random bits), stores
`(url, hub_id, name, secret)` in a new `peer_links` table (schema 9), starts replicating with
that URL at once, and answers `{"role": "peer", "peer_secret", "hub_id", "hub_url", "schema",
"version", "hub_urls"}`. The joining hub stores the reverse link (the inviting hub's
`hub_url` and the same secret) in its own `peer_links`, under the same rule for that URL as
the inviting hub applies to `peer.url` (below): it checks the join link's hub before sending the
code and the answered `hub_url` before storing anything, and a running hub never replicates
with a stored link that fails it. It refuses an answer whose URL or `hub_id` belongs to a
different link it already has; the same hub at the same URL replaces its old link (a re-pair
after the other side removed it).

`needs-you-admin peer join -` does the joining side; `install-hub.sh --join -` installs the
hub, runs it, and starts the service. Neither prints the secret. Both read the link from stdin
(see the amendment below).

**Why pairwise, not the mesh secret.** A shared secret can't be withdrawn from one hub
without changing it on all of them, so removing a peer would not revoke it. A server that
already has a mesh with its own secret would have to switch secrets to add the Mac. With a
secret per link, removing a peer deletes exactly that secret, and an existing mesh is left as
it is. The mesh secret and config `peers` keep working unchanged (hand-set peers, and the
Mac's `LocalHubPlan.peers` with its `peer-secret` file for someone joining the Mac to an
existing mesh by hand).

**Each secret is bound to its link.** Redeeming also mints a random **link id** (`pl_` + 96
bits; not the hub id, which on the Mac follows its local host name). Both hubs store it with
the secret, and every replication request over a link carries it in `X-Needs-You-Peer-Link`
next to `Authorization: Bearer <secret>`. **Inbound**, a request with a link id is accepted
only with that link's own secret (constant-time compare, the link read fresh from the
database, so a removal counts at once); a request without one only with the mesh secret,
which is for config peers. So one peer can't pose as another or as a mesh member, the mesh
secret is never good for a link, and removing a link revokes exactly that peer. A peer is
still fully trusted for the data it replicates (it pulls every record and may push any, tokens
included), as mesh members are. The link id is not a secret.
**Outbound**, a link peer gets its own secret and link id, a config peer the mesh secret, and
any other URL nothing. A redeem can't take over a config peer's URL (`409 conflict`), and `peer.url` must be
`https`, or plain `http` to a tailnet name or address or loopback (the inviting hub sends it its
secret and every record); redirects are never followed. A hub
needs no mesh secret to have link peers.

**Where the secret lives.** In plaintext in `peer_links` (a hub must send it), in the same
mode-600 database (and mode-600 backups) as everything else; `hub.json` already holds the mesh
secret the same way. It never replicates, never appears in `/v1/health`, `GET /v1/peers`, the
admin tool's output or a log line (the access log and peer-status text redact `nyp_…`), and is
sent once, in the redeem response, to the hub that spent the code.

### 3. Sleep, wake and a changing address

- Peers are addressed by `public_url`, which is the MagicDNS name whenever there is one (the
  Mac's `LocalHubPlan.publicURL`, `install-hub.sh`'s default). A new tailnet IP changes
  nothing for the peer; the app already restarts its hub when its binds change.
- Nothing is lost while the Mac sleeps: the server keeps its writes for the Mac in the durable
  outbox (7 days) and the Mac pulls everything after its cursor when it wakes (anti-entropy is
  transitive, so it also gets what other servers wrote).
- **Wake detection:** a peer worker that sees the wall clock jump more than 30 s past the
  monotonic clock (the process was suspended) drops its backoff and pushes and pulls at once,
  instead of waiting out a 5-minute backoff from before the sleep.
- **Known limit** (narrowed by *Short retention* below): a resolve made on a server while the Mac sleeps longer than the server's
  `retention_days` (7) is purged there before the Mac pulls it, so the Mac keeps that item open
  until someone closes it. Its close then replicates normally. A longer `retention_days` on the
  always-on hub makes it rarer (owner decision below).

### 4. Questions and answers across peers

`question` (schema 7) and `answer`/`answered_at`/`answered_by` (schema 8) already replicate.
The schema check at redeem time means a peer that joins is never older than the hub it joins,
so it reads every field the other writes. The answer endpoints work on any hub, because the
posting token's id replicates with the item. First answer wins per hub; two clicks on two hubs
within the replication delay are settled by LWW (an existing known limit in API.md).

### 5. Seeing and removing a peer

- `GET /v1/peers` (owner): every peer with `url`, `hub_id`, `name`, `source` (`config` or
  `invite`), `added_at` and the replication status `/v1/health` already gives (`outbox_pending`,
  `last_push_ok`, `last_pull_ok`, `last_error`, ...). `/v1/health`'s `peers` gains the same
  `hub_id` and `source`.
- `DELETE /v1/peers/<hub_id or url>` (owner) and `needs-you-admin peer remove`: delete the link
  (and so its secret), its outbox rows and its replication state, and stop its worker. The
  other side's requests are then refused (`401`, or `404` once the hub has no secret left) and
  show as its `last_error` until it is removed there too. Config peers can't be removed over the API (`400`; edit `hub.json`).
- A hub picks up links the admin tool adds or removes within 5 s.

### 6. Invites list every hub

`hub_urls` (the redeem response senders save as `NEEDS_YOU_URLS`) is the hub's URL plus all
its peers, link peers included, so sender invites made on the Mac fail over to the server hubs
with no change to senders.

### 7. A conformance suite

`protocol/conformance/` is a stdlib `unittest` suite that tests a running hub black-box over
HTTP (`NEEDS_YOU_CONFORMANCE_URL`, an owner token, optionally a second hub and the peer secret
for replication). It covers validation, upsert and dedupe, resolve, `cursor`/`since` paging,
roles, the volume guard, and replication (LWW, the same-key merge, peer invites). CI starts a
hub and runs it; the `api-change` skill gains a step to update it.

### 8. The Mac

`LocalHubPlan` gains `peers` and a `peer-secret` file path (`~/Library/Application
Support/NeedsYou/peer-secret`, mode 600; since 2026-10-09 the hub refuses to start when
others can read it) for hand-set peers; invite-made links need neither
(they live in the hub's database). Settings → Built-in hub → Always-on hub makes the peer invite,
shows the server command, and lists each peer's state from `GET /v1/peers`. Settings window
only; nothing in the panel.

## Consequences

- One schema migration (9: `peer_links`). A hub at 9 refuses to downgrade as usual.
- Adding a server to the Mac is one command on the server and no secret to copy.
- A hub may hold several secrets; removal revokes one link and nothing else.
- The peer list is per hub and not replicated: joining hub C to the Mac doesn't make C a peer of
  server B. Anti-entropy is transitive, so items still converge through the Mac (or through B,
  when B and C are joined too).

## Owner decisions (2026-10-08)

- **Accepted**, with [0004](0004-always-on-hub.md) phases 1–2, once merged.
- **One-liner, yes, from GitHub.** The installer is a release asset (`install-hub.sh`, in
  `SHA256SUMS` and `release-manifest.json`), and a peer invite's `install_command` is `(curl -fsSL
  https://github.com/<repo>/releases/download/v<hub version>/install-hub.sh && echo '<link>') |
  sudo bash -s -- --join -` (the link on stdin: see the amendment below). Piped, the installer downloads the server tarball of its own embedded
  version (`INSTALLER_VERSION`) from the same release, checks it against `SHA256SUMS`,
  `release-manifest.json` and, with `gh`, that manifest's build provenance, refuses a tarball or
  manifest for another version, and installs only that. A hub supplies only the link: it can't
  pick the version (no rollback to old authentic code) or the code. An earlier design served
  the code from the hub's `/dl`, checked against the release of the hub's claimed version; it
  was dropped because the verifying script itself came from the hub. A dev build has no
  release: install from a checkout. As root, a checkout is copied to a private directory first
  (no symlinks, nothing others can write, up to `/`) and only the copy is installed.
- **Plain http only on the tailnet.** `peer.url` stays https, or http to `*.ts.net`, a tailnet
  address or loopback; LAN names are refused.
- **Less retention, not more.** Instead of a longer `retention_days`, a resolved item's text
  goes soon after it closes and a small tombstone (no text) stays long enough for a long-asleep
  Mac to learn it was resolved (section 3's known limit). Built on a follow-up branch,
  `tay/short-retention`.

## Follow-up: short retention (2026-10-08)

The owner wants less kept, not more: "if something's resolved it could be removed that day".
So instead of a longer `retention_days`:

- **Text goes a day after an item closes.** Maintenance purges the text of every item resolved
  or dismissed more than `text_retention_hours` (24) ago, and of every item whose `expires_at`
  passed that long ago: `title`, `body`, `links`, `steps`, `question`, `answer` and `source`.
  Open items keep everything.
- **A tombstone stays 30 days.** What's left (`id`, `key`, `status`, the times, `origin_hub`,
  and `"tombstone": true` on the wire) tells a peer or a client that slept that the item
  closed. `retention_days` now defaults to 30 and deletes tombstones.
- **Purging isn't a write.** No new `updated_at` or `seq`: each hub purges its own copy on its
  own clock. A peer still holding the text can't bring it back with the same version (last
  writer wins needs a strictly newer one), and a tombstone replicates like any record when a
  peer pulls or is pushed the item after the purge (a Mac waking after three days gets the
  tombstone instead of the resolve it missed). A tombstone that is open and unexpired is refused.
- **Nothing resurrects.** A tombstone or full version older than `retention_days` is refused,
  as closed records past retention always were. A merge never copies a tombstone's (empty)
  content onto the winner.
- **No copy keeps the text.** A replicated closed (or expired) version arrives without its text
  when this hub already purged the item or it closed more than `text_retention_hours` ago; only
  an open, unexpired version (a re-open) carries text back. Eligibility also counts when this
  hub stored the closed version (its own clock), so a peer's far-future `updated_at` can't keep
  text. A sender re-posting the key gets a new item. Quarantined records go after
  `text_retention_hours`; the database runs with `secure_delete` and checkpoints its WAL; the
  pre-migration backups get the same purge. The Mac keeps items in memory only (an ephemeral,
  cache-less URL session).
- **Clients** drop a tombstone like any closed item; the Mac never shows one.
- Schema 10 (`items.purged_at`), backed up before migrating like every migration. Hubs up to
  0.2.1 skip tombstones as unreadable items (they keep their own text), so upgrade every hub.

## Amendment (2026-10-08): the link stays out of command lines

A security review found the peer invite code in `sudo bash -s -- --join '<link>'`: sudo logs
its whole command line, and `ps` shows it to every user while the installer runs (hard rule 3).
The admin wrapper had the same problem one level down (`sudo -u needs-you ... peer join <link>`).

- **The link travels on stdin.** `install_command` is `(curl -fsSL <installer> && echo '<link>')
  | sudo bash -s -- --join -`. `echo` is a shell builtin, so the code is in no process's argv;
  sudo logs only `bash -s -- --join -`. The whole installer is one `{ ... }` group, which bash
  parses completely before it runs any of it, so when the script reads stdin (first thing,
  before any command that could read it) the next line is the link. The group ends in `exit`,
  so bash never runs the link as a command; and `curl ... &&` means a failed download sends no
  link, while a cut-off one is a syntax error that runs nothing.
- **Considered and rejected:** an environment variable (`sudo` drops it unless passed as
  `sudo VAR=... bash`, which is argv again, or with `--preserve-env`, which sudoers may refuse);
  prompting on `/dev/tty` (two pastes instead of one, and an agent can't run it); a
  `--join-file` (a second step, and a file to clean up). Stdin keeps one copy-paste command.
- `needs-you-admin peer join -` (or no link) reads it from stdin; the system wrapper turns
  `peer join <link>` into that before it calls `sudo -u needs-you`. `--join LINK` still works,
  with a note that it shows in `ps`.

The same review hardened pairing itself: the joining hub applies the `peer.url` rule to the
join link's hub (before sending the code) and to the answered `hub_url` (before storing
anything), and a running hub skips a stored link that fails it; a redeem whose URL or `hub_id`
belongs to another link is `409 conflict` instead of replacing it (section 2).
