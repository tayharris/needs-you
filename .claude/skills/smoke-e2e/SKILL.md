---
name: smoke-e2e
description: End-to-end smoke test of a needs-you hub and CLI on this machine. Starts a throwaway hub on a high loopback port with a temp DB and temp HOME, mints sender and reader tokens, posts, checks dedupe, resolves, then stops the hub and verifies the CLI's offline outbox queues and flushes. Use after changing hub/, cli/ or the wire contract.
---

# smoke-e2e

Everything lives in a temp dir: never touch `~/.config/needs-you`, `~/.local/state/needs-you`, `/etc/needs-you` or a real hub. Use `/usr/bin/python3` (the 3.9 floor). Bind `127.0.0.1` only.

Write the steps below to a script in your scratch directory and run it with `bash`, so the temp HOME and tokens stay in one shell.

```bash
#!/usr/bin/env bash
set -u
REPO=$(git rev-parse --show-toplevel)
T=$(mktemp -d); mkdir -p "$T/home"
PORT=48765                      # any free high port
PY=/usr/bin/python3
URL="http://127.0.0.1:$PORT"

# 1. Tokens (printed once on stdout; the note goes to stderr)
SEND=$($PY "$REPO/hub/needs_you_admin.py" --db "$T/hub.db" token add smoke-sender 2>/dev/null)
READ=$($PY "$REPO/hub/needs_you_admin.py" --db "$T/hub.db" token add smoke-reader --role reader 2>/dev/null)

# 2. Hub
$PY "$REPO/hub/needs_you_hub.py" --bind 127.0.0.1 --port $PORT --db "$T/hub.db" --hub-id smoke 2>"$T/hub.log" &
HUB=$!; sleep 1

# 3. CLI pointed at it, with an isolated HOME (outbox goes to $T/home/.local/state/needs-you/outbox)
export HOME="$T/home" NEEDS_YOU_URL="$URL" NEEDS_YOU_TOKEN="$SEND"
CLI="$PY $REPO/cli/needs-you"
$CLI health                                                             # expect OK, role=sender

# 4. Create, then re-post the same key: same id, created=False, changed=False
$CLI --json add --key smoke:test:one --title "Smoke one"
$CLI --json add --key smoke:test:one --title "Smoke one"
curl -s -H "Authorization: Bearer $READ" "$URL/v1/items?status=open"   # exactly 1 item
$CLI --json add --key smoke:test:one --title "Smoke one, edited"       # changed=True, same id

# 5. Resolve
$CLI resolve --key smoke:test:one                                       # "resolved <id>"
curl -s -H "Authorization: Bearer $READ" "$URL/v1/items?status=open"   # items: []

# 6. Offline outbox: stop the hub, post (exit 0, "queued"), restart, flush
kill $HUB; wait $HUB 2>/dev/null
$CLI add --key smoke:test:offline --title "Queued while down"; echo "exit=$?"   # exit=0
ls "$HOME/.local/state/needs-you/outbox"                                # one .json file
$PY "$REPO/hub/needs_you_hub.py" --bind 127.0.0.1 --port $PORT --db "$T/hub.db" --hub-id smoke 2>>"$T/hub.log" &
HUB=$!; sleep 1
$CLI flush                                                              # "sent 1, dropped 0, 0 still queued"
curl -s -H "Authorization: Bearer $READ" "$URL/v1/items?status=open"   # smoke:test:offline is open

# 7. Role check: a reader can't post (403), a sender can't list (403)
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $READ" \
  -H 'Content-Type: application/json' -d '{"title":"x"}' "$URL/v1/items"
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $SEND" "$URL/v1/items"

kill $HUB; wait $HUB 2>/dev/null
rm -rf "$T"
```

## Expected

| Step | Pass when |
|---|---|
| health | `OK hub=smoke token=smoke-sender role=sender`, `outbox: 0 queued` |
| dedupe | both posts return the same `id`; second has `"created": false, "changed": false` |
| edit | `"changed": true`, same `id` |
| resolve | open list is empty |
| outbox | add exits 0 and prints `queued`; after restart, `flush` sends 1; the item is open |
| roles | `403` and `403` |

Report each row PASS/FAIL. On failure, show `$T/hub.log` (it never contains tokens) before deleting the temp dir. Never echo `$SEND`/`$READ`.

## Optional: two-hub replication

Start a second hub on `PORT+1` with its own DB, both with `--config` files that set `peers` and a `peer_secret` of ≥ 16 chars (see `deploy/hub.example.json`), post to one and poll the other. `tests/test_replication.py` already covers this in depth; prefer running it.

## In flux

Invites (`/v1/invites`, `/v1/invites/redeem`, an `owner` role, a `/join/<code>` page) and the hub embedded in the Mac app are being built on other branches. Once merged, add a step: mint an invite, redeem it with `curl`, and post with the returned token. Check the real endpoint and flag names in `hub/needs_you_hub.py` first.
