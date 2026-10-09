# 0011. Status records: a quiet progress strip and usage meters, apart from items

- Status: Accepted for usage meters (2026-10-09); the progress strip is deferred (see "Owner decisions")
- Date: 2026-10-08, accepted 2026-10-09

## Context

needs-you is one inbox for "you have to do something" ([0007](0007-founding-design.md)). Every
item is something to act on, or a `done`/`info` FYI that expires and never counts. The agent
guide forbids progress cards, and that rule is what keeps the pill trustworthy: when it lights
up, someone needs you.

The owner asked for two things that aren't "you have to do something"
([roadmap/status-and-usage.md](../roadmap/status-and-usage.md)):

1. **Some way to see progress**: what agents and long jobs are doing, without each one posting
   a card.
2. **A small usage meter**: session (5 h) and weekly limits per provider (Claude, Codex, ...)
   and per account, "like Orca does".

What exists without a wire change:

- Threshold cards: `needs-you-usage` (Claude, status line) and the Codex hook post one low
  `info` card when a limit passes a threshold, expiring at the reset. That is an alert, not a
  meter: below the threshold nothing shows.
- Local status on the Mac: the app already shells out to `orca` for the Terminal button, so a
  strip from `orca worktree ps` (the Mac's Orca and its paired environments) needs no hub.
  `needs-you orca` gives agents the same rows. Neither covers a server with no Orca, CI, or
  usage numbers that exist only on a sender machine (the Claude status line input, Codex's
  session files).
- `info` with a short expiry, re-posted under one key: allowed by the API, but it is exactly a
  progress card. It shows under Recent, re-animates on every content change, counts toward the
  sender's 60-item volume guard and replicates every write. Not a pattern to bless.

So the numbers that matter live on sender machines, and the only way they reach the Mac is
the hub. Constraints that any design must keep:

- **Nothing new demands attention.** A status never counts, never animates, never notifies,
  never plays an arrival animation and never re-orders cards.
- **The panel never takes focus** (CLAUDE.md rule 2). A status row is read-only text with no
  buttons and no links.
- **No credentials, no account emails** (rule 3, and the owner's "never read OAuth tokens or
  browser cookies"). Usage numbers come only from what the agent hands its own hooks or
  writes locally.
- **Untrusted text.** Labels come from senders, branch names and terminals: one line, cleaned,
  never markdown, never a link.
- **Old clients and hubs keep working** (rule 6: unknown fields ignored both ways). A Mac app
  that predates statuses must not show them as cards; a sender talking to an older hub must not
  fail its caller (rule 8).
- **Cheap on peers.** A progress value can change every few seconds; item replication was
  built for writes a person causes.

## Owner decisions (2026-10-09)

The owner asked for usage meters ("we want usage meters, so whatever you need"; "get usage in
the app showing tracker, more customizations") and answered the open questions:

1. **Yes, for usage meters.** The progress strip is deferred: the hub accepts and lists
   `progress` statuses as designed, but the Mac app doesn't show them yet.
2. **Producers are hooks, status line helpers and pollers.** `needs-you status set` exists for
   them; the agent guide and skill don't tell agents to post progress, and "no progress cards"
   stays.
3. **Statuses replicate between hubs**, short-lived as designed.
4. **Meters show in the panel by default**, and a compact meter on the pill that Settings can
   turn off.
5. **Default providers: whatever has a producer** (Claude through `needs-you-usage`, Codex
   through its Stop hook), both the session (5 h) and weekly windows, "hide under" 0 % (always
   shown), all changeable in Settings → Usage. A warning colour from 80 % by default.

Also given: never read OAuth tokens or cookies; no emails in records; accounts are labelled by
a local id (`NEEDS_YOU_USAGE_ACCOUNT`) or a hash.

### As built

Where the build differs from the proposal below, the build and [API.md](../API.md#status-records-usage-meters) win:

- Schema 11 (not 9) adds the `status` table. A status's id is derived from its token and key
  (`st_` + sha256), so every hub names it the same.
- Replication carries statuses in their own `statuses` array in pushes and change pages, not as
  `{"kind": "status"}` records among items. Hubs that predate them ignore the array. A status a
  hub can't read is skipped (`"kind": "status"` in `skipped`), with no quarantine.
- A clear (`DELETE`) is a write that sets `expires_at` to now, so it replicates; expired records
  are therefore pushed like any other, and housekeeping deletes them an hour after expiry.
  `DELETE` answers `{"ok": true, "cleared": <bool>}` and is never refused as `too_fast`.
- `label` may be empty for a usage status; `account` follows `[A-Za-z0-9._-]{0,40}`.
- The producers send both windows when a number changed (at most every 15 s) and every
  5 minutes otherwise; `NEEDS_YOU_USAGE_METER=0` turns that off. The threshold cards stay.
- The Mac app shows one row per provider and account (the newest report wins when several
  machines report the same pair), a window whose `resets_at` has passed as reset (0 %), and
  fetches `GET /v1/status` from the hub that served its last items poll.
- A third producer, the Orca accounts poller (`needs-you orca usage`, run by the 5-minute
  `flush` with `NEEDS_YOU_ORCA_USAGE=1`, at most every 4 minutes), sends a usage status for
  every Claude and Codex account Orca manages on a host, from `orca account list --json` and
  nothing else. A managed account is labelled `orca-` + 8 hex of sha256 of its Orca account id.
  Orca's "system default" login is the account the local producers see, so it goes under their
  key (`usage:<provider>[:NEEDS_YOU_USAGE_ACCOUNT]`), one record and one row, and is left to
  them while either has sent within 15 minutes; the poller never clears that key. It clears
  the keys of accounts Orca no longer lists, skips Orca errors, numbers older than 12 h and
  more than 12 accounts (the 20-per-token limit), and sends nothing when `orca` is absent or
  its answer can't be read. No wire change.

## Decision (as proposed)

Add **status records**: a separate, small resource on the hub, not a kind of item.

### Wire

`PUT /v1/status/<key>` (sender token) sets one status; the key grammar is the item key's,
and keys are per token (a status belongs to the token that set it; another token's `PUT` to the
same key is a different record). Body:

```jsonc
{
  "type": "progress",                 // progress | usage
  "label": "nightly import",          // ≤ 60 chars, one line, plain text
  "state": "working",                 // progress: working | waiting | idle | done | failed
  "progress": 40,                     // progress: 0-100, or null for "no percentage"
  "detail": "step 3 of 7",            // ≤ 120 chars, plain text, optional
  "usage": null,                      // usage: {"provider": "codex", "account": "team-2",
                                      //   "windows": [{"name": "5h", "used_pct": 51, "resets_at": "..."},
                                      //               {"name": "7d", "used_pct": 41, "resets_at": "..."}]}
  "source": {"host": "devbox", "agent": "codex", "project": "app"},
  "expires_at": "2026-10-08T10:00:00Z" // required: progress ≤ now + 1 h, usage ≤ now + 8 days
}
```

- `DELETE /v1/status/<key>` (the same token) clears it. A status also ends at `expires_at`;
  expiry is computed, never written, as for items.
- `GET /v1/status` (reader or owner token) returns every unexpired status, newest first, with
  an `ETag`; `If-None-Match` answers `304`. The Mac polls it with its items poll. Not part of
  `GET /v1/items` or `/v1/stream`, so no client that predates it ever sees one.
- Validation as for item text: control and bidi characters refused, token-shaped text refused
  (`400 secret_in_text`, the same patterns the hooks redact; in the key and `source` too), `@` refused in `account` (no
  emails), `provider` and window `name` from `[a-z0-9-]{1,20}`, at most 4 windows.
- Limits: at most 20 live statuses per token and 64 per hub (`429 too_many_status`); at most
  one write per key every 10 s (`429 too_fast`, with `Retry-After`); sets and clears per token
  at the post rate, counted apart from posts (`429 rate_limited`). A status is never counted
  by the item volume guard.
- Storage: a `status` table (schema 9, backed up first like 7 and 8). Expired rows are deleted
  by housekeeping an hour after `expires_at`; nothing is kept for history.

### Replication

Replicated, LWW on `updated_at` like items, as a record type of its own in the push and pull
batches (`{"kind": "status", ...}`, next to `"item"`), so a status set on a server hub reaches a Mac that reads
another hub. A hub that predates it answers the batch's status records with a per-record error
and keeps the rest (the existing per-record rule). Writes are bounded by the 10 s rule, and an
expired record is never pushed. Until the Mac's own hub peers with server hubs (ADR
[0004](0004-always-on-hub.md), the next big item), a status reaches the Mac only through the
hub it reads.

### CLI and producers

- `needs-you status set --key K --label L [--state S] [--progress N] [--detail D]
  [--expires-in MINUTES]` and `needs-you status clear --key K`. Statuses are **never queued**
  in the outbox: a stale progress row is worse than none. With no hub reachable, or a hub that
  answers `404` (too old), the CLI says so on stderr and exits 0.
- `needs-you-usage` and the Codex hook set a `usage` status (`usage:<provider>[:<account>]`)
  on each check, in addition to the threshold card, which stays the alert.
- The GitHub poller, CI wrappers and `needs-you run` may set a `progress` status for a long job
  the person is waiting on; agents only through the same CLI, at most once a minute, and the
  agent guide keeps "no progress cards" as is.

### Mac app

- A strip at the top of the panel, collapsed by default to one line ("3 running · Codex 5h
  51%"), at most 8 rows when open, each row plain text: label, state, a thin progress bar,
  host. No buttons, no links, no focus. Statuses never change the pill's count or colour.
- Optional usage meters on the pill: two hairline bars (5 h, weekly) for the providers and
  accounts picked in **Settings**, coloured only past the threshold, hidden under N%.
- Settings: show progress (on/off), show usage (on/off), which providers and accounts,
  session/weekly/both, hide under N%. Defaults are an owner decision.

## Alternatives considered

- **`kind: "status"` on items.** Reuses `POST /v1/items`, keys, expiry and replication, but an
  older Mac app treats an unknown kind as `info` and would show every status as a card under
  Recent; an older hub answers `400`; each progress write moves `updated_at` and replicates as
  an item; and every item invariant (volume guard, `content_updated_at` re-animation, answers)
  would need a "except statuses" clause. Rejected: the separation is the point.
- **Mac-local only** (the Orca strip, no wire). Built first and kept, but it can't see a server
  without Orca, CI, or usage numbers that exist only on a sender machine.
- **Progress as short-lived `info` cards.** What the guide forbids; see Context.
- **The hub polls providers for usage.** It would need credentials. Rejected outright.

## Consequences

- needs-you would show, for the first time, something that is not a call to act. The strip and
  meters are quiet by construction (never counted, animated or notified), but the owner has to
  want that at all.
- One more resource for every hub implementation and the conformance suite (ADR 0004 phase 2),
  one more table and migration, a CLI subcommand, a Swift client and view, API.md, and tests:
  a change for the `api-change` skill, in one go.
- Usage numbers live on hubs for at most 8 days and contain no secrets or emails, but they do
  say how much someone used a paid plan; the Mac shows them only when switched on.
- Replication volume grows by at most one write per status per 10 s per token.

## Open questions for the owner (answered above, 2026-10-09)

1. Should needs-you show anything that isn't "you have to do something" (a progress strip,
   usage meters)? If not, this ADR is rejected and the threshold cards stay the only usage
   signal.
2. Progress from agents through the CLI, or only from hooks, pollers and CI wrappers?
3. Replicate statuses between hubs, or keep them on the hub that took them?
4. Defaults on the Mac: strip shown or hidden, meters on the pill or only in the panel?
5. Usage meters: which providers by default, session, weekly or both, and the "hide under"
   percentage.
