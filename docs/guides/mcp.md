# MCP server

For agents that speak MCP but have no shell, or whose shell you'd rather not hand over: chat apps, IDE assistants, sandboxed agents. The needs-you MCP server gives them three tools: `needs_you_add` posts a card (or updates the one with the same key), `needs_you_resolve` closes it, and `needs_you_doctor` checks the setup. Agents with a shell don't need it; the `needs-you` CLI and the [Claude Code skill](claude-code.md) do the same.

The server is one Python file (standard library only) that runs the `needs-you` CLI for each call, so posts get the same failover, offline queue and rules. Its tool descriptions tell the model when to post and when not to ([the agent guide](../AGENT-GUIDE.md)). Reference: [integrations/mcp/README.md](../../integrations/mcp/README.md). Design: [ADR 0008](../adr/0008-mcp-server.md). The invite installer sets it up with `--mcp`.

## Install

Prerequisite: the agent's MCP client runs on a machine you set up (or are setting up) with an invite link: [Add a sender](add-a-sender.md). Add `--mcp` and the agents to register it with to the invite's one line:

```bash
curl -fsSL <invite link>/install.sh | bash -s -- --yes --mcp claude,codex
```

`--mcp` takes a comma-separated list of `claude`, `codex`, `gemini`, `opencode` and `copilot`. The installer downloads the server from the hub (checked against the sha256 on the invite page), installs it as `~/.local/bin/needs-you-mcp` next to the CLI, and registers it under the name `needs-you` in each agent's user-level config:

| Agent | Where | Entry |
|---|---|---|
| Claude Code | `~/.claude.json`, through `claude mcp add-json --scope user` | `{"type": "stdio", "command": "<python3>", "args": ["<server>"]}` |
| OpenAI Codex CLI | `~/.codex/config.toml` (or `$CODEX_HOME`), a marked block | `[mcp_servers.needs-you]` with `command` and `args` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers.needs-you`: `command`, `args` |
| opencode | `~/.config/opencode/opencode.json` | `mcp.needs-you`: `{"type": "local", "command": ["<python3>", "<server>"], "enabled": true}` |
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` (or `$COPILOT_HOME`) | `mcpServers.needs-you`: `type` `local`, `command`, `args`, `tools: ["*"]` |

As with the hooks: a config file is backed up (`<file>.bak-<time>`) before it changes, nothing changes when the entry is already right, a symlinked config or one that isn't valid JSON is left alone with a warning (that agent is listed under "Not set up:" and the rest still installs), and a `needs-you` server that isn't this one is never replaced. Claude Code is registered only through its own `claude` command; without it on PATH, the installer prints the command to run. opencode's `opencode.jsonc` isn't edited: the installer prints the entry to add.

Restart open agent sessions to load the server. `needs-you update` keeps `needs-you-mcp` current (the registrations point at that path, so they don't change), and `needs-you doctor` has an `mcp server` line.

By hand, for another client or a machine without the installer: put `integrations/mcp/needs_you_mcp.py` (from a checkout or the release's server tarball) next to the CLI and register it with the client.

```bash
install -m 755 integrations/mcp/needs_you_mcp.py ~/.local/bin/needs-you-mcp
needs-you install-mcp claude,gemini          # the same registration the installer does
```

**Clients with a JSON config** (an `mcpServers` block): use absolute paths, since these don't expand `~`.

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
needs-you uninstall-hooks --mcp      # every registration needs-you added, and ~/.local/bin/needs-you-mcp
```

It removes only entries that run `needs-you-mcp`, restores each config file as it was otherwise (with a backup) and deletes a config file the installer created that is empty again. Claude Code's entry goes through `claude mcp remove needs-you --scope user`. A plain `needs-you uninstall-hooks`, or the installer's `--uninstall`, includes it.
