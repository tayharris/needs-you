"""scripts/build-release.sh and the one-VERSION rule.

Builds from a throwaway local clone (git archive reads HEAD there), without the Mac
app (NEEDS_YOU_SKIP_APP=1), into a temporary directory.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from support import ROOT

BASH = shutil.which("bash") or "/bin/bash"


def read_version(path, pattern=r'^VERSION = "(.*)"$'):
    with open(os.path.join(ROOT, path)) as fh:
        m = re.search(pattern, fh.read(), re.M)
    return m.group(1) if m else None


class VersionTests(unittest.TestCase):
    def test_hub_cli_and_version_file_agree(self):
        with open(os.path.join(ROOT, "VERSION")) as fh:
            v = fh.read().strip()
        self.assertRegex(v, r"^\d+\.\d+\.\d+$")
        self.assertEqual(read_version("hub/needs_you_hub.py"), v)
        self.assertEqual(read_version("cli/needs-you"), v)

    def test_changelog_has_unreleased_or_current_section(self):
        with open(os.path.join(ROOT, "CHANGELOG.md")) as fh:
            self.assertRegex(fh.read(), r"(?m)^## \[(Unreleased|\d+\.\d+\.\d+)\]")


@unittest.skipUnless(shutil.which("git"), "needs git")
class BuildReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ny-release-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        subprocess.run(["git", "clone", "-q", ROOT, self.repo], check=True)
        with open(os.path.join(self.repo, "VERSION")) as fh:
            self.v = fh.read().strip()
        self.out = os.path.join(self.tmp, "out")

    def build(self, **env):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp,
             "NEEDS_YOU_SKIP_APP": "1"}
        e.update(env)
        return subprocess.run([BASH, os.path.join(self.repo, "scripts", "build-release.sh"), self.out],
                              env=e, capture_output=True, text=True, timeout=60)

    def set_changelog_section(self, present):
        """The clone's CHANGELOG with or without a "## [VERSION]" section, whatever the repo has."""
        path = os.path.join(self.repo, "CHANGELOG.md")
        with open(path) as fh:
            s = fh.read()
        heading = "## [%s]" % self.v
        s = s.replace(heading, "## [0.0.0-test]")
        if present:
            s = s.replace("## [Unreleased]", "## [Unreleased]\n\n%s - 2026-10-06\n\n- A change." % heading, 1)
        with open(path, "w") as fh:
            fh.write(s)

    def cut_changelog(self):
        self.set_changelog_section(True)

    def test_refuses_without_a_changelog_section(self):
        self.set_changelog_section(False)
        r = self.build()
        self.assertEqual(r.returncode, 1)
        self.assertIn('no "## [%s]" section' % self.v, r.stderr)

    def test_refuses_a_tag_that_does_not_match(self):
        self.cut_changelog()
        r = self.build(NEEDS_YOU_TAG="v0.0.1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("does not match VERSION", r.stderr)

    def test_builds_server_cli_sums_and_notes(self):
        self.cut_changelog()
        r = self.build(NEEDS_YOU_TAG="v" + self.v)
        self.assertEqual(r.returncode, 0, r.stderr)
        tarball = "needs-you-server-%s.tar.gz" % self.v
        cli = "needs-you-cli-%s" % self.v
        self.assertEqual(sorted(os.listdir(self.out)), sorted(["NOTES.md", "SHA256SUMS", cli, tarball]))
        self.assertTrue(os.access(os.path.join(self.out, cli), os.X_OK))

        with open(os.path.join(self.out, "SHA256SUMS")) as fh:
            sums = dict(reversed(line.split()) for line in fh if line.strip())
        self.assertEqual(sorted(sums), sorted([cli, tarball]))
        for name, digest in sums.items():
            with open(os.path.join(self.out, name), "rb") as fh:
                self.assertEqual(hashlib.sha256(fh.read()).hexdigest(), digest, name)

        with tarfile.open(os.path.join(self.out, tarball)) as tf:
            names = set(tf.getnames())
        prefix = "needs-you-%s/" % self.v
        for want in ("hub/needs_you_hub.py", "cli/needs-you", "scripts/install-hub.sh", "VERSION"):
            self.assertIn(prefix + want, names)
        self.assertFalse([n for n in names if "/mac/" in n or "/.claude/" in n or n.endswith(".db")])

        with open(os.path.join(self.out, "NOTES.md")) as fh:
            notes = fh.read()
        self.assertIn("Open Anyway", notes)
        self.assertIn("xattr -dr com.apple.quarantine", notes)
        self.assertIn("NeedsYou-%s-macos.zip" % self.v, notes)
        self.assertIn("NeedsYou-%s.dmg" % self.v, notes)
        self.assertIn("SHA256SUMS", notes)
        self.assertNotIn("## [", notes)  # the section body only, no headings from other versions

    def test_refuses_a_non_empty_output_dir(self):
        os.makedirs(self.out)
        open(os.path.join(self.out, "stale"), "w").close()
        r = self.build()
        self.assertEqual(r.returncode, 1)
        self.assertIn("not empty", r.stderr)


if __name__ == "__main__":
    unittest.main()
