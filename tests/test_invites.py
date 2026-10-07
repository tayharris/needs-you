from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import types
import unittest
import urllib.parse

from support import (OPENER, ROOT, FakeClock, HubTestCase, free_port, hubmod, request,
                     wait_until)

ADMIN = os.path.join(ROOT, "hub", "needs_you_admin.py")
HUB = os.path.join(ROOT, "hub", "needs_you_hub.py")
OWNER = "owner-secret-0123456789abcdef"


def get_raw(url):
    import urllib.error
    try:
        with OPENER.open(url, timeout=5) as resp:
            return resp.status, resp.headers.get("Content-Type", ""), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read()


class InviteCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock(time.time())
        self.hub = self.make_hub("hub-a", clock=self.clock, redeem_fail_limit=5,
                                 public_url="http://hub-a.example.ts.net:8765",
                                 peers=[], maintenance_seconds=0)
        self.hub.store.ensure_token("this-mac", "owner", OWNER)
        self.sender, self.reader = self.tokens(self.hub)

    def invite(self, token=OWNER, **body):
        body.setdefault("name", "srv")
        return request("POST", self.hub.url + "/v1/invites", token, body)

    def redeem(self, code, host="box", hub=None):
        return request("POST", (hub or self.hub).url + "/v1/invites/redeem", None,
                       {"code": code, "host": host})


class Create(InviteCase):
    def test_owner_only(self):
        self.assertEqual(self.invite(token=self.reader)[0], 403)
        self.assertEqual(self.invite(token=self.sender)[0], 403)
        self.assertEqual(self.invite(token=None)[0], 401)
        status, body = self.invite(uses=3, ttl_hours=1)
        self.assertEqual(status, 201)
        pub = "http://hub-a.example.ts.net:8765"
        self.assertEqual(body["join_url"], pub + "/join/" + body["code"])
        self.assertEqual(body["mac_url"], "needsyou://connect?hub=%s&code=%s"
                         % (urllib.parse.quote(pub, safe=""), body["code"]))
        self.assertEqual(body["role"], "sender")
        self.assertIn("expires_at", body)
        self.assertEqual(body["install_command"],
                         "curl -fsSL %s/install.sh | bash -s -- --yes --claude-hooks user --skill --alerts"
                         % body["join_url"])
        self.assertEqual(body["agent_prompt"],
                         "Set up needs-you alerts on this machine: read %s and follow it. If this machine "
                         "runs Claude Code, use --claude-hooks user --skill --alerts." % body["join_url"])
        # >= 128 bits, url-safe, and only the hash is stored
        code = body["code"]
        self.assertGreaterEqual(len(code) - len("nyi_"), 22)
        self.assertRegex(code, r"^[A-Za-z0-9_-]+$")
        with self.hub.store.lock:
            dump = "\n".join(self.hub.store.conn.iterdump())
        self.assertNotIn(code, dump)
        self.assertIn(hubmod.hash_token(code), dump)

    def test_validation(self):
        for body in ({"name": "bad name"}, {"role": "admin"}, {"uses": 0}, {"uses": 101},
                     {"uses": "3"}, {"ttl_hours": 0}, {"ttl_hours": 99999}):
            with self.subTest(body):
                self.assertEqual(self.invite(**body)[0], 400)

    def test_owner_reads_but_cannot_send(self):
        self.assertEqual(request("GET", self.hub.url + "/v1/items", OWNER)[0], 200)
        self.assertEqual(request("POST", self.hub.url + "/v1/items", OWNER, {"title": "t"})[0], 403)
        status, body = request("GET", self.hub.url + "/v1/invites", OWNER)
        self.assertEqual(status, 200)
        self.assertEqual(request("GET", self.hub.url + "/v1/invites", self.reader)[0], 403)


class Redeem(InviteCase):
    def test_multi_use_mints_a_token_each(self):
        _, inv = self.invite(uses=3)
        tokens = []
        for host in ("box1", "box2", "box1"):
            status, body = self.redeem(inv["code"], host)
            self.assertEqual(status, 200, body)
            self.assertEqual(body["role"], "sender")
            self.assertEqual(body["hub_id"], "hub-a")
            # redeemed from this machine: the loopback URL first, then public_url
            self.assertEqual(body["hub_urls"], [self.hub.url, "http://hub-a.example.ts.net:8765"])
            tokens.append(body)
        self.assertEqual([t["name"] for t in tokens], ["srv-box1", "srv-box2", "srv-box1-2"])
        self.assertEqual(len({t["token"] for t in tokens}), 3)
        for t in tokens:
            status, _ = request("POST", self.hub.url + "/v1/items", t["token"], {"key": t["name"], "title": "x"})
            self.assertEqual(status, 201)
        status, body = self.redeem(inv["code"], "box4")
        self.assertEqual(status, 404)
        self.assertEqual(body["message"], "invite not found, expired or used up")
        # each token is revocable alone
        self.hub.store.revoke_token("srv-box2")
        self.assertEqual(request("POST", self.hub.url + "/v1/items", tokens[1]["token"], {"title": "x"})[0], 401)
        self.assertEqual(request("POST", self.hub.url + "/v1/items", tokens[0]["token"], {"title": "x"})[0], 201)

    def test_expiry_and_revoke(self):
        _, a = self.invite(ttl_hours=1)
        _, b = self.invite(name="other")
        self.clock.advance(3601)
        self.assertEqual(self.redeem(a["code"])[0], 404)
        self.assertEqual(get_raw(self.hub.url + "/join/" + a["code"])[0], 404)
        self.assertEqual(len(self.hub.store.revoke_invite("other")), 1)
        self.assertEqual(self.redeem(b["code"])[0], 404)
        self.assertEqual(self.redeem("nyi_" + "x" * 32)[0], 404)
        self.assertEqual(self.redeem(None)[0], 404)

    def test_rate_limit_failed_redeems(self):
        _, inv = self.invite()
        for _ in range(5):
            self.assertEqual(self.redeem("nyi_wrong")[0], 404)
        status, body = self.redeem(inv["code"])
        self.assertEqual(status, 429)
        self.assertEqual(body["error"], "rate_limited")
        self.assertEqual(get_raw(self.hub.url + "/join/" + inv["code"])[0], 429)
        self.hub.limiter.fails.clear()
        self.assertEqual(self.redeem(inv["code"])[0], 200)

    def test_successes_are_not_rate_limited(self):
        _, inv = self.invite(uses=8)
        for i in range(8):
            self.assertEqual(self.redeem(inv["code"], "h%d" % i)[0], 200)


class JoinAndDownloads(InviteCase):
    def test_join_markdown_for_sender(self):
        _, inv = self.invite(uses=2)
        status, ctype, data = get_raw(self.hub.url + "/join/" + inv["code"])
        self.assertEqual(status, 200)
        self.assertTrue(ctype.startswith("text/markdown"))
        text = data.decode()
        self.assertIn("curl -fsSL %s/install.sh | bash -s -- --yes" % inv["join_url"], text)
        for opt in ("--claude-hooks", "--skill", "--orca", "--context", "--force", "Posting rules"):
            self.assertIn(opt, text)
        self.assertIn("2 uses left", text)
        # viewing the page doesn't spend a use
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 2)

    def test_join_for_reader_points_to_the_mac(self):
        _, inv = self.invite(role="owner", name="mac")
        _, _, data = get_raw(self.hub.url + "/join/" + inv["code"])
        self.assertIn(inv["mac_url"], data.decode())
        self.assertNotIn("install.sh", data.decode())
        status, ctype, script = get_raw(self.hub.url + "/join/" + inv["code"] + "/install.sh")
        self.assertEqual(status, 200)
        self.assertIn("ROLE='owner'", script.decode())

    def test_spent_link_still_serves_page_and_script(self):
        _, inv = self.invite(uses=1)
        self.assertEqual(self.redeem(inv["code"])[0], 200)
        status, _, data = get_raw(self.hub.url + "/join/" + inv["code"])
        self.assertEqual(status, 200)
        self.assertIn("no uses left", data.decode())
        status, _, script = get_raw(self.hub.url + "/join/" + inv["code"] + "/install.sh")
        self.assertEqual(status, 200)
        self.assertIn("USES_LEFT='0'", script.decode())
        self.assertEqual(self.redeem(inv["code"])[0], 404)  # but it can't mint another token
        # listed for the owner (so it can be revoked), with nothing left
        _, body = request("GET", self.hub.url + "/v1/invites", OWNER)
        self.assertEqual([(i["name"], i["left"]) for i in body["invites"]], [("srv", 0)])
        # an hour past the grace period it's still there; gone once it expires
        self.clock.advance(hubmod.INVITE_GRACE_MS / 1000 + 3600)
        self.hub.store.purge()
        self.assertEqual(get_raw(self.hub.url + "/join/" + inv["code"])[0], 200)
        self.clock.advance(72 * 3600)
        self.hub.store.purge()
        self.assertEqual(get_raw(self.hub.url + "/join/" + inv["code"])[0], 404)

    def test_dead_link_script_fails_loudly(self):
        _, inv = self.invite()
        self.hub.store.revoke_invite("srv")
        for code in (inv["code"], "nyi_unknown"):
            status, ctype, script = get_raw(self.hub.url + "/join/" + code + "/install.sh")
            # 200 on purpose: `curl -f` swallows a 4xx body and bash then exits 0
            self.assertEqual(status, 200)
            self.assertIn("shellscript", ctype)
            text = script.decode()
            self.assertIn("unknown, expired or revoked", text)
            self.assertTrue(text.rstrip().endswith("exit 1"))
            self.assertNotIn(code, text)
            self.assertEqual(get_raw(self.hub.url + "/join/" + code)[0], 404)

    def test_install_script_is_baked(self):
        _, inv = self.invite()
        status, ctype, data = get_raw(self.hub.url + "/join/" + inv["code"] + "/install.sh")
        self.assertEqual(status, 200)
        self.assertIn("shellscript", ctype)
        text = data.decode()
        self.assertTrue(text.startswith("#!/usr/bin/env bash"))
        self.assertIn("CODE='%s'" % inv["code"], text)
        self.assertIn("HUB_URL='http://hub-a.example.ts.net:8765'", text)
        self.assertNotIn("__NY_", text)

    def test_downloads_allow_list(self):
        for name, (rel, _ctype) in hubmod.DOWNLOADS.items():
            with self.subTest(name):
                status, _, data = get_raw(self.hub.url + "/dl/" + name)
                self.assertEqual(status, 200)
                with open(os.path.join(ROOT, rel), "rb") as fh:
                    self.assertEqual(data, fh.read())
        for bad in ("hub.db", "..%2Fhub%2Fneeds_you_hub.py", "needs_you_hub.py", "", "needs-you/x"):
            with self.subTest(bad):
                self.assertEqual(get_raw(self.hub.url + "/dl/" + bad)[0], 404)

    def test_health_stats(self):
        status, body = request("GET", self.hub.url + "/v1/health")
        self.assertEqual(status, 200)
        for k in ("db_bytes", "items", "open_items", "live_invites", "outbox_pending"):
            self.assertIn(k, body["stats"])
        self.assertNotIn("outbox", body["stats"])
        _, body = request("GET", self.hub.url + "/v1/health", self.reader)
        self.assertEqual(body["stats"]["outbox"], {})


class LocalFirst(InviteCase):
    def test_only_redeems_from_this_machine_get_loopback_first(self):
        pub = "http://hub-a.example.ts.net:8765"
        self.assertEqual(self.hub.hub_urls(), [pub])
        self.assertEqual(self.hub.hub_urls(local_first=True), [self.hub.url, pub])
        for ip, local in (("127.0.0.1", True), ("::1", True), ("::ffff:127.0.0.1", True),
                          ("100.64.0.9", False), ("", False)):
            with self.subTest(ip):
                self.assertEqual(self.hub.is_local_client(ip), local)

    def test_own_tailnet_bind_counts_as_local(self):
        # The Mac's hub binds 127.0.0.1 and its tailnet IP. Running the one-liner on the Mac
        # with the MagicDNS URL connects from that tailnet IP. (A fake second listener: a
        # real tailnet address can't be bound here.)
        fake = types.SimpleNamespace(server_address=("100.64.0.9", self.hub.port))
        self.hub.servers.append(fake)
        try:
            self.assertTrue(self.hub.is_local_client("100.64.0.9"))
            self.assertFalse(self.hub.is_local_client("100.64.0.10"))
            self.assertEqual(self.hub.loopback_url, self.hub.url)
        finally:
            self.hub.servers.remove(fake)


class Revoke(InviteCase):
    def test_owner_lists_and_revokes_tokens(self):
        _, inv = self.invite(uses=2)
        _, box1 = self.redeem(inv["code"], "box1")
        self.assertEqual(request("GET", self.hub.url + "/v1/tokens", self.reader)[0], 403)
        self.assertEqual(request("DELETE", self.hub.url + "/v1/tokens/srv-box1", self.reader)[0], 403)
        status, body = request("GET", self.hub.url + "/v1/tokens", OWNER)
        self.assertEqual(status, 200)
        rows = {t["name"]: t for t in body["tokens"]}
        self.assertIn("srv-box1", rows)
        self.assertTrue(rows["this-mac"]["current"])
        self.assertFalse(rows["srv-box1"]["current"])
        self.assertNotIn("hash", rows["srv-box1"])
        self.assertNotIn(box1["token"], json.dumps(body))
        # by id
        status, body = request("DELETE", self.hub.url + "/v1/tokens/" + rows["srv-box1"]["id"], OWNER)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["revoked"][0]["name"], "srv-box1")
        self.assertEqual(request("POST", self.hub.url + "/v1/items", box1["token"], {"title": "x"})[0], 401)
        _, body = request("GET", self.hub.url + "/v1/tokens", OWNER)
        self.assertNotIn("srv-box1", [t["name"] for t in body["tokens"]])
        # again: nothing active by that name
        self.assertEqual(request("DELETE", self.hub.url + "/v1/tokens/srv-box1", OWNER)[0], 404)
        # never the token making the request
        status, body = request("DELETE", self.hub.url + "/v1/tokens/this-mac", OWNER)
        self.assertEqual(status, 400)
        self.assertEqual(request("GET", self.hub.url + "/v1/items", OWNER)[0], 200)

    def test_owner_revokes_invites(self):
        _, inv = self.invite(uses=3)
        self.assertEqual(request("DELETE", self.hub.url + "/v1/invites/" + inv["id"], self.reader)[0], 403)
        status, body = request("DELETE", self.hub.url + "/v1/invites/" + inv["id"], OWNER)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["revoked"], [{"id": inv["id"], "name": "srv"}])
        self.assertEqual(self.redeem(inv["code"])[0], 404)
        self.assertEqual(request("GET", self.hub.url + "/v1/invites", OWNER)[1]["invites"], [])
        self.assertEqual(request("DELETE", self.hub.url + "/v1/invites/" + inv["id"], OWNER)[0], 404)
        # by name works too
        self.invite(name="other")
        self.assertEqual(request("DELETE", self.hub.url + "/v1/invites/other", OWNER)[0], 200)


class Replication(HubTestCase):
    def test_invite_replicates_and_redeems_on_a_peer(self):
        a = self.make_hub("hub-a", start=False)
        b = self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        b.set_peers([a.url])
        a.start()
        b.start()
        a.store.ensure_token("this-mac", "owner", OWNER)
        _, inv = request("POST", a.url + "/v1/invites", OWNER, {"name": "srv", "uses": 3})
        self.assertTrue(wait_until(lambda: b.store.invite_by_code(inv["code"]) is not None))
        status, body = request("POST", b.url + "/v1/invites/redeem", None, {"code": inv["code"], "host": "x"})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["hub_urls"], [b.url, a.url])
        status, body2 = request("POST", a.url + "/v1/invites/redeem", None, {"code": inv["code"], "host": "y"})
        self.assertEqual(status, 200)

        def used(h):
            r = h.store.list_invites(include_dead=True)
            return r[0]["left"] if r else None
        self.assertTrue(wait_until(lambda: used(a) == 1 and used(b) == 1), (used(a), used(b)))
        # the token minted on b works on a
        self.assertTrue(wait_until(lambda: request("GET", a.url + "/v1/health", body["token"])[1]
                                   .get("token") is not None))
        request("POST", a.url + "/v1/invites/redeem", None, {"code": inv["code"], "host": "z"})
        self.assertTrue(wait_until(lambda: used(b) == 0))
        self.assertEqual(request("POST", b.url + "/v1/invites/redeem", None,
                                 {"code": inv["code"], "host": "w"})[0], 404)

    def test_counter_merge_is_order_independent(self):
        h = self.make_hub("hub-x", start=False)
        now = h.store.now_ms()
        ts = hubmod.fmt_ts
        base = {"id": "01INV", "name": "srv", "role": "sender", "hash": "a" * 64, "uses": 5,
                "created_at": ts(now), "expires_at": ts(now + 10 ** 7), "updated_at": ts(now),
                "updated_by": "p"}
        self.assertTrue(h.store.apply_invite(dict(base, used={"p": 1})))
        self.assertTrue(h.store.apply_invite(dict(base, used={"q": 2}, updated_at=ts(now + 1))))
        self.assertFalse(h.store.apply_invite(dict(base, used={"p": 1})))
        self.assertEqual(h.store.list_invites()[0]["left"], 2)
        # expired records are never stored
        self.assertFalse(h.store.apply_invite(dict(base, id="01OLD", hash="b" * 64, used={},
                                                   expires_at=ts(now - 1))))
        # a revoked record older than the grace period is not stored either
        old = now - hubmod.INVITE_GRACE_MS - 1000
        self.assertFalse(h.store.apply_invite(dict(base, id="01REV", hash="c" * 64, used={},
                                                   revoked_at=ts(old), updated_at=ts(old))))
        # a used-up one is kept until it expires (its installer still re-runs and uninstalls)
        self.assertTrue(h.store.apply_invite(dict(base, id="01USED", hash="d" * 64, used={"p": 5},
                                                  updated_at=ts(old))))
        h.store.purge()
        self.assertEqual([r["id"] for r in h.store.list_invites(include_spent=True)], ["01INV", "01USED"])


class OwnerToken(HubTestCase):
    def test_owner_token_file_provisions_and_rotates(self):
        path = os.path.join(self.tmp, "owner")
        with open(path, "w") as fh:
            fh.write(OWNER + "\n")
        a = self.make_hub("hub-a", owner_token_file=path)
        self.assertEqual(request("GET", a.url + "/v1/health", OWNER)[1]["token"],
                         {"name": "this-mac", "role": "owner"})
        cfg = dict(a.cfg)
        a.stop()
        with open(path, "w") as fh:
            fh.write("rotated-owner-secret-0123456789")
        b = hubmod.Hub(dict(cfg, port=0))
        self.hubs.append(b)
        b.start()
        self.assertIsNone(request("GET", b.url + "/v1/health", OWNER)[1]["token"])
        self.assertEqual(request("GET", b.url + "/v1/health", "rotated-owner-secret-0123456789")[1]
                         ["token"]["role"], "owner")
        active = [t for t in b.store.list_tokens() if t["name"] == "this-mac" and not t["revoked_at"]]
        self.assertEqual(len(active), 1)
        self.assertEqual(b.store.ensure_token("this-mac", "owner", "rotated-owner-secret-0123456789"),
                         "unchanged")
        # rotating back re-activates nothing stale and keeps one active token
        self.assertEqual(b.store.ensure_token("this-mac", "owner", OWNER), "updated")
        active = [t for t in b.store.list_tokens() if t["name"] == "this-mac" and not t["revoked_at"]]
        self.assertEqual(len(active), 1)

    def test_multiple_binds(self):
        import socket
        try:
            s = socket.socket(socket.AF_INET6)
            s.bind(("::1", 0))
            s.close()
        except OSError:
            self.skipTest("no IPv6 loopback")
        h = self.make_hub("hub-a", bind=["127.0.0.1", "::1"])
        self.assertEqual(len(h.servers), 2)
        for host in ("127.0.0.1", "[::1]"):
            status, body = request("GET", "http://%s:%d/v1/health" % (host, h.port))
            self.assertEqual(status, 200)


class Process(unittest.TestCase):
    def test_flags_only_and_parent_pid(self):
        import tempfile
        import shutil
        tmp = tempfile.mkdtemp(prefix="needs-you-proc-")
        try:
            parent = subprocess.Popen(["sleep", "60"])
            owner = os.path.join(tmp, "owner")
            with open(owner, "w") as fh:
                fh.write(OWNER)
            port = free_port()
            proc = subprocess.Popen(
                [sys.executable, HUB, "--bind", "127.0.0.1", "--port", str(port),
                 "--db", os.path.join(tmp, "h.db"), "--hub-id", "mac", "--public-url",
                 "http://my-mac.example.ts.net:%d" % port, "--owner-token-file", owner,
                 "--parent-pid", str(parent.pid), "--retention-days", "3", "--quiet",
                 "--set", "max_open_per_token=5"],
                stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
            url = "http://127.0.0.1:%d" % port
            self.assertTrue(wait_until(lambda: _up(url), 10))
            _, body = request("GET", url + "/v1/health", OWNER)
            self.assertEqual(body["token"]["role"], "owner")
            _, inv = request("POST", url + "/v1/invites", OWNER, {"name": "srv"})
            self.assertTrue(inv["join_url"].startswith("http://my-mac.example.ts.net:%d/join/" % port))
            parent.send_signal(signal.SIGTERM)
            parent.wait()
            proc.wait(timeout=10)
            self.assertEqual(proc.returncode, 0)
            self.assertIn(b"parent process", proc.stderr.read())
            proc.stderr.close()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


def _up(url):
    try:
        return request("GET", url + "/v1/health", timeout=1)[0] == 200
    except OSError:
        return False


class Admin(unittest.TestCase):
    def test_invite_create_list_revoke(self):
        import tempfile
        import shutil
        tmp = tempfile.mkdtemp(prefix="needs-you-admin-")
        try:
            db = os.path.join(tmp, "h.db")
            env = dict(os.environ, NEEDS_YOU_HUB_CONFIG=os.path.join(tmp, "missing.json"))
            run = lambda *a: subprocess.run([sys.executable, ADMIN, "--db", db, *a],  # noqa: E731
                                            capture_output=True, text=True, env=env, timeout=30)
            r = run("--public-url", "http://hub.example.ts.net:8765", "invite", "create", "my-server",
                    "--role", "sender", "--uses", "3", "--ttl", "72")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("http://hub.example.ts.net:8765/join/nyi_", r.stdout)
            self.assertIn("/install.sh | bash -s -- --yes", r.stdout)
            self.assertIn("Set up needs-you alerts on this machine: read http://hub.example.ts.net:8765/join/",
                          r.stdout)
            r = run("invite", "create", "mac", "--role", "owner")
            self.assertIn("needsyou://connect?hub=", r.stdout)
            r = run("invite", "list")
            self.assertIn("my-server", r.stdout)
            self.assertIn("3/3", r.stdout)
            r = run("invite", "revoke", "my-server")
            self.assertEqual(r.returncode, 0)
            r = run("invite", "list")
            self.assertNotIn("my-server", r.stdout)
            r = run("token", "add", "x", "--role", "owner")
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
