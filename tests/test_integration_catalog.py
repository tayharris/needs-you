"""The Mac app's integration catalog (Settings → Integrations) against the pollers.

mac/Sources/NeedsYouCore/Integrations.swift names env vars, scripts and token files for
Linear, Jira, GitHub and expiry. Every name must be one the script really reads, so the
in-app setup and its agent prompts can't drift from the code (IntegrationCatalogTests does
the same, and more, on the Mac).
"""
from __future__ import annotations

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "Integrations.swift")
ENV = re.compile(r"NEEDS_YOU_[A-Z0-9_]*[A-Z0-9]")


def read(*parts: str) -> str:
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def blocks() -> dict:
    """Each `public static let <name> = Integration(...)` block, by its script path."""
    src = read("mac", "Sources", "NeedsYouCore", "Integrations.swift")
    out = {}
    starts = [m.start() for m in re.finditer(r"public static let \w+ = Integration\(", src)]
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(src)
        body = src[start:end]
        script = re.search(r'script: "([a-z]+/needs-you-[a-z]+)"', body)
        assert script, body[:200]
        out.setdefault(script.group(1), []).append(body)
    return out


class IntegrationCatalogTest(unittest.TestCase):
    def test_five_integrations_over_four_scripts(self):
        b = blocks()
        self.assertEqual(sorted(b), ["expiry/needs-you-expiry", "github/needs-you-github",
                                     "jira/needs-you-jira", "linear/needs-you-linear"])
        self.assertEqual(sum(len(v) for v in b.values()), 5)

    def test_every_env_var_is_read_by_its_script(self):
        for script, bodies in blocks().items():
            source = read("integrations", *script.split("/"))
            for body in bodies:
                names = set(ENV.findall(body))
                self.assertTrue(names, script)
                for name in names:
                    self.assertIn('"%s"' % name, source, "%s doesn't read %s" % (script, name))

    def test_shared_prompt_text_names_real_vars_only(self):
        # Outside the blocks (the prompt template, comments): names some poller reads.
        src = read("mac", "Sources", "NeedsYouCore", "Integrations.swift")
        head = src[:src.index("public static let linear = Integration(")]
        sources = [read("integrations", *s.split("/")) for s in blocks()]
        for name in set(ENV.findall(head)):
            self.assertTrue(any('"%s"' % name in src for src in sources), name)

    def test_token_files_are_the_scripts_defaults(self):
        for script, bodies in blocks().items():
            source = read("integrations", *script.split("/"))
            for body in bodies:
                for path in re.findall(r'\.file\(path: "([^"]+)"', body):
                    self.assertIn('"%s"' % os.path.basename(path), source, path)

    def test_launch_agents_exist(self):
        for script in blocks():
            d = script.split("/")[0]
            self.assertTrue(os.path.exists(os.path.join(ROOT, "integrations", d, "io.needs-you.%s.plist" % d)), d)


if __name__ == "__main__":
    unittest.main()
