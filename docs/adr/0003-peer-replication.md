# 0003. Leaderless peer replication between hubs

- Status: Accepted
- Date: 2026-10-06

## Context

One hub is a single point of failure: when it's down or asleep, alerts are delayed or lost. Running 2–3 hubs needs replication, and the hubs are small, independently run machines on a tailnet: there's no consensus service, and any of them can be offline for hours. The data is small (titles, short text, links) and conflicts are rare, because one sender usually owns a key and posts to the first hub in a fixed order.

The full contract is in [API.md, "Replication between hubs"](../API.md#replication-between-hubs). This ADR records the choices.

## Decision

- **No leader.** Every hub accepts writes. Each has a `hub_id`, a peer list and a shared `peer_secret` (Bearer auth, compared in constant time).
- **Stable ids:** item ids are **ULIDs** minted once by the hub that created the item and replicated unchanged, so an id means the same item everywhere and sorts by creation time.
- **Push:** every accepted write inserts one row per peer into a durable `outbox` in the same SQLite transaction. A worker per peer sends the record's current version in batches (`POST /v1/replicate`), deleting rows only after a 2xx, with exponential backoff (1 s → 5 min, ±20% jitter).
- **Pull (anti-entropy):** each hub pulls `GET /v1/replicate/changes?after=<seq>` from each peer at start-up and every 60 s, with a per-peer cursor and an `epoch` that resets it if a peer's DB is replaced. Applied versions get a local sequence number, so catch-up is transitive.
- **Last writer wins per id** on `(updated_at, updated_by)`; local writes set `updated_at = max(now, previous + 1 ms)`. Re-applying a version is a no-op, so delivery is idempotent and order-independent.
- **Same-key race:** if two hubs mint different ids for one open key, the **lowest ULID wins**, taking the freshest content (by `content_updated_at`, then `updated_at`, `updated_by`), the earliest `created_at` and the latest `seen_at`. Losers become `resolved` with `superseded_by`. A repair rule re-copies content when merges are seen in different orders, so all hubs converge.
- **Expiry is computed, never written**, so hubs can't disagree about it.
- **Tokens** replicate as records (hash only, never the secret) with the same LWW rule; revocation is a write.

## Consequences

- Any hub can be down; writes elsewhere continue and it catches up on return. A fresh, empty hub fills itself from its peers.
- Wall-clock LWW: hubs must run NTP. A hub with a fast clock wins concurrent edits to the same item.
- A resolve by key on a hub that hasn't yet received the item resolves nothing. Mitigated by clients using hubs in the same fixed order.
- A resolve concurrent with a re-post on another hub is decided by LWW (the later write wins), which is acceptable for alerts.
- Closed items are kept forever for now (no purge or tombstone GC yet).
- Every hub implementation (the embedded hub of [0001](0001-hub-in-mac-app.md), a server hub, a possible Cloudflare hub in [0004](0004-always-on-hub.md)) must implement this exactly. The rules are subtle enough that a shared conformance suite is required before a second implementation ships.
