"""site/: the static landing page. Offline checks only (stdlib html.parser).

Structure (balanced tags, one h1, title, description), in-page anchors, local files,
every link into this repo on GitHub points at a path that exists here, the sections and
links the landing page promises, and no personal hostnames.

The donate link is a placeholder (#donate-tbd) until the donation service is chosen.
Set NEEDS_YOU_SITE_RELEASE=1 (before deploying) to make that placeholder a failure.
"""
from __future__ import annotations

import os
import re
import unittest
from html.parser import HTMLParser

from support import ROOT

SITE = os.path.join(ROOT, "site")
DONATE_PLACEHOLDER = "#donate-tbd"
RELEASE = os.environ.get("NEEDS_YOU_SITE_RELEASE") == "1"
# The site's own origin (canonical and og:url).
SITE_ORIGIN = "https://needsyou.app/"
# Hosts the site may link to. Anything else (a personal domain, a tailnet name) fails.
LINK_HOSTS = {"github.com", "needsyou.app"}
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
        self.assets = []  # href of every <link> but data: URIs
        self.anchors = []  # (attrs, text) for every <a>
        self.text = []
        self._a = None
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
                if tag == "link" and not a[k].startswith("data:"):
                    self.assets.append(a[k])
        if tag == "meta" and a.get("name"):
            self.meta[a["name"]] = a.get("content", "")
        if tag == "title":
            self._in_title = True
        if tag == "a":
            self._a = (a, [])
            self.anchors.append(self._a)
        if tag not in VOID:
            self.stack.append((tag, self.getpos()))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "a":
            self._a = None
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
        if self._a is not None:
            self._a[1].append(data)
        self.text.append(data)

    def anchor_text(self, anchor):
        return " ".join("".join(anchor[1]).split())

    def body_text(self):
        return " ".join("".join(self.text).split())


def read_site(name):
    with open(os.path.join(SITE, name), encoding="utf-8") as fh:
        return fh.read()


def repo_url():
    m = re.search(r'^var REPO_URL = "([^"]+)";$', read_site("site.js"), re.M)
    return m.group(1) if m else None


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
                    if link == DONATE_PLACEHOLDER:
                        continue  # test_donate_link decides
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


    def test_link_hosts(self):
        for name, p in self.pages.items():
            for link in p.links:
                m = re.match(r"^https://([^/]+)", link)
                if m:
                    with self.subTest(page=name, link=link[:80]):
                        self.assertIn(m.group(1), LINK_HOSTS, "link to an unexpected host")

    def test_self_hosted_assets(self):
        # Stylesheets and fonts are same-origin only: no third-party font or CSS hosts.
        for name, p in self.pages.items():
            for href in p.assets:
                if href == SITE_ORIGIN:   # rel="canonical", not an asset
                    continue
                with self.subTest(page=name, href=href[:80]):
                    self.assertNotRegex(href, r"^(?:[a-z]+:)?//", "<link> must be same-origin")
        csp = re.search(r"Content-Security-Policy: (.*)", read_site("_headers")).group(1)
        self.assertIn("font-src 'self';", csp)
        self.assertIn("style-src 'self';", csp)

    def test_fonts(self):
        css = read_site("styles.css")
        urls = re.findall(r'url\("([^"]+)"\)', css)
        self.assertTrue(urls)
        for url in urls:
            with self.subTest(url=url):
                self.assertTrue(url.startswith("fonts/") and url.endswith(".woff2"), url)
                with open(os.path.join(SITE, url), "rb") as fh:
                    self.assertEqual(fh.read(4), b"wOF2")
        self.assertEqual(css.count("font-display: swap"), css.count("@font-face"))
        self.assertIn("SIL Open Font License", read_site(os.path.join("fonts", "OFL.txt")))

    def test_site_domain(self):
        # The site lives at https://needsyou.app: canonical and og:url name it.
        html = re.sub(r"<!--.*?-->", "", read_site("index.html"), flags=re.S)
        self.assertIn('<link rel="canonical" href="%s">' % SITE_ORIGIN, html)
        self.assertIn('<meta property="og:url" content="%s">' % SITE_ORIGIN, html)

    def test_css_hex_only_in_primitives(self):
        # Like the design tokens it follows: a hex appears only as a primitive
        # (--name: #hex; at the top of :root); every rule references a variable.
        for n, line in enumerate(read_site("styles.css").splitlines(), 1):
            if re.search(r"#[0-9a-fA-F]{3,8}\b", line):
                with self.subTest(line=n):
                    self.assertRegex(line, r"^\s*--[\w-]+: #[0-9a-fA-F]{3,8};", line.strip())

    def test_no_personal_hostnames(self):
        # Only the documented placeholders: hub-a.example.ts.net, <tailnet>, devbox.
        for name in sorted(os.listdir(SITE)):
            path = os.path.join(SITE, name)
            if not os.path.isfile(path) or name.endswith(".woff2"):
                continue
            text = read_site(name)
            with self.subTest(file=name):
                for host in re.findall(r"[\w.-]+\.ts\.net", text):
                    self.assertTrue(host.endswith("example.ts.net"), host)
                self.assertNotRegex(text, r"\b(?:100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)\b",
                                    "tailnet IP")

    def test_sections(self):
        p = self.pages["index.html"]
        for sid in ("how", "install", "source", "donate"):
            self.assertIn(sid, p.ids)
        self.assertIn("mock", read_site("index.html"))  # the CSS pill mock, not a screenshot
        self.assertNotIn("img", p.tags)
        how = re.search(r'<ol class="how">(.*?)</ol>', read_site("index.html"), re.S).group(1)
        self.assertEqual(how.count("<li>"), 3)

    def test_install(self):
        p = self.pages["index.html"]
        text = p.body_text()
        download = [a for a in p.anchors if "Download" in p.anchor_text(a)]
        self.assertEqual(len(download), 1)
        self.assertEqual(download[0][0].get("href"), repo_url() + "/releases/latest")
        self.assertIn(".dmg", text)
        self.assertIn(".zip", text)
        self.assertIn("ad-hoc signed", text)
        self.assertIn("Right-click", text)
        self.assertIn("curl -fsSL <join_url>/install.sh | bash -s -- --yes", text)

    def test_repo_links_follow_the_constant(self):
        base = repo_url()
        self.assertEqual(base, "https://github.com/tayharris/needs-you")
        for name, p in self.pages.items():
            repo_anchors = [a for a, _ in p.anchors if (a.get("href") or "").startswith("https://github.com/")]
            self.assertTrue(repo_anchors)
            for a in repo_anchors:
                with self.subTest(page=name, href=a["href"]):
                    self.assertIn("data-repo", a, "GitHub links go through REPO_URL in site.js")
                    self.assertEqual(a["href"], base + a["data-repo"])

    def test_open_source(self):
        p = self.pages["index.html"]
        self.assertIn("Apache-2.0", p.body_text())
        self.assertTrue([a for a, _ in p.anchors if a.get("data-repo") == ""], "a link to the repo itself")

    def test_donate_link(self):
        p = self.pages["index.html"]
        donate = [a for a in p.anchors if "support the project" in p.anchor_text(a).lower()]
        self.assertEqual(len(donate), 1)
        href = donate[0][0].get("href", "")
        if RELEASE:
            self.assertNotEqual(href, DONATE_PLACEHOLDER,
                                "pick the donation service and set the real URL before release")
        else:
            self.assertTrue(href == DONATE_PLACEHOLDER or href.startswith("https://"), href)


if __name__ == "__main__":
    unittest.main()
