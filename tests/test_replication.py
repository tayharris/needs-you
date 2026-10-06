from __future__ import annotations

import time
import unittest

from support import (PEER_SECRET, HubTestCase, hubmod, request, snapshot, token_snapshot,
                     wait_until)


def fields(**kw):
    d = {"key": "k", "title": "t"}
    d.update(kw)
    return hubmod.validate_item_input(d)


class Mesh(HubTestCase):
    """2-3 in-process hubs on ephemeral ports, fully meshed."""

    def mesh(self, names, start=True):
        hubs = [self.make_hub(n, start=False) for n in names]
        for h in hubs:
            h.set_peers([o.url for o in hubs if o is not h])
        if start:
            for h in hubs:
                h.start()
        return hubs

    def converged(self, hubs):
        snaps = [snapshot(h) for h in hubs]
        toks = [token_snapshot(h) for h in hubs]
        return all(s == snaps[0] for s in snaps) and all(t == toks[0] for t in toks)

    def assertConverged(self, hubs, timeout=15):
        ok = wait_until(lambda: self.converged(hubs), timeout)
        if not ok:
            for h in hubs:
                print(h.hub_id, [(i["id"][-6:], i["key"], i["status"], i["title"]) for i in snapshot(h)],
                      [h.peer_status(p) for p in h.cfg["peers"]])
        self.assertTrue(ok, "hubs did not converge")


class Convergence(Mesh):
    def test_writes_on_different_hubs_converge(self):
        a, b, c = self.mesh(["hub-a", "hub-b", "hub-c"])
        sa, _ = self.tokens(a)
        sb, _ = self.tokens(b)
        _, x = request("POST", a.url + "/v1/items", sa, {"key": "x", "title": "from a"})
        _, y = request("POST", b.url + "/v1/items", sb, {"key": "y", "title": "from b"})
        self.assertConverged([a, b, c])
        # ids are minted once and are the same everywhere
        self.assertEqual(sorted(i["id"] for i in snapshot(c)), sorted([x["id"], y["id"]]))
        # tokens minted on a work on c
        _, rc = self.tokens(c)
        status, body = request("POST", c.url + "/v1/items", sa, {"key": "x", "title": "from a, via c"})
        self.assertEqual(status, 200)
        self.assertEqual(body["id"], x["id"])  # upsert used the replicated id
        status, body = request("POST", c.url + "/v1/items/resolve", sb, {"key": "y"})
        self.assertEqual(status, 200)
        self.assertConverged([a, b, c])
        for h in (a, b, c):
            items = {i["key"]: i for i in snapshot(h)}
            self.assertEqual(items["x"]["title"], "from a, via c")
            self.assertEqual(items["y"]["status"], "resolved")
        del rc

    def test_late_replicated_item_is_seen_by_since_polling(self):
        """`since` is matched against when *this* hub stored the version, so an item that
        reaches the Mac's hub late (older updated_at than the cursor) is still delivered."""
        a, b = self.mesh(["hub-a", "hub-b"], start=False)
        rec, _, _ = a.store.upsert_item(fields(key="late", title="t"), None, 0, 1000)
        b.start()
        _, rb = self.tokens(b)
        time.sleep(0.01)
        _, body = request("GET", b.url + "/v1/items?status=open", rb)
        self.assertEqual(body["items"], [])
        cursor = body["server_time"]
        self.assertGreater(cursor, hubmod.fmt_ts(rec["updated_at"]))
        a.start()
        self.assertTrue(wait_until(lambda: b.store.get_item(rec["id"]) is not None))
        _, body = request("GET", b.url + "/v1/items?status=open&since=" + cursor, rb)
        self.assertEqual([i["id"] for i in body["items"]], [rec["id"]])

    def test_patch_from_the_mac_replicates(self):
        a, b = self.mesh(["hub-a", "hub-b"])
        sa, ra = self.tokens(a)
        _, x = request("POST", a.url + "/v1/items", sa, {"key": "x", "title": "t"})
        self.assertConverged([a, b])
        status, _ = request("PATCH", b.url + "/v1/items/" + x["id"], ra, {"status": "dismissed"})
        self.assertEqual(status, 200)
        self.assertConverged([a, b])
        self.assertEqual(a.store.get_item(x["id"])["status"], "dismissed")

    def test_token_revocation_replicates(self):
        a, b = self.mesh(["hub-a", "hub-b"])
        sa, _ = self.tokens(a)
        self.assertConverged([a, b])
        self.assertEqual(request("GET", b.url + "/v1/health", sa)[1]["token"]["role"], "sender")
        name = [t for t in a.store.list_tokens() if t["role"] == "sender"][0]["name"]
        a.store.revoke_token(name)
        a.notify()
        self.assertConverged([a, b])
        self.assertIsNone(request("GET", b.url + "/v1/health", sa)[1]["token"])
        self.assertEqual(request("POST", b.url + "/v1/items", sa, {"key": "x", "title": "t"})[0], 401)
        # only hashes travel
        for t in token_snapshot(b):
            self.assertEqual(len(t["hash"]), 64)
            self.assertNotIn(sa, str(t))

    def test_kill_and_restart_catches_up(self):
        a, b, c = self.mesh(["hub-a", "hub-b", "hub-c"])
        sa, _ = self.tokens(a)
        request("POST", a.url + "/v1/items", sa, {"key": "before", "title": "t"})
        self.assertConverged([a, b, c])

        c_cfg = dict(c.cfg)
        c_port = c.port
        c.stop()

        # writes on a and b while c is down, including an update and a resolve
        sb, _ = self.tokens(b)
        request("POST", a.url + "/v1/items", sa, {"key": "during-a", "title": "t"})
        request("POST", b.url + "/v1/items", sb, {"key": "during-b", "title": "t"})
        request("POST", b.url + "/v1/items", sa, {"key": "before", "title": "edited while c down"})
        request("POST", a.url + "/v1/items/resolve", sa, {"key": "during-a"})
        self.assertConverged([a, b])
        time.sleep(0.5)  # let a and b fail against c and back off
        self.assertGreater(a.store.outbox_pending(c.url) + b.store.outbox_pending(c.url), 0)

        c_cfg["port"] = c_port
        c2 = hubmod.Hub(c_cfg)
        self.hubs.append(c2)
        c2.start()
        self.assertConverged([a, b, c2])
        items = {i["key"]: i for i in snapshot(c2)}
        self.assertEqual(items["before"]["title"], "edited while c down")
        self.assertEqual(items["during-a"]["status"], "resolved")
        wait_until(lambda: a.store.outbox_pending(c.url) == 0 and b.store.outbox_pending(c.url) == 0)
        self.assertEqual(a.store.outbox_pending(c.url), 0)

    def test_anti_entropy_brings_a_new_hub_up_to_date(self):
        a, b = self.mesh(["hub-a", "hub-b"])
        sa, _ = self.tokens(a)
        for i in range(30):
            request("POST", a.url + "/v1/items", sa, {"key": "k%d" % i, "title": "t%d" % i})
        self.assertConverged([a, b])
        # c knows a and b, but they don't know c: nothing is ever pushed to it
        c = self.make_hub("hub-c", start=False)
        c.set_peers([a.url, b.url])
        c.start()
        self.assertConverged([a, b, c])
        self.assertEqual(len(snapshot(c)), 30)

    def test_anti_entropy_pages(self):
        a = self.make_hub("hub-a")
        sa, _ = self.tokens(a)
        for i in range(25):
            a.store.upsert_item(fields(key="p%d" % i), None, 0, 1000)
        status, body = request("GET", a.url + "/v1/replicate/changes?after=0&limit=10", PEER_SECRET)
        self.assertEqual(status, 200)
        self.assertTrue(body["more"])
        self.assertEqual(len(body["items"]) + len(body["tokens"]), 10)
        self.assertEqual(request("GET", a.url + "/v1/replicate/changes", "wrong")[0], 401)
        del sa


class Conflicts(Mesh):
    def test_same_key_minted_on_two_hubs_lower_ulid_wins(self):
        a, b = self.mesh(["hub-a", "hub-b"], start=False)
        # both hubs accept the key before either hears of the other (a partition)
        ra, _, _ = a.store.upsert_item(fields(key="race", title="from a"), None, 0, 1000)
        time.sleep(0.01)
        rb, _, _ = b.store.upsert_item(fields(key="race", title="from b, newer"), None, 0, 1000)
        self.assertNotEqual(ra["id"], rb["id"])
        a.start()
        b.start()
        self.assertConverged([a, b])
        winner_id = min(ra["id"], rb["id"])
        loser_id = max(ra["id"], rb["id"])
        for h in (a, b):
            items = {i["id"]: i for i in snapshot(h)}
            self.assertEqual(items[winner_id]["status"], "open")
            self.assertEqual(items[winner_id]["title"], "from b, newer")  # freshest content kept
            self.assertEqual(items[loser_id]["status"], "resolved")
            self.assertEqual(items[loser_id]["superseded_by"], winner_id)
            opens = [i for i in items.values() if i["status"] == "open" and i["key"] == "race"]
            self.assertEqual(len(opens), 1)

    def test_three_way_race(self):
        hubs = self.mesh(["hub-a", "hub-b", "hub-c"], start=False)
        recs = []
        for h in hubs:
            r, _, _ = h.store.upsert_item(fields(key="race3", title="from " + h.hub_id), None, 0, 1000)
            recs.append(r)
            time.sleep(0.005)
        for h in hubs:
            h.start()
        self.assertConverged(hubs)
        winner = min(r["id"] for r in recs)
        for h in hubs:
            opens = [i for i in snapshot(h) if i["status"] == "open"]
            self.assertEqual([i["id"] for i in opens], [winner])
            self.assertEqual(opens[0]["title"], "from hub-c")


class LastWriterWins(HubTestCase):
    def rec(self, **kw):
        base = {"id": "01AAAAAAAAAAAAAAAAAAAAAAAA", "key": "k", "context": "work", "kind": "needs",
                "priority": "normal", "title": "t", "status": "open",
                "created_at": "2026-10-06T10:00:00.000Z", "updated_at": "2026-10-06T10:00:00.000Z",
                "updated_by": "hub-a"}
        base.update(kw)
        return base

    def test_table(self):
        h = self.make_hub("hub-x", start=False)
        st = h.store
        cases = [
            # (incoming record, applied?, resulting title)
            (self.rec(title="first"), True, "first"),
            (self.rec(title="same version again"), False, "first"),
            (self.rec(title="older", updated_at="2026-10-06T09:59:59.999Z"), False, "first"),
            (self.rec(title="tie, higher hub id", updated_by="hub-b"), True, "tie, higher hub id"),
            (self.rec(title="tie, lower hub id", updated_by="hub-0"), False, "tie, higher hub id"),
            (self.rec(title="newer", updated_at="2026-10-06T10:00:00.001Z", updated_by="hub-0"), True, "newer"),
        ]
        for rec, applied, title in cases:
            with self.subTest(rec["title"]):
                self.assertEqual(st.apply_item(rec), applied)
                self.assertEqual(st.get_item(rec["id"])["title"], title)

    def test_bad_records_rejected(self):
        h = self.make_hub("hub-x", start=False)
        for bad in ({}, self.rec(status="weird"), self.rec(updated_at="nope"), "x"):
            with self.subTest(str(bad)[:40]):
                with self.assertRaises(hubmod.ApiError):
                    h.store.apply_item(bad)

    def test_replicate_to_self_is_refused(self):
        h = self.make_hub("hub-x")
        status, _ = request("POST", h.url + "/v1/replicate", PEER_SECRET,
                            {"from_hub": "hub-x", "items": []})
        self.assertEqual(status, 409)


if __name__ == "__main__":
    unittest.main()
