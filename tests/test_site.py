"""site/: the static landing page. Offline checks only (stdlib html.parser).

Structure (balanced tags, one h1, title, description), in-page anchors, local files,
and every link into this repo on GitHub points at a path that exists here.
"""
from __future__ import annotations

import os
import re
import unittest
from html.parser import HTMLParser

from support import ROOT

SITE = os.path.join(ROOT, "site")
REPO_LINK = re.compile(r"^https://github\.com/tayharris/needs-you/(?:blob|tree)/main/(.+?)/?(?:#.*)?$")
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "source", "track", "wbr", "path", "circle", "rect", "line", "polyline", "polygon",
        "ellipse", "use", "stop"}
# Elements whose end tag the HTML spec lets you leave out.
OPTIONAL_END = {"p", "li", "dt", "dd", "tr", "td", "th", "option", "thead", "tbody"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.errors = []
        self.ids = set()
        self.links = []
        self.tags = []
        self.meta = {}
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append(tag)
        if a.get("id"):
            if a["id"] in self.ids:
                self.errors.append("duplicate id %r" % a["id"])
            self.ids.add(a["id"])
        for k in ("href", "src"):
            if a.get(k):
                self.links.append(a[k])
        if tag == "meta" and a.get("name"):
            self.meta[a["name"]] = a.get("content", "")
        if tag == "title":
            self._in_title = True
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag in VOID:
            return
        while self.stack and self.stack[-1][0] != tag and self.stack[-1][0] in OPTIONAL_END:
            self.stack.pop()
        if not self.stack or self.stack[-1][0] != tag:
            self.errors.append("unexpected </%s> at line %d" % (tag, self.getpos()[0]))
            return
        self.stack.pop()

    def handle_data(self, data):
        if self._in_title:
            self.title += data


class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pages = {}
        for name in sorted(os.listdir(SITE)):
            if name.endswith(".html"):
                p = Page()
                with open(os.path.join(SITE, name), encoding="utf-8") as fh:
                    p.feed(fh.read())
                p.close()
                cls.pages[name] = p

    def test_has_an_index(self):
        self.assertIn("index.html", self.pages)

    def test_structure(self):
        for name, p in self.pages.items():
            with self.subTest(page=name):
                self.assertEqual(p.errors, [])
                leftover = [t for t, _ in p.stack if t not in OPTIONAL_END]
                self.assertEqual(leftover, [], "unclosed tags")
                self.assertEqual(p.tags.count("h1"), 1)
                self.assertTrue(p.title.strip())
                self.assertTrue(p.meta.get("description"))
                self.assertIn("viewport", p.meta)

    def test_links(self):
        for name, p in self.pages.items():
            for link in p.links:
                with self.subTest(page=name, link=link[:80]):
                    if link.startswith("#"):
                        self.assertIn(link[1:], p.ids, "no element with this id")
                    elif link.startswith(("data:", "mailto:")):
                        pass
                    elif link.startswith("http://"):
                        self.fail("plain http link")
                    elif link.startswith("https://"):
                        m = REPO_LINK.match(link)
                        if m:
                            self.assertTrue(os.path.exists(os.path.join(ROOT, m.group(1))),
                                            "not in the repo: " + m.group(1))
                    else:
                        local = link.split("#", 1)[0].split("?", 1)[0]
                        self.assertTrue(os.path.exists(os.path.join(SITE, local)), "missing file")


if __name__ == "__main__":
    unittest.main()
