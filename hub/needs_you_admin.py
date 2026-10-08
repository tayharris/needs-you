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
    needs_you_admin.py invite create hub-b --role peer       # pair another hub with this one
    needs_you_admin.py peer join http://hub-a.example.ts.net:8765/join/nyi_...  # redeem one here
    needs_you_admin.py peer list                             # every peer (never the secrets)
    needs_you_admin.py peer remove hub-b                     # by hub id, URL or name

Config: --config, else $NEEDS_YOU_HUB_CONFIG, else ~/.config/needs-you/hub.json (user
install), else /etc/needs-you/hub.json (system install). --db overrides the database path.

Tokens and invite codes are stored as sha256 hashes; the plaintext is printed once. Changes
are queued in the hub's peer outbox, so the running hub replicates them to every peer.
Peer secrets (from `peer join`, or a peer invite another hub redeemed here) stay in the
database and are never printed; the running hub picks up added and removed peers within 5 s.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

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
    ic.add_argument("--role", choices=hubmod.INVITE_ROLES, default="sender",
                    help="sender, reader, owner (a Mac app), or peer (another hub; one use)")
    ic.add_argument("--uses", type=int, default=1, help="how many machines may redeem it (default 1)")
    ic.add_argument("--ttl", type=float, default=None, metavar="HOURS",
                    help="lifetime (default 72; a peer invite 1, at most 24)")
    il = isub.add_parser("list", help="list live invites")
    il.add_argument("--all", action="store_true", help="include used-up, revoked and expired ones")
    ir = isub.add_parser("revoke", help="revoke an invite by name or id")
    ir.add_argument("name_or_id")

    peer = sub.add_parser("peer", help="hubs this hub replicates with")
    psub = peer.add_subparsers(dest="cmd")
    pj = psub.add_parser("join", help="redeem another hub's peer invite (its join URL) for this hub")
    pj.add_argument("link", help="the peer invite's join URL, http(s)://<hub>/join/nyi_...")
    psub.add_parser("list", help="list peers (never shows secrets)")
    pr = psub.add_parser("remove", help="stop replicating with a peer from a peer invite")
    pr.add_argument("which", help="its hub id, URL or name")

    args = p.parse_args(argv)
    if args.group not in ("token", "invite", "peer") or not args.cmd:
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
        if args.group == "peer":
            return peer_cmd(args, cfg, store)
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
        ttl = args.ttl if args.ttl is not None else (
            hubmod.PEER_INVITE_TTL_HOURS if args.role == hubmod.PEER_ROLE else 72.0)
        try:
            code, rec = store.create_invite(args.name, args.role, args.uses, ttl, created_by="admin")
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
        if rec["role"] == hubmod.PEER_ROLE:
            print("On the other hub (a server), from a checkout of needs-you:")
            print("  %s" % links["install_command"])
            print()
            print("Or, where a hub already runs: needs-you-admin peer join %s" % links["join_url"])
        elif rec["role"] == "sender":
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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """The invite code is a credential: never follow a redirect with it."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def parse_join_link(link: str) -> Tuple[str, str]:
    """(hub URL, code) from a peer invite's join URL: http(s)://<hub>[/prefix]/join/<code>."""
    parts = urllib.parse.urlsplit(link.strip())
    head, sep, code = parts.path.rstrip("/").rpartition("/join/")
    if parts.scheme not in ("http", "https") or not parts.hostname or not sep or "@" in parts.netloc \
            or not code.startswith("nyi_") or "/" in code or parts.query or parts.fragment:
        raise ValueError("not a join URL (http(s)://<hub>/join/nyi_...)")
    return "%s://%s%s" % (parts.scheme, parts.netloc, head), code


def redeem_peer(hub: str, code: str, me: Dict[str, Any], timeout: float = 15.0) -> Dict[str, Any]:
    """POST the peer invite to the hub that made it. Raises RuntimeError with a sentence."""
    body = json.dumps({"code": code, "host": socket.gethostname().split(".")[0], "peer": me}).encode("utf-8")
    req = urllib.request.Request(hub + "/v1/invites/redeem", data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    try:
        with opener.open(req, timeout=timeout) as resp:
            out = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode("utf-8") or "{}")
        except ValueError:
            err = {}
        msg = hubmod.safe_text(err.get("message") or "HTTP %d" % e.code, 300)
        if e.code == 404:
            msg = "the link is unknown, expired or already used; make a new peer invite"
        raise RuntimeError("%s refused the peer invite: %s" % (hub, msg))
    except (OSError, ValueError) as e:
        raise RuntimeError("could not reach %s: %s" % (hub, hubmod.safe_text(str(e), 200)))
    if not isinstance(out, dict) or out.get("role") != hubmod.PEER_ROLE \
            or not isinstance(out.get("peer_secret"), str) or len(out["peer_secret"]) < 16 \
            or not isinstance(out.get("link_id"), str) or not hubmod.PEER_LINK_ID_RE.match(out["link_id"]):
        raise RuntimeError("%s did not answer like a needs-you hub that supports peer invites" % hub)
    return out


def peer_cmd(args: argparse.Namespace, cfg: dict, store: hubmod.Store) -> int:
    if args.cmd == "join":
        try:
            hub, code = parse_join_link(args.link)
        except ValueError as e:
            sys.stderr.write("error: %s\n" % e)
            return 2
        me = {"url": args.public_url or public_url(cfg), "hub_id": str(cfg["hub_id"]),
              "schema": hubmod.SCHEMA_VERSION}
        try:
            me["url"] = hubmod.normalise_peer_url(me["url"])
        except ValueError:
            sys.stderr.write("error: this hub's public_url %r isn't an http(s)://host[:port] URL\n" % me["url"])
            return 2
        host = urllib.parse.urlsplit(me["url"]).hostname or ""
        if host in ("127.0.0.1", "localhost", "::1") and urllib.parse.urlsplit(hub).hostname not in (
                "127.0.0.1", "localhost", "::1"):
            sys.stderr.write("warning: this hub's public_url is %s, which the other hub can't reach. "
                             "Set public_url (the MagicDNS URL) first.\n" % me["url"])
        try:
            out = redeem_peer(hub, code, me)
        except RuntimeError as e:
            sys.stderr.write("error: %s\n" % e)
            return 1
        try:
            url = hubmod.normalise_peer_url(out.get("hub_url") or hub)
        except ValueError:
            url = hubmod.normalise_peer_url(hub)
        hub_id = out.get("hub_id") if isinstance(out.get("hub_id"), str) and hubmod.HUB_ID_RE.match(
            out.get("hub_id") or "") else ""
        name = out.get("name") if isinstance(out.get("name"), str) else ""
        link = store.add_peer_link(url, out["link_id"], hub_id, hubmod.safe_text(name, 40), out["peer_secret"])
        if args.json:
            print(json.dumps({"url": link["url"], "hub_id": link["hub_id"], "name": link["name"]}))
        else:
            print("joined %s (%s): this hub now replicates with it" % (link["url"], link["hub_id"] or "?"))
            their = out.get("schema")
            if isinstance(their, int) and not isinstance(their, bool) and their > hubmod.SCHEMA_VERSION:
                sys.stderr.write("note: %s runs a newer needs-you (schema %d, this hub %d); upgrade this "
                                 "hub so it keeps every field\n" % (url, their, hubmod.SCHEMA_VERSION))
        return 0
    if args.cmd == "list":
        rows = [{"url": p, "hub_id": None, "name": None, "source": "config", "added_at": None}
                for p in cfg["peers"]]
        for link in store.peer_links():
            rows = [r for r in rows if r["url"] != link["url"]]
            rows.append({"url": link["url"], "hub_id": link["hub_id"] or None, "name": link["name"] or None,
                         "source": "invite", "added_at": hubmod.fmt_ts(link["added_at"])})
        if args.json:
            print(json.dumps(rows, indent=2))
            return 0
        print("%-40s  %-20s  %-16s  %-7s  %s" % ("URL", "HUB ID", "NAME", "SOURCE", "ADDED"))
        for r in rows:
            print("%-40s  %-20s  %-16s  %-7s  %s" % (r["url"], r["hub_id"] or "-", r["name"] or "-",
                                                    r["source"], r["added_at"] or "-"))
        return 0
    if args.cmd == "remove":
        removed = store.remove_peer_link(args.which)
        if not removed:
            if args.which.rstrip("/") in cfg["peers"]:
                sys.stderr.write("%s is in the config's peers; remove it there (install-hub.sh --peer ...) "
                                 "and restart the hub\n" % args.which)
            else:
                sys.stderr.write("no peer with hub id, URL or name %r\n" % args.which)
            return 1
        for r in removed:
            print("removed %s (%s); its secret is gone, so remove this hub on that side too"
                  % (r["url"], r["hub_id"] or "?"))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
