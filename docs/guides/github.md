# GitHub

Get a card when GitHub is waiting on you: a review request, a deployment that needs your approval, CI that failed on your branch, a mention, or one of your PRs that is ready to merge, has changes requested, conflicts or failing checks. Each card clears itself once the condition goes away. When one of your PRs merges, you get a low "Merged owner/repo#20: *title*" FYI that expires after a day.

A small poller, `needs-you-github`, does this from **one** machine every 5 minutes, using that machine's `gh` login. Nothing on GitHub changes: no webhook, no app, no public endpoint.

## Before you start

- A sender machine that's always on, such as a devbox: run an invite link's installer there first ([add-a-sender.md](add-a-sender.md)). `needs-you doctor` should show no `FAIL`.
- [GitHub CLI](https://cli.github.com/) logged in on it: `gh auth status` says "Logged in". (`gh auth login` grants the `repo` scope, which covers the notifications and pull requests the poller reads.)
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
NEEDS_YOU_GITHUB_REASONS=-mention,-assign              # turn reasons off (or list the ones you want); -merged: no "Merged" FYIs
```

### Projects statuses and Dependabot alerts (opt-in)

Two more kinds of card are off until you turn them on:

```bash
NEEDS_YOU_GITHUB_PROJECT_STATUSES=Blocked=urgent,In Review=normal   # a card when an issue or PR assigned to you moves to one of these
NEEDS_YOU_GITHUB_SECURITY=1                                          # a card per open critical Dependabot alert (low priority)
NEEDS_YOU_GITHUB_SECURITY_SEVERITIES=critical,high                   # optional: high too
```

- **Projects:** when an open issue or PR assigned to you moves to a status you named in a GitHub project (for example **Blocked**), you get "acme/app#30 is Blocked in Roadmap: *title*" at the priority you gave it. It clears when the status moves on, the issue closes or you're unassigned. The first run only notes where everything is, so turning it on doesn't post what was already blocked. It needs one more `gh` scope: `gh auth refresh -s read:project`. If your projects call the field something other than `Status`, set `NEEDS_YOU_GITHUB_PROJECT_FIELD`.
- **Dependabot:** when GitHub sends you a security alert notification, the poller reads that repo's open Dependabot alerts and posts one low card per critical alert: "Critical security alert in acme/app: lodash: *summary*", linking the alert. It clears when the alert is fixed or dismissed, or you read the notification. It needs `gh auth refresh -s security_events`.

**Let an agent set it up.** On your Mac, **Settings → Integrations → Cards from your tools** lists both, each with its commands and **Copy agent prompt**. Paste the prompt into Claude Code (or another agent) on the machine that runs the poller; it installs the poller if it isn't there yet. It holds no token: the agent asks you to run `gh auth refresh -s ...` in your own terminal.

For Projects statuses:

```text
Set up needs-you cards for GitHub Projects statuses on this machine. The guide is https://github.com/tayharris/needs-you/blob/main/docs/guides/github.md#projects-statuses-and-dependabot-alerts-opt-in.
This machine must already send needs-you alerts: if ~/.local/bin/needs-you is missing or ~/.local/bin/needs-you doctor shows a FAIL, stop and ask me for an invite link (Needs You on my Mac: Settings → Connect a machine).
If ~/.local/bin/needs-you-github isn't there yet, install it: `gh api -H 'Accept: application/vnd.github.raw' repos/tayharris/needs-you/contents/integrations/github/needs-you-github > ~/.local/bin/needs-you-github && chmod 755 ~/.local/bin/needs-you-github`. It also posts cards for review requests, deploys waiting for approval, failed CI and my own pull requests (NEEDS_YOU_GITHUB_REASONS turns some off).
needs-you-github uses this machine's gh login (`gh auth status` must say Logged in) and needs gh's read:project scope. Ask me to run `gh auth refresh -s read:project` in my own terminal (it signs in in the browser), and wait until I say it's done. Never ask me for a GitHub token and never print one.
Settings go in ~/.config/needs-you/env, which also holds this machine's needs-you token: only append lines to it (`echo 'NAME=value' >> ~/.config/needs-you/env`), never print, read out or rewrite it.
Ask me which project statuses need me and how urgent each is, and append them like NEEDS_YOU_GITHUB_PROJECT_STATUSES=Blocked=urgent,In Review=normal. If my projects call the field something other than Status, also append NEEDS_YOU_GITHUB_PROJECT_FIELD with its name.
Its first run only notes where everything is and posts no status cards.
Run `~/.local/bin/needs-you-github --dry-run -v` and tell me what it says.
Schedule it. On Linux add the cron line: `(crontab -l 2>/dev/null; echo '*/5 * * * * $HOME/.local/bin/needs-you-github >/dev/null  # needs-you-github') | crontab -`. On macOS use the LaunchAgent integrations/github/io.needs-you.github.plist from the repo instead (replace /Users/me with my home directory). If `crontab -l` already lists needs-you-github, it's scheduled: skip this.
If a run prints an error, fix what it names, or tell me if it needs me.
```

For Dependabot alerts:

```text
Set up needs-you cards for Dependabot alerts on this machine. The guide is https://github.com/tayharris/needs-you/blob/main/docs/guides/github.md#projects-statuses-and-dependabot-alerts-opt-in.
This machine must already send needs-you alerts: if ~/.local/bin/needs-you is missing or ~/.local/bin/needs-you doctor shows a FAIL, stop and ask me for an invite link (Needs You on my Mac: Settings → Connect a machine).
If ~/.local/bin/needs-you-github isn't there yet, install it: `gh api -H 'Accept: application/vnd.github.raw' repos/tayharris/needs-you/contents/integrations/github/needs-you-github > ~/.local/bin/needs-you-github && chmod 755 ~/.local/bin/needs-you-github`. It also posts cards for review requests, deploys waiting for approval, failed CI and my own pull requests (NEEDS_YOU_GITHUB_REASONS turns some off).
needs-you-github uses this machine's gh login (`gh auth status` must say Logged in) and needs gh's security_events scope. Ask me to run `gh auth refresh -s security_events` in my own terminal (it signs in in the browser), and wait until I say it's done. Never ask me for a GitHub token and never print one.
Settings go in ~/.config/needs-you/env, which also holds this machine's needs-you token: only append lines to it (`echo 'NAME=value' >> ~/.config/needs-you/env`), never print, read out or rewrite it.
Append NEEDS_YOU_GITHUB_SECURITY=1. Ask me whether high alerts should count too; if so, also append NEEDS_YOU_GITHUB_SECURITY_SEVERITIES=critical,high.
Run `~/.local/bin/needs-you-github --dry-run -v` and tell me what it says.
Schedule it. On Linux add the cron line: `(crontab -l 2>/dev/null; echo '*/5 * * * * $HOME/.local/bin/needs-you-github >/dev/null  # needs-you-github') | crontab -`. On macOS use the LaunchAgent integrations/github/io.needs-you.github.plist from the repo instead (replace /Users/me with my home directory). If `crontab -l` already lists needs-you-github, it's scheduled: skip this.
If a run prints an error, fix what it names, or tell me if it needs me.
```

If the scope is missing, the poller says so once, with one low card ("GitHub Projects cards on devbox need gh's read:project scope"), and everything else keeps working. These cards say what happened in `source.event` (`status`, `security`), so a Mac alert rule can single them out; they need the `needs-you` CLI 0.4.0 or later (`needs-you update`).

The full list of cards, keys and settings is in [integrations/github/README.md](../../integrations/github/README.md). If you have many open PRs, `NEEDS_YOU_GITHUB_PR_DAYS` (default 14) skips the ones nobody has touched lately, and at most 20 cards are open at once (`NEEDS_YOU_GITHUB_MAX_CARDS`).

## When it doesn't post

- Run `needs-you-github -v`. It says how many notifications and PRs it saw and any `gh` error. It always exits 0, so cron won't tell you.
- A "need gh's ... scope" card: run the `gh auth refresh -s ...` command it names. The poller checks again within the hour, and the card goes.
- `gh` errors (logged out, token expired): fix with `gh auth login`. After 3 failed runs in a row it posts one low card, "GitHub alerts stopped on devbox", which clears on the next good run.
- Cards from the dry run but nothing on the Mac: the hub isn't reachable from this machine; see [troubleshooting](troubleshooting.md#a-sender-cant-reach-the-hub).
- To start over, delete `~/.local/state/needs-you/github.json`. Cards it posted expire within 15 minutes on their own (a merged-PR card after a day); a "GitHub alerts stopped" or "... cards need gh's ... scope" card has no expiry, so dismiss it on the Mac.
