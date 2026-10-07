# needs-you for opencode

When an opencode session asks for permission (a shell command, an edit, a web fetch, a folder outside the project, an MCP tool) or asks you a question, or goes idle waiting for your next message, a `needs` item appears on your Mac. It's resolved when you reply, the session gets busy again, or it's deleted.

opencode has no shell hooks; it has [plugins](https://opencode.ai/docs/plugins/). `needs-you.js` is a small plugin that listens to opencode's events and starts the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md) with an `opencode` argument. Opt-in, keys, links, leases and expiry work as described there. User guide: [docs/guides/opencode.md](../../docs/guides/opencode.md).

## Files

```
integrations/opencode/
├── needs-you.js                  the plugin (served by the hub as needs-you-opencode.js)
└── install-opencode-plugin.sh    copies it and the hook into the opencode config directory
```

## Install

```bash
integrations/opencode/install-opencode-plugin.sh                   # ~/.config/opencode ($XDG_CONFIG_HOME/opencode)
integrations/opencode/install-opencode-plugin.sh --config-dir DIR
integrations/opencode/install-opencode-plugin.sh --uninstall
```

It writes `plugins/needs-you.js` and `hooks/needs-you-hook.sh` there (opencode loads every `.js` in `plugins/` at startup) and edits no config file. Restart opencode. On a sender set up by an invite link: add `--opencode-plugin` to the one-liner.

## What gets posted

| opencode event | Hook mode | Action |
|---|---|---|
| `permission.asked` | `notify opencode` | **opencode wants to run git** (`bash`: the program from the first pattern), **opencode wants to edit main.ts** (`edit`), **opencode wants to fetch a page**, **opencode wants to use a folder outside the project**, else **opencode needs permission for <permission>** |
| `question.asked` | `notify opencode` | **opencode asked you a question** |
| `session.status` idle, `session.idle` | `notify opencode` | **opencode is waiting for you** (once per idle; `NEEDS_YOU_AGENT_TURN_CARDS=0` turns these off) |
| `permission.replied`, `question.replied`, `question.rejected`, `session.status` busy | `resolve opencode` | resolves the session's card |
| `session.deleted` | `end opencode` | resolves it |

- The plugin starts the hook only for sessions it posted a card for, so busy events cost nothing otherwise. It never awaits the hook, never throws, and has no permission hook, so it can't change a decision.
- The hook gets the session id, the project directory, the permission name and up to five patterns on stdin. The card keeps at most a program name or a file's basename; patterns, metadata, questions and answers are never sent.
- **Key:** `agent:<host>:<session id>` (or the Orca terminal handle). **Source:** `--agent opencode`.
- The hook is a child of the opencode process, so its lease points at opencode and the 5-minute `needs-you flush` clears the card of an opencode that died.

## Check and test

```bash
needs-you doctor      # an "opencode plugin" line
echo '{"hook_event_name":"Stop","session_id":"ses_test","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh notify opencode
echo '{"session_id":"ses_test"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh resolve opencode
```

`NEEDS_YOU_OPENCODE_HOOK` points the plugin at another hook path. `needs-you update` keeps the plugin and its hook copy current (restart opencode afterwards). Tests: `tests/test_opencode.py` (the plugin part runs under `node` when it's installed).
