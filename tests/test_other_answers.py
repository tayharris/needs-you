"""Free-text answers ("Other", ADR 0009 amendment 2026-10-09): a question item's `allow_other`,
an answer's `text` (only where allowed, one line, bounded, kept as typed), read back by the
sender, and replicated (an older hub's shapes still work, a made-up text is dropped)."""
from __future__ import annotations

import unittest

from support import FakeClock, HubTestCase, hubmod, request

QUESTION = {"id": "toolu_02", "answerable": True, "items": [
    {"header": "Database", "text": "Which database?", "allow_other": True, "options": [
        {"label": "Postgres"}, {"label": "SQLite"}]},
    {"text": "Which extras?", "multi_select": True, "allow_other": True, "options": [
        {"label": "Metrics"}, {"label": "Tracing"}]},
    {"text": "Anything else?", "allow_other": True},
    {"text": "Ship it?", "options": [{"label": "Yes"}, {"label": "No"}]}]}


class OtherCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a", clock=FakeClock(), answer_rate_limit=100)
        self.sender, self.reader = self.tokens(self.hub)
        self.base = self.hub.url

    def ask(self, key="q", question=None):
        status, item = request("POST", self.base + "/v1/items", self.sender,
                               {"key": key, "title": "Claude asks", "question": question or QUESTION})
        self.assertIn(status, (200, 201), item)
        return item

    def answer(self, item, answers):
        body = {"question_id": item["question"].get("id"),
                "content_updated_at": item["content_updated_at"], "answers": answers}
        return request("POST", self.base + "/v1/items/%s/answer" % item["id"], self.reader, body)


class AllowOther(OtherCase):
    def test_normalised_only_when_true(self):
        item = self.ask()
        items = item["question"]["items"]
        self.assertEqual([it.get("allow_other") for it in items], [True, True, True, None])
        self.assertNotIn("allow_other", items[3])
        off = self.ask("off", {"items": [{"text": "Why?", "allow_other": False, "options": [{"label": "A"}]}]})
        self.assertNotIn("allow_other", off["question"]["items"][0])

    def test_a_free_text_question_is_answerable_only_with_allow_other(self):
        self.ask("free", {"answerable": True, "items": [{"text": "Name it?", "allow_other": True}]})
        status, err = request("POST", self.base + "/v1/items", self.sender, {
            "key": "bad", "title": "t", "question": {"answerable": True, "items": [{"text": "Name it?"}]}})
        self.assertEqual((status, err.get("field")), (400, "question.answerable"))
        status, err = request("POST", self.base + "/v1/items", self.sender, {
            "key": "bad", "title": "t", "question": {"items": [{"text": "Name it?", "allow_other": "yes"}]}})
        self.assertEqual((status, err.get("field")), (400, "question.items[0].allow_other"))

    def test_turning_it_on_is_a_content_change_and_clears_the_answer(self):
        q = {"id": "x", "answerable": True, "items": [{"text": "Which?", "options": [{"label": "A"}]}]}
        item = self.ask("c", q)
        self.assertEqual(self.answer(item, [{"selected": ["A"]}])[0], 200)
        q2 = {"id": "x", "answerable": True, "items": [{"text": "Which?", "allow_other": True, "options": [{"label": "A"}]}]}
        again = self.ask("c", q2)
        self.assertNotEqual(again["content_updated_at"], item["content_updated_at"])
        self.assertIsNone(again["answer"])


class TextAnswers(OtherCase):
    GOOD = [{"selected": [], "text": "  MySQL, the team knows it  "}, {"selected": ["Tracing"], "text": "Logs"},
            {"text": "Keep the old schema"}, {"selected": ["Yes"]}]

    def test_taken_kept_as_typed_and_read_back(self):
        item = self.ask()
        status, got = self.answer(item, self.GOOD)
        self.assertEqual(status, 200, got)
        want = [{"selected": [], "text": "MySQL, the team knows it"}, {"selected": ["Tracing"], "text": "Logs"},
                {"selected": [], "text": "Keep the old schema"}, {"selected": ["Yes"]}]
        self.assertEqual(got["answer"], want)
        status, read = request("GET", self.base + "/v1/items/answer?key=q&wait=0", self.sender)
        self.assertEqual((status, read["answers"], read["question_id"]), (200, want, "toolu_02"))

    def test_token_shaped_text_is_not_rewritten(self):
        # The person typed it for the agent: the hub never redacts an answer (nor logs it).
        item = self.ask()
        words = "use the key in ~/.aws, not sk-ant-0123456789abcdef0123456789"
        answers = [{"text": words}] + self.GOOD[1:]
        status, got = self.answer(item, answers)
        self.assertEqual((status, got["answer"][0]["text"]), (200, words))

    def test_a_needs_you_secret_is_refused(self):
        """Hard rule 3: needs-you's own tokens, invite codes and peer secrets never go into item
        text, an answer's included (it is stored, replicated and passed to the agent). Other
        token-shaped words still go as typed (the test above); the error doesn't echo it."""
        item = self.ask()
        for secret in ("ny_" + "A1b2C3d4e5F6g7H8i9J0k1L2m3N4o5P6", "nyi_AbCdEfGhIjKlMnOpQrStUvWx",
                       "nyp_" + "Zz9" * 14, "x%3Dny_" + "Q" * 30):
            status, err = self.answer(item, [{"text": "here: " + secret}] + self.GOOD[1:])
            self.assertEqual((status, err.get("error"), err.get("field")), (400, "secret_in_text", "answers[0].text"))
            self.assertNotIn(secret[-12:], str(err))
        self.assertEqual(self.answer(item, [{"text": "nyc_office, any_thing"}] + self.GOOD[1:])[0], 200)

    def test_refused(self):
        item = self.ask()
        rest = self.GOOD[1:]
        cases = [
            ([{"selected": ["Postgres"], "text": "and MySQL"}] + rest, "answers[0].selected"),  # one or the other
            ([{"selected": []}] + rest, "answers[0].selected"),
            ([{"selected": [], "text": "   "}] + rest, "answers[0].selected"),                  # blank is no text
            ([{"text": "x" * 1001}] + rest, "answers[0].text"),
            ([{"text": "two\nlines"}] + rest, "answers[0].text"),
            ([{"text": "a b"}] + rest, "answers[0].text"),
            ([{"text": "a‮b"}] + rest, "answers[0].text"),
            ([{"text": "a\x07b"}] + rest, "answers[0].text"),
            ([{"text": 5}] + rest, "answers[0].text"),
            ([{"selected": "Postgres"}] + rest, "answers[0]"),
            (self.GOOD[:2] + [{"selected": []}] + self.GOOD[3:], "answers[2].selected"),
            (self.GOOD[:3] + [{"selected": [], "text": "Maybe"}], "answers[3].text"),        # no allow_other
            (self.GOOD[:3] + [{"selected": ["Yes"], "text": "Maybe"}], "answers[3].text"),
        ]
        for answers, field in cases:
            status, err = self.answer(item, answers)
            self.assertEqual((status, err.get("field")), (400, field), answers)
            self.assertNotIn("sk-", str(err))
        self.assertEqual(self.answer(item, self.GOOD)[0], 200)  # none of those was taken

    def test_exactly_the_limit(self):
        item = self.ask()
        status, got = self.answer(item, [{"text": "é" * 1000}] + self.GOOD[1:])
        self.assertEqual(status, 200, got)

    def test_first_answer_wins(self):
        item = self.ask()
        self.assertEqual(self.answer(item, self.GOOD)[0], 200)
        status, err = self.answer(item, [{"text": "changed my mind"}] + self.GOOD[1:])
        self.assertEqual((status, err["error"]), (409, "already_answered"))


class Replication(HubTestCase):
    def rec(self, **kw):
        base = {"id": "01BBBBBBBBBBBBBBBBBBBBBBBB", "key": "k", "context": "work", "kind": "needs",
                "priority": "normal", "title": "t", "status": "open",
                "created_at": "2026-10-06T10:00:00.000Z", "updated_at": "2026-10-06T10:00:00.000Z",
                "content_updated_at": "2026-10-06T10:00:00.000Z", "updated_by": "hub-a",
                "question": QUESTION, "answered_at": "2026-10-06T10:00:01.000Z", "answered_by": "mac"}
        base.update(kw)
        return base

    def test_a_text_answer_round_trips(self):
        st = self.make_hub("hub-x", start=False).store
        good = TextAnswers.GOOD[1:]
        answer = [{"selected": [], "text": "MySQL"}] + good[:1] + [{"selected": [], "text": "Keep it"}] + good[2:]
        self.assertTrue(st.apply_item(self.rec(answer=answer, updated_at="2026-10-06T10:00:02.000Z")))
        wire = hubmod.item_wire(st.get_item(self.rec()["id"]))
        self.assertEqual(wire["answer"], answer)
        self.assertTrue(wire["question"]["items"][0]["allow_other"])
        st2 = self.make_hub("hub-y", start=False).store
        self.assertTrue(st2.apply_item(wire))
        self.assertEqual(hubmod.item_wire(st2.get_item(wire["id"])), wire)

    def test_made_up_text_is_dropped(self):
        st = self.make_hub("hub-x", start=False).store
        iid = self.rec()["id"]
        ok = [{"selected": ["Postgres"]}, {"selected": ["Metrics"]}, {"selected": [], "text": "x"}, {"selected": ["No"]}]
        bad = [
            ok[:3] + [{"selected": [], "text": "Maybe"}],                  # the question takes no text
            [{"selected": [], "text": "a\nb"}] + ok[1:],                    # not one line
            [{"selected": [], "text": "x" * 1001}] + ok[1:],
            [{"selected": [], "text": ""}] + ok[1:],
            [{"selected": [], "text": 7}] + ok[1:],
        ]
        for n, answer in enumerate(bad):
            st.apply_item(self.rec(answer=answer, updated_at="2026-10-06T10:00:0%d.000Z" % (n + 2)))
            self.assertIsNone(hubmod.item_wire(st.get_item(iid))["answer"], answer)
        st.apply_item(self.rec(answer=ok, updated_at="2026-10-06T10:00:09.000Z"))
        self.assertEqual(hubmod.item_wire(st.get_item(iid))["answer"], ok)

    def test_an_older_hubs_question_without_allow_other_takes_no_text(self):
        st = self.make_hub("hub-x", start=False).store
        old_q = {"id": "o", "answerable": True, "items": [{"text": "Which?", "options": [{"label": "A"}]}]}
        st.apply_item(self.rec(question=old_q, answer=[{"selected": [], "text": "B"}],
                               updated_at="2026-10-06T10:00:02.000Z"))
        wire = hubmod.item_wire(st.get_item(self.rec()["id"]))
        self.assertIsNotNone(wire["question"])
        self.assertIsNone(wire["answer"])


if __name__ == "__main__":
    unittest.main()
