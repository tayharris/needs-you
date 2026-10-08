# 0010. Refuse line separators in one-line fields, check resolve's key, and cap posts per token

- Status: Accepted
- Date: 2026-10-08

## Context

Three gaps in `/v1` input handling, found in the 0.2.x bug hunt:

1. **U+2028 and U+2029** (LINE SEPARATOR, PARAGRAPH SEPARATOR) pass the hub's one-line check,
   which refuses only C0 controls and DEL (`[\x00-\x1f\x7f]`; U+0085 is already refused with
   the C1 range). Text views break a line at them, so a title, a source field, a link label or
   a step can show as two lines (or push the rest of the card out of view), which is what the
   one-line rule is there to stop.
2. **`POST /v1/items/resolve` takes any key.** `POST /v1/items` refuses a key outside `KEY_RE`
   (`400 invalid`), but resolve answers `200 {"resolved": 0}` for a key no item can have, so a
   sender with a typo or a mangled key (a shell that ate a `$`) is told "nothing open" instead
   of "that isn't a key".
3. **No rate on posts.** The volume guard caps a token's *open* items (60), but a sender stuck
   in a loop that re-posts the same key with new text, or posts and resolves, never reaches it:
   each re-post is a write, a replication record, an SSE event, and (when the text changes) a
   card that moves to the top of the Mac's panel again. Answers already have a per-token rate
   (`answer_rate_limit`).

Each is a tighter rule on an existing `/v1` endpoint, which the `api-change` skill calls a
breaking change. As in ADR 0006, a `/v2` would leave `/v1` open to exactly the problem.

## Decision

Change `/v1` in place:

- **One-line fields** (every text field but `body` and a question's `text`, which allow `\n`) also
  refuse U+2028 and U+2029: `400 invalid` with that field's `field`. `body` and question text keep them (they may
  hold line breaks). Records from peers are not re-checked (they were checked where they were
  posted); a peer on an older version may still replicate one.
- **Resolve by key** checks the key as `POST /v1/items` does (trimmed, at most 200 characters,
  `KEY_RE`): `400 invalid` with `field: "key"` otherwise. Resolve by `id` is unchanged.
- **Posts per token:** `POST /v1/items` counts every request per token in a sliding window,
  `post_rate_limit` (default 120) per `post_rate_window_seconds` (default 60). Past it:
  `429 rate_limited` with `Retry-After` (seconds; also `"retry_after"` in the body). The count
  is per hub and in memory; 0 turns it off. Resolves aren't counted: closing a card is never held back.

Migration:

- The repo's own senders already fold whitespace (the hooks' `one_line` splits on every
  Unicode space, U+2028/2029 included); the CLI turns U+2028/U+2029 in `--title` into spaces
  before it posts, so a sender that passed one keeps its card.
- The CLI never fails its caller on it: a post that gets `429 rate_limited` stays queued (exit
  0, "slow down" on stderr), and every queued add waits until the hub's `retry_after` (the
  `Retry-After` header, also `"retry_after"` in the error body), kept to one per key (a later
  add of a key replaces the held one, a resolve of it cancels it). Resolves still go. The
  hooks, the MCP server ("slow down, don't retry") and `needs-you-github` all post through
  the CLI, so they queue too. 120 a minute is far above any hook or CI job (a hook posts once
  per wait).
- Only `POST /v1/items` counts: replication between hubs, readers (the Mac app's PATCH and
  answers) and resolves never do.
- The Mac app doesn't post or resolve items, so it needs no change.

## Consequences

- A looping sender now gets `429` after two posts a second for a minute instead of filling the
  panel; the person sees the cards it already posted, unchanged.
- A sender that put U+2028/2029 in a title through its own HTTP client now gets `400` and must
  replace them (the error names the field).
- A resolve with a malformed key is a `400` (CLI exit 2) instead of a silent `resolved: 0`.
- Hubs on different versions disagree on these three rules until both are updated; none of
  them changes what is stored or replicated.
