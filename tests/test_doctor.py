"""`needs-you doctor`: read-only checks, exit codes, --json, and never printing the token."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import plistlib
import sys
import time
import unittest

from support import CLI
from test_cli import CliTestCase

HOOK_SRC = os.path.join(os.path.dirname(CLI), "..", "integrations", "claude-code", "needs-you-hook.sh")
MINIMAL_PATH = "/usr/bin:/bin"


def load_cli():
    loader = importlib.machinery.SourceFileLoader("needs_you_cli", CLI)
    spec = importlib.util.spec_from_loader("needs_you_cli", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def tree(root):
    """Every path under root with its size and mtime, to prove doctor wrote nothing. Skips
    ~/Library/Caches, where Apple's /usr/bin/python3 keeps its own bytecode cache."""
    out = {}
    caches = os.path.join(root, "Library", "Caches")
    for d, dirs, files in os.walk(root):
        if d == os.path.join(root, "Library"):
            dirs[:] = [x for x in dirs if x != "Caches"]
        for n in dirs + files:
            p = os.path.join(d, n)
            if p == caches or p == os.path.join(root, "Library"):
                continue
            st = os.lstat(p)
            out[p] = (st.st_size, st.st_mtime_ns)
    return out


class DoctorTestCase(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def write_env(self, lines, mode=0o600):
        d = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "env")
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(p, mode)
        return p

    def install_claude(self, hook_text=None, referenced=True, executable=True):
        hooks = os.path.join(self.home, ".claude", "hooks")
        os.makedirs(hooks, exist_ok=True)
        hook = os.path.join(hooks, "needs-you-hook.sh")
        if hook_text is None:
            with open(HOOK_SRC) as fh:
                hook_text = fh.read()
        with open(hook, "w") as fh:
            fh.write(hook_text)
        os.chmod(hook, 0o755 if executable else 0o644)
        settings = {"hooks": {"Stop": [{"hooks": [{"type": "command",
                                                   "command": '"$HOME/.claude/hooks/needs-you-hook.sh" resolve'}]}]}}
        with open(os.path.join(self.home, ".claude", "settings.json"), "w") as fh:
            json.dump(settings if referenced else {}, fh)
        skill = os.path.join(self.home, ".claude", "skills", "needs-you")
        os.makedirs(skill, exist_ok=True)
        with open(os.path.join(skill, "SKILL.md"), "w") as fh:
            fh.write("---\nname: needs-you\n---\n")

    def install_schedule(self):
        if sys.platform != "darwin":
            return
        d = os.path.join(self.home, "Library", "LaunchAgents")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "io.needs-you.flush.plist"), "wb") as fh:
            plistlib.dump({"Label": "io.needs-you.flush", "ProgramArguments": [CLI, "-q", "flush"],
                           "StartInterval": 300}, fh)

    def doctor(self, *args, extra_env=None, cwd=None):
        env = {"PATH": MINIMAL_PATH}
        env.update(extra_env or {})
        return self.run_cli("doctor", *args, urls=None, token=None, extra_env=env, cwd=cwd)

    def doctor_json(self, extra_env=None, cwd=None):
        r = self.doctor("--json", extra_env=extra_env, cwd=cwd)
        data = json.loads(r.stdout)
        return r, data, {c["check"]: c for c in data["checks"]}


class Healthy(DoctorTestCase):
    def test_all_ok_and_exit_zero(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender,
                        "NEEDS_YOU_AGENT_ALERTS=1"])
        self.install_claude()
        self.install_schedule()
        r, data, checks = self.doctor_json()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(data["ok"])
        for c in data["checks"]:
            self.assertEqual(set(c), {"check", "status", "detail", "hint"})
            self.assertIn(c["status"], ("OK", "WARN", "FAIL", "INFO"))
        self.assertEqual(checks["config"]["status"], "OK", checks["config"])
        self.assertIn("mode 600", checks["config"]["detail"])
        self.assertIn("NEEDS_YOU_TOKEN set (%d chars" % len(self.sender), checks["config"]["detail"])
        self.assertEqual(checks["hub 1"]["status"], "OK")
        self.assertIn("role=sender", checks["hub 1"]["detail"])
        self.assertIn("version", checks["hub 1"]["detail"])
        self.assertEqual(checks["hubs"]["status"], "OK")
        self.assertEqual(checks["outbox"]["status"], "OK")
        self.assertEqual(checks["claude hooks"]["status"], "OK", checks["claude hooks"])
        self.assertIn("alerts on", checks["claude hooks"]["detail"])
        self.assertEqual(checks["claude skill"]["status"], "OK")
        if sys.platform == "darwin":
            self.assertEqual(checks["flush schedule"]["status"], "OK", checks["flush schedule"])
        self.assertNotIn("orca", checks)  # no Orca here: the check is skipped
        self.assertEqual(checks["path"]["status"], "WARN")  # minimal PATH, no ~/.local/bin
        self.assertIn(".local/bin", checks["path"]["hint"])

    def test_plain_output(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender])
        r = self.doctor()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OK    config", r.stdout)
        self.assertIn("-> ", r.stdout)  # hints are printed under their line
        self.assertIn("claude hooks", r.stdout)
        # the minimal PATH is a WARN: the last line says so instead of a bare "ok"
        self.assertRegex(r.stdout, r"\nok, with \d+ warnings? \(WARN above\)\n$")


class NeverLeaksOrWrites(DoctorTestCase):
    def test_token_never_printed(self):
        bogus = "nyt_bogus_SECRET_VALUE_0123456789abcdef"
        cases = [("valid", self.sender, self.hub.url), ("rejected", bogus, self.hub.url),
                 ("unreachable", bogus, self.dead)]
        for label, tok, url in cases:
            self.write_env(["NEEDS_YOU_URLS=%s" % url, "NEEDS_YOU_TOKEN=%s" % tok])
            for args in ((), ("--json",)):
                with self.subTest(case=label, args=args):
                    r = self.doctor(*args)
                    self.assertNotIn(tok, r.stdout + r.stderr)
                    self.assertNotIn(tok[:12], r.stdout + r.stderr)
            # also with the token in the environment instead of the file
            r = self.run_cli("--json", "doctor", urls=[url], token=tok, extra_env={"PATH": MINIMAL_PATH})
            self.assertNotIn(tok, r.stdout + r.stderr)

    def test_changes_nothing_and_never_posts(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender])
        os.makedirs(self.outbox)
        name = "%020d-00001.json" % (time.time_ns() - 3 * 3600 * 10 ** 9)
        with open(os.path.join(self.outbox, name), "w") as fh:
            json.dump({"method": "POST", "path": "/v1/items",
                       "body": {"key": "queued", "title": "t", "source": {"host": "x"}}}, fh)
        before = tree(self.home)
        r, data, checks = self.doctor_json()
        self.assertEqual(tree(self.home), before)  # no flush, no prune, no new dirs
        self.assertEqual(self.items(self.hub, self.reader), [])
        self.assertEqual(checks["outbox"]["status"], "WARN")
        self.assertIn("1 queued, oldest 3h", checks["outbox"]["detail"])
        self.assertIn("needs-you flush", checks["outbox"]["hint"])

    def test_no_outbox_dir_is_not_created(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender])
        self.doctor()
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state")))


class Failures(DoctorTestCase):
    def test_no_config_fails(self):
        r, data, checks = self.doctor_json()
        self.assertEqual(r.returncode, 1)
        self.assertFalse(data["ok"])
        self.assertEqual(checks["config"]["status"], "FAIL")
        self.assertIn("invite", checks["config"]["hint"])
        self.assertEqual(checks["hubs"]["status"], "FAIL")

    def test_rejected_token_fails(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=not-a-real-token"])
        r, data, checks = self.doctor_json()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(checks["hub 1"]["status"], "FAIL")
        self.assertIn("token rejected", checks["hub 1"]["detail"])
        self.assertIn("--force", checks["hub 1"]["hint"])

    def test_reader_token_warns(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.reader])
        r, data, checks = self.doctor_json()
        self.assertEqual(checks["hub 1"]["status"], "WARN")
        self.assertEqual(checks["hubs"]["status"], "FAIL")
        self.assertEqual(r.returncode, 1)

    def test_loose_mode_warns(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender], mode=0o644)
        r, data, checks = self.doctor_json()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(checks["config"]["status"], "WARN")
        self.assertIn("chmod 600", checks["config"]["hint"])

    def test_only_fallback_answers_warns(self):
        self.write_env(["NEEDS_YOU_URLS=%s,%s" % (self.dead, self.hub.url), "NEEDS_YOU_TOKEN=%s" % self.sender])
        r, data, checks = self.doctor_json()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(checks["hub 1"]["status"], "WARN")
        self.assertEqual(checks["hub 2"]["status"], "OK")
        self.assertEqual(checks["hubs"]["status"], "WARN")
        self.assertIn("only a fallback", checks["hubs"]["detail"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS-only check")
    def test_loopback_not_first_warns_on_mac(self):
        self.write_env(["NEEDS_YOU_URLS=http://192.0.2.1:9,%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender])
        r, data, checks = self.doctor_json()
        self.assertEqual(checks["hub order"]["status"], "WARN")
        self.assertIn("first", checks["hub order"]["hint"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS-only check")
    def test_missing_launch_agent_warns(self):
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender])
        r, data, checks = self.doctor_json()
        self.assertEqual(checks["flush schedule"]["status"], "WARN")
        self.assertIn("io.needs-you.flush", checks["flush schedule"]["detail"])


class ClaudeAndOrca(DoctorTestCase):
    def setUp(self):
        super().setUp()
        self.write_env(["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender,
                        "NEEDS_YOU_ORCA_ENVIRONMENT=devbox"])

    def test_no_claude_is_info(self):
        r, data, checks = self.doctor_json()
        self.assertEqual(checks["claude hooks"]["status"], "INFO")
        self.assertEqual(checks["claude skill"]["status"], "INFO")
        self.assertEqual(r.returncode, 0)

    def test_old_hook_warns(self):
        self.install_claude(hook_text="#!/bin/bash\nexit 0\n")
        r, data, checks = self.doctor_json()
        self.assertEqual(checks["claude hooks"]["status"], "WARN")
        self.assertIn("old hook", checks["claude hooks"]["detail"])
        self.assertIn("re-run the installer", checks["claude hooks"]["hint"])

    def test_not_executable_and_not_referenced_warn(self):
        self.install_claude(executable=False, referenced=False)
        r, data, checks = self.doctor_json()
        detail = checks["claude hooks"]["detail"]
        self.assertEqual(checks["claude hooks"]["status"], "WARN")
        self.assertIn("not executable", detail)
        self.assertIn("doesn't reference", detail)

    def test_alerts_opt_in_state(self):
        self.install_claude()
        r, data, checks = self.doctor_json()
        self.assertIn("alerts off until opted in", checks["claude hooks"]["detail"])
        self.assertIn("NEEDS_YOU_AGENT_ALERTS=1", checks["claude hooks"]["hint"])
        r, data, checks = self.doctor_json(extra_env={"NEEDS_YOU_AGENT_ALERTS": "0"})
        self.assertIn("alerts off (NEEDS_YOU_AGENT_ALERTS=0 in env)", checks["claude hooks"]["detail"])
        r, data, checks = self.doctor_json(extra_env={"ORCA_TERMINAL_HANDLE": "term_1"})
        self.assertIn("alerts on (Orca session)", checks["claude hooks"]["detail"])

    def test_hook_settings_in_the_detail(self):
        self.install_claude()
        r, data, checks = self.doctor_json()
        self.assertIn("context alert at 80%", checks["claude hooks"]["detail"])
        self.assertNotIn("ssh alias", checks["claude hooks"]["detail"])
        r, data, checks = self.doctor_json(extra_env={"NEEDS_YOU_CONTEXT_ALERT_PCT": "0",
                                                      "NEEDS_YOU_SSH_ALIAS": "devbox",
                                                      "NEEDS_YOU_AGENT_LINK": "none"})
        detail = checks["claude hooks"]["detail"]
        for want in ("context alert off", "ssh alias devbox (env)", "agent link off (env)"):
            self.assertIn(want, detail)

    def test_project_hooks_reported_inside_the_project(self):
        proj = os.path.join(self.tmp, "proj")
        claude = os.path.join(proj, ".claude")
        os.makedirs(os.path.join(claude, "hooks"))
        os.makedirs(os.path.join(proj, "src", "deep"))
        with open(os.path.join(claude, "settings.local.json"), "w") as fh:
            json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command":
                       '"$CLAUDE_PROJECT_DIR/.claude/hooks/needs-you-hook.sh" stop'}]}]}}, fh)
        hook = os.path.join(claude, "hooks", "needs-you-hook.sh")
        with open(HOOK_SRC) as src, open(hook, "w") as fh:
            fh.write(src.read())
        os.chmod(hook, 0o755)
        r, data, checks = self.doctor_json()  # not in the project: no line
        self.assertNotIn("claude project hooks", checks)
        # A clone that merely ships such settings: reported, but not as this machine's install.
        r, data, checks = self.doctor_json(cwd=proj)
        self.assertEqual(checks["claude project hooks"]["status"], "WARN")
        self.assertIn("not installed from this machine", checks["claude project hooks"]["detail"])
        state = os.path.join(self.home, ".local", "state", "needs-you")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "claude-projects.json"), "w") as fh:
            json.dump({os.path.realpath(os.path.join(claude, "settings.local.json")): {"hooks_json_sha256": "x"}}, fh)
        r, data, checks = self.doctor_json(cwd=os.path.join(proj, "src", "deep"))
        line = checks["claude project hooks"]
        self.assertEqual(line["status"], "OK", line)
        self.assertIn("proj/.claude/settings.local.json", line["detail"])
        self.assertIn("alerts off until opted in", line["detail"])
        os.chmod(hook, 0o644)
        r, data, checks = self.doctor_json(cwd=proj)
        line = checks["claude project hooks"]
        self.assertEqual(line["status"], "WARN")
        self.assertIn("not executable", line["detail"])
        self.assertIn("--local", line["hint"])
        os.remove(hook)
        r, data, checks = self.doctor_json(cwd=proj)
        self.assertIn("is missing", checks["claude project hooks"]["detail"])

    def test_orca_reported_inside_orca(self):
        r, data, checks = self.doctor_json(extra_env={"ORCA_TERMINAL_HANDLE": "term_1"})
        detail = checks["orca"]["detail"]
        self.assertEqual(checks["orca"]["status"], "INFO")
        self.assertIn("ORCA_TERMINAL_HANDLE set", detail)
        self.assertIn("ORCA_WORKTREE_ID not set", detail)
        self.assertIn("NEEDS_YOU_ORCA_ENVIRONMENT=devbox (env file)", detail)


class Helpers(unittest.TestCase):
    def test_crontab_tag(self):
        cli = load_cli()
        self.assertTrue(cli.crontab_has_flush('*/5 * * * * "/h/.local/bin/needs-you" -q flush >/dev/null 2>&1 # needs-you-flush\n'))
        self.assertFalse(cli.crontab_has_flush("# */5 * * * * needs-you flush # needs-you-flush\n"))
        self.assertFalse(cli.crontab_has_flush(""))

    def test_age(self):
        cli = load_cli()
        self.assertEqual([cli._age(s) for s in (5, 600, 3 * 3600, 3 * 86400)], ["5s", "10m", "3h", "3d"])


if __name__ == "__main__":
    unittest.main()
