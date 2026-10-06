from __future__ import annotations

import os
import sqlite3
import time
import unittest

from support import FakeClock, HubTestCase, hubmod, request

DAY = 86400


def fields(**kw):
    d = {"key": "k", "title": "t"}
    d.update(kw)
    return hubmod.validate_item_input(d)


class Retention(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock(time.time())
        self.hub = self.make_hub("hub-a", clock=self.clock, maintenance_seconds=0)
        self.st = self.hub.store

    def ids(self, hub=None):
        with (hub or self.hub).store.lock:
            return sorted(r[0] for r in (hub or self.hub).store.conn.execute("SELECT id FROM items"))

    def test_purges_closed_and_expired_after_retention(self):
        open_needs, _, _ = self.st.upsert_item(fields(key="open"), None, 0, DAY * 1000)
        resolved, _, _ = self.st.upsert_item(fields(key="res"), None, 0, DAY * 1000)
        self.st.resolve(None, "res")
        dismissed, _, _ = self.st.upsert_item(fields(key="dis"), None, 0, DAY * 1000)
        self.st.patch(dismissed["id"], "dismissed", None, False)
        info, _, _ = self.st.upsert_item(fields(key="info", kind="info"), None, 0, DAY * 1000)
        self.clock.advance(6 * DAY)
        self.assertEqual(self.hub.maintain()["purged"]["items"], 0)
        self.clock.advance(2.5 * DAY)  # closed > 7 days ago; the info item expired > 7 days ago
        out = self.hub.maintain(full=True)
        self.assertEqual(out["purged"]["items"], 3)
        self.assertEqual(self.ids(), [open_needs["id"]])  # open needs items are never purged

    def test_closed_old_records_are_not_applied(self):
        rec, _, _ = self.st.upsert_item(fields(key="x"), None, 0, DAY * 1000)
        self.st.resolve(rec["id"], None)
        wire = hubmod.item_wire(self.st.get_item(rec["id"]))
        self.clock.advance(8 * DAY)
        self.hub.maintain()
        self.assertEqual(self.ids(), [])
        self.assertFalse(self.st.apply_item(wire))
        self.assertEqual(self.ids(), [])
        # an old *open* record still applies (only closed/expired ones are refused)
        live = dict(wire, status="open", id="01ZZZZZZZZZZZZZZZZZZZZZZZZ", key="other")
        self.assertTrue(self.st.apply_item(live))

    def test_outbox_and_invites_purged(self):
        self.st.peers = ["http://peer.example:1"]
        self.st.upsert_item(fields(key="q"), None, 0, DAY * 1000)
        self.assertEqual(self.st.outbox_pending("http://peer.example:1"), 1)
        _code, inv = self.st.create_invite("srv", "sender", 1, 1)
        self.clock.advance(8 * DAY)
        out = self.hub.maintain()
        self.assertEqual(out["purged"]["outbox"], 2)  # the item row and the invite row
        self.assertEqual(out["purged"]["invites"], 1)
        self.assertEqual(self.st.list_invites(include_dead=True), [])

    def test_auto_vacuum_incremental_and_migration(self):
        with self.st.lock:
            self.assertEqual(self.st.conn.execute("PRAGMA auto_vacuum").fetchone()[0], 2)
        old = os.path.join(self.tmp, "old.db")
        c = sqlite3.connect(old)
        c.execute("CREATE TABLE junk(x)")
        c.execute("INSERT INTO junk VALUES (1)")
        c.commit()
        self.assertEqual(c.execute("PRAGMA auto_vacuum").fetchone()[0], 0)
        c.close()
        st = hubmod.Store(old, "h", [])
        try:
            self.assertEqual(st.conn.execute("PRAGMA auto_vacuum").fetchone()[0], 2)
            self.assertEqual(st.conn.execute("SELECT x FROM junk").fetchone()[0], 1)
        finally:
            st.close()


class NoResurrection(HubTestCase):
    def test_anti_entropy_does_not_bring_purged_items_back(self):
        clock = FakeClock(time.time())
        a = self.make_hub("hub-a", clock=clock, maintenance_seconds=0)
        b = self.make_hub("hub-b", clock=clock, maintenance_seconds=0)
        rec, _, _ = b.store.upsert_item(fields(key="gone"), None, 0, DAY * 1000)
        b.store.resolve(rec["id"], None)
        keep, _, _ = b.store.upsert_item(fields(key="keep"), None, 0, DAY * 1000)
        hubmod.PeerWorker(a, b.url).pull()
        self.assertIsNotNone(a.store.get_item(rec["id"]))
        clock.advance(8 * DAY)
        a.maintain()  # a purges; b (not yet maintained) still holds the closed item
        self.assertIsNone(a.store.get_item(rec["id"]))
        a.store.save_peer_state(b.url, cursor=0, epoch="")  # force a full re-pull
        hubmod.PeerWorker(a, b.url).pull()
        self.assertIsNone(a.store.get_item(rec["id"]))
        self.assertIsNotNone(a.store.get_item(keep["id"]))
        # and a push of the old record is refused too
        status, body = request("POST", a.url + "/v1/replicate", "test-peer-secret-0123456789",
                               {"from_hub": "hub-b", "items": [hubmod.item_wire(b.store.get_item(rec["id"]))]})
        self.assertEqual((status, body["applied"]), (200, 0))
        self.assertIsNone(a.store.get_item(rec["id"]))


if __name__ == "__main__":
    unittest.main()
