"""`needs-you update`, the daily auto-update from `flush`, and the X-Needs-You-Client header,
against a fake hub that serves a manifest and files from a dict (so checksums can be
wrong on purpose). The CLI under test is always a copy in a temp dir, never cli/needs-you."""
from __future__ import annotations

import hashlib
import json
import re
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import CLI, ROOT, HubTestCase, free_port, hubmod, wait_until

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
        self.bad_shape = False
        self.redirect = False
        self.update_requested = False
        self.headers = []
        self.hosts = []
        owner = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                owner.headers.append((self.path, self.headers.get("X-Needs-You-Client")))
                owner.hosts.append(self.headers.get("Host"))
                if self.path == "/v1/health":
                    return self.reply(200, json.dumps({"ok": True, "version": owner.version}).encode())
                if self.path == "/dl/manifest.json" and owner.redirect:
                    self.send_response(302)
                    self.send_header("Location", "http://127.0.0.1:9/evil")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path == "/dl/manifest.json" and owner.manifest:
                    files = {}
                    for name, data in owner.files.items():
                        digest = hashlib.sha256(data).hexdigest()
                        if name in owner.bad:
                            digest = "0" * 64
                        files[name] = {"sha256": digest, "size": len(data)}
                        if owner.bad_shape and name == "needs-you":
                            del files[name]["sha256"]
                    return self.reply(200, json.dumps({"version": owner.version, "files": files}).encode())
                name = self.path[len("/dl/"):]
                if self.path.startswith("/dl/") and name in owner.files:
                    return self.reply(200, owner.files[name])
                self.reply(404, b'{"error":"not_found"}')

            def do_POST(self):
                owner.headers.append((self.path, self.headers.get("X-Needs-You-Client")))
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                body = {"id": "01TEST", "created": True, "changed": True}
                if owner.update_requested:
                    body["update_requested"] = True
                self.reply(201, json.dumps(body).encode())

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

    def run_cli(self, *args, urls, env=None, cwd=None):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "2",
             "NEEDS_YOU_HOST": "testbox", "NEEDS_YOU_URLS": ",".join(urls), "NEEDS_YOU_TOKEN": "t",
             "NEEDS_YOU_GH": "none"}
        e.update(env or {})
        return subprocess.run([sys.executable, self.cli] + list(args), env=e, capture_output=True, text=True,
                              timeout=60, cwd=cwd or self.tmp)  # never a checkout with project hooks


class Update(UpdateCase):
    def test_updates_installed_pieces_only(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        orca = self.install(".config/needs-you/orca-snippet.md", mode=0o600)
        dead = "http://127.0.0.1:%d" % free_port()
        r = self.run_cli("update", urls=[h.url, dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("from %s" % h.url, r.stdout)
        self.assertIn("WARNING: not checked against the GitHub release (gh isn't installed)", r.stderr)
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
            self.assertIn("refusing to update:", r.stderr, url)
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

    def test_rollback_undoes_only_the_last_update(self):
        h = self.hub()
        skill = self.install(".claude/skills/needs-you/SKILL.md")
        self.assertEqual(self.run_cli("update", urls=[h.url]).returncode, 0)  # skill and CLI
        with open(self.cli, "wb") as fh:  # later, only the CLI is behind
            fh.write(self.old_cli)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("SKILL.md", r.stdout)
        r = self.run_cli("update", "--rollback", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(read(skill), read(SKILL))  # not two updates back

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


class ProjectHooks(UpdateCase):
    """Hooks installed with install-hooks.sh --project: recorded, and updated by an update
    run inside the project (and only there)."""

    def install_project(self, *flags):
        proj = os.path.join(self.tmp, "proj")
        os.makedirs(os.path.join(proj, "src"), exist_ok=True)
        r = subprocess.run(["bash", INSTALL_HOOKS, "--project", proj] + list(flags), capture_output=True, text=True,
                           env={"HOME": self.home, "PATH": os.environ.get("PATH", "")}, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return proj

    def projects(self):
        try:
            with open(os.path.join(self.home, ".local", "state", "needs-you", "claude-projects.json")) as fh:
                return json.load(fh)
        except OSError:
            return {}

    def test_install_records_and_uninstall_forgets(self):
        proj = self.install_project("--local")
        settings = os.path.realpath(os.path.join(proj, ".claude", "settings.local.json"))
        self.assertEqual(self.projects(), {settings: {"hooks_json_sha256": hashlib.sha256(read(HOOKS_JSON)).hexdigest()}})
        self.install_project("--local", "--uninstall")
        self.assertEqual(self.projects(), {})
        self.assertFalse(os.path.exists(os.path.join(proj, ".claude", "hooks", "needs-you-hook.sh")))

    def test_update_inside_the_project_refreshes_its_hooks(self):
        h = self.hub()
        proj = self.install_project()
        hook = os.path.join(proj, ".claude", "hooks", "needs-you-hook.sh")
        settings = os.path.join(proj, ".claude", "settings.json")
        with open(hook, "wb") as fh:
            fh.write(b"#!/bin/bash\n# needs-you-version: 0.0.1\nexit 0\n")
        with open(settings, "w") as fh:  # an older merge: one entry only
            json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command":
                       '"$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh" stop'}]}]}, "model": "keep-me"}, fh)
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        # Outside the project there's nothing to do; inside (a subdirectory too) there is.
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])
        r = self.run_cli("--json", "update", "--check", urls=[h.url], cwd=os.path.join(proj, "src"))
        self.assertEqual([c["file"] for c in json.loads(r.stdout)["changes"]], ["project hooks"])
        r = self.run_cli("doctor", "--json", urls=[h.url], cwd=os.path.join(proj, "src"))
        checks = {c["check"]: c for c in json.loads(r.stdout)["checks"]}
        self.assertIn("newer on the hub: project hooks", checks["update"]["detail"])
        self.assertEqual(checks["claude project hooks"]["status"], "WARN")
        self.assertIn("old hook", checks["claude project hooks"]["detail"])
        r = self.run_cli("update", urls=[h.url], cwd=os.path.join(proj, "src"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("updated the project hooks", r.stdout)
        self.assertEqual(read(hook), read(HOOK))
        with open(settings) as fh:
            s = json.load(fh)
        self.assertEqual(s["model"], "keep-me")
        self.assertIn("PermissionRequest", s["hooks"])
        self.assertIn("$CLAUDE_PROJECT_DIR", json.dumps(s))
        self.assertNotIn("$HOME", json.dumps(s))
        r = self.run_cli("--json", "update", "--check", urls=[h.url], cwd=proj)
        self.assertEqual(json.loads(r.stdout)["changes"], [])
        # The user level wasn't touched.
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))

    def test_a_clone_that_only_ships_hook_settings_is_never_written(self):
        # An untrusted repo whose .claude names the hook, with no install recorded here:
        # update reads it as data and leaves it alone.
        h = self.hub()
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        proj = os.path.join(self.tmp, "clone")
        os.makedirs(os.path.join(proj, ".claude", "hooks"))
        evil = {"hooks": {"Stop": [{"hooks": [{"type": "command",
                "command": "touch %s/pwned; needs-you-hook.sh" % self.tmp}]}]}}
        with open(os.path.join(proj, ".claude", "settings.json"), "w") as fh:
            json.dump(evil, fh)
        with open(os.path.join(proj, ".claude", "hooks", "needs-you-hook.sh"), "w") as fh:
            fh.write("#!/bin/sh\ntouch %s/pwned\n" % self.tmp)
        r = self.run_cli("--json", "update", urls=[h.url], cwd=proj)
        self.assertEqual(json.loads(r.stdout)["changes"], [])
        with open(os.path.join(proj, ".claude", "settings.json")) as fh:
            self.assertEqual(json.load(fh), evil)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "pwned")))

    def test_symlinked_project_files_are_refused(self):
        proj = self.install_project()
        outside = os.path.join(self.tmp, "outside.json")
        with open(outside, "w") as fh:
            fh.write("{}\n")
        settings = os.path.join(proj, ".claude", "settings.json")
        os.remove(settings)
        os.symlink(outside, settings)
        r = subprocess.run(["bash", INSTALL_HOOKS, "--project", proj], capture_output=True, text=True,
                           env={"HOME": self.home, "PATH": os.environ.get("PATH", "")}, timeout=60)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is a symlink", r.stderr)
        self.assertEqual(read(outside), b"{}\n")


class ReleaseCrossCheck(UpdateCase):
    """With gh, every file must match the GitHub release of the hub's version (its server
    tarball, itself checked against SHA256SUMS). The fake gh builds that release."""

    def fake_gh(self, files, version, tamper=False, fail=False, attest="ok", private="false",
                manifest_tarball_sha=None):
        """attest: "ok" (gh attestation verify passes) or "fail"; private: what
        `gh api repos/... --jq .private` prints."""
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
        tar_sha = hashlib.sha256(read(os.path.join(rel, tarball))).hexdigest()
        with open(os.path.join(rel, "SHA256SUMS"), "w") as fh:
            fh.write("%s  %s\n" % (tar_sha, tarball))
        with open(os.path.join(rel, "release-manifest.json"), "w") as fh:
            json.dump({"version": version, "assets": [
                {"name": tarball, "sha256": manifest_tarball_sha or tar_sha, "size": 1}]}, fh)
        gh = os.path.join(self.tmp, "gh")
        log = os.path.join(self.tmp, "gh.log")
        out = os.path.join(self.tmp, "attestation.json")
        if attest == "fail":
            attest_cmd = "echo 'no attestations found' >&2; exit 1"
        else:
            if isinstance(attest, str) and attest.startswith("raw:"):
                text = attest[4:]
            else:
                entry = self.attestation(read(os.path.join(rel, "release-manifest.json")), version)
                if callable(attest):
                    attest(entry)
                text = json.dumps([entry])
            with open(out, "w") as afh:
                afh.write(text)
            attest_cmd = "cat %s; exit 0" % out
        with open(gh, "w") as fh:
            fh.write("#!/bin/sh\necho \"$*\" >> %s\n" % log)
            fh.write('[ "$1" = attestation ] && { %s; }\n' % attest_cmd)
            fh.write('[ "$1" = api ] && { echo %s; exit 0; }\n' % private)
            if fail:
                fh.write("echo 'release not found' >&2\nexit 1\n")
            else:
                fh.write('while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done\ncp %s/* "$dir"/\n' % rel)
        os.chmod(gh, 0o755)
        return gh, log

    @staticmethod
    def attestation(data, version):
        """One `gh attestation verify --format json` entry, as GitHub's release workflow makes it."""
        return {"attestation": {"bundle": {}}, "verificationResult": {
            "statement": {"_type": "https://in-toto.io/Statement/v1",
                          "predicateType": "https://slsa.dev/provenance/v1",
                          "subject": [{"name": "release-manifest.json",
                                       "digest": {"sha256": hashlib.sha256(data).hexdigest()}}]},
            "signature": {"certificate": {
                "issuer": "https://token.actions.githubusercontent.com",
                "sourceRepositoryURI": "https://github.com/tayharris/needs-you",
                "sourceRepositoryRef": "refs/tags/v%s" % version,
                "buildSignerURI": "https://github.com/tayharris/needs-you/.github/workflows/release.yml"
                                  "@refs/tags/v%s" % version,
                "runnerEnvironment": "github-hosted"}}}}

    def refused_by(self, attest, message):
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, attest=attest)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(message, r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_wrong_repo_refuses(self):
        def f(e):
            e["verificationResult"]["signature"]["certificate"]["sourceRepositoryURI"] = "https://github.com/evil/needs-you"
        self.refused_by(f, "built from another repository")

    def test_wrong_workflow_refuses(self):
        def f(e):
            e["verificationResult"]["signature"]["certificate"]["buildSignerURI"] = \
                "https://github.com/tayharris/needs-you/.github/workflows/ci.yml@refs/heads/main"
        self.refused_by(f, "signed by another workflow")

    def test_wrong_ref_refuses(self):
        def f(e):
            e["verificationResult"]["signature"]["certificate"]["sourceRepositoryRef"] = "refs/heads/main"
        self.refused_by(f, "built from another ref")

    def test_self_hosted_runner_refuses(self):
        def f(e):
            e["verificationResult"]["signature"]["certificate"]["runnerEnvironment"] = "self-hosted"
        self.refused_by(f, "built on a self-hosted runner")

    def test_digest_mismatch_refuses(self):
        def f(e):
            e["verificationResult"]["statement"]["subject"][0]["digest"]["sha256"] = "0" * 64
        self.refused_by(f, "the attested digest isn't the downloaded file's")

    def test_wrong_predicate_refuses(self):
        def f(e):
            e["verificationResult"]["statement"]["predicateType"] = "https://example.com/other"
        self.refused_by(f, "not SLSA provenance")

    def test_bad_or_empty_json_refuses(self):
        self.refused_by("raw:not json", "printed no valid JSON")
        self.refused_by("raw:[]", "returned no attestation")
        self.refused_by("raw:", "printed no valid JSON")
        self.refused_by('raw:[{"verificationResult": {}}]', "unexpected shape")

    def test_matching_release_installs(self):
        h = self.hub()
        gh, log = self.fake_gh(current_files(), h.version)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("matches release v%s on GitHub (build provenance verified)" % h.version, r.stdout)
        self.assertEqual(read(self.cli), read(CLI))
        with open(log) as fh:
            calls = fh.read()
        self.assertIn("release download v%s --repo tayharris/needs-you" % h.version, calls)
        self.assertIn("--pattern release-manifest.json", calls)
        self.assertRegex(calls, r"attestation verify \S+/release-manifest\.json --repo tayharris/needs-you "
                                r"--signer-workflow tayharris/needs-you/\.github/workflows/release\.yml "
                                r"--source-ref refs/tags/v%s --predicate-type https://slsa\.dev/provenance/v1 "
                                r"--deny-self-hosted-runners --format json" % re.escape(h.version))

    def test_missing_provenance_refuses(self):
        # security audit #17 (c): gh is there, the repo is public, the attestation doesn't verify
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, attest="fail")
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1)
        self.assertIn("has no valid build provenance", r.stderr)
        self.assertIn("no attestations found", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_GH": gh, "NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertEqual(read(self.cli), self.old_cli)

    def test_private_repo_skips_provenance_with_a_note(self):
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, attest="fail", private="true")
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no build provenance to check", r.stdout)
        self.assertEqual(read(self.cli), read(CLI))

    def test_manifest_not_listing_the_tarball_refuses(self):
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, manifest_tarball_sha="0" * 64)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1)
        self.assertIn("release-manifest.json doesn't list this", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)

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

    def test_a_gh_that_fails_refuses(self):
        # Installed but failing (no such release, not logged in, a timeout): never fail open.
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version, fail=True)
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1)
        self.assertIn("gh couldn't download release", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_a_broken_release_refuses(self):
        h = self.hub()
        gh, _ = self.fake_gh(current_files(), h.version)
        with open(os.path.join(self.tmp, "release", "SHA256SUMS"), "w") as fh:
            fh.write("garbage\n")
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_GH": gh})
        self.assertEqual(r.returncode, 1)
        self.assertIn("doesn't match its SHA256SUMS", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)

    def test_without_gh(self):
        h = self.hub()
        # Required: refused.
        r = self.run_cli("update", urls=[h.url], env={"NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH is on", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)
        # Automatic updates require it by default.
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1"})
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertEqual(read(self.cli), self.old_cli)
        # By hand: goes ahead, with a warning.
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WARNING: not checked against the GitHub release", r.stderr)
        self.assertEqual(read(self.cli), read(CLI))

    def test_manifest_without_a_checksum_refuses(self):
        h = self.hub()
        h.bad_shape = True
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 1)
        self.assertIn("no valid checksum", r.stderr)
        self.assertEqual(read(self.cli), self.old_cli)


class Transport(unittest.TestCase):
    """resolve_update_target and pinned_get, called directly (the CLI loaded as a module)."""

    @classmethod
    def setUpClass(cls):
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("needs_you_cli", CLI)
        spec = importlib.util.spec_from_loader("needs_you_cli", loader)
        cls.cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.cli)

    def resolver(self, *answers):
        """Each call returns the next answer: a rebinding DNS server."""
        calls = []
        def resolve(host, port, *a):
            calls.append(host)
            ips = answers[min(len(calls) - 1, len(answers) - 1)]
            return [(None, None, None, None, (ip, port)) for ip in ips]
        return resolve, calls

    def target(self, url, *answers):
        resolve, calls = self.resolver(*(answers or (["100.64.0.7"],)))
        return self.cli.resolve_update_target(url, resolve), calls

    def refused(self, url, *answers):
        with self.assertRaises(self.cli.UpdateRefused, msg=url):
            self.target(url, *answers)

    def test_allowed(self):
        t, _ = self.target("https://hub.example.com/needs/")
        self.assertEqual((t.scheme, t.host, t.port, t.base_path, t.connect_host), ("https", "hub.example.com", 443, "/needs", "hub.example.com"))
        t, _ = self.target("http://127.0.0.1:8765")
        self.assertEqual((t.connect_host, t.port, t.host_header), ("127.0.0.1", 8765, "127.0.0.1:8765"))
        t, _ = self.target("http://localhost:8765")
        self.assertEqual(t.connect_host, "127.0.0.1")
        t, _ = self.target("http://[::1]:8765")
        self.assertEqual((t.connect_host, t.host_header), ("::1", "[::1]:8765"))
        self.assertEqual(self.target("http://100.101.102.103:8765")[0].connect_host, "100.101.102.103")
        self.assertEqual(self.target("http://[fd7a:115c:a1e0::1]:8765")[0].connect_host, "fd7a:115c:a1e0::1")
        t, calls = self.target("http://MAC.Tail1.TS.NET:8765", ["100.64.0.7"])
        self.assertEqual((t.host, t.connect_host, t.host_header), ("mac.tail1.ts.net", "100.64.0.7", "mac.tail1.ts.net:8765"))
        self.assertEqual(calls, ["mac.tail1.ts.net"])

    def test_bypass_shapes_are_refused(self):
        for url in ("http://10.0.0.5:8765", "http://hub.example.com", "http://100.128.0.1:8765", "ftp://127.0.0.1/",
                    "file:///etc/passwd", "http://127.0.0.1@evil.example.com/", "http://user@127.0.0.1:8765",
                    "http://u:p@mac.tail1.ts.net", "http://mac.tail1.ts.net.:8765", "http://127.0.0.1.:8765",
                    "http://xn--mc-uia.tail1.ts.net", "http://m\u00e4c.tail1.ts.net", "http://evil.ts.net.example.com",
                    "http://127.0.0.1:8765/?x=1", "http://127.0.0.1:8765/#x", "http://127.0.0.1:99999",
                    "http://127.0.0.1 :8765", "http://[::ffff:10.0.0.5]:8765", "http://a..ts.net",
                    "http://127.0.0.1\\@evil.example.com", "http://"):
            self.refused(url)
        # *.ts.net that resolves outside the tailnet, partly or entirely.
        self.refused("http://mac.tail1.ts.net:8765", ["203.0.113.5"])
        self.refused("http://mac.tail1.ts.net:8765", ["100.64.0.7", "203.0.113.5"])
        self.refused("http://mac.tail1.ts.net:8765", [])

    def test_resolves_once_and_connects_to_that_address(self):
        # DNS rebinding: the first answer is checked and used; a second lookup would say evil.
        t, calls = self.target("http://mac.tail1.ts.net:8765", ["100.64.0.7"], ["203.0.113.5"])
        self.assertEqual(calls, ["mac.tail1.ts.net"])
        self.assertEqual(t.connect_host, "100.64.0.7")

    def test_pinned_get_sends_the_host_header_and_refuses_redirects(self):
        h = FakeHub(current_files())
        self.addCleanup(h.stop)
        port = h.server.server_address[1]
        t = self.cli.UpdateTarget("http", "mac.tail1.ts.net", port, "", "127.0.0.1", "tailnet name")
        self.assertEqual(json.loads(self.cli.pinned_get(t, "/v1/health", 5))["ok"], True)
        self.assertEqual(h.hosts[-1], "mac.tail1.ts.net:%d" % port)
        h.redirect = True
        with self.assertRaises(self.cli.UpdateRefused) as e:
            self.cli.pinned_get(t, "/dl/manifest.json", 5)
        self.assertIn("redirects aren't followed", str(e.exception))
        self.assertEqual([p for p in h.hosts if p != "mac.tail1.ts.net:%d" % port], [])  # nothing went elsewhere


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
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "0"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertEqual(read(self.cli), read(CLI))
        st = self.state()
        self.assertIn("auto_ok_at", st)
        # The next flush (5 minutes later) doesn't ask again.
        n = len(h.headers)
        self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "0"})
        self.assertFalse([p for p, _ in h.headers[n:] if p == "/dl/manifest.json"])

    def test_opt_out_and_hub_down(self):
        h = self.hub()
        r = self.run_cli("-q", "flush", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "0"})
        self.assertEqual(r.returncode, 0)
        self.assertEqual(read(self.cli), self.old_cli)
        self.assertEqual(self.state(), {})
        dead = "http://127.0.0.1:%d" % free_port()
        r = self.run_cli("-q", "flush", urls=[dead], env={"NEEDS_YOU_AUTO_UPDATE": "1", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "0"})
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("auto_ok_at", self.state())
        self.assertIn("auto_tried_at", self.state())   # retried after an hour, not every flush

    def test_not_http_is_a_failed_check_not_a_traceback(self):
        """Another service on the hub's port (http.client.HTTPException isn't an OSError)."""
        from support import garbage_server
        bad = garbage_server(self, b"SSH-2.0-OpenSSH_9.6\r\n")
        r = self.run_cli("update", urls=[bad])
        self.assertNotIn("Traceback", r.stderr)
        self.assertNotEqual(r.returncode, 0)
        r = self.run_cli("--json", "update", urls=[bad])
        self.assertNotIn("Traceback", r.stderr)
        json.loads(r.stdout)
        r = self.run_cli("update", "--auto", urls=[bad])
        self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(r.returncode, 0)   # --auto never fails
        self.assertEqual(read(self.cli), self.old_cli)

    def test_opt_in_in_the_env_file(self):
        h = self.hub()
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_AUTO_UPDATE=1\nNEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH=0\n")
        self.run_cli("-q", "flush", urls=[h.url])
        self.assertEqual(read(self.cli), read(CLI))   # opted in through the env file


class ReleaseOverHttps(UpdateCase):
    """Without gh, the same release files come from github.com over https (stdlib), so an
    automatic update works on a box with no gh. Here the download is served from the fake
    release directory instead of the network."""

    fake_gh = ReleaseCrossCheck.fake_gh     # builds the fake release directory
    attestation = staticmethod(ReleaseCrossCheck.attestation)

    def load(self, release_dir, unreachable=False):
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("needs_you_cli_https", CLI)
        spec = importlib.util.spec_from_loader("needs_you_cli_https", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        fetched = []

        def fake_get(url, dest, timeout=60.0):
            fetched.append(url)
            if unreachable:
                raise mod._ReleaseUnreachable("Name or service not known")
            name = url.rsplit("/", 1)[-1]
            src = os.path.join(release_dir, name)
            if not os.path.exists(src):
                raise mod.UpdateRefused("GitHub has no %s for this release (HTTP 404)" % name)
            shutil.copy(src, dest)
        mod._release_get = fake_get
        mod._gh = lambda: None
        old = os.environ.pop("NEEDS_YOU_GH", None)
        if old is not None:
            self.addCleanup(os.environ.__setitem__, "NEEDS_YOU_GH", old)
        return mod, fetched

    def test_matching_release_without_gh(self):
        version = "9.8.7"
        self.fake_gh(current_files(), version)
        mod, fetched = self.load(os.path.join(self.tmp, "release"))
        digests, note = mod.release_digests(version, ["needs-you", "SKILL.md"])
        self.assertEqual(digests["needs-you"], hashlib.sha256(read(CLI)).hexdigest())
        self.assertIn("without gh", note)
        self.assertIn("build provenance not checked", note)
        self.assertEqual(fetched, ["https://github.com/tayharris/needs-you/releases/download/v9.8.7/" + n
                                   for n in ("SHA256SUMS", "needs-you-server-9.8.7.tar.gz", "release-manifest.json")])

    def test_tampered_tarball_refuses(self):
        version = "9.8.7"
        self.fake_gh(current_files(), version)
        rel = os.path.join(self.tmp, "release")
        with open(os.path.join(rel, "needs-you-server-9.8.7.tar.gz"), "ab") as fh:
            fh.write(b"x")
        mod, _ = self.load(rel)
        with self.assertRaises(mod.UpdateRefused) as cm:
            mod.release_digests(version, ["needs-you"])
        self.assertIn("doesn't match its SHA256SUMS", str(cm.exception))

    def test_manifest_must_list_the_tarball(self):
        version = "9.8.7"
        self.fake_gh(current_files(), version, manifest_tarball_sha="0" * 64)
        mod, _ = self.load(os.path.join(self.tmp, "release"))
        with self.assertRaises(mod.UpdateRefused) as cm:
            mod.release_digests(version, ["needs-you"])
        self.assertIn("doesn't list this", str(cm.exception))

    def test_missing_release_refuses(self):
        mod, _ = self.load(os.path.join(self.tmp, "nowhere"))
        with self.assertRaises(mod.UpdateRefused):
            mod.release_digests("9.8.7", ["needs-you"])

    def test_unreachable_github_is_not_a_match(self):
        mod, _ = self.load(os.path.join(self.tmp, "nowhere"), unreachable=True)
        digests, why = mod.release_digests("9.8.7", ["needs-you"])
        self.assertIsNone(digests)
        self.assertIn("github.com couldn't be reached", why)

    def cross_check(self, mod, auto, **env):
        """cross_check with a config file of its own (never the real ~/.config) and env."""
        conf = os.path.join(self.tmp, "cc-env")
        open(conf, "w").close()
        saved = {k: os.environ.get(k) for k in ["NEEDS_YOU_CONFIG", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH"]}

        def restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ["NEEDS_YOU_CONFIG"] = conf
        os.environ.pop("NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH", None)
        os.environ.update(env)
        files = current_files()
        manifest = {"version": "9.8.7", "files": {n: {"sha256": hashlib.sha256(d).hexdigest()} for n, d in files.items()}}
        changes = [{"file": "needs-you"}]
        return mod.cross_check(mod.Config(), manifest, changes, auto=auto)

    def test_unreachable_github_refuses_automatic_updates(self):
        mod, _ = self.load(os.path.join(self.tmp, "nowhere"), unreachable=True)
        with self.assertRaises(mod.UpdateRefused) as cm:
            self.cross_check(mod, auto=True)
        self.assertIn("automatic updates need it", str(cm.exception))
        # A manual update only with the explicit warning, and not at all with =1.
        self.assertTrue(self.cross_check(mod, auto=False).startswith("WARNING: not checked against the GitHub release"))
        with self.assertRaises(mod.UpdateRefused):
            self.cross_check(mod, auto=False, NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH="1")

    def test_matching_https_release_satisfies_the_check_and_says_what_was_skipped(self):
        self.fake_gh(current_files(), "9.8.7")
        mod, _ = self.load(os.path.join(self.tmp, "release"))
        for auto in (True, False):
            note = self.cross_check(mod, auto=auto, NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH="1")
            self.assertIn("matches release v9.8.7 on GitHub", note)
            self.assertIn("build provenance not checked", note)

    def test_hub_file_not_in_the_https_release_refuses(self):
        files = current_files()
        self.fake_gh(files, "9.8.7", tamper=True)   # the release's CLI differs from the hub's
        mod, _ = self.load(os.path.join(self.tmp, "release"))
        with self.assertRaises(mod.UpdateRefused):
            self.cross_check(mod, auto=True)

    def test_tls_failure_is_a_refusal_not_unreachable(self):
        import ssl
        import urllib.error
        import urllib.request
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("needs_you_cli_tls", CLI)
        spec = importlib.util.spec_from_loader("needs_you_cli_tls", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)

        class Opener:
            def open(self, *a, **kw):
                raise urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))
        real = urllib.request.build_opener
        urllib.request.build_opener = lambda *a: Opener()
        self.addCleanup(setattr, urllib.request, "build_opener", real)
        with self.assertRaises(mod.UpdateRefused) as cm:
            mod._release_get("https://github.com/tayharris/needs-you/releases/download/v1.2.3/SHA256SUMS",
                             os.path.join(self.tmp, "out"))
        self.assertIn("TLS", str(cm.exception))

    def test_only_github_urls(self):
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.SourceFileLoader("needs_you_cli_urls", CLI)
        spec = importlib.util.spec_from_loader("needs_you_cli_urls", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        for url in ("http://github.com/x", "https://evil.example/x", "https://github.com.evil.example/x",
                    "https://github.com:8443/x", "https://evilgithub.com/x", "ftp://github.com/x"):
            with self.assertRaises(mod.UpdateRefused):
                mod._release_get(url, os.path.join(self.tmp, "out"))


class AutoSwitch(UpdateCase):
    def env_file(self):
        return os.path.join(self.home, ".config", "needs-you", "env")

    def test_enable_and_disable_keep_other_lines(self):
        h = self.hub()
        os.makedirs(os.path.dirname(self.env_file()))
        with open(self.env_file(), "w") as fh:
            fh.write("# mine\nNEEDS_YOU_TOKEN=t\nexport NEEDS_YOU_AUTO_UPDATE=0\nNEEDS_YOU_AGENT_ALERTS=1\n")
        r = self.run_cli("update", "--disable-auto", urls=["http://127.0.0.1:%d" % free_port()])
        self.assertEqual(r.returncode, 0, r.stderr)           # no hub needed to turn it off
        self.assertIn("daily automatic updates off", r.stdout)
        self.assertEqual(read(self.cli), self.old_cli)         # and nothing updated
        r = self.run_cli("update", "--enable-auto", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("daily automatic updates on", r.stdout)
        self.assertEqual(read(self.cli), read(CLI))            # updated now as well
        with open(self.env_file()) as fh:
            self.assertEqual(fh.read(), "# mine\nNEEDS_YOU_TOKEN=t\nNEEDS_YOU_AUTO_UPDATE=1\nNEEDS_YOU_AGENT_ALERTS=1\n")
        self.assertEqual(os.stat(self.env_file()).st_mode & 0o777, 0o600)

    def test_enable_without_an_env_file(self):
        h = self.hub()
        r = self.run_cli("update", "--enable-auto", "--check", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.env_file()) as fh:
            self.assertIn("NEEDS_YOU_AUTO_UPDATE=1\n", fh.read())

    def test_both_flags_are_refused(self):
        r = self.run_cli("update", "--enable-auto", "--disable-auto", urls=["http://127.0.0.1:9"])
        self.assertEqual(r.returncode, 2)


class DoctorUpdate(UpdateCase):
    def test_doctor_reports_versions_against_the_hub(self):
        h = self.hub()
        r = self.run_cli("doctor", "--json", urls=[h.url], env={"NEEDS_YOU_AUTO_UPDATE": "1"})
        checks = {c["check"]: c for c in json.loads(r.stdout)["checks"]}
        self.assertEqual(checks["update"]["status"], "WARN")
        self.assertIn("newer on the hub: needs-you", checks["update"]["detail"])
        self.assertEqual(checks["update"]["hint"], "run: needs-you update")
        self.assertEqual(read(self.cli), self.old_cli)   # doctor never changes anything

    def test_older_with_auto_update_off_says_how_to_turn_it_on(self):
        h = self.hub()
        r = self.run_cli("doctor", "--json", urls=[h.url])
        checks = {c["check"]: c for c in json.loads(r.stdout)["checks"]}
        self.assertEqual(checks["update"]["status"], "WARN")
        self.assertIn("daily auto-update off", checks["update"]["detail"])
        self.assertIn("nothing updates this machine on its own", checks["update"]["detail"])
        self.assertTrue(checks["update"]["hint"].startswith("run: needs-you update --enable-auto"))
        self.assertEqual(read(self.cli), self.old_cli)

    def test_up_to_date_with_auto_off_is_ok(self):
        h = self.hub()
        shutil.copy(CLI, self.cli)
        r = self.run_cli("doctor", "--json", urls=[h.url])
        checks = {c["check"]: c for c in json.loads(r.stdout)["checks"]}
        self.assertEqual(checks["update"]["status"], "OK", checks["update"])


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




class RequestedUpdate(UpdateCase):
    """A hub response with `update_requested` (the Mac's Request update): a reminder on stderr
    once a day, or with NEEDS_YOU_AUTO_UPDATE=1 the verified update, detached. Never the exit code."""

    REMINDER = "asked this machine to update: run `needs-you update`"

    def state(self):
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            return json.load(fh)

    def age_state(self, key, seconds):
        path = os.path.join(self.home, ".local", "state", "needs-you", "update.json")
        st = self.state()
        st[key] -= seconds
        with open(path, "w") as fh:
            json.dump(st, fh)

    def add(self, h, *extra, **kw):
        return self.run_cli(*(list(extra) + ["add", "--key", "k", "--title", "t"]), urls=[h.url], **kw)

    def manifest_fetches(self, h):
        return sum(1 for path, _ in h.headers if path == "/dl/manifest.json")

    def test_no_flag_no_reminder(self):
        h = self.hub()
        r = self.add(h)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(self.REMINDER, r.stderr)

    def test_reminder_at_most_once_a_day(self):
        h = self.hub()
        h.update_requested = True
        r = self.add(h, "-q")                      # quiet: no reminder, and it isn't used up
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        r = self.add(h)
        self.assertEqual(r.returncode, 0)
        self.assertIn("needs-you: 127.0.0.1 " + self.REMINDER, r.stderr)
        self.assertEqual(r.stderr.count(self.REMINDER), 1)
        r = self.add(h)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn(self.REMINDER, r.stderr)
        self.age_state("requested_update_noted_at", 24 * 3600 + 1)
        self.assertIn(self.REMINDER, self.add(h).stderr)
        self.assertEqual(self.manifest_fetches(h), 0)   # never updates on its own without opt-in

    def test_stderr_to_dev_null_does_not_use_up_the_reminder(self):
        h = self.hub()
        h.update_requested = True
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_URLS": h.url,
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_GH": "none"}
        r = subprocess.run([sys.executable, self.cli, "resolve", "--key", "k"], env=e,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        self.assertEqual(r.returncode, 0)
        self.assertIn(self.REMINDER, self.add(h).stderr)

    def test_auto_update_runs_detached_and_rate_limited(self):
        h = self.hub()
        h.update_requested = True
        env = {"NEEDS_YOU_AUTO_UPDATE": "1", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "0"}
        r = self.add(h, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(self.REMINDER, r.stderr)
        self.assertIn("created", r.stdout)
        # The background `update --auto` fetches the manifest and replaces the 0.0.1 CLI.
        self.assertTrue(wait_until(lambda: read(self.cli) == read(CLI), timeout=30))
        self.assertEqual(self.manifest_fetches(h), 1)
        ran_at = self.state()["requested_update_run_at"]
        # Within 6 hours: no second run, even if the machine is still behind.
        with open(self.cli, "wb") as fh:
            fh.write(self.old_cli)
        self.assertEqual(self.add(h, env=env).returncode, 0)
        self.assertEqual(self.state()["requested_update_run_at"], ran_at)
        self.assertEqual(self.manifest_fetches(h), 1)
        self.age_state("requested_update_run_at", 6 * 3600 + 1)
        self.assertEqual(self.add(h, env=env).returncode, 0)
        self.assertTrue(wait_until(lambda: read(self.cli) == read(CLI), timeout=30))

    def test_a_failing_background_update_never_reaches_the_caller(self):
        h = self.hub(bad={"needs-you"})
        h.update_requested = True
        r = self.add(h, env={"NEEDS_YOU_AUTO_UPDATE": "1", "NEEDS_YOU_UPDATE_REQUIRE_RELEASE_MATCH": "0"})
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        self.assertTrue(wait_until(lambda: self.manifest_fetches(h) == 1, timeout=30))
        self.assertEqual(read(self.cli), self.old_cli)


if __name__ == "__main__":
    unittest.main()
