"""`needs-you update`, the daily auto-update from `flush`, and the X-Needs-You-Client header,
against a fake hub that serves a manifest and files from a dict (so checksums can be
wrong on purpose). The CLI under test is always a copy in a temp dir, never cli/needs-you."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import CLI, ROOT, HubTestCase, free_port, hubmod

HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
HOOKS_JSON = os.path.join(ROOT, "integrations", "claude-code", "hooks.json")
INSTALL_HOOKS = os.path.join(ROOT, "integrations", "claude-code", "install-hooks.sh")
SKILL = os.path.join(ROOT, "integrations", "claude-code", "skill", "needs-you", "SKILL.md")
SNIPPET = os.path.join(ROOT, "integrations", "orca", "snippet.md")


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


class FakeHub:
    def __init__(self, files, version=None, manifest=True, bad=()):
        self.files = dict(files)
        self.version = version or self.cli_version()
        self.manifest = manifest
        self.bad = set(bad)
        self.headers = []
        owner = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                owner.headers.append((self.path, self.headers.get("X-Needs-You-Client")))
                if self.path == "/v1/health":
                    return self.reply(200, json.dumps({"ok": True, "version": owner.version}).encode())
                if self.path == "/dl/manifest.json" and owner.manifest:
                    files = {}
                    for name, data in owner.files.items():
                        digest = hashlib.sha256(data).hexdigest()
                        if name in owner.bad:
                            digest = "0" * 64
                        files[name] = {"sha256": digest, "size": len(data)}
                    return self.reply(200, json.dumps({"version": owner.version, "files": files}).encode())
                name = self.path[len("/dl/"):]
                if self.path.startswith("/dl/") and name in owner.files:
                    return self.reply(200, owner.files[name])
                self.reply(404, b'{"error":"not_found"}')

            def reply(self, status, data):
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def cli_version(self):
        import re
        return re.search(rb'^VERSION = "([^"]+)"', self.files.get("needs-you", read(CLI)), re.M).group(1).decode()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def current_files():
    return {"needs-you": read(CLI), "needs-you-hook.sh": read(HOOK), "hooks.json": read(HOOKS_JSON),
            "install-hooks.sh": read(INSTALL_HOOKS), "SKILL.md": read(SKILL), "orca-snippet.md": read(SNIPPET)}


class UpdateCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ny-update-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.home, ".local", "bin")
        os.makedirs(self.bin)
        self.cli = os.path.join(self.bin, "needs-you")
        self.old_cli = read(CLI).replace(b'VERSION = "', b'VERSION = "0.0.1" or "', 1)
        with open(self.cli, "wb") as fh:
            fh.write(self.old_cli)
        os.chmod(self.cli, 0o755)
        self.hubs = []

    def hub(self, **kw):
        h = FakeHub(kw.pop("files", None) or current_files(), **kw)
        self.hubs.append(h)
        self.addCleanup(h.stop)
        return h

    def install(self, rel, data=b"old\n# needs-you-version: 0.0.1\n", mode=0o644):
        path = os.path.join(self.home, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        os.chmod(path, mode)
        return path

    def run_cli(self, *args, urls, env=None):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "2",
             "NEEDS_YOU_HOST": "testbox", "NEEDS_YOU_URLS": ",".join(urls), "NEEDS_YOU_TOKEN": "t",
             "NEEDS_YOU_GH": "none"}
        e.update(env or {})
        return subprocess.run([sys.executable, self.cli] + list(args), env=e, capture_output=True, text=True, timeout=60)


class Update(UpdateCase):
    def test_updates_installed_pieces_only(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        orca = self.install(".config/needs-you/orca-snippet.md", mode=0o600)
        dead = "http://127.0.0.1:%d" % free_port()
        r = self.run_cli("update", urls=[h.url, dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("from %s" % h.url, r.stdout)
        self.assertIn("not checked against the GitHub release: gh isn't installed", r.stdout)
        self.assertEqual(read(self.cli), read(CLI))
        self.assertEqual(os.stat(self.cli).st_mode & 0o777, 0o755)
        self.assertEqual(read(skill), read(SKILL))
        self.assertEqual(read(orca), read(SNIPPET))
        self.assertEqual(os.stat(orca).st_mode & 0o777, 0o600)          # mode kept
        self.assertIn("updated ~/.claude/skills/needs-you/SKILL.md: 0.0.1 -> ", r.stdout)
        # Not installed here, so not installed by update.
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude", "hooks", "needs-you-hook.sh")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude", "settings.json")))
        self.assertEqual(sorted(os.listdir(self.bin)), ["needs-you"])    # no temp files
        r = self.run_cli("update", urls=[h.url])
        self.assertIn("already up to date", r.stdout)

    def test_check_changes_nothing(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(sorted(c["file"] for c in out["changes"]), ["SKILL.md", "needs-you"])
        self.assertEqual(out["applied"], [])
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(read(skill), b"old\n# needs-you-version: 0.0.1\n")

    def test_bad_checksum_replaces_nothing(self):
        h = self.hub(bad={"needs-you", "SKILL.md"})
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 1)
        self.assertIn("doesn't match the hub's checksum", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(read(skill), b"old\n# needs-you-version: 0.0.1\n")
        # --auto: same refusal, but never a failure for the caller.
        r = self.run_cli("update", "--auto", urls=[h.url])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout + r.stderr, "")

    def test_broken_cli_is_refused_even_with_a_good_checksum(self):
        files = current_files()
        files["needs-you"] = b"#!/usr/bin/env python3\nVERSION = \"9.9.9\"\ndef main(:\n"
        h = self.hub(files=files, version="9.9.9")
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 1)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_never_downgrades(self):
        files = current_files()
        files["needs-you"] = self.old_cli   # the hub serves 0.0.1
        h = self.hub(files=files, version="0.0.1")
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not downgrading", r.stdout)
        self.assertEqual(read(self.cli), read(CLI))
        r = self.run_cli("update", "--allow-downgrade", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_only_the_invite_hub_never_a_failover(self):
        h = self.hub()
        dead = "http://127.0.0.1:%d" % free_port()
        r = self.run_cli("update", urls=[dead, h.url])
        self.assertEqual(r.returncode, 1)
        self.assertIn(dead, r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertFalse([p for p, _ in h.headers if p.startswith("/dl/")])
        # Unless named explicitly.
        r = self.run_cli("update", urls=[dead, h.url], env={"NEEDS_YOU_UPDATE_HUB": h.url})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(self.cli), read(CLI))

    def test_plain_http_off_the_tailnet_is_refused(self):
        for url in ("http://10.0.0.5:8765", "http://hub.example.com:8765", "ftp://127.0.0.1/"):
            r = self.run_cli("update", urls=[url])
            self.assertEqual(r.returncode, 1, url)
            self.assertIn("refusing to update over", r.stderr, url)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_rollback_restores_the_previous_files(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        self.assertEqual(self.run_cli("update", urls=[h.url]).returncode, 0)
        self.assertEqual(read(skill), read(SKILL))
        r = self.run_cli("update", "--rollback", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(read(skill), b"old\n# needs-you-version: 0.0.1\n")
        self.assertEqual(os.stat(self.cli).st_mode & 0o777, 0o755)
        r = self.run_cli("update", "--rollback", urls=[h.url])
        self.assertIn("nothing to roll back", r.stdout)

    def test_old_hub_without_manifest(self):
        h = self.hub(manifest=False)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 1)
        self.assertIn("older than 0.1.2", r.stderr)
        self.assertEqual(self.run_cli("update", "--auto", urls=[h.url]).returncode, 0)

    def test_self_update_is_an_alias(self):
        h = self.hub()
        r = self.run_cli("self-update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("updated", r.stdout)
        self.assertEqual(read(self.cli), read(CLI))

    def test_hook_entries_are_re_merged(self):
        h = self.hub()
        hook = self.install(".claude/hooks/needs-you-hook.sh", mode=0o755)
        settings = self.install(".claude/settings.json",
                                json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command",
                                            "command": "\"$HOME/.claude/hooks/needs-you-hook.sh\" stop"}]}]},
                                            "model": "keep-me"}).encode())
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(hook), read(HOOK))
        with open(settings) as fh:
            s = json.load(fh)
        self.assertEqual(s["model"], "keep-me")
        self.assertIn("PermissionRequest", s["hooks"])
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            self.assertEqual(json.load(fh)["hooks_json_sha256"], hashlib.sha256(read(HOOKS_JSON)).hexdigest())
        # Again: nothing left to do.
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])


class ReleaseCrossCheck(UpdateCase):
    """With gh, every file must match the GitHub release of the hub's version (its server
    tarball, itself checked against SHA256SUMS). The fake gh builds that release."""

    def fake_gh(self, files, version, tamper=False, fail=False):
        import io
        import tarfile
        rel = os.path.join(self.tmp, "release")
        os.makedirs(rel, exist_ok=True)
        tarball = "needs-you-server-%s.tar.gz" % version
        paths = {"needs-you": "cli/needs-you", "needs-you-hook.sh": "integrations/claude-code/needs-you-hook.sh",
                 "install-hooks.sh": "integrations/claude-code/install-hooks.sh",
                 "hooks.json": "integrations/claude-code/hooks.json",
                 "SKILL.md": "integrations/claude-code/skill/needs-you/SKILL.md",
                 "orca-snippet.md": "integrations/orca/snippet.md"}
        with tarfile.open(os.path.join(rel, tarball), "w:gz") as tf:
            for name, data in files.items():
                if tamper and name == "needs-you":
                    data = data + b"# not the release\n"
                info = tarfile.TarInfo("needs-you-%s/%s" % (version, paths[name]))
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
        with open(os.path.join(rel, "SHA256SUMS"), "w") as fh:
            fh.write("%s  %s\n" % (hashlib.sha256(read(os.path.join(rel, tarball))).hexdigest(), tarball))
        gh = os.path.join(self.tmp, "gh")
        log = os.path.join(self.tmp, "gh.log")
        with open(gh, "w") as fh:
            fh.write("#!/bin/sh\necho \"$*\" >> %s\n" % log)
            if fail:
                fh.write("echo 'release not found' >&2\nexit 1\n")
            else:
                fh.write('while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done\ncp %s/* "$dir"/\n' % rel)
        os.chmod(gh, 0o755)
        return gh, log

    def test_matching_release_installs(self):
        h = self.hub()
        gh, log = self.fake_gh(current_files(), h.version)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("matches release v%s on GitHub" % h.version, r.stdout)
        self.assertEqual(read(self.cli), read(CLI))
        with open(log) as fh:
            self.assertIn("release download v%s --repo tayharris/needs-you" % h.version, fh.read())

    def test_mismatch_refuses_everything(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        gh, _ = self.fake_gh(current_files(), h.version, tamper=True)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1)
        self.assertIn("doesn't match release", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(read(skill), b"old\n# needs-you-version: 0.0.1\n")
        # Automatic: refused just as quietly.
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_GH": gh, "NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertEqual(read(self.cli), self.old_cli)

    def test_require_match_refuses_when_the_check_cannot_run(self):
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, fail=True)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 0, r.stderr)            # not required: installs, says so
        self.assertIn("not checked against the GitHub release: gh couldn't download", r.stdout)
        with open(self.cli, "wb") as fh:
            fh.write(self.old_cli)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh, "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)


class Transport(unittest.TestCase):
    """update_transport_ok, called directly (the CLI file loaded as a module)."""

    @classmethod
    def setUpClass(cls):
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("needs_you_cli", CLI)
        spec = importlib.util.spec_from_loader("needs_you_cli", loader)
        cls.cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.cli)

    def ok(self, url, ips=None):
        resolve = (lambda *a: [(None, None, None, None, (ip, 80)) for ip in ips]) if ips is not None else None
        return self.cli.update_transport_ok(url, resolve)[0]

    def test_table(self):
        self.assertTrue(self.ok("https://hub.example.com"))
        self.assertTrue(self.ok("http://127.0.0.1:8765"))
        self.assertTrue(self.ok("http://localhost:8765"))
        self.assertTrue(self.ok("http://[::1]:8765"))
        self.assertTrue(self.ok("http://100.101.102.103:8765"))
        self.assertTrue(self.ok("http://[fd7a:115c:a1e0::1]:8765"))
        self.assertTrue(self.ok("http://mac.tail1.ts.net:8765", ips=["100.64.0.7"]))
        self.assertFalse(self.ok("http://mac.tail1.ts.net:8765", ips=["203.0.113.5"]))
        self.assertFalse(self.ok("http://mac.tail1.ts.net:8765", ips=["100.64.0.7", "203.0.113.5"]))
        self.assertFalse(self.ok("http://100.128.0.1:8765"))      # just outside 100.64.0.0/10
        self.assertFalse(self.ok("http://10.0.0.5:8765"))
        self.assertFalse(self.ok("http://hub.example.com"))
        self.assertFalse(self.ok("http://evil.ts.net.example.com", ips=["100.64.0.7"]))
        self.assertFalse(self.ok("file:///etc/passwd"))


class ClientHeader(UpdateCase):
    def test_every_request_says_what_runs_here(self):
        h = self.hub()
        self.install(".claude/skills/needs-you/SKILL.md", read(SKILL))
        self.install(".claude/hooks/needs-you-hook.sh", b"#!/bin/sh\n# no stamp: an old hook\n")
        self.run_cli("health", urls=[h.url])
        header = dict(h.headers)["/v1/health"]
        v = FakeHub.cli_version(h)
        self.assertEqual(header, "cli=0.0.1; hook=unknown; skill=%s; orca=none" % v)
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        self.run_cli("health", urls=[h.url])
        self.assertEqual(h.headers[-1][1], "cli=%s; hook=unknown; skill=%s; orca=none" % (v, v))


class AutoUpdate(UpdateCase):
    def state(self):
        try:
            with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
                return json.load(fh)
        except OSError:
            return {}

    def test_off_by_default(self):
        h = self.hub()
        r = self.run_cli("-q", "flush", urls=[h.url])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertFalse([p for p, _ in h.headers if p.startswith("/dl/")])

    def test_flush_updates_once_a_day(self):
        h = self.hub()
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertEqual(read(self.cli), read(CLI))
        st = self.state()
        self.assertIn("auto_ok_at", st)
        # The next flush (5 minutes later) doesn't ask again.
        n = len(h.headers)
        self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertFalse([p for p, _ in h.headers[n:] if p == "/dl/manifest.json"])

    def test_opt_out_and_hub_down(self):
        h = self.hub()
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "0"})
        self.assertEqual(r.returncode, 0)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(self.state(), {})
        dead = "http://127.0.0.1:%d" % free_port()
        r = self.run_cli("-q", "flush", urls=[dead], env={"NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("auto_ok_at", self.state())
        self.assertIn("auto_tried_at", self.state())   # retried after an hour, not every flush

    def test_opt_in_in_the_env_file(self):
        h = self.hub()
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_AUTO_UPDATE=1\n")
        self.run_cli("-q", "flush", urls=[h.url])
        self.assertEqual(read(self.cli), read(CLI))   # opted in through the env file


class DoctorUpdate(UpdateCase):
    def test_doctor_reports_versions_against_the_hub(self):
        h = self.hub()
        r = self.run_cli("doctor", "--json", urls=[h.url])
        checks = {c["check"]: c for c in json.loads(r.stdout)["checks"]}
        self.assertEqual(checks["update"]["status"], "WARN")
        self.assertIn("newer on the hub: needs-you", checks["update"]["detail"])
        self.assertEqual(checks["update"]["hint"], "needs-you update")
        self.assertEqual(read(self.cli), self.old_cli)   # doctor never changes anything


class RealHub(HubTestCase):
    def test_update_against_a_real_hub_records_versions(self):
        tmp = tempfile.mkdtemp(prefix="ny-update-real-")
        self.addCleanup(shutil.rmtree, tmp, True)
        hub = self.make_hub("hub-a", install_dir=ROOT)
        sender, _ = hub.store.add_token("devbox", "sender")
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        cli = os.path.join(tmp, "needs-you")
        with open(cli, "wb") as fh:
            fh.write(read(CLI).replace(b'VERSION = "', b'VERSION = "0.0.1" or "', 1))
        env = {"HOME": home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_URLS": hub.url,
               "NEEDS_YOU_TOKEN": sender, "NEEDS_YOU_TIMEOUT": "2", "NEEDS_YOU_GH": "none"}
        r = subprocess.run([sys.executable, cli, "update"], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(cli), read(CLI))
        subprocess.run([sys.executable, cli, "health"], env=env, capture_output=True, text=True, timeout=60)
        tid = hub.store.token_by_secret(sender)["id"]
        self.assertEqual(hub.store.token_clients()[tid]["client"]["cli"], hubmod.VERSION)


if __name__ == "__main__":
    unittest.main()
