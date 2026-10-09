# needs-you from Jira

`needs-you-jira` is a poller for one sender machine (an always-on devbox is best) that turns changes on the Jira issues assigned to **you** into needs-you cards: an issue moved to a new status, a new comment, a comment that mentions you, an issue newly assigned to you. It works with Jira Cloud and Jira Data Center 8.14 or later, runs from cron, a systemd user timer or a LaunchAgent every 5 minutes, and makes only outbound HTTPS calls to your Jira. No webhook, no public endpoint, no Jira app.

It's opt-in: until `NEEDS_YOU_JIRA_SITE` is set it does nothing. Setup is in [docs/guides/jira.md](../../docs/guides/jira.md).

## Files

| File | What |
|---|---|
| [`needs-you-jira`](needs-you-jira) | The poller. Python 3.9+ stdlib, one file. Copy it to `~/.local/bin/` |
| [`crontab.example`](crontab.example) | The cron line (Linux) |
| [`systemd/needs-you-jira.service`](systemd/needs-you-jira.service), [`.timer`](systemd/needs-you-jira.timer) | A systemd user timer instead of cron |
| [`io.needs-you.jira.plist`](io.needs-you.jira.plist) | A LaunchAgent (macOS) |

## How it works

Each run:

1. **Who you are:** `GET /myself` (cached for a day), so it can tell your own changes and mentions of you from everyone else's.
2. **What changed:** one search, `assignee = currentUser() AND updated >= "-15m"` (the window grows to cover the time since the last good run, up to 24 h), with each issue's changelog. Cloud: `GET /rest/api/3/search/jql`, paged with `nextPageToken`. Data Center: `GET /rest/api/2/search`, paged with `startAt`.
3. **What's still yours:** a second search, `assignee = currentUser() AND statusCategory != Done`. An issue that was yours and isn't in it any more was unassigned (or left your filter), and its card resolves.
4. **Comments:** only for an issue whose `updated` moved since the last run, `GET /issue/<KEY>/comment` (newest 50). New comments are the ones with a higher id than the last one seen. Their bodies are searched for a mention of you and never copied anywhere.
5. **Diff:** the status, assignee and comments are compared with the last run's saved state. The latest event by **someone else** sets the issue's card. A later change of **yours** (a comment, a transition, assigning it to yourself) clears it: you've already acted.
6. **Cards:** one per issue, updated in place. A card is re-posted on every run while it stands, with `--expires-in` of 3x the interval (15 minutes), so a poller that stops leaves nothing stale behind. Re-posting identical content doesn't re-animate a card.

The **first run** only records your open issues and posts nothing, so installing it never posts a burst of old changes. The same goes for issues that come into view because you changed `NEEDS_YOU_JIRA_PROJECTS`, `_JQL_EXTRA` or `_WATCHING`.

It posts through the `needs-you` CLI, so the outbox and hub failover apply. While the outbox has a backlog (no hub reachable), unchanged cards aren't renewed, so a sleeping Mac doesn't fill it.

What it remembers is in `~/.local/state/needs-you/jira.json` (mode 600): your account id, each open issue's key, status, summary, `updated` and last comment id, and what it posted. No token and no comment text.

## Cards

`<ctx>` is `work` or `personal` (see `NEEDS_YOU_JIRA_PROJECTS`). `<site>` is the part before `.atlassian.net` (`acme`), or the whole Data Center host name (`jira.acme.example`).

| Event (`source.event`) | When | Title | Priority floor |
|---|---|---|---|
| `status` | someone else moved the issue to another status (not Done) | ACME-123 moved to In Review: *summary* | the status rule, else low |
| `comment` | someone else commented | New comment on ACME-123: *summary* | normal |
| `mention` | someone else's new comment mentions you | You were mentioned on ACME-123: *summary* | normal |
| `assigned` | someone else assigned you the issue (not you, and not an issue you created assigned to yourself) | Assigned to you: ACME-123: *summary* | low |
| | the poller couldn't read Jira 3 runs in a row | Jira alerts stopped on devbox: check its config | low |

- **Key:** `<ctx>:jira:<site>:ACME-123`, one per issue; the failing card is `<default ctx>:jira:<site>:<host>:poller-failing`.
- **Link:** `https://acme.atlassian.net/browse/ACME-123`, with `?focusedCommentId=<id>` for a comment or mention.
- **Body:** a count line, such as "2 new comments, status Blocked". Comment text is never copied, so a ticket can't put words or links on your card.
- **Priority:** the highest of the issue's status rule (`NEEDS_YOU_JIRA_STATUSES`), its project's base (`NEEDS_YOU_JIRA_PROJECTS`) and the event's floor above.
- **Resolves when** the issue reaches the Done status category, is no longer assigned to you (or no longer matches your filter), when you made the latest change, or 24 hours after its latest event with nothing new.

At most `NEEDS_YOU_JIRA_MAX_CARDS` (20) cards are open at once: urgent first, then cards already on the panel, so the panel isn't churned.

What it doesn't see: mentions on issues that are neither assigned to you nor watched by you (`NEEDS_YOU_JIRA_WATCHING=1` adds watched issues), mentions in descriptions, and changes on an issue that happened while it wasn't yours.

## Config

In `~/.config/needs-you/env` (or the environment).

| Variable | Default | What |
|---|---|---|
| `NEEDS_YOU_JIRA_SITE` | unset: off | `https://acme.atlassian.net`, or your Data Center base URL (with its context path, if any). `https://` only |
| `NEEDS_YOU_JIRA_AUTH` | `cloud` for `*.atlassian.net`, else `dc` | `cloud`: Basic auth with your email and an [API token](https://id.atlassian.com/manage-profile/security/api-tokens). `dc`: a personal access token as a Bearer token (Data Center 8.14+) |
| `NEEDS_YOU_JIRA_EMAIL` | none | Your Atlassian account email (Cloud only) |
| `NEEDS_YOU_JIRA_TOKEN_FILE` | `~/.config/needs-you/jira-token` | The file holding the token, alone on one line. It must be yours and mode `600` (or `400`): a file anyone else can read or write is refused. There is no environment variable for the token itself |
| `NEEDS_YOU_JIRA_CA_FILE` | unset (the system's CAs) | A PEM file with the CA that signs a Data Center server's certificate, for a private CA. When set, only it is trusted; the certificate and host name are still checked |
| `NEEDS_YOU_JIRA_EVENTS` | `status,comment,assigned,mention` | The events to post; or turn some off: `-comment,-assigned` |
| `NEEDS_YOU_JIRA_STATUSES` | every status, low | `Blocked=urgent,In Review=normal,Backlog=off,*=low`: the priority for an issue in that status (names aren't case-sensitive), `off` for no status card. A status not listed takes the `*` rule; with no `*`, a move to an unlisted status posts no card. The rule also raises the priority of comments on an issue in that status |
| `NEEDS_YOU_JIRA_PROJECTS` | every project, default context, low | `ACME=work:normal,OPS=work:urgent`: only these projects, each one's context (and key prefix) and base priority |
| `NEEDS_YOU_JIRA_JQL_EXTRA` | none | More JQL to narrow the searches, such as `labels != noise` (see below) |
| `NEEDS_YOU_JIRA_WATCHING` | `0` | `1`: issues you watch count too (status, comment and mention cards; no `assigned`) |
| `NEEDS_YOU_JIRA_INTERVAL` | `5` | Minutes between runs; cards expire after 3x this. Match your schedule |
| `NEEDS_YOU_JIRA_MAX_CARDS` | `20` | Cap on open cards from this poller |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | Path to the CLI |

### `NEEDS_YOU_JIRA_JQL_EXTRA`

It's added to **both** searches as `AND (<your JQL>)`, after the poller's own clauses and before its `ORDER BY`. The parentheses mean it can only narrow what the poller sees: `labels = a OR labels = b` stays inside them and can't widen `assignee = currentUser()` to other people's issues. A leading `AND` is dropped, so `'AND labels != noise'` works too.

It's refused, and the poller does nothing until it's fixed, when it has unbalanced quotes or parentheses (a stray `)` could close the poller's own group), `ORDER BY`, a line break or control character, or more than 500 characters. JQL that Jira itself rejects shows up as Jira's error message in the poller's log, and after 3 runs as the "Jira alerts stopped" card.

An issue that stops matching it (say, it gets the `noise` label) counts as no longer yours: its card resolves.

Run it on **one** machine. Keys dedupe, so a second machine wouldn't duplicate cards, but the two would fight over resolves when their views differ for a minute.

## Safety

- The token lives only in its mode-600 file. It's never logged, printed, put in an error message, a card or the state file. Redirects aren't followed (a redirect would carry the `Authorization` header elsewhere, such as an SSO login page); a redirect is reported as an error instead. The site must be `https://`.
- Everything from Jira is untrusted data. Only the issue summary (truncated to 70 characters) and status name reach a card, with control, bidi and zero-width characters removed and token-shaped text redacted. Comment bodies are read only to look for a mention of you; descriptions are never read. Links are built from your site URL and the issue key.
- It always exits 0. When Jira or the config is broken it changes nothing (no posts, no resolves), writes one line to stderr, and after 3 failed runs in a row posts the single low `poller-failing` card, which clears on the next good run.

## Test

```bash
/usr/bin/python3 -m unittest tests.test_jira      # a fake Jira (Cloud and Data Center shapes) over TLS, against a real local hub
needs-you-jira --dry-run -v                       # your real Jira: prints what it would post, changes nothing
```

The API calls, paging and response shapes follow Atlassian's documentation; the fake Jira in the tests mirrors them.
