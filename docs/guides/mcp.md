# MCP server

For agents that speak MCP but have no shell, or whose shell you'd rather not hand over: chat apps, IDE assistants, sandboxed agents. The needs-you MCP server gives them three tools: `needs_you_add` posts a card (or updates the one with the same key), `needs_you_resolve` closes it, and `needs_you_doctor` checks the setup. Agents with a shell don't need it; the `needs-you` CLI and the [Claude Code skill](claude-code.md) do the same.

The server is one Python file (standard library only) that runs the `needs-you` CLI for each call, so posts get the same failover, offline queue and rules. Its tool descriptions tell the model when to post and when not to ([the agent guide](../AGENT-GUIDE.md)). Reference: [integrations/mcp/README.md](../../integrations/mcp/README.md). It's new and its design is still [proposed](../adr/0008-mcp-server.md), so the installer doesn't set it up yet.

## Install

Prerequisite: the machine is a sender, so `needs-you` works in a shell there (an invite link's one-liner, see [Add a sender](add-a-sender.md)). The agent's MCP client runs on that machine.

Copy the server next to the CLI, from a checkout of this repo or the release's server tarball:

```bash
install -m 755 integrations/mcp/needs_you_mcp.py ~/.local/bin/needs-you-mcp
```

Then register it with the client.

**Claude Code**, for every project:

```bash
claude mcp add --scope user needs-you -- python3 "$HOME/.local/bin/needs-you-mcp"
```

**Clients with a JSON config** (an `mcpServers` block): use the absolute path, since these don't expand `~`.

```json
{
  "mcpServers": {
    "needs-you": {
      "command": "/usr/bin/python3",
      "args": ["/Users/you/.local/bin/needs-you-mcp"]
    }
  }
}
```

If the CLI isn't next to the server, on `PATH` or in `~/.local/bin`, add `"env": {"NEEDS_YOU_CLI": "/path/to/needs-you"}`. The server reads no token itself: the CLI reads `~/.config/needs-you/env`, so the client needs read access to it and network access to the hub (the tailnet, or `127.0.0.1` on the Mac that runs it). A sandboxed client may need both allowed.

## Check it works

Ask the agent: *"Run the needs_you_doctor tool and tell me what it says."* It returns the same report as `needs-you doctor --json`; every `WARN` or `FAIL` check has one next step. Don't post a test card: doctor is the test.

By hand, without a client:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"needs_you_doctor","arguments":{}}}' \
  | python3 ~/.local/bin/needs-you-mcp
```

## What the agent sees

- `needs_you_add`: `key` and `title` are required; `body`, `kind` (`needs`, `done` or `info`), `priority`, `context`, `links`, `steps`, `project` and `expires_in_hours` are optional. Each item's agent is `mcp:<client name>`.
- If no hub answers, the result says the item was queued (`"queued": true`): the CLI sends it later, and the agent shouldn't retry. A refusal (a bad link, a title over 100 characters) comes back as a tool error with the hub's message.
- There's no tool to list the agent's open cards. A sender can post and resolve but can't read your inbox, and that stays so; the agent keeps track of the keys it posted.
- Nothing token-shaped ever appears in a result.

**One card per wait:** when the client starts the server with the Claude Code session's environment (`CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`) or inside an Orca terminal, the hooks skip their generic "Claude is waiting" card while the agent's own card is open, as they do for the CLI. Other clients don't pass a session, so if their agent also has needs-you hooks you may see both cards.

## Remove it

```bash
claude mcp remove --scope user needs-you     # or delete the block from the client's config
rm ~/.local/bin/needs-you-mcp
```
