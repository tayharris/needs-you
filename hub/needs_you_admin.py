#!/usr/bin/env python3
"""needs-you-admin: manage a hub's tokens and invites directly in its SQLite database.

    needs_you_admin.py invite create my-server --role sender --uses 3 --ttl 72
    needs_you_admin.py invite create mac --role owner        # connect a Mac app
    needs_you_admin.py invite list
    needs_you_admin.py invite revoke my-server               # by name or id
    needs_you_admin.py token add ci-myrepo --role sender     # a bare token, printed once
    needs_you_admin.py token list
    needs_you_admin.py token revoke ci-myrepo
    needs_you_admin.py token request-update devbox           # ask that machine to update
    needs_you_admin.py token clear-update devbox             # withdraw the request

Config: --config, else $NEEDS_YOU_HUB_CONFIG, else ~/.config/needs-you/hub.json (user
install), else /etc/needs-you/hub.json (system install). --db overrides the database path.

Tokens and invite codes are stored as sha256 hashes; the plaintext is printed once. Changes
are queued in the hub's peer outbox, so the running hub replicates them to every peer.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import needs_you_hub as hubmod  # noqa: E402

USER_CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                           "needs-you", "hub.json")
SYSTEM_CONFIG = "/etc/needs-you/hub.json"


def default_config() -> str:
    if os.environ.get("NEEDS_YOU_HUB_CONFIG"):
        return os.environ["NEEDS_YOU_HUB_CONFIG"]
    if os.path.exists(USER_CONFIG):
        return USER_CONFIG
    return SYSTEM_CONFIG


def public_url(cfg: dict) -> str:
    if cfg.get("public_url"):
        return cfg["public_url"]
    bind = hubmod.normalise_binds(cfg.get("bind"))[0] or "127.0.0.1"
    host = "[%s]" % bind if ":" in bind else bind
    return "http://%s:%d" % (host, int(cfg.get("port") or hubmod.DEFAULT_PORT))


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="needs-you-admin", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--config", default=None, help="hub config file (see above)")
    p.add_argument("--db", help="override the database path from the config")
    p.add_argument("--public-url", help="override the hub's public URL for printed links")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="group")

    tok = sub.add_parser("token", help="manage tokens")
    tsub = tok.add_subparsers(dest="cmd")
    add = tsub.add_parser("add", help="mint a token (printed once)")
    add.add_argument("name", help="who the token is for, e.g. my-server or ci-myrepo")
    add.add_argument("--role", choices=hubmod.ROLES, default="sender",
                     help="sender (create/resolve), reader (list/patch) or owner (reader + invites)")
    tsub.add_parser("list", help="list tokens (never shows the secret)")
    rev = tsub.add_parser("revoke", help="revoke a token by name or id")
    rev.add_argument("name_or_id")
    ru = tsub.add_parser("request-update", help="ask a sender machine to update (this hub only)")
    ru.add_argument("name_or_id")
    cu = tsub.add_parser("clear-update", help="withdraw an update request")
    cu.add_argument("name_or_id")

    inv = sub.add_parser("invite", help="manage invite links")
    isub = inv.add_subparsers(dest="cmd")
    ic = isub.add_parser("create", help="create an invite link (printed once)")
    ic.add_argument("name", help="name prefix for the tokens it mints, e.g. my-server (-> my-server-<host>)")
    ic.add_argument("--role", choices=hubmod.ROLES, default="sender")
    ic.add_argument("--uses", type=int, default=1, help="how many machines may redeem it (default 1)")
    ic.add_argument("--ttl", type=float, default=72.0, metavar="HOURS", help="lifetime (default 72)")
    il = isub.add_parser("list", help="list live invites")
    il.add_argument("--all", action="store_true", help="include used-up, revoked and expired ones")
    ir = isub.add_parser("revoke", help="revoke an invite by name or id")
    ir.add_argument("name_or_id")

    args = p.parse_args(argv)
    if args.group not in ("token", "invite") or not args.cmd:
        p.print_help()
        return 2

    cfg_file = args.config or default_config()
    cfg_path = cfg_file if os.path.exists(cfg_file) else None
    if cfg_path is None and not args.db:
        sys.stderr.write("config %s not found (pass --config or --db)\n" % cfg_file)
        return 2
    cfg = hubmod.load_config(cfg_path, {"db": args.db})
    store = hubmod.Store(cfg["db"], str(cfg["hub_id"]), cfg["peers"],
                         retention_days=float(cfg["retention_days"]))
    try:
        if args.group == "token":
            return token_cmd(args, cfg, store)
        return invite_cmd(args, cfg, store)
    finally:
        store.close()


def token_cmd(args: argparse.Namespace, cfg: dict, store: hubmod.Store) -> int:
    if args.cmd == "add":
        try:
            token, rec = store.add_token(args.name, args.role)
        except ValueError as e:
            sys.stderr.write("error: %s\n" % e)
            return 1
        if args.json:
            print(json.dumps({"id": rec["id"], "name": rec["name"], "role": rec["role"], "token": token}))
        else:
            print(token)
            sys.stderr.write("Added %s token %r (id %s). This is the only time the token is "
                             "shown.\n" % (rec["role"], rec["name"], rec["id"]))
            if cfg["peers"]:
                sys.stderr.write("Queued for replication to %d peer(s).\n" % len(cfg["peers"]))
        return 0
    if args.cmd == "list":
        rows = store.list_tokens()
        requests = store.update_requests()
        if args.json:
            print(json.dumps([{"id": r["id"], "name": r["name"], "role": r["role"],
                               "created_at": hubmod.fmt_ts(r["created_at"]),
                               "revoked_at": hubmod.fmt_ts(r["revoked_at"]),
                               "open_items": r["open_items"],
                               "update_requested_at": hubmod.fmt_ts(requests.get(r["id"]))} for r in rows], indent=2))
            return 0
        print("%-26s  %-28s  %-6s  %-8s  %-5s  %s" % ("ID", "NAME", "ROLE", "STATE", "OPEN", "CREATED"))
        for r in rows:
            print("%-26s  %-28s  %-6s  %-8s  %-5d  %s%s" % (
                r["id"], r["name"], r["role"], "revoked" if r["revoked_at"] else "active",
                r["open_items"], hubmod.fmt_ts(r["created_at"]),
                "  update requested" if r["id"] in requests and not r["revoked_at"] else ""))
        return 0
    if args.cmd in ("request-update", "clear-update"):
        try:
            rec = (store.request_update(args.name_or_id) if args.cmd == "request-update"
                   else store.clear_update_request(args.name_or_id))
        except hubmod.ApiError as e:
            sys.stderr.write("error: %s\n" % e.message)
            return 1
        if rec is None:
            sys.stderr.write("no active token named or with id %r\n" % args.name_or_id)
            return 1
        if args.json:
            print(json.dumps({"id": rec["id"], "name": rec["name"],
                              "update_requested_at": hubmod.fmt_ts(rec["update_requested_at"])}))
        elif rec["update_requested_at"]:
            print("update requested for %s (%s); it sees the request on its next call to this hub" % (rec["name"], rec["id"]))
        else:
            print("cleared the update request for %s (%s)" % (rec["name"], rec["id"]))
        return 0
    if args.cmd == "revoke":
        recs = store.revoke_token(args.name_or_id)
        if not recs:
            sys.stderr.write("no active token named or with id %r\n" % args.name_or_id)
            return 1
        for r in recs:
            print("revoked %s (%s)" % (r["name"], r["id"]))
        return 0
    return 2


def invite_cmd(args: argparse.Namespace, cfg: dict, store: hubmod.Store) -> int:
    if args.cmd == "create":
        try:
            code, rec = store.create_invite(args.name, args.role, args.uses, args.ttl, created_by="admin")
        except hubmod.ApiError as e:
            sys.stderr.write("error: %s\n" % e.message)
            return 1
        url = args.public_url or public_url(cfg)
        links = hubmod.invite_links(url, code, rec["role"])
        expires = hubmod.fmt_ts(rec["expires_at"])
        if args.json:
            out = {"code": code, "id": rec["id"], "name": rec["name"], "role": rec["role"],
                   "uses": rec["uses"], "expires_at": expires}
            out.update(links)
            print(json.dumps(out, indent=2))
            return 0
        print("Invite %r: role %s, %d use%s, expires %s" % (rec["name"], rec["role"], rec["uses"],
                                                          "" if rec["uses"] == 1 else "s", expires))
        print()
        if rec["role"] == "sender":
            print("Join URL (open it to read what it does):")
            print("  %s" % links["join_url"])
            print()
            print("One-liner, on the machine to connect:")
            print("  %s" % links["install_command"])
            print()
            print("Or paste this to an agent on that machine:")
            print("  %s" % links["agent_prompt"])
        else:
            print("Open this on the Mac (NeedsYou.app adds the hub and its token):")
            print("  %s" % links["mac_url"])
            print()
            print("Instructions page: %s" % links["join_url"])
        if not cfg.get("public_url") and not args.public_url:
            sys.stderr.write("\nnote: no public_url in the config; links use %s. Set \"public_url\" "
                             "(e.g. the MagicDNS URL) so other machines can reach it.\n" % url)
        return 0
    if args.cmd == "list":
        rows = store.list_invites(include_dead=args.all)
        if args.json:
            print(json.dumps([{"id": r["id"], "name": r["name"], "role": r["role"], "uses": r["uses"],
                               "left": r["left"], "live": r["live"],
                               "expires_at": hubmod.fmt_ts(r["expires_at"]),
                               "revoked_at": hubmod.fmt_ts(r["revoked_at"])} for r in rows], indent=2))
            return 0
        print("%-26s  %-20s  %-6s  %-9s  %-8s  %s" % ("ID", "NAME", "ROLE", "LEFT/USES", "STATE", "EXPIRES"))
        for r in rows:
            state = "live" if r["live"] else ("revoked" if r["revoked_at"] else "dead")
            print("%-26s  %-20s  %-6s  %-9s  %-8s  %s" % (
                r["id"], r["name"], r["role"], "%d/%d" % (r["left"], r["uses"]), state,
                hubmod.fmt_ts(r["expires_at"])))
        return 0
    if args.cmd == "revoke":
        recs = store.revoke_invite(args.name_or_id)
        if not recs:
            sys.stderr.write("no live invite named or with id %r\n" % args.name_or_id)
            return 1
        for r in recs:
            print("revoked invite %s (%s); tokens it already minted stay valid" % (r["name"], r["id"]))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
