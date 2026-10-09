#!/usr/bin/env python3
"""Build site/guides/ (the guides on needsyou.app) from the markdown in docs/.

    python3 scripts/build_site_guides.py           # write site/guides/*.html
    python3 scripts/build_site_guides.py --check   # exit 1 if site/guides/ is stale

Stdlib only, Python 3.9. The output is committed, and tests/test_site_guides.py fails when
it no longer matches the markdown, so a forgotten rebuild is caught by CI. The site workflow
(.github/workflows/site.yml) rebuilds and deploys on every push to main.

The markdown subset is what docs/ uses: ATX headings (GitHub-style anchor ids), paragraphs,
nested lists and task lists, fenced code, tables, blockquotes, rules, inline code, links,
bold and italic. All HTML in the markdown is escaped, except <img> tags that point into
site/img/ (the screenshots), which are rebuilt from their src, width and alt. Relative links
to a published doc become links to its page; links to anything else in the repo go to GitHub
(through REPO_URL in site/site.js); a link to a file or anchor that doesn't exist fails the
build. A shell block that runs exactly as written gets a Copy button (see copyable()); one
with placeholders or example values doesn't. The output depends only on the inputs: no
dates, sorted everything.
"""
from __future__ import annotations

import html
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT_DIR = "guides"  # under site/
ORIGIN = "https://needsyou.app/"

# The guides index, grouped and ordered for a first-time reader: what it is and how to set it
# up, then one guide per agent, then servers, CI and other senders, then running hubs, then
# the reference.
# GROUPS is the order of the sections; MORE is where a guide not listed in CURATED goes.
START, AGENTS, SENDERS, MORE, RUN, REFERENCE = (
    "Start here", "Agents", "Servers, CI and tools", "More guides", "Run it", "Reference")
GROUPS = [START, AGENTS, SENDERS, MORE, RUN, REFERENCE]

# (group, markdown source, page name, short title, one-line summary), in order within each
# group. An entry whose source doesn't exist yet is skipped. Every other docs/guides/*.md is
# published too, under MORE (title from its "# " line, summary from its first paragraph), so
# a new guide is on the site as soon as it's merged; add it here to place and describe it.
CURATED = [
    (START, "docs/guides/quickstart.md", "quickstart", "Quickstart",
     "The whole setup, step by step: the Mac app, Claude Code on the Mac, servers."),
    (START, "docs/guides/setup-with-an-agent.md", "setup-with-an-agent", "Set it up with an agent",
     "One prompt for Claude Code or another agent: it installs the app, connects the agents it finds, and asks you at every choice."),
    (START, "docs/guides/testers.md", "testers", "Testers",
     "Trying needs-you: download, first run, what to try and how to report problems, on one page."),
    (START, "docs/guides/concepts.md", "concepts", "App, hubs and senders",
     "The three parts and their names: the Needs You app shows alerts, a hub stores them (built into the app, or on a server), senders post them. Plus roles, invites and the Settings page for each."),
    (START, "docs/guides/mac-app.md", "mac-app", "Mac app",
     "Installing and using NeedsYou.app: the pill, the cards, Settings."),
    (START, "docs/guides/help-us-test.md", "help-us-test", "Help us test",
     "Which AI tools have been run for real and which only against a stub or from their docs, what to try, and how to report back."),
    (AGENTS, "docs/guides/claude-code.md", "claude-code", "Claude Code",
     "Claude Code hooks for \"agent is waiting\" cards, and the skill: what gets installed and what each hook posts."),
    (AGENTS, "docs/guides/claude-code-everywhere.md", "claude-code-everywhere", "Claude Code everywhere",
     "Alerts from Claude Code sessions on the Mac, over SSH, in tmux, VS Code Remote-SSH and Orca."),
    (AGENTS, "docs/guides/codex.md", "codex", "Codex CLI",
     "OpenAI Codex CLI hooks: a card when a session wants approval or is waiting for your next message."),
    (AGENTS, "docs/guides/gemini.md", "gemini", "Gemini CLI",
     "Gemini CLI hooks: a card when a session wants approval or is waiting for your next message."),
    (AGENTS, "docs/guides/copilot.md", "copilot", "Copilot CLI",
     "GitHub Copilot CLI hooks: a card when Copilot asks for permission or finishes its turn, cleared when you answer."),
    (AGENTS, "docs/guides/kimi.md", "kimi", "Kimi Code",
     "Kimi Code CLI hooks: a card when Kimi asks for approval or a question, or finishes its turn, cleared when you answer."),
    (AGENTS, "docs/guides/grok.md", "grok", "Grok Build",
     "Grok Build hooks: a card when Grok asks for permission or has waited a minute for you, and how they share the Claude Code hooks."),
    (AGENTS, "docs/guides/cursor.md", "cursor", "Cursor",
     "Cursor hooks: a card when a Cursor agent finishes its turn (Cursor has no approval hook)."),
    (AGENTS, "docs/guides/cline.md", "cline", "Cline",
     "Cline hooks, VS Code and CLI: a card when a task finishes (Cline has no approval hook)."),
    (AGENTS, "docs/guides/aider.md", "aider", "Aider",
     "Aider's notifications command: a card when Aider waits for you; it can't tell when you answer."),
    (AGENTS, "docs/guides/opencode.md", "opencode", "opencode",
     "An opencode plugin: a card when a session asks for permission, asks a question or goes idle."),
    (AGENTS, "docs/guides/orca.md", "orca", "Orca",
     "Orca agents and automations on one or many servers: the Terminal button, keys, a hand-off example."),
    (AGENTS, "docs/guides/mcp.md", "mcp", "MCP server",
     "A stdlib-Python MCP server so agents without a shell can post, resolve and run doctor through MCP tools."),
    (AGENTS, "docs/guides/custom-connector.md", "custom-connector", "Custom connector",
     "Connect any agent or tool: the exact item format, and which fields are required or optional."),
    (SENDERS, "docs/guides/add-a-sender.md", "add-a-sender", "Add a sender",
     "Invite links, the installer's options, CI and cron, removing a sender."),
    (SENDERS, "docs/guides/tailscale.md", "tailscale", "Tailscale",
     "Putting the Mac and your servers on one tailnet, and checking they can reach each other."),
    (SENDERS, "docs/guides/github.md", "github", "GitHub",
     "Review requests, deploy approvals, failed CI and your PRs' state, from one poller."),
    (SENDERS, "docs/guides/linear.md", "linear", "Linear",
     "Assignments, comments, mentions and status changes from your Linear inbox, from one poller."),
    (RUN, "docs/HUB.md", "hub", "Server hubs",
     "Optional always-on server hubs: install, two-hub setup, backups, upgrades, resource use."),
    (RUN, "docs/guides/updates.md", "updates", "Keeping up to date",
     "Keeping up to date: the Mac app updating itself, needs-you update on senders, rollouts."),
    (RUN, "docs/guides/troubleshooting.md", "troubleshooting", "Troubleshooting",
     "When an item doesn't show up: needs-you doctor, reachability, hooks."),
    (REFERENCE, "docs/AGENT-GUIDE.md", "agent-guide", "Agent guide",
     "The sender contract: when agents should post, keys, rules, and resolving what they posted."),
    (REFERENCE, "docs/API.md", "api", "API",
     "The hub's HTTP API (v1): every endpoint, field, status code and the replication format."),
]


def published():
    """CURATED entries that exist plus any other docs/guides/*.md under MORE, in GROUPS order."""
    out = [g for g in CURATED if os.path.isfile(os.path.join(ROOT, g[1]))]
    listed = {g[1] for g in CURATED}
    gdir = os.path.join(ROOT, "docs", "guides")
    for name in sorted(os.listdir(gdir)):
        src = "docs/guides/" + name
        if not name.endswith(".md") or src in listed:
            continue
        with open(os.path.join(gdir, name), encoding="utf-8") as fh:
            text = fh.read()
        m = re.search(r"^# (.+)$", text, re.M)
        title = m.group(1).strip() if m else name[:-3]
        para = next((b for b in re.split(r"\n\s*\n", text[m.end():] if m else text)
                     if b.strip() and not re.match(r"\s*(?:[#|<>`-]|\d+\.)", b)), "")
        summary = re.sub(r"[`*_]|\[([^\]]*)\]\([^)]*\)", lambda x: x.group(1) or "", " ".join(para.split()))
        if len(summary) > 200:
            summary = summary[:197].rsplit(" ", 1)[0] + "..."
        out.append((MORE, src, name[:-3], title, summary or title))
    # A stable sort: the groups in GROUPS order, CURATED order (then by file name) inside each.
    return sorted(out, key=lambda g: GROUPS.index(g[0]))


GUIDES = published()
PAGE_OF = {src: name for _, src, name, _, _ in GUIDES}
SHORT = {name: short for _, _, name, short, _ in GUIDES}


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as fh:
        return fh.read()


def repo_url():
    m = re.search(r'^var REPO_URL = "([^"]+)";$', read("site/site.js"), re.M)
    if not m:
        raise SystemExit("REPO_URL not found in site/site.js")
    return m.group(1)


def favicon():
    m = re.search(r'^\s*(<link rel="icon" [^>]+>)$', read("site/index.html"), re.M)
    if not m:
        raise SystemExit("favicon <link> not found in site/index.html")
    return m.group(1)


def esc(s):
    return html.escape(s, quote=True)


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    return struct.unpack(">II", head[16:24])


class BuildError(Exception):
    pass


# ---- inline ----

CODE_SPAN = re.compile(r"(`+)(.+?)(?<!`)\1(?!`)", re.S)
LINK = re.compile(r"\[((?:[^\[\]\\]|\\.|\[[^\[\]]*\])*)\]\(\s*<?([^\s()<>]*(?:\([^\s()]*\)[^\s()<>]*)*)>?(?:\s+\"[^\"]*\")?\s*\)")
ESCAPE = re.compile(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])")
AUTOLINK = re.compile(r"(?<![\w/\"'=])https://[^\s<>()\[\]`]*[^\s<>()\[\]`.,;:!?'\"*_]")
ENTITY = re.compile(r"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")
BOLD = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
ITALIC = re.compile(r"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])")
ITALIC_U = re.compile(r"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])")
TOKEN = re.compile("\x00(\\d+)\x00")


def plain_text(s):
    """Escaped text: entities to characters (so &lt; shows as <), then HTML-escaped."""
    s = ENTITY.sub(lambda m: html.unescape(m.group(0)), s)
    return html.escape(s, quote=False)


def emphasis(s):
    s = BOLD.sub(r"<strong>\1</strong>", s)
    s = ITALIC.sub(r"<em>\1</em>", s)
    return ITALIC_U.sub(r"<em>\1</em>", s)


class Doc:
    """One markdown file rendered to HTML. Collects heading ids and links for checking."""

    def __init__(self, src, builder):
        self.src = src
        self.b = builder
        self.ids = []
        self.links = []  # (target page or None for this one, fragment) to check after all pages
        self.h1 = None
        self.headings = []  # (id, html) of each h2, for the table of contents

    # Inline: code spans, links, escapes and bare URLs become placeholders first, so emphasis
    # can wrap them and nothing inside them is touched; the rest is escaped, then emphasis.
    def inline(self, text):
        saved = []

        def keep(fragment):
            saved.append(fragment)
            return "\x00%d\x00" % (len(saved) - 1)

        def code(m):
            body = m.group(2)
            if body.strip() and body[0] == " " and body[-1] == " ":
                body = body[1:-1]
            return keep("<code>%s</code>" % html.escape(body.replace("\n", " "), quote=False))

        def link(m):
            href, attrs = self.resolve(m.group(2))
            label = m.group(1)
            # Link text that's a file name ("tailscale.md", "tailscale.md → Without Tailscale")
            # reads as the page's short title here.
            page = re.match(r"^([\w-]+)\.html(?:#|$)", href)
            if page and page.group(1) in SHORT:
                label = re.sub(r"^[\w./-]+\.md(?= →|$)", SHORT[page.group(1)], label)
            return keep('<a%s href="%s">%s</a>' % (attrs, esc(href), emphasis(plain_text(label))))

        def autolink(m):
            href, attrs = self.resolve(m.group(0))
            return keep('<a%s href="%s">%s</a>' % (attrs, esc(href), esc(m.group(0))))

        # Escapes first so \` and \[ stay literal; code spans keep their backslashes.
        parts = []
        pos = 0
        for m in CODE_SPAN.finditer(text):
            parts.append(ESCAPE.sub(lambda e: keep(esc(e.group(1))), text[pos:m.start()]))
            parts.append(code(m))
            pos = m.end()
        parts.append(ESCAPE.sub(lambda e: keep(esc(e.group(1))), text[pos:]))
        text = "".join(parts)
        text = LINK.sub(link, text)
        text = AUTOLINK.sub(autolink, text)
        text = emphasis(plain_text(text))
        while TOKEN.search(text):
            text = TOKEN.sub(lambda m: saved[int(m.group(1))], text)
        return text

    def resolve(self, url):
        """A markdown link target -> (href, extra attributes)."""
        base = self.b.repo
        if url.startswith(base + "/") or url == base:
            path = url[len(base):]
            return url, ' data-repo="%s"' % esc(path)
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", url):
            if url.startswith("http://"):
                raise BuildError("%s: plain http link %s" % (self.src, url))
            return url, ""
        path, _, frag = url.partition("#")
        if not path:
            self.links.append((None, frag))
            return url, ""
        target = os.path.normpath(os.path.join(os.path.dirname(self.src), path)).replace(os.sep, "/")
        if target.startswith("../") or not os.path.exists(os.path.join(ROOT, target)):
            raise BuildError("%s: link to a missing file %s" % (self.src, url))
        if target in PAGE_OF:
            self.links.append((target, frag))
            return PAGE_OF[target] + ".html" + ("#" + frag if frag else ""), ""
        if target.startswith("site/") and os.path.isfile(os.path.join(ROOT, target)):
            return "../" + target[len("site/"):], ""
        kind = "tree" if os.path.isdir(os.path.join(ROOT, target)) else "blob"
        repo_path = "/%s/main/%s%s" % (kind, target, "#" + frag if frag else "")
        return base + repo_path, ' data-repo="%s"' % esc(repo_path)

    def slug(self, heading_html):
        text = html.unescape(re.sub(r"<[^>]+>", "", heading_html)).strip().lower()
        s = re.sub(r"[^\w\- ]", "", text).replace(" ", "-")
        candidate, n = s, 0
        while candidate in self.ids:
            n += 1
            candidate = "%s-%d" % (s, n)
        self.ids.append(candidate)
        return candidate

    # ---- blocks ----

    def blocks(self, lines, tight=False):
        out = []
        i, n = 0, len(lines)
        while i < n:
            line = lines[i]
            if not line.strip():
                i += 1
                continue
            m = FENCE.match(line)
            if m:
                i = self.fence(lines, i, m, out)
                continue
            m = HEADING.match(line)
            if m:
                self.heading(len(m.group(1)), m.group(2), out)
                i += 1
                continue
            if RULE.match(line):
                out.append("<hr>")
                i += 1
                continue
            if QUOTE.match(line):
                inner = []
                while i < n and lines[i].strip() and (QUOTE.match(lines[i]) or not starts_block(lines[i])):
                    inner.append(QUOTE.sub("", lines[i], count=1))
                    i += 1
                out.append("<blockquote>\n%s\n</blockquote>" % "\n".join(self.blocks(inner)))
                continue
            if i + 1 < n and "|" in line and TABLE_SEP.match(lines[i + 1]) and "|" in lines[i + 1]:
                i = self.table(lines, i, out)
                continue
            m = LIST_ITEM.match(line)
            if m:
                i = self.list(lines, i, out)
                continue
            if IMG_LINE.match(line):
                # A screenshot line, and its caption when the next paragraph is one line
                # of italics ("*Settings → Panel → Opacity, at the defaults.*").
                imgs = self.images(line)
                i += 1
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                cap = CAPTION.match(lines[j]) if j < n else None
                if cap and (j + 1 >= n or not lines[j + 1].strip()):
                    caption = "\n<figcaption>%s</figcaption>" % self.inline(cap.group(1))
                    i = j + 1
                else:
                    caption = ""
                out.append('<figure class="doc-fig">\n<div class="stage">%s</div>%s\n</figure>'
                           % (imgs, caption))
                continue
            para = [line.strip()]
            i += 1
            while i < n and lines[i].strip() and not interrupts(lines[i]):
                para.append(lines[i].strip())
                i += 1
            body = self.inline("\n".join(para))
            out.append(body if tight else "<p>%s</p>" % body)
        return out

    def fence(self, lines, i, m, out):
        indent, marks, lang = len(m.group(1)), m.group(2), m.group(3)
        close = re.compile(r"^ {0,3}%s{%d,}\s*$" % (re.escape(marks[0]), len(marks)))
        body = []
        i += 1
        while i < len(lines) and not close.match(lines[i]):
            ln = lines[i]
            strip = min(indent, len(ln) - len(ln.lstrip(" ")))
            body.append(ln[strip:])
            i += 1
        cls = ' class="language-%s"' % esc(lang) if lang else ""
        text = "\n".join(body)
        if lang == "prompt":  # a prompt to paste into an agent as is: wrapped, with a Copy button
            out.append('<div class="code prompt" data-copy><pre><code>%s</code></pre></div>'
                       % html.escape(text, quote=False))
            return i + 1
        out.append('<div class="code"%s><pre><code%s>%s</code></pre></div>'
                   % (" data-copy" if copyable(lang, text) else "", cls, html.escape(text, quote=False)))
        return i + 1

    def heading(self, level, text, out):
        body = self.inline(text.strip())
        if level == 1 and self.h1 is None:
            self.h1 = body
            return
        level = max(level, 2)
        hid = self.slug(body)
        if level == 2:
            self.headings.append((hid, body))
        out.append('<h%d id="%s">%s <a class="anchor" href="#%s" aria-label="Link to this section">#</a></h%d>'
                   % (level, hid, body, hid, level))

    def table(self, lines, i, out):
        head = split_row(lines[i])
        aligns = []
        for cell in split_row(lines[i + 1]):
            c = cell.strip()
            aligns.append("center" if c.startswith(":") and c.endswith(":")
                          else "right" if c.endswith(":") else "")
        rows = []
        i += 2
        while i < len(lines) and lines[i].strip() and "|" in lines[i]:
            rows.append(split_row(lines[i]))
            i += 1

        def cells(row, tag):
            row = (row + [""] * len(head))[:len(head)]
            return "".join("<%s%s>%s</%s>" % (tag, ' class="ta-%s"' % a if a else "",
                                               self.inline(c.strip()), tag)
                           for c, a in zip(row, aligns + [""] * len(head)))

        body = "\n".join("<tr>%s</tr>" % cells(r, "td") for r in rows)
        out.append('<div class="table-wrap"><table class="doc-table">\n<thead><tr>%s</tr></thead>\n'
                   "<tbody>\n%s\n</tbody>\n</table></div>" % (cells(head, "th"), body))
        return i

    def list(self, lines, i, out):
        first = LIST_ITEM.match(lines[i])
        ordered = first.group(2)[0].isdigit()
        kind = first.group(2)[-1]  # the bullet character, or . / ) for ordered lists
        start = int(first.group(2)[:-1]) if ordered else 1
        items, loose = [], False
        n = len(lines)
        while i < n:
            m = LIST_ITEM.match(lines[i])
            if not m or m.group(2)[0].isdigit() != ordered or m.group(2)[-1] != kind:
                break
            pad = len(m.group(3))
            width = len(m.group(1)) + len(m.group(2)) + (1 if pad > 4 or not m.group(4) else pad)
            body = [m.group(4) if pad <= 4 else " " * (pad - 1) + m.group(4)]
            i += 1
            in_fence = bool(FENCE.match(body[0]))
            while i < n:
                ln = lines[i]
                if not ln.strip():
                    body.append("")
                    i += 1
                    continue
                if len(ln) - len(ln.lstrip(" ")) >= width:
                    body.append(ln[width:])
                    i += 1
                    if FENCE.match(body[-1]):
                        in_fence = not in_fence
                    continue
                if body[-1] == "" or in_fence or starts_block(ln):
                    break
                body.append(ln.strip())  # lazy continuation of the item's paragraph
                i += 1
            trailing = 0
            while body and body[-1] == "":
                body.pop()
                trailing += 1
            nxt = LIST_ITEM.match(lines[i]) if i < n else None
            if trailing and nxt and nxt.group(2)[0].isdigit() == ordered and nxt.group(2)[-1] == kind:
                loose = True
            if has_blank_between_blocks(body):
                loose = True
            items.append(body)
        parts = []
        for body in items:
            task = re.match(r"^\[([ xX])\] +", body[0]) if body else None
            if task:
                body = [body[0][task.end():]] + body[1:]
            inner = "\n".join(self.blocks(body, tight=not loose))
            if task:
                box = '<input type="checkbox" disabled%s aria-label="%s"> ' % (
                    " checked" if task.group(1) != " " else "",
                    "done" if task.group(1) != " " else "to do")
                if loose and inner.startswith("<p>"):
                    inner = "<p>" + box + inner[3:]
                else:
                    inner = box + inner
                parts.append('<li class="task">%s</li>' % inner)
            else:
                parts.append("<li>%s</li>" % inner)
        tag = "ol" if ordered else "ul"
        attrs = ' start="%d"' % start if ordered and start != 1 else ""
        if any(p.startswith('<li class="task">') for p in parts):
            attrs += ' class="tasks"'
        out.append("<%s%s>\n%s\n</%s>" % (tag, attrs, "\n".join(parts), tag))
        return i

    def images(self, line):
        imgs = []
        for tag in IMG_TAG.findall(line):
            attrs = dict(re.findall(r'([a-z]+)="([^"]*)"', tag))
            src, alt = attrs.get("src", ""), attrs.get("alt", "")
            href, _ = self.resolve(src)
            if not href.startswith("../img/") or not alt.strip():
                raise BuildError("%s: images must be in site/img/ and have alt text: %s" % (self.src, src))
            w, h = png_size(os.path.join(SITE, href[3:]))
            width = int(attrs.get("width") or w // 2)
            height = int(round(width * h / float(w)))
            imgs.append('<img src="%s" width="%d" height="%d" alt="%s" loading="lazy" decoding="async">'
                        % (esc(href), width, height, esc(html.unescape(alt))))
        return " ".join(imgs)


FENCE = re.compile(r"^( {0,3})(`{3,}|~{3,})\s*([\w+-]*)\s*$")
HEADING = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
RULE = re.compile(r"^ {0,3}([-*_])(?:\s*\1){2,}\s*$")
QUOTE = re.compile(r"^ {0,3}> ?")
TABLE_SEP = re.compile(r"^ {0,3}\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$")
LIST_ITEM = re.compile(r"^( {0,3})([-*+]|\d{1,9}[.)])( +|$)(.*)$")
IMG_TAG = re.compile(r"<img\s[^>]*>")
IMG_LINE = re.compile(r"^\s*(?:<img\s[^>]*>\s*(?:&nbsp;\s*)?)+$")
CAPTION = re.compile(r"^\s*\*(?!\*)(\S(?:.*\S)?)\*\s*$")


# Copy buttons (site.js adds one to a code block marked data-copy) are only for commands a
# reader can run exactly as written. The real setup commands come from the app's invite
# flow, with the reader's own URL and code in them; a block with a placeholder or an
# example value is there to read, not to paste. So: shell blocks only, and none that
# contain <placeholders>, "...", example hosts or names, tokens or tailnet addresses.
# Erring towards no button is fine.
COPY_LANGS = {"bash", "sh", "shell", "console"}
NOT_AS_IS = re.compile(
    r"<[^<>\n]*>|\.\.\.|…|example\.|\bacme|devbox|build-box|my-server|\bhub-[ab]\b|"
    r"\byour[-_ ]|\bYOUR_|ny_[A-Za-z0-9]|token|tailnet|\b100\.64\.|AAAA|XXXX|--comment\b",
    re.I)


def copyable(lang, body):
    return lang in COPY_LANGS and bool(body.strip()) and not NOT_AS_IS.search(body)


def starts_block(line):
    return bool(FENCE.match(line) or HEADING.match(line) or RULE.match(line) or QUOTE.match(line)
                or LIST_ITEM.match(line))


def interrupts(line):
    """Can this line end a paragraph? (Ordered lists only interrupt when they start at 1.)"""
    m = LIST_ITEM.match(line)
    if m and m.group(4).strip():
        return not m.group(2)[0].isdigit() or m.group(2)[:-1] == "1"
    return bool(FENCE.match(line) or HEADING.match(line) or RULE.match(line) or QUOTE.match(line))


def has_blank_between_blocks(body):
    in_fence = False
    for k, ln in enumerate(body):
        if FENCE.match(ln.lstrip()):
            in_fence = not in_fence
        elif not ln.strip() and not in_fence and 0 < k < len(body) - 1:
            # A blank inside a nested list belongs to that list, not to this item.
            nxt = next((x for x in body[k + 1:] if x.strip()), "")
            if not nxt.startswith(" "):
                return True
    return False


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.replace("\\|", "|") for c in re.split(r"(?<!\\)\|", s)]


# ---- pages ----

HEAD = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <meta name="description" content="{description}">
  <meta name="color-scheme" content="dark light">
  <meta name="theme-color" content="#0d0e10" media="(prefers-color-scheme: dark)">
  <meta name="theme-color" content="#e3e5e8" media="(prefers-color-scheme: light)">
  <link rel="canonical" href="{canonical}">
  {favicon}
  <link rel="stylesheet" href="../styles.css">
  <script src="../site.js" defer></script>
</head>
<body>
  <!-- Generated by scripts/build_site_guides.py from {source}. Edit the markdown, not this file. -->
  <a class="skip" href="#main">Skip to content</a>

  <header class="bar">
    <div class="wrap top">
      <a class="brand" href="../index.html"><span class="dot" aria-hidden="true"></span>needs-you</a>
      <nav aria-label="Primary">
        <a class="nav-wide" href="../index.html#how">How it works</a>
        <a href="index.html"{guides_current}>Guides</a>
        <a href="../index.html#install">Install</a>
        <a data-repo="" href="{repo}">Source</a>
      </nav>
    </div>
  </header>

"""

FOOT = """
  <footer class="wrap foot">
    <p>needs-you &middot; Apache-2.0</p>
  </footer>
</body>
</html>
"""


class Builder:
    def __init__(self):
        self.repo = repo_url()
        self.favicon = favicon()

    def head(self, title, description, page, source, current=False):
        return HEAD.format(title=esc(title), description=esc(description),
                           canonical=esc(ORIGIN + OUT_DIR + "/" + page), favicon=self.favicon,
                           source=source, repo=esc(self.repo),
                           guides_current=' aria-current="page"' if current else "")

    def build(self):
        """Return {path under site/: content} for every generated file."""
        docs = {}
        for _, src, name, _, _ in GUIDES:
            doc = Doc(src, self)
            doc.body = doc.blocks(read(src).splitlines())
            if doc.h1 is None:
                raise BuildError("%s: no # title" % src)
            docs[src] = doc
        for src, doc in sorted(docs.items()):
            for target, frag in doc.links:
                if frag and frag not in docs[target or src].ids:
                    raise BuildError("%s: no #%s in %s" % (src, frag, target or src))
        files = {}
        for group, src, name, _, summary in GUIDES:
            files["%s/%s.html" % (OUT_DIR, name)] = self.page(docs[src], name, summary)
        files[OUT_DIR + "/index.html"] = self.index(docs)
        return files

    def page(self, doc, name, summary):
        title = html.unescape(re.sub(r"<[^>]+>", "", doc.h1))
        parts = [self.head("%s · needs-you guides" % title, summary, name + ".html", doc.src)]
        parts.append('  <main id="main" class="wrap doc">\n')
        parts.append('    <p class="crumb"><a href="index.html">Guides</a></p>\n')
        parts.append("    <h1>%s</h1>\n" % doc.h1)
        if len(doc.headings) >= 4:
            parts.append('    <nav class="toc" aria-label="On this page">\n      <p>On this page</p>\n      <ul>\n')
            for hid, body in doc.headings:
                parts.append('        <li><a href="#%s">%s</a></li>\n' % (hid, re.sub(r"</?a\b[^>]*>", "", body)))
            parts.append("      </ul>\n    </nav>\n")
        parts.append("\n".join(doc.body) + "\n")
        parts.append('    <p class="doc-source note">This page is <a data-repo="/blob/main/{0}" href="{1}/blob/main/{0}">'
                     "{0}</a> in the repo. View or edit it on GitHub.</p>\n".format(doc.src, esc(self.repo)))
        parts.append("  </main>\n")
        parts.append(FOOT)
        return "".join(parts)

    def index(self, docs):
        parts = [self.head("Guides · needs-you",
                           "Guides for needs-you: install the Mac app, connect machines and agents, "
                           "run server hubs, and the sender contract.",
                           "index.html", "the GUIDES list in scripts/build_site_guides.py", current=True)]
        parts.append('  <main id="main" class="wrap doc">\n    <h1>Guides</h1>\n')
        parts.append('    <p class="lede">Setting up needs-you and connecting the things that should alert you. '
                     "New here? Start with the <a href=\"quickstart.html\">quickstart</a>, or the "
                     "<a href=\"testers.html\">tester guide</a> if you were invited to try it.</p>\n")
        for group in [g for g in GROUPS if any(e[0] == g for e in GUIDES)]:
            gid = re.sub(r"[^a-z0-9]+", "-", group.lower()).strip("-")
            parts.append('    <section aria-labelledby="%s">\n      <h2 id="%s">%s</h2>\n      <ul class="guide-list">\n'
                         % (gid, gid, esc(group)))
            for g, src, name, short, summary in GUIDES:
                if g == group:
                    title = esc(short)
                    parts.append('        <li><a href="%s.html">%s</a> <span>%s</span></li>\n'
                                 % (name, title, esc(summary)))
            parts.append("      </ul>\n    </section>\n")
        parts.append('    <p class="doc-source note">These pages are built from the markdown in '
                     '<a data-repo="/tree/main/docs" href="%s/tree/main/docs">docs/</a> on every push to main.</p>\n'
                     % esc(self.repo))
        parts.append("  </main>\n")
        parts.append(FOOT)
        return "".join(parts)


def stale(files):
    """Paths under site/ that differ from what build() makes, or are left over."""
    out = []
    for path, content in sorted(files.items()):
        full = os.path.join(SITE, path)
        try:
            with open(full, encoding="utf-8", newline="") as fh:
                if fh.read() != content:
                    out.append(path)
        except FileNotFoundError:
            out.append(path)
    gen = os.path.join(SITE, OUT_DIR)
    if os.path.isdir(gen):
        for name in sorted(os.listdir(gen)):
            if "%s/%s" % (OUT_DIR, name) not in files:
                out.append("%s/%s (not generated; remove it)" % (OUT_DIR, name))
    return out


def main(argv):
    try:
        files = Builder().build()
    except BuildError as e:
        print("build_site_guides: %s" % e, file=sys.stderr)
        return 2
    if "--check" in argv:
        bad = stale(files)
        for path in bad:
            print("stale: site/%s" % path, file=sys.stderr)
        if bad:
            print("Run: python3 scripts/build_site_guides.py", file=sys.stderr)
        return 1 if bad else 0
    os.makedirs(os.path.join(SITE, OUT_DIR), exist_ok=True)
    for path, content in sorted(files.items()):
        with open(os.path.join(SITE, path), "w", encoding="utf-8", newline="") as fh:
            fh.write(content)
    for path in stale(files):
        os.remove(os.path.join(SITE, path.split(" ")[0]))
    print("built %d pages in site/%s/" % (len(files), OUT_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
