"""Security regression tests from the 2026-10-07 audit (docs/security/audit-2026-10-07.md).

Each test tries one bypass or abuse and checks that the hub, CLI or installer refuses it.
"""
from __future__ import annotations

import importlib.machinery
import io
import json
import os
import socket
import sys
import time
import unittest
import urllib.parse
import urllib.request

import test_install
from support import CLI, OPENER, HubTestCase, hubmod, request  # noqa: E402

ApiError = hubmod.ApiError
OWNER = "owner-secret-0123456789abcdef"
OK = {"key": "work:SEC-1:x", "title": "Decide the thing"}


def with_(**kw):
    d = dict(OK)
    d.update(kw)
    return d


def link(url, label="L"):
    return {"label": label, "url": url}


def load_cli():
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("needs_you_cli_sec", CLI)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class SpoofingAndSchemes(unittest.TestCase):
    """Text and link tricks an agent could be talked into posting."""

    REJECTED = [
        ("RLO in title", with_(title="Approve \u202egpj.exe"), "title"),
        ("RLI isolate in title", with_(title="a\u2067b"), "title"),
        ("bidi override in body", with_(body="line\n\u202dforced"), "body"),
        ("bidi override in link label", with_(links=[link("https://a.example", "\u202eRP")]), "links[0].label"),
        ("bidi override in source", with_(source={"agent": "\u202ex"}), "source.agent"),
        ("C1 control in title", with_(title="a\u009bb"), "title"),
        ("zero-width space in url", with_(links=[link("https://git\u200bhub.com/x")]), "links[0].url"),
        ("bidi override in url", with_(links=[link("https://a.example/\u202e")]), "links[0].url"),
        ("BOM in url", with_(links=[link("\ufeffjavascript:alert(1)")]), "links[0].url"),
        ("space inside url", with_(links=[link("https://a.example/x y")]), "links[0].url"),
        ("nbsp inside url", with_(links=[link("https://a.example/\u00a0x")]), "links[0].url"),
        ("javascript mixed case", with_(links=[link("JaVaScRiPt:alert(1)")]), "links[0].url"),
        ("javascript leading space", with_(links=[link("  javascript:alert(1)")]), "links[0].url"),
        ("javascript tab inside", with_(links=[link("java\tscript:alert(1)")]), "links[0].url"),
        ("javascript newline inside", with_(links=[link("java\nscript:alert(1)")]), "links[0].url"),
        ("percent-encoded scheme", with_(links=[link("%6Aavascript:alert(1)")]), "links[0].url"),
        ("data url", with_(links=[link("data:text/html,<b>x</b>")]), "links[0].url"),
        ("file url", with_(links=[link("FILE:///etc/passwd")]), "links[0].url"),
        ("vbscript", with_(links=[link("vbscript:msgbox")]), "links[0].url"),
        ("http", with_(links=[link("http://a.example")]), "links[0].url"),
        ("needsyou connect", with_(links=[link("needsyou://connect?hub=http://x&code=y")]), "links[0].url"),
        ("needsyou other host", with_(links=[link("needsyou://evil/terminal?handle=term_12345678")]), "links[0].url"),
        ("unicode lookalike scheme", with_(links=[link("\uff48ttps://a.example")]), "links[0].url"),
    ]

    ACCEPTED = [
        ("Arabic text", with_(title="\u0645\u0631\u062d\u0628\u0627 approve")),
        ("Hebrew with RLM", with_(body="\u05e9\u05dc\u05d5\u05dd\u200f ok")),
        ("emoji ZWJ sequence", with_(body="team \U0001F469\u200d\U0001F4BB done")),
        ("Persian ZWNJ", with_(body="\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645")),
        ("encoded space in url", with_(links=[link("https://a.example/x%20y")])),
        ("terminal link", with_(links=[link("needsyou://orca/terminal?handle=term_ab12cd34&environment=dev%20box")])),
    ]

    def test_rejected(self):
        for name, payload, field in self.REJECTED:
            with self.subTest(name):
                with self.assertRaises(ApiError) as cm:
                    hubmod.validate_item_input(payload)
                self.assertEqual(cm.exception.status, 400)
                self.assertEqual(cm.exception.field, field)

    def test_accepted(self):
        for name, payload in self.ACCEPTED:
            with self.subTest(name):
                hubmod.validate_item_input(payload)

    def test_link_allowed_matches_validation(self):
        for name, payload, field in self.REJECTED:
            if not field.endswith(".url"):
                continue
            for lk in payload.get("links") or []:
                with self.subTest(name):
                    self.assertFalse(hubmod.link_allowed(lk["url"]))
        self.assertTrue(hubmod.link_allowed("https://a.example/x"))
        self.assertTrue(hubmod.link_allowed("vscode://file/home/dev/x.py"))
        self.assertFalse(hubmod.link_allowed(None))


class Timestamps(unittest.TestCase):
    def test_out_of_range_is_refused(self):
        # 1e13 s is in the year ~318,000: storable, but unprintable, so it would break listings.
        for raw in (1e13, -1, float("inf"), float("nan"), 1e300, "99999999999999999999",
                    "10000000000000", "-5"):
            with self.subTest(raw):
                with self.assertRaises((ValueError, TypeError)):
                    hubmod.parse_ts(raw)

    def test_edges(self):
        self.assertEqual(hubmod.parse_ts(0), 0)
        self.assertEqual(hubmod.parse_ts("9999-12-31T23:59:59.999Z"), hubmod.MAX_TS_MS)
        self.assertEqual(hubmod.fmt_ts(hubmod.MAX_TS_MS), "9999-12-31T23:59:59.999Z")


class HubAbuse(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a", public_url="http://hub-a.example.ts.net:8765",
                                 maintenance_seconds=0)
        self.hub.store.ensure_token("this-mac", "owner", OWNER)
        self.sender, self.reader = self.tokens(self.hub)

    def raw(self, data, timeout=5.0):
        host, port = self.hub.server.server_address[:2]
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.sendall(data)
            chunks = []
            while True:
                try:
                    b = s.recv(65536)
                except socket.timeout:
                    break
                if not b:
                    break
                chunks.append(b)
        return b"".join(chunks)

    def test_far_future_expiry_cannot_break_the_feed(self):
        st, body = request("POST", self.hub.url + "/v1/items", self.sender,
                           with_(expires_at=1e13))
        self.assertEqual(st, 400, body)
        self.assertEqual(body.get("field"), "expires_at")
        st, body = request("POST", self.hub.url + "/v1/items", self.sender, with_(expires_at=float("inf")))
        self.assertEqual(st, 400, body)
        st, body = request("GET", self.hub.url + "/v1/items", self.reader)
        self.assertEqual(st, 200, body)

    def test_far_future_seen_at_is_refused(self):
        st, item = request("POST", self.hub.url + "/v1/items", self.sender, OK)
        self.assertEqual(st, 201)
        st, body = request("PATCH", self.hub.url + "/v1/items/" + item["id"], self.reader,
                           {"seen_at": 9e15})
        self.assertEqual(st, 400, body)
        self.assertEqual(request("GET", self.hub.url + "/v1/items", self.reader)[0], 200)

    def test_negative_content_length_is_refused_without_reading(self):
        # Unauthenticated endpoint; before the fix rfile.read(-1) read until the client hung up.
        t0 = time.time()
        resp = self.raw(b"POST /v1/invites/redeem HTTP/1.0\r\nContent-Length: -1\r\n\r\n{\"code\":")
        self.assertIn(b" 400 ", resp.split(b"\r\n", 1)[0])
        self.assertLess(time.time() - t0, 4)

    def test_deeply_nested_json_is_a_400(self):
        body = b"[" * 50000
        resp = self.raw(b"POST /v1/invites/redeem HTTP/1.0\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        self.assertIn(b" 400 ", resp.split(b"\r\n", 1)[0])

    def test_idle_connections_time_out(self):
        self.assertTrue(0 < hubmod.Handler.timeout <= 120)

    def test_role_matrix(self):
        st, item = request("POST", self.hub.url + "/v1/items", self.sender, OK)
        self.assertEqual(st, 201)
        iid = item["id"]
        u = self.hub.url
        cases = [
            # (method, path, body, {token: expected status})
            ("POST", "/v1/items", OK, {None: 401, "bogus": 401, "reader": 403, "owner": 403}),
            ("POST", "/v1/items/resolve", {"key": "nope"}, {None: 401, "reader": 403, "owner": 403}),
            ("GET", "/v1/items", None, {None: 401, "bogus": 401, "sender": 403, "reader": 200, "owner": 200}),
            ("GET", "/v1/items/" + iid, None, {None: 401, "sender": 403, "reader": 200}),
            ("PATCH", "/v1/items/" + iid, {"seen_at": None}, {None: 401, "sender": 403, "reader": 200}),
            ("GET", "/v1/stream", None, {None: 401, "sender": 403}),
            ("POST", "/v1/invites", {"name": "x"}, {None: 401, "sender": 403, "reader": 403, "owner": 201}),
            ("GET", "/v1/invites", None, {None: 401, "sender": 403, "reader": 403, "owner": 200}),
            ("DELETE", "/v1/invites/x", None, {None: 401, "sender": 403, "reader": 403}),
            ("GET", "/v1/tokens", None, {None: 401, "sender": 403, "reader": 403, "owner": 200}),
            ("DELETE", "/v1/tokens/x", None, {None: 401, "sender": 403, "reader": 403}),
            ("GET", "/v1/replicate/changes", None, {None: 401, "sender": 401, "owner": 401}),
            ("POST", "/v1/replicate", {"items": []}, {None: 401, "owner": 401}),
        ]
        toks = {None: None, "bogus": "ny_not-a-real-token-000000000000", "sender": self.sender,
                "reader": self.reader, "owner": OWNER}
        for method, path, body, want in cases:
            for who, status in want.items():
                with self.subTest(method=method, path=path, who=who):
                    got, resp = request(method, u + path, toks[who], body)
                    self.assertEqual(got, status, resp)

    def test_no_cors_headers(self):
        req = urllib.request.Request(self.hub.url + "/v1/health", method="GET")
        req.add_header("Origin", "https://evil.example")
        with OPENER.open(req, timeout=5) as resp:
            self.assertIsNone(resp.headers.get("Access-Control-Allow-Origin"))

    def test_sql_metacharacters_are_data(self):
        st, body = request("POST", self.hub.url + "/v1/items/resolve", self.sender,
                           {"key": "x' OR '1'='1"})
        self.assertEqual((st, body["resolved"]), (200, 0))
        st, _ = request("GET", self.hub.url + "/v1/items/" + urllib.parse.quote("x' OR 1=1 --", safe=""),
                        self.reader)
        self.assertEqual(st, 404)
        st, body = request("GET", self.hub.url + "/v1/items", self.reader)
        self.assertEqual(st, 200)
        self.assertEqual(len(body["items"]), 0)

    def test_downloads_cannot_traverse(self):
        for path in ("/dl/../hub/needs_you_hub.py", "/dl/..%2Fhub%2Fneeds_you_hub.py",
                     "/dl/%2e%2e/%2e%2e/etc/passwd", "/dl/needs-you/../../etc/passwd", "/dl/"):
            with self.subTest(path):
                resp = self.raw(("GET %s HTTP/1.0\r\n\r\n" % path).encode())
                self.assertIn(b" 404 ", resp.split(b"\r\n", 1)[0])
                self.assertNotIn(b"def main(", resp)

    def test_replicated_items_lose_disallowed_links(self):
        rec = {"id": hubmod.new_ulid(), "key": "work:x:y", "context": "work", "kind": "needs",
               "priority": "normal", "title": "t", "status": "open",
               "created_at": hubmod.fmt_ts(self.hub.store.now_ms()),
               "updated_at": hubmod.fmt_ts(self.hub.store.now_ms()),
               "links": [link("javascript:alert(1)"), link("https://ok.example"),
                         link("needsyou://connect?hub=x&code=y"), "junk"]}
        st, body = request("POST", self.hub.url + "/v1/replicate", "test-peer-secret-0123456789",
                           {"from_hub": "hub-z", "items": [rec]})
        self.assertEqual(st, 200, body)
        got = self.hub.store.get_item(rec["id"])
        self.assertEqual(json.loads(got["links"]), [link("https://ok.example")])

    def test_replicated_items_follow_the_post_rules(self):
        # Scan 2026-10-08: a peer record's link labels, step text, source fields, title, body and
        # key were stored as sent. A label or source field that isn't a string made the Mac
        # app's decoder refuse the whole poll, every item with it.
        now = hubmod.fmt_ts(self.hub.store.now_ms())

        def rec(**kw):
            r = {"id": hubmod.new_ulid(), "key": "work:x:" + hubmod.new_ulid(), "context": "work",
                 "kind": "needs", "priority": "normal", "title": "t", "status": "open",
                 "created_at": now, "updated_at": now}
            r.update(kw)
            return r

        kept = rec(links=[{"label": 5, "url": "https://a.example"}, link("https://ok.example"),
                          {"label": "‮evil", "url": "https://b.example"},
                          {"label": "L", "url": "https://c.example", "extra": {"x": [1]}}],
                   steps=[{"text": "do it", "link": {"label": ["x"], "url": "https://a.example"}}],
                   source={"host": "devbox", "agent": "claude", "extra": {"deep": [1, 2]}})
        bad = {
            "source not text": rec(source={"host": 5}),
            "source too long": rec(source={"project": "p" * 101}),
            "title too long": rec(title="t" * 101),
            "title control": rec(title="a‮b"),
            "body too long": rec(body="b" * 2001),
            "key not a key": rec(key="work:x y"),
            "step text too long": rec(steps=[{"text": "s" * 201}]),
            "too many steps": rec(steps=[{"text": "s"}] * 11),
            "id too long": rec(id="I" * 201),
            "updated_by too long": rec(updated_by="h" * 201),
            "origin_hub too long": rec(origin_hub="h" * 201),
            "token_id too long": rec(token_id="t" * 201),
            "superseded_by control": rec(superseded_by="a\x00b"),
        }
        st, body = request("POST", self.hub.url + "/v1/replicate", "test-peer-secret-0123456789",
                           {"from_hub": "hub-z", "items": [kept] + list(bad.values())})
        self.assertEqual(st, 200, body)
        skipped = {s["id"] for s in body["skipped"]}
        for name, r in bad.items():
            with self.subTest(name):
                self.assertIn(r["id"][:100], skipped)
                self.assertIsNone(self.hub.store.get_item(r["id"]))
        got = self.hub.store.get_item(kept["id"])
        self.assertEqual(json.loads(got["links"]), [link("https://ok.example"), link("https://c.example")])
        self.assertEqual(json.loads(got["steps"]), [{"text": "do it"}])
        self.assertEqual(json.loads(got["source"]), {"host": "devbox", "agent": "claude"})
        st, listing = request("GET", self.hub.url + "/v1/items", self.reader)
        self.assertEqual(st, 200)
        for item in listing["items"]:
            for lk in item["links"]:
                self.assertIsInstance(lk["label"], str)
            for v in item["source"].values():
                self.assertIsInstance(v, str)

    def test_access_log_never_shows_invite_codes(self):
        st, inv = request("POST", self.hub.url + "/v1/invites", OWNER, {"name": "srv"})
        self.assertEqual(st, 201)
        code = inv["code"]
        self.hub.cfg["quiet"] = False
        buf = io.StringIO()
        old, sys.stderr = sys.stderr, buf
        try:
            for path in ("/join/" + code, "/join/" + code + "/install.sh", "/join/nyi_wrong-guess"):
                with OPENER.open(self.hub.url + path, timeout=5) as resp:
                    resp.read()
            self.raw(("GARBAGE %s\x1b[31m HTTP/9\r\n\r\n" % code).encode())
        except Exception:
            pass
        finally:
            sys.stderr = old
            self.hub.cfg["quiet"] = True
        log = buf.getvalue()
        self.assertIn("/join/<code>", log)
        self.assertNotIn(code, log)
        self.assertNotIn(code[4:], log)
        self.assertNotIn("\x1b", log)

    def test_redact_log(self):
        line = 'GET /join/nyi_abc-DEF_123/install.sh HTTP/1.1" 200 - \x1b]0;pwned\x07 ny_' + "a" * 43
        out = hubmod.redact_log(line)
        self.assertNotIn("nyi_abc", out)
        self.assertNotIn("a" * 43, out)
        self.assertNotIn("\x1b", out)
        self.assertNotIn("\x07", out)
        self.assertIn("\\x1b", out)

    def test_install_script_substitutes_in_one_pass(self):
        inv = {"name": "__NY_MAC_URL__", "role": "sender", "uses": 1, "used": {}}
        out = hubmod.install_script(self.hub, inv, "nyi_code")
        self.assertIn("INVITE_NAME='__NY_MAC_URL__'\n", out)
        self.assertIn("CODE='nyi_code'\n", out)
        inv["name"] = "it's $(x)"
        out = hubmod.install_script(self.hub, inv, "nyi_code")
        self.assertIn("INVITE_NAME='it'\"'\"'s $(x)'\n", out)

    def test_bind_refusal(self):
        for bind in ("0.0.0.0", "::", "[::]", "", "*", "127.0.0.1,0.0.0.0"):
            with self.subTest(bind):
                with self.assertRaises(SystemExit):
                    hubmod.check_bind({"bind": bind, "hub_id": "h"})

    def test_bind_refusal_other_spellings(self):
        # Other spellings of the any-address that the OS binds as 0.0.0.0 or :: (scan 2026-10-08).
        for bind in ("0", "0.0", "000.0.0.0", "0x0", "::0", "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0",
                     "[::0]", "127.0.0.1,0"):
            with self.subTest(bind):
                with self.assertRaises(SystemExit):
                    hubmod.check_bind({"bind": bind, "hub_id": "h"})
        for bind in ("127.0.0.1", "::1", "100.64.1.2", "devbox", "hub-a.example.ts.net"):
            with self.subTest(bind):
                hubmod.check_bind({"bind": bind, "hub_id": "h"})
        hubmod.check_bind({"bind": "0", "hub_id": "h", "allow_any_interface": True})


class ConnectionLimit(HubTestCase):
    """Scan 2026-10-08: every connection got a thread and a file descriptor, without limit.
    Idle connections (a few hundred on macOS, whose default limit is 256 descriptors) left the
    hub unable to accept, spinning on EMFILE, until they went away."""

    def test_connections_over_the_limit_are_closed_at_once(self):
        hub = self.make_hub("hub-a", maintenance_seconds=0, max_connections=4)
        host, port = hub.server.server_address[:2]
        idle = []
        try:
            for _ in range(4):
                s = socket.create_connection((host, port), timeout=5)
                s.sendall(b"GET /v1/health HTTP/1.0\r\n")  # never finishes its request
                idle.append(s)
            time.sleep(0.3)
            extra = socket.create_connection((host, port), timeout=5)
            t0 = time.time()
            try:
                self.assertEqual(extra.recv(100), b"")  # closed, not left waiting
            except ConnectionResetError:
                pass
            finally:
                extra.close()
            self.assertLess(time.time() - t0, 3)
        finally:
            for s in idle:
                s.close()
        ok = False
        deadline = time.time() + 5
        while time.time() < deadline and not ok:
            try:
                ok = request("GET", hub.url + "/v1/health")[0] == 200
            except OSError:
                time.sleep(0.1)
        self.assertTrue(ok, "the hub answers again once the idle connections are gone")

    def test_limit_is_shared_by_every_bind(self):
        # Two binds (loopback and the tailnet IP) must not get the limit each: the descriptors
        # it protects are the process's.
        hub = self.make_hub("hub-a", bind="127.0.0.1,127.0.0.2", maintenance_seconds=0,
                            max_connections=4, request_read_seconds=30)
        port = hub.port
        idle = []
        try:
            for host in ("127.0.0.1", "127.0.0.1", "127.0.0.2", "127.0.0.2"):
                s = socket.create_connection((host, port), timeout=5)
                s.sendall(b"GET /v1/health HTTP/1.0\r\n")
                idle.append(s)
            time.sleep(0.3)
            for host in ("127.0.0.1", "127.0.0.2"):
                extra = socket.create_connection((host, port), timeout=5)
                try:
                    self.assertEqual(extra.recv(100), b"")
                except ConnectionResetError:
                    pass
                finally:
                    extra.close()
        finally:
            for s in idle:
                s.close()

    def test_clients_that_stop_reading_give_way_when_the_hub_is_full(self):
        # A finished request whose client never reads the answer (a /dl file, unauthenticated)
        # blocked in the hub's write and kept its slot for the whole socket timeout.
        install = os.path.join(self.tmp, "install")
        os.makedirs(os.path.join(install, "cli"))
        with open(os.path.join(install, "cli", "needs-you"), "wb") as fh:
            fh.write(b"#" * (32 << 20))  # far more than the socket buffers hold
        hub = self.make_hub("hub-a", maintenance_seconds=0, max_connections=4, request_read_seconds=0.5,
                            install_dir=install)
        host, port = hub.server.server_address[:2]
        stuck = []
        try:
            for _ in range(4):
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                s.settimeout(5)
                s.connect((host, port))
                s.sendall(b"GET /dl/needs-you HTTP/1.0\r\n\r\n")
                stuck.append(s)
            time.sleep(1.0)
            self.assertEqual(request("GET", hub.url + "/v1/health")[0], 200)
        finally:
            for s in stuck:
                s.close()

    def test_slow_requests_give_way_when_the_hub_is_full(self):
        # Connections that hold a slot without finishing their request (sending a byte now and
        # then, inside the socket timeout) are closed once they are older than
        # request_read_seconds and another client needs the slot.
        hub = self.make_hub("hub-a", maintenance_seconds=0, max_connections=4, request_read_seconds=0.5)
        host, port = hub.server.server_address[:2]
        idle = []
        try:
            for _ in range(4):
                s = socket.create_connection((host, port), timeout=5)
                s.sendall(b"GET /v1/health HTTP/1.0\r\n")
                idle.append(s)
            time.sleep(1.0)
            self.assertEqual(request("GET", hub.url + "/v1/health")[0], 200)
        finally:
            for s in idle:
                s.close()

    def test_default_limit_leaves_descriptors_for_the_hub(self):
        limit = hubmod.connection_limit({})
        self.assertGreaterEqual(limit, 8)
        try:
            import resource
            soft = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except (ImportError, OSError, ValueError):
            return
        if soft != resource.RLIM_INFINITY:
            self.assertLess(limit, soft)


class PeerRedirects(HubTestCase):
    """Scan 2026-10-08: the peer worker's opener followed redirects, and urllib copies the
    Authorization header to the new location, any origin: a peer URL answering 3xx handed
    the peer secret to whatever the Location named."""

    def test_peer_secret_never_follows_a_redirect(self):
        import http.server
        import threading
        seen = []

        class Catch(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
            do_POST = do_GET

            def log_message(self, *a):
                pass

        catcher = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Catch)
        target = "http://127.0.0.1:%d" % catcher.server_address[1]

        class Redirect(Catch):
            def do_GET(self):
                self.send_response(307)
                self.send_header("Location", target + self.path)
                self.end_headers()
            do_POST = do_GET

        redirector = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
        for srv in (catcher, redirector):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.server_close)
            self.addCleanup(srv.shutdown)
        hub = self.make_hub("hub-a", maintenance_seconds=0, start=False)
        hub.set_peers(["http://127.0.0.1:%d" % redirector.server_address[1]])
        hub.start()
        sender, _ = hub.store.add_token("s", "sender")
        request("POST", hub.url + "/v1/items", sender, OK)  # something to push
        time.sleep(2.0)
        self.assertEqual(seen, [])


class DatabaseFileModes(HubTestCase):
    def test_db_wal_and_shm_are_private(self):
        # Items and token hashes: the -wal and -shm files hold the same data as the database,
        # and used to be created with the umask's 0644 before the database was chmod 0600.
        old = os.umask(0o022)
        try:
            hub = self.make_hub("hub-a")
            sender, _ = self.tokens(hub)
            self.assertEqual(request("POST", hub.url + "/v1/items", sender, {"key": "k", "title": "t"})[0], 201)
            path = hub.store.path
            for p in (path, path + "-wal", path + "-shm"):
                if os.path.exists(p):
                    self.assertEqual(oct(os.stat(p).st_mode & 0o777), "0o600", p)
            self.assertTrue(os.path.exists(path + "-wal"))
        finally:
            os.umask(old)


class CliOutput(unittest.TestCase):
    def test_clean_neutralises_terminal_escapes(self):
        cli = load_cli()
        self.assertEqual(cli.clean("ok"), "ok")
        self.assertEqual(cli.clean("a\x1b[2Jb"), "a\\x1b[2Jb")
        self.assertEqual(cli.clean("x\x9by"), "x\\x9by")
        self.assertEqual(cli.clean("x\u202ey"), "x\\u202ey")
        self.assertEqual(cli.clean("caf\u00e9 \u0645"), "caf\u00e9 \u0645")
        self.assertEqual(cli.clean(None), "None")


class InstallerEnvFile(test_install.InstallScript):
    """A hub answer with shell syntax must never reach the sourceable env file."""

    def test_shell_syntax_in_hub_urls_is_refused(self):
        marker = os.path.join(self.tmp, "pwned")
        self.hub.hub_urls = lambda local_first=False: ["http://h:1/$(touch %s)" % marker]
        inv = self.invite(role="sender")
        r = self.install(inv, "--yes", "--no-schedule")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("don't belong", r.stderr)
        env_file = os.path.join(self.home, ".config", "needs-you", "env")
        self.assertFalse(os.path.exists(env_file))
        self.assertFalse(os.path.exists(marker))

    def test_shell_syntax_in_hub_flag_is_refused(self):
        inv = self.invite(role="sender")
        r = self.install(inv, "--yes", "--no-schedule", "--hub", "'http://h:1/`id`'")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("--hub", r.stderr)


# Reuse InstallScript's fixtures without running its tests a second time.
for _name in dir(test_install.InstallScript):
    if _name.startswith("test_"):
        setattr(InstallerEnvFile, _name, None)


class ClaudeInstallerFiles(unittest.TestCase):
    """Scan 2026-10-08: install-hooks.sh (Claude Code) and the files it writes."""

    def setUp(self):
        import shutil
        import tempfile
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="ny-sec-claude-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        self.script = os.path.join(os.path.dirname(CLI), "..", "integrations", "claude-code", "install-hooks.sh")

    def run_install(self, *flags):
        import subprocess
        return subprocess.run(["bash", self.script] + list(flags), env=self.env, capture_output=True,
                              text=True, timeout=60, cwd=self.tmp)

    def test_backup_is_private_and_never_written_through_a_planted_name(self):
        # The backup took the umask's mode (a settings.json holding an API key in "env" became
        # world-readable) and followed a symlink a repo could ship under the predictable name;
        # so did the hook's .tmp copy.
        proj = os.path.join(self.tmp, "proj")
        claude = os.path.join(proj, ".claude")
        os.makedirs(os.path.join(claude, "hooks"))
        settings = os.path.join(claude, "settings.json")
        with open(settings, "w") as fh:
            json.dump({"env": {"ANTHROPIC_API_KEY": "sk-secret"}}, fh)
        os.chmod(settings, 0o600)
        victim = os.path.join(self.tmp, "victim")
        with open(victim, "w") as fh:
            fh.write("untouched\n")
        now = time.time()
        for i in range(-2, 30):
            stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now + i))
            os.symlink(victim, settings + ".bak-" + stamp)
        os.symlink(victim, os.path.join(claude, "hooks", "needs-you-hook.sh.tmp"))
        old = os.umask(0o022)
        try:
            r = self.run_install("--project", proj)
        finally:
            os.umask(old)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(victim) as fh:
            self.assertEqual(fh.read(), "untouched\n")
        backups = [n for n in os.listdir(claude) if n.startswith("settings.json.bak-")
                   and not os.path.islink(os.path.join(claude, n))]
        self.assertEqual(len(backups), 1, os.listdir(claude))
        self.assertEqual(os.stat(os.path.join(claude, backups[0])).st_mode & 0o777, 0o600)
        with open(os.path.join(claude, backups[0])) as fh:
            self.assertIn("sk-secret", fh.read())

    def test_settings_path_with_shell_syntax_is_refused(self):
        # --settings FILE: its directory went into the hook command line inside double quotes,
        # so a `$(...)` in a directory name ran on every hook event.
        for name in ("x$(touch PWNED)", "a`id`b", 'q"q', "b\\s"):
            with self.subTest(name):
                d = os.path.join(self.tmp, name)
                os.makedirs(d, exist_ok=True)
                r = self.run_install("--settings", os.path.join(d, "settings.json"))
                self.assertNotEqual(r.returncode, 0)
                self.assertFalse(os.path.exists(os.path.join(d, "settings.json")))
        ok = os.path.join(self.tmp, "with space")
        os.makedirs(ok)
        r = self.run_install("--settings", os.path.join(ok, "settings.json"))
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
