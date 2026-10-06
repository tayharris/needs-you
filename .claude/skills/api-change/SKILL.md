---
name: api-change
description: Checklist for changing the needs-you wire contract (an endpoint, a field, a validation rule, a status code, the replication format) so the hub, CLI, Mac client, docs and tests change together. Use whenever a change touches request or response shapes in hub/needs_you_hub.py or docs/API.md.
---

# api-change

`docs/API.md` is the contract. Every hub implementation and every client follows it. Make the whole change in one branch.

## Before you code

1. **Is it compatible?** Adding an optional request field or a response field is compatible: old clients ignore unknown fields, old hubs ignore unknown request fields. Renaming, removing, changing a type, tightening validation, or changing a status code is **breaking**. Breaking changes need a new path (`/v2/...`) or a migration plan; write an ADR in `docs/adr/`.
2. **Replication:** if the item or token record changes, mixed-version hubs will exchange it. New fields must have a safe default when missing, and LWW (`updated_at`, `updated_by`) must still decide conflicts. Read the Replication section of `docs/API.md`.
3. **Privacy:** new fields hold titles, short text and links only. Nothing that invites secrets.

## Change, in this order

| # | File | What |
|---|---|---|
| 1 | `docs/API.md` | Update the contract first: field table, semantics, errors, examples |
| 2 | `hub/needs_you_hub.py` | Validation (`validate_*`), storage/schema (add columns with a migration that tolerates old DBs), handlers, replication record fields |
| 3 | `tests/test_validation.py`, `tests/test_api.py`, `tests/test_replication.py` | Table-driven cases for the new rule, and a mixed-version / missing-field replication case |
| 4 | `cli/needs-you` | New flags, docstring usage block at the top of the file |
| 5 | `tests/test_cli.py` | The flag end to end against a real hub |
| 6 | `mac/Sources/NeedsYouCore/Models.swift`, `HubClient.swift` | Decode the field (optional, tolerant of absence); PATCH bodies |
| 7 | `mac/Tests/NeedsYouCoreTests/` | Decoding/merge tests; register new classes in `mac/Sources/NeedsYouSelfTest/main.swift` |
| 8 | `docs/AGENT-GUIDE.md`, `integrations/claude-code/skill/needs-you/SKILL.md` | If senders should use it |
| 9 | `docs/guides/*`, `docs/HUB.md` | User-visible behaviour, config keys |
| 10 | Link allow-list only: `LinkPolicy.swift` **and** the hub's scheme list | Both or neither |

Bump `VERSION` in the hub/CLI only as part of a release (see the `release` skill).

## Verify

- `test-all` skill (Python on `/usr/bin/python3` 3.9, `mac/scripts/test.sh`).
- `smoke-e2e` skill, plus a `curl` of the new behaviour.
- Grep for the old name/shape across the repo: `grep -rn '<field>' hub cli mac/Sources docs integrations tests`.
- Python stays 3.9-compatible and stdlib-only.

## Future

When `protocol/` exists (docs/roadmap/ai-first.md, ADR 0004), also update the machine-readable spec there and the shared conformance suite, and run it against every hub implementation.
