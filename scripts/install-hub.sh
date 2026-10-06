#!/usr/bin/env bash
# Install (or upgrade) a needs-you hub on a Linux machine with systemd and Tailscale.
#
#   sudo ./scripts/install-hub.sh [options]
#
# Options:
#   --bind ADDR          address to listen on (default: `tailscale ip -4`)
#   --port N             port (default 8765)
#   --hub-id ID          this hub's unique id (default: short hostname)
#   --peer URL           another hub, e.g. http://linux-box.example.ts.net:8765 (repeatable)
#   --peer-secret S      shared secret for hub-to-hub replication (same on every hub)
#   --peer-secret-file F read the shared secret from a file
#   --reconfigure        rewrite /etc/needs-you/hub.json even if it exists
#   --no-start           install everything but don't enable/start the service
#   -h, --help           show this help
#
# What it does: checks python3 >= 3.9, creates the `needs-you` system user, copies
# hub/*.py to /opt/needs-you/hub, writes /etc/needs-you/hub.json (mode 640, root:needs-you),
# installs the needs-you-hub systemd unit and the /usr/local/bin/needs-you-admin wrapper,
# then enables and starts the service and checks /v1/health.
#
# With no --peer-secret and no existing config, a secret is generated and printed once.
# Re-running is safe: code and unit are replaced, an existing config is kept (unless
# --reconfigure), and the database in /var/lib/needs-you is never touched.
set -euo pipefail

PREFIX=/opt/needs-you
CONF_DIR=/etc/needs-you
CONF=$CONF_DIR/hub.json
STATE_DIR=/var/lib/needs-you
UNIT=/etc/systemd/system/needs-you-hub.service
SVC_USER=needs-you
PYTHON=/usr/bin/python3

BIND=""
PORT=8765
HUB_ID=""
PEERS=()
PEER_SECRET=""
RECONFIGURE=0
START=1

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "install-hub: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bind) BIND=${2:?}; shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --hub-id) HUB_ID=${2:?}; shift 2 ;;
    --peer) PEERS+=("${2:?}"); shift 2 ;;
    --peer-secret) PEER_SECRET=${2:?}; shift 2 ;;
    --peer-secret-file) PEER_SECRET=$(tr -d '\r\n' < "${2:?}"); shift 2 ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux with systemd"
command -v systemctl >/dev/null || die "systemd is required"
[ -x "$PYTHON" ] || die "$PYTHON not found (apt install python3)"
"$PYTHON" -c 'import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "python3 >= 3.9 with the sqlite3 module is required"

SRC=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$SRC/hub/needs_you_hub.py" ] || die "run this from a checkout of the needs-you repo"

if [ -z "$BIND" ]; then
  command -v tailscale >/dev/null || die "tailscale not found; pass --bind <tailnet IP>"
  BIND=$(tailscale ip -4 2>/dev/null | head -n1)
  [ -n "$BIND" ] || die "could not read the tailnet IP (is tailscale up?); pass --bind"
fi
case "$BIND" in
  0.0.0.0|::|"[::]"|"") die "refusing to bind to all interfaces; use the tailnet IP" ;;
esac
[ -n "$HUB_ID" ] || HUB_ID=$(hostname -s)

# 1. user and directories
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
fi
install -d -m 0755 "$PREFIX" "$PREFIX/hub"
install -d -m 0750 -o root -g "$SVC_USER" "$CONF_DIR"
install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$STATE_DIR"

# 2. code
install -m 0644 "$SRC/hub/needs_you_hub.py" "$SRC/hub/needs_you_admin.py" "$PREFIX/hub/"
install -m 0755 "$SRC/deploy/needs-you-admin.sh" /usr/local/bin/needs-you-admin

# 3. config
GENERATED_SECRET=0
if [ ! -f "$CONF" ] || [ "$RECONFIGURE" -eq 1 ]; then
  if [ -z "$PEER_SECRET" ] && [ -f "$CONF" ]; then
    PEER_SECRET=$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("peer_secret",""))' "$CONF")
  fi
  if [ -z "$PEER_SECRET" ]; then
    PEER_SECRET=$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')
    GENERATED_SECRET=1
  fi
  umask 027
  NY_BIND="$BIND" NY_PORT="$PORT" NY_HUB_ID="$HUB_ID" NY_DB="$STATE_DIR/hub.db" \
  NY_SECRET="$PEER_SECRET" "$PYTHON" - "${PEERS[@]+"${PEERS[@]}"}" > "$CONF.tmp" <<'PY'
import json, os, sys
cfg = {
    "bind": os.environ["NY_BIND"],
    "port": int(os.environ["NY_PORT"]),
    "db": os.environ["NY_DB"],
    "hub_id": os.environ["NY_HUB_ID"],
    "freebind": True,
    "peers": [p.rstrip("/") for p in sys.argv[1:]],
    "peer_secret": os.environ["NY_SECRET"],
}
print(json.dumps(cfg, indent=2))
PY
  chown root:"$SVC_USER" "$CONF.tmp"
  chmod 0640 "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
  echo "wrote $CONF"
else
  echo "kept existing $CONF (use --reconfigure to rewrite it)"
fi

# 4. systemd
install -m 0644 "$SRC/deploy/needs-you-hub.service" "$UNIT"
systemctl daemon-reload
if [ "$START" -eq 1 ]; then
  systemctl enable needs-you-hub.service >/dev/null
  systemctl restart needs-you-hub.service
  CONF_BIND=$("$PYTHON" -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["bind"], c.get("port", 8765))' "$CONF")
  set -- $CONF_BIND
  ok=0
  for _ in $(seq 1 20); do
    if "$PYTHON" -c 'import sys,urllib.request as u; u.urlopen("http://%s:%s/v1/health" % (sys.argv[1], sys.argv[2]), timeout=2)' "$1" "$2" 2>/dev/null; then
      ok=1; break
    fi
    sleep 0.5
  done
  if [ "$ok" -eq 1 ]; then
    echo "needs-you-hub is up on http://$1:$2 (hub_id $HUB_ID)"
  else
    echo "needs-you-hub did not answer yet; check: journalctl -u needs-you-hub -n 50" >&2
  fi
fi

if [ "$GENERATED_SECRET" -eq 1 ]; then
  echo
  echo "Generated peer secret (needed only for multi-hub setups; pass it to install-hub.sh"
  echo "on the other hubs with --peer-secret, and keep it out of git):"
  echo "  $PEER_SECRET"
fi
cat <<EOF

Next:
  needs-you-admin token add mac --role reader        # for the Mac app
  needs-you-admin token add <machine> --role sender  # one per sending machine
Senders should use the MagicDNS name, e.g. http://$(hostname -s).<tailnet>.ts.net:$PORT
EOF
