# Work-tool alerts: tickets, design files, ops, and getting you there

Status (2026-10-09): built: step 2 (the Linear poller, `integrations/linear/`; its GraphQL field names still need a check against a live workspace), step 3 (the Jira poller, `integrations/jira/`; its API calls still need a check against a live Jira), step 4's first two items (host detection with one "go there" button per agent card, `needsyou://app/activate`), step 6 (`integrations/expiry/needs-you-expiry`: TLS certs, domains via RDAP, key dates) and step 7 (GitHub Projects status cards and Dependabot alert cards, opt-in, in `integrations/github/needs-you-github`); the rest is research. Three research passes (ticketing, design and ops sources, deep links into desktop apps) behind the owner's ask: "if something assigned to me moves to a status, or a ticket I'm assigned gets a comment, it pops up, and I can configure which and how loudly". Vendor facts link to vendor docs; a few are marked unverified and need a live check before we build on them.

## How events get in: poll, not webhooks or MCP

- **Webhooks** (Jira, Linear, Figma, Notion, Asana, Shortcut) all need a public HTTPS endpoint. Hubs bind loopback or the tailnet only (hard rule 4), so a webhook needs a relay: a listener behind Tailscale Funnel, or a public mailbox (a Cloudflare Worker queue) that a tailnet poller drains. Either is new public surface and needs an ADR. Keep it for the sources only webhooks can serve (Figma "ready for dev", Notion).
- **Vendor MCP servers** ([Atlassian Rovo MCP](https://support.atlassian.com/security-and-access-policies/docs/understand-atlassian-rovo-mcp-server/), [Linear MCP](https://linear.app/docs/mcp), Slack, Notion) answer requests; they don't watch anything. Watching through them means a scheduled agent run each poll: tokens every run, results that vary between runs (so keys and resolves are unreliable), OAuth refresh, and prompt injection from ticket or message text. Good for *judgement* sources ("does this Slack thread need a reply from me?") as a documented recipe ([below](#c-a-scheduled-agent-with-the-vendors-mcp-server)), never as the watcher.
- **Polling** from a stdlib script, the way `integrations/github/needs-you-github` does it, works with a tailnet-only hub, needs no new dependency and no API change, and a 5-minute poll is fast enough for tickets. It copies the GitHub poller's lifecycle: a stable key per condition, re-post with an expiry of 3x the interval, resolve when the condition clears, a card cap, only titles from vendor text (cleaned and redacted), a `poller-failing` card, back off while the outbox is full, always exit 0.

## Sources, ranked

| # | Source | Verdict | Event source | Auth | Link | Effort |
|---|---|---|---|---|---|---|
| 1 | **Jira** (Cloud and Data Center): assigned issue changed status, new comment, assigned or unassigned, mention | Build | Poll `GET /rest/api/3/search/jql` with `assignee = currentUser() AND updated >= "-15m"` (the old `/search` was removed in 2025; the new one pages with `nextPageToken`); comments only for issues whose `updated` moved. Detect status changes and new comments by diffing against the last run's saved state, not the changelog. A second query, `assignee = currentUser() AND statusCategory != Done`, finds unassigns | Cloud: email + API token (Basic). Data Center 8.14+: PAT as Bearer against `/rest/api/2/search` | `https://acme.atlassian.net/browse/ACME-123` (`?focusedCommentId=<id>` for a comment). No desktop app | M |
| 2 | **Linear**: assignments, comments and replies, mentions, status changes | Built: [needs-you-linear](../../integrations/linear/README.md) | Poll `notifications(filter: {updatedAt: {gt: $since}})`; `IssueNotification.category` is an enum (`assignments`, `commentsAndReplies`, `mentions`, `statusChanges`, ...) and carries `readAt`, `snoozedUntilAt`, `archivedAt`, `url` and the issue. `viewer.assignedIssues` resolves on Done or unassign | Personal API key (no `Bearer` prefix); 1,500 requests an hour ([limits](https://linear.app/developers/rate-limiting)) | `https://linear.app/acme/issue/ACME-123` opens the desktop app when "Open in desktop app" is on. `linear://` is on our allow-list but undocumented: check live before using it | S |
| 3 | **GitHub Projects** status changes on issues assigned to me | Add to the GitHub poller | One GraphQL call for `projectItems` field values; a card when Status moves to a configured value | `gh` | `https` | S |
| 4 | **Sentry**: unresolved issues assigned to me | Build (or a config of the generic poller) | `GET /api/0/organizations/<org>/issues/?query=assigned:me is:unresolved` ([docs](https://docs.sentry.io/api/events/list-an-organizations-issues)) | Token with `event:read` | `https` | S |
| 5 | **GitLab**: MRs to review, mentions, failed pipelines | Build | `glab api todos?state=pending` ([Todos API](https://docs.gitlab.com/api/todos/)); resolve when the to-do is done | The person's `glab` login | `https` | M |
| 6 | **Vercel / Netlify / Fly**: failed production deploys | Config of the generic poller | Vercel `GET /v6/deployments?state=ERROR` ([docs](https://vercel.com/docs/rest-api/deployments/list-deployments)); Netlify's deploys API and `fly releases --json` look similar | Bearer token in a mode-600 file | `https` | S each |
| 7 | **Expiring TLS certs, domains, API keys** | Build | No vendor: `ssl` for `notAfter`, RDAP (HTTPS JSON) for domains, a config list of key dates. Daily | none | `https` | S |
| 8 | **Figma**: comments and mentions on watched files | Maybe | No "my mentions" endpoint: poll `GET /v1/files/:key/comments` for a watch list; keep threads that mention me or reply to me; resolve on `resolved_at`. Tier 2 limits, 5/min on View/Collab seats ([limits](https://developers.figma.com/docs/rest-api/rate-limits/)). "Ready for dev" (`DEV_MODE_STATUS_UPDATE`) is webhook-only | PAT with `file_comments:read`, expires after 90 days at most: the poller warns before expiry | `https://www.figma.com/design/<key>/<name>?node-id=1-3` opens the desktop app with "Open links in desktop app" on. `figma://` is allowed but undocumented: test first | M |
| 9 | **App Store Connect** review state (`REJECTED`, `PENDING_DEVELOPER_RELEASE`) | Maybe | Poll `apps/<id>/appStoreVersions` | ES256 JWT, 20-minute life; stdlib can't sign ES256, so `openssl dgst -sign` plus DER-to-raw. Fiddly, no new dependency | `https` | M |
| 10 | **Shortcut**, **Asana** | When asked | Shortcut: REST v3 search `owner:me !is:done`. Asana: `GET /tasks?assignee=me&modified_since=` plus stories; workspace events need Enterprise+ | Token | `https` | S / M |
| 11 | **Dependabot / Renovate** | Tiny GitHub-poller addition | Their PRs are covered; optionally stop ignoring `security_alert` notifications (critical only, low priority) | `gh` | `https` | S |
| — | Slack mentions and DMs awaiting a reply | Agent recipe only | `search.messages` needs a user token, is Tier 2 and legacy; many workspaces block personal apps; "awaiting reply" is judgement | | `https` permalink (opens the app) | |
| — | Google Docs comments, Notion | Skip, or agent recipe | No cross-file query and OAuth (Docs); webhook-only mentions (Notion). Their own inboxes and emails cover it | | | |
| — | Bitbucket | Skip until asked | No "PRs I review" listing; would be per-repo polling | | | |
| — | Graphite | Covered | Graphite PRs are GitHub PRs | | | |
| — | PagerDuty, Opsgenie, calendar reminders | Skip | They already page or remind; a second place to acknowledge makes it worse | | | |

## Keys, cards and resolves (every ticket source)

- **One card per ticket**, updated in place: `<context>:jira:acme:ACME-123`, `<context>:linear:ACME-123`. A new event re-posts the same key.
- **Title says the latest event:** "ACME-123 moved to In Review: *summary*", "New comment on ACME-123: *summary*". The body is a count line ("2 new comments, status Blocked"); comment bodies are never copied (as in the GitHub poller), so a ticket can't put text or links on a card.
- **Resolve** when the ticket reaches the Done category or is unassigned from me; when I'm the actor of the latest comment or transition (I've already acted); for Linear, when the notification is read, archived or snoozed; and after `MAX_AGE_H` (24) with nothing new.
- **`source.event`** (being added in `tay/session-alert-rules`): `status`, `comment`, `assigned`, `mention`, so the person's rules can treat them differently. See [Configuration](#configuration-and-urgency).

## Configuration and urgency

Two layers, so a sender never has to guess what's urgent to someone:

1. **The poller's config** decides *what* becomes a card and its base priority. Env lines in `~/.config/needs-you/env`, like the GitHub poller:

   ```
   NEEDS_YOU_JIRA_SITE=https://acme.atlassian.net      # or the Data Center base URL
   NEEDS_YOU_JIRA_AUTH=cloud                           # cloud | dc; token in the mode-600 NEEDS_YOU_JIRA_TOKEN_FILE (+ _EMAIL for cloud)
   NEEDS_YOU_JIRA_EVENTS=status,comment,assigned,mention # -mention drops one
   NEEDS_YOU_JIRA_STATUSES=Blocked=urgent,In Review=normal,QA Failed=urgent,*=low
   NEEDS_YOU_JIRA_PROJECTS=ACME=work:normal,OPS=work:urgent   # context + base priority; also the include list
   NEEDS_YOU_JIRA_JQL_EXTRA='AND labels != noise'
   NEEDS_YOU_JIRA_WATCHING=0                           # 1 = also issues I watch
   ```

   Priority is the highest of the status rule, the project's base and the event's floor (comment and mention: normal). Linear has the same shape (`NEEDS_YOU_LINEAR_CATEGORIES`, `_STATUSES`, `_TEAMS=ACME=work:normal`).
2. **The Mac's alert rules** decide *how loudly* it arrives: the bypass rules plus the per-session and per-event rules being built in `tay/session-alert-rules` ("Treat as urgent", match on `source.event`). For example: `work:jira:` + event `comment` → Always later; `work:jira:acme:ACME-123` → Treat as urgent while I'm on it.

A later step can make the first layer editable from the Mac (Settings → Connections, written back to the sender's env file through the CLI), but env lines come first: they work on headless devboxes, where most pollers run.

## Three mechanisms, so we don't write N pollers

### A. A generic poller (recommended first)

One stdlib script, `needs-you poll`, and one small config file per source:

- **Source:** a `command` that prints JSON (`glab api ...`, `fly releases --json`, `curl -H @tokenfile ...`) or a `url` plus an `auth_file`. Secrets live in files, never in the config text, and are never logged (hard rule 3).
- **Selection:** a tiny path language (`issues[]`, `a.b`, equality filters) instead of depending on `jq`.
- **Card templates:** `key`, `title`, `link` with `{field}` placeholders, plus `priority`, `context`, `event` and `resolve_when_absent`. Template output goes through the same cleaning, redaction and link allow-list as every other sender.

It covers Sentry, Vercel/Netlify/Fly, GitLab to-dos and Dependabot as configs. Jira and Linear get dedicated scripts because they need saved-state diffing and two auth modes. Risk: a bad mapping can flood the inbox; the card cap, the hub's open-item limit and the Mac's noisy-sender guard bound it.

### B. A webhook relay (later, ADR first)

The only route for Figma "ready for dev", Notion and real-time GitHub org events (already planned in [future.md](future.md)). Build it once, generically: a per-vendor signature check (Figma passcode, Sentry and Notion HMAC; stdlib `hmac` is enough) feeding mechanism A's mapping, off by default.

### C. A scheduled agent with the vendor's MCP server

`claude -p` on a cron on a tailnet machine, with read-only vendor MCP tools plus the needs-you MCP server's `needs_you_add` and `needs_you_resolve`. The prompt prescribes the keys. Right for judgement sources (Slack "needs a reply from me", Docs and Notion comments). Shipped as a recipe plus a prompt block in `integrations/agent-instructions/`, not code. Cloud routines can't reach a tailnet-only hub, so it must run on a tailnet machine.

## Getting you there: deep links into the app you work in

A card is only as good as its "go there" button. What's built and what's left (the full table of hosts, environment variables and jump mechanisms is in [linking.md](linking.md); additions here).

**Fixed in `tay/orca-jump-label`:** an Orca session's card had a "Terminal" button (it was the Orca jump, mislabelled) and a VS Code button that the hook adds on every Mac. Now the hook labels it **Orca** and adds no editor link when Orca is the host. The Mac names every app-action button for where it goes (Orca, WezTerm, tmux, iTerm2, Terminal, Ghostty), whatever the sender called it.

**Built in `tay/go-there`:** items 1 and 2 below. The hook detects the host once in that order and writes one go-there link; the editor folder link comes only for VS Code or Cursor, or when no go-there link could be built (a remote tmux without `LC_NEEDS_YOU_TERM`, Terminal.app without a tty and no bundle id), so a card always keeps a button. Cursor sessions now get `cursor://` links. `app/activate` brings forward only a running app on a fixed list of 9 terminals and 17 editors (`AppActivation.allowedApps`, mirrored by the hook's `TERMINAL_APPS`/`EDITOR_APPS` and compared by `tests/test_link_mirror.py`); it never launches an app, and from outside the panel it does nothing.

**Left, in order:**

1. **One primary "go there" button per agent card.** (Built.) Detect the host once (first match wins): `ORCA_TERMINAL_HANDLE` → Orca; an IDE (`CLAUDE_CODE_ENTRYPOINT=claude-vscode`, `TERM_PROGRAM=vscode`, `CURSOR_TRACE_ID`, named by `__CFBundleIdentifier`); `TMUX_PANE`; `WEZTERM_PANE`; `ITERM_SESSION_ID`; `KITTY_WINDOW_ID`; Ghostty; `Apple_Terminal` + tty. Emit the editor folder link only when the host *is* the editor or nothing was detected (today it's added beside every terminal jump).
2. **`needsyou://app/activate?bundle=<id>`** (built): bring an allow-listed app forward when we know the app but not the window (any other `__CFBundleIdentifier`). A new app-action path, mirrored in the hub's `APP_LINK_PATHS` and `LinkPolicy.appActionPaths` (hard rule 7).
3. **New jumps:** kitty (`kitten @ focus-window --match id:N`, needs `allow_remote_control`), Ghostty per terminal (1.3+ AppleScript `focus`, matching the working directory; [docs](https://ghostty.org/docs/features/applescript)), Codex app (`codex://threads/<session-uuid>`, [docs](https://developers.openai.com/codex/app/commands); a new scheme for the allow-list), remote tmux over SSH. Warp can't focus an existing tab yet ([open request](https://github.com/warpdotdev/warp/issues/8929)); Claude desktop can only open a new Code session in a folder (`claude://code/new?folder=`), not an existing one.
4. **Commands on cards are copyable, not selectable.** The panel never takes focus (hard rule 2), so text can't be selected; `tay/card-copy-dev-mode` adds copy chips for single-line commands in a body (inert, fully visible text only) and a card "…" menu with Copy items. With the Orca button working, the hook's "Jump to its terminal: `orca terminal switch ...`" body line becomes a fallback; consider moving it behind the expander.
5. **Ticket and design links open the native app** through `https` plus the app's own "open links in the app" setting (Linear, Figma, Slack). Only adopt `linear://` / `figma://` forms after a live check on a Mac.

## Suggested order

| Step | What | Effort |
|---|---|---|
| 1 | `source.event` + per-session and per-event alert rules (in progress, `tay/session-alert-rules`) | in progress |
| 2 | Linear poller (dedicated; the notifications feed maps almost 1:1 onto the GitHub poller) | S (built: `integrations/linear/`; live check left) |
| 3 | Jira poller, Cloud and Data Center (saved-state diff; fake HTTP server tests) | M (built: `integrations/jira/`; live check left) |
| 4 | Host detection + one primary "go there" button; `needsyou://app/activate` | M (items 1 and 2 built) |
| 5 | Generic poller with configs for Sentry, Vercel, GitLab | M |
| 6 | Cert, domain and key expiry (built: `integrations/expiry/`) | S |
| 7 | GitHub Projects status cards, Dependabot security alerts (built: `integrations/github/`) | S |
| 8 | Figma comment polling on a watch list | M |
| 9 | MCP-agent recipe for Slack, Docs, Notion | S (docs) |
| 10 | Webhook relay (ADR) for Figma "ready for dev", Notion, GitHub org events | L |

Each integration uses the `add-integration` skill (script, README, user guide, tests, links). None needs an API change beyond `source.event`.
