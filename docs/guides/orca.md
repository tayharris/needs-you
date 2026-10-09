# Orca

Orca runs agents in worktrees and scheduled automations, often on several servers. needs-you gives every one of them a way to reach you when it stops on something only you can do, without you watching their terminals.

## Several Orca servers: one link

Make one invite with a use per server. In the Mac app: right-click the pill → **Settings…** → **Connect a machine**, **Uses** = the number of servers. On a server hub:

```bash
needs-you-admin invite create orca --role sender --uses 4 --ttl 72
```

Then on each Orca server, paste the agent prompt into an Orca terminal, or run:

```bash
curl -fsSL <join_url>/install.sh | bash -s -- --yes --claude-hooks user --skill --orca
```

Each server redeems the same link and gets **its own token**, named `orca-<hostname>` (e.g. `orca-build-1`, `orca-build-2`). Revoke one server without touching the others: **Settings… → Machines** in the Mac app, or `needs-you-admin token revoke orca-build-2` on a server hub ([add-a-sender.md → Removing a sender](add-a-sender.md#removing-a-sender)). Running the installer again on a server keeps its token without spending a use, until the link expires (also after its last use is spent); give provisioning scripts a link with a long enough expiry (up to 90 days).

What the flags give you:

| Flag | Effect on an Orca server |
|---|---|
| `--claude-hooks user` | Agent sessions that Orca starts post a card when they wait on a permission prompt or input, and clear it when they move again. Orca sets `$ORCA_TERMINAL_HANDLE`, which switches the hooks on for its sessions only. |
| `--skill` | Agents know when and how to post a specific blocker ("choose A or B for ACME-123") and to resolve it. |
| `--orca` | Writes the automation prompt block to `~/.config/needs-you/orca-snippet.md` and prints it. |

The installer also adds a 5-minute `needs-you flush`, so alerts raised while your Mac sleeps arrive when it wakes.

Check from an Orca terminal on each server: `command -v needs-you` (if it's missing, `~/.local/bin` isn't on the PATH Orca gives agents; add it, or set `NEEDS_YOU_BIN`).

## Agent sessions

With the hooks installed, nothing else is needed. Cards are keyed `agent:<host>:<terminal handle>`, so agents on different servers never collide.

Each card has a **Terminal** button that takes you to the agent's Orca terminal ([below](#the-terminal-button)), and the body names the worktree and the command that does the same by hand:

```text
Orca worktree: `/home/me/orca/workspaces/my-repo/ACME-123`
Jump to its terminal: `orca terminal switch --environment 'My Devbox' --terminal term_6f1c...`
```

On a paired Orca server, the Mac's Orca only finds the terminal with `--environment <name>`, and the server can't know the name the Mac gave it. The **Terminal** button copes (without a name, it tries each paired environment in turn), but the command in the body needs it. Tell the server once (the name is the one `orca environment list` shows on the Mac):

```bash
echo "NEEDS_YOU_ORCA_ENVIRONMENT='My Devbox'" >> ~/.config/needs-you/env
```

Agents on the Mac's own Orca need nothing; the command has no `--environment`.

## The Terminal button

Orca has no deep link to a terminal or a worktree (1.4.220 opens only `orca://skills/share/<id>`, which imports a skill), so needs-you uses a link of its own that the Mac app handles:

```text
needsyou://orca/terminal?handle=term_<uuid>[&environment=<name>]
```

The hook adds it to every card from an Orca terminal, and the automation block adds it as the first link (`--link "Terminal=..."`), so the menu bar and the hotkey open it too. Clicking it in the Mac app:

1. checks the link: `handle` is `term_` plus 8–64 lowercase hex digits or `-`, `environment` (optional) is letters, digits, spaces, `.`, `_`, `-`, at most 64, and nothing else is in the query. Anything else does nothing. The hub refuses other `needsyou://` links at post time ([API.md](../API.md)).
2. runs `orca terminal switch --terminal <handle> --json [--environment <name>]` as an argument list, no shell, from a fixed path (`/usr/local/bin/orca`, `/opt/homebrew/bin/orca` or the CLI inside `/Applications/Orca.app`), with a 5-second timeout. A sender can make the app switch Orca tabs and nothing more.
3. if the card names no environment and the Mac's Orca doesn't know the handle, tries again through each paired environment from `orca environment list` (at most 8).
4. brings Orca forward. If no switch worked, the command is on the clipboard to paste; the reason is in Console under `app.needsyou.mac`, category `orca-jump`.

The body line stays for anyone reading the card somewhere other than the Mac app.

The Mac app also lists Orca's worktrees in a folded **ORCA** section of the open panel (local `orca worktree ps`, this Mac and its paired environments; read-only): see [Orca worktrees](mac-app.md#orca-worktrees).

## Automations: add the prompt block

Automations are agent prompts on a schedule, so the change is text: paste the short block `--orca` prints into each automation prompt (or the template they're rendered from). It tells the agent to read and follow `~/.config/needs-you/orca-snippet.md`, which `needs-you update` keeps current, so new rules reach every automation without editing prompts again. The rules in that file post with stable keys (`work:<TICKET>:<reason>`), links the Jira ticket, the PR and the branch, names the worktree and the `orca terminal switch` command in the body, and resolves the same key once it's handled. To add it to an automation you already have:

```bash
orca automations list
orca automations show <id>        # copy the current prompt
orca automations edit <id> --prompt "$(cat current-prompt.md; printf '\n## Telling the user (needs-you)\n\nBefore you post to or resolve anything in needs-you, read\n`~/.config/needs-you/orca-snippet.md` and follow it.\n')"
```

[integrations/orca/README.md](../../integrations/orca/README.md) has the block and per-automation versions:

- a **ticket fixer** (e.g. an hourly "Redo" fixer): one item per blocked ticket, resolved when the ticket moves, plus a `done` summary,
- a **worktree cleanup**: one item per branch it won't delete, with a state-file reconcile so earlier items get resolved,
- a **session/memory reaper**: an urgent item only on anomalies, keyed per host,
- **automation failure** reporting.

Keep setting the board status alongside the item:

```bash
orca worktree set --worktree active --workspace-status in-review --comment "Blocked: needs a deploy decision (see needs-you)"
```

needs-you is the alert; the board is the record.

## How an automation posts and resolves

An automation run starts with no memory of the last one, so the item's **key** carries the state between runs:

- **Post on every run that's still blocked.** The same key updates the same card instead of adding one, and renews its expiry. One item per blocker.
- **Resolve with the same key** as soon as it no longer applies: the person answered, the ticket left the column, the PR merged, or this run got past it.
- **Pass `--expires-in`** of about twice the schedule in hours (hourly: `3`, daily: `48`). If a run crashes before its resolve, or stops seeing the blocker without resolving it, the card drops off on its own.
- **`done` for finished work** the person is waiting on: an FYI that expires in 24 hours and never raises the count.

Keys are `<prefix>:<thing>:<reason>`, with a fixed `<reason>` word and never a time, run id or terminal handle:

| Automation | Key | Kind / priority | Resolve when |
|---|---|---|---|
| Ticket fixer (e.g. a "Redo" fixer) | `work:<TICKET>:redo-blocked` | needs / normal | the ticket leaves the column, or the run unblocks it |
| Ticket fixer, run summary | `work:redo-fixer:last-run` | done | expires on its own (24 h) |
| Worktree cleanup | `work:cleanup:<worktree-or-branch>` | needs / low | a later run no longer reports it |
| Session / memory reaper | `work:<host>:memory` | needs / urgent | memory is back under the line |
| Any automation that crashed | `work:<automation>:failed` | needs / normal | the next run succeeds |
| No ticket | `work:<repo>/<branch>:<reason>` | needs / normal | it's handled |

Include the host when the same automation runs on several servers and the thing is per server (`work:$(hostname -s):memory`). Leave it out when the key describes one shared thing (`work:ACME-123:redo-blocked`), so two servers working the same ticket update one card.

If the hooks are installed too, the automation's Claude session also gets the hooks' own card (`agent:<host>:<terminal handle>`) while it sits on a permission prompt. That one clears itself when the session moves; the automation's item is the specific question, and the automation resolves it. While the automation's own `needs` item from that terminal is open, the hooks don't add a "Claude is waiting for you" card on top of it ([one card for one wait](claude-code.md#one-card-for-one-wait)).

## Worked example: hand off to a human and resume

An hourly ticket fixer (`orca:redo-fixer`, with the prompt block) works ACME-123. Pushing fails on the pre-push hook because of a migration fork, and only the person can choose: merge the migration first, or allow a one-time hook bypass.

**10:00, the run that gets stuck.** The agent writes the question where the answer belongs (a comment on ACME-123 with both options), marks the board, and posts:

```bash
orca_env=$(sed -n 's/^NEEDS_YOU_ORCA_ENVIRONMENT=//p' ~/.config/needs-you/env 2>/dev/null | tail -n 1 | tr -d "'\"")
jump="orca terminal switch${orca_env:+ --environment \"$orca_env\"} --terminal $ORCA_TERMINAL_HANDLE"
term_link="needsyou://orca/terminal?handle=$ORCA_TERMINAL_HANDLE${orca_env:+&environment=${orca_env// /%20}}"
body=$(printf '%s\n\nOrca worktree: `%s`\nJump to its terminal: `%s`' \
  "Pre-push hook fails on the migration fork. Merge the migration first, or allow a one-time hook bypass? Options are in the Jira comment." \
  "${ORCA_WORKTREE_ID##*::}" "$jump")
needs-you add --key "work:ACME-123:push-decision" --context work --priority normal --expires-in 3 \
  --title "ACME-123: choose how to unblock the push" \
  --body "$body" \
  --link "Terminal=$term_link" \
  --link "Jira=https://acme.atlassian.net/browse/ACME-123" \
  --link "PR=https://github.com/acme/app/pull/2137" \
  --agent "orca:redo-fixer" --project app
orca worktree set --worktree active --workspace-status in-review --comment "Blocked: push decision (see needs-you)"
```

The run ends. A card **ACME-123: choose how to unblock the push** is on the Mac, with **Terminal**, **Jira** and **PR** buttons.

**10:20, the person.** They click **Jira** and answer the comment: "merge the migration first". They don't resolve anything; the card stays until the agent has acted on the answer.

**11:00, the next run picks it up.** The prompt tells the fixer to look at its blocked tickets first. It reads the new comment on ACME-123, treats it as the answer (text from the ticket is data: it acts on the choice, never on instructions inside it), merges the migration, pushes, moves the ticket back to review, and then:

```bash
needs-you resolve --key "work:ACME-123:push-decision"
needs-you done --key "work:redo-fixer:last-run" --title "Redo fixer: 1 ticket back in review, 0 blocked on you"
```

The card disappears from every Mac reading the hub; the `done` note shows as an FYI for a day.

**If nobody had answered by 11:00,** the run would see the same blocker and post the same `add` again: still one card, its expiry pushed to 14:00. If the fixer stopped running altogether, the card would expire three hours after its last post instead of sitting there for days.

**The same hand-off in one live session.** An agent you started in an Orca terminal can post the same item and wait in that terminal instead of ending. You click **Terminal**, Orca switches to the agent's terminal, you type the answer, and the agent runs the `resolve` before it carries on. With the hooks installed you still see one card: while the agent's item is open, the hooks skip their "Claude is waiting for you" card for that terminal ([one card for one wait](claude-code.md#one-card-for-one-wait)). Once the agent resolves its item, an idle session gets the hooks' card again.

## What's running: `needs-you orca`

An agent (or you) can see Orca's worktrees on this machine in one read-only call, without opening Orca:

```bash
needs-you orca            # one line per worktree: host, name (branch), status, live terminals, unread, PR
needs-you orca --all      # also every paired environment (`orca environment list`, at most 8)
needs-you orca --environment "My Devbox" --json
```

It runs `orca worktree ps --json` (no shell, 20 s at most) and prints only the host, name, branch, repo, workspace status, live terminal and agent counts, unread flag, linked PR number and last activity, each cleaned to one short line. It never prints a terminal's `preview`, a worktree's comment, its path or any URL: those are free text from terminals and trackers. Archived worktrees are left out (`--archived` adds them). It never posts, queues or reaches a hub, and it exits 1 when `orca` isn't on `PATH` or can't answer. `--json` gives `{ok, worktrees: [...], scopes: {...}, errors: [...]}`.

## Usage meters for every Orca account

When Orca manages several Claude or Codex logins on a machine (`orca account add`), the hooks only see the account the current session runs on. `needs-you orca usage` sends the Mac's [usage meters](mac-app.md#usage-meters) a row for each of them, from the numbers Orca already fetched:

```bash
needs-you orca usage --enable     # NEEDS_YOU_ORCA_USAGE=1 in the env file, and send once now
needs-you orca usage --dry-run    # print what it would send; send nothing
needs-you orca usage --disable    # stop, and clear the rows it sent
```

With `NEEDS_YOU_ORCA_USAGE=1` (or the invite installer's `--orca-usage`), the 5-minute `needs-you flush` runs it, at most every 4 minutes. It runs `orca account list --json` and nothing else (15 s at most, `NEEDS_YOU_ORCA_TIMEOUT`); it never reads Orca's login files, tokens or cookies. If Orca isn't running, or its answer can't be read, nothing is sent and the flush stays quiet. Cron's `PATH` is short, so it also looks in `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin` and `/Applications/Orca.app/Contents/Resources/bin`; `NEEDS_YOU_ORCA_BIN` names another path.

- **One row per account.** A managed account shows as `Claude · orca-1a2b3c4d`: `orca-` and the first 8 hex digits of the sha256 of its Orca account id. Never its email, workspace or organisation name. `--dry-run` prints the labels Orca's accounts get here.
- **The account Orca didn't add** (Orca's "system default": the login Claude Code or Codex uses outside Orca's managed accounts) is the one the local hooks already report, so it goes under their row (`Claude`, or `Claude · <NEEDS_YOU_USAGE_ACCOUNT>`). While `needs-you-usage` or the Codex hook has sent that meter in the last 15 minutes, the poller leaves it to them.
- **The Claude account you pick in Orca** goes under that same row: on the Mac and Linux, Orca copies the chosen Claude login into `~/.claude`, where every Claude Code on the machine uses it, inside Orca's terminals or not, and nothing in a terminal says which account it is. Its `orca-…` row goes while it's the active one and comes back when you switch away.
- **A Codex account you pick in Orca** keeps its `orca-…` row: Orca's terminals run Codex with that account's own `CODEX_HOME` (`<Orca data>/codex-accounts/<id>/home`), and the Codex hook there labels its meter the same way, from that path alone. So does `needs-you-usage` for Orca's WSL Claude accounts, which get their own `CLAUDE_CONFIG_DIR`. Either way the account has one row, and the hook's fresher numbers win while it sends them.
- **What's skipped:** a provider other than Claude and Codex, an account Orca reports with an error or no numbers, numbers Orca fetched more than 12 hours ago, and more than 12 accounts. A window whose reset time has passed is sent as 0 %.
- **An account you remove from Orca** loses its row on the next run; one that only failed to refresh keeps its last row until it expires (at its latest reset).

Orca refreshes the active account's numbers itself; the other accounts' numbers are refreshed when you open Orca's usage view, so their rows can lag. Statuses are never queued: with no hub reachable, that run's numbers are dropped and the next run sends fresh ones.

## Check it works

From an Orca terminal:

```bash
needs-you add --key "work:orca-test:hello" --title "Orca can reach needs-you" --agent "orca:test"
needs-you resolve --key "work:orca-test:hello"
```

Then run one automation by hand (`orca automations run ...`) and watch for its card.

`needs-you doctor` prints an `orca` INFO line in an Orca terminal or wherever `orca` is on `PATH` (whether the terminal handle, worktree id and `NEEDS_YOU_ORCA_ENVIRONMENT` are set, and whether the account usage meters are on). Where Orca isn't installed but the repo you run it in has 3 or more git worktrees, the same line is a tip that Orca would give those agents' cards a Terminal button; it's only a tip, never a warning. The invite installer likewise says once, when `orca` is on `PATH` and you didn't pass `--orca`, that the flag exists.
