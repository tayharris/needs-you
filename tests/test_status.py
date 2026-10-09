"""Status records (ADR 0011, docs/API.md "Status records"): usage meters apart from items."""
from __future__ import annotations

import json
import sqlite3
import urllib.error
import urllib.request

from support import OPENER, PEER_SECRET, FakeClock, HubTestCase, hubmod, request, wait_until

NOW = 1_790_000_000.0


def usage_body(pct5=51, pct7=41, expires_in=3600, now=NOW, **extra):
    body = {"type": "usage", "label": "Claude",
            "usage": {"provider": "claude", "account": "",
                      "windows": [{"name": "5h", "used_pct": pct5, "resets_at": now + 1800},
                                  {"name": "7d", "used_pct": pct7}]},
            "source": {"host": "devbox", "agent": "claude-code"},
            "expires_at": now + expires_in}
    body.update(extra)
    return body


def get_with_headers(url, token, etag=None):
    req = urllib.request.Request(url, method="GET", headers={"Authorization": "Bearer " + token})
    if etag:
        req.add_header("If-None-Match", etag)
    try:
        with OPENER.open(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}"), dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        return e.code, json.loads(raw) if raw else {}, dict(e.headers)


class Validation(HubTestCase):
    def check(self, body, field=None, code="invalid"):
        with self.assertRaises(hubmod.ApiError) as cm:
            hubmod.validate_status_input(body, int(NOW * 1000))
        self.assertEqual(cm.exception.code, code, cm.exception.message)
        if field:
            self.assertEqual(cm.exception.field, field)

    def test_a_usage_body_is_normalised(self):
        out = hubmod.validate_status_input(usage_body(pct7=41.56), int(NOW * 1000))
        self.assertEqual(out["type"], "usage")
        self.assertEqual(out["usage"]["windows"][0], {"name": "5h", "used_pct": 51,
                                                      "resets_at": int((NOW + 1800) * 1000)})
        self.assertEqual(out["usage"]["windows"][1]["used_pct"], 41.6)
        self.assertIsNone(out["state"])

    def test_a_progress_body(self):
        out = hubmod.validate_status_input({"type": "progress", "label": "nightly import", "progress": 40,
                                            "expires_at": NOW + 600}, int(NOW * 1000))
        self.assertEqual((out["state"], out["progress"], out["usage"]), ("working", 40, None))

    def test_refusals(self):
        cases = [
            ({"label": "x"}, "type"),
            (dict(usage_body(), type="card"), "type"),
            (dict(usage_body(), expires_at=None), "expires_at"),
            (dict(usage_body(), expires_at=NOW - 1), "expires_at"),
            (dict(usage_body(), expires_at=NOW + 9 * 86400), "expires_at"),
            ({"type": "progress", "label": "p", "expires_at": NOW + 7200}, "expires_at"),
            ({"type": "progress", "expires_at": NOW + 60}, "label"),
            ({"type": "progress", "label": "p", "progress": 101, "expires_at": NOW + 60}, "progress"),
            ({"type": "progress", "label": "p", "progress": True, "expires_at": NOW + 60}, "progress"),
            ({"type": "progress", "label": "p", "state": "busy", "expires_at": NOW + 60}, "state"),
            (dict(usage_body(), label="x" * 61), "label"),
            (dict(usage_body(), label="two\nlines"), "label"),
            (dict(usage_body(), label="evil‮name"), "label"),
            (dict(usage_body(), detail="a b"), "detail"),
            (dict(usage_body(), usage=None), "usage"),
            (dict(usage_body(), usage={"provider": "Claude!", "windows": [{"name": "5h", "used_pct": 1}]}),
             "usage.provider"),
            (dict(usage_body(), usage={"provider": "claude", "account": "me@example.com",
                                       "windows": [{"name": "5h", "used_pct": 1}]}), "usage.account"),
            (dict(usage_body(), usage={"provider": "claude", "account": "a b",
                                       "windows": [{"name": "5h", "used_pct": 1}]}), "usage.account"),
            (dict(usage_body(), usage={"provider": "claude", "windows": []}), "usage.windows"),
            (dict(usage_body(), usage={"provider": "claude", "windows": [{"name": "w%d" % i, "used_pct": 1}
                                                                         for i in range(5)]}), "usage.windows"),
            (dict(usage_body(), usage={"provider": "claude", "windows": [{"name": "5h", "used_pct": 1},
                                                                         {"name": "5h", "used_pct": 2}]}),
             "usage.windows"),
            (dict(usage_body(), usage={"provider": "claude", "windows": [{"name": "5h", "used_pct": 120}]}),
             "usage.windows[0].used_pct"),
            (dict(usage_body(), usage={"provider": "claude", "windows": [{"name": "5h", "used_pct": "50"}]}),
             "usage.windows[0].used_pct"),
            (dict(usage_body(), usage={"provider": "claude", "windows": [{"name": "5h", "used_pct": 5,
                                                                          "resets_at": "soon"}]}),
             "usage.windows[0].resets_at"),
        ]
        for body, field in cases:
            with self.subTest(field=field, body=body):
                self.check(body, field)

    def test_token_shaped_text_is_refused(self):
        for text in ("ny_" + "A1b2C3d4e5F6g7H8", "ghp_" + "a" * 20, "sk-" + "x" * 20,
                     "key 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                     "Zx9Qw3Er7Ty1Ui5Op2As8Df4Gh6Jk0LmNbVcXz"):
            with self.subTest(text=text):
                self.check(dict(usage_body(), label=text[:60]), "label", "secret_in_text")
        self.check(dict(usage_body(), usage={"provider": "claude", "account": "nyp_" + "x" * 20,
                                             "windows": [{"name": "5h", "used_pct": 1}]}),
                   "usage.account", "secret_in_text")

    def test_ordinary_text_is_not_a_secret(self):
        for text in ("nightly-import-of-the-acme-customer-data", "Claude (team-2)",
                     "deploy/acme/2026-10-08/build-1234567"):
            with self.subTest(text=text):
                self.assertFalse(hubmod.looks_secret(text))


class StatusApi(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock(NOW)
        self.hub = self.make_hub("hub-a", clock=self.clock)
        self.sender, self.reader = self.tokens(self.hub)
        self.base = self.hub.url

    def put(self, key, body, token=None):
        return request("PUT", self.base + "/v1/status/" + key, token or self.sender, body)

    def clear(self, key, token=None):
        return request("DELETE", self.base + "/v1/status/" + key, token or self.sender)

    def statuses(self, token=None):
        status, body = request("GET", self.base + "/v1/status", token or self.reader)
        self.assertEqual(status, 200, body)
        return body["statuses"]

    def test_put_get_and_clear(self):
        status, rec = self.put("usage:claude", usage_body())
        self.assertEqual(status, 200, rec)
        self.assertEqual(rec["key"], "usage:claude")
        self.assertTrue(rec["id"].startswith("st_"))
        self.assertEqual(rec["usage"]["windows"][0]["resets_at"], hubmod.fmt_ts(int((NOW + 1800) * 1000)))
        self.assertIsNone(rec["usage"]["windows"][1]["resets_at"])
        listed = self.statuses()
        self.assertEqual([s["id"] for s in listed], [rec["id"]])
        self.assertEqual(listed[0]["source"], {"host": "devbox", "agent": "claude-code"})
        self.assertEqual(self.clear("usage:claude"), (200, {"ok": True, "cleared": True}))
        self.assertEqual(self.statuses(), [])
        self.assertEqual(self.clear("usage:claude"), (200, {"ok": True, "cleared": False}))

    def test_statuses_are_never_items(self):
        self.put("usage:claude", usage_body())
        _, body = request("GET", self.base + "/v1/items", self.reader)
        self.assertEqual(body["items"], [])
        self.assertEqual(self.hub.store.open_count_for_token(
            self.hub.store.token_by_secret(self.sender)["id"]), 0)

    def test_roles(self):
        self.assertEqual(self.put("k", usage_body(), token=self.reader)[0], 403)
        self.assertEqual(self.clear("k", token=self.reader)[0], 403)
        self.assertEqual(request("GET", self.base + "/v1/status", self.sender)[0], 403)
        self.assertEqual(request("GET", self.base + "/v1/status")[0], 401)
        owner, _ = self.hub.store.add_token("owner-1", "owner")
        self.assertEqual(request("GET", self.base + "/v1/status", owner)[0], 200)

    def test_bad_key(self):
        self.assertEqual(self.put("a%20b", usage_body())[0], 400)

    def test_keys_are_per_token(self):
        other, _ = self.hub.store.add_token("sender-2", "sender")
        self.assertEqual(self.put("usage:claude", usage_body(pct5=10))[0], 200)
        self.assertEqual(self.put("usage:claude", usage_body(pct5=20), token=other)[0], 200)
        self.assertEqual(len(self.statuses()), 2)
        self.clear("usage:claude", token=other)
        self.assertEqual([s["usage"]["windows"][0]["used_pct"] for s in self.statuses()], [10])

    def test_one_write_per_key_every_10_seconds(self):
        self.assertEqual(self.put("usage:claude", usage_body())[0], 200)
        self.clock.advance(4)
        status, body = self.put("usage:claude", usage_body(pct5=60))
        self.assertEqual((status, body["error"]), (429, "too_fast"))
        self.assertEqual(body["retry_after"], 6)
        self.assertEqual(self.put("usage:other", usage_body())[0], 200)  # per key
        self.clock.advance(6)
        status, rec = self.put("usage:claude", usage_body(pct5=60))
        self.assertEqual(status, 200, rec)
        self.assertEqual(rec["usage"]["windows"][0]["used_pct"], 60)
        self.assertEqual(self.clear("usage:claude")[1]["cleared"], True)  # a clear is never too fast
        self.assertEqual(self.put("usage:claude", usage_body())[0], 200)  # nor a set after a clear

    def test_writes_per_token_are_rate_limited(self):
        """A set after a clear is never too fast, and every new key is a new row, so without a
        per-token limit a sender could write (and every peer store) statuses without end. Sets
        and clears have their own limit (post_rate_limit a minute), apart from posts."""
        limit = int(self.hub.cfg["post_rate_limit"])
        codes = []
        for i in range(limit + 10):
            codes.append(self.put("loop", usage_body())[0])
            codes.append(self.clear("loop")[0])
        self.assertIn(429, codes)
        self.assertLessEqual(codes.count(200), limit)
        status, body = self.put("loop-%d" % len(codes), usage_body())
        self.assertEqual((status, body["error"]), (429, "rate_limited"))
        self.assertGreaterEqual(body["retry_after"], 1)
        self.assertEqual(request("POST", self.base + "/v1/items", self.sender,
                                 {"key": "k", "title": "still posts"})[0], 201)  # items aren't held

    def test_live_status_limits(self):
        for i in range(hubmod.STATUS_MAX_PER_TOKEN):
            self.assertEqual(self.put("s%d" % i, usage_body())[0], 200)
        status, body = self.put("one-more", usage_body())
        self.assertEqual((status, body["error"]), (429, "too_many_status"))
        self.clock.advance(11)
        self.assertEqual(self.put("s0", usage_body())[0], 200)  # replacing one is fine
        others = [self.hub.store.add_token("sender-x%d" % n, "sender")[0] for n in range(3)]
        n = hubmod.STATUS_MAX_PER_TOKEN
        for tok in others:
            for i in range(hubmod.STATUS_MAX_PER_TOKEN):
                if n < hubmod.STATUS_MAX_PER_HUB:
                    self.assertEqual(self.put("s%d" % i, usage_body(), token=tok)[0], 200)
                    n += 1
        status, body = self.put("s19", usage_body(), token=others[-1])
        self.assertEqual((status, body["error"]), (429, "too_many_status"))

    def test_expiry_is_computed_and_housekeeping_deletes(self):
        self.put("usage:claude", usage_body(expires_in=60))
        self.assertEqual(len(self.statuses()), 1)
        self.clock.advance(61)
        self.assertEqual(self.statuses(), [])
        self.assertIsNotNone(self.hub.store.get_status(hubmod.status_id(
            self.hub.store.token_by_secret(self.sender)["id"], "usage:claude")))
        self.clock.advance(3600)
        self.assertEqual(self.hub.store.purge()["statuses"], 1)
        with self.hub.store.lock:
            self.assertEqual(self.hub.store.conn.execute("SELECT COUNT(*) FROM status").fetchone()[0], 0)

    def test_a_revoked_tokens_statuses_are_hidden(self):
        self.put("usage:claude", usage_body())
        tok = self.hub.store.token_by_secret(self.sender)
        self.hub.store.revoke_token(tok["id"])
        self.assertEqual(self.statuses(), [])

    def test_etag_and_304(self):
        self.put("usage:claude", usage_body())
        status, body, headers = get_with_headers(self.base + "/v1/status", self.reader)
        self.assertEqual(status, 200)
        tag = headers.get("ETag")
        self.assertTrue(tag and tag.startswith('"'))
        status, body, headers = get_with_headers(self.base + "/v1/status", self.reader, etag=tag)
        self.assertEqual((status, body), (304, {}))
        self.clock.advance(11)
        self.put("usage:claude", usage_body(pct5=70))
        status, body, headers = get_with_headers(self.base + "/v1/status", self.reader, etag=tag)
        self.assertEqual(status, 200)
        self.assertNotEqual(headers.get("ETag"), tag)

    def test_newest_first(self):
        self.put("a", usage_body())
        self.clock.advance(1)
        self.put("b", usage_body())
        self.assertEqual([s["key"] for s in self.statuses()], ["b", "a"])


class StatusReplication(HubTestCase):
    def mesh(self):
        a, b = self.make_hub("hub-a", start=False), self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        b.set_peers([a.url])
        a.start()
        b.start()
        return a, b

    def keys(self, hub, reader):
        _, body = request("GET", hub.url + "/v1/status", reader)
        return [(s["key"], s["usage"]["windows"][0]["used_pct"]) for s in body.get("statuses", [])]

    def test_set_and_clear_replicate(self):
        import time
        a, b = self.mesh()
        sender, reader = self.tokens(a)
        self.assertTrue(wait_until(lambda: b.store.token_by_secret(reader) is not None))
        now = time.time()
        self.assertEqual(request("PUT", a.url + "/v1/status/usage:claude", sender,
                                 usage_body(pct5=33, now=now))[0], 200)
        self.assertTrue(wait_until(lambda: self.keys(b, reader) == [("usage:claude", 33)]))
        # the same token's key on the other hub is the same record (LWW)
        self.assertEqual(request("PUT", b.url + "/v1/status/usage:claude", sender,
                                 usage_body(pct5=44, now=now))[0], 429)  # within 10 s of the replicated write
        self.assertEqual(request("DELETE", b.url + "/v1/status/usage:claude", sender)[1]["cleared"], True)
        self.assertTrue(wait_until(lambda: self.keys(a, reader) == []))

    def test_pull_brings_statuses(self):
        import time
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        request("PUT", a.url + "/v1/status/usage:codex", sender, usage_body(now=time.time()))
        b = self.make_hub("hub-b", start=False)
        b.set_peers([a.url])
        b.start()
        self.assertTrue(wait_until(lambda: self.keys(b, reader) == [("usage:codex", 51)]))

    def test_an_unreadable_status_is_skipped_not_the_batch(self):
        import time
        a = self.make_hub("hub-a")
        now = time.time()
        good = {"key": "usage:claude", "token_id": "tok1", "updated_by": "hub-z",
                "created_at": now, "updated_at": now, **usage_body(now=now)}
        good["id"] = hubmod.status_id("tok1", "usage:claude")
        bad = dict(good, key="usage:x", label="nyp_" + "s" * 20)
        bad["id"] = hubmod.status_id("tok1", "usage:x")
        forged = dict(good, id=hubmod.status_id("tok2", "usage:claude"))
        status, body = request("POST", a.url + "/v1/replicate", PEER_SECRET,
                               {"from_hub": "hub-z", "items": [], "statuses": [bad, good, forged]})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["applied"], 1)
        self.assertEqual(sorted(s["id"] for s in body["skipped"]), sorted([bad["id"], forged["id"]]))
        self.assertEqual([r["key"] for r in a.store.list_statuses()], ["usage:claude"])
        # an older version never replaces a newer one
        older = dict(good, updated_at=now - 60, label="old")
        request("POST", a.url + "/v1/replicate", PEER_SECRET, {"from_hub": "hub-z", "statuses": [older]})
        self.assertEqual(a.store.list_statuses()[0]["label"], "Claude")

    def test_statuses_must_be_an_array(self):
        a = self.make_hub("hub-a")
        status, body = request("POST", a.url + "/v1/replicate", PEER_SECRET,
                               {"from_hub": "hub-z", "statuses": {"x": 1}})
        self.assertEqual((status, body.get("field")), (400, "statuses"))


class Migration(HubTestCase):
    def test_a_schema_10_database_gains_the_status_table(self):
        path = self.tmp + "/old.db"
        conn = sqlite3.connect(path)
        for i, mig in enumerate(hubmod.MIGRATIONS[:10]):
            conn.executescript(mig)
        conn.execute("PRAGMA user_version = 10")
        conn.commit()
        conn.close()
        store = hubmod.Store(path, "hub-a", [])
        try:
            self.assertEqual(store.conn.execute("PRAGMA user_version").fetchone()[0], hubmod.SCHEMA_VERSION)
            self.assertEqual(store.list_statuses(), [])
            self.assertIsNotNone(store.backup_path)
        finally:
            store.close()


if __name__ == "__main__":
    import unittest
    unittest.main()
