# needs-you from GitHub

`needs-you-github` is a poller for one sender machine (an always-on devbox is best) that turns the GitHub events that wait on **you** into needs-you cards: review requests, deployments waiting for your approval, failed CI on your branches, mentions, and the state of your own open PRs. It runs from cron, a systemd user timer or a LaunchAgent every 5 minutes, and makes only outbound HTTPS calls through `gh`. No webhook, no public endpoint, no token of its own.

Setup is in [docs/guides/github.md](../../docs/guides/github.md).

## Files

| File | What |
|---|---|
| [`needs-you-github`](needs-you-github) | The poller. Python 3.9+ stdlib, one file. Copy it to `~/.local/bin/` |
| [`crontab.example`](crontab.example) | The cron line (Linux) |
| [`systemd/needs-you-github.service`](systemd/needs-you-github.service), [`.timer`](systemd/needs-you-github.timer) | A systemd user timer instead of cron |
| [`io.needs-you.github.plist`](io.needs-you.github.plist) | A LaunchAgent (macOS) |

## How it works

Each run:

1. **Notifications:** `gh api -i /notifications` (unread threads), with `If-Modified-Since` from the last answer, at most once per `X-Poll-Interval` (GitHub says 60 s). A `304` costs no rate limit and keeps the last list. Every 30 minutes it fetches without the condition, so threads you've read drop off.
2. **Your PRs:** one `gh api graphql` call: your open PRs updated in the last 14 days (review decision, mergeable, the checks on the head commit), and the open PRs that still request your review.
3. **Cards:** one per condition, with a stable key. A card is re-posted on every run while its condition holds, with `--expires-in` of 3x the interval (15 minutes), so a poller that stops (machine off, gh logged out) leaves nothing stale behind. Re-posting identical content doesn't re-animate a card. When the condition clears, it resolves the key.

It posts through the `needs-you` CLI, so the outbox and hub failover apply. While the outbox has a backlog (no hub reachable), unchanged cards aren't renewed, so a sleeping Mac doesn't fill it.

What it posted is in `~/.local/state/needs-you/github.json` (mode 600; no tokens, just keys, content hashes and the last notification list).

## Cards

`<ctx>` is `work` or `personal` (see `NEEDS_YOU_GITHUB_CONTEXTS`).

| Reason | Source | Title | Priority | Key | Links and steps | Clears when |
|---|---|---|---|---|---|---|
| `review` | `review_requested` notification | Review owner/repo#12: *title* | normal | `<ctx>:gh:owner/repo#12:review` | PR; steps: Read the diff (Files), Approve or request changes | the thread is read, or the PR no longer requests your review (you reviewed, it closed) |
| `deploy` | `approval_requested` notification | Approve the deploy: owner/repo: *title* | **urgent** | `<ctx>:gh:deploy:owner/repo:<run id>` | Run; steps: Open the run and choose **Review deployments**, Approve or reject | the thread is read |
| `ci` | `ci_activity` notification whose latest run on that branch **failed** | CI failed on *branch*: owner/repo: *title* | normal | `<ctx>:gh:owner/repo:ci:<branch>` | Runs for the branch | a later run on the branch didn't fail, or the thread is read. Skipped for the head branch of one of your open PRs: the `checks` card covers it |
| `mention` | `mention`, `team_mention` | You were mentioned in owner/repo#7: *title* | low | `<ctx>:gh:owner/repo#7:mention` | Open | the thread is read |
| `assign` | `assign` | Assigned to you: owner/repo#8: *title* | low | `<ctx>:gh:owner/repo#8:assign` | Open | the thread is read |
| `merge` | your PR: approved, checks green (or none), mergeable | Merge owner/repo#20: *title* | normal | `<ctx>:gh:owner/repo#20:merge` | PR | merged, closed, or no longer approved/green |
| `changes` | your PR: changes requested | Changes requested on owner/repo#21: *title* | normal | `<ctx>:gh:owner/repo#21:changes` | PR; steps: Read the review, Push the changes, Re-request review | the review decision changes |
| `conflict` | your PR: `mergeable: CONFLICTING` | Resolve conflicts in owner/repo#22: *title* | normal | `<ctx>:gh:owner/repo#22:conflict` | Conflicts, PR; steps: Resolve the conflicts, Push | mergeable again |
| `checks` | your PR: check rollup `FAILURE`/`ERROR` | Fix failing checks on owner/repo#23: *title* | normal | `<ctx>:gh:owner/repo#23:checks` | Checks, PR; a step per failing check (up to 3) linking its logs | checks pass |
| | `gh` failed 3 runs in a row | GitHub alerts stopped on devbox: check gh | low | `<default ctx>:gh:<host>:poller-failing` | body: run `gh auth status` | the next successful run |

Draft PRs, `subscribed`, `author`, `state_change`, `security_alert` and other reasons are ignored. At most `NEEDS_YOU_GITHUB_MAX_CARDS` (20) cards are open at once: urgent first, then cards already on the panel, so the 60-item volume guard is never hit and the panel isn't churned.

## Config

In `~/.config/needs-you/env` (or the environment). All optional.

| Variable | Default | What |
|---|---|---|
| `NEEDS_YOU_GITHUB_INCLUDE` | all | Comma list of `owner` or `owner/repo` to watch |
| `NEEDS_YOU_GITHUB_EXCLUDE` | none | Comma list of `owner` or `owner/repo` to ignore; wins over include |
| `NEEDS_YOU_GITHUB_CONTEXTS` | `NEEDS_YOU_DEFAULT_CONTEXT`, else `work` | Per owner: `acme=work,my-user=personal`. Also the key prefix |
| `NEEDS_YOU_GITHUB_REASONS` | all | The reasons above to post, e.g. `review,deploy,checks`; or turn some off: `-mention,-assign` |
| `NEEDS_YOU_GITHUB_INTERVAL` | `5` | Minutes between runs; cards expire after 3x this. Match your schedule |
| `NEEDS_YOU_GITHUB_PR_DAYS` | `14` | Only your PRs updated in the last N days (stale PRs aren't gates) |
| `NEEDS_YOU_GITHUB_MAX_CARDS` | `20` | Cap on open cards from this poller |
| `NEEDS_YOU_GITHUB_GH` | `gh` on `PATH` | Path to `gh` |
| `NEEDS_YOU_BIN` | `needs-you` on `PATH`, else `~/.local/bin/needs-you` | Path to the CLI |

Run it on **one** machine. Keys dedupe, so a second machine wouldn't duplicate cards, but the two would fight over resolves when their views differ for a minute.

## Safety

- Auth is your `gh` login (`gh auth login`); the poller never reads, stores or prints a token. It needs the `notifications` and `repo` scopes that `gh auth login` grants.
- Everything from GitHub is untrusted data. Only PR/issue titles reach a card, with control, bidi and zero-width characters removed and truncated to 70 characters; check names go into steps with markdown escaped. Bodies, comments and review text are never copied. Links are built from the repo URL and number, and only `https://` links from GitHub are kept.
- It always exits 0. When `gh` is missing or failing, it changes nothing (no posts, no resolves), writes one line to stderr, and after 3 failed runs in a row posts the single low `poller-failing` card.

## Test

```bash
/usr/bin/python3 -m unittest tests.test_github     # fake gh + fixture JSON against a real local hub
needs-you-github --dry-run -v                       # your real GitHub, prints what it would post, changes nothing
```
