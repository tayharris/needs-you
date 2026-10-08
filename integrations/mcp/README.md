# needs-you MCP server

`needs_you_mcp.py` is a stdio [MCP](https://modelcontextprotocol.io) server, so an agent that
speaks MCP can post to the needs-you inbox without a shell. One file, Python 3.9+ standard
library only. Status: [ADR 0008](../../docs/adr/0008-mcp-server.md) (Accepted). Setup guide:
[docs/guides/mcp.md](../../docs/guides/mcp.md).

## Tools

| Tool | Arguments | Runs |
|---|---|---|
| `needs_you_add` | `key`, `title` (required); `body`, `kind` (`needs`/`done`/`info`), `priority`, `context`, `links` (`[{label, url}]`, at most 6), `steps` (`[{text, link?, done?}]`, at most 10), `project`, `expires_in_hours` | `needs-you --json add` |
| `needs_you_resolve` | `key` | `needs-you --json resolve --key` |
| `needs_you_doctor` | none | `needs-you doctor --json` |

The tool descriptions and the server's `instructions` carry the rules from
[AGENT-GUIDE.md](../../docs/AGENT-GUIDE.md): when to post and when not, stable keys, the
title is the action, resolve what you posted, no secrets.

There is no "list my open items" tool: a sender token can't read the inbox, and adding a
sender-scoped read would change the wire contract (see the ADR). Keep track of the keys
you post.

## How it works

- Each tool call runs the `needs-you` CLI as a child process, so a post gets the CLI's
  config (`~/.config/needs-you/env`), hub failover, offline outbox and the "one card per wait"
  note, exactly as from a shell. The server itself never reads the token.
- The CLI is found by `$NEEDS_YOU_CLI`, then a `needs-you` next to the server, then
  `../../cli/needs-you` (a checkout), then `PATH`, then `~/.local/bin/needs-you`.
- Results are JSON text (and `structuredContent`): `{"ok", "queued", "state", "id", "key",
  "status"}` for an add, `{"ok", "queued", "key", "resolved"}` for a resolve, the doctor report
  for doctor. A queued post is a success with `"queued": true`. A hub refusal (bad input, bad
  token, the volume guard) is a result with `isError: true` and the CLI's message. Anything
  shaped like a needs-you token, invite code or bearer header is redacted from results.
- The `agent` on each item is `mcp:<client name>` from the client's `initialize`.
- A link label can't contain `=` (the CLI's `--link LABEL=URL`): it becomes `-`.
- Exits 0 when stdin closes, and on SIGTERM or Ctrl-C. It writes nothing but protocol
  messages to stdout and nothing to stderr.

Protocol: JSON-RPC 2.0, one message per line; `initialize` (protocol versions 2025-06-18,
2025-03-26 and 2024-11-05), `ping`, `tools/list`, `tools/call`. Notifications are accepted and
ignored; batches get `-32600`.

## Test

```bash
python3 -m unittest discover -s tests -p test_mcp.py
```

By hand, against the hub this machine is set up for:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"needs_you_doctor","arguments":{}}}' \
  | python3 integrations/mcp/needs_you_mcp.py
```
