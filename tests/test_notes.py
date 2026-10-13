"""Notes (ADR 0014, docs/API.md "Notes"): one markdown document beside the alerts."""
from __future__ import annotations

import json
import sqlite3
import time
import urllib.error
import urllib.request

from support import OPENER, PEER_SECRET, HubTestCase, hubmod, request, wait_until


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


class AppendLine(HubTestCase):
    def test_a_new_section_goes_at_the_end(self):
        self.assertEqual(hubmod.notes_append_line("", "a", "Inbox"), "## Inbox\n- [ ] a\n")
        self.assertEqual(hubmod.notes_append_line("# Mine\n- [x] b\n\n", "a", "Today"),
                         "# Mine\n- [x] b\n\n## Today\n- [ ] a\n")

    def test_the_line_goes_last_in_its_section(self):
        doc = "## Today\n- [ ] one\n\n## inbox\n- [ ] two\n\n## Later\n- x\n"
        self.assertEqual(hubmod.notes_append_line(doc, "three", "Inbox"),
                         "## Today\n- [ ] one\n\n## inbox\n- [ ] two\n- [ ] three\n\n## Later\n- x\n")
        self.assertEqual(hubmod.notes_append_line(doc, "plain", "Later", check=False),
                         "## Today\n- [ ] one\n\n## inbox\n- [ ] two\n\n## Later\n- x\n- plain\n")

    def test_a_subheading_stays_in_the_section(self):
        doc = "## Today\n### Morning\n- [ ] a\n## Later\n"
        self.assertEqual(hubmod.notes_append_line(doc, "b", "Today"),
                         "## Today\n### Morning\n- [ ] a\n- [ ] b\n## Later\n")

    def test_headings_in_code_fences_are_text(self):
        doc = "```\n## Inbox\n```\n"
        self.assertEqual(hubmod.notes_append_line(doc, "a", "Inbox"), "```\n## Inbox\n```\n\n## Inbox\n- [ ] a\n")


class Validation(HubTestCase):
    def test_text(self):
        self.assertEqual(hubmod.validate_notes_text("a\r\nb\tc"), "a\nb\tc")
        for bad in ("x" * (hubmod.MAX_NOTES_TEXT + 1), "a\x00b", "evil‮name", "a b", 3):
            with self.assertRaises(hubmod.ApiError) as cm:
                hubmod.validate_notes_text(bad)
            self.assertEqual(cm.exception.code, "invalid")
        for secret in ("ny_" + "a" * 20, "token ghp_" + "b" * 20, "sk-" + "c" * 20):
            with self.assertRaises(hubmod.ApiError) as cm:
                hubmod.validate_notes_text("- [ ] " + secret)
            self.assertEqual(cm.exception.code, "secret_in_text")

    def test_append(self):
        out = hubmod.validate_notes_append({"text": "  check it  "})
        self.assertEqual(out, {"text": "check it", "section": "Inbox", "check": True})
        for body, field in (({}, "text"), ({"text": "a\nb"}, "text"), ({"text": "x" * 301}, "text"),
                            ({"text": "a", "section": "## x"}, "section"), ({"text": "a", "section": ""}, "section"),
                            ({"text": "a", "check": "yes"}, "check")):
            with self.assertRaises(hubmod.ApiError) as cm:
                hubmod.validate_notes_append(body)
            self.assertEqual(cm.exception.field, field, body)


class NotesApi(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        self.base = self.hub.url

    def notes(self):
        status, body = request("GET", self.base + "/v1/notes", self.reader)
        self.assertEqual(status, 200, body)
        return body

    def test_empty_then_append_then_put(self):
        self.assertEqual(self.notes(), {"id": "nt_main", "text": "", "rev": "", "created_at": None,
                                        "updated_at": None})
        status, body = request("POST", self.base + "/v1/notes/append", self.sender, {"text": "a"})
        self.assertEqual(status, 200, body)
        self.assertEqual(set(body), {"ok", "rev"}, "a sender never gets the text back")
        cur = self.notes()
        self.assertEqual((cur["text"], cur["rev"]), ("## Inbox\n- [ ] a\n", body["rev"]))
        status, body = request("PUT", self.base + "/v1/notes", self.reader,
                               {"text": "## Inbox\n- [x] a\n", "base_rev": cur["rev"]})
        self.assertEqual(status, 200, body)
        self.assertNotEqual(body["rev"], cur["rev"])
        self.assertEqual(self.notes()["text"], "## Inbox\n- [x] a\n")

    def test_a_stale_base_rev_is_a_conflict(self):
        request("POST", self.base + "/v1/notes/append", self.sender, {"text": "a"})
        status, body = request("PUT", self.base + "/v1/notes", self.reader, {"text": "x", "base_rev": ""})
        self.assertEqual((status, body["error"]), (409, "conflict"))
        status, body = request("PUT", self.base + "/v1/notes", self.reader, {"text": "x"})
        self.assertEqual((status, body.get("field")), (400, "base_rev"))
        self.assertEqual(self.notes()["text"], "## Inbox\n- [ ] a\n")

    def test_an_unchanged_put_keeps_the_rev(self):
        rev = request("PUT", self.base + "/v1/notes", self.reader, {"text": "x", "base_rev": ""})[1]["rev"]
        status, body = request("PUT", self.base + "/v1/notes", self.reader, {"text": "x", "base_rev": rev})
        self.assertEqual((status, body["rev"]), (200, rev))

    def test_roles(self):
        self.assertEqual(request("GET", self.base + "/v1/notes", self.sender)[0], 403)
        self.assertEqual(request("PUT", self.base + "/v1/notes", self.sender, {"text": "x", "base_rev": ""})[0], 403)
        self.assertEqual(request("GET", self.base + "/v1/notes")[0], 401)
        self.assertEqual(request("POST", self.base + "/v1/notes/append", self.reader, {"text": "mine"})[0], 200)

    def test_etag(self):
        status, body, headers = get_with_headers(self.base + "/v1/notes", self.reader)
        self.assertEqual(headers["ETag"], '"none"')
        status, _, _ = get_with_headers(self.base + "/v1/notes", self.reader, etag='"none"')
        self.assertEqual(status, 304)
        request("POST", self.base + "/v1/notes/append", self.sender, {"text": "a"})
        status, body, headers = get_with_headers(self.base + "/v1/notes", self.reader, etag='"none"')
        self.assertEqual((status, headers["ETag"]), (200, '"%s"' % body["rev"]))

    def test_full_notes_refuse_an_append(self):
        rev = request("PUT", self.base + "/v1/notes", self.reader,
                      {"text": "x" * (hubmod.MAX_NOTES_TEXT - 5), "base_rev": ""})[1]["rev"]
        status, body = request("POST", self.base + "/v1/notes/append", self.sender, {"text": "one more"})
        self.assertEqual((status, body["error"]), (400, "notes_full"))
        self.assertEqual(self.notes()["rev"], rev)


class NotesReplication(HubTestCase):
    def test_writes_replicate_both_ways(self):
        a, b = self.make_hub("hub-a", start=False), self.make_hub("hub-b", start=False)
        a.set_peers([b.url])
        b.set_peers([a.url])
        a.start()
        b.start()
        sender, reader = self.tokens(a)
        self.assertTrue(wait_until(lambda: b.store.token_by_secret(reader) is not None))
        request("POST", a.url + "/v1/notes/append", sender, {"text": "from a"})
        self.assertTrue(wait_until(lambda: (b.store.get_notes() or {}).get("text") == "## Inbox\n- [ ] from a\n"))
        rev = request("GET", b.url + "/v1/notes", reader)[1]["rev"]
        self.assertEqual(request("PUT", b.url + "/v1/notes", reader, {"text": "edited on b", "base_rev": rev})[0], 200)
        self.assertTrue(wait_until(lambda: (a.store.get_notes() or {}).get("text") == "edited on b"))
        self.assertEqual(request("GET", a.url + "/v1/notes", reader)[1]["rev"],
                         request("GET", b.url + "/v1/notes", reader)[1]["rev"], "the same rev on every hub")

    def test_pull_brings_notes(self):
        a = self.make_hub("hub-a")
        _sender, reader = self.tokens(a)
        request("PUT", a.url + "/v1/notes", reader, {"text": "hello", "base_rev": ""})
        b = self.make_hub("hub-b", start=False)
        b.set_peers([a.url])
        b.start()
        self.assertTrue(wait_until(lambda: (b.store.get_notes() or {}).get("text") == "hello"))

    def test_unreadable_and_older_records_are_skipped(self):
        a = self.make_hub("hub-a")
        now = time.time()
        good = {"id": "nt_main", "text": "good", "created_at": now, "updated_at": now, "updated_by": "hub-z"}
        later_list = dict(good, id="nt_second")
        secret = dict(good, text="ny_" + "s" * 20, updated_at=now + 5)
        status, body = request("POST", a.url + "/v1/replicate", PEER_SECRET,
                               {"from_hub": "hub-z", "items": [], "notes": [later_list, good, secret]})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["applied"], 1)
        self.assertEqual(len(body["skipped"]), 2)
        self.assertEqual(a.store.get_notes()["text"], "good")
        request("POST", a.url + "/v1/replicate", PEER_SECRET,
                {"from_hub": "hub-z", "notes": [dict(good, text="old", updated_at=now - 60)]})
        self.assertEqual(a.store.get_notes()["text"], "good")
        status, body = request("POST", a.url + "/v1/replicate", PEER_SECRET, {"from_hub": "hub-z", "notes": {}})
        self.assertEqual((status, body.get("field")), (400, "notes"))


class Migration(HubTestCase):
    def test_a_schema_11_database_gains_the_notes_table(self):
        path = self.tmp + "/old.db"
        conn = sqlite3.connect(path)
        for mig in hubmod.MIGRATIONS[:11]:
            conn.executescript(mig)
        conn.execute("PRAGMA user_version = 11")
        conn.commit()
        conn.close()
        store = hubmod.Store(path, "hub-a", [])
        try:
            self.assertEqual(store.conn.execute("PRAGMA user_version").fetchone()[0], hubmod.SCHEMA_VERSION)
            self.assertIsNone(store.get_notes())
        finally:
            store.close()


if __name__ == "__main__":
    import unittest
    unittest.main()
