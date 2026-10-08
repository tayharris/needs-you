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
| `question.asked` | `notify opencode` | **opencode asks “<question>”**, the questions and their choices in the body and as the item's `question` |
| `session.status` idle, `session.idle` | `notify opencode` | **opencode finished: <session title> (<project>)**, or **opencode asks: <question>** when the last assistant text ends on one (once per idle; `NEEDS_YOU_AGENT_TURN_CARDS=0` turns these off) |
| `session.created`, `session.updated`, `message.updated`, `message.part.updated` | nothing | remembered: the session's title (not the "New session - ..." placeholder) and the end (4000 characters) of the latest assistant message's text, sent with the idle card as `session_title` and `last_assistant_message` |
| `permission.replied`, `question.replied`, `question.rejected`, `session.status` busy | `resolve opencode` | resolves the session's card |
| `session.deleted` | `end opencode` | resolves it |

- The plugin starts the hook only for sessions it posted a card for, so busy events cost nothing otherwise. It never awaits the hook, never throws, and has no permission hook, so it can't change a decision.
- The hook gets the session id, the project directory, the permission name and up to five patterns on stdin. The card keeps at most a program name or a file's basename; patterns, metadata and answers are never sent. For a question the plugin passes each question's text, header, options (label, description) and `multiple`, each cut to a fixed length; the hook cleans them, redacts anything token-shaped and clamps them (`NEEDS_YOU_AGENT_QUESTIONS=0` keeps them off the card).
- Answers from the card (ADR 0009 B2): for a question the card can show whole (1-4 questions, 1-8 options each, labels as written; never opencode's plan exit, `custom: false`) the card is posted `answerable`, and after the post the plugin runs the hook's `answer-wait` mode (`needs-you answer-wait`, up to `NEEDS_YOU_ANSWER_TIMEOUT` s). An answer it prints is checked against the options asked (same question id, offered labels only, one per single-choice question) and sent with `POST /question/{id}/reply` through the plugin's own SDK client (`client._client`, in-process when opencode runs without a port), else at `serverUrl`. `question.replied` or `question.rejected` stops the wait (the hook's process group is killed). Nothing is answered on a timeout, an error or by default. Verified against opencode 1.18.35's source; not yet run against a live opencode.
- **Key:** `agent:<host>:<session id>` (or the Orca terminal handle). **Source:** `--agent opencode`.
- Its `shell.env` hook sets `NEEDS_YOU_AGENT_SESSION=<session id>` for the agent's shell commands (nothing else), so a `needs-you add` the agent runs itself is noted for its session and the **opencode finished** card is skipped while that item is open (one card for one wait, see [the Claude Code hooks](../claude-code/README.md)).
- The hook is a child of the opencode process, so its lease points at opencode and the 5-minute `needs-you flush` clears the card of an opencode that died. A one-shot `opencode run` exits as soon as it goes idle; the hook sees opencode gone and posts no "waiting" card for it.

## Check and test

```bash
needs-you doctor      # an "opencode plugin" line
echo '{"hook_event_name":"Stop","session_id":"ses_test","cwd":"'"$PWD"'"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh notify opencode
echo '{"session_id":"ses_test"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.config/opencode/hooks/needs-you-hook.sh resolve opencode
```

`NEEDS_YOU_OPENCODE_HOOK` points the plugin at another hook path. `needs-you update` keeps the plugin and its hook copy current (restart opencode afterwards). Tests: `tests/test_opencode.py` (the plugin part runs under `node` when it's installed).
