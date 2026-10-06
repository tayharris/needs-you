# Troubleshooting

Work from the sender toward the Mac: can the sender reach a hub, did the hub store the item, can the Mac see it, is the Mac showing the right context.

## Quick checks

```bash
# on the sender
. ~/.config/needs-you/env
for u in $(echo "$NEEDS_YOU_URLS" | tr ',' ' '); do
  printf '%s  ' "$u"; curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 "$u/v1/health"
done
ls ~/.local/state/needs-you/outbox/ 2>/dev/null   # queued items that haven't reached a hub
tailscale status | head                          # is this machine on the tailnet?
```

## A sender can't reach the hub

| Symptom | Likely cause | Fix |
|---|---|---|
| `curl: (6) Could not resolve host` | MagicDNS off, or the machine isn't on the tailnet | `tailscale up`; enable MagicDNS in the admin console; `tailscale status` should list the hub |
| `curl: (7) Failed to connect` / timeout | Hub down, or listening on a different address/port | On the hub: `systemctl status needs-you-hub`, `journalctl -u needs-you-hub -n 50` (see [HUB.md](../HUB.md) for the unit name) |
| Times out only from some machines | Tailscale ACL | Allow those machines (or their tag) to reach the hub's tag on `tcp:8765` |
| Works by IP, not by name | DNS | Use the full MagicDNS name, `<hub>.<tailnet>.ts.net` |
| `HTTP 401` / `403` | Wrong, revoked, or Mac-only token | Get a new invite link and re-run its installer with `--force` |
| Times out only while the Mac sleeps | The Mac's own hub is asleep | Expected: items queue and the 5-minute flush sends them after it wakes. Add a [server hub](../HUB.md) to avoid the wait. |
| Times out from servers, works on the Mac | The hub listens only on `127.0.0.1`, or the macOS firewall blocks it | Turn on tailnet access in the app; allow `python3` in System Settings → Network → Firewall |
| `HTTP 422` / `400` | Validation: title > 100 chars, body > 2,000, > 6 links, a link scheme not on the allow-list, a bad `context`/`kind`/`priority` | Fix the item; the response body says which field |
| `HTTP 429` or "too many open items" | The sender has 60 open items: something is looping | Stop the loop; resolve the stale keys |

The CLI never fails your job because of the hub. It queues to `~/.local/state/needs-you/outbox/` and sends on the next call or `needs-you flush` (the invite installer schedules one every 5 minutes). Items sitting in the outbox mean no hub has accepted them yet. The outbox keeps at most 500 requests and 7 days; older ones are dropped with a warning.

## Invite links

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (22) ... 404` from the one-liner (and bash "succeeds" with no output) | The link is used up, expired or revoked | Make a new link |
| `HTTP 429` / "too many failed invite attempts" | 10 failed tries from this IP in 10 minutes | Wait 10 minutes; check the link was pasted whole |
| "This invite (..., role owner) is for the Mac app" | An owner/reader link was used on a server | Open the `needsyou://` link on the Mac; make a `sender` link for servers |
| "kept the existing token" | The machine was already set up | Expected. `--force` redeems again and replaces the token |
| Installer says no hub answered | The hub is asleep or unreachable right now | The setup still completed; the test item is queued |

## setup-sender.sh (manual setup)

- **`needs-you: command not found` after setup:** `~/.local/bin` isn't on your `PATH`. Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile. Hooks and cron don't read your profile; they find the CLI at `~/.local/bin/needs-you` directly (or set `NEEDS_YOU_BIN`).
- **"no terminal available; continuing as --non-interactive":** you ran it without a TTY (e.g. over `ssh host cmd`). Use `ssh -t`, or pass `--url` and `--token-stdin`.
- **"does not look like the needs-you CLI":** the `--install-cli` URL returned an HTML page (login wall, 404). Use the raw file URL.
- **Health ok, but the test item is refused (401):** the token isn't valid on that hub. Tokens are added to every hub by the admin tool; check the hubs are peered and the token exists on each.

## Items post, but nothing shows on the Mac

1. **Context and hours:** a `work` item at 21:00 shows only as the faint second number (`0 · 1`). Use the toggle in the expanded header, or check the work-hours setting.
2. **Kind:** `done` and `info` items never raise the count. They're in the collapsed **Recent** section.
3. **Snoozed:** press ⌃⌥Space (or your configured shortcut) to bring the panel back.
4. **Mac can't reach a server hub:** the Mac needs Tailscale up. Hover the idle pill: the "last check" time should be recent.
5. **Wrong hub:** the sender's `NEEDS_YOU_URLS` must include the Mac's hub or a server hub peered with it.
6. **Hubs out of sync:** if the Mac polls `hub-a` and the sender wrote to `hub-b`, replication should copy it within seconds. If it doesn't, check the peer list and the replication outbox on `hub-b` ([HUB.md](../HUB.md)).

## Duplicate or stale cards

- **Duplicates:** the sender changes its key between runs (a timestamp, a run id). Keys must be stable.
- **Cards that never go away:** the sender never calls `resolve`. Fix the sender, then clear the card with **Done** on the Mac.
- **A card keeps re-animating:** the title, body or priority changes on every post (e.g. a counter or time in the title). Put changing details in the body sparingly, or keep them out.

## Claude Code hooks

Turn on the debug log and simulate an event:

```bash
echo '{"session_id":"t1","cwd":"'"$PWD"'","notification_type":"idle_prompt","message":"test"}' |
  NEEDS_YOU_AGENT_ALERTS=1 NEEDS_YOU_HOOK_LOG=/dev/stderr ~/.claude/hooks/needs-you-hook.sh notify
```

| Log says | Meaning |
|---|---|
| nothing at all | Not opted in. Set `NEEDS_YOU_AGENT_ALERTS=1`, or run inside Orca. Check it isn't `0` in `~/.config/needs-you/env`. |
| `needs-you CLI not found` | Install it (`setup-sender.sh --install-cli`) or set `NEEDS_YOU_BIN`. |
| `notify agent:... -> 0` | Posted (or queued). Check the hub and the Mac as above. |
| `notify agent:... -> 1` | The CLI failed. Run the same `needs-you add` by hand to see the error. |

Other checks:

- `/hooks` inside Claude Code lists the active hooks. If ours are missing, re-run `install-hooks.sh` and restart the session.
- Project-level hooks use `$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh`. If the repo was cloned without `.claude/hooks/`, re-run `install-hooks.sh --project`.
- A card that doesn't clear: the resolve runs only if this session posted (marker files in `~/.local/state/needs-you/claude-hooks/`). Deleting that directory is safe.
- Too noisy? `idle_prompt` fires after about a minute of waiting. Opt in only on machines where agents run unattended.

## Orca automations

- `needs-you` must be on the `PATH` that Orca's agent terminals get. From an Orca terminal: `command -v needs-you`.
- An automation that stopped posting after a template re-render: the block was added to the live prompt, not the template.
- Deep links that open nothing: the `orca://` format is unverified. Remove the link (or the `NEEDS_YOU_AGENT_LINK` setting).
