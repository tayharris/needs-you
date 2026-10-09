# Jira

Get a card when something happens on a Jira issue assigned to you: someone moves it to another status, comments on it, mentions you, or assigns it to you. One card per issue, updated in place, with a button that opens the issue (or the comment). It clears itself when the issue is done, when it's no longer yours, when you act on it yourself (comment, move it), or after a day with nothing new. Works with Jira Cloud and Jira Data Center 8.14 or later.

A small poller, `needs-you-jira`, does this from **one** machine every 5 minutes, with a token you give it. Nothing in Jira changes: no webhook, no Jira app, no public endpoint. It's off until you set it up.

## Before you start

- A sender machine that's always on, such as a devbox: run an invite link's installer there first ([add-a-sender.md](add-a-sender.md)). `needs-you doctor` should show no `FAIL`.
- `python3` 3.9 or newer.
- A token for Jira:
  - **Jira Cloud** (`https://acme.atlassian.net`): an API token from [id.atlassian.com → Security → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens), plus the email you sign in with.
  - **Jira Data Center**: a personal access token (your avatar → Profile → Personal Access Tokens). Give it an expiry you'll remember.

## Set up

```bash
# 1. Install the poller (or `install -m 755 integrations/jira/needs-you-jira ~/.local/bin/` from a checkout)
curl -fsSL https://raw.githubusercontent.com/tayharris/needs-you/main/integrations/jira/needs-you-jira -o ~/.local/bin/needs-you-jira && chmod 755 ~/.local/bin/needs-you-jira

# 2. Save the token in a file only you can read (it isn't echoed or kept in your shell history)
mkdir -p ~/.config/needs-you && (umask 077; printf 'Jira token: '; read -rs t; printf '%s\n' "$t" > ~/.config/needs-you/jira-token); echo

# 3. Turn it on: your site, and for Jira Cloud your email
cat >> ~/.config/needs-you/env <<'EOF'
NEEDS_YOU_JIRA_SITE=https://acme.atlassian.net
NEEDS_YOU_JIRA_EMAIL=me@acme.example
EOF

# 4. Check it can read Jira (the first run only records your open issues; it posts nothing)
~/.local/bin/needs-you-jira -v

# 5. Run it every 5 minutes
(crontab -l 2>/dev/null; echo '*/5 * * * * $HOME/.local/bin/needs-you-jira >/dev/null  # needs-you-jira') | crontab -
```

For **Data Center**, step 3 is just the base URL (`NEEDS_YOU_JIRA_SITE=https://jira.acme.example`, with a context path such as `/jira` if yours has one); the poller uses your personal access token as a Bearer token. Set `NEEDS_YOU_JIRA_AUTH=dc` if your Data Center site happens to end in `.atlassian.net`, or `cloud` for a Cloud site on a custom domain. If the server's certificate comes from your company's own CA, put that CA in a PEM file and set `NEEDS_YOU_JIRA_CA_FILE=/path/to/acme-ca.pem`: the poller then trusts only that CA, and still checks the certificate and host name.

The token file must be yours and mode `600`. If it isn't, the poller refuses it and tells you to `chmod 600` it: anyone who can read it can act as you in Jira.

Prefer a systemd user timer or, on a Mac, a LaunchAgent? Use the files in [integrations/jira](../../integrations/jira/README.md) instead of step 5.

## Check it works

Ask a teammate to comment on one of your issues (or comment from another account). Within 5 minutes a card "New comment on ACME-123: *summary*" appears on your Mac; **Open** goes straight to the comment. Reply in Jira, and the card goes on the next run, since you acted last.

`needs-you-jira --dry-run -v` shows what it would post right now without posting anything.

## Tune it

Settings go in `~/.config/needs-you/env`:

```bash
NEEDS_YOU_JIRA_STATUSES=Blocked=urgent,In Review=normal,QA Failed=urgent,*=low   # which statuses matter, and how much
NEEDS_YOU_JIRA_PROJECTS=ACME=work:normal,OPS=work:urgent                         # only these projects; context and base priority
NEEDS_YOU_JIRA_EVENTS=-assigned                                                  # turn events off (status, comment, assigned, mention)
NEEDS_YOU_JIRA_JQL_EXTRA='labels != noise'                                       # narrow it further with JQL
NEEDS_YOU_JIRA_WATCHING=1                                                        # issues you watch count too
```

`NEEDS_YOU_JIRA_JQL_EXTRA` is added in parentheses with `AND`, so it can only narrow what you get, never widen it to other people's issues. It's refused if its quotes or parentheses don't balance or it has `ORDER BY`.

How loudly a card arrives is up to the Mac: each card carries what happened as its event (`status`, `comment`, `assigned`, `mention`), so an alert rule on the Mac can, say, make comments always wait for later, or one issue urgent while you're on it ([Mac app](mac-app.md#focus-heads-down-except-what-you-choose)).

The full list of cards, keys and settings is in [integrations/jira/README.md](../../integrations/jira/README.md). At most 20 cards are open at once (`NEEDS_YOU_JIRA_MAX_CARDS`).

## When it doesn't post

- Run `needs-you-jira -v`. It says how many issues changed and how many are open, and any Jira error. It always exits 0, so cron won't tell you.
- See [troubleshooting](troubleshooting.md#jira-poller) for token, permission and JQL errors. After 3 failed runs in a row it posts one low card, "Jira alerts stopped on devbox", which clears on the next good run.
- Cards from the dry run but nothing on the Mac: the hub isn't reachable from this machine; see [troubleshooting](troubleshooting.md#a-sender-cant-reach-the-hub).
- To start over, delete `~/.local/state/needs-you/jira.json`. The next run records your issues again without posting, and cards it posted expire within 15 minutes on their own.
