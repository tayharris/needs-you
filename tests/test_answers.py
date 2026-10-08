"""Answers to an item's question (ADR 0009 B2): the `answerable`/`expires_at` question fields,
POST /v1/items/{id}/answer (reader; the 409 rules, offered labels only, first answer wins, the
rate limit), GET /v1/items/answer (the posting token only, long poll, 204), re-posts, and
replication of the answer."""
from __future__ import annotations

import threading
import time
import unittest
import urllib.parse

from support import FakeClock, HubTestCase, hubmod, request, wait_until

QUESTION = {"id": "toolu_01", "answerable": True, "items": [
    {"header": "Database", "text": "Which database?", "options": [
        {"label": "Postgres", "description": "Durable"}, {"label": "SQLite"}]},
    {"text": "Which extras?", "multi_select": True, "options": [
        {"label": "Metrics"}, {"label": "Tracing"}]}]}
GOOD = [{"selected": ["Postgres"]}, {"selected": ["Tracing", "Metrics"]}]


class AnswerCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.clock = FakeClock()
        self.hub = self.make_hub("hub-a", clock=self.clock, answer_rate_limit=30)
        self.sender, self.reader = self.tokens(self.hub)
        self.base = self.hub.url

    def post(self, body, token=None):
        return request("POST", self.base + "/v1/items", token or self.sender, body)

    def ask(self, key="q", question=None, **extra):
        body = {"key": key, "title": "Claude asks", "question": question or QUESTION}
        body.update(extra)
        status, item = self.post(body)
        self.assertIn(status, (200, 201), item)
        return item

    def answer(self, item, answers=GOOD, token=None, **over):
        body = {"question_id": (item.get("question") or {}).get("id"),
                "content_updated_at": item["content_updated_at"], "answers": answers}
        body.update(over)
        return request("POST", self.base + "/v1/items/%s/answer" % item["id"], token or self.reader, body)

    def read(self, key="q", wait=0, token=None, timeout=5.0):
        qs = urllib.parse.urlencode({"key": key, "wait": wait})
        return request("GET", self.base + "/v1/items/answer?" + qs, token or self.sender, timeout=timeout)


class QuestionFields(AnswerCase):
    def test_answerable_and_expiry_are_normalised(self):
        item = self.ask(question=dict(QUESTION, expires_at="2026-10-08T17:04:05Z"))
        self.assertTrue(item["question"]["answerable"])
        self.assertEqual(item["question"]["expires_at"], "2026-10-08T17:04:05.000Z")
        self.assertIsNone(item["answer"])
        self.assertIsNone(item["answered_at"])
        self.assertIsNone(item["answered_by"])
        plain = self.ask("q2", question={"items": [{"text": "Why?"}]})
        self.assertFalse(plain["question"]["answerable"])
        self.assertNotIn("expires_at", plain["question"])

    def test_bad_fields(self):
        cases = [
            ({"answerable": "yes"}, "question.answerable"),
            ({"expires_at": "soon"}, "question.expires_at"),
            # only offered labels can be answered: every item needs options
            ({"items": [{"text": "Name it?"}]}, "question.answerable"),
        ]
        for extra, field in cases:
            q = dict(QUESTION, **extra)
            status, err = self.post({"key": "bad", "title": "t", "question": q})
            self.assertEqual((status, err.get("field")), (400, field), extra)


class PostAnswer(AnswerCase):
    def test_first_answer_wins_and_the_item_stays_open(self):
        item = self.ask()
        status, got = self.answer(item)
        self.assertEqual(status, 200, got)
        self.assertEqual(got["answer"], [{"selected": ["Postgres"]}, {"selected": ["Tracing", "Metrics"]}])
        self.assertEqual(got["answered_by"], "reader-hub-a-1")
        self.assertIsNotNone(got["answered_at"])
        self.assertEqual(got["status"], "open")
        self.assertEqual(got["content_updated_at"], item["content_updated_at"])
        self.assertGreater(got["updated_at"], item["updated_at"])
        status, err = self.answer(item, [{"selected": ["SQLite"]}, {"selected": ["Metrics"]}])
        self.assertEqual((status, err["error"]), (409, "already_answered"))

    def test_only_readers_and_owners(self):
        item = self.ask()
        status, _ = self.answer(item, token=self.sender)
        self.assertEqual(status, 403)
        owner, _ = self.hub.store.add_token("owner-mac", "owner")
        status, got = self.answer(item, token=owner)
        self.assertEqual((status, got["answered_by"]), (200, "owner-mac"))

    def test_conflicts(self):
        item = self.ask()
        self.assertEqual(request("POST", self.base + "/v1/items/01NOPE/answer", self.reader,
                                 {"content_updated_at": item["content_updated_at"], "answers": GOOD})[0], 404)
        status, err = self.answer(item, question_id="toolu_other")
        self.assertEqual((status, err["error"]), (409, "question_changed"))
        status, err = self.answer(item, content_updated_at="2026-01-01T00:00:00Z")
        self.assertEqual((status, err["error"]), (409, "question_changed"))
        plain = self.ask("plain", question={"items": [{"text": "Ok?", "options": [{"label": "Yes"}]}]})
        status, err = self.answer(plain, [{"selected": ["Yes"]}])
        self.assertEqual((status, err["error"]), (409, "not_answerable"))
        none = self.ask("none", question={"items": [{"text": "Ok?"}]})
        status, _ = self.post({"key": "none", "title": "no question now"})
        status, err = self.answer(dict(none, question=None), [])
        self.assertEqual((status, err["error"]), (409, "not_answerable"))
        expiring = self.ask("exp", question=dict(QUESTION, expires_at=(self.clock() + 60)))
        self.clock.advance(61)
        status, err = self.answer(expiring)
        self.assertEqual((status, err["error"]), (409, "question_expired"))
        closed = self.ask("closed")
        request("POST", self.base + "/v1/items/resolve", self.sender, {"key": "closed"})
        status, err = self.answer(closed)
        self.assertEqual((status, err["error"]), (409, "not_open"))

    def test_only_offered_labels(self):
        item = self.ask()
        cases = [
            ([{"selected": ["Postgres"]}], "answers"),                                   # one per question
            ([{"selected": ["MySQL"]}, {"selected": ["Metrics"]}], "answers[0].selected[0]"),
            ([{"selected": ["postgres"]}, {"selected": ["Metrics"]}], "answers[0].selected[0]"),
            ([{"selected": ["Postgres", "SQLite"]}, {"selected": ["Metrics"]}], "answers[0].selected"),
            ([{"selected": ["Postgres"]}, {"selected": []}], "answers[1].selected"),
            ([{"selected": ["Postgres"]}, {"selected": ["Metrics", "Metrics"]}], "answers[1].selected[1]"),
            ([{"selected": ["Postgres"]}, {"selected": [3]}], "answers[1].selected[0]"),
            ([{"selected": ["Postgres"]}, "Metrics"], "answers[1]"),
            ("Postgres", "answers"),
        ]
        for answers, field in cases:
            status, err = self.answer(item, answers)
            self.assertEqual((status, err.get("field")), (400, field), answers)
        self.assertEqual(self.answer(item)[0], 200)  # none of those was taken

    def test_bad_request_fields(self):
        item = self.ask()
        self.assertEqual(self.answer(item, question_id=5)[1].get("field"), "question_id")
        self.assertEqual(self.answer(item, content_updated_at=None)[1].get("field"), "content_updated_at")

    def test_a_changed_question_clears_the_answer_an_unchanged_one_keeps_it(self):
        item = self.ask()
        self.assertEqual(self.answer(item)[0], 200)
        self.clock.advance(5)
        same = self.ask()
        self.assertFalse(same["changed"])
        self.assertIsNotNone(same["answer"])
        self.clock.advance(5)
        q2 = dict(QUESTION, id="toolu_02")
        new = self.ask(question=q2)
        self.assertTrue(new["changed"])
        self.assertIsNone(new["answer"])
        self.assertIsNone(new["answered_by"])
        self.assertEqual(self.answer(new)[0], 200)

    def test_rate_limited_per_token(self):
        hub = self.make_hub("hub-r", answer_rate_limit=3)
        sender, reader = self.tokens(hub)
        _, item = request("POST", hub.url + "/v1/items", sender, {"key": "q", "title": "t", "question": QUESTION})
        url = hub.url + "/v1/items/%s/answer" % item["id"]
        bad = {"question_id": "toolu_01", "content_updated_at": item["content_updated_at"], "answers": []}
        for _ in range(3):
            self.assertEqual(request("POST", url, reader, bad)[0], 400)
        status, err = request("POST", url, reader, bad)
        self.assertEqual((status, err["error"]), (429, "rate_limited"))
        other, _ = hub.store.add_token("reader-two", "reader")
        self.assertEqual(request("POST", url, other, dict(bad, answers=GOOD))[0], 200)


class ReadAnswer(AnswerCase):
    def test_no_answer_yet_then_the_answer(self):
        item = self.ask()
        status, _ = self.read()
        self.assertEqual(status, 204)
        self.answer(item)
        status, got = self.read()
        self.assertEqual(status, 200)
        self.assertEqual(got, {"id": item["id"], "key": "q", "status": "open", "question_id": "toolu_01",
                               "answers": GOOD[:1] + [{"selected": ["Tracing", "Metrics"]}],
                               "answered_at": got["answered_at"], "answered_by": "reader-hub-a-1"})
        # still there after the sender resolved it
        request("POST", self.base + "/v1/items/resolve", self.sender, {"key": "q"})
        status, got = self.read()
        self.assertEqual((status, got["status"]), (200, "resolved"))

    def test_only_the_posting_token(self):
        self.ask()
        other, _ = self.hub.store.add_token("sender-two", "sender")
        self.assertEqual(self.read(token=other)[0], 404)
        self.assertEqual(self.read(token=self.reader)[0], 403)
        self.assertEqual(self.read(key="nope")[0], 404)
        status, err = request("GET", self.base + "/v1/items/answer", self.sender)
        self.assertEqual((status, err.get("field")), (400, "key"))
        status, err = request("GET", self.base + "/v1/items/answer?key=q&wait=x", self.sender)
        self.assertEqual((status, err.get("field")), (400, "wait"))

    def test_no_answer_will_come(self):
        self.ask("plain", question={"items": [{"text": "Ok?", "options": [{"label": "Yes"}]}]})
        self.assertEqual(self.read("plain")[1]["error"], "not_answerable")
        self.ask("exp", question=dict(QUESTION, expires_at=self.clock() + 10))
        self.clock.advance(11)
        self.assertEqual(self.read("exp")[1]["error"], "question_expired")
        self.ask("closed")
        request("POST", self.base + "/v1/items/resolve", self.sender, {"key": "closed"})
        self.assertEqual(self.read("closed")[1]["error"], "not_open")

    def test_long_poll_wakes_on_the_answer(self):
        item = self.ask()
        result = {}

        def wait():
            started = time.time()
            result["status"], result["body"] = self.read(wait=10, timeout=15)
            result["took"] = time.time() - started

        t = threading.Thread(target=wait)
        t.start()
        time.sleep(0.5)
        self.answer(item)
        t.join(15)
        self.assertEqual(result["status"], 200)
        self.assertEqual(result["body"]["answers"][0], {"selected": ["Postgres"]})
        self.assertLess(result["took"], 5)

    def test_long_poll_gives_up_with_204(self):
        self.ask()
        started = time.time()
        status, _ = self.read(wait=1)
        self.assertEqual(status, 204)
        self.assertGreaterEqual(time.time() - started, 0.9)


class AnswerSecurity(AnswerCase):
    """Only the token that posted the question reads its answer, whoever re-posts the key."""

    def test_another_sender_reposting_the_key_never_reads_the_answer(self):
        item = self.ask()
        self.assertEqual(self.answer(item)[0], 200)
        other, _ = self.hub.store.add_token("sender-other", "sender")
        self.clock.advance(1)
        status, again = self.post({"key": "q", "title": "Claude asks", "question": QUESTION}, token=other)
        self.assertEqual(status, 200)
        self.assertFalse(again["changed"])
        # the answer was the first sender's: it is gone, not handed to the re-poster
        self.assertIsNone(again["answer"])
        status, got = self.read(token=other)
        self.assertNotEqual(status, 200, got)
        self.assertNotIn("answers", got)
        # and the first sender no longer owns the item: the same answer as "no such item"
        status, err = self.read()
        self.assertEqual(status, 404)
        self.assertEqual(err, self.read(key="never-posted")[1])

    def test_a_repost_by_the_same_sender_keeps_the_answer(self):
        item = self.ask()
        self.answer(item)
        self.clock.advance(1)
        self.assertIsNotNone(self.ask()["answer"])
        self.assertEqual(self.read()[0], 200)

    def test_long_polls_per_token_are_capped(self):
        hub = self.make_hub("hub-c", answer_waits_per_token=1)
        sender, _ = self.tokens(hub)
        request("POST", hub.url + "/v1/items", sender, {"key": "q", "title": "t", "question": QUESTION})
        url = hub.url + "/v1/items/answer?key=q&wait=3"
        first = {}
        t = threading.Thread(target=lambda: first.update(r=request("GET", url, sender, timeout=10)))
        t.start()
        time.sleep(0.5)
        started = time.time()
        status, err = request("GET", url, sender, timeout=10)
        self.assertEqual((status, err.get("error")), (429, "rate_limited"))
        self.assertLess(time.time() - started, 1.5)  # refused at once, not held
        t.join(10)
        self.assertEqual(first["r"][0], 204)

    def test_reads_are_rate_limited(self):
        hub = self.make_hub("hub-r2", answer_read_rate_limit=3)
        sender, _ = self.tokens(hub)
        url = hub.url + "/v1/items/answer?key=q&wait=0"
        for _ in range(3):
            self.assertEqual(request("GET", url, sender)[0], 404)
        status, err = request("GET", url, sender)
        self.assertEqual((status, err["error"]), (429, "rate_limited"))


class PeerAnswers(HubTestCase):
    def rec(self, **kw):
        base = {"id": "01AAAAAAAAAAAAAAAAAAAAAAAA", "key": "k", "context": "work", "kind": "needs",
                "priority": "normal", "title": "t", "status": "open",
                "created_at": "2026-10-06T10:00:00.000Z", "updated_at": "2026-10-06T10:00:01.000Z",
                "content_updated_at": "2026-10-06T10:00:00.000Z", "updated_by": "hub-a",
                "question": QUESTION, "answered_at": "2026-10-06T10:00:01.000Z", "answered_by": "mac"}
        base.update(kw)
        return base

    def test_a_peer_answer_must_fit_the_question(self):
        st = self.make_hub("hub-x", start=False).store
        iid = self.rec()["id"]
        made_up = [
            [{"selected": ["MySQL"]}, {"selected": ["Metrics"]}],          # not an offered label
            [{"selected": ["Postgres", "SQLite"]}, {"selected": ["Metrics"]}],  # two for single choice
            [{"selected": ["Postgres"]}],                                   # one question short
        ]
        for n, bad in enumerate(made_up):
            st.apply_item(self.rec(answer=bad, updated_at="2026-10-06T10:00:0%d.000Z" % (n + 2)))
            wire = hubmod.item_wire(st.get_item(iid))
            self.assertIsNone(wire["answer"], bad)
            self.assertIsNone(wire["answered_by"], bad)
        # an answer to a question nobody can answer
        plain = dict(QUESTION, answerable=False)
        st.apply_item(self.rec(question=plain, answer=GOOD, updated_at="2026-10-06T10:00:09.000Z"))
        self.assertIsNone(hubmod.item_wire(st.get_item(iid))["answer"])
        # a good one is kept
        st.apply_item(self.rec(answer=GOOD, updated_at="2026-10-06T10:00:10.000Z"))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["answer"], GOOD)


class Replication(HubTestCase):
    def rec(self, **kw):
        base = {"id": "01AAAAAAAAAAAAAAAAAAAAAAAA", "key": "k", "context": "work", "kind": "needs",
                "priority": "normal", "title": "t", "status": "open",
                "created_at": "2026-10-06T10:00:00.000Z", "updated_at": "2026-10-06T10:00:00.000Z",
                "content_updated_at": "2026-10-06T10:00:00.000Z", "updated_by": "hub-a",
                "question": QUESTION}
        base.update(kw)
        return base

    def test_answer_round_trip_and_old_peers(self):
        st = self.make_hub("hub-x", start=False).store
        iid = self.rec()["id"]
        answered = self.rec(answer=GOOD, answered_at="2026-10-06T10:00:05.000Z", answered_by="mac",
                            updated_at="2026-10-06T10:00:05.000Z")
        self.assertTrue(st.apply_item(answered))
        wire = hubmod.item_wire(st.get_item(iid))
        self.assertEqual((wire["answer"], wire["answered_at"], wire["answered_by"]),
                         (GOOD, "2026-10-06T10:00:05.000Z", "mac"))
        st2 = self.make_hub("hub-y", start=False).store
        self.assertTrue(st2.apply_item(wire))
        self.assertEqual(hubmod.item_wire(st2.get_item(iid)), wire)
        # a hub older than answers: its resolve (same content) keeps the answer
        old = self.rec(status="resolved", updated_at="2026-10-06T10:00:06.000Z", updated_by="hub-old")
        self.assertTrue(st.apply_item(old))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["answer"], GOOD)

    def test_unreadable_answers_are_dropped(self):
        st = self.make_hub("hub-x", start=False).store
        iid = self.rec()["id"]
        for bad in ("Postgres", [{"selected": []}], [{"selected": ["x" * 81]}], [{"selected": ["a‮b"]}],
                    [{"selected": ["a"]}] * 5):
            st.apply_item(self.rec(answer=bad, answered_by="mac", updated_at="2026-10-06T10:00:0%d.000Z"
                                   % (len(str(bad)) % 10)))
            self.assertIsNone(hubmod.item_wire(st.get_item(iid))["answer"], bad)
        # no question, no answer
        st.apply_item(self.rec(question=None, answer=GOOD, updated_at="2026-10-06T10:01:00.000Z"))
        self.assertIsNone(hubmod.item_wire(st.get_item(iid))["answer"])

    def test_answer_replicates_between_hubs(self):
        a = self.make_hub("hub-a", start=False)
        b = self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        b.set_peers([a.url])
        a.start()
        b.start()
        sender, reader = self.tokens(a)
        _, item = request("POST", a.url + "/v1/items", sender, {"key": "q", "title": "t", "question": QUESTION})
        body = {"question_id": "toolu_01", "content_updated_at": item["content_updated_at"], "answers": GOOD}
        self.assertEqual(request("POST", a.url + "/v1/items/%s/answer" % item["id"], reader, body)[0], 200)
        def answered_on_b():
            got = b.store.get_item(item["id"])
            return got is not None and got.get("answer") is not None
        self.assertTrue(wait_until(answered_on_b, 10))


if __name__ == "__main__":
    unittest.main()
