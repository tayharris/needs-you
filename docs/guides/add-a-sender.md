# Add a sender (a machine, a project, a CI repo)

A sender is anything that posts items: an agent, an Orca automation, a VM's cron jobs, a CI workflow. Each one gets its own token so you can revoke it alone.

## With an invite link (recommended)

1. **Make a link.** In the Mac app: right-click the pill → **Settings…** → **Invite a machine**, set **Uses** to the number of machines, **Create invite**. On a server hub: `needs-you-admin invite create my-server --role sender --uses 3 --ttl 72`. You get:
   - a join URL, e.g. `http://my-mac.example.ts.net:8765/join/nyi_...`,
   - a one-liner: `curl -fsSL <join_url>/install.sh | bash -s -- --yes`,
   - an agent prompt: *"Set up needs-you alerts on this machine: read &lt;join_url&gt; and follow it."*
2. **Use it on the machine.** Paste the prompt into the machine's agent (Claude Code, Orca), or run the one-liner yourself. The machine must reach the hub: on the Mac itself `127.0.0.1` always works (pass `--hub http://127.0.0.1:8765` if the link's MagicDNS name doesn't resolve) and the installer puts it first; elsewhere it must be on the tailnet.
3. **Check** the card that the installer posts (`setup:<host>:test`, under **Recent**).

The join URL is safe to open in a browser first: it's Markdown that explains what will happen. Opening it doesn't spend a use.

### What the installer does

| Step | Detail |
|---|---|
| Installs the CLI | Downloads `needs-you` from the hub (`/dl/needs-you`), checks it compiles, puts it in `~/.local/bin`. Prints the `PATH` line to add if needed; never edits your dotfiles. |
| Redeems the invite | Mints a token for this machine, named `<invite name>-<host>`. One link with `uses: 5` sets up five machines, each with its own token. |
| Writes the config | `~/.config/needs-you/env`, mode 600: `NEEDS_YOU_URLS` (the hub plus its peers, in failover order), `NEEDS_YOU_URL`, `NEEDS_YOU_TOKEN`, and `NEEDS_YOU_DEFAULT_CONTEXT` with `--context`. Other lines in the file are kept. |
| Schedules a flush | Every 5 minutes, `needs-you flush` sends anything queued while no hub answered (e.g. the Mac was asleep): a crontab line on Linux, the LaunchAgent `io.needs-you.flush` on macOS. |
| Checks and tests | `needs-you health`, then a test `info` item. An unreachable hub is only a warning: the item queues. |

### Options

Add them after `--yes`: `curl -fsSL <join_url>/install.sh | bash -s -- --yes --skill --context personal`.

| Option | Meaning |
|---|---|
| `--yes` | Don't ask. Needed when piped (there's no terminal to confirm on). |
| `--claude-hooks user\|project\|none` | Install the Claude Code hooks for every repo (`user`), or the current directory's repo (`project`). Default `none`. See [claude-code.md](claude-code.md). |
| `--alerts` | Turn the Claude Code hooks on for every session here (`NEEDS_YOU_AGENT_ALERTS=1` in the env file). |
| `--skill` | Install the needs-you skill to `~/.claude/skills/needs-you/`. |
| `--context-alert PCT` | Card suggesting `/compact` or `/clear` once a Claude session's context is PCT% full. Default 80; `0` off. |
| `--ssh-alias NAME` | This machine's name in the Mac's `~/.ssh/config`: agent cards get a VS Code Remote-SSH button. |
| `--agent-link 'LABEL=URL'` | One link template for agent cards instead of the automatic editor links; `none` turns them off. See [claude-code-everywhere.md](claude-code-everywhere.md#buttons). |
| `--orca-environment NAME` | On a paired Orca server: its name in the Mac's Orca. |
| `--orca` | Write the Orca automation snippet to `~/.config/needs-you/orca-snippet.md` and print it. See [orca.md](orca.md). |
| `--context work\|personal` | Default context for this machine's items. |
| `--host NAME` | This machine's name (default: short hostname). |
| `--hub URL` | Use a different URL for the same hub (e.g. its IP while DNS is broken). It is used for the install and saved first in `NEEDS_YOU_URLS`, ahead of the hub's advertised URLs. |
| `--no-schedule` | Don't add the 5-minute flush. |
| `--no-path` | Don't add `~/.local/bin` to `PATH` in your shell profile; print the line instead. |
| `--force` | Redeem again and replace an existing token (needs a link with a use left). |
| `--uninstall` | Remove the CLI, the config, the flush schedule, the skill, local state (outbox, hook markers) and (if installed) the user-level hooks. Works until the link expires or is revoked. |

Re-running with an already-configured machine updates the CLI and the schedule and keeps the token and every setting you don't pass again (the PATH line is added once). It doesn't spend a use, and it works until the link expires or is revoked, also after its last use is spent. A new machine (or `--force`) needs a use left; the installer stops with exit 1 before installing anything if there's none. Give provisioning scripts a link with a long enough expiry (up to 90 days).

Notes:

- An expired, revoked or unknown link fails with exit 1 and `needs-you install: This invite link is unknown, expired or revoked.` on stderr.
- After the link expires, remove things by hand (below).
- Update the CLI, hook, skill and Orca snippet later with `needs-you update` (or add `--auto-update` to the one-liner for a daily update). See [Keeping up to date](updates.md).

## Manually (no invite link)

Mint a token on a server hub (`needs-you-admin token add <name> --role sender`), then on the machine, from a checkout of this repo:

```bash
./scripts/setup-sender.sh
```

It installs the CLI, asks for the hub URLs and the token (hidden input), writes `~/.config/needs-you/env`, checks health, schedules the 5-minute `needs-you flush` (crontab on Linux, a LaunchAgent on macOS, like the installer), puts `~/.local/bin` on `PATH` in your shell profile, and offers a test item. Re-running it is safe. Unattended:

```bash
printf '%s' "$TOKEN" | ./scripts/setup-sender.sh --non-interactive \
  --url "http://hub-a.example.ts.net:8765,http://hub-b.example.ts.net:8765" \
  --token-stdin --install-cli --test
```

| Flag | Meaning |
|---|---|
| `--non-interactive` | Never prompt. Reuses the saved URL/token when flags are omitted. |
| `--token-stdin` | Read the token from stdin (keeps it out of `ps` and history). `--token X` and `NEEDS_YOU_TOKEN` also work. |
| `--install-cli [SRC]` | Install the CLI from this repo, a local path, or a URL (a hub's `/dl/needs-you` works). `--no-install-cli` skips it. |
| `--bin-dir DIR` | Install somewhere other than `~/.local/bin`. |
| `--test` / `--no-test` | Post (or don't) the test item. `--test-context work\|personal`. |
| `--require-health` | Exit 3 if no hub answers. |
| `--no-schedule` / `--no-path` | Skip the flush schedule / the shell profile line. |
| `--alerts`, `--context-alert`, `--ssh-alias`, `--agent-link`, `--orca-environment` | Claude Code hook settings, as in the installer above. |


## Without the CLI

Anything that can make an HTTP request can post; see [AGENT-GUIDE.md → With curl](../AGENT-GUIDE.md#with-curl). The trade-off: no outbox and no failover, so loop over `NEEDS_YOU_URLS` yourself (the [GitHub Actions example](../../integrations/ci/github-actions.yml) does) or accept that an alert is lost while the hub is down.

## Picking keys and context

- **Key:** `<prefix>:<project-or-ticket>:<reason>`, e.g. `personal:my-server:backup-failed`, `work:ACME-456:feature-flag`. Stable across runs, never a timestamp. The same key updates the item; `resolve` with the same key clears it.
- **Context:** `work` or `personal`; it decides when the item is prominent on the Mac. Set a machine default with `--context`.
- **Kind:** `needs` (you must act, raises the count), `done` (FYI, finished), `info`. `done` and `info` expire after 24 h.

## Cron, systemd, CI

Ready-made pieces are in [integrations/ci](../../integrations/ci/README.md): a wrapper that alerts on failure and resolves on success, an `OnFailure=` systemd template, and a GitHub Actions step that joins the tailnet.

## Removing a sender

1. **Revoke its token.** In the Mac app: right-click the pill → **Settings…** → **Access** → **Revoke** next to the machine (invites are listed there too). Over HTTP with an owner token: `DELETE /v1/tokens/<name>` ([API.md](../API.md#tokens)). On a server hub: `needs-you-admin token revoke <name>`. Or run the admin tool bundled in the app against its database (safe while the app runs):

   ```bash
   ADMIN=/Applications/NeedsYou.app/Contents/Resources/hub/needs_you_admin.py
   DB="$HOME/Library/Application Support/NeedsYou/hub.db"
   /usr/bin/python3 "$ADMIN" --db "$DB" token list
   /usr/bin/python3 "$ADMIN" --db "$DB" token revoke <name>      # e.g. orca-build-2
   ```

   `invite list --all` and `invite revoke <name>` work the same way for links.

2. **Clean up the machine.** Either run a live invite's installer with `--uninstall`, or by hand. First the Claude Code hooks, if they were installed: `integrations/claude-code/install-hooks.sh --uninstall` from a checkout of this repo, or without one:

   ```bash
   . ~/.config/needs-you/env; d=$(mktemp -d)
   curl -fsS "$NEEDS_YOU_URL/dl/install-hooks.sh" -o "$d/install-hooks.sh"
   bash "$d/install-hooks.sh" --uninstall; rm -rf "$d"
   ```

   Then the rest:

   ```bash
   crontab -l | grep -v needs-you-flush | crontab -                          # Linux
   launchctl bootout gui/$(id -u)/io.needs-you.flush; rm -f ~/Library/LaunchAgents/io.needs-you.flush.plist   # macOS
   rm -rf ~/.config/needs-you ~/.local/bin/needs-you ~/.local/state/needs-you ~/.claude/skills/needs-you
   ```
