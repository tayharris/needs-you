"""scripts/build-release.sh and the one-VERSION rule.

Builds from a throwaway local clone (git archive reads HEAD there), without the Mac
app (NEEDS_YOU_SKIP_APP=1), into a temporary directory.
"""
from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
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
        self.assertEqual(read_version("integrations/mcp/needs_you_mcp.py"), v)

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
        manifest = "release-manifest.json"
        self.assertEqual(sorted(os.listdir(self.out)),
                         sorted(["NOTES.md", "SHA256SUMS", cli, tarball, manifest]))
        self.assertTrue(os.access(os.path.join(self.out, cli), os.X_OK))

        with open(os.path.join(self.out, "SHA256SUMS")) as fh:
            sums = dict(reversed(line.split()) for line in fh if line.strip())
        self.assertEqual(sorted(sums), sorted([cli, tarball, manifest]))
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

    def test_release_manifest_matches_the_assets(self):
        self.cut_changelog()
        r = self.build(NEEDS_YOU_TAG="v" + self.v, NEEDS_YOU_TESTS_RESULT="success",
                       GITHUB_RUN_ID="123456", GITHUB_RUN_ATTEMPT="2", GITHUB_REPOSITORY="owner/repo",
                       GITHUB_SHA="a" * 40)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.out, "release-manifest.json")) as fh:
            m = json.load(fh)
        self.assertEqual(m["schema"], 1)
        self.assertEqual(m["version"], self.v)
        self.assertEqual(m["tag"], "v" + self.v)
        self.assertEqual(m["commit"], "a" * 40)
        self.assertEqual(m["run_id"], 123456)
        self.assertEqual(m["run_attempt"], 2)
        self.assertEqual(m["repository"], "owner/repo")
        self.assertEqual(m["tests"], "success")
        with open(os.path.join(ROOT, "mac", "Package.swift")) as fh:
            major = re.search(r"\.macOS\(\.v(\d+)\)", fh.read()).group(1)
        self.assertEqual(m["min_macos"], major + ".0")
        with open(os.path.join(self.out, "SHA256SUMS")) as fh:
            sums = dict(reversed(line.split()) for line in fh if line.strip())
        names = [a["name"] for a in m["assets"]]
        self.assertEqual(sorted(names), sorted(n for n in sums if n != "release-manifest.json"))
        for a in m["assets"]:
            path = os.path.join(self.out, a["name"])
            self.assertEqual(a["size"], os.path.getsize(path), a["name"])
            self.assertEqual(a["sha256"], sums[a["name"]], a["name"])

    def test_manifest_defaults_outside_ci(self):
        self.cut_changelog()
        r = self.build(GITHUB_RUN_ID="", GITHUB_SHA="")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.out, "release-manifest.json")) as fh:
            m = json.load(fh)
        self.assertEqual(m["tests"], "local")
        self.assertIsNone(m["run_id"])
        self.assertRegex(m["commit"], r"^[0-9a-f]{40}$")

    def test_refuses_a_non_empty_output_dir(self):
        os.makedirs(self.out)
        open(os.path.join(self.out, "stale"), "w").close()
        r = self.build()
        self.assertEqual(r.returncode, 1)
        self.assertIn("not empty", r.stderr)


class BundleScriptTests(unittest.TestCase):
    def test_bundle_ships_install_sh_for_the_updater(self):
        with open(os.path.join(ROOT, "mac", "scripts", "bundle.sh")) as fh:
            s = fh.read()
        self.assertIn('cp scripts/install.sh "$RES/scripts/install.sh"', s)

    def test_bundle_builds_the_app_icon_and_localized_name(self):
        with open(os.path.join(ROOT, "mac", "scripts", "bundle.sh")) as fh:
            s = fh.read()
        self.assertIn('iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"', s)
        self.assertIn("cp Resources/en.lproj/InfoPlist.strings", s)
        # Built before the signature, so codesign covers both.
        self.assertLess(s.index("iconutil -c icns"), s.index("codesign --force"))
        self.assertLess(s.index("cp Resources/en.lproj/InfoPlist.strings"), s.index("codesign --force"))

    def test_info_plist_names_and_icon(self):
        with open(os.path.join(ROOT, "mac", "Resources", "Info.plist"), "rb") as fh:
            info = plistlib.load(fh)
        self.assertEqual(info["CFBundleIconFile"], "AppIcon")
        self.assertIs(info["LSHasLocalizedDisplayName"], True)
        # Finder and Spotlight use the localized name only when the unlocalized one matches
        # the file name, NeedsYou.app (checked on macOS 15).
        self.assertEqual(info["CFBundleName"], "NeedsYou")
        self.assertEqual(info["CFBundleDisplayName"], "NeedsYou")
        with open(os.path.join(ROOT, "mac", "Resources", "en.lproj", "InfoPlist.strings")) as fh:
            strings = fh.read()
        self.assertIn('"CFBundleDisplayName" = "Needs You";', strings)
        self.assertIn('"CFBundleName" = "Needs You";', strings)

    def test_icon_master_is_1024_rgba_png(self):
        with open(os.path.join(ROOT, "mac", "Resources", "AppIcon.png"), "rb") as fh:
            head = fh.read(33)
        self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n")
        width, height, depth, colour = struct.unpack(">IIBB", head[16:26])
        self.assertEqual((width, height, depth, colour), (1024, 1024, 8, 6))  # 6 = RGBA
        self.assertTrue(os.path.isfile(os.path.join(ROOT, "mac", "Resources", "AppIcon.svg")))

    def test_install_sh_records_rollbacks(self):
        with open(os.path.join(ROOT, "mac", "scripts", "install.sh")) as fh:
            s = fh.read()
        self.assertIn("--record-rollback)", s)
        self.assertEqual(s.count('record_rollback "'), 2)  # --rollback and the auto-restore


if __name__ == "__main__":
    unittest.main()
