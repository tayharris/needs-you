# needs-you for Aider

When Aider has replied and waits for you (your next message, or a yes/no question), a `needs` item appears on your Mac. The next wait updates it. It's resolved when Aider exits, or expires after an hour.

**Fidelity: waiting only, no "answered" event.** Aider's notifications command says only that it waits: not what for, and nothing when you reply. So the card stays while you type, until Aider exits (the lease: the 5-minute `needs-you flush` resolves it) or `NEEDS_YOU_AIDER_EXPIRY_HOURS` (default 1) passes.

It uses Aider's `--notifications-command` and the same `needs-you-hook.sh` as the [Claude Code integration](../claude-code/README.md), started with an `aider` argument. Opt-in, keys, links, leases and expiry work as described there.

The machine must be a sender first: an invite link (add `--aider --alerts` to its one-liner) or [`scripts/setup-sender.sh`](../../scripts/setup-sender.sh). User guide: [docs/guides/aider.md](../../docs/guides/aider.md).

## Files

```
integrations/aider/
└── install-aider-notifications.sh    writes the ~/.aider.conf.yml block and copies the hook
```

## Install

```bash
integrations/aider/install-aider-notifications.sh                # ~/.aider.conf.yml
integrations/aider/install-aider-notifications.sh --conf FILE
integrations/aider/install-aider-notifications.sh --dry-run
integrations/aider/install-aider-notifications.sh --uninstall
```

It copies the hook to `~/.config/needs-you/aider/hooks/` and appends a marked block:

```yaml
# needs-you (managed by install-aider-notifications.sh; do not edit between these markers)
notifications: true
notifications-command: '"$HOME/.config/needs-you/aider/hooks/needs-you-hook.sh" notify aider'
# end needs-you
```

Both keys are needed: without `notifications: true` Aider never runs the command. The file is changed only when that's safe: not a symlink, a plain YAML mapping (no flow style, no list, no second document), and neither key already set outside the block (PyYAML, which Aider uses, would let the later one win silently). Otherwise nothing is written to it, the two lines are printed, and the installer exits 4 (the invite installer then lists "Aider notifications" under "Not set up"). Re-running replaces the block. `needs-you update` keeps the hook copy current; `needs-you uninstall-hooks --aider` removes the block and the copy offline.

Aider also reads `.aider.conf.yml` from the git root and the current directory, and `AIDER_NOTIFICATIONS` / `AIDER_NOTIFICATIONS_COMMAND` from the environment; those override this file.

## What gets posted

| When | Hook mode | Action |
|---|---|---|
| Aider shows its next prompt or a yes/no question after an LLM reply | `notify aider` | `needs-you add`: **Aider finished** (Aider doesn't say whether it asked a yes/no question; the body says it may have; `NEEDS_YOU_TURN_TEXT=0`: **Aider is waiting for you**), `--expires-in` 1 hour |
| Aider exits | (`needs-you flush`) | resolves it: the lease's process is gone |

- **Key:** `agent:<short-hostname>:aider-<pid>`, the pid of the Aider process (the first ancestor of the hook that isn't a shell; Aider runs the command through `sh -c`).
- **Never sent:** anything from the chat. There is no payload.
- **Source:** `--agent aider`.
- Aider runs the command with `subprocess.run(..., shell=True, capture_output=True)`: **its stdin is the terminal** and Aider waits for it to exit. A command that reads stdin swallows what you type (seen live), so in `aider` mode the hook never reads it. It finds the Aider pid before its `sh -c` parent exits, hands the work to a background copy with no stdio, and exits 0 at once.

## Settings

The [Claude Code hook settings](../claude-code/README.md#settings) apply, plus:

| Variable | Default | Meaning |
|---|---|---|
| `NEEDS_YOU_AIDER_EXPIRY_HOURS` | `1` | How long the card lasts without a new wait |
| `NEEDS_YOU_AGENT_TURN_CARDS` | on | `0`: no Aider card at all |

## Check and test

```bash
needs-you doctor      # an "aider notifications" line
```

Tests: `tests/test_aider.py`. Checked live with Aider 0.86.2 in a scratch venv against a loopback model stub: two prompts, two cards (one item, updated), both prompts reached Aider, and `needs-you flush` resolved the card after `/exit`.
