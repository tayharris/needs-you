#!/usr/bin/env bash
# Install (or upgrade) an always-on needs-you hub on a Linux server. Optional: the Mac app
# runs its own hub; server hubs add redundancy and catch items while the Mac sleeps.
#
#   ./scripts/install-hub.sh --user [options]     no root: runs as a systemd --user service
#   sudo ./scripts/install-hub.sh [options]       system-wide: a `needs-you` system user
#
# Options:
#   --user                 install under your home directory (recommended)
#   --bind ADDR            listen address, repeatable or comma-separated
#                          (default: 127.0.0.1 plus `tailscale ip -4`)
#   --port N               port (default 8765)
#   --hub-id ID            this hub's unique id (default: short hostname)
#   --public-url URL       how others reach this hub (default: http://<MagicDNS name>:PORT)
#   --peer URL             another hub's public URL (repeatable; replaces the peer list)
#   --peer-secret-file F   read the shared replication secret from a file
#   --peer-secret S        the shared secret (visible in `ps`; prefer the file)
#   --generate-peer-secret make a new secret and print it once (copy it to the other hub)
#   --join LINK            pair with another hub (the Mac's, or a server) by its peer invite
#                          (http(s)://<hub>/join/nyi_...): no secret to copy; it stays in the DB
#   --reconfigure          rebuild the config from defaults + flags (keeps the secret)
#   --no-start             install files and config, don't start the service
#   --no-invite            don't print an owner invite at the end
#   -h, --help             this help
#
# Re-running upgrades the code in place, keeps the config (flags you pass are applied to it)
# and the database, and restarts the service.
set -euo pipefail

MODE=system
BINDS=()
PORT=""
HUB_ID=""
PUBLIC_URL=""
PEERS=()
PEER_SECRET=""
GEN_SECRET=0
RECONFIGURE=0
START=1
INVITE=1
JOIN=""

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "install-hub: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) MODE=user; shift ;;
    --system) MODE=system; shift ;;
    --bind) BINDS+=("${2:?--bind needs an address}"); shift 2 ;;
    --port) PORT=${2:?}; shift 2 ;;
    --hub-id) HUB_ID=${2:?}; shift 2 ;;
    --public-url) PUBLIC_URL=${2:?}; shift 2 ;;
    --peer) PEERS+=("${2:?--peer needs a URL}"); shift 2 ;;
    --peer-secret) PEER_SECRET=${2:?}; shift 2 ;;
    --peer-secret-file) PEER_SECRET=$(tr -d '\r\n' < "${2:?}"); shift 2 ;;
    --generate-peer-secret) GEN_SECRET=1; shift ;;
    --join) JOIN=${2:?--join needs the peer invite link}; shift 2 ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --no-start) START=0; shift ;;
    --no-invite) INVITE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
if [ -n "$JOIN" ]; then
  case "$JOIN" in
    http://*/join/nyi_*|https://*/join/nyi_*) ;;
    *) die "--join takes a peer invite link: http(s)://<hub>/join/nyi_... (make one in the Mac app's Settings, or with needs-you-admin invite create NAME --role peer)" ;;
  esac
  INVITE=0  # the hub it joins already has the owner; its tokens replicate here
fi

PYTHON=/usr/bin/python3
[ -x "$PYTHON" ] || PYTHON=$(command -v python3 || true)
[ -n "$PYTHON" ] || die "python3 not found (apt install python3)"
"$PYTHON" -c 'import sys, sqlite3; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "python3 >= 3.9 with the sqlite3 module is required"

SRC=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$SRC/hub/needs_you_hub.py" ] || die "run this from a checkout of the needs-you repo"

if [ "$MODE" = user ]; then
  [ "$(id -u)" -ne 0 ] || die "--user installs for the current user; don't run it as root"
  PREFIX="$HOME/.local/share/needs-you"
  CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/needs-you"
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/needs-you"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  ADMIN_BIN="$HOME/.local/bin/needs-you-admin"
else
  [ "$(id -u)" -eq 0 ] || die "a system install needs root (sudo), or use --user"
  PREFIX=/opt/needs-you
  CONF_DIR=/etc/needs-you
  STATE_DIR=/var/lib/needs-you
  UNIT_DIR=/etc/systemd/system
  ADMIN_BIN=/usr/local/bin/needs-you-admin
  SVC_USER=needs-you
fi
CONF="$CONF_DIR/hub.json"
if [ "$START" -eq 1 ]; then
  [ "$(uname -s)" = "Linux" ] || die "the service needs Linux with systemd (use --no-start to only install files)"
  command -v systemctl >/dev/null || die "systemd is required (or pass --no-start)"
fi

# Defaults that need tailscale: only computed for a new config or when not given.
TS_IP=""; TS_NAME=""
if command -v tailscale >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  TS_NAME=$(tailscale status --json 2>/dev/null | "$PYTHON" -c \
    'import json,sys; print((json.load(sys.stdin).get("Self") or {}).get("DNSName","").rstrip("."))' 2>/dev/null || true)
fi
DEFAULT_BIND="127.0.0.1${TS_IP:+,$TS_IP}"
for b in "${BINDS[@]+"${BINDS[@]}"}"; do
  case "$b" in 0.0.0.0|::|"[::]") die "refusing to bind to all interfaces; use 127.0.0.1 and the tailnet IP" ;; esac
done
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
[ -n "$HUB_ID" ] || HUB_ID_DEFAULT=$HOST_SHORT
GENERATED=""
if [ "$GEN_SECRET" -eq 1 ]; then
  GENERATED=$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')
  PEER_SECRET=$GENERATED
fi

# 1. directories and code (upgrade in place)
if [ "$MODE" = system ]; then
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
  fi
  install -d -m 0755 "$PREFIX"
  install -d -m 0750 -o root -g "$SVC_USER" "$CONF_DIR"
  install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$STATE_DIR"
else
  install -d -m 0700 "$PREFIX" "$CONF_DIR" "$STATE_DIR"
  install -d -m 0755 "$(dirname "$ADMIN_BIN")" "$UNIT_DIR"
fi
install -d -m 0755 "$PREFIX/hub" "$PREFIX/cli" "$PREFIX/integrations/claude-code/skill/needs-you"
install -m 0644 "$SRC/hub/needs_you_hub.py" "$SRC/hub/needs_you_admin.py" "$SRC/hub/join-install.sh" "$PREFIX/hub/"
install -m 0755 "$SRC/cli/needs-you" "$PREFIX/cli/needs-you"
install -m 0644 "$SRC/integrations/claude-code/needs-you-hook.sh" "$SRC/integrations/claude-code/install-hooks.sh" \
  "$SRC/integrations/claude-code/hooks.json" "$PREFIX/integrations/claude-code/"
install -m 0644 "$SRC/integrations/claude-code/skill/needs-you/SKILL.md" "$PREFIX/integrations/claude-code/skill/needs-you/"
for agent in codex gemini copilot grok cursor; do
  install -d -m 0755 "$PREFIX/integrations/$agent"
  install -m 0644 "$SRC/integrations/$agent/install-$agent-hooks.sh" "$SRC/integrations/$agent/$agent-hooks.json" \
    "$PREFIX/integrations/$agent/"
done
install -d -m 0755 "$PREFIX/integrations/kimi"
install -m 0644 "$SRC/integrations/kimi/install-kimi-hooks.sh" "$SRC/integrations/kimi/kimi-hooks.toml" \
  "$PREFIX/integrations/kimi/"
install -d -m 0755 "$PREFIX/integrations/opencode"
install -m 0644 "$SRC/integrations/opencode/needs-you.js" "$SRC/integrations/opencode/install-opencode-plugin.sh" \
  "$PREFIX/integrations/opencode/"
install -d -m 0755 "$PREFIX/integrations/cline" "$PREFIX/integrations/aider"
install -m 0644 "$SRC/integrations/cline/install-cline-hooks.sh" "$PREFIX/integrations/cline/"
install -m 0644 "$SRC/integrations/aider/install-aider-notifications.sh" "$PREFIX/integrations/aider/"
echo "installed code in $PREFIX"

# 2. config: create, or apply only the flags that were passed
NEW_CONFIG=0
[ -f "$CONF" ] || NEW_CONFIG=1
umask 077
NY_CONF="$CONF" NY_NEW="$NEW_CONFIG" NY_RECONF="$RECONFIGURE" NY_DB="$STATE_DIR/hub.db" \
NY_BIND="$(IFS=,; echo "${BINDS[*]+"${BINDS[*]}"}")" NY_DEFAULT_BIND="$DEFAULT_BIND" \
NY_PORT="$PORT" NY_HUB_ID="$HUB_ID" NY_HUB_ID_DEFAULT="${HUB_ID_DEFAULT:-}" \
NY_PUBLIC_URL="$PUBLIC_URL" NY_TS_NAME="$TS_NAME" NY_HOST="$HOST_SHORT" NY_SECRET="$PEER_SECRET" \
"$PYTHON" - "${PEERS[@]+"${PEERS[@]}"}" > "$CONF.tmp" <<'PY'
import json, os, sys
e = os.environ
old = {}
if e["NY_NEW"] != "1":
    with open(e["NY_CONF"]) as fh:
        old = json.load(fh)
cfg = dict(old) if e["NY_RECONF"] != "1" else {}
if e["NY_RECONF"] == "1" and old.get("peer_secret"):
    cfg["peer_secret"] = old["peer_secret"]
fresh = not cfg
def put(key, value, default=None):
    if value not in (None, ""):
        cfg[key] = value
    elif key not in cfg and default not in (None, ""):
        cfg[key] = default
binds = [b for b in e["NY_BIND"].split(",") if b]
put("bind", binds or None, [b for b in e["NY_DEFAULT_BIND"].split(",") if b])
put("port", int(e["NY_PORT"]) if e["NY_PORT"] else None, 8765)
put("db", None, e["NY_DB"])
put("hub_id", e["NY_HUB_ID"], e["NY_HUB_ID_DEFAULT"])
port = cfg.get("port", 8765)
# this machine's name, whatever --hub-id says (that names the hub, not the host)
host = e["NY_TS_NAME"] or e["NY_HOST"] or "localhost"
put("public_url", e["NY_PUBLIC_URL"].rstrip("/"), "http://%s:%d" % (host, port))
put("freebind", None, True)
if sys.argv[1:]:
    cfg["peers"] = [p.rstrip("/") for p in sys.argv[1:]]
cfg.setdefault("peers", [])
put("peer_secret", e["NY_SECRET"])
if cfg["peers"] and len(cfg.get("peer_secret") or "") < 16:
    sys.exit("install-hub: peers are set but there is no peer secret; pass --peer-secret-file "
             "(the other hub's secret) or --generate-peer-secret")
cfg.setdefault("retention_days", 7)
print(json.dumps(cfg, indent=2))
PY
if [ "$MODE" = system ]; then
  chown root:"$SVC_USER" "$CONF.tmp"
  chmod 0640 "$CONF.tmp"
else
  chmod 0600 "$CONF.tmp"
fi
if [ -f "$CONF" ] && cmp -s "$CONF" "$CONF.tmp"; then
  rm -f "$CONF.tmp"; echo "config unchanged: $CONF"
else
  mv "$CONF.tmp" "$CONF"; echo "wrote $CONF"
fi
cfg_get() { "$PYTHON" -c 'import json,sys; c=json.load(open(sys.argv[1])); v=c.get(sys.argv[2]); print(",".join(v) if isinstance(v, list) else ("" if v is None else v))' "$CONF" "$1"; }

# 3. admin wrapper
if [ "$MODE" = user ]; then
  cat > "$ADMIN_BIN.tmp" <<EOF
#!/bin/sh
# needs-you-admin (user install): manage tokens and invites on this hub.
exec "$PYTHON" "$PREFIX/hub/needs_you_admin.py" --config "\${NEEDS_YOU_HUB_CONFIG:-$CONF}" "\$@"
EOF
  chmod 0755 "$ADMIN_BIN.tmp"
  mv -f "$ADMIN_BIN.tmp" "$ADMIN_BIN"
else
  install -m 0755 "$SRC/deploy/needs-you-admin.sh" "$ADMIN_BIN"
fi

# 3b. pair with the hub whose peer invite this is (before the service starts, so it starts
#     replicating with it at once). The secret goes into the database, never to the terminal.
JOINED=""
if [ -n "$JOIN" ]; then
  if ! JOINED=$("$ADMIN_BIN" peer join "$JOIN"); then
    die "couldn't join with that link (above). The hub is installed; make a new peer invite and re-run with --join, or run: needs-you-admin peer join <link>"
  fi
  echo "$JOINED"
fi

# 4. service
if [ "$MODE" = user ]; then
  # The paths this install used, quoted for systemd (which also expands % and $).
  "$PYTHON" - "$SRC/deploy/needs-you-hub.user.service" "$PYTHON" "$PREFIX/hub/needs_you_hub.py" "$CONF" \
    > "$UNIT_DIR/needs-you-hub.service.tmp" <<'PY'
import sys
tmpl, python, hub, conf = sys.argv[1:5]
q = lambda p: '"%s"' % p.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
with open(tmpl) as fh:
    sys.stdout.write(fh.read().replace("@PYTHON@", q(python)).replace("@HUB@", q(hub)).replace("@CONF@", q(conf)))
PY
  mv -f "$UNIT_DIR/needs-you-hub.service.tmp" "$UNIT_DIR/needs-you-hub.service"
  SYSTEMCTL=(systemctl --user)
  JOURNAL="journalctl --user -u needs-you-hub"
else
  install -m 0644 "$SRC/deploy/needs-you-hub.service" "$UNIT_DIR/needs-you-hub.service"
  SYSTEMCTL=(systemctl)
  JOURNAL="journalctl -u needs-you-hub"
fi
if [ "$START" -eq 1 ]; then
  "${SYSTEMCTL[@]}" daemon-reload
  "${SYSTEMCTL[@]}" enable needs-you-hub.service >/dev/null
  "${SYSTEMCTL[@]}" restart needs-you-hub.service
  first_bind=$(cfg_get bind | cut -d, -f1)
  port=$(cfg_get port)
  ok=0
  for _ in $(seq 1 20); do
    if "$PYTHON" -c 'import sys,urllib.request as u; u.build_opener(u.ProxyHandler({})).open("http://%s:%s/v1/health" % (sys.argv[1], sys.argv[2]), timeout=2)' "$first_bind" "$port" 2>/dev/null; then
      ok=1; break
    fi
    sleep 0.5
  done
  if [ "$ok" -eq 1 ]; then
    echo "needs-you-hub is up: $(cfg_get public_url) (hub_id $(cfg_get hub_id))"
  else
    echo "needs-you-hub did not answer yet; check: $JOURNAL -n 50" >&2
  fi
  if [ "$MODE" = user ]; then
    linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || echo unknown)
    if [ "$linger" != "yes" ]; then
      echo
      echo "IMPORTANT: lingering is off, so the hub stops when you log out and won't start at boot."
      echo "Run this once (it needs sudo):"
      echo "  sudo loginctl enable-linger $(id -un)"
    fi
  fi
else
  echo "not started (--no-start). Run it with: $PYTHON $PREFIX/hub/needs_you_hub.py --config $CONF"
fi

if [ -n "$GENERATED" ]; then
  echo
  echo "Peer secret (shown once). Copy it to the other hub and install there with"
  echo "--peer-secret-file <file holding it>. Keep it out of git and chat logs:"
  echo "  $GENERATED"
fi

# 5. first owner invite, so the Mac can connect
if [ "$INVITE" -eq 1 ] && [ "$NEW_CONFIG" -eq 1 ]; then
  echo
  echo "Connect your Mac to this hub (or, if the Mac app runs its own hub, add this hub as a peer instead):"
  "$ADMIN_BIN" invite create mac --role owner --uses 1 --ttl 72 | sed 's/^/  /'
fi
if [ -n "$JOINED" ]; then
  echo
  echo "This hub now replicates with the hub that invited it: items posted to either show on both,"
  echo "and sender invites made there list this hub too. Check it: needs-you-admin peer list"
fi
cat <<EOF

Next:
  needs-you-admin invite create my-server --role sender --uses 3   # a link for servers/agents
  needs-you-admin invite list
  needs-you-admin token list
Upgrade later with: git pull && $0 $([ "$MODE" = user ] && echo --user)
EOF
