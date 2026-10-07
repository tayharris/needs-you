# needs-you hub API (v1): wire contract

This is the exact contract implemented by `hub/needs_you_hub.py`. The design rationale is in
`adr/0007-founding-design.md`; how senders should behave is in `AGENT-GUIDE.md`; running hubs is in `HUB.md`.

## Conventions

- **Transport:** plain HTTP on the tailnet or loopback, or any https URL. Clients use the hub's
  `public_url`: a MagicDNS name (`http://<hub>.<tailnet>.ts.net:8765`), or
  `http://127.0.0.1:8765` for a hub on the same machine. Request and response bodies are JSON
  (UTF-8), except the `/join` pages and `/dl` files.
- **Host check (DNS rebinding):** every endpoint answers only when the `Host` header is an IP
  literal, `localhost`, a bind name, the `public_url` host (and, for a `*.ts.net` name, its
  short form and `<that label>.<any tailnet>.ts.net`), the machine's host name (full, short,
  `<short>.local`, `<short>.<tailnet>.ts.net`), or a name in the hub's `allowed_hosts`. Any
  other name gets **421** `misdirected`, a malformed `Host` **400**; no `Host` at all (HTTP/1.0)
  is accepted. `allowed_hosts` comes from the config, `--allowed-host NAME` (repeatable) and
  `NEEDS_YOU_HUB_ALLOWED_HOSTS` (comma-separated; the Mac app's hub inherits it from the app's
  environment); `*` turns the check off.
- **Timestamps:** the hub always emits RFC 3339 UTC with exactly three fractional digits:
  `2026-10-06T17:04:05.123Z`. These sort correctly as strings. On input the hub accepts
  ISO 8601 with or without fractional seconds, with `Z` or a `±HH:MM` / `±HHMM` offset, or no
  zone (taken as UTC), or a number of epoch seconds. Precision below 1 ms is dropped.
  Timestamps must fall between 1970-01-01 and 9999-12-31 (UTC); anything else is a 400.
- **Auth:** `Authorization: Bearer <token>`. Every token has one role:

  | Role | Can call |
  |---|---|
  | `sender` | `POST /v1/items`, `POST /v1/items/resolve` |
  | `reader` | `GET /v1/items`, `GET /v1/items/{id}`, `PATCH /v1/items/{id}`, `GET /v1/stream` |
  | `owner` | everything `reader` can, plus invites (`/v1/invites`) and tokens (`/v1/tokens`): list, create, revoke and request updates (the Mac app) |

  `GET /v1/health`, `POST /v1/invites/redeem` (the invite code is the credential),
  `GET /join/<code>[/install.sh]` and `GET /dl/<file>` need no token. The hub stores only the sha256 of each token, and records
  which token created or last re-posted each item (used by the volume guard).
- **Client versions (optional):** senders send
  `X-Needs-You-Client: cli=<v>; hook=<v|none>; skill=<v|none>; orca=<v|none>` on every request.
  The hub keeps the last report per sender token, **on that hub only** (not replicated), with
  the time it last saw the token, and lists both in `GET /v1/tokens`. Parsing is strict: at
  most 200 characters, `;`-separated `name=value` pairs, names `cli`, `hook`, `skill`,
  `orca` (others ignored), values `X.Y.Z`, `none` or `unknown` (others dropped). A missing or
  unparseable header never fails a request. A request without it keeps the last report and
  only updates `last_seen_at`, which is written at most every 10 minutes unless the versions change.
- **Update requests (optional):** while the owner has asked a sender token's machine to update
  (`POST /v1/tokens/<id>/request-update`, below), every **2xx** JSON response to a request made
  with that token (`POST /v1/items`, `POST /v1/items/resolve`, token-checked `GET /v1/health`)
  carries `"update_requested": true`. Absent otherwise. It is a flag only: no URL, version or
  command comes with it. A CLI that understands it runs its own `needs-you update` (with
  auto-update on) or prints a reminder; older clients ignore it.
- **Errors:** a non-2xx response has the body
  `{"error": "<code>", "message": "<human text>", "field": "<field path>"}` (`field` only on
  validation errors, for example `title`, `links[2].url`, `source.agent`).

  | HTTP | `error` | When |
  |---|---|---|
  | 400 | `invalid` | Validation failed, bad JSON, bad query parameter |
  | 401 | `unauthorized` | Missing, unknown or revoked token (or bad peer secret) |
  | 403 | `forbidden` | Valid token, wrong role for the endpoint |
  | 404 | `not_found` | Unknown endpoint, unknown id on `GET`/`PATCH /v1/items/{id}`, or nothing to revoke on `DELETE /v1/invites/…` / `/v1/tokens/…` |
  | 409 | `self` | A hub tried to replicate to itself (replication only) |
  | 421 | `misdirected` | The `Host` header names something this hub isn't (below). Clients fail over to their next hub URL |
  | 413 | `too_large` | Body over 64 KiB (8 MiB for `/v1/replicate`) |
  | 429 | `too_many_open` | The token already has 60 open items (the volume guard) |
  | 429 | `rate_limited` | Too many failed invite redeems from this client IP (10 per 10 min by default) |
  | 500 | `internal` | Bug; details are in the hub's log |

- Unknown JSON fields in requests are ignored, so newer clients can send extra fields.
  Clients must likewise ignore unknown response fields.

## The item

```jsonc
{
  "id": "01M492BJ7AYVYAA9X7WTP13JWG",      // ULID minted once by the hub that created it; same on every hub
  "key": "work:ACME-123:redo-blocked",       // sender's dedupe key; = id when the sender gave none
  "context": "work",                         // work | personal
  "kind": "needs",                           // needs | done | info
  "priority": "normal",                      // urgent | normal | low
  "title": "ACME-123: push blocked on the migration fork",
  "body": "Choose: **merge** or **bypass**.", // markdown, or null when empty
  "links": [{"label": "Jira", "url": "https://example.atlassian.net/browse/ACME-123"}],
  "steps": [                                 // the person's checklist, in order; [] when none
    {"text": "Pick **merge** or **bypass** in the PR thread", "done": false,
     "link": {"label": "PR #42", "url": "https://github.com/example/app/pull/42"}},
    {"text": "Re-run the push", "done": false}
  ],
  "source": {"host": "my-server", "agent": "orca:redo-fixer", "project": "app"},
  "status": "open",                          // open | resolved | dismissed
  "created_at": "2026-10-06T17:04:05.123Z",
  "updated_at": "2026-10-06T18:04:05.456Z",  // moves on EVERY write (re-post, resolve, patch)
  "content_updated_at": "2026-10-06T17:04:05.123Z", // moves only when title, body, priority or steps change
  "seen_at": null,
  "expires_at": null,                        // done/info default to created/re-posted + 24 h
  "superseded_by": null                      // set when this item lost a same-key merge (see Replication)
}
```

### Change detection: `content_updated_at`

`content_updated_at` is the re-animation signal. It is set at creation and changes only when a
re-post changes `title`, `body`, `priority` or `steps` (any step's text, link or `done`, or
the list itself). Re-posting identical content, changing only
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
{"ok": true, "hub_id": "hub-a", "version": "1.0.0", "api": "v1", "time": "2026-10-06T17:04:05.123Z",
 "stats": {"db_bytes": 98304, "items": 41, "open_items": 3, "live_invites": 1, "outbox_pending": 0}}
```

`stats.db_bytes` is the database plus its WAL file. With a valid token, `stats.outbox` also
gives the pending outbox rows per peer URL.

If a bearer token is sent it is checked but never causes an error: a valid token adds
`"token": {"name": "...", "role": "sender"}` and a `"peers"` array (per-peer outbox depth,
last successful push/pull, last error); an unknown or revoked token adds `"token": null` and
`"token_error": "unknown or revoked token"`.

### `POST /v1/items` (sender)

Create an item, or update the open item with the same `key`.

| Field | Type | Rule | Default |
|---|---|---|---|
| `key` | string | ≤ 200 chars, only `A-Z a-z 0-9 . _ : - / @ # + =` | the new item's id (so no dedupe) |
| `title` | string | required, 1–100 chars after trimming, no control characters (see below) | |
| `body` | string | ≤ 2,000 chars, markdown; newlines and tabs allowed | empty |
| `context` | string | `work` or `personal` (case-insensitive) | `work` |
| `kind` | string | `needs`, `done` or `info` | `needs` |
| `priority` | string | `urgent`, `normal` or `low` | `normal` |
| `links` | array | ≤ 6 of `{"label": ≤ 80 chars, "url": ≤ 2,000 chars}` | `[]` |
| `steps` | array | ≤ 10 of `{"text", "link", "done"}`, see below | `[]` |
| `source` | object | optional `host`, `agent`, `project`, each ≤ 100 chars | `{}` |
| `expires_at` | timestamp | any accepted timestamp | `done`/`info`: now + 24 h; `needs`: none |
| `status` | | **rejected** (use resolve or PATCH) | |

Link URLs must use one of these schemes (case-insensitive): `https`, `slack`,
`vscode`, `cursor`, `figma`, `msteams`, `discord`, `linear`. Anything else, including `http`, `jira`,
`file`, `javascript` and `orca`, is a 400. Text strings are trimmed.

Before the scheme is even read, every link URL (the app actions below included) must fit a
strict, parser-neutral subset of RFC 3986, checked on the raw string by the hub and the Mac app
with the same regex: plain ASCII; `<scheme>://` (so `https:host` and `vscode:/file/x` are
refused); no userinfo `@` before the host; no backslash, whitespace, quotes, `[ ] < > ^` `` ` ``
`{ | }` or control characters anywhere; `%` only as `%XX`; at most one `#`. An `https` link
also needs a host (`https:///x` and `https://:443/` are refused). Percent-encode anything
else.

`vscode` and `cursor` reach every installed extension's URI handler, so only these shapes are
accepted (the scheme is case-insensitive, the rest is matched exactly, lowercase):

| Shape | Opens |
|---|---|
| `vscode://file/<abs path>[:line[:col]]` | A file or folder on the Mac. No query, no fragment, no `//` after `file` |
| `vscode://vscode-remote/ssh-remote+<host>[/<abs path>]` | A Remote-SSH window. `<host>` is an `~/.ssh/config` alias or name, optionally `user@`: letters, digits, `.`, `_`, `-`, starting with a letter or digit, no `%`; an all-hex value starting `7b` (a hex-encoded JSON host spec) is refused |
| `vscode://vscode-remote/tunnel+<name>[/<abs path>]` | A Remote Tunnel window (tunnels belong to the user's own account); same name rule |
| `vscode://anthropic.claude-code/open?session=<id>` | The Claude Code extension's tab for that session. Exactly one parameter, `session`, 8–64 letters, digits or `-` |

The same with `cursor://`. Paths take RFC 3986 path characters and `%XX` escapes, but no escape
that decoding would turn into structure or into something to decode again (`%2F`, `%3F`, `%23`,
`%2E`, `%25`, `%5C`), no escaped control character (`%00`–`%1F`, `%7F`), and no `.` or `..`
segment. Everything else is a 400: other authorities
(`vscode://<publisher.extension>/…`, `vscode://settings/…`), `wsl+`, `dev-container+` and other
remote kinds, userinfo, ports, queries or fragments on file and remote links, other paths or
parameters on the Claude link. `orca://` was dropped: Orca's only link
(`orca://skills/share/<id>`) imports a skill, which a card should never ask for, and the Orca
jump is the app action below.

One exception: the Mac app's own scheme, for a fixed set of **app actions** (the card's
**Terminal** button). The hub accepts `needsyou://<host>/<path>?<query>` only for these
`<host>/<path>` pairs (case-insensitive), and nothing else under `needsyou://`:

| Action | Link | What the app does |
|---|---|---|
| `orca/terminal` | `needsyou://orca/terminal?handle=term_<uuid>[&environment=<name>]` | `orca terminal switch`. The handle is `term_` plus 8–64 lowercase hex or `-`; the environment name is letters, digits, space, `.`, `_`, `-`, ≤ 64 |
| `terminal/focus` | `needsyou://terminal/focus?app=<app>&<id>` | Focuses one terminal tab or pane on the Mac (below) |

`terminal/focus` takes `app` and exactly the parameters for that app, each at most once:

| `app` | Parameters | Mac side |
|---|---|---|
| `wezterm` | `pane=<n>` (1–6 digits, `$WEZTERM_PANE`) | `wezterm cli activate-pane --pane-id <n>`, then WezTerm comes forward |
| `tmux` | `pane=<n>` (the pane id `%<n>` without the `%`, 1–6 digits) **or** `target=<session>:<window>.<pane>` (session: letters, digits, `_`, `-`, ≤ 64, not starting with `-`; window and pane: 1–4 digits); optional `host=<iterm\|terminal\|wezterm\|ghostty>`, the terminal tmux runs in | `tmux select-window -t` / `select-pane -t` on the default tmux server, then the host terminal comes forward |
| `iterm` | `session=<UUID>` (the part of `$ITERM_SESSION_ID` after `:`) **or** `tty=/dev/ttys<n>` | AppleScript (opt-in on the Mac): selects that session's window, tab and session |
| `terminal` | `tty=/dev/ttys<n>` (1–4 digits) | AppleScript (opt-in on the Mac): selects the Terminal.app tab with that tty |
| `ghostty` | none | Ghostty comes forward (no tab selection yet) |

The hub checks only the action prefix; the app parses every link into a typed value and
refuses anything else (an unknown parameter, a repeated one, a value outside its pattern, a
value starting with `-`, user, port or fragment), and then does nothing. It runs only fixed
executables from fixed paths with argument arrays, never a shell, and AppleScript only as
fixed handlers called with the validated value as a typed parameter. Worst case for a
sender: the Mac shows a different terminal tab. A hub older than an action rejects the item
with 400; senders that add one (the Claude Code hook) retry without their `needsyou://` links.

Control characters are refused in every text field (`title`, `body` except newline and tab,
link labels, `source` fields): C0, DEL, C1 (U+0080–U+009F), and the bidi embedding, override
and isolate controls U+202A–U+202E and U+2066–U+2069, which can make text read as something
it isn't. Ordinary right-to-left text, marks (U+200E/U+200F) and joiners (U+200C/U+200D) are
fine. Link URLs may not contain whitespace or invisible format characters at all (percent-encode
a space as `%20`). Item records that arrive by replication keep only links that pass these
rules. The same goes for steps: their text and link fields follow these rules on POST, and a
replicated step whose link fails keeps its text and loses the link.

**Steps** are the things the person has to do, in order. Each step is an object:

| Field | Type | Rule | Default |
|---|---|---|---|
| `text` | string | required, 1–200 chars after trimming, no newlines or control characters; inline markdown | |
| `link` | object | optional `{"label", "url"}`, validated exactly like an entry of `links` (same limits and schemes) | none |
| `done` | boolean | `true` or `false` (anything else is a 400) | `false` |

Unknown step fields are ignored. Errors name the step, for example `steps[2].link.url`. The
hub returns every step as `{"text", "done"}` plus `"link"` when it has one; an item without
steps has `"steps": []`. Steps are the sender's view: there is no endpoint to tick one, and
the Mac app keeps the person's ticks locally (it offers Done once every step is ticked).

Semantics:

1. If an item with this `key` is open (and not expired), it is updated **in place, keeping its
   id**. A re-post is the sender's full current view: `title`, `body`, `context`, `kind`,
   `priority`, `links`, `steps`, `source` and `expires_at` are all replaced (omitted optional
   fields become empty/default). `updated_at` always moves (strictly forward, even within one
   millisecond). `content_updated_at` moves only if `title`, `body`, `priority` or `steps`
   changed. The
   item's token becomes the re-posting token. The volume guard does not apply to updates.
2. Otherwise a new item is created with a new id. If the token already owns 60 open,
   unexpired items, the hub returns `429 too_many_open` instead.

Response: `201` when created, `200` when an existing item was updated. The body is the item
plus `"created": true|false` and `"changed": true|false` (`changed` is true on create and when
title/body/priority/steps changed).

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
| `status` | `open` (default), `resolved`, `dismissed` or `all`. **Ignored when `cursor` or `since` is given.** |
| `cursor` | A cursor: the `next` from this hub's previous response. Opaque; send it back unchanged. |
| `since` | A cursor for clients that don't know `next`: the `server_time` from this hub's previous response. |
| `limit` | Max items, default 500, max 2,000. |

Response:

```json
{"items": [ ... ], "server_time": "2026-10-06T17:04:05.122Z", "next": "01M492BJ7A...J.812.1791306245123",
 "hub_id": "hub-a", "more": false}
```

**Without `cursor` or `since`:** the full current set for `status`. `status=open` returns every
item that is open and not expired. `resolved` includes expired items (shown as resolved).

**With `cursor` or `since`:** every item that changed on this hub after the cursor, **in any
status**, plus every item whose `expires_at` passed since then (reported as resolved). This is
how a poller learns about resolves, dismissals and expiry, not only new items. "Changed on
this hub" means this hub stored a new version of it after the cursor: a local write, or a
replicated version arriving from a peer. That is this hub's own order, not the item's
`updated_at`, so an item that reaches this hub late by replication is still delivered even if
its `updated_at` is older than the cursor.

**The polling loop:**

1. First poll (or after any doubt): `GET /v1/items?status=open`. Replace the local set.
2. Keep `next` and `server_time` from the response. Next poll:
   `GET /v1/items?cursor=<next>&since=<server_time>` (adding `status=open` is harmless; it is
   ignored). Upsert every returned item by `id`; drop it from the open view if its status isn't
   `open`. Store the new `next` and `server_time`.
3. If `more` is true, poll again immediately the same way.
4. **Both are cursors for that hub only.** If `hub_id` in a response differs from the hub that
   issued the cursor (failover), discard them and go back to step 1.

`next` (hubs after 0.1.2) is `<database epoch>.<seq>.<expiry position>`: the hub's per-write
sequence number, so a page always moves past what it returned and never holds more than
`limit` items, however many writes share a millisecond. Clients must not parse it. A hub
answers a `cursor` from another database (it was replaced) or one it can't read by serving
`since` instead when that was sent, and with `400 invalid` (`"field": "cursor"`) when it
wasn't; drop the cursor and do a full poll then. Sending both is also what keeps an older hub,
which ignores `cursor`, working. `next` is in every response except a `since`-only page with
`more: true`; keep paging with `since` then, and the last page carries a `next`.

`server_time` is the hub's clock 1 ms before it ran the query, so a write landing in the same
millisecond is never missed; when a `since` page has `more`, it is instead the time of the
page's last event, and the page holds **every** event up to that millisecond (so it can
exceed `limit` when more than `limit` writes or expiries share it; hubs up to 0.1.2 served such a page
repeated forever). The price is that an item can occasionally be delivered twice; clients
must treat responses as idempotent upserts by `id`. With `cursor`, changes come back in the
hub's write order, then expiries; with `since`, in time order.

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

## Invites

An invite is a link that sets up one or more machines. Redeeming it mints a **new token per
machine**, so one link with `uses: 5` can set up five servers, each with its own revocable
token. Codes are `nyi_` plus 192 random bits (URL-safe base64); hubs store only their sha256.

### `POST /v1/invites` (owner)

```json
{"name": "my-server", "role": "sender", "uses": 1, "ttl_hours": 72}
```

| Field | Rule | Default |
|---|---|---|
| `name` | required, 1–40 chars of letters, digits, `.`, `_`, `@`, `-` | |
| `role` | `sender`, `reader` or `owner` | `sender` |
| `uses` | integer 1–100 | 1 |
| `ttl_hours` | number, more than 0 and at most 2160 (90 days) | 72 |

Response `201`:

```json
{"code": "nyi_...", "join_url": "http://hub-a.example.ts.net:8765/join/nyi_...",
 "mac_url": "needsyou://connect?hub=http%3A%2F%2Fhub-a.example.ts.net%3A8765&code=nyi_...",
 "expires_at": "2026-10-09T17:04:05.123Z",
 "id": "01M...", "name": "my-server", "role": "sender", "uses": 1,
 "install_command": "curl -fsSL http://hub-a.example.ts.net:8765/join/nyi_.../install.sh | bash -s -- --yes --claude-hooks user --skill --alerts",
 "agent_prompt": "Set up needs-you alerts on this machine: read http://hub-a.example.ts.net:8765/join/nyi_... and follow it. If this machine runs Claude Code, use --claude-hooks user --skill --alerts. If it runs OpenAI Codex CLI, add --codex-hooks user; Gemini CLI, add --gemini-hooks user; opencode, add --opencode-plugin."}
```

`install_command` and `agent_prompt` are only present for `sender` invites. Both set up Claude
Code alerts (`--claude-hooks user --skill --alerts`); the join page lists the other options. The URLs use the
hub's `public_url` (config `public_url` / `--public-url`; without it, the first bind address).

### `GET /v1/invites` (owner)

`{"invites": [{"id", "name", "role", "uses", "left", "created_at", "expires_at"}, ...]}`: every
invite that is neither revoked nor expired, including used-up ones (`left: 0`), whose
installer still re-runs and uninstalls until they expire. Never includes codes.

### `DELETE /v1/invites/<id or name>` (owner)

Revokes the invite: it can't be redeemed, and its `/join` page and installer stop working.
Tokens it already minted stay valid (revoke those separately). Response `200`
`{"revoked": [{"id", "name"}]}`; `404 not_found` if no unrevoked invite has that id or name.

## Tokens

### `GET /v1/tokens` (owner)

```json
{"tokens": [{"id": "01M...", "name": "servers-devbox", "role": "sender",
             "created_at": "2026-10-06T17:04:05.123Z", "open_items": 2, "current": false,
             "client": {"cli": "0.1.1", "hook": "0.1.1", "skill": "0.1.1", "orca": "none"},
             "last_seen_at": "2026-10-07T09:12:00.000Z", "update_requested_at": null}]}
```

Active tokens only. `current` marks the token making the request. Never includes secrets or
hashes. `client` is what the token's machine last reported in `X-Needs-You-Client` (`{}` when
nothing yet) and `last_seen_at` when this hub last saw a sender call or token-checked
`/v1/health` from it (`null` when never). Both are per hub: a client merging several hubs
takes the newest `last_seen_at` per token id. Hubs before 0.1.2 omit both fields.
`update_requested_at` is when an update request for the token was made on this hub, or `null`
(absent from hubs that predate it).

### `POST /v1/tokens/<id or name>/request-update` (owner)

Asks that sender machine to update: its next requests to **this hub** get
`"update_requested": true`. No body. Asking again refreshes the time. Response `200`:

```json
{"id": "01M...", "name": "servers-devbox", "update_requested_at": "2026-10-07T09:12:00.000Z"}
```

`404 not_found` if no active token has that id or name; `400 invalid` for a `reader` or `owner`
token (they don't run the CLI).

The hub records the CLI version the machine last reported with the request and **clears the
request by itself** when a request from that token reports a different `cli` version in
`X-Needs-You-Client`, or one at least the hub's own version (what its `/dl` serves). A request
made before the machine ever reported a version takes its first report as the baseline. A
request without the header changes nothing. Revoking the token drops its request.

**Per hub, not replicated** (like `client` and `last_seen_at`): the Mac app sends the request to
every owner hub it has. A machine that only talks to another hub doesn't see it there.

### `DELETE /v1/tokens/<id or name>/request-update` (owner)

Withdraws the request. Idempotent: `200` `{"id", "name", "update_requested_at": null}` whether
or not one was pending; `404 not_found` if no active token has that id or name.

### `DELETE /v1/tokens/<id or name>` (owner)

Revokes the token on this hub (and, by replication, on its peers). Its open items stay until
they are resolved, dismissed or expire. Response `200` `{"revoked": [{"id", "name"}]}`;
`404 not_found` if no active token has that id or name; `400 invalid` for the token making the
request (use another owner token, or `needs_you_admin.py`).

### `POST /v1/invites/redeem` (no token)

```json
{"code": "nyi_...", "host": "build-1"}
```

Response `200`:

```json
{"token": "ny_...", "role": "sender", "name": "my-server-build-1",
 "hub_urls": ["http://hub-a.example.ts.net:8765", "http://hub-b.example.ts.net:8765"],
 "hub_id": "hub-a"}
```

- `name` is `<invite name>-<host>` (the host is reduced to letters, digits, `.`, `_`, `-`). If
  an active token already has that name, `-2`, `-3`... is appended.
- `hub_urls` is this hub's `public_url` followed by its peers, in that order. Save it as
  `NEEDS_YOU_URLS`. When the request comes from the hub's own machine (a loopback address, or
  one of the addresses the hub listens on) and the hub listens on loopback, its loopback URL
  (`http://127.0.0.1:<port>`) comes first, so that machine's senders don't depend on the
  tailnet. (Behind a local reverse proxy every client looks local; the CLI fails over to the
  next URL.)
- Unknown, expired, revoked or used-up codes all get the same `404`
  `{"error": "not_found", "message": "invite not found, expired or used up"}`. Each failure
  counts against the client IP; after 10 failures in 10 minutes (`redeem_fail_limit`,
  `redeem_fail_window_seconds`) that IP gets `429 rate_limited` on redeem and `/join` until the
  window passes. Successful redeems don't count.

### `GET /join/<code>` (no token)

`text/markdown`, written for an agent and readable by a person: what needs-you is, the
one-line install command, the installer's options, and the posting rules. For a `reader` or
`owner` invite it says to open the `needsyou://` link on the Mac instead. Viewing the page
doesn't spend a use. A used-up invite's page is still served, with a note that it can't set
up a new machine. Unknown, expired and revoked codes get a plain-text `404` (and count as a
failed attempt). A sender invite's page ends with **Files and checksums**: each `/dl` file
and its sha256, the same values as `/dl/manifest.json`.

### `GET /join/<code>/install.sh` (no token)

A bash script (bash, curl and python3 only) with this hub's URL, the code and the uses left
baked in. See [guides/add-a-sender.md](guides/add-a-sender.md) for its flags. It is served
until the invite expires or is revoked, also after its uses are spent: re-runs and
`--uninstall` on a machine that is already set up don't redeem.

The script also carries the sha256 of every `/dl` file at the moment it was served
(`SHA256S`, the page's list). It checks each file it downloads (the CLI, hooks, skill, Orca
snippet) against that list and refuses a file that doesn't match or isn't listed, before
installing anything from it. This is integrity, not authenticity (the list and the files come
from the same hub): it catches corrupt or partial downloads and a hub whose files changed
between the page and the download.

For an unknown, expired or revoked code (or a rate-limited client) the response is still
`200`, with header `X-Needs-You-Invite: unusable (HTTP 404)` (or `429`) and a script that
prints the reason to stderr and exits 1. A `4xx` would make `curl -fsSL ... | bash` run an
empty script and exit 0, which reads as success.

### `GET /dl/<file>` (no token)

Serves files from the hub's install directory (`install_dir`, default: the directory above
`hub/`). Allow-list only:

| File | Source in the repo layout |
|---|---|
| `needs-you` | `cli/needs-you` |
| `needs-you-hook.sh` | `integrations/claude-code/needs-you-hook.sh` |
| `install-hooks.sh` | `integrations/claude-code/install-hooks.sh` |
| `hooks.json` | `integrations/claude-code/hooks.json` |
| `SKILL.md` | `integrations/claude-code/skill/needs-you/SKILL.md` |
| `orca-snippet.md` | `integrations/orca/snippet.md` (the Orca automation rules; prompts point at the installed copy) |
| `manifest.json` | generated: see below |

Anything else is a `404`. A file the install directory lacks is a `404` too.

`GET /dl/manifest.json` lists what this hub serves, for `needs-you update`:

```json
{"version": "0.1.2",
 "files": {"needs-you": {"sha256": "<64 hex>", "size": 51234, "version": "0.1.2"},
           "needs-you-hook.sh": {"sha256": "...", "size": 30211, "version": "0.1.2"},
           "install-hooks.sh": {"sha256": "...", "size": 8122},
           "hooks.json": {"sha256": "...", "size": 2310, "version": "0.1.2"},
           "SKILL.md": {"sha256": "...", "size": 9876, "version": "0.1.2"},
           "orca-snippet.md": {"sha256": "...", "size": 3456, "version": "0.1.2"}}}
```

`version` at the top is the hub's; a file's `version` is its stamp (`needs-you-version: X.Y.Z`
in a comment, `"_needs_you_version"` in `hooks.json`, `VERSION = "X.Y.Z"` in the CLI), absent
when the file has none. Files the hub doesn't have are left out. The checksums guard a sender
against truncated or mixed-version downloads; they don't make the hub more trustworthy than
it already is (it minted the sender's token and served its installer).

### Invite replication

Invite records replicate like tokens (`invites` arrays next to `tokens` in `/v1/replicate`
and `/v1/replicate/changes`), carrying the hash, never the code. Uses are a per-hub
grow-only counter (`"used": {"hub-a": 2, "hub-b": 1}`), merged by taking the maximum per hub,
so redemptions on different hubs add up and every hub converges on the same count.
Revocation wins over an unrevoked version.

**Double-spend window:** each hub checks uses against what it has seen. If two hubs redeem
the last use of the same invite within the replication delay (normally under a second; up to
the retry backoff if a hub is unreachable), both succeed, so a link can set up one machine
more than `uses`. Each extra machine still gets its own revocable token. Keep `uses` and
`ttl_hours` small.

## Housekeeping

The hub cleans up after itself every 10 minutes (`maintenance_seconds`):

- Hard-deletes items that were resolved or dismissed more than `retention_days` (default 7)
  ago, and items whose `expires_at` passed more than `retention_days` ago. Open `needs` items
  are never purged.
- Deletes peer outbox rows older than 7 days (anti-entropy covers anything they held).
- Deletes expired invites, and revoked ones 24 h after their last change. Used-up invites
  are kept until they expire.
- Checkpoints the WAL and runs an incremental vacuum (`auto_vacuum=INCREMENTAL`; older
  databases are migrated once at start-up), plus a full `VACUUM` once a day when more than a
  quarter of the file is free pages.

So purged items can't come back, a hub **refuses to apply** a replicated item that is closed
(or expired) and older than its own retention cutoff, and an invite that is expired, or
revoked past the 24 h grace period.

## Replication between hubs

Hubs are peers with no leader. Each hub has a `hub_id`, a list of peer URLs and a shared
`peer_secret`. Replication endpoints authenticate with `Authorization: Bearer <peer_secret>`
(compared in constant time) and are disabled (`404`) on a hub with no secret.

### Records

Replication carries full records: the item JSON above with the raw stored `status` (expiry not
applied) plus `token_id`, `origin_hub` (where it was minted) and `updated_by` (the hub that
made this version). `steps` is carried as the array. A record **without** a `steps` key comes
from a hub that predates steps: the receiver keeps its own steps for that id when the record's
`content_updated_at` equals its own (a resolve, dismiss, seen or unchanged re-post on the old
hub), and otherwise stores none. An empty array clears them. Older hubs ignore the field, so
their own copies have no steps. Token records carry `id`, `name`, `role`, `hash` (sha256 hex, never the
token), `created_at`, `updated_at`, `revoked_at` and `updated_by`.

### Push: `POST /v1/replicate`

```json
{"from_hub": "hub-a", "items": [ ...item records... ], "tokens": [ ...token records... ]}
```

Response `{"ok": true, "applied": <n>, "hub_id": "hub-b"}`; `409 self` if `from_hub` is the
receiving hub's own id (the sender then stops using that peer).

Every accepted write (create, upsert, resolve, patch, token add/revoke, merge) inserts one row
per peer into a durable `outbox` table in the same SQLite transaction as the write. A worker
thread per peer sends batches of up to 200 records (fewer when the body would pass 4 MiB), always the record's *current* version, and
deletes the rows only after a 2xx (rows older than 7 days are dropped; anti-entropy covers them). On failure it backs off exponentially (1 s doubling to
5 min, ±20% jitter). Outbox rows survive restarts. The admin tool writes to the same outbox, so
`needs-you-admin token add` on one hub reaches every peer.

Applied records are not forwarded again (the mesh is full); anti-entropy covers indirect paths.

### Pull (anti-entropy): `GET /v1/replicate/changes?after=<seq>&limit=<n>`

Every stored version gets a per-hub sequence number. The response is

```json
{"hub_id": "hub-b", "epoch": "01M...", "max_seq": 812, "next_after": 500, "more": true,
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
     `kind`, `links`, `steps`, `source`, `expires_at` and `content_updated_at` of whichever record has the
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
- Closed items are purged after `retention_days`. A hub that was offline for longer than that
  can still hold (and push) open versions of items the others resolved and purged; wipe such a
  hub's database before bringing it back (see HUB.md).
