# GitHub

Get a card when GitHub is waiting on you: a review request, a deployment that needs your approval, CI that failed on your branch, a mention, or one of your PRs that is ready to merge, has changes requested, conflicts or failing checks. Each card clears itself once the condition goes away.

A small poller, `needs-you-github`, does this from **one** machine every 5 minutes, using that machine's `gh` login. Nothing on GitHub changes: no webhook, no app, no public endpoint.

## Before you start

- A sender machine that's always on, such as a devbox: run an invite link's installer there first ([add-a-sender.md](add-a-sender.md)). `needs-you doctor` should show no `FAIL`.
- [GitHub CLI](https://cli.github.com/) logged in on it: `gh auth status` says "Logged in". (`gh auth login` grants the `repo` and `notifications` scopes the poller needs.)
- `python3` 3.9 or newer.

## Set up (3 commands)

```bash
# 1. Install the poller (from GitHub with your gh login, or `install -m 755 integrations/github/needs-you-github ~/.local/bin/` from a checkout)
gh api -H 'Accept: application/vnd.github.raw' repos/tayharris/needs-you/contents/integrations/github/needs-you-github > ~/.local/bin/needs-you-github && chmod 755 ~/.local/bin/needs-you-github

# 2. See what it would post, without posting anything
~/.local/bin/needs-you-github --dry-run -v

# 3. Run it every 5 minutes
(crontab -l 2>/dev/null; echo '*/5 * * * * $HOME/.local/bin/needs-you-github >/dev/null  # needs-you-github') | crontab -
```

Prefer a systemd user timer or, on a Mac, a LaunchAgent? Use the files in [integrations/github](../../integrations/github/README.md) instead of step 3.

## Check it works

Within 5 minutes the cards from the dry run appear on your Mac. Each one has a link to the place you act (the PR's files, the run's "Review deployments" page, the failing check's logs) and, where it takes more than one action, numbered steps. When you merge, review or fix the thing, the card goes away on the next run.

## Tune it

Settings go in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_GITHUB_CONTEXTS=acme=work,my-user=personal   # which owner's cards are work or personal
NEEDS_YOU_GITHUB_EXCLUDE=acme/huge-monorepo            # owners or repos to ignore
NEEDS_YOU_GITHUB_REASONS=-mention,-assign              # turn reasons off (or list the ones you want)
```

The full list of cards, keys and settings is in [integrations/github/README.md](../../integrations/github/README.md). If you have many open PRs, `NEEDS_YOU_GITHUB_PR_DAYS` (default 14) skips the ones nobody has touched lately, and at most 20 cards are open at once (`NEEDS_YOU_GITHUB_MAX_CARDS`).

## When it doesn't post

- Run `needs-you-github -v`. It says how many notifications and PRs it saw and any `gh` error. It always exits 0, so cron won't tell you.
- `gh` errors (logged out, token expired): fix with `gh auth login`. After 3 failed runs in a row it posts one low card, "GitHub alerts stopped on devbox", which clears on the next good run.
- Cards from the dry run but nothing on the Mac: the hub isn't reachable from this machine; see [troubleshooting](troubleshooting.md#a-sender-cant-reach-the-hub).
- To start over, delete `~/.local/state/needs-you/github.json`. Cards it posted expire within 15 minutes on their own.
