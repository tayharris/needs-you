"""Short retention (ADR 0012, follow-up): a closed item's text goes ~24 h after it closed and a
text-free tombstone stays ~30 days, so a peer that slept for days still learns it closed."""
from __future__ import annotations

import json
import time
import unittest

from support import PEER_SECRET, FakeClock, HubTestCase, hubmod, request, wait_until

DAY = 86400
HOUR = 3600


def fields(**kw):
    d = {"key": "k", "title": "Approve the deploy", "body": "secret-ish details",
         "links": [{"label": "PR", "url": "https://example.com/pr/1"}], "steps": [{"text": "click"}],
         "source": {"host": "devbox"}}
    d.update(kw)
    return hubmod.validate_item_input(d)


def row(hub, item_id):
    return hub.store.get_item(item_id)


class TextRetention(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock(time.time())
        self.hub = self.make_hub("hub-a", clock=self.clock, maintenance_seconds=0)
        self.st = self.hub.store
        self.owner = "owner-0123456789abcdef"
        self.st.ensure_token("owner", "owner", self.owner)

    def test_defaults(self):
        self.assertEqual(self.hub.cfg["text_retention_hours"], 24)
        self.assertEqual(self.hub.cfg["retention_days"], 30)

    def test_text_goes_a_day_after_close_and_the_tombstone_after_thirty(self):
        open_item, _, _ = self.st.upsert_item(fields(key="open"), None, 0, DAY * 1000)
        closed, _, _ = self.st.upsert_item(fields(key="res"), None, 0, DAY * 1000)
        self.st.resolve(None, "res")
        info, _, _ = self.st.upsert_item(fields(key="info", kind="info"), None, 0, HOUR * 1000)
        self.clock.advance(20 * HOUR)
        self.assertEqual(self.hub.maintain()["purged"]["texts"], 0)
        self.clock.advance(6 * HOUR)  # closed 26 h ago; the info item expired 25 h ago
        self.assertEqual(self.hub.maintain()["purged"]["texts"], 2)
        for item_id in (closed["id"], info["id"]):
            r = row(self.hub, item_id)
            self.assertEqual((r["title"], r["body"], r["links"], r["steps"], r["source"]), ("", "", "[]", "[]", "{}"))
            self.assertIsNone(r["question"])
            self.assertIsNotNone(r["purged_at"])
        self.assertEqual(row(self.hub, open_item["id"])["title"], "Approve the deploy")  # open: kept
        status, body = request("GET", self.hub.url + "/v1/items/" + closed["id"], self.owner)
        self.assertEqual(status, 200)
        self.assertIs(body["tombstone"], True)
        self.assertEqual((body["key"], body["status"], body["title"], body["body"], body["links"], body["steps"]),
                         ("res", "resolved", "", None, [], []))
        self.assertIs(request("GET", self.hub.url + "/v1/items/" + open_item["id"], self.owner)[1]["tombstone"], False)
        self.assertEqual(self.hub.maintain()["purged"]["texts"], 0)  # once
        self.clock.advance(28 * DAY)
        self.assertEqual(self.hub.maintain()["purged"]["items"], 0)
        self.clock.advance(3 * DAY)
        self.assertEqual(self.hub.maintain()["purged"]["items"], 2)
        self.assertIsNone(row(self.hub, closed["id"]))
        self.assertIsNotNone(row(self.hub, open_item["id"]))

    def test_zero_keeps_the_text(self):
        hub = self.make_hub("hub-z", clock=self.clock, maintenance_seconds=0, text_retention_hours=0)
        rec, _, _ = hub.store.upsert_item(fields(), None, 0, DAY * 1000)
        hub.store.resolve(rec["id"], None)
        self.clock.advance(5 * DAY)
        self.assertEqual(hub.maintain()["purged"]["texts"], 0)
        self.assertEqual(row(hub, rec["id"])["title"], "Approve the deploy")

    def test_a_tombstone_record_must_be_closed(self):
        rec, _, _ = self.st.upsert_item(fields(key="o"), None, 0, DAY * 1000)
        wire = dict(hubmod.item_wire(row(self.hub, rec["id"])), tombstone=True, id="01" + rec["id"][2:],
                    updated_by="zz")
        changed, skip = self.st.apply_record("item", wire)
        self.assertFalse(changed)
        self.assertIn("tombstone", skip["reason"])


class SleepingPeer(HubTestCase):
    """The Mac (here hub `mac`) sleeps for days; the server resolves an item and purges its text.
    When the Mac wakes it learns the item closed, from the tombstone."""

    def setUp(self):
        super().setUp()
        self.clock = FakeClock(time.time())
        self.srv = self.make_hub("srv", clock=self.clock, maintenance_seconds=0)
        self.mac = self.make_hub("mac", clock=self.clock, maintenance_seconds=0, start=False)
        self.mac.set_peers([self.srv.url])
        self.sender, _ = self.tokens(self.srv)

    def test_a_peer_that_slept_learns_the_item_closed(self):
        status, item = request("POST", self.srv.url + "/v1/items", self.sender,
                               {"key": "deploy", "title": "Approve the deploy", "body": "details"})
        self.assertEqual(status, 201)
        hubmod.PeerWorker(self.mac, self.srv.url).pull()   # the Mac had it, open, then slept
        self.assertEqual(row(self.mac, item["id"])["status"], "open")
        request("POST", self.srv.url + "/v1/items/resolve", self.sender, {"key": "deploy"})
        self.clock.advance(3 * DAY)
        self.assertEqual(self.srv.maintain()["purged"]["texts"], 1)
        hubmod.PeerWorker(self.mac, self.srv.url).pull()   # wakes up
        r = row(self.mac, item["id"])
        self.assertEqual((r["status"], r["title"], r["body"]), ("resolved", "", ""))
        self.assertIsNotNone(r["purged_at"])

    def test_an_equal_version_with_text_never_brings_it_back(self):
        status, item = request("POST", self.srv.url + "/v1/items", self.sender,
                               {"key": "k2", "title": "Has text", "body": "b"})
        request("POST", self.srv.url + "/v1/items/resolve", self.sender, {"key": "k2"})
        full = hubmod.item_wire(row(self.srv, item["id"]))    # what a peer that kept it holds
        self.clock.advance(2 * DAY)
        self.srv.maintain()
        status, body = request("POST", self.srv.url + "/v1/replicate", PEER_SECRET,
                               {"from_hub": "other", "items": [full]})
        self.assertEqual((status, body["applied"]), (200, 0))
        self.assertEqual(row(self.srv, item["id"])["title"], "")

    def test_an_expired_tombstone_never_resurrects_the_item(self):
        status, item = request("POST", self.srv.url + "/v1/items", self.sender, {"key": "k3", "title": "Old"})
        request("POST", self.srv.url + "/v1/items/resolve", self.sender, {"key": "k3"})
        full = hubmod.item_wire(row(self.srv, item["id"]))
        self.clock.advance(2 * DAY)
        self.srv.maintain()
        tomb = hubmod.item_wire(row(self.srv, item["id"]))
        self.assertIs(tomb["tombstone"], True)
        self.clock.advance(31 * DAY)
        self.assertEqual(self.srv.maintain()["purged"]["items"], 1)
        for rec in (full, tomb):
            status, body = request("POST", self.srv.url + "/v1/replicate", PEER_SECRET,
                                   {"from_hub": "other", "items": [rec]})
            self.assertEqual((status, body["applied"]), (200, 0))
        self.assertIsNone(row(self.srv, item["id"]))

    def test_a_tombstone_doesnt_blank_a_merge_winner(self):
        st = self.srv.store
        win, _, _ = st.upsert_item(fields(key="w", title="winner"), None, 0, DAY * 1000)
        lose, _, _ = st.upsert_item(fields(key="l", title="loser"), None, 0, DAY * 1000)
        with st.tx() as c:
            c.execute("UPDATE items SET status='resolved', superseded_by=?, content_updated_at=?, title='', "
                      "purged_at=? WHERE id=?", (win["id"], win["content_updated_at"] + 5000, 1, lose["id"]))
            st._settle_content(win["id"])
        self.assertEqual(row(self.srv, win["id"])["title"], "winner")


class NoWayBack(HubTestCase):
    """Purged text stays gone: no peer version, client timestamp or leftover copy brings it back."""

    def setUp(self):
        super().setUp()
        self.clock = FakeClock(time.time())
        self.hub = self.make_hub("hub-a", clock=self.clock, maintenance_seconds=0)
        self.st = self.hub.store

    def closed_item(self, key="k"):
        rec, _, _ = self.st.upsert_item(fields(key=key), None, 0, DAY * 1000)
        self.st.resolve(rec["id"], None)
        return row(self.hub, rec["id"])

    def push(self, rec):
        return request("POST", self.hub.url + "/v1/replicate", PEER_SECRET, {"from_hub": "hub-b", "items": [rec]})

    def test_a_newer_closed_version_with_text_stays_a_tombstone(self):
        """A peer that keeps text longer marks the closed item seen (a newer version, with its
        text). Its metadata is taken; the text isn't."""
        full = hubmod.item_wire(self.closed_item())
        self.clock.advance(2 * DAY)
        self.hub.maintain()
        newer = dict(full, seen_at=hubmod.fmt_ts(self.st.now_ms()), updated_by="hub-b",
                     updated_at=hubmod.fmt_ts(self.st.now_ms()))
        self.assertEqual(self.push(newer)[1]["applied"], 1)
        r = row(self.hub, full["id"])
        self.assertEqual((r["title"], r["body"], r["links"]), ("", "", "[]"))
        self.assertIsNotNone(r["seen_at"])
        self.assertIsNotNone(r["purged_at"])

    def test_old_closed_text_from_a_peer_is_never_stored(self):
        """A peer with longer retention sends a closed item, closed long ago, to a hub that
        never had it: it lands as a tombstone, not with its text."""
        other = self.make_hub("hub-c", clock=self.clock, maintenance_seconds=0, text_retention_hours=0)
        rec, _, _ = other.store.upsert_item(fields(key="old"), None, 0, DAY * 1000)
        other.store.resolve(rec["id"], None)
        self.clock.advance(3 * DAY)
        self.assertEqual(self.push(hubmod.item_wire(row(other, rec["id"])))[1]["applied"], 1)
        r = row(self.hub, rec["id"])
        self.assertEqual((r["status"], r["title"]), ("resolved", ""))
        self.assertIsNotNone(r["purged_at"])

    def test_a_future_timestamp_doesnt_dodge_the_purge(self):
        """Eligibility runs on this hub's clock (when it stored the version), not on a
        peer's updated_at."""
        rec, _, _ = self.st.upsert_item(fields(key="f"), None, 0, DAY * 1000)
        wire = hubmod.item_wire(row(self.hub, rec["id"]))
        future = self.st.now_ms() + 3650 * DAY * 1000
        self.push(dict(wire, status="resolved", updated_by="hub-b", updated_at=hubmod.fmt_ts(future)))
        self.assertEqual(row(self.hub, rec["id"])["status"], "resolved")
        self.clock.advance(25 * HOUR)
        self.assertEqual(self.hub.maintain()["purged"]["texts"], 1)
        self.assertEqual(row(self.hub, rec["id"])["title"], "")

    def test_a_repost_of_the_key_is_a_new_item(self):
        old = self.closed_item("same")
        self.clock.advance(2 * DAY)
        self.hub.maintain()
        new, created, _ = self.st.upsert_item(fields(key="same", title="fresh"), None, 0, DAY * 1000)
        self.assertTrue(created)
        self.assertNotEqual(new["id"], old["id"])
        self.assertEqual(row(self.hub, old["id"])["title"], "")  # the old one stays a tombstone

    def test_no_copy_of_the_text_is_left_behind(self):
        item = self.closed_item("secret")
        # an unreadable replicated record with the same text sits in quarantine
        changed, skip = self.st.apply_record("item", dict(hubmod.item_wire(item), id="01QUARANTINED",
                                                          status="exploded"))
        self.assertIsNotNone(skip)
        backup = self.st._backup(hubmod.SCHEMA_VERSION)   # a pre-migration backup
        self.clock.advance(2 * DAY)
        self.hub.maintain(full=True)
        with self.st.lock:
            self.assertEqual(self.st.conn.execute("PRAGMA secure_delete").fetchone()[0], 1)
            self.assertEqual(self.st.conn.execute("SELECT COUNT(*) FROM quarantine").fetchone()[0], 0)
        import sqlite3
        b = sqlite3.connect(backup)
        try:
            self.assertEqual(b.execute("SELECT title, body FROM items WHERE id = ?", (item["id"],)).fetchone(),
                             ("", ""))
        finally:
            b.close()
        for path in (self.st.path, self.st.path + "-wal", backup):
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            self.assertNotIn(b"secret-ish details", data, path)


if __name__ == "__main__":
    unittest.main()
