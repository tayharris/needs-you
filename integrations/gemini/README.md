# needs-you for Gemini CLI

When a Gemini CLI session asks you to approve a tool call (a shell command, an edit, an MCP tool, a web fetch) or finishes its turn and waits for your next message, a `needs` item appears on your Mac. It's resolved when you send the next prompt, a tool runs, or the session ends.

It uses Gemini CLI's [hooks](https://geminicli.com/docs/hooks/) in `~/.gemini/settings.json` and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with a `gemini` argument. Opt-in, keys, links, leases and expiry work as described there.

The machine must be a sender first: an invite link (add `--gemini-hooks user --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/gemini.md](../../docs/guides/gemini.md).

## Files

```
integrations/gemini/
├── gemini-hooks.json          the hook entries (user-level paths), for reference or hand-merging
└── install-gemini-hooks.sh    merges them into ~/.gemini/settings.json and copies the hook
```

## Install

```bash
integrations/gemini/install-gemini-hooks.sh                  # ~/.gemini/settings.json
integrations/gemini/install-gemini-hooks.sh --gemini-dir DIR
integrations/gemini/install-gemini-hooks.sh --dry-run
integrations/gemini/install-gemini-hooks.sh --uninstall
```

The installer backs up `settings.json`, replaces only entries whose command contains `needs-you-hook.sh`, appends them after your own hooks, and leaves every other setting alone. It never writes through a symlinked `settings.json` (merge by hand into the file it points to). Gemini allows comments in `settings.json`; this installer doesn't parse those and stops without changing anything: merge `gemini-hooks.json` by hand (replace `$HOME/.gemini` if you use another directory). Gemini runs hooks, user-level ones included, only in folders you have trusted (folder trust is on by default; `security.folderTrust.enabled: false` turns it off), and `needs-you doctor` reminds you. `hooksConfig.enabled: false` turns all hooks off; the installer and `needs-you doctor` say so. `/hooks` in Gemini CLI lists them.

## What gets posted

| Gemini event | Hook mode | Action |
|---|---|---|
| `Notification`, matcher `ToolPermission` | `notify gemini` | `needs-you add`: **Gemini wants to run npm** (`details.rootCommand`), **Gemini wants to edit app.py** (`details.fileName`), **Gemini needs permission for github create_pr** (MCP), **Gemini wants to fetch a page**, else **Gemini needs your approval** |
| `AfterAgent` | `notify gemini` | `needs-you add`: **Gemini is waiting for you** (the turn ended). `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only approval cards |
| `BeforeAgent`, `AfterTool` | `resolve gemini` | `needs-you resolve`, only if this session posted something |
| `SessionStart` (`clear`, `resume`) | `start gemini` | resolves the cards this Gemini process posted before |
| `SessionEnd` | `end gemini` | resolves the session's card |

- Denying an approval (Esc, "No, suggest changes") fires no hook in Gemini CLI 0.63, so that card stays until the next prompt or the session ends.
- **Key:** `agent:<short-hostname>:<id>`, `<id>` being `$ORCA_TERMINAL_HANDLE` or Gemini's `session_id`.
- **Never sent:** the command line, diffs, file contents, URLs, the notification `message`, the prompt or Gemini's reply. A card names at most the program or a file's basename.
- **Source:** `--agent gemini-cli --project <basename of the project dir>`.
- Gemini waits for every hook and reads its stdout (or, if empty, stderr) as JSON. So in `gemini` mode the hook reads its input, starts a background copy with no stdin, stdout or stderr, and exits 0 at once with no output. The copy keeps the lease on the Gemini process, so the 5-minute `needs-you flush` can clear the card of a session that died.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply, plus `NEEDS_YOU_AGENT_TURN_CARDS` (`0`: no card when a turn ends).

## Check and test

```bash
needs-you doctor      # a "gemini hooks" line
echo '{"hook_event_name":"Notification","notification_type":"ToolPermission","session_id":"test-1","cwd":"'"$PWD"'","details":{"type":"exec","rootCommand":"ls"}}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh notify gemini
echo '{"session_id":"test-1"}' | NEEDS_YOU_AGENT_ALERTS=1 ~/.gemini/hooks/needs-you-hook.sh resolve gemini
```

`NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs to a file (stderr goes nowhere in this mode). `needs-you update` keeps `~/.gemini/hooks/needs-you-hook.sh` and the entries current. Tests: `tests/test_gemini.py`.
