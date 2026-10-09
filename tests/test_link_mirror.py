"""Hard rule 7: the link allow-list lives in two places, the hub and the Mac app's
LinkPolicy.swift, and they must say the same thing. This reads both and compares them,
so a change to one side alone fails here instead of on someone's Mac."""
from __future__ import annotations

import json
import os
import re
import unittest

from support import ROOT, hubmod

LINK_POLICY = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "LinkPolicy.swift")
CASES = os.path.join(ROOT, "tests", "fixtures", "link_cases.json")
APP_ACTIVATION = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "AppActivation.swift")
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")


def swift_array(name):
    with open(LINK_POLICY, encoding="utf-8") as fh:
        src = fh.read()
    m = re.search(r"static let %s\s*:[^=]*=\s*\[(.*?)\]" % re.escape(name), src, re.S)
    assert m, "%s not found in LinkPolicy.swift" % name
    return re.findall(r'"([^"]*)"', m.group(1))


def swift_string(name):
    """A `static let name: String = #"..."# + #"..."#` declaration, joined."""
    with open(LINK_POLICY, encoding="utf-8") as fh:
        src = fh.read()
    m = re.search(r"static let %s\s*:\s*String\s*=(.*?)\n\s*\n" % re.escape(name), src, re.S)
    assert m, "%s not found in LinkPolicy.swift" % name
    return "".join(re.findall(r'#"(.*?)"#', m.group(1)))


class LinkMirrorTests(unittest.TestCase):
    def setUp(self):
        self.hub = hubmod

    def test_schemes_match(self):
        self.assertEqual(sorted(swift_array("allowedSchemes")), sorted(self.hub.LINK_SCHEMES))

    def test_editor_schemes_match(self):
        self.assertEqual(sorted(swift_array("editorSchemes")), sorted(self.hub.EDITOR_SCHEMES))

    def test_patterns_match(self):
        """Security audit #14: the raw link grammar, the https host rule and the vscode/cursor
        shapes are regexes, byte-identical on both sides (Python re and ICU read this subset
        the same way: classes, (?i:), (?!), {m,n}, no backreferences)."""
        for swift_name, hub_name in (("rawLinkPattern", "LINK_RAW_PATTERN"),
                                     ("httpsHostPattern", "HTTPS_HOST_PATTERN"),
                                     ("editorLinkPattern", "EDITOR_LINK_PATTERN")):
            with self.subTest(swift_name):
                self.assertEqual(swift_string(swift_name), getattr(self.hub, hub_name))

    def test_shared_cases(self):
        """tests/fixtures/link_cases.json, which LinkCasesTests.swift runs against LinkPolicy."""
        with open(CASES, encoding="utf-8") as fh:
            doc = json.load(fh)
        self.assertGreater(len(doc["cases"]), 100)
        for c in doc["cases"]:
            with self.subTest(c["url"]):
                self.assertEqual(self.hub.link_allowed(c["url"]), c["allowed"])
        for c in doc["app_stricter"]:
            with self.subTest(c["url"]):
                # only app actions, and only in the safe direction: the hub takes the prefix,
                # the app's parser refuses the parameters
                self.assertTrue(c["url"].lower().startswith("needsyou://"))
                self.assertTrue(c["hub"] and not c["app"])
                self.assertTrue(self.hub.link_allowed(c["url"]))

    def test_app_actions_match(self):
        self.assertEqual(swift_array("appActionPaths"), list(self.hub.APP_LINK_PATHS))

    def test_activate_allow_list_matches_the_hook(self):
        """needsyou://app/activate: the hook writes only bundle ids the Mac app will bring
        forward (AppActivation.allowedApps), under the same button names."""
        with open(APP_ACTIVATION, encoding="utf-8") as fh:
            src = fh.read()
        m = re.search(r"static let allowedApps\s*:[^=]*=\s*\[(.*?)\n\s*\]", src, re.S)
        self.assertTrue(m)
        swift = dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', m.group(1)))
        with open(HOOK, encoding="utf-8") as fh:
            hook_src = fh.read()
        hook = {}
        for name in ("TERMINAL_APPS", "EDITOR_APPS"):
            m = re.search(r"^%s = \{(.*?)^\}" % name, hook_src, re.S | re.M)
            self.assertTrue(m, name)
            hook.update(re.findall(r'"([^"]+)":\s*"([^"]+)"', m.group(1)))
        self.assertEqual(hook, swift)
        self.assertGreater(len(swift), 10)
        self.assertNotIn("app.needsyou.mac", swift)
        for bid in swift:
            self.assertRegex(bid, r"^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$")
            self.assertTrue(self.hub.link_allowed("needsyou://app/activate?bundle=" + bid))


if __name__ == "__main__":
    unittest.main()
