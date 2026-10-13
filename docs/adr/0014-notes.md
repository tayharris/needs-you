# 0014. Notes: a short todo list you keep, beside the alerts

- Status: Accepted (2026-10-13)
- Date: 2026-10-13
- Builds on [0007](0007-founding-design.md), [0009](0009-questions-on-cards.md) (the answer
  window, the first typed-input exception) and [0011](0011-status-records.md) (records that are
  never items)

## Context

The owner asked for "a toggle mode to add a couple quick things that i can toggle visibility on
separate from the alerts": a few important todos as checkboxes, with markdown so a line can link
to where the work is, and plain text reminders. Next comes a "gm / gn" routine that carries the
list over between days and prioritises the morning ([roadmap/notes-and-gm-gn.md](../roadmap/notes-and-gm-gn.md)).

Nothing that exists fits:

- **Items** are "you have to do something" from a sender, and a closed item loses its text
  within a day. A todo the person writes for themselves isn't one, and must outlive a day.
- **Statuses** expire within 8 days, hold one line, and never take links.
- A **file on the Mac** would be quickest, but agents on other machines (the gm routine, a
  sender that wants to leave "check the deploy tomorrow") could never add to it.

Constraints: the panel never takes focus (hard rule 2); no secrets in text (rule 3); links only
from the allow-list (rule 7); old clients and hubs keep working (rule 6); senders never fail
their caller (rule 8).

## Decision

### 1. One notes document per hub cluster, replicated

A **notes** record is one markdown document (`id` `nt_main`, at most 16,000 characters) stored
on every hub and replicated like a status: its own `notes` array in pushes and change pages,
last writer wins on (`updated_at`, `updated_by`). Hubs that predate notes ignore the array. It
is never purged; nothing about it counts, notifies or makes a card.

### 2. Readers edit the whole document, with a revision check

`GET /v1/notes` (reader) returns the document and its `rev`. `PUT /v1/notes` (reader) replaces
the text and must send the `base_rev` it read; a stale one is `409 conflict`, so two Macs (or a
Mac and the gm agent) never overwrite each other blindly. Replication between hubs still settles
concurrent writes by last writer wins; a revision check is per hub.

### 3. Senders may only append, and never read

`POST /v1/notes/append` (sender or reader) adds one line, as a checkbox by default, under a
`## <section>` heading (`Inbox` unless named), creating the heading at the end if it's missing.
The response carries the new `rev` only, never the text: a sender token on a build box can add
"check the nightly import" but can't read the person's list. Appends count toward the
per-token post rate (ADR 0010). A full document refuses the append (`400 notes_full`).

Reading the list for the gm routine is a later, separate decision (a narrow read scope).

### 4. Text rules

The document may hold line breaks and tabs, nothing else from the control range; no bidi
controls or U+2028/U+2029; nothing token-shaped (`secret_in_text`, the same patterns as a
status's text). Links are markdown links and render only if their scheme is on the allow-list
(`LinkPolicy`, as on cards). No HTML and no images are rendered.

### 5. The Mac: a Notes view in the panel, typing in its own window

- The panel gets a second view, Notes, toggled from the pill, the menu bar or a hotkey, shown
  and hidden apart from the alert cards.
- The view renders the document with the card renderer plus checkboxes. **Clicking a checkbox
  ticks it in place**: a click, like a card's buttons, never a key press, so the panel still
  never becomes key.
- **Amendment to rule 2** (as for the answer window in ADR 0009): an **Edit…** button in the
  Notes view opens a separate `NotesWindow`, an ordinary titled window with a plain markdown
  editor and a live preview, which may become key. It is the third and last exception besides
  Settings and the answer window, and opens only from that explicit click: never from a poll,
  an arrival, a timer or a hotkey.
- v1 edits markdown source, not WYSIWYG.

## Consequences

- A new table (schema 12), three endpoints, a `notes` array in replication, and
  `needs-you notes add` (sender tokens; the CLI has no reader token, so no `show`).
- The notes text lives on every hub the Mac peers with, as item text already does.
- A concurrent edit on two hubs before they sync loses one side (last writer wins). Acceptable
  for one person's list; the revision check covers the common case of one hub.
- The gm/gn routine builds on this without another wire change for writing; reading for agents
  needs its own decision.
