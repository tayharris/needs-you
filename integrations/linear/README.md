# needs-you from Linear

`needs-you-linear` is a poller for one sender machine (an always-on devbox is best) that turns your Linear inbox into needs-you cards: issues assigned to you, new comments and replies, mentions, and status changes. One card per issue, updated in place as new events arrive, cleared when you read, archive or snooze the notification in Linear, when the issue is done or no longer yours, or after 24 hours with nothing new. It runs from cron, a systemd user timer or a LaunchAgent every 5 minutes and makes only outbound HTTPS calls to `api.linear.app`. No webhook, no public endpoint.

It is opt-in: until a Linear personal API key is configured it does nothing.

Setup is in [docs/guides/linear.md](../../docs/guides/linear.md).

## Files

| File | What |
|---|---|
| [`needs-you-linear`](needs-you-linear) | The poller. Python 3.9+ stdlib, one file. Copy it to `~/.local/bin/` |
| [`crontab.example`](crontab.example) | The cron line (Linux) |
| [`systemd/needs-you-linear.service`](systemd/needs-you-linear.service), [`.timer`](systemd/needs-you-linear.timer) | A systemd user timer instead of cron |
| [`io.needs-you.linear.plist`](io.needs-you.linear.plist) | A LaunchAgent (macOS) |

## How it works

Each run makes one GraphQL request to `https://api.linear.app/graphql` (Linear allows 1,500 an hour; a run every 5 minutes uses 12):

1. **New notifications:** `notifications` updated since the last run (5 minutes of overlap; the first run looks back 24 hours), archived ones included, up to 5 pages of 50. Only issue notifications in the categories `assignments`, `commentsAndReplies`, `mentions` and `statusChanges` count; reactions, subscriptions and the rest are ignored.
2. **The notifications behind open cards**, looked up by id, so reading one in Linear clears its card even when the feed doesn't show the change.
3. **Your assigned issues:** `viewer.assignedIssues`, not done or canceled. An issue that was in this list and leaves it (done, canceled, or unassigned from you) clears its card. If you have more than 250, nothing is cleared that way.
4. **Cards:** one per issue with at least one open notification (not read, archived or snoozed) from the last 24 hours. The title says the latest event, the body counts them ("2 new comments, 1 mention, status In Review"). A card is re-posted on every run while it holds, with `--expires-in` of 3x the interval (15 minutes), so a poller that stops leaves nothing stale behind. Re-posting identical content doesn't re-animate a card; a new event changes the title and body of the same card. When nothing holds it up, it resolves the key.

It posts through the `needs-you` CLI, so the outbox and hub failover apply. While the outbox has a backlog (no hub reachable), unchanged cards aren't renewed, so a sleeping Mac doesn't fill it.

What it posted is in `~/.local/state/needs-you/linear.json` (mode 600; no key, just keys, content hashes, the time of the last run, and the notifications behind open cards with their issue's cleaned title, status and link).

## Cards

`<ctx>` is `work` or `personal` (see `NEEDS_YOU_LINEAR_TEAMS`). Key: `<ctx>:linear:<ISSUE-ID>`, for example `work:linear:ACME-123`.

| Latest event (`source.event`) | Linear category | Title | Priority floor | Link |
|---|---|---|---|---|
| `assigned` | `assignments` | Assigned to you: ACME-123: *title* | low | Issue |
| `status` | `statusChanges` | ACME-123 moved to *In Review*: *title* | low | Issue |
| `comment` | `commentsAndReplies` | New comment on ACME-123: *title* | normal | Comment (the notification's link to the comment) |
| `mention` | `mentions` | You were mentioned in ACME-123: *title* | normal | Comment |
| | the API failed 3 runs in a row | Linear alerts stopped on devbox: check the API key | low | key `<default ctx>:linear:<host>:poller-failing`; clears on the next good run |

A card's priority is the highest of its status rule (`NEEDS_YOU_LINEAR_STATUSES`), its team's base (`NEEDS_YOU_LINEAR_TEAMS`) and the event's floor above. `source.event` lets the Mac's alert rules treat comments and status changes differently (for example `work:linear:` + event `comment` → Always later). At most `NEEDS_YOU_LINEAR_MAX_CARDS` (20) cards are open at once: urgent first, then cards already on the panel.

A card clears when:

- every notification behind it is read, archived or snoozed in Linear (or deleted);
- the issue is done or canceled, or it was assigned to you and no longer is;
- 24 hours pass with nothing new (`NEEDS_YOU_LINEAR_MAX_AGE_H`).

## Config

In `~/.config/needs-you/env` (or the environment).

| Variable | Default | What |
|---|---|---|
| `NEEDS_YOU_LINEAR_KEY_FILE` | `~/.config/needs-you/linear-key` if it exists | The file holding your personal API key. It must be a regular file (not a symlink), owned by you, with no group or other access (mode 600); otherwise the poller refuses it and posts nothing |
| `NEEDS_YOU_LINEAR_KEY` | none | The key itself, read from the process environment only (never from the env file). Prefer the key file |
| `NEEDS_YOU_LINEAR_CATEGORIES` | all | Events to post: `assigned,status,comment,mention` or Linear's names (`assignments,statusChanges,commentsAndReplies,mentions`); or turn some off: `-mention` |
| `NEEDS_YOU_LINEAR_STATUSES` | `*=low` | Priority by the issue's current status: `Blocked=urgent,In Review=normal,*=low`. `Backlog=off` posts no status-change card for that status (comments and mentions still do) |
| `NEEDS_YOU_LINEAR_TEAMS` | every team, `NEEDS_YOU_DEFAULT_CONTEXT` (else `work`), base `low` | Per team key: context and base priority, `ACME=work:normal,OPS=work:urgent`. When set, only these teams are watched |
| `NEEDS_YOU_LINEAR_INTERVAL` | `5` | Minutes between runs; cards expire after 3x this. Match your schedule |
| `NEEDS_YOU_LINEAR_MAX_CARDS` | `20` | Cap on open cards from this poller |
| `NEEDS_YOU_LINEAR_MAX_AGE_H` | `24` | A card with nothing new for this many hours resolves |
| `NEEDS_YOU_LINEAR_API` | `https://api.linear.app/graphql` | The GraphQL URL: `https`, or `http` to a loopback address (tests) |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | Path to the CLI |

Run it on **one** machine. Keys dedupe, so a second machine wouldn't duplicate cards, but the two would fight over resolves when their views differ for a minute.

## Safety

- The key is a Linear personal API key (Linear: Settings → Account → Security & access → Personal API keys). Give it read access only if Linear offers the choice; the poller only reads. It is sent as the `Authorization` header (no `Bearer`) to the API URL only, redirects are never followed, and it is never logged, printed, written to the state file, put on a card or passed to another program; any error text that repeats it is scrubbed. The shared redaction catches `lin_api_` and `lin_oauth_` keys in any card text.
- Everything from Linear is untrusted data. Only issue titles and status names reach a card, with control, bidi and zero-width characters removed, token-shaped text redacted, and truncated (titles to 70 characters); the status name in the body is markdown-escaped. Comment bodies are never read. Links are kept only when they are `https://linear.app/<workspace>/issue/<that issue's id>...`; `linear://` is not used. "Open links in the desktop app" in Linear opens them in the app.
- It always exits 0. When the API fails (network, a revoked key, a rate limit), it changes nothing (no posts, no resolves), writes one line to stderr, and after 3 failed runs in a row posts the single low `poller-failing` card.

## Test

```bash
/usr/bin/python3 -m unittest tests.test_linear     # a fake Linear GraphQL server against a real local hub
needs-you-linear --dry-run -v                       # your real Linear inbox: prints what it would post, changes nothing
```
