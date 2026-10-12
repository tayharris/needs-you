# 0013. The owner can ask a server hub to update now

- Status: Proposed (2026-10-12)
- Date: 2026-10-12
- Builds on [0004](0004-always-on-hub.md), [0012](0012-mac-hub-peers.md) and the server hubs'
  automatic updates ([HUB.md](../HUB.md#automatic-updates))

## Context

Server hubs update themselves: every 6 hours `needs_you_hub_update.py` (run as root on a
system install) takes the newest release on the hub's channel once it has soaked (24 hours by
default), checks its SHA-256 sums, manifest and build provenance, runs its installer, and rolls
back if the new version doesn't answer. The Mac app can already ask a **sender machine** to
update (`POST /v1/tokens/<id>/request-update`), but not a hub: after a release the owner waits
up to a day and a quarter for each server, with no way to see from the Mac whether it updated.

Constraints: the hub runs unprivileged and sandboxed (`ProtectSystem=strict`, no
capabilities), while the updater needs root; hard rule 3 (no secrets in logs or responses);
peers are trusted for the data they replicate but must not gain new powers; Python stdlib only.

## Decision

### 1. `GET` and `POST /v1/hub/update`, owner only

`GET` shows the hub's version, whether it can update itself on request (`available`, with a
`reason` when not), and the state of the last run (`requested`, `checking`, `updating`,
`updated`, `up_to_date`, `off`, `failed`, or `idle`). `POST` asks it to update now. Both need an
**owner token**: a sender or reader token is a `403`, and a peer secret is not a token at all
(`401`), so neither a peer nor a sender can ask. Details in [API.md](../API.md#hub-updates).

### 2. The request is a flag, nothing more

The hub reads **no body**. There is no URL, version, channel or command to send, so a request
can't choose what is installed. The hub drops an empty-of-meaning file, `hub-update-request`
(`{"requested_at": <ms>}`, written by rename), next to its database, the one directory it can
write. The updater never opens that file: it `lstat`s it, `unlink`s it, and treats only a
regular file as a request (a symlink or anything else is removed, never followed).

### 3. The updater does the work, with every check

`needs-you-hub-update.path` (`PathExists=` on that file) starts the existing
`needs-you-hub-update.service` within seconds; the 6-hour timer also picks up a request it
missed (a run that held the lock when it came in runs once more). A requested run is the same
run as the timer's with one difference: it **doesn't wait out the soak**. The channel, the
SHA-256 sums, the manifest, the build provenance (`gh attestation verify
--deny-self-hosted-runners`), the "a failed release is never retried" record, the health check
and the rollback all stay. With automatic updates off the hub says it isn't `available`
(`409 unavailable`), the path unit is disabled, and the updater ignores a request.

So the worst a forged request can do is install the newest **checked** release on the
configured channel a day early.

### 4. Its state goes back the other way through a file the hub can only read

Each run writes `hub-update-status.json` next to `hub.json` (in root's `/etc/needs-you` on a
system install, mode 644; the hub's group can read the directory): the state, whether it was
requested, start and finish times, the versions, and one log line (≤ 300 characters; the hub
redacts it like its access log before serving it). The hub checks each field's type and shape
when it reads it. A `checking` or `updating` state older than 30 minutes reads as `failed`.

### 5. Rate limits, on both sides

The hub accepts one request per 15 minutes (`update_request_interval_seconds`), measured from
its own last request and the last requested run in the status file, so a restart doesn't reset
it; a request while one is pending or running is a `200` that records nothing. The updater, which
doesn't trust the hub, honours one requested run per 10 minutes and runs anything sooner as a
plain timer run (with the soak).

### 6. Which hubs

Only a hub started from a config file (`self_update_dir` defaults to its directory) with the
updater's `hub-update.json` there and `auto_update` on. The Mac app's own hub has no config
file, so it is never `available` (it updates with the app).

### 7. The Mac

Settings → Updates gets a **Machines and hubs** section: each sender machine (what
`GET /v1/tokens` already lists) and each peer hub (the local hub's `GET /v1/peers`, plus any
other owner hub the app is connected to), with its version and whether it's behind the newest
version the app knows, a **Request update** per row and **Update all** for the ones behind. A
hub's row calls `GET`/`POST /v1/hub/update` at the hub's own URL with the app's owner token
(tokens replicate, so the Mac's owner token is valid on its peers). An older hub without the
endpoint shows its version from `/v1/health` and no button.

## Consequences

- A new owner-only endpoint, local to each hub (nothing replicates), and a new systemd unit.
- Peers stay fully trusted for data, as in 0012: a peer that pushes a forged owner token record
  could call this endpoint. That's no new exposure: such a token can already mint invites and
  revoke tokens, and here it can only bring a checked update forward.
- The status file and the request flag are the only channel between the sandboxed hub and the
  root updater. No sudo rule, polkit rule or socket is added.
- Hubs installed before this change get the path unit at their next update (the installer
  writes it); until then a request waits for the timer.
