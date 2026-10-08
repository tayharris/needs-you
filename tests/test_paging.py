"""GET /v1/items paging always makes progress: the `next` cursor, and `since` for older clients.

Many writes can land in one millisecond (a replicated batch, a frozen test clock), and many
items can expire in one poll window. Neither may make a poller get the same page forever."""
from __future__ import annotations

import urllib.parse

from support import FakeClock, HubTestCase, request


class PagingCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()
        self.hub = self.make_hub("hub-a", clock=self.clock)
        self.sender, self.reader = self.tokens(self.hub)

    def post(self, body):
        s, out = request("POST", self.hub.url + "/v1/items", self.sender, body)
        self.assertIn(s, (200, 201), out)
        return out

    def list(self, **q):
        return request("GET", self.hub.url + "/v1/items?" + urllib.parse.urlencode(q), self.reader)

    def drain(self, limit, max_pages=30, **first):
        """Page like a client until `more` is false. Returns (ids in order, page sizes, last body)."""
        seen, sizes = [], []
        q = dict(first)
        for _ in range(max_pages):
            s, body = self.list(limit=str(limit), **q)
            self.assertEqual(s, 200, body)
            sizes.append(len(body["items"]))
            seen += [i["id"] for i in body["items"] if i["id"] not in seen]
            if not body["more"]:
                return seen, sizes, body
            q = self.next_query(body, q)
        self.fail("paging did not finish in %d pages (sizes %s)" % (max_pages, sizes))

    def next_query(self, body, q):
        return {"since": body["server_time"]}


class LegacySince(PagingCase):
    """Older clients send only `since=<server_time>`."""

    def test_many_writes_in_one_millisecond(self):
        _, body = self.list()
        cursor = body["server_time"]
        self.clock.advance(1)
        made = [self.post({"key": "p%d" % i, "title": "t"})["id"] for i in range(7)]  # frozen clock
        self.clock.advance(1)
        seen, _sizes, _ = self.drain(3, since=cursor)
        self.assertEqual(sorted(seen), sorted(made))

    def test_many_expiries_in_one_window(self):
        made = [self.post({"key": "e%d" % i, "title": "t", "kind": "info"})["id"] for i in range(7)]
        self.clock.advance(1)
        _, body = self.list(since="1970-01-01T00:00:00Z")
        cursor = body["server_time"]
        self.clock.advance(25 * 3600)
        seen, _sizes, body = self.drain(3, since=cursor)
        self.assertEqual(sorted(seen), sorted(made))
        statuses = self.list(since=cursor)[1]["items"]
        self.assertTrue(all(i["status"] == "resolved" for i in statuses))


class NextCursor(PagingCase):
    """Newer clients send back `next` as `cursor` (and `since` too, for older hubs)."""

    def next_query(self, body, q):
        self.assertIsInstance(body.get("next"), str)
        return {"cursor": body["next"], "since": body["server_time"]}

    def first_cursor(self):
        _, body = self.list()
        self.assertIsInstance(body.get("next"), str)
        return {"cursor": body["next"], "since": body["server_time"]}

    def test_many_writes_in_one_millisecond_pages_within_limit(self):
        q = self.first_cursor()
        made = [self.post({"key": "p%d" % i, "title": "t"})["id"] for i in range(7)]
        seen, sizes, _ = self.drain(3, **q)
        self.assertEqual(seen, made)  # in write order, each once
        self.assertTrue(all(n <= 3 for n in sizes), sizes)

    def test_many_expiries_page_within_limit(self):
        made = [self.post({"key": "e%d" % i, "title": "t", "kind": "info"})["id"] for i in range(7)]
        self.clock.advance(1)
        _, _, body = self.drain(500, **self.first_cursor())
        q = self.next_query(body, {})
        self.clock.advance(25 * 3600)
        seen, sizes, body = self.drain(3, **q)
        self.assertEqual(sorted(seen), sorted(made))
        self.assertTrue(all(n <= 3 for n in sizes), sizes)
        # and they are not delivered again
        self.clock.advance(1)
        self.assertEqual(self.list(**self.next_query(body, {}))[1]["items"], [])

    def test_mixed_changes_and_expiries(self):
        expiring = [self.post({"key": "e%d" % i, "title": "t", "kind": "done"})["id"] for i in range(4)]
        self.clock.advance(1)
        q = self.first_cursor()
        self.clock.advance(25 * 3600)
        fresh = [self.post({"key": "n%d" % i, "title": "t"})["id"] for i in range(4)]
        seen, sizes, _ = self.drain(3, **q)
        self.assertEqual(sorted(seen), sorted(expiring + fresh))
        self.assertTrue(all(n <= 3 for n in sizes), sizes)

    def test_closes_are_delivered(self):
        a = self.post({"key": "a", "title": "t"})
        q = self.first_cursor()
        request("POST", self.hub.url + "/v1/items/resolve", self.sender, {"key": "a"})
        _, body = self.list(**q)
        self.assertEqual([(i["id"], i["status"]) for i in body["items"]], [(a["id"], "resolved")])
        _, body = self.list(**self.next_query(body, q))
        self.assertEqual(body["items"], [])

    def test_cursor_is_stable_when_nothing_changes(self):
        q = self.first_cursor()
        for _ in range(3):
            self.clock.advance(1)
            _, body = self.list(**q)
            self.assertEqual(body["items"], [])
            self.assertFalse(body["more"])
            q = self.next_query(body, q)

    def test_cursor_from_another_database_falls_back_to_since(self):
        q = self.first_cursor()
        a = self.post({"key": "a", "title": "t"})
        other = q["cursor"].split(".", 1)
        stale = "01AAAAAAAAAAAAAAAAAAAAAAAA." + other[1]
        s, body = self.list(cursor=stale, since=q["since"])
        self.assertEqual(s, 200)
        self.assertEqual([i["id"] for i in body["items"]], [a["id"]])
        self.assertIsInstance(body["next"], str)
        # without a since to fall back on, a stale or malformed cursor is a 400 naming it
        for bad in (stale, "garbage", "x.1.2", q["cursor"] + ".extra.bits"):
            with self.subTest(bad):
                s, body = self.list(cursor=bad)
                self.assertEqual(s, 400)
                self.assertEqual(body.get("field"), "cursor")

    def test_truncated_full_poll_continues_by_next(self):
        """A full poll cut short by `limit` (`more`): its `next` delivers the rest, then the
        changes after it, as the polling loop says."""
        made = [self.post({"key": "s%d" % i, "title": "t"})["id"] for i in range(7)]
        resolved = self.post({"key": "gone", "title": "t"})["id"]
        request("POST", self.hub.url + "/v1/items/resolve", self.sender, {"key": "gone"})
        s, body = self.list(limit="3")
        self.assertEqual(s, 200, body)
        self.assertTrue(body["more"])
        self.assertEqual(len(body["items"]), 3)
        self.assertTrue(all(i["status"] == "open" for i in body["items"]))
        first = [i["id"] for i in body["items"]]
        # an item changed and one posted while the client pages are delivered too
        request("POST", self.hub.url + "/v1/items/resolve", self.sender, {"key": "s0"})
        late = self.post({"key": "late", "title": "t"})["id"]
        rest, sizes, last = self.drain(3, cursor=body["next"])
        self.assertTrue(all(n <= 3 for n in sizes), sizes)
        self.assertIsInstance(last.get("next"), str)
        got = set(first) | set(rest)
        self.assertTrue(set(made) | {late} <= got, (made, got))
        self.assertNotIn(resolved, first)
        # the close of an item from the first page comes with the rest
        _, again = self.list(cursor=body["next"], limit="100")
        self.assertIn((made[0], "resolved"), [(i["id"], i["status"]) for i in again["items"]])

    def test_status_is_ignored_with_a_cursor(self):
        q = self.first_cursor()
        a = self.post({"key": "a", "title": "t"})
        request("POST", self.hub.url + "/v1/items/resolve", self.sender, {"key": "a"})
        _, body = self.list(status="open", **q)
        self.assertEqual([(i["id"], i["status"]) for i in body["items"]], [(a["id"], "resolved")])


class TruncatedFullListing(PagingCase):
    """A full listing cut short by `limit` (`more: true`) continues where it stopped: polling
    on with its `next` (and `since`, as clients send both) brings the items it left out, with
    closed items mixed in."""

    def setUp(self):
        super().setUp()
        self.ids = []
        for n in range(5):
            self.ids.append(self.post({"key": "k%d" % n, "title": "t"})["id"])
            if n % 2:
                self.clock.advance(0.002)
        request("POST", self.hub.url + "/v1/items/resolve", self.sender, {"key": "k1"})

    def check(self, next_query):
        s, body = self.list(status="open", limit="2")
        self.assertEqual(s, 200, body)
        self.assertTrue(body["more"])
        open_ids = {i for n, i in enumerate(self.ids) if n != 1}
        seen = {i["id"] for i in body["items"]}
        q = next_query(body)
        for _ in range(10):
            s, body = self.list(limit="2", **q)
            self.assertEqual(s, 200, body)
            seen |= {i["id"] for i in body["items"] if i["status"] == "open"}
            if not body["more"]:
                break
            q = next_query(body)
        self.assertEqual(seen, open_ids)

    def test_with_next(self):
        self.check(lambda b: {"cursor": b["next"], "since": b["server_time"]})
