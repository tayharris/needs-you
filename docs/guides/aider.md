# Aider

A card appears on your Mac when Aider has replied and is waiting for you: for your next message, or for a yes/no answer such as "Run shell command?". The next wait updates the same card.

**Waiting only, and it can't tell when you answered.** Aider's one hook, its notifications command, says only "I'm waiting": not what for, and nothing when you reply. So the card stays while you type. It goes when Aider exits (the 5-minute `needs-you flush` notices) or after an hour (`NEEDS_YOU_AIDER_EXPIRY_HOURS`).

Quickest: add `--aider --alerts` to an invite link's one-liner (or paste the link's agent prompt into an agent on that machine; it names the flag):

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --aider --alerts
```

Then restart Aider. Reference: [integrations/aider/README.md](../../integrations/aider/README.md).

## Manual install

On a sender machine, from a checkout of this repo:

```bash
integrations/aider/install-aider-notifications.sh    # ~/.aider.conf.yml
```

It copies the hook to `~/.config/needs-you/aider/hooks/` and adds this block to `~/.aider.conf.yml` (backing the file up first):

```yaml
# needs-you (managed by install-aider-notifications.sh; do not edit between these markers)
notifications: true
notifications-command: '"$HOME/.config/needs-you/aider/hooks/needs-you-hook.sh" notify aider'
# end needs-you
```

It only edits the file when that's safe: not a symlink, a plain YAML mapping, and neither key set already. Otherwise it changes nothing there, prints the two lines for you to add (or pass as `--notifications --notifications-command '...'`), and exits 4; the invite installer lists it under "Not set up". `--uninstall` removes the block, and so does `needs-you uninstall-hooks --aider`.

A `.aider.conf.yml` in a repo or the current directory, and `AIDER_NOTIFICATIONS`/`AIDER_NOTIFICATIONS_COMMAND` in the environment, override the one in your home directory.

## Opt in

```bash
NEEDS_YOU_AGENT_ALERTS=1 aider                               # one session
echo 'NEEDS_YOU_AGENT_ALERTS=1' >> ~/.config/needs-you/env   # every session on this machine
```

## What you'll see

| Aider state | Card |
|---|---|
| Replied, waiting for your message or a yes/no answer | **Aider is waiting for you: my-repo** |

One card per Aider process. Nothing from the chat is sent. `NEEDS_YOU_AIDER_EXPIRY_HOURS` (default 1) sets how long it lasts without a new wait; `NEEDS_YOU_AGENT_TURN_CARDS=0` turns it off.

Aider runs the command with your terminal as its input and waits for it, so the hook never reads its input and returns at once.

## Check it works

```bash
needs-you doctor    # the "aider notifications" line should be OK
```

Then start Aider in a repo, send a message, and the card arrives once the reply is done. Quit Aider and run `needs-you flush`: it says `resolved 1 from ended sessions`. `NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log aider` logs each hook call ([troubleshooting](troubleshooting.md#cursor-cline-and-aider)).

Tested live with Aider 0.86.2 against a local model stub.
