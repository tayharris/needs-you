# Add a sender (a VM, a project, a CI repo)

A sender is anything that posts items: a VM's cron jobs, an agent, an Orca automation, a CI workflow. Each one gets its own token so you can revoke it alone.

## Checklist

1. **Tailnet:** join the machine to your tailnet (`tailscale up`). Check: `curl -fsS http://hub-a.<tailnet>.ts.net:8765/v1/health`.
2. **Token:** on a hub, `needs_you_admin.py token add <machine-or-repo-name>` ([HUB.md](../HUB.md)). It's valid on every hub.
3. **Setup:** on the machine, from a checkout of this repo:

   ```bash
   ./scripts/setup-sender.sh
   ```

   Then post the test `info` item when it offers.
4. **Decide the key prefix and context** for this machine's items (below), and give its agents [AGENT-GUIDE.md](../AGENT-GUIDE.md) or the [Claude Code skill](claude-code.md#the-skill).
5. **Outbox flush:** if it runs jobs while the hubs might be unreachable, add to cron:

   ```cron
   */10 * * * *  $HOME/.local/bin/needs-you flush >/dev/null 2>&1
   ```

   (Use the full path: cron's `PATH` doesn't include `~/.local/bin`.)

## What setup-sender.sh does

| Step | Detail |
|---|---|
| Installs the CLI | Copies `cli/needs-you` (one Python 3 file) to `~/.local/bin/needs-you`. If `~/.local/bin` isn't on `PATH` it prints the line to add; it never edits your dotfiles. |
| Asks for hubs | Comma-separated, in failover order. Use MagicDNS names, not `100.x` IPs, so moving a hub is only a DNS change. |
| Asks for the token | Hidden input. Press Enter on a re-run to keep the saved one. |
| Writes the config | `~/.config/needs-you/env`, mode 600 (directory 700). Other lines you add there are kept. |
| Checks health | `GET /v1/health` on each hub; prints ok/FAIL per hub. |
| Test item | Optional `info` item keyed `setup:<host>:test` (shows under Recent, expires in 24 h). |

The config file:

```bash
NEEDS_YOU_URLS=http://hub-a.example.ts.net:8765,http://hub-b.example.ts.net:8765   # CLI: tried in order
NEEDS_YOU_URL=http://hub-a.example.ts.net:8765                                      # first hub, for curl
NEEDS_YOU_TOKEN=...
```

### Unattended (provisioning, cloud-init, Ansible)

```bash
printf '%s' "$TOKEN" | ./scripts/setup-sender.sh --non-interactive \
  --url "http://hub-a.example.ts.net:8765,http://hub-b.example.ts.net:8765" \
  --token-stdin --install-cli --test
```

| Flag | Meaning |
|---|---|
| `--non-interactive` | Never prompt. Reuses the saved URL/token when flags are omitted. |
| `--token-stdin` | Read the token from stdin (keeps it out of `ps` and history). `--token X` and `NEEDS_YOU_TOKEN` also work. |
| `--install-cli [SRC]` | Install the CLI from this repo, a local path, or an `https://` URL to the raw file. `--no-install-cli` skips it. |
| `--bin-dir DIR` | Install somewhere other than `~/.local/bin`. |
| `--test` / `--no-test` | Post (or don't) the test item. `--test-context work\|personal`. |
| `--require-health` | Exit 3 if no hub answers. By default an unreachable hub is only a warning, since the CLI queues. |

Requirements: bash (macOS's 3.2 is fine), curl, python3 3.9+. No jq, no package installs.

## Without the CLI

Anything that can make an HTTP request can post. See [AGENT-GUIDE.md → With curl](../AGENT-GUIDE.md#with-curl). The trade-off: no offline outbox and no automatic failover, so either loop over `NEEDS_YOU_URLS` yourself (the [GitHub Actions example](../../integrations/ci/github-actions.yml) does) or accept that an alert is lost while the hub is down.

## Picking keys and context

- **Key:** `<prefix>:<project-or-ticket>:<reason>`, e.g. `personal:hub-b:backup-failed`, `work:ACME-4529:ssm-flag`. Stable across runs, never a timestamp. The same key updates the item; `resolve` with the same key clears it.
- **Context:** `work` or `personal`. It decides when the item is prominent on the Mac. Wrong context = shown at the wrong time of day.
- **Kind:** `needs` (you must act, raises the count), `done` (FYI, finished), `info`. `done` and `info` expire after 24 h.

## Cron, systemd, CI

Ready-made pieces are in [integrations/ci](../../integrations/ci/README.md): a wrapper that alerts on failure and resolves on success, an `OnFailure=` systemd template, and a GitHub Actions step that joins the tailnet.

## Removing a sender

Revoke its token on a hub (`needs_you_admin.py token ...`, see [HUB.md](../HUB.md)), then on the machine `rm -r ~/.config/needs-you ~/.local/bin/needs-you ~/.local/state/needs-you`.
