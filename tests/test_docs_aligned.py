"""The docs and the site say what the code does. Offline, stdlib only, well under a second.

Everything is parsed from the source, not listed here, so a renamed page, a new env var or a
new guide fails the test until the docs follow:

- Settings paths: every "Settings → X → Y" in the user docs names a real sidebar group or
  page (SettingsTab and SettingsSidebarGroup in mac/Sources/NeedsYouCore/SettingsPages.swift),
  a page in that group, and then something the app really shows (a string in the app's
  Swift sources: a section header, a toggle, a button).
- Env vars: every NEEDS_YOU_* variable a doc names exists in code, and every one an
  integration's scripts read is documented in that integration's guide (or, for the shared
  sender config, in Add a sender).
- Guides: every docs/guides/*.md is placed and described on the site's guides index
  (scripts/build_site_guides.py CURATED) and linked from README.md.
- Site images: every image a page or a doc references exists, and every file in site/img is
  used somewhere.
- CHANGELOG: every Added or Changed entry in [Unreleased] and the latest release links the
  guide (or doc) that explains it.
"""
from __future__ import annotations

import glob
import os
import re
import sys
import unittest

from support import ROOT

sys.path.insert(0, os.path.join(ROOT, "scripts"))
import build_site_guides as gen  # noqa: E402

SETTINGS_PAGES = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "SettingsPages.swift")
SWIFT_DIRS = [os.path.join(ROOT, "mac", "Sources", d) for d in ("NeedsYou", "NeedsYouCore")]

# User-facing docs. History (CHANGELOG, ADRs, roadmap) keeps the names of its day.
USER_DOCS = (["README.md", "mac/README.md", "docs/API.md", "docs/HUB.md", "docs/AGENT-GUIDE.md",
              "integrations/claude-code/skill/needs-you/SKILL.md"]
             + sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, "docs", "guides", "*.md")))
             + sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, "docs", "security", "*.md")))
             + sorted(os.path.relpath(p, ROOT) for p in glob.glob(os.path.join(ROOT, "integrations", "*", "*.md"))))
SITE_PAGES = ["site/index.html"]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def plain(text):
    """Markdown or HTML as plain prose: no emphasis, tags or entities, arrows as →."""
    text = re.sub(r"<[^>]+>", "", text)
    for ent, ch in (("&rarr;", "→"), ("&hellip;", "…"), ("&amp;", "&"), ("&gt;", ">"), ("&lt;", "<"),
                    ("&quot;", '"'), ("&nbsp;", " ")):
        text = text.replace(ent, ch)
    return text.replace("**", "").replace("`", "")


# ---------------------------------------------------------------------------------------------
# Settings paths
# ---------------------------------------------------------------------------------------------

def settings_model():
    """({page title: group title}, {group title: [page titles]}) from SettingsPages.swift."""
    src = read(os.path.relpath(SETTINGS_PAGES, ROOT))

    def switch(prop):
        body = re.search(r"var %s: [^{]+\{\s*switch self \{(.*?)\n        \}" % prop, src, re.S).group(1)
        out = {}
        for cases, value in re.findall(r"case ([.\w, ]+): return (\S[^\n]*)", body):
            for case in re.findall(r"\.(\w+)", cases):
                out[case] = value.strip()
        return out

    titles = {k: v.strip('"') for k, v in switch("title").items()}
    groups = {k: v.lstrip(".") for k, v in switch("group").items()}
    group_body = src[src.index("enum SettingsSidebarGroup"):]
    group_titles = {k: v.strip('"') for k, v in
                    re.findall(r'case \.(\w+): return ("[^"]*"|nil)', group_body[:group_body.index("func pages")])}
    page_group = {titles[k]: group_titles.get(groups[k], "nil") for k in titles}
    by_group = {}
    for k in re.search(r"enum SettingsTab[^{]*\{(.*?)public var title", src, re.S).group(1).split("\n"):
        for case in re.findall(r"\b(\w+)\b", k.split("//")[0].replace("case", "")):
            if case in titles:
                by_group.setdefault(page_group[titles[case]], []).append(titles[case])
    # "Other hubs (advanced)" may be named without its parenthesis.
    for title, group in list(page_group.items()):
        short = re.sub(r"\s*\([^)]*\)$", "", title)
        if short != title:
            page_group[short] = group
            by_group[group].append(short)
    return page_group, by_group


SETTINGS_LAYOUT = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "SettingsLayout.swift")
SECTION_TAG = re.compile(r"^\s*//\s*settings-section:\s*(\w+)\s*$")
STRING = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def literal_variants(s):
    s = re.sub(r"\\\(.*?\)", "", s).strip()
    return {s, s.rstrip("….").strip()} if len(s) >= 3 else set()


def page_strings():
    """{page title: strings its sections show}. SettingsSection (SettingsLayout.swift) says
    which page each section is on; the app tags each section's view
    `// settings-section: <case>`, and a section's strings are those from its tag to the next."""
    pages = read(os.path.relpath(SETTINGS_PAGES, ROOT))
    body = re.search(r"public var title: String \{\s*switch self \{(.*?)\n        \}", pages, re.S).group(1)
    title = dict(re.findall(r'case \.(\w+): return "([^"]*)"', body))
    layout = read(os.path.relpath(SETTINGS_LAYOUT, ROOT))
    tab_body = re.search(r"public var tab: SettingsTab \{\s*switch self \{(.*?)\n        \}", layout, re.S).group(1)
    section_tab = {}
    for cases, tab in re.findall(r"case ([.\w, ]+): return \.(\w+)", tab_body):
        for case in re.findall(r"\.(\w+)", cases):
            section_tab[case] = tab
    out = {}
    for dirpath, _, files in os.walk(SWIFT_DIRS[0]):
        for f in files:
            if not f.endswith(".swift"):
                continue
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                current = None
                for line in fh:
                    m = SECTION_TAG.match(line)
                    if m and m.group(1) in section_tab:
                        current = title[section_tab[m.group(1)]]
                        continue
                    if current:
                        for lit in STRING.findall(line):
                            out.setdefault(current, set()).update(literal_variants(lit))
    for t in list(out):   # "Other hubs (advanced)" may be named without its parenthesis.
        out.setdefault(re.sub(r"\s*\([^)]*\)$", "", t), out[t])
    return out


def swift_strings():
    """Every string literal in the app's Swift sources (labels, headers, buttons, menu items)."""
    out = set()
    for d in SWIFT_DIRS:
        for dirpath, _, files in os.walk(d):
            for f in files:
                if f.endswith(".swift"):
                    with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                        for s in re.findall(r'"((?:[^"\\\n]|\\.)*)"', fh.read()):
                            s = re.sub(r"\\\(.*?\)", "", s).strip()
                            if len(s) >= 3:
                                out.add(s)
                                out.add(s.rstrip("….").strip())   # "Add an always-on hub…"
    return out


# Settings of other apps, named in passing: macOS's System Settings, and Linear, Cursor,
# GitHub, Tailscale's admin console. A path right after one of these isn't ours.
FOREIGN = re.compile(r"(System|Linear|Cursor|GitHub|Tailscale|admin|repository|Jira|Atlassian|Slack)\W.{0,60}$")
SETTINGS_PATH = re.compile(r"\bSettings(?:…|\.\.\.)?\s*(?:→|>)\s*")
SEGMENT_END = re.compile(r"\s*(?:→|>(?!=))\s*")


def settings_paths(text):
    """(line, [segments]) for each "Settings → A → B ..." in the text. The last segment runs on
    into the sentence; callers match segments by prefix."""
    lines = plain(text).split("\n")
    start = 0
    for i in range(len(lines) + 1):          # paragraphs: a path may wrap onto the next line
        if i < len(lines) and lines[i].strip():
            continue
        n, line = start + 1, " ".join(l.strip() for l in lines[start:i])
        start = i + 1
        for m in SETTINGS_PATH.finditer(line):
            if FOREIGN.search(line[:m.start()]):
                continue
            rest = re.split(r"[.;:,()|\"*]|\s-\s", line[m.end():])[0]
            segs = [s.strip() for s in SEGMENT_END.split(rest) if s.strip()]
            if segs:
                yield n, segs


def starts_with_one_of(segment, names):
    """The longest name the segment starts with, as whole words, or None."""
    best = None
    for name in names:
        if segment == name or (segment.startswith(name) and not segment[len(name)].isalnum()):
            if best is None or len(name) > len(best):
                best = name
    return best


class SettingsPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page_group, cls.by_group = settings_model()
        cls.strings = swift_strings()
        cls.by_page = page_strings()

    def check(self, segs):
        """None if the path is real, else why not."""
        groups = {g for g in self.by_group if g != "nil"}
        first = starts_with_one_of(segs[0], list(self.page_group) + list(groups))
        if first is None:
            return "%r is not a Settings page or group (SettingsPages.swift)" % segs[0]
        rest = segs[1:]
        if first in groups and first not in self.page_group:
            if not rest:
                return None
            page = starts_with_one_of(rest[0], self.by_group[first])
            if page is None:
                return "%r is not a page under %s (%s)" % (rest[0], first, ", ".join(self.by_group[first]))
            first, rest = page, rest[1:]
        if rest and first in self.by_page:
            # The first thing on a page must be on that page, not on another one.
            seg = rest[0]
            here = starts_with_one_of(seg, self.by_page[first])
            elsewhere = sorted(p for p, strings in self.by_page.items()
                               if p != first and starts_with_one_of(seg, strings))
            if here is None and elsewhere:
                return "%r is on %s, not %s" % (seg, " / ".join(elsewhere), first)
        for seg in rest:
            # A path is cut at a comma, so "Expiring certificates" stands for the app's
            # "Expiring certificates, domains and keys".
            if starts_with_one_of(seg, self.strings) is None and \
                    not any(s.startswith(seg + ",") for s in self.strings):
                return "%r isn't shown anywhere in the app's Settings (no such string in mac/Sources)" % seg
        return None

    def test_the_model_parses(self):
        self.assertIn("Appearance", self.by_group)
        self.assertIn("Usage meters", self.by_group["Appearance"])
        self.assertIn("Built-in hub", self.page_group)
        self.assertGreaterEqual(sum(len(v) for v in self.by_group.values()), 10)

    def test_every_settings_path_is_real(self):
        for rel in USER_DOCS + SITE_PAGES:
            for n, segs in settings_paths(read(rel)):
                why = self.check(segs)
                with self.subTest(doc="%s:%d" % (rel, n), path=" → ".join(segs)[:80]):
                    self.assertIsNone(why, why)

    def test_the_checker_catches_stale_paths(self):
        bad = ("Settings → Usage meters → Style", "Settings → Your inbox", "Settings → Appearance → Usage",
               "Settings → Panel → Make it pink")
        for text in bad:
            with self.subTest(text=text):
                paths = list(settings_paths(text))
                self.assertEqual(len(paths), 1)
                if text == bad[0]:
                    self.assertIsNone(self.check(paths[0][1]))   # a page by its own name is fine
                else:
                    self.assertIsNotNone(self.check(paths[0][1]))
        self.assertEqual(list(settings_paths("System Settings → Privacy & Security")), [])
        self.assertEqual(list(settings_paths("in Linear, Settings → Account → API")), [])
        self.assertIsNone(self.check(next(settings_paths("**Settings → Appearance → Usage meters** has"))[1]))
        # Moved sections are caught: the edge glow is on Alert style, not Alerts.
        self.assertIn("Edge glow", self.by_page["Alert style"])
        self.assertIsNotNone(self.check(next(settings_paths("Settings → Alerts → Edge glow"))[1]))
        self.assertIsNone(self.check(next(settings_paths("Settings → Appearance → Alert style → Edge glow"))[1]))


# ---------------------------------------------------------------------------------------------
# mac/README.md's list of stored keys
# ---------------------------------------------------------------------------------------------

def swift_key_value(ref):
    """`UIPrefs.Key.theme` or `EdgeGlowMode.defaultsKey` or `AppPrefKey.userName.rawValue`:
    the UserDefaults key it names, read from the Swift source."""
    sources = {}
    for d in SWIFT_DIRS:
        for dirpath, _, files in os.walk(d):
            for f in files:
                if f.endswith(".swift"):
                    with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                        sources[f] = fh.read()
    parts = ref.split(".")
    owner = parts[0]
    for src in sources.values():
        m = re.search(r"(?:struct|enum|class|extension) %s\b" % re.escape(owner), src)
        if not m:
            continue
        rest = src[m.start():]
        if parts[-1] == "rawValue":       # an enum case: its raw value or its name
            case = parts[1]
            cm = re.search(r'\bcase %s = "([^"]+)"' % case, rest)
            return cm.group(1) if cm else case
        name = parts[-1]
        km = re.search(r'static let %s = "([^"]+)"' % re.escape(name), rest)
        if km:
            return km.group(1)
    return None


class StoredKeysTests(unittest.TestCase):
    def test_mac_readme_lists_every_look_key(self):
        # Every look setting's stored key is in the `defaults read app.needsyou.mac` list.
        layout = read(os.path.relpath(SETTINGS_LAYOUT, ROOT))
        readme = read("mac/README.md")
        para = next(p for p in readme.split("\n\n") if "defaults read app.needsyou.mac" in p and "Every default" in p)
        refs = re.findall(r"\.look\((\w+\.[\w.]+),", layout)
        self.assertGreater(len(refs), 20)
        for ref in refs:
            key = swift_key_value(ref)
            with self.subTest(setting=ref):
                self.assertIsNotNone(key, "can't resolve " + ref)
                self.assertIn("`%s`" % key, para, "mac/README.md: add `%s` to the stored keys" % key)

    def test_mac_readme_names_no_stale_key(self):
        readme = read("mac/README.md")
        para = next(p for p in readme.split("\n\n") if "defaults read app.needsyou.mac" in p and "Every default" in p)
        sources = ""
        for d in SWIFT_DIRS:
            for dirpath, _, files in os.walk(d):
                for f in files:
                    if f.endswith(".swift"):
                        with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                            sources += fh.read()
        for word in re.findall(r"`([a-z][A-Za-z]+)`", para):
            with self.subTest(key=word):
                self.assertRegex(sources, r"\b%s\b" % word, "mac/README.md names `%s`, which no Swift code uses" % word)


# ---------------------------------------------------------------------------------------------
# Env vars
# ---------------------------------------------------------------------------------------------

ENV = re.compile(r"\bNEEDS_YOU_[A-Z0-9_]*[A-Z0-9]\b")
CODE_DIRS = ["hub", "cli", "integrations", "scripts", "deploy", "mac/Sources", "mac/scripts", "protocol"]
SHARED_CONFIG_DOC = "docs/guides/add-a-sender.md"
HOOK = "needs-you-hook"
# Set by needs-you itself for its own child processes, or a seam for the tests: never
# something a person sets, so no guide names them. Each must still be in the code.
INTERNAL = {
    "NEEDS_YOU_INSTALLER": "the invite installer and `needs-you install-*` set it for the agent installers they run",
    "NEEDS_YOU_WATCH_PID": "the hook sets it for `needs-you answer-wait`",
    "NEEDS_YOU_HOOK_TTY": "tests: the hook's terminal",
    "NEEDS_YOU_HOOK_PLATFORM": "tests: the hook's platform",
}


def code_files(dirs):
    for d in dirs:
        top = os.path.join(ROOT, d)
        for dirpath, dirnames, files in os.walk(top):
            dirnames[:] = [x for x in dirnames if x not in (".build", "dist", "__pycache__", "node_modules")]
            for f in files:
                if not f.endswith((".md", ".png", ".woff2", ".icns", ".pyc")):
                    yield os.path.join(dirpath, f)


def env_in(paths):
    out = set()
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                out |= set(ENV.findall(fh.read()))
        except (OSError, UnicodeDecodeError):
            pass
    return out


def defined_in_doc(text):
    """Variables a doc's own example code reads (a relay script it walks through, say)."""
    return set(re.findall(r"""environ(?:\.get)?[(\[]\s*["'](NEEDS_YOU_\w+)""", text)) | \
        set(re.findall(r"\$\{(NEEDS_YOU_\w+)", text))


class EnvVarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = env_in(code_files(CODE_DIRS))

    def test_every_documented_variable_exists(self):
        for rel in USER_DOCS + SITE_PAGES:
            text = read(rel)
            local = defined_in_doc(text)
            for var in sorted(set(ENV.findall(text))):
                with self.subTest(doc=rel, var=var):
                    self.assertTrue(var in self.code or var in local,
                                    "no code reads %s (renamed, or a typo?)" % var)

    def test_every_integration_variable_is_documented(self):
        shared = set(ENV.findall(read(SHARED_CONFIG_DOC)))
        hook_users = []
        per_dir = {}
        for d in sorted(os.listdir(os.path.join(ROOT, "integrations"))):
            top = os.path.join(ROOT, "integrations", d)
            if not os.path.isdir(top):
                continue
            files = list(code_files(["integrations/" + d]))
            guides = (glob.glob(os.path.join(ROOT, "docs", "guides", d + "*.md"))
                      + glob.glob(os.path.join(top, "**", "*.md"), recursive=True))
            per_dir[d] = (env_in(files), env_in(guides))
            for f in files:
                with open(f, encoding="utf-8", errors="replace") as fh:
                    if HOOK in fh.read():
                        hook_users.append(d)
                        break
        # The one hook serves every agent: its variables may be in any of their guides.
        hook_docs = set().union(*(per_dir[d][1] for d in hook_users)) if hook_users else set()
        for d, (used, documented) in per_dir.items():
            docs = documented | shared | (hook_docs if d in hook_users else set())
            for var in sorted(used - set(INTERNAL)):
                with self.subTest(integration=d, var=var):
                    self.assertIn(var, docs, "integrations/%s reads %s: say what it does in its guide "
                                  "(docs/guides/%s.md or integrations/%s/README.md)" % (d, var, d, d))

    def test_internal_variables_are_still_used(self):
        for var, why in INTERNAL.items():
            with self.subTest(var=var):
                self.assertTrue(why)
                self.assertIn(var, self.code, "no longer used: drop it from INTERNAL")


# ---------------------------------------------------------------------------------------------
# Guides
# ---------------------------------------------------------------------------------------------

class GuideIndexTests(unittest.TestCase):
    def guides(self):
        return sorted("docs/guides/" + n for n in os.listdir(os.path.join(ROOT, "docs", "guides"))
                      if n.endswith(".md"))

    def test_every_guide_is_placed_on_the_site_index(self):
        # Not just published under "More guides": placed in its group with a summary.
        curated = {g[1] for g in gen.CURATED}
        for g in self.guides():
            with self.subTest(guide=g):
                self.assertIn(g, curated, "add it to CURATED in scripts/build_site_guides.py")

    def test_readme_links_every_guide(self):
        links = set(re.findall(r"\]\((docs/guides/[\w-]+\.md)(?:#[^)]*)?\)", read("README.md")))
        for g in self.guides():
            with self.subTest(guide=g):
                self.assertIn(g, links, "README.md links no %s" % g)

    def test_landing_page_lists_every_integration(self):
        # "Works with" on needsyou.app: every integration with a guide of its own.
        html = read("site/index.html")
        works = re.search(r'<section id="works".*?</section>', html, re.S).group(0)
        for d in sorted(os.listdir(os.path.join(ROOT, "integrations"))):
            if os.path.isfile(os.path.join(ROOT, "docs", "guides", d + ".md")):
                with self.subTest(integration=d):
                    self.assertIn('href="guides/%s.html"' % d, works, "add it to Works with in site/index.html")

    def test_landing_page_links_the_guides_index(self):
        self.assertRegex(read("site/index.html"), r'href="guides/(?:index\.html)?"')


# ---------------------------------------------------------------------------------------------
# Site images
# ---------------------------------------------------------------------------------------------

IMG_REF = re.compile(r"""(?:src=["']|\]\()(?:\.\./)*(?:site/)?(img/[\w./-]+)""")


class SiteImageTests(unittest.TestCase):
    def references(self):
        refs = {}
        texts = [(rel, read(rel)) for rel in USER_DOCS + SITE_PAGES + ["site/site.js", "site/styles.css"]]
        texts += [(os.path.relpath(p, ROOT), read(os.path.relpath(p, ROOT)))
                  for p in glob.glob(os.path.join(ROOT, "site", "guides", "*.html"))]
        for rel, text in texts:
            for ref in IMG_REF.findall(text):
                refs.setdefault(ref, set()).add(rel)
        return refs

    def test_every_referenced_image_exists(self):
        for ref, where in sorted(self.references().items()):
            with self.subTest(image=ref, used_in=sorted(where)[0]):
                self.assertTrue(os.path.isfile(os.path.join(ROOT, "site", ref)), "missing site/" + ref)

    def test_every_image_is_used(self):
        used = set(self.references())
        for name in sorted(os.listdir(os.path.join(ROOT, "site", "img"))):
            with self.subTest(image=name):
                self.assertIn("img/" + name, used, "site/img/%s isn't used by the site or the docs" % name)


# ---------------------------------------------------------------------------------------------
# CHANGELOG
# ---------------------------------------------------------------------------------------------

DOC_LINK = re.compile(r"\]\(((?:docs|integrations)/[^)#\s]+\.md|README\.md|mac/README\.md)(#[^)]*)?\)")


def changelog_sections():
    """{"Unreleased" or the latest version: {"Added": [entries], ...}}."""
    text = read("CHANGELOG.md")
    out = {}
    releases = re.split(r"(?m)^## \[", text)[1:]
    for block in releases[:2]:
        name = block.split("]", 1)[0]
        kinds = {}
        for kind, body in re.findall(r"(?ms)^### (\w+)\n(.*?)(?=^### |\Z)", block):
            kinds[kind] = [e.strip() for e in re.split(r"(?m)^- ", body) if e.strip()]
        out[name] = kinds
        if name != "Unreleased":
            break
    return out


class ChangelogTests(unittest.TestCase):
    def test_new_features_link_their_guide(self):
        sections = changelog_sections()
        self.assertTrue([k for k in sections if k != "Unreleased"], "no release found")
        for release, kinds in sections.items():
            for kind in ("Added", "Changed"):
                for entry in kinds.get(kind, []):
                    with self.subTest(release=release, kind=kind, entry=entry[:70]):
                        links = DOC_LINK.findall(entry)
                        self.assertTrue(links, "link the guide that explains it")
                        for path, _ in links:
                            self.assertTrue(os.path.isfile(os.path.join(ROOT, path)), path)


if __name__ == "__main__":
    unittest.main()
