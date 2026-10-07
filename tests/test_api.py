from __future__ import annotations

import http.client
import json
import socket
import threading
import urllib.parse

from support import PEER_SECRET, FakeClock, HubTestCase, hubmod, request


class ApiTestCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()
        self.hub = self.make_hub("hub-a", clock=self.clock)
        self.sender, self.reader = self.tokens(self.hub)
        self.base = self.hub.url

    def post(self, body, token=None):
        return request("POST", self.base + "/v1/items", token or self.sender, body)

    def resolve(self, body, token=None):
        return request("POST", self.base + "/v1/items/resolve", token or self.sender, body)

    def patch(self, item_id, body, token=None):
        return request("PATCH", self.base + "/v1/items/" + item_id, token or self.reader, body)

    def list(self, **q):
        qs = urllib.parse.urlencode(q)
        return request("GET", self.base + "/v1/items" + ("?" + qs if qs else ""), self.reader)


class Health(ApiTestCase):
    def test_unauthenticated(self):
        status, body = request("GET", self.base + "/v1/health")
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        self.assertEqual(body["hub_id"], "hub-a")
        self.assertNotIn("token", body)

    def test_with_token(self):
        status, body = request("GET", self.base + "/v1/health", self.sender)
        self.assertEqual(status, 200)
        self.assertEqual(body["token"]["role"], "sender")

    def test_bad_token_is_not_an_error(self):
        status, body = request("GET", self.base + "/v1/health", "nope")
        self.assertEqual(status, 200)
        self.assertIsNone(body["token"])
        self.assertIn("token_error", body)


class Roles(ApiTestCase):
    def test_matrix(self):
        status, item = self.post({"key": "k", "title": "t"})
        self.assertEqual(status, 201)
        iid = item["id"]
        cases = [
            ("POST", "/v1/items", self.reader, {"key": "k2", "title": "t"}, 403),
            ("POST", "/v1/items", None, {"key": "k2", "title": "t"}, 401),
            ("POST", "/v1/items", "garbage", {"key": "k2", "title": "t"}, 401),
            ("POST", "/v1/items/resolve", self.reader, {"key": "k"}, 403),
            ("GET", "/v1/items", self.sender, None, 403),
            ("GET", "/v1/items", None, None, 401),
            ("PATCH", "/v1/items/" + iid, self.sender, {"seen_at": None}, 403),
            ("GET", "/v1/items", self.reader, None, 200),
            ("GET", "/v1/items/" + iid, self.reader, None, 200),
            ("GET", "/v1/nope", self.reader, None, 404),
            ("POST", "/v1/replicate", self.sender, {"items": []}, 401),
        ]
        for method, path, tok, body, want in cases:
            with self.subTest("%s %s" % (method, path)):
                status, _ = request(method, self.base + path, tok, body)
                self.assertEqual(status, want)

    def test_revoked_token_rejected(self):
        self.hub.store.revoke_token(self.hub.store.list_tokens()[0]["name"])
        status, _ = self.post({"key": "k", "title": "t"})
        self.assertEqual(status, 401)


class Upsert(ApiTestCase):
    def test_create_then_dedupe(self):
        s1, a = self.post({"key": "work:ACME-1:x", "title": "Decide", "body": "b",
                           "links": [{"label": "Jira", "url": "https://j/ACME-1"}],
                           "source": {"agent": "orca:redo"}})
        self.assertEqual(s1, 201)
        self.assertTrue(a["created"])
        self.assertTrue(a["changed"])
        self.assertEqual(a["status"], "open")
        self.assertEqual(a["created_at"], a["updated_at"])
        self.assertEqual(a["content_updated_at"], a["updated_at"])
        self.assertIsNone(a["expires_at"])

        # the same content an hour later: same id, updated_at moves, content_updated_at doesn't
        self.clock.advance(3600)
        s2, b = self.post({"key": "work:ACME-1:x", "title": "Decide", "body": "b"})
        self.assertEqual(s2, 200)
        self.assertEqual(b["id"], a["id"])
        self.assertFalse(b["created"])
        self.assertFalse(b["changed"])
        self.assertGreater(b["updated_at"], a["updated_at"])
        self.assertEqual(b["content_updated_at"], a["content_updated_at"])

        # a change to title, body or priority re-animates
        for field, value in (("title", "Decide now"), ("body", "b2"), ("priority", "urgent")):
            with self.subTest(field):
                self.clock.advance(60)
                prev = self.list()[1]["items"][0]
                payload = {"key": "work:ACME-1:x", "title": prev["title"], "body": prev["body"],
                           "priority": prev["priority"]}
                payload[field] = value  # change exactly one visible field
                _, c = self.post(payload)
                self.assertEqual(c["id"], a["id"])
                self.assertTrue(c["changed"], field)
                self.assertEqual(c["content_updated_at"], c["updated_at"])

        # links/source changes alone don't count as a visible change
        self.clock.advance(60)
        cur = self.list()[1]["items"][0]
        _, d = self.post({"key": "work:ACME-1:x", "title": cur["title"], "body": cur["body"],
                          "priority": cur["priority"], "links": [{"label": "PR", "url": "https://pr"}]})
        self.assertFalse(d["changed"])
        self.assertEqual(d["links"], [{"label": "PR", "url": "https://pr"}])
        self.assertEqual(len(self.list()[1]["items"]), 1)

    def test_steps(self):
        steps = [{"text": "Approve **prod** deploy", "link": {"label": "Approve", "url": "https://ci/run/9"},
                  "owner": "ignored"},
                 {"text": "Post in #releases", "done": True}]
        s1, a = self.post({"key": "steps", "title": "Ship it", "steps": steps, "future": {"x": 1}})
        self.assertEqual(s1, 201)
        want = [{"text": "Approve **prod** deploy", "done": False,
                 "link": {"label": "Approve", "url": "https://ci/run/9"}},
                {"text": "Post in #releases", "done": True}]
        self.assertEqual(a["steps"], want)
        _, got = request("GET", self.base + "/v1/items/" + a["id"], self.reader)
        self.assertEqual(got["steps"], want)
        # the same steps again: not a visible change
        self.clock.advance(60)
        _, b = self.post({"key": "steps", "title": "Ship it", "steps": steps})
        self.assertFalse(b["changed"])
        # a changed step (here: one more done) is content: it re-animates
        self.clock.advance(60)
        steps[0]["done"] = True
        _, c = self.post({"key": "steps", "title": "Ship it", "steps": steps})
        self.assertTrue(c["changed"])
        self.assertEqual(c["content_updated_at"], c["updated_at"])
        # a re-post is the full view: no steps clears them (and is a change)
        self.clock.advance(60)
        _, d = self.post({"key": "steps", "title": "Ship it"})
        self.assertEqual(d["steps"], [])
        self.assertTrue(d["changed"])
        # items without steps carry an empty list
        _, e = self.post({"key": "plain", "title": "t"})
        self.assertEqual(e["steps"], [])

    def test_updated_at_strictly_increases_even_with_a_frozen_clock(self):
        _, a = self.post({"key": "k", "title": "t"})
        _, b = self.post({"key": "k", "title": "t"})
        _, c = self.post({"key": "k", "title": "t"})
        self.assertLess(a["updated_at"], b["updated_at"])
        self.assertLess(b["updated_at"], c["updated_at"])

    def test_no_key_creates_each_time(self):
        _, a = self.post({"title": "t"})
        _, b = self.post({"title": "t"})
        self.assertNotEqual(a["id"], b["id"])
        self.assertEqual(a["key"], a["id"])

    def test_reopen_after_resolve_gets_new_id(self):
        _, a = self.post({"key": "k", "title": "t"})
        self.resolve({"key": "k"})
        s, b = self.post({"key": "k", "title": "t"})
        self.assertEqual(s, 201)
        self.assertNotEqual(a["id"], b["id"])

    def test_validation_errors_are_400_and_name_the_field(self):
        cases = [
            ({"key": "k", "title": "t", "links": [{"label": "x", "url": "http://x"}]}, "links[0].url"),
            ({"key": "k"}, "title"),
            ({"key": "has space", "title": "t"}, "key"),
            ({"key": "k", "title": "t", "priority": "high"}, "priority"),
            ({"key": "k", "title": "t", "source": {"agent": "a" * 101}}, "source.agent"),
            ({"key": "k", "title": "t", "steps": [{"text": "a"}, {"text": "b", "link": {
                "label": "x", "url": "file:///etc/passwd"}}]}, "steps[1].link.url"),
            ({"key": "k", "title": "t", "steps": [{"text": "x" * 201}]}, "steps[0].text"),
            ({"key": "k", "title": "t", "steps": [{"text": "s"}] * 11}, "steps"),
        ]
        for body, field in cases:
            with self.subTest(field):
                status, resp = self.post(body)
                self.assertEqual(status, 400)
                self.assertEqual(resp["error"], "invalid")
                self.assertEqual(resp["field"], field)

    def test_bad_json_and_oversize(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.hub.port, timeout=5)
        conn.request("POST", "/v1/items", body=b"{nope", headers={
            "Authorization": "Bearer " + self.sender, "Content-Type": "application/json"})
        self.assertEqual(conn.getresponse().status, 400)
        conn.close()
        status, _ = self.post({"key": "k", "title": "t", "body": "x" * (70 * 1024)})
        self.assertEqual(status, 413)


class Resolve(ApiTestCase):
    def test_by_key_and_id(self):
        _, a = self.post({"key": "a", "title": "t"})
        _, b = self.post({"key": "b", "title": "t"})
        s, r = self.resolve({"key": "a"})
        self.assertEqual(s, 200)
        self.assertEqual(r["resolved"], 1)
        self.assertEqual([i["id"] for i in r["items"]], [a["id"]])
        self.assertEqual(r["items"][0]["status"], "resolved")
        s, r = self.resolve({"id": b["id"]})
        self.assertEqual(s, 200)
        self.assertEqual(r["items"][0]["status"], "resolved")
        self.assertEqual(self.list()[1]["items"], [])

    def test_idempotent(self):
        _, a = self.post({"key": "a", "title": "t"})
        self.resolve({"id": a["id"]})
        cases = [{"key": "a"}, {"id": a["id"]}, {"key": "never-existed"}, {"id": "nope"}]
        for body in cases:
            with self.subTest(body):
                s, r = self.resolve(body)
                self.assertEqual(s, 200)
                self.assertEqual(r, {"resolved": 0, "items": []})

    def test_errors(self):
        for body in ({}, {"key": "a", "id": "b"}, {"key": 5}):
            with self.subTest(body):
                self.assertEqual(self.resolve(body)[0], 400)


class Patch(ApiTestCase):
    def test_seen_and_dismiss(self):
        _, a = self.post({"key": "a", "title": "t"})
        self.clock.advance(5)
        s, p = self.patch(a["id"], {"seen_at": "2026-10-06T17:00:00.000Z"})
        self.assertEqual(s, 200)
        self.assertEqual(p["seen_at"], "2026-10-06T17:00:00.000Z")
        self.assertGreater(p["updated_at"], a["updated_at"])
        self.assertEqual(p["content_updated_at"], a["content_updated_at"])  # no re-animation
        s, p = self.patch(a["id"], {"status": "dismissed"})
        self.assertEqual(p["status"], "dismissed")
        s, p = self.patch(a["id"], {"seen_at": None})
        self.assertIsNone(p["seen_at"])

    def test_errors(self):
        _, a = self.post({"key": "a", "title": "t"})
        cases = [(a["id"], {"status": "open"}, 400), (a["id"], {"status": "bogus"}, 400),
                 (a["id"], {}, 400), (a["id"], {"seen_at": "later"}, 400),
                 ("nope", {"status": "resolved"}, 404)]
        for iid, body, want in cases:
            with self.subTest(body):
                self.assertEqual(self.patch(iid, body)[0], want)


class ListAndSince(ApiTestCase):
    def ids(self, body):
        return [i["id"] for i in body["items"]]

    def test_full_open_set_without_since(self):
        _, a = self.post({"key": "a", "title": "t"})
        _, b = self.post({"key": "b", "title": "t"})
        self.resolve({"key": "b"})
        s, body = self.list(status="open")
        self.assertEqual(s, 200)
        self.assertEqual(self.ids(body), [a["id"]])
        self.assertEqual(self.ids(self.list()[1]), [a["id"]])  # status defaults to open
        self.assertEqual(self.ids(self.list(status="resolved")[1]), [b["id"]])
        self.assertEqual(sorted(self.ids(self.list(status="all")[1])), sorted([a["id"], b["id"]]))
        self.assertEqual(body["hub_id"], "hub-a")
        self.assertFalse(body["more"])

    def test_polling_loop_with_server_time(self):
        """The Mac's loop: full poll, then since=<previous server_time>."""
        _, a = self.post({"key": "a", "title": "t"})
        self.clock.advance(0.01)
        _, body = self.list(status="open")
        self.assertEqual(self.ids(body), [a["id"]])
        cursor = body["server_time"]
        self.assertRegex(cursor, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")

        # nothing new: empty
        self.clock.advance(1)
        _, body = self.list(status="open", since=cursor)
        self.assertEqual(body["items"], [])
        cursor = body["server_time"]

        # a write in the same millisecond as the poll is still picked up next time
        _, b = self.post({"key": "b", "title": "same ms"})
        _, body = self.list(status="open", since=cursor)
        self.assertEqual(self.ids(body), [b["id"]])
        cursor = body["server_time"]

        # closes are delivered too, in any status, even though status=open was asked for
        self.clock.advance(1)
        self.resolve({"key": "a"})
        self.patch(b["id"], {"status": "dismissed"})
        _, body = self.list(status="open", since=cursor)
        self.assertEqual({i["id"]: i["status"] for i in body["items"]},
                         {a["id"]: "resolved", b["id"]: "dismissed"})
        cursor = body["server_time"]

        # expiry is not a write, but an item whose expiry passed since the cursor is included
        # (the frozen test clock would otherwise re-deliver same-millisecond writes, which is
        # allowed: clients upsert by id)
        self.clock.advance(0.01)
        _, d = self.post({"key": "d", "title": "fyi", "kind": "done"})
        self.clock.advance(0.01)
        _, body = self.list(status="open", since=cursor)
        cursor = body["server_time"]
        self.clock.advance(24 * 3600 + 1)
        _, body = self.list(status="open", since=cursor)
        self.assertEqual([(i["id"], i["status"]) for i in body["items"]], [(d["id"], "resolved")])
        cursor = body["server_time"]
        self.clock.advance(1)
        self.assertEqual(self.list(status="open", since=cursor)[1]["items"], [])

    def test_since_is_exclusive(self):
        _, a = self.post({"key": "a", "title": "t"})
        just_before = hubmod.fmt_ts(hubmod.parse_ts(a["updated_at"]) - 1)
        self.assertEqual(self.ids(self.list(since=just_before)[1]), [a["id"]])
        self.assertEqual(self.list(since=a["updated_at"])[1]["items"], [])

    def test_since_with_offset(self):
        from datetime import datetime, timedelta, timezone
        _, a = self.post({"key": "a", "title": "t"})
        ms = hubmod.parse_ts(a["updated_at"]) - 1
        since = datetime.fromtimestamp(ms / 1000, timezone(timedelta(hours=2))).isoformat(
            timespec="milliseconds")
        self.assertIn("+02:00", since)
        self.assertEqual(self.ids(self.list(since=since)[1]), [a["id"]])

    def test_paging_with_more(self):
        _, body = self.list()
        cursor = body["server_time"]
        made = []
        for i in range(7):
            self.clock.advance(0.01)
            made.append(self.post({"key": "p%d" % i, "title": "t"})[1]["id"])
        seen = []
        for _ in range(10):
            _, body = self.list(since=cursor, limit="3")
            seen += [i for i in self.ids(body) if i not in seen]
            cursor = body["server_time"]
            if not body["more"]:
                break
        self.assertEqual(seen, made)

    def test_bad_params(self):
        for q in ({"status": "weird"}, {"since": "soon"}, {"limit": "x"}):
            with self.subTest(q):
                self.assertEqual(self.list(**q)[0], 400)


class Expiry(ApiTestCase):
    def test_done_and_info_default_24h(self):
        for kind in ("done", "info"):
            with self.subTest(kind):
                _, a = self.post({"key": "x:" + kind, "title": "t", "kind": kind})
                exp = hubmod.parse_ts(a["expires_at"]) - hubmod.parse_ts(a["created_at"])
                self.assertEqual(exp, 24 * 3600 * 1000)
        _, n = self.post({"key": "needs", "title": "t"})
        self.assertIsNone(n["expires_at"])

    def test_expired_items_leave_open_and_key_reopens(self):
        _, a = self.post({"key": "d", "title": "t", "kind": "done"})
        self.clock.advance(24 * 3600 - 1)
        self.assertEqual(len(self.list(status="open")[1]["items"]), 1)
        self.clock.advance(2)
        self.assertEqual(self.list(status="open")[1]["items"], [])
        _, body = self.list(status="resolved")
        self.assertEqual([(i["id"], i["status"]) for i in body["items"]], [(a["id"], "resolved")])
        s, b = self.post({"key": "d", "title": "t", "kind": "done"})
        self.assertEqual(s, 201)
        self.assertNotEqual(b["id"], a["id"])

    def test_repost_extends_expiry(self):
        _, a = self.post({"key": "d", "title": "t", "kind": "info"})
        self.clock.advance(3600)
        _, b = self.post({"key": "d", "title": "t", "kind": "info"})
        self.assertEqual(b["id"], a["id"])
        self.assertGreater(b["expires_at"], a["expires_at"])

    def test_explicit_expiry(self):
        when = hubmod.fmt_ts(int((self.clock() + 60) * 1000))
        _, a = self.post({"key": "n", "title": "t", "expires_at": when})
        self.assertEqual(a["expires_at"], when)


class VolumeGuard(ApiTestCase):
    def test_sixty_open_items_per_token(self):
        for i in range(60):
            s, _ = self.post({"key": "loop:%d" % i, "title": "t"})
            self.assertEqual(s, 201)
        s, body = self.post({"key": "loop:60", "title": "t"})
        self.assertEqual(s, 429)
        self.assertEqual(body["error"], "too_many_open")
        # updating an existing key is still fine
        s, _ = self.post({"key": "loop:0", "title": "t2"})
        self.assertEqual(s, 200)
        # a different token is unaffected
        other, _ = self.hub.store.add_token("other", "sender")
        s, _ = self.post({"key": "other:1", "title": "t"}, token=other)
        self.assertEqual(s, 201)
        # resolving one frees a slot
        self.resolve({"key": "loop:1"})
        s, _ = self.post({"key": "loop:60", "title": "t"})
        self.assertEqual(s, 201)
        # expired items free slots too
        self.resolve({"key": "loop:2"})
        s, _ = self.post({"key": "loop:61", "title": "t", "kind": "done"})
        self.assertEqual(s, 201)
        s, _ = self.post({"key": "loop:62", "title": "t"})
        self.assertEqual(s, 429)
        self.clock.advance(25 * 3600)
        s, _ = self.post({"key": "loop:62", "title": "t"})
        self.assertEqual(s, 201)


class Stream(ApiTestCase):
    def test_sse_delivers_new_items(self):
        sock = socket.create_connection(("127.0.0.1", self.hub.port), timeout=5)
        sock.sendall(("GET /v1/stream HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\n\r\n"
                      % self.reader).encode())
        f = sock.makefile("rb")
        self.assertIn(b"200", f.readline())
        while f.readline() not in (b"\r\n", b"\n"):
            pass
        self.assertEqual(f.readline().strip(), b": connected")
        threading.Timer(0.2, lambda: self.post({"key": "sse", "title": "live"})).start()
        data = None
        for _ in range(50):
            line = f.readline().decode().strip()
            if line.startswith("data: "):
                data = json.loads(line[6:])
                break
        sock.close()
        self.assertIsNotNone(data)
        self.assertEqual(data["title"], "live")


class BadInput(ApiTestCase):
    """Input the hub can't store is a 400 naming the problem, never a 500."""

    def test_lone_surrogates(self):
        # e.g. a title built from a file name with a byte that isn't UTF-8 (Python's
        # surrogateescape): SQLite can't encode it, and a 5xx made the CLI queue it forever.
        for body in ({"key": "k", "title": "report-\udcff.txt"}, {"key": "k", "title": "t", "body": "\ud800"},
                     {"key": "k", "title": "t", "source": {"host": "h\ud83d"}},
                     {"key": "k", "title": "t", "steps": [{"text": "a\udfff"}]}):
            s, r = self.post(body)
            self.assertEqual((s, r.get("error")), (400, "invalid"), body)
        s, r = self.resolve({"key": "k\ud800"})
        self.assertEqual(s, 400, r)
        s, r = self.post({"key": "k", "title": "emoji \U0001F600 is fine"})
        self.assertEqual(s, 201, r)
        # a replicated item with one is skipped, the rest of the batch applied
        good = dict(self.list(status="all")[1]["items"][0])
        bad = dict(good, id="01BADBADBADBADBADBADBADBAD", key="k2", title="x\ud800")
        good = dict(good, id="01GOODGOODGOODGOODGOODGOOD", key="k3")
        s, r = request("POST", self.base + "/v1/replicate", PEER_SECRET, {"from_hub": "hub-z", "items": [bad, good]})
        self.assertEqual(s, 200, r)
        self.assertEqual([x["id"] for x in r["skipped"]], [bad["id"]])
        self.assertIsNotNone(self.hub.store.get_item(good["id"]))


if __name__ == "__main__":
    import unittest
    unittest.main()
