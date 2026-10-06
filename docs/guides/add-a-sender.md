# Add a sender (a machine, a project, a CI repo)

A sender is anything that posts items: an agent, an Orca automation, a VM's cron jobs, a CI workflow. Each one gets its own token so you can revoke it alone.

## With an invite link (recommended)

1. **Make a link.** In the Mac app, **Invite a machine** (set **uses** to the number of machines). On a server hub: `needs-you-admin invite create my-server --role sender --uses 3 --ttl 72`. You get:
   - a join URL, e.g. `http://my-mac.example.ts.net:8765/join/nyi_...`,
   - a one-liner: `curl -fsSL <join_url>/install.sh | bash -s -- --yes`,
   - an agent prompt: *"Set up needs-you alerts on this machine: read &lt;join_url&gt; and follow it."*
2. **Use it on the machine.** Paste the prompt into the machine's agent (Claude Code, Orca), or run the one-liner yourself. The machine must reach the hub: on the Mac itself that's `127.0.0.1`; elsewhere it must be on the tailnet.
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
| `--skill` | Install the needs-you skill to `~/.claude/skills/needs-you/`. |
| `--orca` | Write the Orca automation snippet to `~/.config/needs-you/orca-snippet.md` and print it. See [orca.md](orca.md). |
| `--context work\|personal` | Default context for this machine's items. |
| `--host NAME` | This machine's name (default: short hostname). |
| `--hub URL` | Use a different URL for the same hub (e.g. its IP while DNS is broken). |
| `--no-schedule` | Don't add the 5-minute flush. |
| `--force` | Redeem again and replace an existing token (needs a link with a use left). |
| `--uninstall` | Remove the CLI, the config, the flush schedule, the skill and (if installed) the user-level hooks. |

Re-running with an already-configured machine updates the CLI and the schedule and keeps the token.

Notes:

- A used-up or expired link returns 404. With `curl ... | bash`, bash then exits 0 on the empty script, so look for `curl: (22) ... 404` in the output.
- `--uninstall` needs a live link to fetch the script; otherwise remove things by hand (below).
- Update the CLI later with `needs-you self-update`.

## Manually (no invite link)

Mint a token on a server hub (`needs-you-admin token add <name> --role sender`), then on the machine, from a checkout of this repo:

```bash
./scripts/setup-sender.sh
```

It installs the CLI, asks for the hub URLs and the token (hidden input), writes `~/.config/needs-you/env`, checks health, and offers a test item. Unattended:

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

It doesn't schedule a flush; add one to cron yourself:

```cron
*/5 * * * *  $HOME/.local/bin/needs-you -q flush >/dev/null 2>&1
```

## Without the CLI

Anything that can make an HTTP request can post; see [AGENT-GUIDE.md → With curl](../AGENT-GUIDE.md#with-curl). The trade-off: no outbox and no failover, so loop over `NEEDS_YOU_URLS` yourself (the [GitHub Actions example](../../integrations/ci/github-actions.yml) does) or accept that an alert is lost while the hub is down.

## Picking keys and context

- **Key:** `<prefix>:<project-or-ticket>:<reason>`, e.g. `personal:my-server:backup-failed`, `work:ACME-456:feature-flag`. Stable across runs, never a timestamp. The same key updates the item; `resolve` with the same key clears it.
- **Context:** `work` or `personal`; it decides when the item is prominent on the Mac. Set a machine default with `--context`.
- **Kind:** `needs` (you must act, raises the count), `done` (FYI, finished), `info`. `done` and `info` expire after 24 h.

## Cron, systemd, CI

Ready-made pieces are in [integrations/ci](../../integrations/ci/README.md): a wrapper that alerts on failure and resolves on success, an `OnFailure=` systemd template, and a GitHub Actions step that joins the tailnet.

## Removing a sender

Revoke its token: in the Mac app, or `needs-you-admin token revoke <name>` on a hub. Then on the machine, either run an invite's installer with `--uninstall`, or:

```bash
crontab -l | grep -v needs-you-flush | crontab -                          # Linux
launchctl bootout gui/$(id -u)/io.needs-you.flush; rm ~/Library/LaunchAgents/io.needs-you.flush.plist   # macOS
rm -r ~/.config/needs-you/env ~/.local/bin/needs-you ~/.local/state/needs-you ~/.claude/skills/needs-you
integrations/claude-code/install-hooks.sh --uninstall                     # if the hooks were installed
```
