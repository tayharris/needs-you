"""One item record a peer can't read (a newer hub's status, say) must not hold up the rest.

The receiver applies what it can and lists the skipped items; the pusher and puller move
past them (counted in peer status, kept in quarantine), and still retry transient failures.
Against an older peer that refuses the whole batch with 400, the pusher halves the batch
until it has found the one record and skips that.

Token and invite records are security state (a revocation, a role, a redemption): one that
can't be read is never skipped. Replication fails closed there, retries, and says so."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import PEER_SECRET, HubTestCase, hubmod, request, wait_until


def item_rec(i, status="open", **extra):
    rec = {"id": "01TEST%020d" % i, "key": "k%d" % i, "context": "work", "kind": "needs",
           "priority": "normal", "title": "t%d" % i, "body": None, "links": [], "steps": [],
           "source": {}, "status": status, "created_at": "2026-10-06T17:04:05.123Z",
           "updated_at": "2026-10-06T17:04:05.123Z", "content_updated_at": "2026-10-06T17:04:05.123Z",
           "seen_at": None, "expires_at": None, "superseded_by": None, "token_id": None,
           "origin_hub": "hub-z", "updated_by": "hub-z"}
    rec.update(extra)
    return rec


def plant_unreadable(hub, i=999):
    """Store, as if a newer hub had written it, an item whose status this version doesn't
    know, and queue it for every peer."""
    rec = hubmod.normalise_item_record(item_rec(i))
    rec["status"] = "archived"
    with hub.store.tx():
        hub.store._write_item(rec)
        hub.store.enqueue("item", rec["id"])
    hub.notify()
    return rec["id"]


TS = "2026-10-06T17:04:05.123Z"


def token_rec(tid="T1", role="sender", revoked=None, updated=TS, h="0" * 64):
    return {"id": tid, "name": "n-" + tid, "role": role, "hash": h, "created_at": TS,
            "updated_at": updated, "revoked_at": revoked, "updated_by": "hub-z"}


def plant_unreadable_revocation(hub, tok_id):
    """Revoke a token on `hub` with a role this version doesn't know (as a newer hub might
    write it), and queue it for every peer."""
    with hub.store.tx():
        row = dict(hub.store.conn.execute("SELECT * FROM tokens WHERE id = ?", (tok_id,)).fetchone())
        row.update({"role": "auditor", "revoked_at": hub.store.now_ms(),
                    "updated_at": hub.store.bump(row["updated_at"]), "updated_by": hub.hub_id})
        hub.store._write_token(row)
        hub.store.enqueue("token", tok_id)
    hub.notify()


class Receiver(HubTestCase):
    def test_bad_items_are_skipped_not_the_batch(self):
        hub = self.make_hub("hub-b", clock=None)
        good = [item_rec(1), item_rec(3)]
        bad = item_rec(2, status="archived")
        s, body = request("POST", hub.url + "/v1/replicate", PEER_SECRET,
                          {"from_hub": "hub-z", "items": [good[0], bad, good[1], "not an object"]})
        self.assertEqual(s, 200, body)
        self.assertEqual(body["applied"], 2)
        skipped = {(r["kind"], r.get("id")) for r in body["skipped"]}
        self.assertEqual(skipped, {("item", bad["id"]), ("item", None)})
        self.assertTrue(all(r["reason"] for r in body["skipped"]))
        self.assertIsNotNone(hub.store.get_item(good[1]["id"]))
        self.assertIsNone(hub.store.get_item(bad["id"]))
        # kept in quarantine, and applied once this hub can read it
        with hub.store.lock:
            q = hub.store.conn.execute("SELECT id FROM quarantine").fetchall()
        self.assertEqual([r[0] for r in q], [bad["id"]])
        orig = hubmod.STATUSES
        hubmod.STATUSES = orig + ("archived",)
        try:
            self.assertEqual(hub.store.retry_quarantine(), 1)
        finally:
            hubmod.STATUSES = orig
        self.assertIsNotNone(hub.store.get_item(bad["id"]))

    def test_unreadable_token_or_invite_fails_the_batch_closed(self):
        hub = self.make_hub("hub-b", clock=None)
        hub.store.apply_token(token_rec())
        revoke = token_rec(role="auditor", revoked=TS, updated="2026-10-06T18:00:00.000Z")
        for batch in ({"tokens": [revoke]}, {"invites": ["not an object"]},
                      {"invites": [{"id": "I1", "role": "auditor"}]}):
            with self.subTest(batch):
                body = dict(batch, from_hub="hub-z", items=[item_rec(1)])
                s, out = request("POST", hub.url + "/v1/replicate", PEER_SECRET, body)
                self.assertEqual(s, 400, out)
                self.assertNotIn("0" * 64, json.dumps(out))  # a token hash is never echoed
                self.assertIsNone(hub.store.get_item(item_rec(1)["id"]))  # nothing applied
        self.assertIsNone(hub.store.conn.execute("SELECT revoked_at FROM tokens WHERE id='T1'").fetchone()[0])


class Mesh(HubTestCase):
    def pair(self):
        a = self.make_hub("hub-a", start=False)
        b = self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        b.set_peers([a.url])
        return a, b

    def test_push_moves_past_a_record_the_peer_cant_read(self):
        a, b = self.pair()
        sender, _ = self.tokens(a)
        bad = plant_unreadable(a)
        a.store.upsert_item(hubmod.validate_item_input({"key": "after", "title": "t"}), None, 0, 0)
        a.start()
        b.start()
        self.assertTrue(wait_until(lambda: a.store.outbox_pending(b.url) == 0), a.peer_status(b.url))
        self.assertTrue(wait_until(lambda: b.store._effective_open("after", b.store.now_ms())))
        self.assertIsNone(b.store.get_item(bad))
        st = a.peer_status(b.url)
        self.assertGreaterEqual(st["skipped_push"], 1)
        self.assertIn(bad, st["last_skipped"])

    def test_pull_moves_past_a_record_it_cant_read(self):
        a, b = self.pair()
        b.set_peers([])  # b never pushes: a only learns by pulling
        bad = plant_unreadable(b)
        b.store.upsert_item(hubmod.validate_item_input({"key": "after", "title": "t"}), None, 0, 0)
        a.start()
        b.start()
        self.assertTrue(wait_until(lambda: a.store._effective_open("after", a.store.now_ms())),
                        a.peer_status(b.url))
        st = a.peer_status(b.url)
        self.assertEqual(st["skipped_pull"], 1)
        self.assertIn(bad, st["last_skipped"])
        self.assertTrue(wait_until(lambda: a.store.peer_state(b.url)["cursor"] == b.store.max_seq()))


class OldPeer:
    """A peer running a hub from before per-record skipping: /v1/replicate refuses the whole
    batch with 400 when one record doesn't parse, and applies nothing. `fail_with` makes it
    answer every push with that status instead (a transient failure)."""

    def __init__(self, test):
        self.received = []
        self.batches = []
        self.fail_with = None
        self.refuse_tokens = False
        peer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._send(200, {"hub_id": "hub-old", "epoch": "E", "max_seq": 0, "next_after": 0,
                                 "more": False, "items": [], "tokens": [], "invites": []})

            def do_POST(self):
                data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                peer.batches.append(len(data.get("items", [])))
                if peer.fail_with:
                    return self._send(peer.fail_with, {"error": "internal", "message": "try later"})
                if peer.refuse_tokens and data.get("tokens"):
                    return self._send(400, {"error": "invalid", "message": "bad token record"})
                try:
                    for it in data.get("items", []):
                        hubmod.normalise_item_record(it)
                except hubmod.ApiError as e:
                    return self._send(400, {"error": "invalid", "message": e.message})
                peer.received += [it["id"] for it in data.get("items", [])]
                self._send(200, {"ok": True, "applied": len(data.get("items", [])), "hub_id": "hub-old"})

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        test.addCleanup(self.srv.shutdown)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]


class MixedVersion(HubTestCase):
    def test_older_peer_400_is_bisected_to_the_bad_record(self):
        old = OldPeer(self)
        a = self.make_hub("hub-a", start=False)
        a.set_peers([old.url])
        made = []
        for i in range(10):
            made.append(a.store.upsert_item(hubmod.validate_item_input({"key": "k%d" % i, "title": "t"}),
                                            None, 0, 0)[0]["id"])
            if i == 6:
                bad = plant_unreadable(a)
        a.start()
        self.assertTrue(wait_until(lambda: a.store.outbox_pending(old.url) == 0), a.peer_status(old.url))
        self.assertEqual(sorted(set(old.received)), sorted(made))
        st = a.peer_status(old.url)
        self.assertEqual(st["skipped_push"], 1)
        self.assertIn(bad, st["last_skipped"])
        self.assertLess(len(old.batches), 20, old.batches)  # halving, not one request a record

    def test_transient_failures_are_still_retried(self):
        old = OldPeer(self)
        old.fail_with = 503
        a = self.make_hub("hub-a", start=False)
        a.set_peers([old.url])
        a.store.upsert_item(hubmod.validate_item_input({"key": "k", "title": "t"}), None, 0, 0)
        a.start()
        self.assertTrue(wait_until(lambda: len(old.batches) >= 3))
        self.assertEqual(a.store.outbox_pending(old.url), 1)
        self.assertEqual(a.peer_status(old.url)["skipped_push"], 0)
        old.fail_with = None
        self.assertTrue(wait_until(lambda: a.store.outbox_pending(old.url) == 0))
        self.assertEqual(len(old.received), 1)


class FailClosed(HubTestCase):
    """A revocation a peer can't read is retried, never skipped: the token never stays
    accepted on the peer because replication passed over its revocation."""

    def setUp(self):
        super().setUp()
        self.roles = hubmod.ROLES
        self.addCleanup(setattr, hubmod, "ROLES", self.roles)

    def upgrade(self):
        hubmod.ROLES = self.roles + ("auditor",)  # every hub in this process can read it now

    def accepted(self, hub, token):
        s, body = request("GET", hub.url + "/v1/health", token)
        return body.get("token") is not None

    def test_push_holds_an_unreadable_revocation_until_the_peer_can_read_it(self):
        a = self.make_hub("hub-a", start=False)
        b = self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        tok, rec = a.store.add_token("ci", "sender")
        b.store.apply_token(hubmod.token_wire(rec))
        plant_unreadable_revocation(a, rec["id"])
        a.store.upsert_item(hubmod.validate_item_input({"key": "after", "title": "t"}), None, 0, 0)
        a.start()
        b.start()
        self.assertTrue(wait_until(lambda: a.peer_status(b.url)["blocked"]), a.peer_status(b.url))
        st = a.peer_status(b.url)
        self.assertIn(rec["id"], st["blocked"])
        self.assertNotIn(rec["hash"], json.dumps(st))
        self.assertEqual(st["skipped_push"], 0)
        self.assertGreaterEqual(a.store.outbox_pending(b.url), 1)  # not acked
        self.assertTrue(self.accepted(b, tok))  # b never heard; it was not told "done" either
        self.upgrade()
        self.assertTrue(wait_until(lambda: not self.accepted(b, tok)))
        self.assertTrue(wait_until(lambda: a.store.outbox_pending(b.url) == 0))
        self.assertTrue(wait_until(lambda: not a.peer_status(b.url)["blocked"]))

    def test_pull_does_not_move_past_an_unreadable_revocation(self):
        a = self.make_hub("hub-a", start=False)
        b = self.make_hub("hub-b", start=False)
        a.set_peers([b.url])  # b never pushes: a only learns by pulling
        tok, rec = b.store.add_token("ci", "sender")
        a.store.apply_token(hubmod.token_wire(rec))
        plant_unreadable_revocation(b, rec["id"])
        a.start()
        b.start()
        self.assertTrue(wait_until(lambda: a.peer_status(b.url)["blocked"]), a.peer_status(b.url))
        self.assertLess(a.store.peer_state(b.url)["cursor"], b.store.max_seq())
        self.assertTrue(self.accepted(a, tok))  # still the old version: it was not skipped
        self.upgrade()
        a.workers[b.url].next_pull = 0
        a.notify()
        self.assertTrue(wait_until(lambda: not self.accepted(a, tok)))
        self.assertTrue(wait_until(lambda: a.store.peer_state(b.url)["cursor"] == b.store.max_seq()))
        self.assertTrue(wait_until(lambda: not a.peer_status(b.url)["blocked"]))

    def test_older_peer_400_on_a_token_record_is_not_skipped(self):
        old = OldPeer(self)
        old.refuse_tokens = True
        a = self.make_hub("hub-a", start=False)
        a.set_peers([old.url])
        for i in range(3):
            a.store.upsert_item(hubmod.validate_item_input({"key": "k%d" % i, "title": "t"}), None, 0, 0)
        a.store.add_token("ci", "sender")
        a.start()
        self.assertTrue(wait_until(lambda: a.peer_status(old.url)["blocked"]), a.peer_status(old.url))
        self.assertEqual(len(set(old.received)), 3)  # what came before still went through
        self.assertEqual(a.store.outbox_pending(old.url), 1)
        self.assertEqual(a.peer_status(old.url)["skipped_push"], 0)
