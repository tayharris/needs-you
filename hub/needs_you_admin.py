#!/usr/bin/env python3
"""needs-you-admin: manage hub tokens directly in the hub's SQLite database.

    python3 hub/needs_you_admin.py --config /etc/needs-you/hub.json token add hub-d-cron --role sender
    python3 hub/needs_you_admin.py --config /etc/needs-you/hub.json token list
    python3 hub/needs_you_admin.py --config /etc/needs-you/hub.json token revoke hub-d-cron

Tokens are stored as sha256 hashes. The plaintext token is printed once, by `add`.
Changes are queued in the hub's peer outbox, so the running hub replicates them to
every configured peer (and peers also pick them up by anti-entropy).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import needs_you_hub as hubmod  # noqa: E402


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="needs-you-admin", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", default=os.environ.get("NEEDS_YOU_HUB_CONFIG", "/etc/needs-you/hub.json"),
                   help="hub config file (default: %(default)s)")
    p.add_argument("--db", help="override the database path from the config")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="group")
    tok = sub.add_parser("token", help="manage tokens")
    tsub = tok.add_subparsers(dest="cmd")
    add = tsub.add_parser("add", help="mint a token (printed once)")
    add.add_argument("name", help="who the token is for, e.g. devbox or mac-reader")
    add.add_argument("--role", choices=hubmod.ROLES, default="sender",
                     help="sender (create/resolve) or reader (list/patch, for the Mac)")
    tsub.add_parser("list", help="list tokens (never shows the secret)")
    rev = tsub.add_parser("revoke", help="revoke a token by name or id")
    rev.add_argument("name_or_id")
    args = p.parse_args(argv)
    if args.group != "token" or not args.cmd:
        p.print_help()
        return 2

    cfg_path = args.config if args.config and os.path.exists(args.config) else None
    if args.config and cfg_path is None and not args.db:
        sys.stderr.write("config %s not found (pass --config or --db)\n" % args.config)
        return 2
    cfg = hubmod.load_config(cfg_path, {"db": args.db})
    store = hubmod.Store(cfg["db"], str(cfg["hub_id"]), cfg["peers"])
    try:
        if args.cmd == "add":
            try:
                token, rec = store.add_token(args.name, args.role)
            except ValueError as e:
                sys.stderr.write("error: %s\n" % e)
                return 1
            if args.json:
                print(json.dumps({"id": rec["id"], "name": rec["name"], "role": rec["role"],
                                  "token": token}))
            else:
                print(token)
                sys.stderr.write("Added %s token %r (id %s). This is the only time the token is "
                                 "shown.\n" % (rec["role"], rec["name"], rec["id"]))
                if cfg["peers"]:
                    sys.stderr.write("Queued for replication to %d peer(s).\n" % len(cfg["peers"]))
            return 0
        if args.cmd == "list":
            rows = store.list_tokens()
            if args.json:
                print(json.dumps([{"id": r["id"], "name": r["name"], "role": r["role"],
                                   "created_at": hubmod.fmt_ts(r["created_at"]),
                                   "revoked_at": hubmod.fmt_ts(r["revoked_at"]),
                                   "open_items": r["open_items"]} for r in rows], indent=2))
                return 0
            print("%-26s  %-24s  %-6s  %-8s  %-5s  %s" % ("ID", "NAME", "ROLE", "STATE", "OPEN", "CREATED"))
            for r in rows:
                print("%-26s  %-24s  %-6s  %-8s  %-5d  %s" % (
                    r["id"], r["name"], r["role"], "revoked" if r["revoked_at"] else "active",
                    r["open_items"], hubmod.fmt_ts(r["created_at"])))
            return 0
        if args.cmd == "revoke":
            recs = store.revoke_token(args.name_or_id)
            if not recs:
                sys.stderr.write("no active token named or with id %r\n" % args.name_or_id)
                return 1
            for r in recs:
                print("revoked %s (%s)" % (r["name"], r["id"]))
            return 0
    finally:
        store.close()
    return 2


if __name__ == "__main__":
    sys.exit(main())
