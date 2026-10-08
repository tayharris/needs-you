# Troubleshooting

Work from the sender toward the Mac: can the sender reach a hub, did the hub store the item, can the Mac see it, is the Mac showing the right context.

Reporting a problem: what to include, and how to save the app's log with tokens and invite codes masked, is in [testers.md → Report a problem](testers.md#8-report-a-problem).

## Start here: `needs-you doctor`

On the sender, run:

```bash
needs-you doctor          # or ~/.local/bin/needs-you doctor if it isn't on PATH
needs-you doctor --json   # the same, for agents: {ok, version, checks: [{check, status, detail, hint}]}
```

It checks the env file (and that its mode is 600), whether `needs-you` and `~/.local/bin` are on `PATH`, each hub URL (reachable, hub version, the token's name and role), the outbox (queued, failed, oldest), the Claude Code hooks and skill, Orca settings, and the 5-minute flush schedule. Each line is `OK`, `WARN`, `FAIL` or `INFO`. Every `WARN` and `FAIL` has one next step under it (after `->`): a command to run as is, or exactly what to ask for, such as a new invite link (`<invite link>` is the only placeholder). It exits 1 if any check is `FAIL`. It's read-only: it never posts an item, never flushes the outbox and never prints the token (only "set" and its length).

## Quick checks by hand

```bash
# on the sender
. ~/.config/needs-you/env
for u in $(echo "$NEEDS_YOU_URLS" | tr ',' ' '); do
  printf '%s  ' "$u"; curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 "$u/v1/health"
done
ls ~/.local/state/needs-you/outbox/ 2>/dev/null   # queued items that haven't reached a hub
tailscale status | head                          # is this machine on the tailnet?
# macOS with the Tailscale app: /Applications/Tailscale.app/Contents/MacOS/Tailscale status
```

## A sender can't reach the hub

Setting up Tailscale, or checking it step by step: [tailscale.md](tailscale.md).

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: (6) Could not resolve host` | MagicDNS off, or the machine isn't on the tailnet | `tailscale up`; enable MagicDNS in the admin console; `tailscale status` should list the hub |
| `curl: (7) Failed to connect` / timeout | Hub down, or listening on a different address/port | On the hub: `systemctl status needs-you-hub`, `journalctl -u needs-you-hub -n 50` (see [HUB.md](../HUB.md) for the unit name) |
| Times out only from some machines | Tailscale ACL | Allow those machines (or their tag) to reach the hub's tag on `tcp:8765` |
| Works by IP, not by name | DNS | Use the full MagicDNS name, `<hub>.<tailnet>.ts.net` |
| `HTTP 421` "doesn't answer to that host name" | The URL uses a name the hub doesn't know as its own (a custom DNS name or alias); this is its DNS-rebinding protection | Use the hub's public URL (MagicDNS name) or tailnet IP, or add the name to the hub's `allowed_hosts` (`--allowed-host`, or `NEEDS_YOU_HUB_ALLOWED_HOSTS` for the Mac app's hub, [HUB.md](../HUB.md)) |
| `HTTP 401` / `403` | Wrong, revoked, or Mac-only token | Get a new invite link and re-run its installer with `--force` |
| Times out only while the Mac sleeps | The Mac's own hub is asleep | Expected: items queue and the 5-minute flush sends them after it wakes. Add a [server hub](../HUB.md) to avoid the wait. |
| Times out from servers, works on the Mac | Tailscale is down on the Mac (the app's hub then listens only on `127.0.0.1`), or the macOS firewall blocks it | Bring Tailscale up on the Mac; the hub picks up the tailnet address by itself (Settings… → Your inbox shows the URL). Allow `python3` in System Settings → Network → Firewall |
| `HTTP 400` | Validation: title > 100 chars, body > 2,000, > 6 links, a link scheme not on the allow-list, a bad `context`/`kind`/`priority` | Fix the item; the response body says which field |
| `HTTP 429` or "too many open items" | The sender has 60 open items: something is looping | Stop the loop; resolve the stale keys |

The CLI never fails your job because of the hub. It queues to `~/.local/state/needs-you/outbox/` and sends on the next call or `needs-you flush` (the invite installer schedules one every 5 minutes). Items sitting in the outbox mean no hub has accepted them yet. The outbox keeps at most 500 requests and 7 days; older ones are dropped with a warning.

## Invite links

| Symptom | Cause | Fix |
|---|---|---|
| `This invite link is unknown, expired or revoked` (exit 1) | What it says | Make a new link |
| `invite ... has no uses left` (exit 1) | A new machine, or `--force`, on a used-up link | Make a new link, or one with more uses |
| `HTTP 429` / "too many failed invite attempts" | 10 failed tries from this IP in 10 minutes | Wait 10 minutes; check the link was pasted whole |
| "This invite (..., role owner) is for the Mac app" | An owner/reader link was used on a server | Open the `needsyou://` link on the Mac; make a `sender` link for servers |
| Re-running the one-liner (or `--uninstall`) fails after the link expired | Re-runs work until expiry, not after | Update with `needs-you update`; remove by hand ([add-a-sender.md](add-a-sender.md#removing-a-sender)); or make a new link |
| `curl: (22) ... 404` and no other output | A hub older than this release (it 404s dead links, and bash runs the empty script) | Make a new link; update the hub |
| "kept the existing token" | The machine was already set up | Expected. `--force` redeems again and replaces the token |
| Installer says no hub answered | The hub is asleep or unreachable right now | The setup still completed; the test item is queued |

## setup-sender.sh (manual setup)

- **`needs-you: command not found` after setup:** `~/.local/bin` isn't on your `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile. Hooks and cron don't read your profile; they find the CLI at `~/.local/bin/needs-you` directly (or set `NEEDS_YOU_BIN`).
- **"no terminal available; continuing as --non-interactive":** you ran it without a TTY (e.g. over `ssh host cmd`). Use `ssh -t`, or pass `--url` and `--token-stdin`.
- **"does not look like the needs-you CLI":** the `--install-cli` URL returned an HTML page (login wall, 404). Use the raw file URL.
- **Health ok, but the test item is refused (401):** the token isn't valid on that hub. Tokens replicate between peered hubs; check the hubs are peered and the token exists on each (`needs-you-admin token list`).

## Items post, but nothing shows on the Mac

1. **Context and hours:** a `work` item at 21:00 shows only as the faint second number (`0 · 1`). Use the toggle in the expanded header, or check the work-hours setting.
2. **Kind:** `done` and `info` items never raise the count. They're in the collapsed **Recent** section.
3. **Snoozed:** press Control-Option-Space (⌃⌥Space, or your configured shortcut) to bring the panel back.
4. **Mac can't reach a server hub:** the Mac needs Tailscale up. Hover the idle pill: the "last check" time should be recent.
5. **Wrong hub:** the sender's `NEEDS_YOU_URLS` must include the Mac's hub or a server hub peered with it.
6. **Hubs out of sync:** if the Mac polls `hub-a` and the sender wrote to `hub-b`, replication should copy it within seconds. If it doesn't, check the peer list and the replication outbox on `hub-b` ([HUB.md](../HUB.md)).

## Duplicate or stale cards

- **Duplicates:** the sender changes its key between runs (a timestamp, a run id). Keys must be stable.
- **Cards that never go away:** the sender never calls `resolve`. Fix the sender, then clear the card with **Done** on the Mac.
- **A card keeps re-animating:** the title, body or priority changes on every post (e.g. a counter or time in the title). Put changing details in the body sparingly, or keep them out.

## Claude Code hooks

Setup per environment (SSH, tmux, VS Code Remote-SSH, Orca): [claude-code-everywhere.md](claude-code-everywhere.md). Turn on the debug log and simulate an event:

```bash
echo '{"session_id":"t1","cwd":"'"$PWD"'","notification_type":"idle_prompt","message":"test"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify
```

| Log says | Meaning |
|---|---|
| nothing at all | Not opted in. Set `NEEDS_YOU_AGENT_ALERTS=1`, or run inside Orca. Check it isn't `0` in `~/.config/needs-you/env`. |
| `needs-you CLI not found` | Install it (an invite link, or `setup-sender.sh --install-cli`) or set `NEEDS_YOU_BIN`. |
| `notify agent:... -> 0` | Posted (or queued). Check the hub and the Mac as above. |
| `notify agent:... -> 1` | The CLI failed. Run the same `needs-you add` by hand to see the error. |

Other checks:

- `/hooks` inside Claude Code lists the active hooks. If ours are missing, re-run `install-hooks.sh` and restart the session.
- Project-level hooks use `$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh`. If the repo was cloned without `.claude/hooks/`, re-run `install-hooks.sh --project`.
- A card that doesn't clear: the resolve runs only if this session posted (marker files in `~/.local/state/needs-you/claude-hooks/`). Deleting that directory is safe. A session that was killed is cleared by the next `needs-you flush` once its Claude process is gone (`needs-you doctor` shows whether the flush is scheduled), or 48 hours after its last post.
- Too noisy? `idle_prompt` fires after about a minute of waiting. Opt in only on machines where agents run unattended.

## Codex hooks

`needs-you doctor` has a `codex hooks` line. Simulate an approval prompt and its resolve with a log to stderr:

```bash
echo '{"hook_event_name":"PermissionRequest","session_id":"t1","cwd":"'"$PWD"'","tool_name":"Bash","tool_input":{"command":"make test"}}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.codex/hooks/needs-you-hook.sh notify codex
echo '{"session_id":"t1"}' | NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.codex/hooks/needs-you-hook.sh resolve codex
```

The log lines mean the same as for the Claude Code hooks above. Codex-specific causes:

- **Not trusted.** Codex skips hooks nobody has reviewed and says so at startup. Open `/hooks` in Codex and trust the needs-you entries. Editing those entries by hand makes them untrusted again.
- **Hooks turned off.** `hooks = false` under `[features]` in `~/.codex/config.toml` (or a managed `requirements.toml`) disables every hook; doctor reports the first.
- **Another `CODEX_HOME`.** The installer and doctor follow `$CODEX_HOME`; run them with the same value Codex uses.
- **Every turn makes a card.** That's the `Stop` hook: Codex finished and is waiting for you. Opt in only where Codex runs unattended, set `NEEDS_YOU_AGENT_TURN_CARDS=0` to keep only approval cards, or turn it off for a session with `NEEDS_YOU_AGENT_ALERTS=0`.

## Copilot CLI hooks

`needs-you doctor` has a `copilot hooks` line. In `copilot` mode the hook finishes in the background, so log to a file:

```bash
echo '{"sessionId":"t1","cwd":"'"$PWD"'","notification_type":"permission_prompt","message":"Run command: make test"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/tmp/ny-hook.log ~/.copilot/hooks/needs-you-hook.sh notify copilot
sleep 2; cat /tmp/ny-hook.log
```

Copilot-specific causes:

- **Not restarted.** Copilot CLI reads `~/.copilot/hooks/*.json` when it starts.
- **Hooks turned off.** `"disableAllHooks": true` in `~/.copilot/settings.json` or `config.json`; doctor reports it.
- **Another `COPILOT_HOME`.** Copilot then reads `$COPILOT_HOME/hooks/` instead; run the installer and doctor with the same value.
- **A card stays after Esc.** Cancelling a permission prompt runs no hook in Copilot; the card goes with your next prompt or the end of the session.

## GitHub poller

- `needs-you-github -v` prints what it saw (notifications, PRs) and any `gh` error. It always exits 0, so a broken cron job is silent; after 3 failed runs in a row it posts one low card, "GitHub alerts stopped on <host>".
- `gh: Bad credentials` or `gh auth login` errors: log in again as the user cron runs as. cron and systemd have a short `PATH`; set `NEEDS_YOU_GITHUB_GH` to the full path of `gh` if it isn't in `/usr/bin`.
- Too many cards: narrow it with `NEEDS_YOU_GITHUB_EXCLUDE`, `NEEDS_YOU_GITHUB_REASONS` or `NEEDS_YOU_GITHUB_PR_DAYS` ([integrations/github](../../integrations/github/README.md#config)).
- A card that doesn't clear: it clears on the run after the condition goes away, or 15 minutes after the poller stops. Notification cards clear when you read the thread on GitHub.

## Orca automations

- `needs-you` must be on the `PATH` that Orca's agent terminals get. From an Orca terminal: `command -v needs-you`.
- An automation that stopped posting after a template re-render: the block was added to the live prompt, not the template.
- An `orca://` link refused with 400: the hub no longer accepts `orca://` at all (Orca has no terminal or worktree links; its only link, `orca://skills/share/<id>`, imports a skill). Remove it from the automation prompt or `NEEDS_YOU_AGENT_LINK`; the card's **Terminal** button (`needsyou://orca/terminal`) and the body's `orca terminal switch` command are the way back to the terminal.
- A `vscode://` or `cursor://` link refused with 400, or shown as plain text on an older card: only `vscode://file/<abs path>[:line[:col]]`, `vscode://vscode-remote/ssh-remote+<host>[/<path>]` (or `tunnel+<name>`) and `vscode://anthropic.claude-code/open?session=<id>` are allowed, without a query string ([API.md](../API.md#post-v1items-sender)). The Claude Code hook posts its card again without links when the hub refuses a custom `NEEDS_YOU_AGENT_LINK`.
- `orca terminal switch` says the terminal isn't found: the agent runs on a paired Orca server. Set `NEEDS_YOU_ORCA_ENVIRONMENT` in `~/.config/needs-you/env` on that server to the name `orca environment list` shows on the Mac.
