"""The format catalog (tests/format_cases.py) against a real hub and the CLI: every shape a
sender can produce is taken as given, every refused one names its field, re-posts update in
place, and each CLI flag lands in the item field it promises. mac/scripts/format-fixtures.py
draws the same catalog on cards (mac/scripts/screenshots.sh)."""
from __future__ import annotations

import os
import sys
import unittest

from support import request
from test_cli import CliTestCase

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import format_cases  # noqa: E402


def key(name):
    return "fmt:%02d-%s" % ([n for n, _ in format_cases.ACCEPTED].index(name) + 1, name)


class FormatCases(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def post(self, body):
        return request("POST", self.hub.url + "/v1/items", self.sender, body)

    def test_accepted_round_trip(self):
        names = [n for n, _ in format_cases.ACCEPTED]
        self.assertEqual(len(names), len(set(names)))
        for name, item in format_cases.ACCEPTED:
            with self.subTest(name):
                status, out = self.post(dict(item, key=key(name)))
                self.assertEqual(status, 201, out)
                for field in ("title", "context", "kind", "priority"):
                    if field in item:
                        self.assertEqual(out[field], item[field].strip())
                if "body" in item:
                    self.assertEqual(out["body"], item["body"])
                self.assertEqual(len(out["links"]), len(item.get("links", [])))
                self.assertEqual([s["text"] for s in out["steps"]], [s["text"] for s in item.get("steps", [])])
                if "question" in item:
                    q = item["question"]
                    self.assertEqual(out["question"]["answerable"], bool(q.get("answerable")))
                    self.assertEqual([[o["label"] for o in i["options"]] for i in out["question"]["items"]],
                                     [[o["label"] for o in i.get("options", [])] for i in q["items"]])

    def test_reposts_update_in_place(self):
        accepted = dict(format_cases.ACCEPTED)
        for name, item, changed in format_cases.REPOSTS:
            with self.subTest(name):
                first = self.post(dict(accepted[name], key=key(name)))[1]
                status, out = self.post(dict(item, key=key(name)))
                self.assertEqual(status, 200, out)
                self.assertEqual(out["id"], first["id"])
                self.assertEqual(out["changed"], changed)
                self.assertEqual(out["title"], item["title"])

    def test_refused_name_their_field(self):
        for name, item, field in format_cases.REFUSED:
            with self.subTest(name):
                status, out = self.post(dict(item, key="fmt:refused:" + name) if name != "key-space" else item)
                self.assertEqual(status, 400, out)
                self.assertEqual(out.get("field"), field, out)

    def test_cli_flags_produce_fields(self):
        for argv, expect in format_cases.CLI:
            with self.subTest(argv[2]):
                r = self.run_cli(*argv, urls=[self.hub.url], token=self.sender)
                self.assertEqual(r.returncode, 0, r.stderr)
                items = {i["key"]: i for i in self.items(self.hub, self.reader)}
                got = items[argv[2]]
                for field, value in expect.items():
                    self.assertEqual(got[field], value, field)


if __name__ == "__main__":
    unittest.main()
