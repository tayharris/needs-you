"""Peer invites (ADR 0012): a hub joins another with a one-use invite and a pairwise secret,
the way a server joins the Mac's own hub (which has no config file and no mesh secret)."""
from __future__ import annotations

import io
import json
import os
import time
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout

from support import OPENER, PEER_SECRET, HubTestCase, hubmod, request, snapshot, wait_until

import needs_you_admin as admin  # noqa: E402  (hub/ is on sys.path via support)

OWNER = "owner-secret-0123456789abcdef"


def get_raw(url):
    import urllib.error
    try:
        with OPENER.open(url, timeout=5) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8")


def _peer_call(method, h, path, secret, link_id=None, body=None):
    import urllib.error
    import urllib.request
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(h.url + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + secret)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if link_id is not None:
        req.add_header(hubmod.PEER_LINK_HEADER, link_id)
    try:
        with OPENER.open(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8") or "{}")


def peer_get(h, secret, link_id=None):
    """GET /v1/replicate/changes as a peer: the secret, and the link id for a link's secret."""
    return _peer_call("GET", h, "/v1/replicate/changes?after=0&limit=5", secret, link_id)


def peer_push(h, secret, link_id=None):
    return _peer_call("POST", h, "/v1/replicate", secret, link_id, {"from_hub": "someone", "items": []})


class PeerCase(HubTestCase):
    def hub(self, name, **extra):
        """A hub like the Mac's: no config peers and no mesh secret."""
        extra.setdefault("peer_secret", "")
        extra.setdefault("maintenance_seconds", 0)
        h = self.make_hub(name, **extra)
        h.store.ensure_token("owner-" + name, "owner", OWNER + name)
        return h

    def owner(self, h):
        return OWNER + h.hub_id

    def peer_invite(self, h, **body):
        body.setdefault("name", "server")
        body.setdefault("role", "peer")
        return request("POST", h.url + "/v1/invites", self.owner(h), body)

    def redeem(self, h, code, peer, **extra):
        body = {"code": code, "host": "box", "peer": peer}
        body.update(extra)
        return request("POST", h.url + "/v1/invites/redeem", None, body)

    def me(self, h):
        return {"url": h.url, "hub_id": h.hub_id, "schema": hubmod.SCHEMA_VERSION}

    def admin(self, h, *argv):
        """needs-you-admin against `h`'s database, with a config naming it."""
        conf = os.path.join(self.tmp, h.hub_id + ".json")
        with open(conf, "w") as fh:
            json.dump({"db": h.cfg["db"], "hub_id": h.hub_id, "public_url": h.url}, fh)
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = admin.main(["--config", conf] + list(argv))
        return rc, out.getvalue(), err.getvalue()

    def join(self, inviter, joiner):
        """`joiner` redeems a peer invite from `inviter` with the admin tool, as install-hub.sh
        --join does, and both hubs start replicating."""
        status, inv = self.peer_invite(inviter)
        self.assertEqual(status, 201, inv)
        rc, out, err = self.admin(joiner, "peer", "join", inv["join_url"])
        self.assertEqual(rc, 0, out + err)
        joiner.sync_peers()  # (the running hub also picks it up by itself within 5 s)
        return inv, out + err


class CreatePeerInvite(PeerCase):
    def test_one_use_short_lived_owner_only(self):
        a = self.hub("hub-a")
        sender, reader = self.tokens(a)
        self.assertEqual(request("POST", a.url + "/v1/invites", reader, {"name": "s", "role": "peer"})[0], 403)
        status, body = self.peer_invite(a)
        self.assertEqual(status, 201, body)
        self.assertEqual(body["role"], "peer")
        self.assertEqual(body["uses"], 1)
        self.assertEqual(body["join_url"], a.url + "/join/" + body["code"])
        self.assertEqual(body["install_command"],
                         "curl -fsSL %s/dl/install-hub.sh | sudo bash -s -- --join '%s'" % (a.url, body["join_url"]))
        self.assertNotIn("mac_url", body)
        self.assertNotIn("agent_prompt", body)
        left = hubmod.parse_ts(body["expires_at"]) - a.store.now_ms()
        self.assertTrue(3500 * 1000 < left <= 3600 * 1000, left)  # 1 hour by default
        for bad, field in (({"uses": 2}, "uses"), ({"ttl_hours": 25}, "ttl_hours"),
                           ({"ttl_hours": 0}, "ttl_hours")):
            status, err = self.peer_invite(a, **bad)
            self.assertEqual((status, err.get("field")), (400, field), bad)
        self.assertEqual(self.peer_invite(a, ttl_hours=24)[0], 201)
        status, err = request("POST", a.url + "/v1/invites", self.owner(a), {"name": "s", "role": "hub"})
        self.assertEqual(status, 400)
        self.assertIn("peer", err["message"])
        listed = request("GET", a.url + "/v1/invites", self.owner(a))[1]["invites"]
        self.assertEqual({i["role"] for i in listed}, {"peer"})

    def test_join_page_and_installer_point_to_install_hub(self):
        a = self.hub("hub-a")
        _, inv = self.peer_invite(a)
        status, _, page = get_raw(inv["join_url"])
        self.assertEqual(status, 200)
        self.assertIn("This invite is for another hub", page)
        self.assertIn(inv["install_command"], page)
        status, headers, script = get_raw(inv["join_url"] + "/install.sh")
        self.assertEqual(status, 200)  # so `curl -f | bash` runs it and fails loudly
        self.assertIn("exit 1", script)
        self.assertIn("install-hub.sh --join", script)
        self.assertEqual(a.store.list_invites()[0]["left"], 1)  # nothing spent

    def test_peer_invites_stay_on_the_hub_that_made_them(self):
        a = self.make_hub("hub-a", start=False, maintenance_seconds=0)
        b = self.make_hub("hub-b", start=False, maintenance_seconds=0)
        a.set_peers([b.url])
        b.set_peers([a.url])
        a.start()
        b.start()
        a.store.ensure_token("owner-hub-a", "owner", OWNER + "hub-a")
        self.assertEqual(self.peer_invite(a)[0], 201)
        status, sender_inv = self.peer_invite(a, role="sender", name="later")
        self.assertEqual(status, 201)
        self.assertTrue(wait_until(lambda: any(i["name"] == "later" for i in b.store.list_invites())))
        self.assertEqual([i["role"] for i in b.store.list_invites()], ["sender"])
        status, changes = request("GET", a.url + "/v1/replicate/changes?after=0", PEER_SECRET)
        self.assertEqual(status, 200)
        self.assertEqual([i["role"] for i in changes["invites"]], ["sender"])


class Redeem(PeerCase):
    def test_refusals_spend_nothing(self):
        a = self.hub("hub-a")
        _, inv = self.peer_invite(a)
        code = inv["code"]
        cases = [
            ({"code": code, "host": "box"}, 400, "peer"),  # a sender-style redeem
            ({"code": code, "peer": "x"}, 400, "peer"),
            ({"code": code, "peer": {"url": "ftp://b.example.ts.net", "hub_id": "b", "schema": 99}}, 400, "peer.url"),
            ({"code": code, "peer": {"url": "http://u@b.example.ts.net", "hub_id": "b", "schema": 99}}, 400, "peer.url"),
            ({"code": code, "peer": {"url": "http://b.example.ts.net/x", "hub_id": "b", "schema": 99}}, 400, "peer.url"),
            ({"code": code, "peer": {"url": "http://b.example.ts.net:8765", "hub_id": "-b", "schema": 99}}, 400, "peer.hub_id"),
            ({"code": code, "peer": {"url": "http://b.example.ts.net:8765", "hub_id": "b", "schema": "9"}}, 400, "peer.schema"),
            ({"code": code, "peer": {"url": "http://b.example.ts.net:8765", "hub_id": "b", "schema": True}}, 400, "peer.schema"),
            ({"code": code, "peer": {"url": "http://b.example.ts.net:8765", "hub_id": "hub-a", "schema": 99}}, 409, None),
            ({"code": code, "peer": {"url": a.url, "hub_id": "b", "schema": 99}}, 409, None),
            ({"code": code, "peer": {"url": "http://b.example.ts.net:8765", "hub_id": "b",
                                     "schema": hubmod.SCHEMA_VERSION - 1}}, 409, None),
        ]
        for body, want, field in cases:
            with self.subTest(body=body):
                status, err = request("POST", a.url + "/v1/invites/redeem", None, body)
                self.assertEqual(status, want, err)
                if field:
                    self.assertEqual(err.get("field"), field)
        status, err = request("POST", a.url + "/v1/invites/redeem", None, cases[-1][0])
        self.assertEqual(err["error"], "peer_outdated")
        self.assertEqual(a.store.list_invites()[0]["left"], 1)
        self.assertEqual(a.store.peer_links(), [])
        self.assertFalse(a.limiter.blocked("127.0.0.1"))  # only unknown codes count as failures

    def test_peer_url_must_be_on_the_tailnet_or_https(self):
        """The inviting hub sends its secret and every record to that URL: plain http only to
        a tailnet name or address (or loopback), never an arbitrary LAN or internet host."""
        a = self.hub("hub-a")
        for url in ("http://intranet.example.com:8765", "http://192.168.1.10:8765", "http://10.0.0.5",
                    "http://devbox:8765", "http://169.254.169.254", "http://hub-b.local:8765"):
            _, inv = self.peer_invite(a)
            status, err = self.redeem(a, inv["code"], {"url": url, "hub_id": "hub-b",
                                                       "schema": hubmod.SCHEMA_VERSION})
            self.assertEqual((status, err.get("field")), (400, "peer.url"), url)
        for url in ("http://hub-b.example.ts.net:8765", "http://100.64.0.7:8765",
                    "http://[fd7a:115c:a1e0::7]:8765", "https://hub-b.example.com", "http://127.0.0.1:9"):
            _, inv = self.peer_invite(a)
            status, err = self.redeem(a, inv["code"], {"url": url, "hub_id": "hub-b-%d" % len(url),
                                                       "schema": hubmod.SCHEMA_VERSION})
            self.assertEqual(status, 200, (url, err))

    def test_a_config_peer_url_cant_be_taken_over_by_an_invite(self):
        """A redeemer naming a mesh peer's URL would get that peer sent a secret it doesn't
        know (and replication with it broken)."""
        a = self.hub("hub-a", start=False, peer_secret=PEER_SECRET)
        a.set_peers(["http://hub-b.example.ts.net:8765"])
        a.start()
        _, inv = self.peer_invite(a)
        status, err = self.redeem(a, inv["code"], {"url": "http://hub-b.example.ts.net:8765", "hub_id": "evil",
                                                   "schema": hubmod.SCHEMA_VERSION})
        self.assertEqual((status, err.get("error")), (409, "conflict"), err)
        self.assertEqual(a.secret_for("http://hub-b.example.ts.net:8765"), PEER_SECRET)

    def test_the_mesh_secret_goes_only_to_config_peers(self):
        a = self.hub("hub-a", start=False, peer_secret=PEER_SECRET)
        a.set_peers(["http://hub-b.example.ts.net:8765"])
        a.start()
        self.assertEqual(a.secret_for("http://hub-b.example.ts.net:8765"), PEER_SECRET)
        self.assertEqual(a.secret_for("http://someone-else.example.ts.net:8765"), "")
        _, inv = self.peer_invite(a)
        _, body = self.redeem(a, inv["code"], {"url": "http://hub-c.example.ts.net:8765", "hub_id": "hub-c",
                                               "schema": hubmod.SCHEMA_VERSION})
        self.assertEqual(a.secret_for("http://hub-c.example.ts.net:8765"), body["peer_secret"])
        # and the changes feed (what peers pull) never carries a link or its secret
        text = json.dumps(request("GET", a.url + "/v1/replicate/changes?after=0&limit=2000", PEER_SECRET)[1])
        self.assertNotIn(body["peer_secret"], text)
        self.assertNotIn("nyp_", text)

    def test_unknown_code_counts_and_a_sender_invite_is_not_a_peer_invite(self):
        a = self.hub("hub-a")
        status, _ = self.redeem(a, "nyi_nope", self.me(a))
        self.assertEqual(status, 404)
        _, inv = self.peer_invite(a, role="sender", name="srv")
        status, err = self.redeem(a, inv["code"], {"url": "http://b.example.ts.net:8765", "hub_id": "b",
                                                   "schema": hubmod.SCHEMA_VERSION})
        self.assertEqual((status, err.get("field")), (400, "peer"))
        self.assertEqual(a.store.list_invites()[0]["left"], 1)

    def test_redeem_returns_a_secret_once_and_stores_the_link(self):
        a = self.hub("hub-a")
        _, inv = self.peer_invite(a, name="pi")
        peer = {"url": "HTTP://B.example.ts.net:8765/", "hub_id": "hub-b", "schema": hubmod.SCHEMA_VERSION}
        status, body = self.redeem(a, inv["code"], peer)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["role"], "peer")
        self.assertTrue(body["peer_secret"].startswith("nyp_") and len(body["peer_secret"]) > 40)
        self.assertEqual((body["hub_id"], body["hub_url"], body["schema"]), ("hub-a", a.url, hubmod.SCHEMA_VERSION))
        self.assertNotIn("token", body)
        self.assertEqual(body["hub_urls"], [a.url, "http://b.example.ts.net:8765"])
        links = a.store.peer_links()
        self.assertEqual([(l["url"], l["hub_id"], l["name"]) for l in links],
                         [("http://b.example.ts.net:8765", "hub-b", "pi")])
        self.assertEqual(links[0]["secret"], body["peer_secret"])
        self.assertIn("http://b.example.ts.net:8765", a.peer_urls())
        # spent: a second redeem is a 404
        self.assertEqual(self.redeem(a, inv["code"], peer)[0], 404)
        # the new peer is in sender invites' hub_urls
        _, s_inv = self.peer_invite(a, role="sender", name="srv")
        status, red = request("POST", a.url + "/v1/invites/redeem", None, {"code": s_inv["code"], "host": "x"})
        self.assertIn("http://b.example.ts.net:8765", red["hub_urls"])
        # the secret authenticates replication with its link id; nothing lists it
        self.assertTrue(body["link_id"].startswith("pl_"))
        self.assertEqual(peer_get(a, body["peer_secret"], body["link_id"])[0], 200)
        self.assertEqual(peer_get(a, "nyp_wrong", body["link_id"])[0], 401)
        for path in ("/v1/peers", "/v1/health", "/v1/invites", "/v1/tokens"):
            text = json.dumps(request("GET", a.url + path, self.owner(a))[1])
            self.assertNotIn(body["peer_secret"], text, path)
            self.assertNotIn("nyp_", text, path)

    def test_each_secret_works_only_for_its_own_link(self):
        """One peer can't pose as another (or as a mesh member), and removing a link revokes
        exactly that peer."""
        a = self.hub("hub-a", start=False, peer_secret=PEER_SECRET)
        a.set_peers(["http://hub-m.example.ts.net:8765"])
        a.start()
        pairs = []
        for name in ("hub-b", "hub-c"):
            _, inv = self.peer_invite(a)
            status, body = self.redeem(a, inv["code"], {"url": "http://%s.example.ts.net:8765" % name,
                                                       "hub_id": name, "schema": hubmod.SCHEMA_VERSION})
            self.assertEqual(status, 200, body)
            pairs.append(body)
        b, c = pairs
        self.assertNotEqual(b["link_id"], c["link_id"])
        self.assertEqual(peer_get(a, b["peer_secret"], b["link_id"])[0], 200)
        self.assertEqual(peer_get(a, b["peer_secret"])[0], 401)               # no link id
        self.assertEqual(peer_get(a, b["peer_secret"], c["link_id"])[0], 401)  # posing as c
        self.assertEqual(peer_get(a, PEER_SECRET, b["link_id"])[0], 401)       # mesh secret as a link
        self.assertEqual(peer_get(a, PEER_SECRET)[0], 200)                     # mesh member
        self.assertEqual(peer_get(a, b["peer_secret"], "pl_nosuchlink")[0], 401)
        # push too
        self.assertEqual(peer_push(a, b["peer_secret"], c["link_id"])[0], 401)
        self.assertEqual(peer_push(a, b["peer_secret"], b["link_id"])[0], 200)
        # removing b revokes b only
        self.assertEqual(request("DELETE", a.url + "/v1/peers/hub-b", self.owner(a))[0], 200)
        self.assertEqual(peer_get(a, b["peer_secret"], b["link_id"])[0], 401)
        self.assertEqual(peer_get(a, c["peer_secret"], c["link_id"])[0], 200)

    def test_rejoin_under_a_new_url_replaces_the_old_link(self):
        a = self.hub("hub-a")
        for url in ("http://b.example.ts.net:8765", "http://b2.example.ts.net:8765"):
            _, inv = self.peer_invite(a)
            status, _ = self.redeem(a, inv["code"], {"url": url, "hub_id": "hub-b",
                                                     "schema": hubmod.SCHEMA_VERSION})
            self.assertEqual(status, 200)
        self.assertEqual([l["url"] for l in a.store.peer_links()], ["http://b2.example.ts.net:8765"])

    def test_without_a_mesh_secret_replication_is_off_until_a_link_exists(self):
        a = self.hub("hub-a")
        self.assertEqual(request("GET", a.url + "/v1/replicate/changes?after=0", "anything")[0], 404)


class Pair(PeerCase):
    def test_a_server_joins_the_macs_hub_and_they_replicate(self):
        mac = self.hub("mac")
        srv = self.hub("srv")
        inv, said = self.join(mac, srv)
        self.assertIn("joined %s (mac)" % mac.url, said)
        self.assertNotIn("nyp_", said)
        self.assertEqual([l["url"] for l in srv.store.peer_links()], [mac.url])
        self.assertEqual(srv.store.peer_links()[0]["secret"], mac.store.peer_links()[0]["secret"])
        self.assertEqual(srv.store.peer_links()[0]["link_id"], mac.store.peer_links()[0]["link_id"])
        self.assertEqual(mac.peer_urls(), [srv.url])

        # a sender set up from the Mac posts to the server; the Mac's hub gets it
        sender, reader = self.tokens(mac)
        self.assertTrue(wait_until(lambda: srv.store.token_by_secret(sender) is not None))
        status, item = request("POST", srv.url + "/v1/items", sender, {
            "key": "deploy", "title": "Approve the deploy",
            "question": {"items": [{"text": "Ship it?", "options": [{"label": "Yes"}, {"label": "No"}]}],
                         "answerable": True}})
        self.assertEqual(status, 201, item)
        self.assertTrue(wait_until(lambda: mac.store.get_item(item["id"]) is not None))
        # the person answers on the Mac; the sender reads the answer on the server
        status, ans = request("POST", mac.url + "/v1/items/%s/answer" % item["id"], reader, {
            "question_id": None, "content_updated_at": item["content_updated_at"],
            "answers": [{"selected": ["Yes"]}]})
        self.assertEqual(status, 200, ans)
        self.assertTrue(wait_until(lambda: (srv.store.get_item(item["id"]) or {}).get("answer")))
        status, got = request("GET", srv.url + "/v1/items/answer?key=deploy&wait=0", sender)
        self.assertEqual((status, got.get("answers")), (200, [{"selected": ["Yes"]}]))
        # a resolve on the Mac reaches the server
        request("POST", mac.url + "/v1/items/resolve", sender, {"key": "deploy"})
        self.assertTrue(wait_until(lambda: srv.store.get_item(item["id"])["status"] == "resolved"))
        self.assertTrue(wait_until(lambda: snapshot(mac) == snapshot(srv)))

        # status on both sides
        health = request("GET", mac.url + "/v1/health", self.owner(mac))[1]
        (p,) = health["peers"]
        self.assertEqual((p["url"], p["hub_id"], p["source"], p["name"]), (srv.url, "srv", "invite", "server"))
        self.assertTrue(wait_until(lambda: mac.peer_status(srv.url)["last_pull_ok"]))
        peers = request("GET", srv.url + "/v1/peers", self.owner(srv))[1]["peers"]
        self.assertEqual([(q["url"], q["source"], q["hub_id"]) for q in peers], [(mac.url, "invite", "mac")])
        self.assertEqual(request("GET", mac.url + "/v1/peers", reader)[0], 403)
        self.assertEqual(request("GET", mac.url + "/v1/peers", sender)[0], 403)

    def test_removing_a_peer_revokes_its_secret(self):
        mac = self.hub("mac")
        srv = self.hub("srv")
        self.join(mac, srv)
        sender, _ = self.tokens(mac)
        self.assertTrue(wait_until(lambda: srv.store.token_by_secret(sender) is not None))
        self.assertEqual(request("DELETE", mac.url + "/v1/peers/nobody", self.owner(mac))[0], 404)
        status, body = request("DELETE", mac.url + "/v1/peers/srv", self.owner(mac))
        self.assertEqual(status, 200, body)
        self.assertEqual(body["removed"], [{"url": srv.url, "hub_id": "srv", "name": "server"}])
        self.assertEqual(mac.peer_urls(), [])
        self.assertNotIn(srv.url, mac.hub_urls())
        self.assertEqual(mac.store.outbox_pending(srv.url), 0)
        # the server's next push is refused and says so in its peer status (404: the Mac's hub
        # has no peers left, so replication is off there; 401 while it has others)
        request("POST", srv.url + "/v1/items", sender, {"key": "after", "title": "after removal"})
        self.assertTrue(wait_until(lambda: "HTTP Error 404" in str(srv.peer_status(mac.url)["last_error"])))
        self.assertIsNone(mac.store.get_item(snapshot(srv)[-1]["id"]))
        # and on the server, the admin tool removes it
        rc, out, _ = self.admin(srv, "peer", "remove", mac.url)
        self.assertEqual(rc, 0)
        self.assertIn("removed", out)
        srv.sync_peers()
        self.assertEqual(srv.peer_urls(), [])

    def test_config_peers_cant_be_removed_over_the_api(self):
        a = self.make_hub("hub-a", start=False, maintenance_seconds=0)
        a.set_peers(["http://hub-b.example.ts.net:8765"])
        a.start()
        a.store.ensure_token("owner-hub-a", "owner", OWNER + "hub-a")
        status, err = request("DELETE", a.url + "/v1/peers/" + urllib.parse.quote(
            "http://hub-b.example.ts.net:8765", safe=""), OWNER + "hub-a")
        self.assertEqual(status, 400, err)
        peers = request("GET", a.url + "/v1/peers", OWNER + "hub-a")[1]["peers"]
        self.assertEqual([(p["url"], p["source"]) for p in peers], [("http://hub-b.example.ts.net:8765", "config")])

    def test_a_mesh_hub_joins_by_invite_and_keeps_its_mesh_secret(self):
        """An existing server mesh (shared secret) adds the Mac with a link: the mesh is left
        as it is, and the Mac never learns the mesh secret."""
        b = self.make_hub("hub-b", start=False, maintenance_seconds=0)
        c = self.make_hub("hub-c", start=False, maintenance_seconds=0)
        b.set_peers([c.url])
        c.set_peers([b.url])
        b.start()
        c.start()
        mac = self.hub("mac")
        self.join(mac, b)
        self.assertEqual(b.peer_urls(), [c.url, mac.url])
        self.assertEqual(b.secret_for(c.url), PEER_SECRET)
        self.assertNotEqual(b.secret_for(mac.url), PEER_SECRET)
        sender, _ = self.tokens(c)
        status, item = request("POST", c.url + "/v1/items", sender, {"key": "k", "title": "from c"})
        self.assertEqual(status, 201)
        # c -> b (mesh secret) -> mac (link): anti-entropy is transitive
        self.assertTrue(wait_until(lambda: mac.store.get_item(item["id"]) is not None, 20))

    def test_the_running_hub_picks_up_admin_changes(self):
        mac = self.hub("mac")
        srv = self.hub("srv")
        _, inv = self.peer_invite(mac)
        rc, _, _ = self.admin(srv, "peer", "join", inv["join_url"])
        self.assertEqual(rc, 0)
        self.assertTrue(wait_until(lambda: mac.url in srv.workers, hubmod.PEER_SYNC_SECONDS + 5))
        rc, out, _ = self.admin(srv, "--json", "peer", "list")
        self.assertEqual(rc, 0)
        self.assertEqual([(p["url"], p["source"]) for p in json.loads(out)], [(mac.url, "invite")])
        self.assertNotIn("nyp_", out)


class AdminTool(PeerCase):
    def test_invite_create_peer(self):
        a = self.hub("hub-a")
        rc, out, err = self.admin(a, "invite", "create", "pi", "--role", "peer")
        self.assertEqual(rc, 0, err)
        self.assertIn("/dl/install-hub.sh | sudo bash -s -- --join", out)
        self.assertIn("needs-you-admin peer join", out)
        (inv,) = a.store.list_invites()
        self.assertEqual((inv["role"], inv["uses"]), ("peer", 1))
        self.assertLessEqual(inv["expires_at"] - inv["created_at"], 3600 * 1000)
        rc, _, err = self.admin(a, "invite", "create", "pi2", "--role", "peer", "--uses", "3")
        self.assertEqual(rc, 1)
        self.assertIn("one use", err)

    def test_join_errors(self):
        a = self.hub("hub-a")
        b = self.hub("hub-b")
        rc, _, err = self.admin(b, "peer", "join", "http://x.example.ts.net/nope")
        self.assertEqual(rc, 2)
        rc, _, err = self.admin(b, "peer", "join", a.url + "/join/nyi_unknown")
        self.assertEqual(rc, 1)
        self.assertIn("unknown, expired or already used", err)
        _, inv = self.peer_invite(a, role="sender", name="srv")
        rc, _, err = self.admin(b, "peer", "join", inv["join_url"])
        self.assertEqual(rc, 1)
        self.assertIn("not for another hub", err)
        self.assertEqual(b.store.peer_links(), [])

    def test_parse_join_link(self):
        self.assertEqual(admin.parse_join_link("http://hub-a.example.ts.net:8765/join/nyi_abc"),
                         ("http://hub-a.example.ts.net:8765", "nyi_abc"))
        self.assertEqual(admin.parse_join_link("https://h.example/prefix/join/nyi_abc/"),
                         ("https://h.example/prefix", "nyi_abc"))
        for bad in ("needsyou://connect?hub=x&code=nyi_a", "http://h/join/abc", "http://u@h/join/nyi_a",
                    "http://h/join/nyi_a?x=1", "ftp://h/join/nyi_a"):
            with self.assertRaises(ValueError, msg=bad):
                admin.parse_join_link(bad)


class Wake(unittest.TestCase):
    def test_a_clock_jump_drops_the_backoff(self):
        w = hubmod.PeerWorker.__new__(hubmod.PeerWorker)
        w._clocks = (1000.0, 50.0)
        w.failures, w.next_push, w.next_pull = 9, 400.0, 200.0
        self.assertFalse(w.check_wake(1010.0, 60.0))  # both clocks moved alike
        self.assertEqual(w.failures, 9)
        self.assertTrue(w.check_wake(5000.0, 61.0))   # an hour asleep, 1 s awake
        self.assertEqual((w.failures, w.next_push, w.next_pull), (0, 0.0, 0.0))
        self.assertFalse(w.check_wake(5001.0, 62.0))


class Redaction(unittest.TestCase):
    def test_peer_secrets_never_reach_a_log_line(self):
        line = hubmod.redact_log('"POST /v1/x HTTP/1.1" Bearer nyp_AbC-123_xyz')
        self.assertNotIn("AbC", line)
        self.assertIn("nyp_<redacted>", line)


if __name__ == "__main__":
    unittest.main()
