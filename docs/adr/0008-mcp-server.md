# 0008. A one-file stdlib MCP server that wraps the CLI

- Status: Accepted (2026-10-08)
- Date: 2026-10-07

## Context

Agents post with the `needs-you` CLI, which needs a shell. Some agents that a person wants to
hear from have MCP but no shell, or a shell the person would rather not hand over: chat
clients, IDE assistants, sandboxed or tool-restricted agents. For them, "post when you're
blocked on me" has to be a tool call. [roadmap/ai-first.md §4](../roadmap/ai-first.md#4-mcp-server)
planned an MCP server; [0005](0005-ai-first.md) lists it as agent-facing surface.

Constraints that shape it:

- Python standard library only, 3.9-compatible, no SDK ([0002](0002-python-stdlib-only.md)).
  The MCP surface a tools-only server needs (JSON-RPC 2.0 over stdio: `initialize`, `ping`,
  `tools/list`, `tools/call`) is small.
- One sending path. The CLI already has the config file, hub failover, the offline outbox
  and its ordering, the client-version header, update requests and the "one card per wait"
  session notes. A second implementation would drift.
- Tokens are never printed ([CLAUDE.md](../../CLAUDE.md) hard rule 3), and senders never fail
  the caller's job (rule 8).
- A sender token can post and resolve but can't read the inbox: `GET /v1/items` is
  reader-only ([API.md](../API.md#conventions)). That is deliberate: a machine that sends
  alerts can't see the person's other alerts.

## Decision

Add `integrations/mcp/needs_you_mcp.py`: one executable stdlib Python file, a stdio MCP
server with three tools.

| Tool | Runs |
|---|---|
| `needs_you_add` | `needs-you --json add` (kind `needs`, `done` or `info`; links, steps, expiry) |
| `needs_you_resolve` | `needs-you --json resolve --key` |
| `needs_you_doctor` | `needs-you doctor --json` (read-only) |

1. **It wraps the CLI as a subprocess**, one run per tool call, instead of importing it. The
   CLI writes to stdout (which is the protocol channel here), calls `sys.exit`, keeps module
   globals and may start a background update; a child process keeps all of that out of the
   server and keeps exactly one sending path. The CLI is found by `NEEDS_YOU_CLI`, then next
   to the server, then on `PATH`, then `~/.local/bin/needs-you`.
2. **The tool descriptions carry the sender contract** (when to post and when not, stable
   keys, the title is the action, links, resolve what you posted, no secrets), since that is
   what the model reads. They are kept in step with [AGENT-GUIDE.md](../AGENT-GUIDE.md).
3. **No "list mine".** Listing the caller's open items needs a sender-scoped read endpoint,
   which doesn't exist. Adding one changes the wire contract and the "senders can't read"
   rule above, so it's left out here; it needs its own decision (and the `api-change`
   checklist). The agent keeps track of the keys it posted, as CLI users do.
4. **Tokens never reach the protocol.** The server never reads the token: the CLI reads the
   env file as it always does. Tool results carry the CLI's output with anything shaped like a
   needs-you token or invite code (`ny_…`, `nyi_…`) or a bearer header redacted, as a backstop.
5. **Failures are tool results, not crashes.** A queued post is a success that says so; a hub
   refusal (CLI exit 2) is `isError` with the CLI's message; a missing CLI says how to set
   the machine up. Malformed JSON-RPC gets the standard error codes. The server exits 0 when
   stdin closes, and on SIGTERM or SIGINT.
6. **Installed by hand for now:** `claude mcp add needs-you -- python3 <path>/needs_you_mcp.py`
   or the client's MCP config. Serving it from `/dl` and an installer flag is a separate
   change (it touches the `/dl` allow-list in API.md and the invite installer).
   *Done (2026-10-08):* the hub serves `/dl/needs_you_mcp.py`, and the installer's
   `--mcp <agents>` installs it as `~/.local/bin/needs-you-mcp` and registers it with Claude
   Code, Codex, Gemini CLI, opencode and Copilot CLI ([guides/mcp.md](../guides/mcp.md)).

## Consequences

- MCP clients can post, resolve and check the setup without a shell, with the same
  failover, outbox and rules as the CLI.
- Every tool call starts a Python process (tens of milliseconds); posts are rare, so this is
  fine.
- The server depends on the CLI's flags and its `--json` output; `tests/test_mcp.py` runs the
  real CLI against a test hub, so a CLI change that breaks it fails there.
- "One card per wait" works only when the client starts the server with the session's
  environment (`CLAUDECODE` and `CLAUDE_CODE_SESSION_ID`, or `ORCA_TERMINAL_HANDLE`); without
  it, the hooks' generic waiting card may show next to the agent's own.
- Open: a sender-scoped `GET` for the caller's own open items (point 3); exposing
  AGENT-GUIDE.md as an MCP resource.
