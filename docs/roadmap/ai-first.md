# AI-first

Status (2026-10-08): items 4 (the MCP server) and 5 (`needs-you doctor`) are built and shipped, and most of 7 (agent self-setup) is. Still plan: the machine-readable spec (2), the conformance suite (3), the repo moves (1) and routing beyond links (6). The decision behind it is [ADR 0005](../adr/0005-ai-first.md).

**Product goal:** give AI agents the tools to set themselves up and to alert people when they actually need them, routed to where they need to act.

That means two audiences are first-class: agents that *use* needs-you (set up a machine, post, resolve, diagnose), and agents that *build* it (this repo). Both should find one obvious, machine-readable path.

## Where we are

| Surface | State |
|---|---|
| Sender contract | [AGENT-GUIDE.md](../AGENT-GUIDE.md); the same rules for Codex, Gemini and opencode through `--agent-instructions` |
| Claude skill | `integrations/claude-code/skill/needs-you/SKILL.md` |
| Hooks | Ten agents ([README](../../README.md#works-with)): "agent is waiting" and permission cards |
| MCP server | `integrations/mcp/needs_you_mcp.py`, installed with `--mcp` ([guide](../guides/mcp.md)) |
| Self-setup | Invite links: an agent prompt or `curl` one-liner from the Mac app; the `/join/<code>` page is Markdown written for an agent ([Add a sender](../guides/add-a-sender.md)) |
| Contributor entry | `CLAUDE.md`, `AGENTS.md`, `.claude/skills/` |
| Machine-readable API | None. `docs/API.md` is prose |
| Diagnosis | `needs-you doctor [--json]`, one next step per `WARN`/`FAIL` ([Troubleshooting](../guides/troubleshooting.md#start-here-needs-you-doctor)) |

## 1. Repo structure review

Is the layout predictable for an agent? Mostly. Top-level dirs map to components, each script has one job, docs are split by audience. The friction points:

1. **The contract has no home of its own.** `docs/API.md` describes it, `hub/needs_you_hub.py` implements it, `tests/` tests one implementation, and `mac/Sources/NeedsYouCore/HubClient.swift` consumes it. A second hub implementation (ADR 0004 (c)) would have no shared spec or tests to target.
2. **Integration docs are split** between `integrations/<x>/README.md` (reference) and `docs/guides/<x>.md` (task guide). An agent asked to "change the Orca integration" has to find both.
3. **Agent-facing entry points are scattered:** `docs/AGENT-GUIDE.md`, the skill under `integrations/claude-code/skill/`, `AGENTS.md`, invite prompts inside the Mac app's Swift code.
4. **`tests/` is Python-only** and sits at the root, while Swift tests live in `mac/Tests/`. Fine, but the name suggests it covers everything.
5. `scripts/` mixes hub install and sender setup; `deploy/` holds hub service files. Two places for "install a hub".

### Proposed moves (not done; other branches are editing these dirs)

| Move | Why |
|---|---|
| New `protocol/` with `openapi.yaml`, `schemas/*.json`, `conformance/` (a black-box test suite that takes a base URL + tokens) | One spec, one test suite, every hub implementation and client targets it |
| `tests/` → `hub/tests/` + `cli/tests/` (or keep `tests/` but rename to `tests/python/`), with shared helpers in `tests/support.py` | Tests sit next to what they test |
| `docs/guides/<integration>.md` → `integrations/<x>/GUIDE.md`, with `docs/guides/` keeping only cross-cutting guides (quickstart, troubleshooting) and an index linking out | One obvious place per integration |
| `integrations/claude-code/skill/needs-you/` → `agents/skill/needs-you/`, plus `agents/AGENT-GUIDE.md` (moved from `docs/`), `agents/prompts/invite.md` (the invite prompt text the Mac app embeds, loaded from one file) | All agent-facing material in one place, versioned together |
| `deploy/` → `hub/deploy/`; `scripts/install-hub.sh` → `hub/install.sh`; `scripts/setup-sender.sh` → `cli/setup.sh` (keep thin wrappers at the old paths for a release) | Each component owns its install |
| `mac/` → `apple/mac/` and `apple/NeedsYouCore/` when iOS starts ([ios-widget.md](ios-widget.md)) | Shared Swift package |

Do these as one coordinated change with redirects (old paths as stubs or symlinks for one release) and a sweep of links in docs, the site and the skills.

## 2. Machine-readable API spec

- `protocol/openapi.yaml` (OpenAPI 3.1, whose schemas are JSON Schema 2020-12): every `/v1` endpoint, the item and error shapes, roles as security schemes, the replication endpoints in a separate tag.
- `protocol/schemas/item.json`, `item-input.json`, `error.json`: referenced by the OpenAPI file and usable on their own by agents validating a payload before posting.
- Generated docs stay prose: `docs/API.md` remains the readable explanation and links to the spec as normative for shapes.
- **Drift check:** a stdlib test loads the spec (JSON, or YAML via a tiny subset parser, or keep the spec as `openapi.json` to stay stdlib-only) and checks the hub's validation limits (lengths, enums, schemes, max links) match it.
- The `api-change` skill gains a step: update `protocol/` first.

## 3. Conformance suite

`protocol/conformance/` (Python stdlib `unittest`, black-box over HTTP): `NEEDS_YOU_CONFORMANCE_URL`, sender/reader tokens and, for replication, two or three hub URLs. Covers validation tables, upsert/dedupe, `content_updated_at`, resolve idempotency, `since` polling and the `more` cursor, roles, the volume guard, replication LWW and the same-key merge. Runs in CI against the Python hub and every other implementation (ADR 0004).

## 4. MCP server

Built. Shipped in 0.1.4, installed by the invite's `--mcp` flag since 0.1.5. Design: [ADR 0008](../adr/0008-mcp-server.md). How to use it: [MCP server guide](../guides/mcp.md). Still open: a status tool listing the caller's open items, which needs a sender-scoped read endpoint (an owner decision; "no for now").

## 5. `needs-you doctor`

Built. Shipped in 0.1.1; since 0.1.4 every `WARN` and `FAIL` prints one next step an agent can run or relay. Checks and `--json` shape: [Troubleshooting](../guides/troubleshooting.md#start-here-needs-you-doctor). Still to do: a diagnostics pane in the Mac app reusing these checks ([future.md](future.md)).

## 6. Routing

"Routed to where they need to act" has two halves:

1. **Which device or person sees it.** Today: everything goes to the hub owner; `context` picks work vs personal hours. Next: optional `to` (person or group) and per-reader filters (team mode, [future.md](future.md)); device rules ("urgent → phone too", "personal → never on the work Mac") as reader-side settings, so the hub stays simple.
2. **Where they act.** Built: AGENT-GUIDE rule 4 asks for the act-here link first, the Mac app treats the first openable link as the default click (menu bar, hotkey, the arrival preview's button), and the integrations add the deepest stable link they have (the PR's files, the run page). An iOS client would do the same.

Escalation (urgent and unseen → Discord/Slack) is in [future.md](future.md).

## 7. Self-setup for agents

Built: the invite flow is the agent's setup path. The `/join/<code>` page is Markdown written for an agent, the redeem response carries the token and the hub URLs in failover order, the installer takes one flag per agent, and the agent prompt ends with `needs-you doctor` and acting on each next step. Not built: a JSON form of the join page for clients that ask for one (`Accept: application/json`), and posting a test `info` item from the doctor step (the installer's test card covers it today).

## Phases

| Phase | What |
|---|---|
| 1 | `protocol/openapi.json` + schemas + drift test (`needs-you doctor` is done) |
| 2 | Conformance suite extracted from `tests/test_api.py` and `test_replication.py`; CI job |
| 3 | Repo moves (one coordinated PR) |
| 4 | ~~MCP server~~ (done); a JSON `/join` |
| 5 | Routing (`to`, reader-side device rules) |

## Open decisions

1. OpenAPI as JSON (stdlib-parseable) or YAML (nicer to edit)?
2. When to do the repo moves: right after the invite branches merge, before more integrations land.
