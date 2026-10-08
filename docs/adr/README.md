# Architecture decision records

Short records of decisions that shape the code: Context, Decision, Consequences, Status. Add one when a change is hard to reverse or affects every component (a new dependency, a new hub implementation, a wire-format break). Number sequentially; never renumber. To change a decision, add a new ADR that supersedes the old one and update the old one's status.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-hub-in-mac-app.md) | The hub runs inside the Mac app by default | Accepted |
| [0002](0002-python-stdlib-only.md) | Python 3 standard library only for the hub and CLI | Accepted |
| [0003](0003-peer-replication.md) | Leaderless peer replication: ULIDs, LWW on `updated_at`, same-key merge | Accepted |
| [0004](0004-always-on-hub.md) | How to provide an always-on hub | Proposed |
| [0005](0005-ai-first.md) | AI-first repo and product | Accepted |
| [0006](0006-security-tightening-2026-10.md) | Tighten link validation and add a Host check in `/v1` (audit #14, #16) | Accepted |
| [0007](0007-founding-design.md) | Founding design: one inbox, senders post, the Mac pulls | Accepted |
| [0008](0008-mcp-server.md) | A one-file stdlib MCP server that wraps the CLI (`add`, `resolve`, `doctor`; no "list mine") | Accepted |
| [0009](0009-questions-on-cards.md) | Questions and choices on cards: the question and its choices on the card, a `question` field, and answers by click (opencode, Claude Code, `needs-you answer-wait`) | Accepted |

Template:

```markdown
# NNNN. Title

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD

## Context
## Decision
## Consequences
```
