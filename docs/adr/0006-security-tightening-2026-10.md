# 0006. Tighten link validation and add a Host check without a /v2

- Status: Accepted
- Date: 2026-10-07

## Context

The 2026-10-07 security audit (#14, #16) needs two changes the `api-change` skill calls breaking:
the hub refuses links it used to accept (`orca://`, `vscode://`/`cursor://` outside four shapes,
links outside a strict raw grammar), and it answers 421 to a `Host` it doesn't know. A `/v2`
path would leave `/v1` open to exactly what the audit found.

## Decision

Change `/v1` in place. Migration instead of a new path:

- Every link the repo's own senders write still passes (tests check the hook's output and the
  shared fixture file `tests/fixtures/link_cases.json`).
- The Claude Code hook posts its card again without links when the hub refuses one, so a custom
  `NEEDS_YOU_AGENT_LINK` that is now refused loses its button, not the card.
- Replicated records from older hubs keep only links the new rules allow (the item stays).
- The Mac app shows refused links on older cards as plain text.
- The Host check accepts every IP literal and the hub's own names, has an `allowed_hosts`
  escape hatch (`*` turns it off), and clients fail over on 421 like on a transport error.

## Consequences

Third-party senders posting extension-handler, `orca://` or malformed links get a 400 with a
message naming the allowed shapes. A hub reached by a name it can't know needs `allowed_hosts`.
Both are listed in the CHANGELOG and `docs/guides/troubleshooting.md`.
