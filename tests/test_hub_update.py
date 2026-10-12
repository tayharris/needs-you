"""hub/needs_you_hub_update.py (server hubs' automatic updates) and install-hub.sh's settings
for it, end to end against a stand-in GitHub release and a fake `gh`.

Everything runs with a temporary HOME and --no-start, so no real systemd, hub or GitHub is
touched.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

from support import ROOT, drop_python_cache, hubmod

import needs_you_hub_update as upd  # noqa: E402  (support puts hub/ on sys.path)

BASH = shutil.which("bash") or "/bin/bash"
SCRIPT = os.path.join(ROOT, "scripts", "install-hub.sh")
UPDATER = os.path.join(ROOT, "hub", "needs_you_hub_update.py")
NEW = hubmod.VERSION
OLD = "0.0.1"
NOW = datetime.datetime(2026, 10, 12, 12, 0, tzinfo=datetime.timezone.utc)


def rel(tag, prerelease=False, draft=False, published="2026-10-10T12:00:00Z"):
    return {"tag_name": tag, "prerelease": prerelease, "draft": draft, "published_at": published}


class PickRelease(unittest.TestCase):
    def test_stable_takes_the_newest_non_prerelease(self):
        r, _ = upd.pick_release([rel("v0.5.0", prerelease=True), rel("v0.3.2"), rel("v0.3.1")],
                                "stable", "0.3.1", 24, NOW)
        self.assertEqual(r["version"], "0.3.2")

    def test_prerelease_channel_takes_pre_releases_too(self):
        r, _ = upd.pick_release([rel("v0.5.0", prerelease=True), rel("v0.3.2")], "prerelease", "0.3.2", 24, NOW)
        self.assertEqual(r["version"], "0.5.0")

    def test_up_to_date_and_never_a_downgrade(self):
        r, why = upd.pick_release([rel("v0.3.2")], "stable", "0.3.2", 24, NOW)
        self.assertIsNone(r)
        self.assertIn("up to date", why)
        r, _ = upd.pick_release([rel("v0.3.2")], "stable", "0.6.0", 24, NOW)
        self.assertIsNone(r)

    def test_waits_out_the_soak(self):
        r, why = upd.pick_release([rel("v0.3.2", published="2026-10-12T02:00:00Z")], "stable", "0.3.1", 24, NOW)
        self.assertIsNone(r)
        self.assertIn("waiting until 2026-10-13 02:00 UTC", why)
        r, _ = upd.pick_release([rel("v0.3.2", published="2026-10-12T02:00:00Z")], "stable", "0.3.1", 0, NOW)
        self.assertEqual(r["version"], "0.3.2")

    def test_drafts_odd_tags_and_junk_are_skipped(self):
        junk = [rel("v9.9.9", draft=True), rel("v1.0.0-beta.1"), rel("nightly"), rel("v2.0.0", published="x"),
                {"tag_name": "v3.0.0", "prerelease": False}, "x", None,
                {"tag_name": "v4.0.0", "draft": None, "prerelease": False, "published_at": "2026-10-01T00:00:00Z"}]
        r, why = upd.pick_release(junk + [rel("v0.3.2")], "stable", "0.3.1", 24, NOW)
        self.assertEqual(r["version"], "0.3.2")
        self.assertIsNone(upd.pick_release("not a list", "stable", "0.3.1", 24, NOW)[0])

    def test_semver_order_not_string_order(self):
        r, _ = upd.pick_release([rel("v0.10.0"), rel("v0.9.0")], "stable", "0.9.0", 24, NOW)
        self.assertEqual(r["version"], "0.10.0")


class Settings(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="needs-you-hu-")
        self.addCleanup(shutil.rmtree, self.dir, True)

    def write(self, obj):
        with open(os.path.join(self.dir, "hub-update.json"), "w") as fh:
            fh.write(obj if isinstance(obj, str) else json.dumps(obj))

    def test_missing_or_malformed_means_off(self):
        self.assertFalse(upd.load_settings(self.dir)["auto_update"])
        for bad in ("{", "[]", {"auto_update": True, "channel": "nightly"},
                    {"auto_update": True, "soak_hours": -1}, {"auto_update": True, "soak_hours": True},
                    {"auto_update": True, "gh": "gh"}, {"auto_update": "yes"}):
            self.write(bad)
            self.assertFalse(upd.load_settings(self.dir)["auto_update"], bad)

    def test_good_settings(self):
        self.write({"auto_update": True, "channel": "prerelease", "soak_hours": 2, "gh": "/usr/bin/gh"})
        s = upd.load_settings(self.dir)
        self.assertEqual((s["auto_update"], s["channel"], s["soak_hours"], s["gh"]),
                         (True, "prerelease", 2, "/usr/bin/gh"))


class HubUpdate(unittest.TestCase):
    """A hub installed from this checkout, its VERSION set back to OLD, then updated to a
    stand-in release v<NEW> built from this checkout."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="needs-you-hu-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.tmp, "stub"))
        os.makedirs(self.home)
        self.env = {"HOME": self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
        self.prefix = os.path.join(self.home, ".local", "share", "needs-you")
        self.conf = os.path.join(self.home, ".config", "needs-you")
        self.addCleanup(drop_python_cache, self.home)

    def install(self, *flags, ok=True):
        r = subprocess.run([BASH, SCRIPT, "--user", "--no-start", "--no-invite", "--bind", "127.0.0.1",
                            "--port", "48799", "--hub-id", "srv", "--public-url", "http://127.0.0.1:48799"]
                           + list(flags), env=self.env, capture_output=True, text=True, timeout=120)
        if ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def settings(self):
        with open(os.path.join(self.conf, "hub-update.json")) as fh:
            return json.load(fh)

    def set_installed(self, version):
        p = os.path.join(self.prefix, "hub", "needs_you_hub.py")
        with open(p) as fh:
            text = fh.read()
        with open(p, "w") as fh:
            fh.write(re.sub(r'^VERSION = "[^"]*"', 'VERSION = "%s"' % version, text, count=1, flags=re.M))

    def release(self, hub_version=None, tamper=None, runner="github-hosted", published="2026-10-10T12:00:00Z",
                prerelease=False, attests=True):
        """Stand-in release v<NEW>: install-hub.sh, the server tarball, release-manifest.json and
        SHA256SUMS; a fake gh serving it. Returns the gh path."""
        out = os.path.join(self.tmp, "release")
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        tarball = "needs-you-server-%s.tar.gz" % NEW
        src = os.path.join(self.tmp, "src")
        shutil.rmtree(src, ignore_errors=True)
        for d in ("hub", "cli", "scripts", "deploy", "integrations"):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(src, d),
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        if hub_version:
            p = os.path.join(src, "hub", "needs_you_hub.py")
            with open(p) as fh:
                text = fh.read()
            with open(p, "w") as fh:
                fh.write(re.sub(r'^VERSION = "[^"]*"', 'VERSION = "%s"' % hub_version, text, count=1, flags=re.M))
        with tarfile.open(os.path.join(out, tarball), "w:gz") as tf:
            for d in ("hub", "cli", "scripts", "deploy", "integrations"):
                tf.add(os.path.join(src, d), "needs-you-%s/%s" % (NEW, d))
        shutil.copy(SCRIPT, os.path.join(out, "install-hub.sh"))
        if tamper == "installer":
            with open(os.path.join(out, "install-hub.sh"), "a") as fh:
                fh.write("\n# changed after the sums\n")

        def sha(name):
            with open(os.path.join(out, name), "rb") as fh:
                return hashlib.sha256(fh.read()).hexdigest()
        assets = [{"name": n, "sha256": sha(n)} for n in (tarball, "install-hub.sh")]
        if tamper == "installer":
            assets[1]["sha256"] = "0" * 64
        with open(os.path.join(out, "release-manifest.json"), "w") as fh:
            json.dump({"schema": 1, "version": NEW, "assets": assets}, fh)
        with open(os.path.join(out, "SHA256SUMS"), "w") as fh:
            for n in (tarball, "install-hub.sh", "release-manifest.json"):
                fh.write("%s  %s\n" % ("0" * 64 if tamper == "installer" and n == "install-hub.sh" else sha(n), n))
        with open(os.path.join(self.tmp, "releases.json"), "w") as fh:
            json.dump([{"tag_name": "v" + NEW, "draft": False, "prerelease": prerelease, "published_at": published},
                       {"tag_name": "v" + OLD, "draft": False, "prerelease": False,
                        "published_at": "2026-01-01T00:00:00Z"}], fh)
        self.gh_log = os.path.join(self.tmp, "gh.log")
        gh = os.path.join(self.tmp, "stub", "gh")
        with open(gh, "w") as fh:
            fh.write("""#!/bin/sh
# fake gh: the release list, release download from the stand-in, attestations that name the
# file's own sha256 (from RUNNER), and an attestation --help of a new or old gh.
echo "$*" >> "%(log)s"
case "$1 $2" in
  "api repos/tayharris/needs-you/releases?per_page=30") cat "%(list)s" ;;
  "release download")
    dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    cp "%(out)s"/* "$dir"/ ;;
  "attestation verify")
    if [ "$3" = --help ]; then
      [ -n "%(attests)s" ] || { echo 'unknown command "attestation" for "gh"' >&2; exit 1; }
      echo "  --source-ref string"; echo "  --deny-self-hosted-runners"; exit 0
    fi
    file=$3; ref=""; prev=""
    for a in "$@"; do [ "$prev" = --source-ref ] && ref=$a; prev=$a; done
    sum=$( (sha256sum "$file" 2>/dev/null || shasum -a 256 "$file") | cut -d' ' -f1)
    printf '[{"verificationResult":{"statement":{"subject":[{"digest":{"sha256":"%%s"}}],"predicateType":"https://slsa.dev/provenance/v1"},"signature":{"certificate":{"sourceRepositoryURI":"https://github.com/tayharris/needs-you","sourceRepositoryRef":"%%s","buildSignerURI":"https://github.com/tayharris/needs-you/.github/workflows/release.yml@%%s","runnerEnvironment":"%(runner)s"}}}}]\\n' "$sum" "$ref" "$ref" ;;
  "api repos/tayharris/needs-you") echo false ;;
  *) exit 2 ;;
esac
""" % {"log": self.gh_log, "list": os.path.join(self.tmp, "releases.json"), "out": out,
                     "attests": "1" if attests else "", "runner": runner})
        os.chmod(gh, 0o755)
        return gh

    def update(self, gh=None, *flags):
        env = dict(self.env, NEEDS_YOU_HUB_UPDATE_NOW="2026-10-12T12:00:00Z")
        if gh is not None:
            env["NEEDS_YOU_GH"] = gh
        return subprocess.run([sys.executable, UPDATER, "--mode", "user", "--no-start"] + list(flags),
                              env=env, capture_output=True, text=True, timeout=300)

    def installed(self):
        return upd.installed_version(self.prefix)

    # --- install-hub.sh's settings ---

    def test_install_turns_updates_on_and_keeps_the_choice(self):
        r = self.install()
        s = self.settings()
        self.assertEqual(s, {"auto_update": True, "channel": "stable", "soak_hours": 24, "gh": ""})
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.conf, "hub-update.json")).st_mode), 0o600)
        self.assertIn("Automatic updates: on (stable channel, 24 h after a release", r.stdout)
        self.assertTrue(os.path.isfile(os.path.join(self.prefix, "hub", "needs_you_hub_update.py")))
        units = os.path.join(self.home, ".config", "systemd", "user")
        with open(os.path.join(units, "needs-you-hub-update.service")) as fh:
            unit = fh.read()
        self.assertIn('--mode user --prefix "%s"' % self.prefix, unit)
        self.assertIn('--conf-dir "%s"' % self.conf, unit)
        self.assertTrue(os.path.isfile(os.path.join(units, "needs-you-hub-update.timer")))

        self.install("--no-auto-update", "--update-channel", "prerelease", "--update-soak-hours", "2")
        self.assertEqual(self.settings(), {"auto_update": False, "channel": "prerelease", "soak_hours": 2, "gh": ""})
        r = self.install()  # a re-run without the flags, as the updater does, keeps them
        self.assertEqual(self.settings()["auto_update"], False)
        self.assertEqual(self.settings()["channel"], "prerelease")
        self.assertIn("Automatic updates: off", r.stdout)

    def test_bad_update_flags_are_refused(self):
        for flags in (["--update-channel", "nightly"], ["--update-soak-hours", "-1"], ["--update-soak-hours", "1000"],
                      ["--update-soak-hours", "2h"], ["--update-gh", "gh"], ["--update-gh", "/nonexistent/gh"]):
            r = self.install(*flags, ok=False)
            self.assertNotEqual(r.returncode, 0, flags)
            self.assertFalse(os.path.exists(os.path.join(self.conf, "hub.json")), flags)

    # --- the updater ---

    def test_updates_to_the_checked_release(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("release v%s checked (SHA256SUMS, manifest, build provenance); upgrading from %s" % (NEW, OLD),
                      r.stdout)
        self.assertIn("upgraded the hub from %s to %s" % (OLD, NEW), r.stdout)
        self.assertEqual(self.installed(), NEW)
        self.assertEqual(upd.installed_version(self.prefix + ".previous"), OLD)
        self.assertEqual(self.settings()["soak_hours"], 0, "the re-run kept the settings")
        with open(self.gh_log) as fh:
            calls = fh.read()
        self.assertIn("--deny-self-hosted-runners", calls)
        self.assertIn("--source-ref refs/tags/v%s" % NEW, calls)
        # nothing more to do the next time
        r = self.update(self.release())
        self.assertEqual(r.returncode, 0)
        self.assertIn("up to date", r.stdout)

    def test_check_changes_nothing(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release(), "--check")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("would install %s" % NEW, r.stdout)
        self.assertEqual(self.installed(), OLD)

    def test_off_does_nothing(self):
        self.install("--no-auto-update", "--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release())
        self.assertEqual(r.returncode, 0)
        self.assertIn("automatic updates are off", r.stdout)
        self.assertEqual(self.installed(), OLD)
        self.assertFalse(os.path.exists(self.gh_log))

    def test_soak_and_channel(self):
        self.install()  # 24 h soak
        self.set_installed(OLD)
        r = self.update(self.release(published="2026-10-12T06:00:00Z"))
        self.assertEqual(r.returncode, 0)
        self.assertIn("waiting until 2026-10-13 06:00 UTC", r.stdout)
        self.assertEqual(self.installed(), OLD)
        r = self.update(self.release(prerelease=True))
        self.assertIn("up to date (%s; newest on the stable channel is %s)" % (OLD, OLD), r.stdout)
        self.assertEqual(self.installed(), OLD)

    def test_no_gh_or_an_old_gh_installs_nothing(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update("/nonexistent/gh")
        self.assertEqual(r.returncode, 1)
        self.assertIn("need gh 2.64 or later", r.stdout)
        r = self.update(self.release(attests=False))
        self.assertEqual(r.returncode, 1)
        self.assertIn("is too old", r.stdout)
        self.assertEqual(self.installed(), OLD)

    def test_a_self_hosted_build_or_tampered_installer_installs_nothing(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release(runner="self-hosted"))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("build provenance doesn't fit", r.stdout)
        r = self.update(self.release(tamper="installer"))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("doesn't match its SHA256SUMS", r.stdout)
        self.assertEqual(self.installed(), OLD)
        self.assertFalse(os.path.exists(self.prefix + ".previous"))

    def test_a_release_that_installs_the_wrong_version_is_rolled_back(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release(hub_version="0.0.2"))
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("putting %s back" % OLD, r.stdout)
        self.assertIn("rolled back to %s" % OLD, r.stdout)
        self.assertEqual(self.installed(), OLD)

    def test_a_planted_checkout_next_to_the_download_is_never_used(self):
        # install-hub.sh run from a real file looks for a checkout one directory up: the
        # updater's private temp dir, never a shared /tmp where anyone could plant hub/.
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        r = self.update(self.release())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("installing release v%s from GitHub" % NEW, r.stdout)

    def test_a_failed_release_is_not_tried_again(self):
        self.install("--update-soak-hours", "0")
        self.set_installed(OLD)
        gh = self.release(hub_version="0.0.2")
        self.assertEqual(self.update(gh).returncode, 1)
        os.remove(self.gh_log)
        r = self.update(gh)
        self.assertEqual(r.returncode, 1)
        self.assertIn("%s failed to install here before and is skipped" % NEW, r.stdout)
        with open(self.gh_log) as fh:
            self.assertNotIn("release download", fh.read())
        self.assertEqual(self.installed(), OLD)

    def test_an_unreadable_settings_file_is_rewritten_off(self):
        self.install()
        with open(os.path.join(self.conf, "hub-update.json"), "w") as fh:
            fh.write("{oops")
        r = self.install()
        self.assertIn("couldn't be read; rewrote it with automatic updates off", r.stderr)
        self.assertFalse(self.settings()["auto_update"])


    # --- update requests (ADR 0013): the hub's hub-update-request flag makes the next run skip
    # the soak (and only the soak); every run writes hub-update-status.json for the hub ---

    def flag(self):
        return os.path.join(self.home, ".local", "state", "needs-you", "hub-update-request")
    def request(self):
        with open(self.flag(), "w") as fh:
            fh.write('{"requested_at": 1}')

    def status(self):
        with open(os.path.join(self.conf, "hub-update-status.json")) as fh:
            return json.load(fh)

    def test_install_writes_the_path_unit(self):
        self.install()
        with open(os.path.join(self.home, ".config", "systemd", "user", "needs-you-hub-update.path")) as fh:
            unit = fh.read()
        self.assertIn("PathExists=%s\n" % self.flag(), unit)
        self.assertIn("Unit=needs-you-hub-update.service", unit)
        self.assertNotIn("@REQUEST@", unit)

    def test_a_request_skips_the_soak_but_not_the_checks(self):
        self.install()  # 24 h soak
        self.set_installed(OLD)
        gh = self.release(published="2026-10-12T06:00:00Z")
        r = self.update(gh)  # the timer: waits
        self.assertIn("waiting until", r.stdout)
        self.assertEqual(self.status()["state"], "up_to_date")
        self.assertFalse(self.status()["requested"])
        self.request()
        r = self.update(gh)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("asked to update now: not waiting out the soak", r.stdout)
        self.assertEqual(self.installed(), NEW)
        self.assertFalse(os.path.lexists(self.flag()))
        st = self.status()
        self.assertEqual((st["state"], st["requested"], st["target"], st["from_version"]), ("updated", True, NEW, OLD))
        self.assertIsNotNone(st["finished_at"])
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.conf, "hub-update-status.json")).st_mode), 0o600)

    def test_a_request_never_skips_provenance(self):
        self.install()
        self.set_installed(OLD)
        self.request()
        r = self.update(self.release(runner="self-hosted"))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.installed(), OLD)
        st = self.status()
        self.assertEqual((st["state"], st["requested"]), ("failed", True))
        self.assertIn("provenance", st["message"])

    def test_requests_too_close_together_run_as_the_timer(self):
        self.install()
        self.set_installed(OLD)
        gh = self.release(published="2026-10-12T06:00:00Z")
        self.request()
        self.update(gh, "--no-start")  # requested: installs NEW
        self.set_installed(OLD)
        self.request()
        r = self.update(gh)
        self.assertIn("within 10 minutes", r.stdout)
        self.assertIn("waiting until", r.stdout)
        self.assertEqual(self.installed(), OLD)
        self.assertFalse(os.path.lexists(self.flag()))

    def test_off_ignores_a_request(self):
        self.install("--no-auto-update")
        self.set_installed(OLD)
        self.request()
        r = self.update(self.release())
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.installed(), OLD)
        self.assertFalse(os.path.lexists(self.flag()))
        self.assertEqual(self.status()["state"], "off")

    def test_a_symlink_request_is_removed_not_followed(self):
        self.install()
        self.set_installed(OLD)
        target = os.path.join(self.tmp, "precious")
        with open(target, "w") as fh:
            fh.write("keep")
        os.symlink(target, self.flag())
        r = self.update(self.release(published="2026-10-12T06:00:00Z"))
        self.assertIn("waiting until", r.stdout)  # not a request
        self.assertFalse(os.path.lexists(self.flag()))
        with open(target) as fh:
            self.assertEqual(fh.read(), "keep")

    def test_check_takes_no_request(self):
        self.install()
        self.set_installed(OLD)
        self.request()
        self.update(self.release(), "--check")
        self.assertTrue(os.path.exists(self.flag()))
        self.assertFalse(os.path.exists(os.path.join(self.conf, "hub-update-status.json")))


class Rollback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="needs-you-hu-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def make_code(self, path, version):
        os.makedirs(os.path.join(path, "hub"))
        with open(os.path.join(path, "hub", "needs_you_hub.py"), "w") as fh:
            fh.write('VERSION = "%s"\n' % version)

    def make_db(self, path, schema):
        import sqlite3
        conn = sqlite3.connect(path)
        conn.execute("PRAGMA user_version = %d" % schema)
        conn.commit()
        conn.close()

    def test_puts_the_code_and_a_migrated_database_back(self):
        prefix, previous = os.path.join(self.tmp, "share"), os.path.join(self.tmp, "share.previous")
        self.make_code(prefix, "0.9.0")
        self.make_code(previous, "0.8.0")
        db = os.path.join(self.tmp, "hub.db")
        self.make_db(db, 12)                 # migrated by the new version
        self.make_db(db + ".bak-11", 11)     # the hub's own backup from before
        with open(db + "-wal", "w") as fh:
            fh.write("stale")
        args = type("A", (), {"prefix": prefix, "no_start": True, "mode": "user"})()
        self.assertTrue(upd.rollback(args, previous, db, 11, "0.8.0"))
        self.assertEqual(upd.installed_version(prefix), "0.8.0")
        self.assertFalse(os.path.exists(previous))
        self.assertEqual(upd.schema_version(db), 11)
        self.assertFalse(os.path.exists(db + "-wal"))

    def test_a_migrated_database_without_its_backup_fails_loudly(self):
        prefix, previous = os.path.join(self.tmp, "share"), os.path.join(self.tmp, "share.previous")
        self.make_code(prefix, "0.9.0")
        self.make_code(previous, "0.8.0")
        db = os.path.join(self.tmp, "hub.db")
        self.make_db(db, 12)
        args = type("A", (), {"prefix": prefix, "no_start": True, "mode": "user"})()
        self.assertFalse(upd.rollback(args, previous, db, 11, "0.8.0"))
        self.assertEqual(upd.schema_version(db), 12, "left as it was")


if __name__ == "__main__":
    unittest.main()
