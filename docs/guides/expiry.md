# Expiring certificates, domains and keys

Get a card before something you own expires: the TLS certificate one of your hosts serves, a domain's registration, or an API key or token whose expiry date you know (a Figma token, a deploy key, a cloud access key). The card appears 30 days out as low, turns normal at 7 days and urgent at 1 day or once it has expired, and clears itself once you renew.

A small poller, `needs-you-expiry`, does this once a day from **one** machine. It needs no account and no token: certificates are read with a TLS handshake, domains through public RDAP over HTTPS.

## Before you start

- A sender machine that's on most days, such as a devbox: run an invite link's installer there first ([add-a-sender.md](add-a-sender.md)). `needs-you doctor` should show no `FAIL`.
- `python3` 3.9 or newer, and outbound HTTPS from that machine. [GitHub CLI](https://cli.github.com/) logged in, for step 1 (or a checkout of this repo).

## Set up (4 commands)

```bash
# 1. Install the poller (from GitHub with your gh login, or `install -m 755 integrations/expiry/needs-you-expiry ~/.local/bin/` from a checkout)
gh api -H 'Accept: application/vnd.github.raw' repos/tayharris/needs-you/contents/integrations/expiry/needs-you-expiry > ~/.local/bin/needs-you-expiry && chmod 755 ~/.local/bin/needs-you-expiry

# 2. List what to watch (this file is the opt-in: no file, no cards)
cat > ~/.config/needs-you/expiry.conf <<'EOF'
tls     example.com
domain  example.com
key     "Figma PAT"  2026-12-31  renew=https://www.figma.com/settings
EOF

# 3. See what it would post, without posting anything
~/.local/bin/needs-you-expiry --dry-run -v

# 4. Run it every day
(crontab -l 2>/dev/null; echo '17 9 * * * $HOME/.local/bin/needs-you-expiry >/dev/null  # needs-you-expiry') | crontab -
```

Prefer a systemd user timer or, on a Mac, a LaunchAgent? Use the files in [integrations/expiry](../../integrations/expiry/README.md) instead of step 4.

## What to put in the list

One thing per line:

- `tls example.com` reads the certificate on port 443; `tls mail.example.com:993` on another port.
- `domain example.com` reads the registration's expiry from RDAP.
- `key "Figma PAT" 2026-12-31` is a date you know: the day it stops working. When you rotate the key, change the date.

Add `renew=https://...` to give the card a **Renew** button that opens the page where you renew it, and `context=personal` for your own things (the default is `work`). For an internal host whose certificate comes from a private CA, add `verify=no`.

## Check it works

Step 3 prints every date it read (`-v`) and the cards it would post: anything within 30 days. Put a `key "Test key" <a date next week>` line in, run `needs-you-expiry` once, and a normal "Test key expires ..." card appears on your Mac. Take the line out, run it again, and the card clears.

## Tune it

Settings go in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_EXPIRY_DAYS=60=low,14=normal,3=urgent   # when cards appear and how loud
NEEDS_YOU_EXPIRY_CONTEXT=personal                  # the default context
```

The full list of cards, keys and settings is in [integrations/expiry/README.md](../../integrations/expiry/README.md).

## When it doesn't post

- Run `needs-you-expiry -v`. It prints each date and each failing check. It always exits 0, so cron won't tell you.
- A host or RDAP lookup that keeps failing: after 2 failed runs in a row, one low card, "Expiry checks failing on devbox", lists what failed and why. It clears on the next run where everything works.
- See [troubleshooting](troubleshooting.md#expiry-poller) for the common errors.
