#!/usr/bin/env bash
# Screenshots for the site and the guides, from demo data, next to a running real app.
#
#   mac/scripts/screenshots.sh [out-dir]              # default: dist/screenshots
#   mac/scripts/screenshots.sh --formats [out-dir]    # default: dist/screenshots/formats
#
# --formats draws every shape a sender can post (tests/format_cases.py, posted to a throwaway
# hub by format-fixtures.py) card by card instead: each card in the three card text modes,
# its arrival preview, picks and answers on the answerable questions, and the cards again
# after the catalog's re-posts (AppDelegate.runFormatTour). Look at every one.
#
# Builds a throwaway copy and runs it three times with the snapshot tour (NEEDS_YOU_SNAPSHOT_DIR,
# see AppDelegate.runSnapshotTour): once with no items (the idle pill), once with the
# example items below (among them agents' questions: 6e-6l, 6k the answer window), and once
# with one agent card (preview-agent.png). Demo mode also shows example usage meters
# (DemoFeed.statusFixture): 15-usage-panel.png, 16*-usage-pill*.png (each pill meter style at
# 31 % / 10 %, waiting and idle) and settings-usage*.png.
# Every PNG is drawn with cacheDisplay, so no Screen Recording permission is needed.
# Isolated the way scripts/upgrade-test.sh is:
#
#   - bundle id app.needsyou.mac.screenshots, no needsyou:// scheme, built into a temp dir
#   - NEEDS_YOU_DEFAULTS_SUITE: a throwaway defaults suite, deleted afterwards
#   - NEEDS_YOU_SUPPORT_DIR: a temp dir (demo mode runs no hub anyway)
#   - a snapshot run registers no global shortcut, and the update checker is off for a
#     bundle id other than the real one
#
# The test copy's pill shows on screen for about 30 s per run (the format tour: a few minutes), then it's quit (SIGTERM).
# Check every image before it's committed: no personal names, hosts or tokens.
set -euo pipefail
cd "$(dirname "$0")/.."

FORMATS=0
if [[ "${1:-}" == "--formats" ]]; then FORMATS=1; shift; fi
if [[ $FORMATS == 1 ]]; then OUT="${1:-dist/screenshots/formats}"; else OUT="${1:-dist/screenshots}"; fi
ID=app.needsyou.mac.screenshots
SUITE="$ID.$$"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}"/needsyou-shots.XXXXXX)" && pwd -P)"
APP="$T/dist/NeedsYou.app"
PID=""

cleanup() {
  set +e
  [[ -n "$PID" ]] && kill -TERM "$PID" 2>/dev/null
  sleep 1
  for domain in "$SUITE" "$ID"; do
    defaults delete "$domain" >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  rm -rf "$T"
}
trap cleanup EXIT

echo "==> building a test copy ($ID)"
NEEDS_YOU_BUNDLE_ID="$ID" NEEDS_YOU_NO_URL_SCHEME=1 NEEDS_YOU_DIST="$T/dist" scripts/bundle.sh > "$T/build.log" 2>&1 \
  || { tail -20 "$T/build.log"; exit 1; }

# Example items, timed relative to now. Example hosts only (devbox, build-box, ci).
/usr/bin/python3 - "$T/items.json" <<'EOF'
import json, sys
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
def ago(minutes):
    return (now - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")

def item(n, minutes, **fields):
    base = {"id": "01SHOT%020d" % n, "status": "open", "kind": "needs", "context": "work",
            "priority": "normal", "links": [], "created_at": ago(minutes), "updated_at": ago(minutes)}
    base.update(fields)
    base.setdefault("key", base["id"])
    return base

items = [
    item(1, 4, key="deploy:api:v2.14", priority="urgent",
         title="Approve the prod deploy of api v2.14",
         body="Canary has been green at 5% for 30 min. **Approve** to roll out to every region, or roll back.",
         links=[{"label": "Approve", "url": "https://ci.example.com/deploys/4182"},
                {"label": "Canary dashboard", "url": "https://grafana.example.com/d/api-canary"},
                {"label": "Slack thread", "url": "slack://channel?team=T0&id=C0"}],
         source={"host": "build-box", "agent": "deploy-bot", "project": "api"}),
    item(2, 22, key="claude-code:devbox:acme-web",
         title="Claude is waiting for you: acme-web",
         body="The schema migration plan is ready. It needs one decision before it edits anything.",
         steps=[{"text": "Read the plan", "link": {"label": "PR #412", "url": "https://github.com/acme/acme-web/pull/412"}, "done": True},
                {"text": "Pick the column name: `owner_id` or `account_id`"},
                {"text": "Answer in the Claude Code session on devbox"}],
         links=[{"label": "PR #412", "url": "https://github.com/acme/acme-web/pull/412"}],
         source={"host": "devbox", "agent": "claude-code", "project": "acme-web"}),
    item(3, 9, key="ci:acme-web:main",
         title="CI failed on main: acme-web",
         body="`test (ubuntu, py3.12)` failed: 2 tests in `checkout_test.py`. The last green run was 3 commits ago.",
         links=[{"label": "Run #8841", "url": "https://github.com/acme/acme-web/actions/runs/8841"}],
         source={"host": "ci", "agent": "github-actions", "project": "acme-web"}),
    item(4, 95, key="cleanup:devbox:old-branch", priority="low",
         title="feature/old-search has 2 unpushed commits",
         body="Daily cleanup won't delete it. Push it, or say it can go.",
         source={"host": "devbox", "agent": "cron:cleanup"}),
    item(5, 40, key="personal:domain:renew", context="personal", priority="low",
         title="Renew example.org: it expires in 9 days",
         body="Auto-renew is off for this one.",
         links=[{"label": "Registrar", "url": "https://registrar.example.com/domains"}],
         source={"host": "home-server", "agent": "cron:domains"}),
    item(7, 3, key="claude-code:devbox:acme-api",
         title="Claude asks \u201cWhich database should the service use?\u201d and 1 more: acme-api",
         body="**Database** \u00b7 choose one\nWhich database should the service use?\n"
              "- Postgres (Recommended) \u2014 Mature, already used by the team.\n- SQLite \u2014 Zero ops, single file.\n\n"
              "**Extras** \u00b7 choose any\nWhich extras should it ship with?\n- Metrics\n- Tracing \u2014 OpenTelemetry\n\n"
              "Answer in Claude.",
         question={"id": "toolu_01SHOT", "items": [
             {"header": "Database", "text": "Which database should the service use?", "multi_select": False,
              "options": [{"label": "Postgres (Recommended)", "description": "Mature, already used by the team."},
                          {"label": "SQLite", "description": "Zero ops, single file."},
                          {"label": "DynamoDB", "description": "Managed, but a new dependency."}]},
             {"header": "Extras", "text": "Which extras should it ship with?", "multi_select": True,
              "options": [{"label": "Metrics", "description": ""},
                          {"label": "Tracing", "description": "OpenTelemetry"}]}]},
         links=[{"label": "VS Code", "url": "vscode://vscode-remote/ssh-remote+devbox/home/dev/acme-api"}],
         source={"host": "devbox", "agent": "claude-code", "project": "acme-api"}),
    # opencode waits for the card's answer (ADR 0009 B2): its options are buttons (6h, 6i).
    item(8, 2, key="agent:devbox:ses_shot",
         title="opencode asks “Which branch should the release come from?” and 1 more: acme-web",
         body="**Branch** · choose one\nWhich branch should the release come from?\n"
              "- main — Everything merged today\n- release/1.4 — Only the fixes\n\n"
              "**Platforms** · choose any\nWhich platforms?\n- macOS\n- Linux\n- Windows\n\n"
              "Pick here or answer in opencode.",
         question={"id": "que_01SHOT", "answerable": True, "items": [
             {"header": "Branch", "text": "Which branch should the release come from?", "multi_select": False,
              "options": [{"label": "main", "description": "Everything merged today"},
                          {"label": "release/1.4", "description": "Only the fixes"}]},
             {"header": "Platforms", "text": "Which platforms?", "multi_select": True,
              "options": [{"label": "macOS", "description": "arm64 and x64"},
                          {"label": "Linux", "description": "x64"},
                          {"label": "Windows", "description": "x64"}]}]},
         content_updated_at=ago(2),
         links=[{"label": "Terminal", "url": "needsyou://terminal/focus?app=wezterm&pane=1"}],
         source={"host": "devbox", "agent": "opencode", "project": "acme-web"}),
    # Claude Code waits for the card's answer (ADR 0009 B3) and takes typed words: "Other…" (6j-6l).
    item(9, 1, key="claude-code:devbox:acme-db",
         title="Claude asks \u201cWhat should the new accounts table be called?\u201d: acme-db",
         body="**Table** \u00b7 choose one\nWhat should the new accounts table be called?\n"
              "- accounts \u2014 Short, matches the model\n- user_accounts \u2014 Matches the old schema\n\n"
              "Pick here or answer in Claude.",
         question={"id": "claude-0123456789abcdef01234567", "answerable": True, "items": [
             {"header": "Table", "text": "What should the new accounts table be called?", "multi_select": False,
              "allow_other": True,
              "options": [{"label": "accounts", "description": "Short, matches the model"},
                          {"label": "user_accounts", "description": "Matches the old schema"}]}]},
         content_updated_at=ago(1),
         links=[{"label": "Terminal", "url": "needsyou://terminal/focus?app=wezterm&pane=2"}],
         source={"host": "devbox", "agent": "claude-code", "project": "acme-db"}),
    item(6, 25, key="ci:nightly", kind="done", title="Nightly e2e: 214 passed, 0 failed",
         source={"host": "ci", "agent": "github-actions"},
         expires_at=(now + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")),
]
json.dump({"items": items}, open(sys.argv[1], "w"), indent=1)
EOF
echo '{"items": []}' > "$T/empty.json"
# The site's "How agents use it": one agent card with an editor link, as the Claude Code hook
# posts it (--ssh-alias devbox), for the preview with its open-and-mark-done button.
/usr/bin/python3 - "$T/agent.json" <<'EOF'
import json, sys
from datetime import datetime, timedelta, timezone

at = (datetime.now(timezone.utc) - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"items": [{
    "id": "01SHOTAGENT0000000000001", "key": "claude-code:devbox:acme-api", "status": "open",
    "kind": "needs", "context": "work", "priority": "urgent",
    "title": "Claude needs permission: acme-api",
    "body": "Claude wants to run: `make migrate`",
    "links": [{"label": "VS Code", "url": "vscode://vscode-remote/ssh-remote+devbox/home/dev/acme-api"}],
    "source": {"host": "devbox", "agent": "claude-code", "project": "acme-api"},
    "created_at": at, "updated_at": at}]}, open(sys.argv[1], "w"), indent=1)
EOF

# Defaults for the test copy: the out-of-the-box look (demo mode shows no setup tips), with
# a list tall enough for the example cards. The tour draws Settings with the defaults.
defaults write "$SUITE" expandedListHeight -float 840
# Clicks elsewhere on the Mac (someone using it meanwhile) mustn't close the panel mid-tour.
defaults write "$SUITE" collapseOnClickOutside -bool false

mkdir -p "$OUT"
# Half-seconds a tour may take. The default tour takes about a minute on an idle Mac (each
# step waits 1.2 s, each Settings page 1.5 s and more per scrolled screen); at `nice -n 19` on
# a busy one it can take several, so the limit is generous and a run that dies stops the wait.
WAIT=600
run() {   # run <fixture> <snapshot dir> [extra env...]
  local fixture="$1" dir="$2"
  shift 2
  mkdir -p "$dir" "$T/support"
  env "$@" NEEDS_YOU_DEMO=1 NEEDS_YOU_DEMO_INJECT_SECONDS=0 NEEDS_YOU_DEMO_FIXTURE="$fixture" NEEDS_YOU_SNAPSHOT_DIR="$dir" \
  NEEDS_YOU_SUPPORT_DIR="$T/support" NEEDS_YOU_DEFAULTS_SUITE="$SUITE" NEEDS_YOU_HUB_LOOPBACK_ONLY=1 \
    "$APP/Contents/MacOS/NeedsYou" > "$T/run.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 "$WAIT"); do
    grep -q "snapshots written" "$T/run.log" && break
    kill -0 "$PID" 2>/dev/null || break   # it quit or crashed: the log says why
    sleep 0.5
  done
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
  PID=""
  grep -q "snapshots written" "$T/run.log" || {
    echo "error: the snapshot tour didn't finish ($(ls "$dir" | wc -l | tr -d ' ') PNGs written)" >&2
    tail -20 "$T/run.log"; exit 1; }
}

if [[ $FORMATS == 1 ]]; then
  echo "==> format fixtures"
  /usr/bin/python3 scripts/format-fixtures.py "$T/formats"
  echo "==> format tour"
  WAIT=2400
  run "$T/formats/formats.json" "$T/shots" NEEDS_YOU_SNAPSHOT_TOUR=formats NEEDS_YOU_DEMO_REPOST="$T/formats/formats-repost.json"
  cp "$T/shots/"*.png "$OUT/"
  echo "==> wrote $(ls "$T/shots" | wc -l | tr -d ' ') PNGs to $OUT"
  exit 0
fi

echo "==> idle run"
run "$T/empty.json" "$T/idle"
cp "$T/idle/1-collapsed.png" "$OUT/pill-idle.png"
echo "==> example items run"
run "$T/items.json" "$T/items"
cp "$T/items/"*.png "$OUT/"
echo "==> agent preview run"
run "$T/agent.json" "$T/agent"
cp "$T/agent/6-preview.png" "$OUT/preview-agent.png"
echo "==> wrote $(ls "$OUT" | wc -l | tr -d ' ') PNGs to $OUT"
