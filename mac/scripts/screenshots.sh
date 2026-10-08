#!/usr/bin/env bash
# Screenshots for the site and the guides, from demo data, next to a running real app.
#
#   mac/scripts/screenshots.sh [out-dir]      # default: dist/screenshots
#
# Builds a throwaway copy and runs it three times with the snapshot tour (NEEDS_YOU_SNAPSHOT_DIR,
# see AppDelegate.runSnapshotTour): once with no items (the idle pill), once with the
# example items below (among them an agent's question: 6e-6g), and once with one agent card
# (preview-agent.png). Every PNG is drawn with cacheDisplay, so no Screen Recording
# permission is needed. Isolated the way scripts/upgrade-test.sh is:
#
#   - bundle id app.needsyou.mac.screenshots, no needsyou:// scheme, built into a temp dir
#   - NEEDS_YOU_DEFAULTS_SUITE: a throwaway defaults suite, deleted afterwards
#   - NEEDS_YOU_SUPPORT_DIR: a temp dir (demo mode runs no hub anyway)
#   - a snapshot run registers no global shortcut, and the update checker is off for a
#     bundle id other than the real one
#
# The test copy's pill shows on screen for about 30 s per run, then it's quit (SIGTERM).
# Check every image before it's committed: no personal names, hosts or tokens.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-dist/screenshots}"
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
                          {"label": "Tracing", "description": "OpenTelemetry"}]}],
             "answerable": True},
         content_updated_at=ago(3),
         links=[{"label": "VS Code", "url": "vscode://vscode-remote/ssh-remote+devbox/home/dev/acme-api"},
                {"label": "Terminal", "url": "needsyou://terminal/focus?app=wezterm&pane=1"}],
         source={"host": "devbox", "agent": "claude-code", "project": "acme-api"}),
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
run() {   # run <fixture> <snapshot dir>
  mkdir -p "$2" "$T/support"
  NEEDS_YOU_DEMO=1 NEEDS_YOU_DEMO_INJECT_SECONDS=0 NEEDS_YOU_DEMO_FIXTURE="$1" NEEDS_YOU_SNAPSHOT_DIR="$2" \
  NEEDS_YOU_SUPPORT_DIR="$T/support" NEEDS_YOU_DEFAULTS_SUITE="$SUITE" NEEDS_YOU_HUB_LOOPBACK_ONLY=1 \
    "$APP/Contents/MacOS/NeedsYou" > "$T/run.log" 2>&1 &
  PID=$!
  for _ in $(seq 1 120); do
    grep -q "snapshots written" "$T/run.log" && break
    sleep 0.5
  done
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
  PID=""
  grep -q "snapshots written" "$T/run.log" || { echo "error: the snapshot tour didn't finish" >&2; tail -20 "$T/run.log"; exit 1; }
}

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
