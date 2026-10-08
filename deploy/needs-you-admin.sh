#!/bin/sh
# needs-you-admin wrapper, installed to /usr/local/bin/needs-you-admin by scripts/install-hub.sh.
# Runs the admin tool as the hub's service user so the database keeps the right owner.
set -eu
ADMIN=/opt/needs-you/hub/needs_you_admin.py
CONFIG=${NEEDS_YOU_HUB_CONFIG:-/etc/needs-you/hub.json}

# A peer invite link is a credential (hard rule 3): `peer join <link>` hands it to the tool on
# stdin as `peer join -`, never on sudo's command line, which sudo logs and ps shows to everyone.
LINK=""
prev2=""
prev=""
for a do
  shift
  if [ -z "$LINK" ] && [ "$prev2" = peer ] && [ "$prev" = join ] && [ "$a" != - ]; then
    LINK=$a
    a=-
  fi
  set -- "$@" "$a"
  prev2=$prev
  prev=$a
done

run() {
  if [ "$(id -un)" = "needs-you" ]; then
    /usr/bin/python3 "$ADMIN" --config "$CONFIG" "$@"
  else
    sudo -u needs-you /usr/bin/python3 "$ADMIN" --config "$CONFIG" "$@"
  fi
}
if [ -n "$LINK" ]; then
  printf '%s\n' "$LINK" | run "$@"
else
  run "$@"
fi
