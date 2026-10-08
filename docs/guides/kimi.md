# Kimi Code CLI

A card appears on your Mac when a Kimi Code CLI session needs you: it asks you to approve a command, an edit or a fetch, it asks you a question, or it finished its turn and is waiting for your next message. The card clears itself when you answer, the next tool runs, you send your next prompt, or you exit the session.

This is for **Kimi Code CLI**, the `kimi` command from `MoonshotAI/kimi-code` (`~/.kimi-code`), not the older Python `kimi-cli` (`~/.kimi`), which is no longer maintained.

Quickest: add `--kimi-hooks user --alerts` to an invite link's one-liner (or paste the link's agent prompt into Kimi; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --kimi-hooks user --alerts
```

Then check Kimi accepts its config with `kimi doctor`, and restart running Kimi sessions: Kimi reads its hooks when it starts. Reference: [integrations/kimi/README.md](../../integrations/kimi/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/kimi/install-kimi-hooks.sh    # ~/.kimi-code/config.toml (or $KIMI_CODE_HOME)
```

It adds one block of `[[hooks]]` entries to the end of `config.toml`, between two comment lines that mark it as needs-you's, and copies the hook to `~/.kimi-code/hooks/`. The rest of the file is kept byte for byte, and a backup (`config.toml.bak-<time>`) is written first. Running it again replaces only that block. `--uninstall` removes exactly that block and the hook copy, and so does `needs-you uninstall-hooks --kimi`, which needs no checkout and no hub.

The installer stops without changing anything if your `config.toml` already uses `hooks` as a table (`[hooks]`) or an inline list (`hooks = [...]`). Then copy the entries from `integrations/kimi/kimi-hooks.toml` into your list by hand.

## Opt in

The same switch as for the other agents:

```bash
NEEDS_YOU_AGENT_ALERTS=1 kimi                                # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Session state | Card |
|---|---|
| Approval for a shell command | **Kimi wants to run make: my-repo** |
| Approval for an edit | **Kimi wants to edit config.py: my-repo** |
| Approval to fetch a page | **Kimi wants to fetch a page: my-repo** |
| A plan to approve | **Approve Kimi's plan: my-repo** |
| A question for you | **Kimi asked you a question: my-repo** |
| Turn finished, waiting for you | **Kimi is waiting for you: my-repo** |
| The turn failed on an error | **Kimi stopped on an error: my-repo** |

One card per session, updated in place. Command lines, questions, prompts and tool output aren't sent: a card names at most the program or a file's name. `NEEDS_YOU_AGENT_TURN_CARDS=0` keeps only the approval, question and error cards. A one-shot `kimi -p` gets no "waiting" card, because Kimi has already exited.

## Check it works

```bash
needs-you doctor    # the "kimi hooks" line should be OK
kimi doctor         # Kimi refuses a config with any key it doesn't know
echo '{"hook_event_name":"PermissionRequest","session_id":"session_test-1","cwd":"'"$PWD"'","tool_name":"Bash","display":{"command":"make test"}}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.kimi-code/hooks/needs-you-hook.sh notify kimi
# "Kimi wants to run make" appears; then clear it:
echo '{"hook_event_name":"PermissionResult","session_id":"session_test-1"}' |
  NEEDS_YOU_AGENT_ALERTS=1 ~/.kimi-code/hooks/needs-you-hook.sh resolve kimi
```

The card arrives a moment after the first command returns: the hook hands its work to the background so Kimi never waits on it. (A "waiting for you" card from `Stop` takes two seconds more: the hook first checks that Kimi is still running.) No card from a real session? Restart Kimi after installing or updating, check that `NEEDS_YOU_AGENT_ALERTS=1` reaches it, and if you run Kimi with `KIMI_CODE_HOME` set, install with that same `KIMI_CODE_HOME`. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log` logs each hook call ([troubleshooting](troubleshooting.md#kimi-code-hooks)).
