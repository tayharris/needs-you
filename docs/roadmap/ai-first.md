# AI-first

Status: plan; item 5 (`needs-you doctor`) is done. The decision behind it is [ADR 0005](../adr/0005-ai-first.md).

**Product goal:** give AI agents the tools to set themselves up and to alert people when they actually need them, routed to where they need to act.

That means two audiences are first-class: agents that *use* needs-you (set up a machine, post, resolve, diagnose), and agents that *build* it (this repo). Both should find one obvious, machine-readable path.

## Where we are

| Surface | State |
|---|---|
| Sender contract | `docs/AGENT-GUIDE.md` (human prose; good rules) |
| Claude skill | `integrations/claude-code/skill/needs-you/SKILL.md` |
| Hooks | `integrations/claude-code/` ("agent is waiting" cards) |
| Self-setup | Invite links: an agent prompt or `curl` one-liner from the Mac app, a `/join/<code>` page (in progress on other branches) |
| Contributor entry | `CLAUDE.md`, `AGENTS.md`, `.claude/skills/` |
| Machine-readable API | None. `docs/API.md` is prose |
| Diagnosis | `needs-you health` (reachability + token role); `needs-you doctor [--json]` (the whole setup, item 5) |

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

**Built, design Proposed** ([ADR 0008](../adr/0008-mcp-server.md), `integrations/mcp/needs_you_mcp.py`, [guide](../guides/mcp.md)). As built: `needs_you_add` (with `kind` instead of a separate done tool), `needs_you_resolve` and `needs_you_doctor`; it runs the CLI as a subprocess rather than importing it (the CLI writes to stdout, the protocol channel). No status/list tool: it needs a sender-scoped read endpoint, an owner decision. Not yet served from `/dl` or set up by the installer. The original plan:

A `needs-you` MCP server so agents call tools instead of shelling out:

| Tool | Maps to |
|---|---|
| `needs_you_add(key, title, body?, priority?, context?, links?)` | `POST /v1/items` |
| `needs_you_done(key, title, ...)` | `POST /v1/items` kind `done` |
| `needs_you_resolve(key)` | `POST /v1/items/resolve` |
| `needs_you_status()` | health + the caller's open items (needs a sender-scoped list endpoint, or the CLI's local record of what it posted) |

- Implementation: a stdlib Python stdio MCP server (`integrations/mcp/needs_you_mcp.py`) that reuses the CLI's config, outbox and failover by importing it, so there's one sending path. No SDK dependency (the stdio JSON-RPC surface needed is small).
- The tool descriptions carry the AGENT-GUIDE rules (when to post, stable keys, no secrets), since that's what the model reads.
- Install: `claude mcp add needs-you -- python3 ~/.local/bin/needs-you-mcp`; the invite prompt can offer it.
- Open: also expose an MCP *resource* with the AGENT-GUIDE text?

## 5. `needs-you doctor`

**Done** (`cli/needs-you`, `tests/test_doctor.py`). As built: checks are `config`, `path`,
`hub N` per URL plus a `hubs` summary (and `hub order` on a Mac whose `127.0.0.1` URL isn't
first), `outbox`, `claude hooks`, `claude skill`, `orca` (only when Orca is present) and
`flush schedule`. Each has a `status` of `OK`, `WARN`, `FAIL` or `INFO` and a `hint`. `--json`
prints `{"ok", "version", "checks": [{"check", "status", "detail", "hint"}]}`; the exit code is
1 on any `FAIL`. It is read-only (it runs before the usual outbox flush) and never posts.
Tailscale isn't checked: hub reachability covers it. Still to do: the Mac diagnostics pane and
the `/join` verify step reusing these checks.

The original sketch:

```
$ needs-you doctor --json
{"ok": false, "checks": [
  {"id": "config", "ok": true, "detail": "~/.config/needs-you/env (mode 600)"},
  {"id": "hubs", "ok": true, "detail": "2 configured, 1 reachable"},
  {"id": "token", "ok": true, "detail": "role sender on hub-a"},
  {"id": "outbox", "ok": false, "detail": "3 queued, oldest 2h", "fix": "needs-you flush"},
  {"id": "path", "ok": false, "detail": "~/.local/bin not on PATH", "fix": "export PATH=..."},
  {"id": "tailscale", "ok": true, "detail": "running"},
  {"id": "hooks", "ok": true, "detail": "installed in ~/.claude/settings.json, opted in"}]}
```

- Every failing check has a `fix` string an agent can run or relay. Never prints the token.
- Exit codes: 0 all ok, 1 a check failed.
- Same checks back the Mac app's diagnostics pane ([future.md](future.md)) and the `/join` page's "verify" step.

## 6. Routing

"Routed to where they need to act" has two halves:

1. **Which device or person sees it.** Today: everything goes to the hub owner; `context` picks work vs personal hours. Next: optional `to` (person or group) and per-reader filters (team mode, [future.md](future.md)); device rules ("urgent → phone too", "personal → never on the work Mac") as reader-side settings, so the hub stays simple.
2. **Where they act.** The item's links already open the right app. Make it better: AGENT-GUIDE asks for one primary `https` link first (works on phone and desktop); the Mac and iOS clients treat link 0 as the default click; integrations add the deepest stable link they have (the PR review page, not the repo).

Escalation (urgent and unseen → Discord/Slack) is in [future.md](future.md).

## 7. Self-setup for agents

The invite flow is the agent's setup path. Make it fully scriptable:

- The `/join/<code>` page serves both HTML (for a person) and `text/markdown` or JSON when the client asks (`Accept` header), so an agent fetching it gets exact steps.
- The redeem response includes the hub URLs in failover order, the token, and a suggested key prefix and context, so `setup-sender.sh --non-interactive` can be fed from it directly.
- After setup the agent runs `needs-you doctor` and posts a test `info` item.

## Phases

| Phase | What |
|---|---|
| 1 | `protocol/openapi.json` + schemas + drift test; `needs-you doctor` (done) |
| 2 | Conformance suite extracted from `tests/test_api.py` and `test_replication.py`; CI job |
| 3 | Repo moves (one coordinated PR) |
| 4 | MCP server; machine-readable `/join` |
| 5 | Routing (`to`, reader-side device rules) |

## Open decisions

1. OpenAPI as JSON (stdlib-parseable) or YAML (nicer to edit)?
2. MCP server inside the CLI file (`needs-you mcp`) or a separate file?
3. When to do the repo moves: right after the invite branches merge, before more integrations land.
