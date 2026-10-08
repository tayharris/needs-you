"""Every relative link in README.md, the other top-level docs and docs/**/*.md points at a file
or directory that exists, and a `#anchor` on a Markdown target matches one of its headings
(GitHub's anchor rules). External links aren't fetched. Stdlib only, no network, well under a
second."""
from __future__ import annotations

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TOP_LEVEL = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "AGENTS.md", "CLAUDE.md", "CHANGELOG.md"]

FENCE = re.compile(r"^\s*(```|~~~)")
# [text](target) or [text](target "title"); images too. Targets with spaces aren't used here.
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s|$)")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ID = re.compile(r"""<a\s+(?:name|id)=["']([^"']+)["']""")


def doc_files() -> list[str]:
    files = [os.path.join(ROOT, f) for f in TOP_LEVEL if os.path.isfile(os.path.join(ROOT, f))]
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "docs")):
        dirnames.sort()
        files += [os.path.join(dirpath, f) for f in sorted(filenames) if f.endswith(".md")]
    return files


def prose_lines(text: str):
    """(line number, line) outside fenced code blocks, with code spans blanked."""
    in_fence = None
    for n, line in enumerate(text.split("\n"), 1):
        m = FENCE.match(line)
        if m:
            if in_fence is None:
                in_fence = m.group(1)
            elif m.group(1) == in_fence:
                in_fence = None
            continue
        if in_fence is None:
            yield n, CODE_SPAN.sub(lambda c: " " * len(c.group(0)), line)


def github_slug(heading: str) -> str:
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links keep their text
    # HTML tags go, but `<id>` inside a code span is text (its < > drop out below).
    parts = re.split(r"(`+[^`]*`+)", text)
    text = "".join(p.strip("`") if p.startswith("`") else re.sub(r"<[^>]+>", "", p) for p in parts)
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchor_cache: dict = {}


def anchors(path: str) -> set:
    """A Markdown file's heading anchors, from the raw text (code spans kept, as GitHub slugs
    them), plus any <a id=...>."""
    if path in _anchor_cache:
        return _anchor_cache[path]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    seen: dict = {}
    out = set()
    in_fence = None
    for line in text.split("\n"):
        m = FENCE.match(line)
        if m:
            if in_fence is None:
                in_fence = m.group(1)
            elif m.group(1) == in_fence:
                in_fence = None
            continue
        if in_fence is not None:
            continue
        out.update(HTML_ID.findall(line))
        h = HEADING.match(line)
        if not h:
            continue
        base = github_slug(h.group(2))
        n = seen.get(base, 0)
        out.add(base if n == 0 else "%s-%d" % (base, n))
        seen[base] = n + 1
    _anchor_cache[path] = out
    return out


def broken_links(path: str) -> list[str]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    rel = os.path.relpath(path, ROOT)
    problems = []
    for n, line in prose_lines(text):
        targets = INLINE_LINK.findall(line)
        m = REF_DEF.match(line)
        if m:
            targets.append(m.group(1))
        for target in targets:
            if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("//"):
                continue  # https:, mailto:, needsyou:, ... (not checked here)
            target_path, _, frag = target.partition("#")
            if target_path:
                dest = os.path.normpath(os.path.join(os.path.dirname(path), target_path))
                if not os.path.exists(dest):
                    problems.append("%s:%d: %s (no such file)" % (rel, n, target))
                    continue
            else:
                dest = path
            if frag and dest.endswith(".md") and os.path.isfile(dest):
                if frag not in anchors(dest):
                    problems.append("%s:%d: %s (no such heading)" % (rel, n, target))
    return problems


class DocLinksTest(unittest.TestCase):
    def test_relative_links_resolve(self):
        problems = []
        for path in doc_files():
            problems += broken_links(path)
        self.assertEqual(problems, [], "broken links:\n" + "\n".join(problems))

    def test_the_checker_catches_a_broken_link(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.md")
            with open(os.path.join(d, "b.md"), "w", encoding="utf-8") as f:
                f.write("# Real heading\n\n## `code` and more\n")
            with open(p, "w", encoding="utf-8") as f:
                f.write("[ok](b.md) [ok](b.md#real-heading) [ok](b.md#code-and-more)\n"
                        "[bad](c.md) [bad](b.md#nope) `[skipped](nope.md)`\n"
                        "```\n[skipped](nope.md)\n```\n[web](https://example.com/x.md)\n")
            found = broken_links(p)
        self.assertEqual(len(found), 2, found)
        self.assertIn("c.md (no such file)", found[0])
        self.assertIn("b.md#nope (no such heading)", found[1])


if __name__ == "__main__":
    unittest.main()
