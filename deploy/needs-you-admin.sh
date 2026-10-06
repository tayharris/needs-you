#!/bin/sh
# needs-you-admin wrapper, installed to /usr/local/bin/needs-you-admin by scripts/install-hub.sh.
# Runs the admin tool as the hub's service user so the database keeps the right owner.
set -eu
ADMIN=/opt/needs-you/hub/needs_you_admin.py
CONFIG=${NEEDS_YOU_HUB_CONFIG:-/etc/needs-you/hub.json}
if [ "$(id -un)" = "needs-you" ]; then
  exec /usr/bin/python3 "$ADMIN" --config "$CONFIG" "$@"
fi
exec sudo -u needs-you /usr/bin/python3 "$ADMIN" --config "$CONFIG" "$@"
