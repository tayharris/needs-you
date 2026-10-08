"""site/guides/: the guide pages generated from docs/ by scripts/build_site_guides.py.

The committed pages must match the markdown (a forgotten rebuild fails here, and so in CI),
every guide in docs/guides/ is published, and the markdown renderer escapes HTML, rewrites
links and makes GitHub's heading anchors. Link and hostname checks for the pages themselves
are in test_site.py.
"""
from __future__ import annotations

import importlib.util
import os
import re
import sys
import unittest

from support import ROOT

SCRIPT = os.path.join(ROOT, "scripts", "build_site_guides.py")


def load():
    sys.dont_write_bytecode = True  # no __pycache__ in scripts/
    spec = importlib.util.spec_from_file_location("build_site_guides", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = load()


def render(md, src="docs/guides/example.md"):
    doc = gen.Doc(src, gen.Builder())
    return "\n".join(doc.blocks(md.splitlines())), doc


class FreshnessTests(unittest.TestCase):
    def test_pages_match_the_markdown(self):
        stale = gen.stale(gen.Builder().build())
        self.assertEqual(stale, [], "run: python3 scripts/build_site_guides.py")

    def test_deterministic(self):
        self.assertEqual(gen.Builder().build(), gen.Builder().build())

    def test_every_guide_is_published(self):
        published = {src for _, src, _, _, _ in gen.GUIDES}
        for name in os.listdir(os.path.join(ROOT, "docs", "guides")):
            if name.endswith(".md"):
                self.assertIn("docs/guides/" + name, published)
        for src in ("docs/HUB.md", "docs/AGENT-GUIDE.md", "docs/API.md"):
            self.assertIn(src, published)

    def test_index_order_for_a_first_time_reader(self):
        names = [name for _, _, name, _, _ in gen.GUIDES]
        self.assertEqual(names[:3], ["quickstart", "testers", "concepts"])
        groups = [g for g, _, _, _, _ in gen.GUIDES]
        self.assertEqual(groups, sorted(groups, key=gen.GROUPS.index))  # sections in GROUPS order
        self.assertLess(names.index("claude-code"), names.index("hub"))
        self.assertLess(names.index("hub"), names.index("api"))
        index = gen.Builder().build()["guides/index.html"]
        self.assertLess(index.index('href="quickstart.html"'), index.index('href="claude-code.html"'))
        self.assertLess(index.index('href="claude-code.html"'), index.index('href="hub.html"'))

    def test_unlisted_guide_goes_under_more_guides(self):
        self.assertIn(gen.MORE, gen.GROUPS)
        listed = {src for _, src, _, _, _ in gen.CURATED}
        for g, src, _, _, _ in gen.GUIDES:
            if src not in listed:
                self.assertEqual(g, gen.MORE, src)

    def test_index_links_every_page(self):
        index = gen.Builder().build()["guides/index.html"]
        for _, _, name, _, _ in gen.GUIDES:
            self.assertIn('href="%s.html"' % name, index)

    def test_landing_page_links_the_setup_guides(self):
        with open(os.path.join(ROOT, "site", "index.html"), encoding="utf-8") as fh:
            html = fh.read()
        for page in ("index", "quickstart", "testers", "tailscale", "claude-code", "codex",
                     "gemini", "opencode", "orca", "add-a-sender"):
            self.assertIn('href="guides/%s.html"' % page, html)


class RenderTests(unittest.TestCase):
    def test_html_is_escaped(self):
        out, _ = render('Hello <script>alert(1)</script> & <b>x</b>\n\n<div onclick="x">y</div>')
        self.assertNotIn("<script>", out)
        self.assertNotIn("<b>", out)
        self.assertNotIn("<div", out)
        self.assertIn("&lt;script&gt;", out)
        self.assertIn("&amp;", out)

    def test_code_is_escaped_and_kept(self):
        out, _ = render("```bash\necho '<x>' && **not bold**\n```\n\nRun `a <b> *c*`.")
        self.assertIn('<code class="language-bash">echo \'&lt;x&gt;\' &amp;&amp; **not bold**</code>', out)
        self.assertIn("<code>a &lt;b&gt; *c*</code>", out)

    def test_copy_only_on_commands_that_run_as_written(self):
        # site.js adds a Copy button to .code[data-copy] only. Real setup commands come from
        # the app's invite flow; examples with placeholders or example values get none.
        runnable = ["```bash\nneeds-you doctor\n```", "```sh\nneeds-you update --check\n```"]
        examples = ["```bash\ncurl -fsSL <join_url>/install.sh | bash\n```",
                    "```bash\nneeds-you add --key \"claude-code:devbox:acme-api\" --title x\n```",
                    "```bash\nexport NEEDS_YOU_TOKEN=ny_abc123\n```",
                    "```bash\ncurl http://hub-a.example.ts.net:8765/v1/health\n```",
                    "```bash\nneeds-you add ... --title x\n```",
                    "```json\n{\"title\": \"x\"}\n```", "```\nneeds-you doctor\n```"]
        for md in runnable:
            self.assertIn('<div class="code" data-copy>', render(md)[0], md)
        for md in examples:
            self.assertNotIn("data-copy", render(md)[0], md)

    def test_entities_render_as_text(self):
        out, _ = render("needs &lt;name&gt;")
        self.assertIn("needs &lt;name&gt;", out)

    def test_only_site_images(self):
        out, _ = render('<img src="../../site/img/panel.png" width="100" alt="The panel">')
        self.assertIn('<img src="../img/panel.png" width="100" height="246" alt="The panel" loading="lazy"', out)
        with self.assertRaises(gen.BuildError):
            render('<img src="https://example.com/x.png" width="10" alt="x">')

    def test_screenshot_figures_and_captions(self):
        # A screenshot line becomes a figure on a stage; a one-line italic paragraph right
        # after it becomes its caption. Any other paragraph stays a paragraph.
        img = '<img src="../../site/img/panel.png" width="100" alt="The panel">'
        out, _ = render(img + "\n\n*Settings → Panel, at the defaults.*\n\nNext.")
        self.assertIn('<figure class="doc-fig">\n<div class="stage"><img src="../img/panel.png"', out)
        self.assertIn("<figcaption>Settings → Panel, at the defaults.</figcaption>\n</figure>", out)
        self.assertIn("<p>Next.</p>", out)
        out, _ = render(img + "\n\nA plain paragraph.")
        self.assertNotIn("<figcaption>", out)
        self.assertIn("<p>A plain paragraph.</p>", out)

    def test_headings_get_github_anchors(self):
        out, doc = render("# Title\n\n## 1. Install the Mac app (it runs its own hub)\n\n"
                          "## Start here: `needs-you doctor`\n\n## Options\n\n## Options")
        self.assertEqual(doc.ids, ["1-install-the-mac-app-it-runs-its-own-hub",
                                   "start-here-needs-you-doctor", "options", "options-1"])
        self.assertIn("Title", doc.h1)
        self.assertNotIn("<h1", out)

    def test_links(self):
        out, doc = render("[a](tailscale.md#4-check-reachability) [b](../HUB.md) "
                          "[c](../../integrations/ci/README.md) [d](../roadmap/) "
                          "[e](https://tailscale.com) [f](https://github.com/tayharris/needs-you/releases)")
        self.assertIn('<a href="tailscale.html#4-check-reachability">a</a>', out)
        self.assertIn('<a href="hub.html">b</a>', out)
        self.assertIn('data-repo="/blob/main/integrations/ci/README.md"', out)
        self.assertIn('data-repo="/tree/main/docs/roadmap"', out)
        self.assertIn('<a href="https://tailscale.com">e</a>', out)
        self.assertIn('data-repo="/releases"', out)

    def test_file_name_links_read_as_titles(self):
        out, _ = render("[tailscale.md](tailscale.md) and [tailscale.md → Without](tailscale.md#a-machine-without-tailscale)")
        self.assertIn('<a href="tailscale.html">Tailscale</a>', out)
        self.assertIn(">Tailscale → Without</a>", out)

    def test_broken_links_fail_the_build(self):
        with self.assertRaises(gen.BuildError):
            render("[x](no-such-guide.md)")
        with self.assertRaises(gen.BuildError):
            render("[x](http://example.com)")

    def test_lists_tables_quotes(self):
        out, _ = render("1. one\n2. two\n   - nested `x`\n\n- [ ] task\n\n"
                        "| A | B |\n|---|--:|\n| `a\\|b` | **2** |\n\n> **Note:** quoted")
        self.assertIn("<ol>\n<li>one</li>\n<li>two\n<ul>\n<li>nested <code>x</code></li>\n</ul></li>\n</ol>", out)
        self.assertIn('<input type="checkbox" disabled aria-label="to do">', out)
        self.assertIn("<td><code>a|b</code></td>", out)
        self.assertIn('<td class="ta-right"><strong>2</strong></td>', out)
        self.assertIn('<div class="table-wrap">', out)
        self.assertIn("<blockquote>\n<p><strong>Note:</strong> quoted</p>\n</blockquote>", out)


class DeployWorkflowTests(unittest.TestCase):
    """.github/workflows/site.yml runs on a self-hosted runner holding a deploy key: never for PRs."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(ROOT, ".github", "workflows", "site.yml"), encoding="utf-8") as fh:
            cls.text = fh.read()
        cls.code = "\n".join(l.split(" #", 1)[0] for l in cls.text.splitlines() if not l.lstrip().startswith("#"))

    def test_only_push_to_main(self):
        on = re.search(r"^on:\n((?:[ ].*\n|\n)+)", self.code, re.M).group(1)
        self.assertNotIn("pull_request", on)
        self.assertNotIn("workflow_run", on)
        self.assertRegex(on, r"push:\n\s+branches: \[main\]")
        self.assertIn("github.ref == 'refs/heads/main'", self.code)
        self.assertIn("environment: site", self.code)

    def test_ssh_is_pinned_and_the_key_is_handled(self):
        self.assertNotRegex(self.code, r"StrictHostKeyChecking[= ]*(?:no|accept-new)")
        self.assertIn("StrictHostKeyChecking=yes", self.code)
        self.assertNotIn("ssh-keyscan", self.code)
        self.assertNotIn("set -x", self.code)
        self.assertIn("persist-credentials: false", self.code)
        self.assertRegex(self.code, r"(?m)^permissions:\n  contents: read$")
        self.assertIn("if: always()", self.code)
        # The key is only in the deploy step's env, after everything that runs repo code.
        self.assertEqual(self.code.count("secrets."), 1)
        self.assertLess(self.code.index("build_site_guides.py"), self.code.index("secrets.SITE_DEPLOY_KEY"))
        self.assertLess(self.code.index("unittest"), self.code.index("secrets.SITE_DEPLOY_KEY"))

    def test_no_host_in_the_workflow(self):
        # Rule 5: the server comes from repo variables, never the file.
        self.assertIn("vars.SITE_DEPLOY_TARGET", self.code)
        self.assertNotRegex(self.code, r"\b[\w-]+@[\w.-]+:")


if __name__ == "__main__":
    unittest.main()
