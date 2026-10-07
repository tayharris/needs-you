"""Hard rule 7: the link allow-list lives in two places, the hub and the Mac app's
LinkPolicy.swift, and they must say the same thing. This reads both and compares them,
so a change to one side alone fails here instead of on someone's Mac."""
from __future__ import annotations

import os
import re
import unittest

from support import ROOT, hubmod

LINK_POLICY = os.path.join(ROOT, "mac", "Sources", "NeedsYouCore", "LinkPolicy.swift")


def swift_array(name):
    with open(LINK_POLICY, encoding="utf-8") as fh:
        src = fh.read()
    m = re.search(r"static let %s\s*:[^=]*=\s*\[(.*?)\]" % re.escape(name), src, re.S)
    assert m, "%s not found in LinkPolicy.swift" % name
    return re.findall(r'"([^"]*)"', m.group(1))


class LinkMirrorTests(unittest.TestCase):
    def setUp(self):
        self.hub = hubmod

    def test_schemes_match(self):
        self.assertEqual(sorted(swift_array("allowedSchemes")), sorted(self.hub.LINK_SCHEMES))

    def test_app_actions_match(self):
        self.assertEqual(swift_array("appActionPaths"), list(self.hub.APP_LINK_PATHS))


if __name__ == "__main__":
    unittest.main()
