# needs-you hub API (v1): wire contract

This is the exact contract implemented by `hub/needs_you_hub.py`. The design rationale is in
`PLAN.md`; how senders should behave is in `AGENT-GUIDE.md`; running hubs is in `HUB.md`.

## Conventions

- **Transport:** plain HTTP on the tailnet. Clients use the hub's MagicDNS name
  (`http://<hub>.<tailnet>.ts.net:8765`). Request and response bodies are JSON (UTF-8).
- **Timestamps:** the hub always emits RFC 3339 UTC with exactly three fractional digits:
  `2026-10-06T17:04:05.123Z`. These sort correctly as strings. On input the hub accepts
  ISO 8601 with or without fractional seconds, with `Z` or a `±HH:MM` / `±HHMM` offset, or no
  zone (taken as UTC), or a number of epoch seconds. Precision below 1 ms is dropped.
- **Auth:** `Authorization: Bearer <token>`. Every token has one role:

  | Role | Can call |
  |---|---|
  | `sender` | `POST /v1/items`, `POST /v1/items/resolve` |
  | `reader` | `GET /v1/items`, `GET /v1/items/{id}`, `PATCH /v1/items/{id}`, `GET /v1/stream` |

  `GET /v1/health` needs no token. The hub stores only the sha256 of each token, and records
  which token created or last re-posted each item (used by the volume guard).
- **Errors:** a non-2xx response has the body
  `{"error": "<code>", "message": "<human text>", "field": "<field path>"}` (`field` only on
  validation errors, for example `title`, `links[2].url`, `source.agent`).

  | HTTP | `error` | When |
  |---|---|---|
  | 400 | `invalid` | Validation failed, bad JSON, bad query parameter |
  | 401 | `unauthorized` | Missing, unknown or revoked token (or bad peer secret) |
  | 403 | `forbidden` | Valid token, wrong role for the endpoint |
  | 404 | `not_found` | Unknown endpoint, or unknown id on `GET`/`PATCH /v1/items/{id}` |
  | 409 | `self` | A hub tried to replicate to itself (replication only) |
  | 413 | `too_large` | Body over 64 KiB (8 MiB for `/v1/replicate`) |
  | 429 | `too_many_open` | The token already has 60 open items (the volume guard) |
  | 500 | `internal` | Bug; details are in the hub's log |

- Unknown JSON fields in requests are ignored, so newer clients can send extra fields.
  Clients must likewise ignore unknown response fields.

## The item

```jsonc
{
  "id": "01M492BJ7AYVYAA9X7WTP13JWG",      // ULID minted once by the hub that created it; same on every hub
  "key": "acme:ACME-4170:redo-blocked",       // sender's dedupe key; = id when the sender gave none
  "context": "work",                         // work | personal
  "kind": "needs",                           // needs | done | info
  "priority": "normal",                      // urgent | normal | low
  "title": "ACME-4170: push blocked on the migration fork",
  "body": "Choose: **merge** or **bypass**.", // markdown, or null when empty
  "links": [{"label": "Jira", "url": "https://acme.atlassian.net/browse/ACME-4170"}],
  "source": {"host": "devbox", "agent": "orca:redo-fixer", "project": "acme-backend"},
  "status": "open",                          // open | resolved | dismissed
  "created_at": "2026-10-06T17:04:05.123Z",
  "updated_at": "2026-10-06T18:04:05.456Z",  // moves on EVERY write (re-post, resolve, patch)
  "content_updated_at": "2026-10-06T17:04:05.123Z", // moves only when title, body or priority change
  "seen_at": null,
  "expires_at": null,                        // done/info default to created/re-posted + 24 h
  "superseded_by": null                      // set when this item lost a same-key merge (see Replication)
}
```

### Change detection: `content_updated_at`

`content_updated_at` is the re-animation signal. It is set at creation and changes only when a
re-post changes `title`, `body` or `priority`. Re-posting identical content, changing only
links/source/kind/context, resolving, dismissing and setting `seen_at` all move `updated_at`
but never `content_updated_at`.

A client animates an item when it is new to it, or when its `content_updated_at` is later than
the value it last saw. `POST /v1/items` responses also carry two response-only booleans,
`created` and `changed` (see below); they are not stored and are not part of the item.

### Expiry

`expires_at` is a deadline, not a write. Once it passes, the item is reported with
`"status": "resolved"` and is no longer open: it leaves `status=open` lists, stops counting
toward the volume guard, and a new POST with its key creates a new item. The stored record
is not rewritten, so `updated_at` does not move when an item expires (see `since` below for how
pollers still learn about it).

## Endpoints

### `GET /v1/health`

No auth needed. Always `200` while the hub is up:

```json
{"ok": true, "hub_id": "hub-d", "version": "1.0.0", "api": "v1", "time": "2026-10-06T17:04:05.123Z"}
```

If a bearer token is sent it is checked but never causes an error: a valid token adds
`"token": {"name": "...", "role": "sender"}` and a `"peers"` array (per-peer outbox depth,
last successful push/pull, last error); an unknown or revoked token adds `"token": null` and
`"token_error": "unknown or revoked token"`.

### `POST /v1/items` (sender)

Create an item, or update the open item with the same `key`.

| Field | Type | Rule | Default |
|---|---|---|---|
| `key` | string | ≤ 200 chars, only `A-Z a-z 0-9 . _ : - / @ # + =` | the new item's id (so no dedupe) |
| `title` | string | required, 1–100 chars after trimming, no control characters | |
| `body` | string | ≤ 2,000 chars, markdown; newlines and tabs allowed | empty |
| `context` | string | `work` or `personal` (case-insensitive) | `work` |
| `kind` | string | `needs`, `done` or `info` | `needs` |
| `priority` | string | `urgent`, `normal` or `low` | `normal` |
| `links` | array | ≤ 6 of `{"label": ≤ 80 chars, "url": ≤ 2,000 chars}` | `[]` |
| `source` | object | optional `host`, `agent`, `project`, each ≤ 100 chars | `{}` |
| `expires_at` | timestamp | any accepted timestamp | `done`/`info`: now + 24 h; `needs`: none |
| `status` | | **rejected** (use resolve or PATCH) | |

Link URLs must use one of these schemes (case-insensitive): `https`, `orca`, `slack`,
`vscode`, `cursor`, `figma`, `msteams`, `discord`. Anything else, including `http`, `jira`,
`file` and `javascript`, is a 400. Text strings are trimmed.

Semantics:

1. If an item with this `key` is open (and not expired), it is updated **in place, keeping its
   id**. A re-post is the sender's full current view: `title`, `body`, `context`, `kind`,
   `priority`, `links`, `source` and `expires_at` are all replaced (omitted optional fields
   become empty/default). `updated_at` always moves (strictly forward, even within one
   millisecond). `content_updated_at` moves only if `title`, `body` or `priority` changed. The
   item's token becomes the re-posting token. The volume guard does not apply to updates.
2. Otherwise a new item is created with a new id. If the token already owns 60 open,
   unexpired items, the hub returns `429 too_many_open` instead.

Response: `201` when created, `200` when an existing item was updated. The body is the item
plus `"created": true|false` and `"changed": true|false` (`changed` is true on create and when
title/body/priority changed).

### `POST /v1/items/resolve` (sender)

Body: exactly one of `{"key": "..."}` or `{"id": "..."}`.

Closes the open item with that key (or that id) as `resolved`. Always `200` and idempotent:

```json
{"resolved": 1, "items": [ { ...the resolved item... } ]}
```

If nothing is open with that key/id (already resolved, dismissed, expired, or never existed),
the response is `{"resolved": 0, "items": []}`. A body with neither or both of `key`/`id` is a 400.

### `PATCH /v1/items/{id}` (reader)

Body: any of

- `"status"`: `"resolved"` or `"dismissed"` (re-opening is not supported; post again instead)
- `"seen_at"`: a timestamp, or `null` to clear it

At least one is required. Moves `updated_at`, never `content_updated_at`. Returns `200` with
the item, or `404` for an unknown id. Patching an already-closed item is allowed.

### `GET /v1/items` (reader)

Query parameters:

| Param | Meaning |
|---|---|
| `status` | `open` (default), `resolved`, `dismissed` or `all`. **Ignored when `since` is given.** |
| `since` | A cursor: the `server_time` from this hub's previous response. |
| `limit` | Max items, default 500, max 2,000. |

Response:

```json
{"items": [ ... ], "server_time": "2026-10-06T17:04:05.122Z", "hub_id": "hub-d", "more": false}
```

**Without `since`:** the full current set for `status`. `status=open` returns every item that
is open and not expired. `resolved` includes expired items (shown as resolved).

**With `since`:** every item that changed on this hub after `since` (exclusive), **in any
status**, plus every item whose `expires_at` fell in `(since, now]` (reported as resolved).
This is how a poller learns about resolves, dismissals and expiry, not only new items.
"Changed on this hub" means this hub stored a new version of it after `since`: a local write,
or a replicated version arriving from a peer. It is matched against the hub's own receive
time, not the item's `updated_at`, so an item that reaches this hub late by replication is
still delivered even if its `updated_at` is older than the cursor.

**The polling loop:**

1. First poll (or after any doubt): `GET /v1/items?status=open`. Replace the local set.
2. Keep `server_time` from the response. Next poll: `GET /v1/items?since=<server_time>`
   (adding `status=open` is harmless; it is ignored). Upsert every returned item by `id`; drop
   it from the open view if its status isn't `open`. Store the new `server_time`.
3. If `more` is true, poll again immediately with the new `server_time`.
4. **`server_time` is a cursor for that hub only.** If `hub_id` in a response differs from the
   hub that issued the cursor (failover), discard the cursor and go back to step 1.

`server_time` is the hub's clock 1 ms before it ran the query (or, when `more` is true, just
before the last returned item), so a write landing in the same millisecond is never missed.
The price is that an item can occasionally be delivered twice; clients must treat responses
as idempotent upserts by `id`. Items come back ordered by the hub's receive time.

### `GET /v1/items/{id}` (reader)

The item, or `404`.

### `GET /v1/stream` (reader, optional)

Server-sent events. Each changed item (same rule as `since`: any version this hub stores) is
sent as

```
id: 1234
event: item
data: {...item JSON...}
```

A comment line (`: ping`) is sent about every 15 s. Reconnect with `Last-Event-ID: <id>` (or
`?after=<id>`) to resume; without it the stream starts at "now". The event id is a per-hub
sequence number, so after failover to another hub, reconnect without `Last-Event-ID` and do a
full poll. Expiry is not an event; clients compare `expires_at` with the clock themselves.

## Replication between hubs

Hubs are peers with no leader. Each hub has a `hub_id`, a list of peer URLs and a shared
`peer_secret`. Replication endpoints authenticate with `Authorization: Bearer <peer_secret>`
(compared in constant time) and are disabled (`404`) on a hub with no secret.

### Records

Replication carries full records: the item JSON above with the raw stored `status` (expiry not
applied) plus `token_id`, `origin_hub` (where it was minted) and `updated_by` (the hub that
made this version). Token records carry `id`, `name`, `role`, `hash` (sha256 hex, never the
token), `created_at`, `updated_at`, `revoked_at` and `updated_by`.

### Push: `POST /v1/replicate`

```json
{"from_hub": "hub-d", "items": [ ...item records... ], "tokens": [ ...token records... ]}
```

Response `{"ok": true, "applied": <n>, "hub_id": "linux-box"}`; `409 self` if `from_hub` is the
receiving hub's own id (the sender then stops using that peer).

Every accepted write (create, upsert, resolve, patch, token add/revoke, merge) inserts one row
per peer into a durable `outbox` table in the same SQLite transaction as the write. A worker
thread per peer sends batches of up to 200 records, always the record's *current* version, and
deletes the rows only after a 2xx. On failure it backs off exponentially (1 s doubling to
5 min, ±20% jitter). Outbox rows survive restarts. The admin tool writes to the same outbox, so
`needs-you-admin token add` on one hub reaches every peer.

Applied records are not forwarded again (the mesh is full); anti-entropy covers indirect paths.

### Pull (anti-entropy): `GET /v1/replicate/changes?after=<seq>&limit=<n>`

Every stored version gets a per-hub sequence number. The response is

```json
{"hub_id": "linux-box", "epoch": "01M...", "max_seq": 812, "next_after": 500, "more": true,
 "items": [ ... ], "tokens": [ ... ]}
```

Each hub pulls from each peer at start-up and then every 60 s, keeping a cursor per peer and
paging while `more` is true. Because applying a replicated version also gives it a local
sequence number, pull is transitive: a hub that was down catches up from any surviving peer.
`epoch` is a random id minted when a database is created; if a peer's epoch changes (its
database was replaced) or its `max_seq` is below the cursor, the puller restarts from 0.

### Conflict rules

1. **Last writer wins, per `id`.** A record replaces the local one only if
   `(updated_at, updated_by)` is strictly greater (timestamps first, then hub id as a string
   tie-break). Re-applying the same version is a no-op, so delivery is idempotent and order
   independent. Every local write sets `updated_at` to `max(now, previous + 1 ms)`, so it always
   beats the version it was based on.
2. **Upsert by key uses the local id.** A POST whose key matches an open item on this hub
   updates that item, so after replication has delivered an item, every hub upserts into the
   same id.
3. **Two hubs mint different ids for one key** (both accepted a POST for the key before
   hearing of the other's). When a hub applies a record that is open and finds another open,
   unexpired item with the same key, it merges them:
   - the **lowest id wins** (ULIDs start with the creation time, so the earliest-minted item
     survives);
   - the winner takes the **freshest content**: the `title`, `body`, `priority`, `context`,
     `kind`, `links`, `source`, `expires_at` and `content_updated_at` of whichever record has the
     greatest `(content_updated_at, updated_at, updated_by)`; `created_at` becomes the earliest,
     `seen_at` the latest;
   - every loser becomes `status: "resolved"` with `superseded_by: <winner id>`;
   - both writes get a fresh `updated_at` and replicate like any other write.

   Hubs can see these events in different orders, so there is one more rule: whenever a hub
   applies a winner or a superseded record, it checks that the winner's `content_updated_at` is
   at least that of every item superseded by it, and copies the freshest content over if not.
   All hubs pick the same winner id and converge on the same content; only the merge
   timestamps differ, and LWW settles those. Clients see the loser close and the winner update.
4. **Expiry is computed, never written**, so hubs can't disagree about it.
5. **Tokens** replicate by `id` with the same LWW rule. Revocation is a write, so it wins over
   the older active version. An active name must be unique on the hub where it's added.

### Known limits

- LWW uses wall clocks. Keep hubs on NTP; a hub whose clock runs far ahead wins concurrent
  edits to the same item.
- A resolve by key on hub B for an item that hasn't replicated to B yet resolves nothing. The
  CLI sends to the first reachable hub in a fixed order, so in practice a sender's add and
  resolve land on the same hub.
- A resolve on one hub concurrent with a re-post on another is decided by LWW: the later write
  wins.
- Closed items are kept indefinitely (they're tiny). There is no purge yet.
