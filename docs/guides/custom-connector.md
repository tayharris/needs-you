# Connect any agent or tool (custom connector)

needs-you works with anything that can run a command or make an HTTP request when something happens: an agent's hooks, a plugin system, a webhook, a "notification command" setting. This page is all you need to connect one: when to post, the exact item format, how to map your tool's events to cards, three worked examples, how to test, and how to share what you built.

Built-in connectors already exist for [Claude Code](claude-code.md), [Codex](codex.md), [Gemini CLI](gemini.md), [opencode](opencode.md), [GitHub Copilot CLI](copilot.md), [Orca](orca.md), [GitHub](github.md) and [cron, systemd and CI](../../integrations/ci/README.md). Use those where they fit.

## Copy this into your agent

Paste this into the agent you want connected (or the one that should build the connector for another tool). Replace `<TOOL>`:

```text
Connect <TOOL> to needs-you on this machine. Read
https://github.com/tayharris/needs-you/blob/main/docs/guides/custom-connector.md
(docs/guides/custom-connector.md in a checkout) and follow it:
1. Find how <TOOL> reports events: hooks, plugins, webhooks or a notification command.
2. Fill in the page's mapping table for <TOOL>'s events (post needs / post done / resolve /
   ignore), with keys, titles and priorities as the page says. Show me the table.
3. Write the connector from the closest example on the page. It must always exit 0,
   never block <TOOL>, never print or log my token, and resolve the card when I act.
4. Test it against a throwaway loopback hub with a temporary HOME, exactly as the page's
   "Test your connector" section says (never my real ~/.config/needs-you), and show me
   the card appearing and resolving.
5. Tell me how to turn it on, and what it posts. Don't install it until I say so.
```

## 1. When to post

Every card interrupts a person. Post only when a human is actually needed ([AGENT-GUIDE.md → What it's for](../AGENT-GUIDE.md#what-its-for)):

- the tool is **blocked on them**: an approval, a question, a decision, access it doesn't have;
- something they're waiting on **finished** (a long run), as `kind=done`;
- something **broke** that they need to know about today.

Never post progress, "started", tool calls or anything the tool will sort out itself. **Resolve what you posted** as soon as the person has acted (they answered, approved, the run went green). A card that stays after the wait is over teaches people to ignore the panel. The full rules are in [AGENT-GUIDE.md → Rules](../AGENT-GUIDE.md#rules).

## 2. Two ways to send

You need a sender machine first: an invite link's installer ([Add a sender](add-a-sender.md)) puts the `needs-you` CLI in `~/.local/bin` and writes `~/.config/needs-you/env` (mode 600) with `NEEDS_YOU_URLS`, `NEEDS_YOU_URL` and `NEEDS_YOU_TOKEN`.

### The `needs-you` CLI (preferred)

```bash
needs-you add --key "acme-agent:devbox:3f9c2a:waiting" --title "acme-agent wants to run git: app" \
  --body "Allow or deny it in the session." --agent acme-agent --project app --expires-in 48
needs-you resolve --key "acme-agent:devbox:3f9c2a:waiting"
```

- It tries each hub in `NEEDS_YOU_URLS` in order (failover), and when none answers it queues the request in `~/.local/state/needs-you/outbox/` and **exits 0**; the next call or the 5-minute `needs-you flush` sends it.
- It exits **2** when the hub refuses the request (a 4xx: bad field, bad token, volume guard) or the flags are wrong. A refused request is not queued, so test your connector (section 5) and wrap every call with `|| true` or ignore the exit code.
- Pass untrusted text as `--title=TEXT` / `--body=TEXT` (with `=`), so a value starting with `-` isn't read as an option, and call it with an argument list, never through `sh -c` with the text pasted in.
- `needs-you --json add ...` prints the hub's response; `-q` prints nothing on success.

### Raw HTTP

Anything that can make an HTTP request can post `POST <hub>/v1/items` with `Authorization: Bearer <token>` and a JSON body. Never print, log or commit the token, and never put it in item text. Reading it from the env file and passing the header through a file descriptor keeps it out of `ps` and your shell history (`printf` is a shell builtin):

<!-- test:curl-post -->
```bash
. ~/.config/needs-you/env
curl -sS --max-time 5 -X POST "$NEEDS_YOU_URL/v1/items" \
  -H @<(printf 'Authorization: Bearer %s\n' "$NEEDS_YOU_TOKEN") \
  -H 'Content-Type: application/json' \
  --data-binary '{"key": "acme-ci:deploy:approval", "title": "Approve the prod deploy of app",
                  "priority": "urgent", "links": [{"label": "Run", "url": "https://ci.example.com/runs/812"}],
                  "source": {"agent": "acme-ci", "project": "app"}}'
```

The trade-off: no outbox and no failover. If you need them without the CLI, try each URL in `NEEDS_YOU_URLS` in order and move to the next one on a connection error, a timeout, `421` or a `5xx`; stop on any other `4xx` (every hub would refuse it the same way). That is the CLI's rule.

## 3. The item format

Verified against `hub/needs_you_hub.py` (`validate_item_input`); the full wire contract is [API.md](../API.md#post-v1items-sender).

### `POST /v1/items` (sender token)

The body is one JSON object (UTF-8, at most 64 KiB). Only `title` is required. A field sent as `null` counts as left out. **Unknown fields are ignored**, so you can send extra fields without breaking anything (they aren't stored). Text fields are trimmed of surrounding whitespace, and lengths are counted in characters (Unicode code points) after trimming.

| Field | Required | Type | Allowed values and limits | Default | CLI flag | What the Mac app does with it |
|---|---|---|---|---|---|---|
| `title` | **yes** | string | 1–100 characters; one line: no newlines, tabs or other control characters | | `--title` | The card's headline, and its entry in the menu bar menu |
| `key` | no | string | at most 200 characters from `A-Z a-z 0-9 . _ : - / @ # + =`; `""` is refused (leave it out instead) | the new item's id, so nothing dedupes | `--key` (required by the CLI) | Same key while open = the same card, updated in place. Settings → Alerts rules can match "Key starts with" |
| `body` | no | string | at most 2,000 characters; markdown; newlines (`\n`, `\r`) and tabs allowed, other control characters not | empty (returned as `null`) | `--body`, `--body-file PATH` (`-` = stdin) | Rendered below the title: bold, italic, code, simple lists and allow-listed links. No HTML, no images |
| `kind` | no | string | `needs`, `done` or `info` (any case) | `needs` | `--kind` on `add`, or the `done` / `info` subcommands | `needs` counts in the pill; `done` and `info` are FYIs |
| `priority` | no | string | `urgent`, `normal` or `low` (any case) | `normal` | `--priority` | Sort order; `urgent` breaks through snooze |
| `context` | no | string | `work` or `personal` (any case) | `work` | `--context` (default `NEEDS_YOU_DEFAULT_CONTEXT`, else `work`) | Which side of the pill it counts on, and when it's prominent (work hours or not) |
| `links` | no | array | at most 6 `{"label", "url"}` objects; `label` 1–80 characters, `url` 1–2,000 characters (rules below) | `[]` | `--link "Label=URL"` (repeatable; a bare URL gets the label `Link`) | Buttons on the card; the menu bar and the hotkey open the first link, so put the place to act first |
| `steps` | no | array | at most 10 step objects (below) | `[]` | `--step "Text"` or `--step "Text=URL"` (link label `Open`), `--steps-json JSON\|@PATH` | A numbered checklist; the app offers Done once every step is ticked |
| `source` | no | object | optional `host`, `agent`, `project`, each a string of at most 100 characters, no control characters; other keys ignored | `{}` | `--host` (default this machine's short hostname), `--agent`, `--project` | `host · agent` under the card; Alerts rules can match "Agent starts with" and "Host is" |
| `expires_at` | no | timestamp | ISO 8601 (`2026-10-08T17:00:00Z`, fractional seconds and `±HH:MM` offsets allowed, no zone = UTC) or a number of epoch seconds, between 1970-01-01 and 9999-12-31 | `done` / `info`: now + 24 h (the hub's `default_expiry_hours`); `needs`: never | `--expires-in HOURS` | After it, the item counts as resolved and leaves the panel. Every re-post sets it again |
| `status` | | | **refused** (400), even as `null`: use resolve | | | |

**Links.** Every `url` (in `links` and in a step's `link`) must:

- use one of these schemes, in any case: `https`, `slack`, `vscode`, `cursor`, `figma`, `msteams`, `discord`, `linear`. Everything else is a 400, including `http`, `file`, `javascript` and `orca`;
- be plain ASCII in the form `<scheme>://...`, with no `user@` before the host, no whitespace, quotes, backslash, `[ ] < > ^` `` ` `` `{ | }` or control or invisible characters, `%` only as `%XX`, and at most one `#`. Percent-encode anything else (a space is `%20`);
- for `https`, have a host;
- for `vscode` and `cursor`, be exactly one of `vscode://file/<abs path>[:line[:col]]`, `vscode://vscode-remote/ssh-remote+<host>[/<abs path>]`, `vscode://vscode-remote/tunnel+<name>[/<abs path>]` or `vscode://anthropic.claude-code/open?session=<id>` (same with `cursor://`); details in [API.md](../API.md#post-v1items-sender).

The app's own `needsyou://` actions (the **Terminal** button) are accepted only in the fixed shapes in API.md; leave them to the built-in hooks. **One bad link refuses the whole item**, so a connector that copies URLs from events should send only `https://` URLs it has checked, or retry without links when the CLI exits 2 (example (b) does).

**Steps** (each an object; unknown step fields are ignored):

| Field | Required | Type | Rule | Default |
|---|---|---|---|---|
| `text` | **yes** | string | 1–200 characters, one line, inline markdown | |
| `link` | no | object | `{"label", "url"}`, the same rules as an entry of `links` | none |
| `done` | no | boolean | `true` or `false`; anything else is a 400 | `false` |

**Same key, same card.** If an item with this `key` is open (not resolved, dismissed or expired), the post updates it in place and keeps its id. A re-post is your whole current view: every field is replaced, and fields you leave out go back to their defaults. The card re-animates only when `title`, `body`, `priority` or `steps` changed. Otherwise a new item is created.

**Response.** `201` when created, `200` when an open item with the key was updated. The body is the item plus two booleans, `created` and `changed`:

```json
{"id": "01M4C6NFX41A7Y475SD1THXN5A", "key": "acme-agent:devbox:3f9c2a:waiting", "context": "work",
 "kind": "needs", "priority": "normal", "title": "acme-agent wants to run git: app", "body": null,
 "links": [], "steps": [], "source": {"host": "devbox", "agent": "acme-agent", "project": "app"},
 "status": "open", "created_at": "2026-10-07T22:10:11.492Z", "updated_at": "2026-10-07T22:10:11.492Z",
 "content_updated_at": "2026-10-07T22:10:11.492Z", "seen_at": null, "expires_at": null,
 "superseded_by": null, "created": true, "changed": true}
```

Keep the `id` only if you want to resolve by id. A response may also carry `"update_requested": true` (the owner asked this machine to run `needs-you update`); a custom connector can ignore it.

### `POST /v1/items/resolve` (sender token)

Body: exactly one of `{"key": "..."}` or `{"id": "..."}`, a non-empty string. CLI: `needs-you resolve --key KEY` or `needs-you resolve --id ID`.

It closes the open item with that key (or id) as resolved. Always `200`, and safe to repeat:

```json
{"resolved": 1, "items": [{"id": "01M4C6NFX41A7Y475SD1THXN5A", "status": "resolved", "...": "the item"}]}
```

Nothing open with that key or id (already resolved, dismissed, expired, never posted) gives `{"resolved": 0, "items": []}`, not an error. So a connector can resolve on every "the person acted" event without remembering whether it posted.

### Errors

Every error has the body `{"error": "<code>", "message": "<text>", "field": "<field>"}`, with `field` only on validation errors (for example `title`, `links[0].url`, `steps[2].done`, `source.host`).

| HTTP | `error` | When | What to do |
|---|---|---|---|
| 400 | `invalid` | A field breaks a rule above, `status` was sent, the body isn't a JSON object, or resolve didn't get exactly one of `key` / `id` | Fix the connector; `message` says which rule |
| 401 | `unauthorized` | No token, or an unknown or revoked one | Re-run the invite installer, or get a new token |
| 403 | `forbidden` | A `reader` or `owner` token on a sender endpoint | Use the machine's sender token |
| 413 | `too_large` | Body over 64 KiB | Shorten it (the field limits keep a valid item far below this) |
| 421 | `misdirected` | The URL's host name isn't one this hub answers to | The CLI tries the next hub; check `NEEDS_YOU_URLS` |
| 429 | `too_many_open` | This token already has 60 open items (`max_open_per_token`) and the post would create a new one. Re-posts of open keys still work | Something is looping: fix the keys (a timestamp or run id in the key?) and resolve what's open |
| 500 | `internal` | A hub bug | Report it; the hub's log has the details |

## 4. Map your tool's events

### The mapping table

Before writing code, list every event your tool can report and decide one action for each. Most events are **ignore**. Copy this table and fill it in (the example rows are for a coding agent):

| Tool event | Means | Action | Key | Title | Priority |
|---|---|---|---|---|---|
| `permission_request` | it waits for the person to allow a tool | post `needs` | `<tool>:<host>:<session>:waiting` | `<Tool> wants to run <first word>: <project>` | `normal` |
| `waiting_for_input`, turn ended | it finished and waits for the next message | post `needs` | same key | `<Tool> is waiting for you: <project>` | `normal` |
| `error` | it stopped on an error the person must fix | post `needs` | same key | `<Tool> stopped on an error: <project>` | `normal` (`urgent` if prod is down) |
| `long_job_finished` | something they asked for is done | post `done` (expires in 24 h) | `<tool>:<host>:<session>:finished` | `<Tool> finished <task>: <project>` | `low` |
| `user_prompt`, `permission_granted`, `tool_finished`, `resumed` | the person acted | resolve | `<tool>:<host>:<session>:waiting` | | |
| `session_end` | the session is gone | resolve | `<tool>:<host>:<session>:waiting` | | |
| everything else (tool started, progress, tokens used) | nothing for a person | ignore | | | |

**Keys.** `<tool>:<host>:<session>:<what>`, for example `acme-agent:devbox:3f9c2a:waiting`.

- Stable for as long as the thing it describes: one key per session (or task, pipeline, ticket) and per kind of wait. Every wait in one session can share one `:waiting` key, so the card updates in place as the wait changes and one resolve clears it.
- Never a timestamp, a run id or a counter: then each event is a new card, and the token hits the 60-item guard.
- Only `A-Z a-z 0-9 . _ : - / @ # + =`, at most 200 characters. Replace anything else in session ids and names (`tr -c 'A-Za-z0-9._-' '_'`).
- Start with your tool's name, so the person can write Alerts rules for it ("Key starts with `acme-agent:`").

**Titles.** At most 100 characters, one line. Lead with what the person has to do or what the tool is waiting for, then where: `acme-agent wants to run git: app`, `Approve the prod deploy of app`. Don't put command lines, prompts, file contents, secrets or anything from the event you haven't reduced to a word or a name: the real hooks send only the first word of a command. Details go in the body (at most 2,000 characters), which says what to do and where; the place to act goes in a link, first.

**Priority.** `normal` for "needs you today" (the default, right for most waits). `urgent` only when something is broken now or someone is blocked today: it breaks through snooze. `low` for this week and suggestions. Don't make every card urgent.

**Clearing the card.** Resolve on the first event that shows the person acted: a new prompt, an approval, the next tool run, the session ending. If your tool has no such event, give the card a short `--expires-in` (a re-post renews it), and tell the person they can click Done. Either way, set `--expires-in` as a backstop (the built-in hooks use 48 hours), so a crashed session's card doesn't stay forever.

**Never block, never fail the tool.** A hook runs inside the tool's event loop: read the input, start the CLI in the background with no stdin or stdout, exit 0, print nothing (some tools read a hook's stdout as instructions). The CLI waits up to 3 seconds per hub (`NEEDS_YOU_TIMEOUT`), which you don't want the tool to sit through. One catch: two background calls fired within milliseconds (a post and its resolve) can reach the hub in either order; the expiry backstop covers that rare case, and example (b) shows a single worker that keeps calls in order.

### One card for one wait

If the agent itself can post (it has the [skill](../AGENT-GUIDE.md) or runs `needs-you add`), it may post its own blocker and then wait, and your "is waiting for you" card would only repeat it. To skip yours while the agent's own item is open:

1. Set **`NEEDS_YOU_AGENT_SESSION=<session id>`** in the environment of the commands the agent runs (its shell tool), using the same id your hook sees for that session. When `needs-you add` posts a `needs` item with it set, the CLI notes the key in `~/.local/state/needs-you/session-items/<id>/` (the id with anything outside `A-Za-z0-9._-` turned into `_`, at most 80 characters): one file per item, with `key=` and `expires=<epoch seconds>` lines. Resolving the item (by key or id) or re-posting it as `done`/`info` removes the file.
2. Before posting your "waiting" card, skip it if that directory has a file whose `expires=` is still in the future. Keep posting permission prompts, questions and errors: those are a different thing to act on. When the session ends, delete the directory.

The shared hook (`integrations/claude-code/needs-you-hook.sh`) does step 2 for you when you feed it the session's events with the same `session_id` (the opencode plugin works this way and sets the variable through opencode's `shell.env`). Inside an Orca terminal `$ORCA_TERMINAL_HANDLE` names the session instead, for the CLI and the hook alike.

### Example (a): a shell hook that reads JSON on stdin

For a tool that runs a command per event with a JSON object on stdin, like Claude Code, Codex and Gemini CLI. Suppose `acme-agent` sends `{"event": "permission_request", "session_id": "3f9c2a", "cwd": "/home/me/src/app", "tool": "git"}`. JSON is read with `python3` (already on the machine: the CLI needs it), not `jq`.

<!-- test:acme-needs-you.sh -->
```bash
#!/usr/bin/env bash
# acme-needs-you.sh: map acme-agent hook events to needs-you cards.
# acme-agent runs it with the event as JSON on stdin. Prints nothing, always exits 0.
set +e
NY=${NEEDS_YOU_BIN:-needs-you}
command -v "$NY" >/dev/null 2>&1 || NY="$HOME/.local/bin/needs-you"

# Four fields, each reduced to one printable line (no control characters, which the
# hub refuses in titles).
fields=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
d = d if isinstance(d, dict) else {}
for k in ("event", "session_id", "cwd", "tool"):
    s = "".join(c if c.isprintable() else " " for c in str(d.get(k) or ""))
    print(" ".join(s.split())[:200])
' 2>/dev/null)
{ read -r event; read -r session; read -r cwd; read -r tool; } <<EOF
$fields
EOF
[ -n "$session" ] || exit 0

safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60; }
host=$(hostname 2>/dev/null)
host=$(safe "${host%%.*}")
key="acme-agent:$host:$(safe "$session"):waiting"
project=$(basename "${cwd:-$PWD}")
project=${project:0:40}
tool=${tool%% *}
tool=${tool:0:30}

post() {  # post TITLE BODY [PRIORITY]: in the background, never waits on the hub
  ( "$NY" add --key "$key" --priority "${3:-normal}" --title="$1" --body="$2" \
      --agent acme-agent --project="$project" --expires-in 48 \
      </dev/null >/dev/null 2>&1 & )
}
resolve() {
  ( "$NY" resolve --key "$key" </dev/null >/dev/null 2>&1 & )
}

case "$event" in
  permission_request) post "acme-agent wants to run ${tool:-a tool}: $project" "Allow or deny it in the session." ;;
  waiting_for_input)  post "acme-agent is waiting for you: $project" "It finished its turn." ;;
  error)              post "acme-agent stopped on an error: $project" "Look at the session; it won't continue on its own." ;;
  user_prompt|permission_granted|tool_finished|session_end) resolve ;;
  *) ;;  # everything else: nothing for a person
esac
exit 0
```

Register it in the tool's hook config for the events in your table, for example `"hooks": {"permission_request": "~/.local/bin/acme-needs-you.sh", ...}`. If the tool already passes the event name as an argument rather than in the JSON, read `$1` instead.

### Example (b): a webhook relay

For a service that sends HTTP webhooks (a CI system, a deploy tool, a ticket tracker). A small stdlib Python server on the same machine as the CLI turns each webhook into `needs-you add` or `resolve`. It answers `202` at once and hands the work to one background thread, so the service never waits on the hub and the calls for one key stay in order. It listens on loopback only: put it on the tailnet (or behind a reverse proxy with TLS) only if the service can't reach it otherwise, and always with the shared secret.

Suppose `acme-ci` posts `{"event": "run.failed", "pipeline": "app-deploy", "url": "https://ci.example.com/runs/812"}`:

| Webhook `event` | Action | Key | Title | Priority |
|---|---|---|---|---|
| `approval.requested` | post `needs` | `acme-ci:<pipeline>:approval` | `Approve the <pipeline> deploy` | `urgent` |
| `approval.approved`, `approval.rejected` | resolve | `acme-ci:<pipeline>:approval` | | |
| `run.failed` | post `needs` | `acme-ci:<pipeline>:failed` | `<pipeline> failed` | `normal` |
| `run.succeeded` | resolve | `acme-ci:<pipeline>:failed` | | |
| anything else | ignore | | | |

<!-- test:needs-you-relay.py -->
```python
#!/usr/bin/env python3
"""needs-you-relay.py: turn acme-ci's JSON webhooks into needs-you cards.

    NEEDS_YOU_RELAY_SECRET=... python3 needs-you-relay.py    # then point acme-ci at
                                                             # http://127.0.0.1:8788/
NEEDS_YOU_RELAY_SECRET  required; the service sends it in the X-Relay-Secret header
NEEDS_YOU_RELAY_PORT    default 8788 (loopback only)
NEEDS_YOU_BIN           the needs-you CLI (default: needs-you on PATH)
"""
from __future__ import annotations

import hmac
import json
import os
import queue
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List

NY = os.environ.get("NEEDS_YOU_BIN") or "needs-you"
SECRET = os.environ.get("NEEDS_YOU_RELAY_SECRET", "")
PORT = int(os.environ.get("NEEDS_YOU_RELAY_PORT") or 8788)
jobs: "queue.Queue[Dict[str, Any]]" = queue.Queue()


def clean(value: Any, limit: int) -> str:
    """One printable line, at most `limit` characters."""
    s = "".join(c if c.isprintable() else " " for c in str(value or ""))
    return " ".join(s.split())[:limit]


def slug(value: Any) -> str:
    """Safe inside a key."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(value or ""))[:60] or "unknown"


def commands(ev: Dict[str, Any]) -> List[List[str]]:
    """The needs-you calls for one webhook; [] means ignore it."""
    event = ev.get("event")
    name = clean(ev.get("pipeline"), 60) or "pipeline"
    key = "acme-ci:" + slug(ev.get("pipeline"))
    url = str(ev.get("url") or "")
    link = ["--link", "Run=" + url] if url.startswith("https://") and len(url) <= 2000 else []
    src = ["--agent", "acme-ci", "--project=" + name, "--expires-in", "72"]
    if event == "approval.requested":
        return [[NY, "add", "--key", key + ":approval", "--priority", "urgent",
                 "--title=Approve the %s deploy" % name,
                 "--body=" + clean(ev.get("summary"), 500)] + src + link]
    if event in ("approval.approved", "approval.rejected"):
        return [[NY, "resolve", "--key", key + ":approval"]]
    if event == "run.failed":
        return [[NY, "add", "--key", key + ":failed", "--title=%s failed" % name,
                 "--body=The latest run failed. The log is behind the Run button."] + src + link]
    if event == "run.succeeded":
        return [[NY, "resolve", "--key", key + ":failed"]]
    return []


def call(cmd: List[str]) -> int:
    try:
        return subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=60).returncode
    except Exception:  # noqa: BLE001 - never stop the worker
        return 1


def worker() -> None:
    while True:
        ev = jobs.get()
        try:
            for cmd in commands(ev):
                if call(cmd) == 2 and "--link" in cmd:  # the hub refused the link: post without it
                    i = cmd.index("--link")
                    call(cmd[:i] + cmd[i + 2:])
        except Exception:  # noqa: BLE001
            pass


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        given = self.headers.get("X-Relay-Secret", "")
        if not hmac.compare_digest(given.encode("utf-8"), SECRET.encode("utf-8")):
            return self.reply(401)
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 < length <= 65536:
            return self.reply(400)
        try:
            ev = json.loads(self.rfile.read(length).decode("utf-8"))
        except ValueError:
            ev = None
        if not isinstance(ev, dict):
            return self.reply(400)
        jobs.put(ev)
        self.reply(202)

    def reply(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args: Any) -> None:  # no access log: keep webhook details out of logs
        pass


def main() -> int:
    if not SECRET:
        sys.stderr.write("needs-you-relay: set NEEDS_YOU_RELAY_SECRET\n")
        return 1
    threading.Thread(target=worker, daemon=True).start()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Run it under systemd or a LaunchAgent like any small service, with the secret in its environment file (mode 600), never on the command line. If the service signs its webhooks (an HMAC header), check the signature in `do_POST` instead of the shared secret.

### Example (c): a notification command with no payload

Some tools only run a command you configure when they start waiting, with no event data. Aider's `--notifications-command` is one. There is nothing to read and usually no "the person is back" event, so the card is keyed by the working directory and expires on its own.

<!-- test:needs-you-notify.sh -->
```bash
#!/usr/bin/env bash
# needs-you-notify.sh [TOOL]: post "TOOL is waiting for you" for a tool that runs a
# command when it waits. Example: aider --notifications-command "needs-you-notify.sh aider"
# Prints nothing, always exits 0, returns at once.
set +e
NY=${NEEDS_YOU_BIN:-needs-you}
command -v "$NY" >/dev/null 2>&1 || NY="$HOME/.local/bin/needs-you"
tool=$(printf '%s' "${1:-aider}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-30)
host=$(hostname 2>/dev/null)
host=$(printf '%s' "${host%%.*}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-60)
project=$(basename "$PWD" | tr -d '[:cntrl:]')
project=${project:0:40}
# One card per tool and directory: the next wait updates it instead of adding one.
dir_id=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
( "$NY" add --key "$tool:$host:$dir_id:waiting" --title="$tool is waiting for you: $project" \
    --body="It's waiting for your next message in \`$project\` on \`$host\`." \
    --agent "$tool" --project="$project" --expires-in 2 \
    </dev/null >/dev/null 2>&1 & )
exit 0
```

The 2-hour expiry stands in for the missing resolve: each wait re-posts and renews it, and the person can click Done. If you'd rather clear it when you're back at the terminal, run `needs-you resolve --key ...` (same key) from your shell prompt hook, or wrap the tool: `aider ...; needs-you resolve --key ...`.

## 5. Test your connector

Test against a throwaway hub on loopback with a temporary `HOME`, so nothing touches your real `~/.config/needs-you` or your Mac's inbox. From a checkout of this repo (`/usr/bin/python3` 3.9 or later is enough):

<!-- test:local-hub -->
```bash
export NY_TEST=$(mktemp -d)
python3 hub/needs_you_hub.py --bind 127.0.0.1 --port 18765 --db "$NY_TEST/hub.db" --hub-id test-hub --quiet &
sleep 1
python3 hub/needs_you_admin.py --db "$NY_TEST/hub.db" token add connector-test --role sender 2>/dev/null > "$NY_TEST/sender"
python3 hub/needs_you_admin.py --db "$NY_TEST/hub.db" token add connector-view --role reader 2>/dev/null > "$NY_TEST/reader"
mkdir -p "$NY_TEST/home/.config/needs-you"
( umask 077; printf 'NEEDS_YOU_URLS=http://127.0.0.1:18765\nNEEDS_YOU_URL=http://127.0.0.1:18765\nNEEDS_YOU_TOKEN=%s\n' \
    "$(cat "$NY_TEST/sender")" > "$NY_TEST/home/.config/needs-you/env" )
```

`token add` prints the token once, on stdout, straight into a file here. Then, in the same shell:

```bash
# The CLI against the test hub: doctor should say OK for config, hub 1 and hubs.
HOME="$NY_TEST/home" python3 cli/needs-you doctor

# Fire your connector with a sample event (example (a) here), with the test HOME and the CLI on PATH.
echo '{"event": "permission_request", "session_id": "3f9c2a", "cwd": "/tmp/app", "tool": "git"}' |
  HOME="$NY_TEST/home" PATH="$PWD/cli:$PATH" ./acme-needs-you.sh; echo "exit $?"

# What the hub holds now (a reader token; the posted card should be "open").
sleep 2; curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$NY_TEST/reader")") \
  'http://127.0.0.1:18765/v1/items?status=all' | python3 -m json.tool

# The "person acted" event: the same card should now be "resolved".
echo '{"event": "user_prompt", "session_id": "3f9c2a"}' |
  HOME="$NY_TEST/home" PATH="$PWD/cli:$PATH" ./acme-needs-you.sh
```

Check, for every row of your mapping table:

1. The connector exits 0 and prints nothing, also with empty or broken input.
2. Each "post" event makes exactly one card with the title, key, priority and links you planned, and a repeat of the event updates it (`"created": false`) instead of adding another.
3. Each "resolve" event turns it `resolved`, and an "ignore" event changes nothing.
4. With the hub stopped (`kill %1`), the connector still exits 0 at once, and `HOME="$NY_TEST/home" python3 cli/needs-you flush` sends the queued call after you start the hub again.
5. The hub log and the cards contain no token, command line or secret.

To see the cards as the person will, point a Mac app at your real hub only once the test passes. Clean up with `kill %1; rm -rf "$NY_TEST"`.

## 6. Before you share it

- [ ] Posts only when a human is needed; progress and tool chatter are ignored.
- [ ] Every card it posts has a resolve path (an event, a short expiry, or both), and an `--expires-in` backstop.
- [ ] Keys are stable (no timestamps or run ids), start with the tool's name, and fit `A-Z a-z 0-9 . _ : - / @ # + =`.
- [ ] Titles lead with the action, at most 100 characters, with no command lines, prompts or secrets.
- [ ] Links are `https` (or another allowed scheme) and point where the person acts, first link first.
- [ ] Always exits 0, prints nothing a tool could read as instructions, and never waits on the hub.
- [ ] Uses the CLI (or loops over `NEEDS_YOU_URLS` itself), reads the token from `~/.config/needs-you/env`, and never prints or logs it.
- [ ] Opt-in if it could be noisy (the built-in hooks stay quiet unless `NEEDS_YOU_AGENT_ALERTS=1`).
- [ ] Tested with section 5's checklist.
- [ ] Python is stdlib-only and 3.9-compatible; shell runs on macOS bash 3.2 without `jq`.

### Contribute it as an integration

A connector for a tool other people use is welcome in the repo. Integrations live in `integrations/<tool>/` (the connector, an installer if it needs one, and a `README.md`), with a user guide in `docs/guides/<tool>.md`, a row in the README's guide table and a test in `tests/test_<tool>.py` that runs it against a real local hub (`tests/support.py` has the helpers). [integrations/opencode](../../integrations/opencode/README.md) (a plugin that starts the shared hook) and [integrations/ci](../../integrations/ci/README.md) (plain scripts) are good models. The full checklist is the `add-integration` skill in [.claude/skills/add-integration/SKILL.md](../../.claude/skills/add-integration/SKILL.md), and [CONTRIBUTING.md](../../CONTRIBUTING.md) has the rest. Use placeholder names (`devbox`, `acme`, `hub-a.example.ts.net`) in examples, never real host or company names.
