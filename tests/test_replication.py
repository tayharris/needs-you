from __future__ import annotations

import json
import time
import unittest

from support import (PEER_SECRET, HubTestCase, garbage_server, hubmod, request, snapshot, token_snapshot,
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


class WorkerSurvives(Mesh):
    def test_broken_peer_responses_dont_kill_the_worker(self):
        """A peer URL that speaks something other than HTTP, cuts a response short, or answers
        with JSON of the wrong shape raises outside (OSError, ValueError). The per-peer thread
        must log it and retry, not die (replication to that peer would stop until restart)."""
        payloads = {
            "not http": b"SSH-2.0-OpenSSH_9.6\r\n",
            "truncated": b"HTTP/1.0 200 OK\r\nContent-Length: 500\r\n\r\n{\"ok\"",
            "json list": b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[]",
            "null max_seq": (b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n"
                             b"{\"hub_id\": \"hub-z\", \"epoch\": \"\", \"max_seq\": null}"),
        }
        urls = {name: garbage_server(self, p) for name, p in payloads.items()}
        a = self.make_hub("hub-a", start=False)
        a.set_peers(list(urls.values()))
        a.start()
        sender, _ = self.tokens(a)
        request("POST", a.url + "/v1/items", sender, {"key": "k", "title": "t"})
        for name, url in urls.items():
            with self.subTest(name):
                w = a.workers[url]
                self.assertTrue(wait_until(lambda: a.store.peer_state(url)["last_error"]
                                           or a.store.peer_state(url)["last_push_ok"], 10))
                time.sleep(0.5)  # a few more rounds of push and pull
                self.assertTrue(w.is_alive(), "worker for %s died" % name)


class BigBatches(Mesh):
    def test_push_batches_stay_under_the_peer_body_limit(self):
        """200 outbox rows of large items (non-ASCII text is \\u-escaped on the wire, 6 bytes
        a character) can exceed the receiver's 8 MiB /v1/replicate limit. The receiver says
        413 every time, the same rows are retried forever and the push to that peer is stuck."""
        a, b = self.mesh(["hub-a", "hub-b"], start=False)
        url = "https://ci.example/" + "x" * 1950
        cjk = "漢" * 199
        for i in range(200):
            a.store.upsert_item(hubmod.validate_item_input({
                "key": "big-%d" % i, "title": "big %d" % i, "body": "字" * 2000,
                "links": [{"label": "L%d" % n, "url": url} for n in range(6)],
                "steps": [{"text": cjk, "link": {"label": "S", "url": url}} for _ in range(10)],
            }), None, 0, 0)
        rows = a.store.outbox_batch(b.url, 200)
        items, _t, _i = a.store.records_for(rows)
        size = len(json.dumps({"items": [hubmod.item_wire(r) for r in items]}))
        self.assertGreater(size, hubmod.MAX_REPLICATE_BYTES)  # the premise
        a.start()
        b.start()
        self.assertTrue(wait_until(lambda: a.store.outbox_pending(b.url) == 0, 20),
                        a.peer_status(b.url))


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

    def test_steps_replicate_and_merge(self):
        a, b = self.mesh(["hub-a", "hub-b"])
        sa, _ = self.tokens(a)
        steps = [{"text": "Rotate the key", "link": {"label": "Console", "url": "https://c/x"}},
                 {"text": "Restart the job", "done": True}]
        _, x = request("POST", a.url + "/v1/items", sa, {"key": "x", "title": "t", "steps": steps})
        self.assertConverged([a, b])
        want = [{"text": "Rotate the key", "done": False, "link": {"label": "Console", "url": "https://c/x"}},
                {"text": "Restart the job", "done": True}]
        for h in (a, b):
            self.assertEqual(hubmod.item_wire(h.store.get_item(x["id"]))["steps"], want)

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

    def test_old_peer_payloads_without_invites_are_accepted(self):
        """A pre-invites hub sends no `invites` key and knows only sender/reader tokens."""
        h = self.make_hub("hub-x")
        tok = {"id": "01TOK", "name": "old-sender", "role": "sender", "hash": "d" * 64,
               "created_at": "2026-10-06T10:00:00.000Z", "updated_at": "2026-10-06T10:00:00.000Z",
               "updated_by": "hub-old"}
        status, body = request("POST", h.url + "/v1/replicate", PEER_SECRET,
                               {"from_hub": "hub-old", "items": [self.rec()], "tokens": [tok]})
        self.assertEqual((status, body["applied"]), (200, 2))
        status, body = request("GET", h.url + "/v1/replicate/changes?after=0", PEER_SECRET)
        self.assertEqual(body["invites"], [])

    STEPS = [{"text": "Approve", "done": False, "link": {"label": "CI", "url": "https://ci/1"}},
             {"text": "Tell the team", "done": True}]

    def test_steps_round_trip(self):
        h = self.make_hub("hub-x", start=False)
        st = h.store
        self.assertTrue(st.apply_item(self.rec(steps=self.STEPS)))
        wire = hubmod.item_wire(st.get_item(self.rec()["id"]))
        self.assertEqual(wire["steps"], self.STEPS)
        # the wire record re-applies to another hub unchanged
        h2 = self.make_hub("hub-y", start=False)
        self.assertTrue(h2.store.apply_item(wire))
        self.assertEqual(hubmod.item_wire(h2.store.get_item(wire["id"])), wire)

    def test_old_peer_record_without_steps_keeps_them(self):
        """A hub older than `steps` stores items without them. Its later writes that don't
        touch content (resolve, seen_at, an unchanged re-post) must not wipe ours; a content
        change it made (new content_updated_at) is authoritative and has no steps."""
        h = self.make_hub("hub-x", start=False)
        st = h.store
        iid = self.rec()["id"]
        st.apply_item(self.rec(steps=self.STEPS))
        old = self.rec(status="resolved", updated_at="2026-10-06T10:00:01.000Z",
                       content_updated_at="2026-10-06T10:00:00.000Z", updated_by="hub-old")
        self.assertNotIn("steps", old)
        self.assertTrue(st.apply_item(old))
        row = st.get_item(iid)
        self.assertEqual(row["status"], "resolved")
        self.assertEqual(hubmod.item_wire(row)["steps"], self.STEPS)
        # content changed on the old hub: its version (no steps) wins
        changed = self.rec(title="new", updated_at="2026-10-06T10:00:02.000Z",
                           content_updated_at="2026-10-06T10:00:02.000Z", updated_by="hub-old")
        self.assertTrue(st.apply_item(changed))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["steps"], [])
        # an explicit empty list from a new hub clears them too
        st.apply_item(self.rec(steps=self.STEPS, updated_at="2026-10-06T10:00:03.000Z",
                               content_updated_at="2026-10-06T10:00:02.000Z"))
        st.apply_item(self.rec(steps=[], updated_at="2026-10-06T10:00:04.000Z",
                               content_updated_at="2026-10-06T10:00:02.000Z"))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["steps"], [])

    QUESTION = {"id": "toolu_1", "items": [{"header": "DB", "text": "Which?", "multi_select": False,
                                            "options": [{"label": "A", "description": "a"}]}]}

    def test_question_round_trip_and_old_peers(self):
        h = self.make_hub("hub-x", start=False)
        st = h.store
        iid = self.rec()["id"]
        self.assertTrue(st.apply_item(self.rec(question=self.QUESTION)))
        wire = hubmod.item_wire(st.get_item(iid))
        self.assertEqual(wire["question"], self.QUESTION)
        h2 = self.make_hub("hub-y", start=False)
        self.assertTrue(h2.store.apply_item(wire))
        self.assertEqual(hubmod.item_wire(h2.store.get_item(iid)), wire)
        # a hub older than `question`: its content-neutral write (a resolve) keeps ours
        old = self.rec(status="resolved", updated_at="2026-10-06T10:00:01.000Z",
                       content_updated_at="2026-10-06T10:00:00.000Z", updated_by="hub-old")
        self.assertNotIn("question", old)
        self.assertTrue(st.apply_item(old))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["question"], self.QUESTION)
        # its content change wins, and has none
        self.assertTrue(st.apply_item(self.rec(title="new", updated_at="2026-10-06T10:00:02.000Z",
                                               content_updated_at="2026-10-06T10:00:02.000Z",
                                               updated_by="hub-old")))
        self.assertIsNone(hubmod.item_wire(st.get_item(iid))["question"])

    def test_peer_question_this_hub_would_refuse_is_dropped(self):
        h = self.make_hub("hub-x", start=False)
        st = h.store
        bad = {"items": [{"text": "x" * 600}]}
        self.assertTrue(st.apply_item(self.rec(question=bad)))
        wire = hubmod.item_wire(st.get_item(self.rec()["id"]))
        self.assertIsNone(wire["question"])
        self.assertEqual(wire["title"], self.rec()["title"])

    def test_peer_step_links_are_checked(self):
        """Defence in depth, like item links: a peer's step link this hub would refuse is
        dropped (the step stays)."""
        h = self.make_hub("hub-x", start=False)
        st = h.store
        st.apply_item(self.rec(steps=[
            {"text": "ok", "done": False, "link": {"label": "a", "url": "https://a"}},
            {"text": "bad", "done": False, "link": {"label": "b", "url": "javascript:alert(1)"}},
            {"text": "odd", "done": False, "link": "https://not-an-object"},
            "not a step",
        ]))
        self.assertEqual(hubmod.item_wire(st.get_item(self.rec()["id"]))["steps"], [
            {"text": "ok", "done": False, "link": {"label": "a", "url": "https://a"}},
            {"text": "bad", "done": False},
            {"text": "odd", "done": False},
        ])

    def test_bad_steps_record_rejected(self):
        h = self.make_hub("hub-x", start=False)
        with self.assertRaises(hubmod.ApiError):
            h.store.apply_item(self.rec(steps="do it"))

    def test_replicate_to_self_is_refused(self):
        h = self.make_hub("hub-x")
        status, _ = request("POST", h.url + "/v1/replicate", PEER_SECRET,
                            {"from_hub": "hub-x", "items": []})
        self.assertEqual(status, 409)


class LateLoserWrite(HubTestCase):
    def test_a_loser_written_again_does_not_undo_a_repost_on_the_winner(self):
        # W wins a merge with L (fresher content). The sender re-posts the key with a new link
        # (same title: content_updated_at stays). Then L arrives again, its own hub's merge
        # result (resolved, superseded by W, a later updated_at): W must keep the new link.
        from support import FakeClock
        clock = FakeClock()
        hub = self.make_hub("hub-a", clock=clock)
        sender, reader = self.tokens(hub)
        s, w = request("POST", hub.url + "/v1/items", sender, {"key": "K", "title": "old title"})
        self.assertEqual(s, 201, w)
        clock.advance(1)
        ts = hubmod.fmt_ts(int(clock() * 1000))
        loser = {"id": hubmod.new_ulid(int(clock() * 1000)), "key": "K", "context": "work", "kind": "needs",
                 "priority": "normal", "title": "fresh title", "body": None, "links": [], "steps": [],
                 "source": {}, "status": "open", "created_at": ts, "updated_at": ts, "content_updated_at": ts,
                 "seen_at": None, "expires_at": None, "superseded_by": None, "token_id": None,
                 "origin_hub": "hub-b", "updated_by": "hub-b"}

        def push(rec):
            return request("POST", hub.url + "/v1/replicate", PEER_SECRET, {"from_hub": "hub-b", "items": [rec]})

        clock.advance(1)
        self.assertEqual(push(loser)[1]["applied"], 1)
        self.assertEqual(request("GET", hub.url + "/v1/items/" + w["id"], reader)[1]["title"], "fresh title")
        clock.advance(1)
        link = {"label": "PR", "url": "https://example.com/pr/1"}
        s, body = request("POST", hub.url + "/v1/items", sender, {"key": "K", "title": "fresh title",
                                                                  "links": [link]})
        self.assertEqual((s, body["id"]), (200, w["id"]), body)
        clock.advance(1)
        push(dict(loser, status="resolved", superseded_by=w["id"], updated_at=hubmod.fmt_ts(int(clock() * 1000))))
        got = request("GET", hub.url + "/v1/items/" + w["id"], reader)[1]
        self.assertEqual(got["links"], [link])
        self.assertEqual(got["title"], "fresh title")


if __name__ == "__main__":
    unittest.main()
