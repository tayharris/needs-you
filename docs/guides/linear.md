# Linear

Get a card when Linear needs you: an issue assigned to you, a new comment or reply, a mention, or a status change on an issue you follow. One card per issue, updated as new events arrive. It clears itself when you read, archive or snooze the notification in Linear, when the issue is done or no longer yours, or after a day with nothing new.

A small poller, `needs-you-linear`, does this from **one** machine every 5 minutes with a Linear personal API key. Nothing in Linear changes: no webhook, no app, no public endpoint. It does nothing until you give it a key.

## Before you start

- A sender machine that's always on, such as a devbox: run an invite link's installer there first ([add-a-sender.md](add-a-sender.md)). `needs-you doctor` should show no `FAIL`.
- A Linear personal API key: in Linear, Settings → Account → Security & access → Personal API keys. If Linear offers a choice, give it read access only.
- `python3` 3.9 or newer.

## Set up (4 commands)

```bash
# 1. Install the poller (or `install -m 755 integrations/linear/needs-you-linear ~/.local/bin/` from a checkout)
curl -fsSL https://raw.githubusercontent.com/tayharris/needs-you/main/integrations/linear/needs-you-linear -o ~/.local/bin/needs-you-linear && chmod 755 ~/.local/bin/needs-you-linear

# 2. Save the key where only you can read it: paste it, press Enter, then Ctrl-D
(umask 077 && mkdir -p ~/.config/needs-you && cat > ~/.config/needs-you/linear-key)

# 3. See what it would post, without posting anything
~/.local/bin/needs-you-linear --dry-run -v

# 4. Run it every 5 minutes
(crontab -l 2>/dev/null; echo '*/5 * * * * $HOME/.local/bin/needs-you-linear >/dev/null  # needs-you-linear') | crontab -
```

The key file must be yours and mode 600 (step 2 does that). The poller refuses a key file that group or others can read, and a symlink. Keep the key out of `~/.config/needs-you/env` and out of the cron line.

Prefer a systemd user timer or, on a Mac, a LaunchAgent? Use the files in [integrations/linear](../../integrations/linear/README.md) instead of step 4.

## Check it works

Within 5 minutes the cards from the dry run appear on your Mac, keyed `work:linear:ACME-123`. The title says what happened last ("New comment on ACME-123: *title*", "ACME-123 moved to Blocked: *title*"), the body counts what's waiting ("2 new comments, status In Review"), and the button opens the issue or the comment in Linear (in the desktop app if Linear's "Open links in desktop app" is on). Read the notification in Linear and the card goes away on the next run.

## Tune it

Settings go in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_LINEAR_TEAMS=ACME=work:normal,OPS=work:urgent      # which teams to watch, their context and base priority
NEEDS_YOU_LINEAR_STATUSES=Blocked=urgent,In Review=normal,Backlog=off,*=low   # priority by status; off = no status-change card
NEEDS_YOU_LINEAR_CATEGORIES=-mention                         # turn events off (or list the ones you want)
```

Each card carries its event (`assigned`, `status`, `comment`, `mention`) as `source.event`, so the Mac's alert rules can treat them differently: for example, comments on `work:linear:` cards **Always later**, and one issue **Treat as urgent** while you're on it ([Mac app guide](mac-app.md#focus-heads-down-except-what-you-choose)).

The full list of cards, keys and settings is in [integrations/linear/README.md](../../integrations/linear/README.md). At most 20 cards are open at once (`NEEDS_YOU_LINEAR_MAX_CARDS`).

## When it doesn't post

- Run `needs-you-linear -v`. It says how many notifications it read and any error. It always exits 0, so cron won't tell you.
- "refusing the key file": run `chmod 600 ~/.config/needs-you/linear-key` as the user cron runs as.
- "Authentication required" or HTTP 400/401: the key was revoked or mistyped; make a new one and repeat step 2. After 3 failed runs in a row it posts one low card, "Linear alerts stopped on devbox", which clears on the next good run.
- Cards from the dry run but nothing on the Mac: the hub isn't reachable from this machine; see [troubleshooting](troubleshooting.md#a-sender-cant-reach-the-hub).
- To start over, delete `~/.local/state/needs-you/linear.json`. Cards it posted expire within 15 minutes on their own.

More in [troubleshooting](troubleshooting.md#linear-poller).
