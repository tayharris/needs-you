"""OpenAI Codex CLI integration (integrations/codex/): the shared hook in `codex` mode, the
hooks.json installer, the end-to-end post and resolve against a real hub, `needs-you doctor`
and `needs-you update`.

Everything runs with a temporary HOME (and CODEX_HOME inside it), so the real ~/.codex,
~/.claude and ~/.config are never touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

from support import CLI, ROOT, HubTestCase, free_port, request, wait_until
from test_cli_update import UpdateCase, current_files, read

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
CODEX_HOOKS_JSON = os.path.join(ROOT, "integrations", "codex", "codex-hooks.json")
INSTALLER = os.path.join(ROOT, "integrations", "codex", "install-codex-hooks.sh")
REAL_HOME = os.path.expanduser("~")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"

# What Orca (or the user) may already have in ~/.codex/hooks.json.
OTHER_HOOK = {"type": "command", "command": "/bin/sh /opt/other/codex-hook.sh", "timeout": 10}


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class CodexHook(unittest.TestCase):
    """The hook with a fake `needs-you` that records its argv."""

    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-codex-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)

    def run_hook(self, mode, data, agent="codex", **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        env.update(extra)
        payload = {"session_id": "019a-codex-sess", "cwd": self.cwd, "model": "gpt-5-codex",
                   "permission_mode": "default", "transcript_path": None}
        payload.update(data)
        args = [BASH, HOOK, mode] + ([agent] if agent else [])
        r = subprocess.run(args, input=json.dumps(payload), env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "")  # Codex would add plain stdout to the model's context
        return r

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def permission(self, tool, tool_input):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "turn_id": "t1",
                                 "tool_name": tool, "tool_input": tool_input})
        return self.calls()[-1]

    # -- cards -------------------------------------------------------------
    def test_bash_names_only_the_program(self):
        argv = self.permission("Bash", {"command": "FOO=1 sudo make deploy TOKEN=%s" % SECRET,
                                        "description": "deploy with %s" % SECRET})
        self.assertEqual(argv[0], "add")
        self.assertEqual(opt(argv, "--title"), "Codex wants to run make: my-repo")
        self.assertEqual(opt(argv, "--agent"), "codex")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertTrue(opt(argv, "--key").endswith(":019a-codex-sess"))
        self.assertTrue(opt(argv, "--key").startswith("agent:"))
        self.assertNotIn(SECRET, json.dumps(argv))

    def test_apply_patch_names_the_file(self):
        patch = "*** Begin Patch\n*** Update File: src/app/config.py\n@@\n-a = '%s'\n+a = 1\n*** End Patch" % SECRET
        argv = self.permission("apply_patch", {"command": patch})
        self.assertEqual(opt(argv, "--title"), "Codex wants to edit config.py: my-repo")
        self.assertNotIn(SECRET, json.dumps(argv))
        patch2 = "*** Begin Patch\n*** Add File: a.txt\n+x\n*** Delete File: b.txt\n*** End Patch"
        self.assertEqual(opt(self.permission("apply_patch", {"command": patch2}), "--title"),
                         "Codex wants to edit 2 files: my-repo")
        self.assertEqual(opt(self.permission("apply_patch", {}), "--title"), "Codex wants to edit files: my-repo")

    def test_mcp_and_other_tools(self):
        self.assertEqual(opt(self.permission("mcp__linear__create_issue", {"title": SECRET}), "--title"),
                         "Codex needs permission for linear create_issue: my-repo")
        self.assertEqual(opt(self.permission("$(rm -rf /)", {}), "--title"),
                         "Codex needs permission for a tool: my-repo")

    def test_turn_end_card_has_no_assistant_text(self):
        self.run_hook("notify", {"hook_event_name": "Stop", "turn_id": "t1", "stop_hook_active": False,
                                 "last_assistant_message": "Here is the key: %s" % SECRET})
        argv = self.calls()[-1]
        self.assertEqual(opt(argv, "--title"), "Codex is waiting for you: my-repo")
        self.assertIn("finished its turn", opt(argv, "--body"))
        self.assertNotIn(SECRET, json.dumps(argv))

    def test_turn_cards_can_be_turned_off(self):
        self.run_hook("notify", {"hook_event_name": "Stop"}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.assertEqual(self.calls(), [])
        self.permission("Bash", {"command": "ls"})  # approvals still post
        self.assertEqual(len(self.calls()), 1)

    def test_turn_cards_setting_from_the_env_file(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_AGENT_TURN_CARDS=0\n")
        self.run_hook("notify", {"hook_event_name": "Stop"})
        self.assertEqual(self.calls(), [])

    def test_other_events_post_nothing(self):
        self.run_hook("notify", {"hook_event_name": "PreToolUse", "tool_name": "Bash"})
        self.assertEqual(self.calls(), [])

    def test_quiet_unless_opted_in(self):
        self.run_hook("notify", {"hook_event_name": "Stop"}, NEEDS_YOU_AGENT_ALERTS="")
        self.run_hook("notify", {"hook_event_name": "Stop"}, NEEDS_YOU_AGENT_ALERTS="0",
                      ORCA_TERMINAL_HANDLE="term_0123456789abcdef")
        self.assertEqual(self.calls(), [])
        self.run_hook("notify", {"hook_event_name": "Stop"}, NEEDS_YOU_AGENT_ALERTS="",
                      ORCA_TERMINAL_HANDLE="term_0123456789abcdef")
        argv = self.calls()[-1]
        self.assertTrue(opt(argv, "--key").endswith(":term_0123456789abcdef"))
        self.assertIn("Terminal=needsyou://orca/terminal?handle=term_0123456789abcdef",
                      [argv[i + 1] for i, a in enumerate(argv) if a == "--link"])

    def test_claude_mode_is_unchanged(self):
        # Without the agent argument the hook is the Claude Code hook.
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                 "tool_input": {"command": "ls"}}, agent=None)
        argv = self.calls()[-1]
        self.assertEqual(opt(argv, "--title"), "Claude wants to run ls: my-repo")
        self.assertEqual(opt(argv, "--agent"), "claude-code")

    # -- resolve -----------------------------------------------------------
    def wait_calls(self, n):
        self.assertTrue(wait_until(lambda: len(self.calls()) >= n, timeout=10), self.calls())
        return self.calls()

    def test_prompt_resolves_what_was_posted(self):
        self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit", "prompt": SECRET})
        time.sleep(0.2)
        self.assertEqual(self.calls(), [])  # nothing posted: no network call
        self.permission("Bash", {"command": "ls"})
        key = opt(self.calls()[-1], "--key")
        self.run_hook("resolve", {"hook_event_name": "PostToolUse", "tool_name": "Bash"})
        calls = self.wait_calls(2)
        self.assertEqual(calls[-1], ["resolve", "--key", key])
        self.assertEqual([n for n in os.listdir(self.state) if not n.startswith(".")], [])

    def test_interrupt_and_session_end_return_at_once(self):
        for mode, event in (("resolve", "Interrupt"), ("end", "SessionEnd")):
            self.run_hook("notify", {"hook_event_name": "Stop"})
            n = len(self.calls())
            started = time.time()
            # A CLI that hangs: the hook must not wait for it (Codex allows 1-3 s here).
            slow = os.path.join(self.home, "slow-cli")
            with open(slow, "w") as fh:
                fh.write("#!/bin/sh\nsleep 5\n")
            os.chmod(slow, 0o755)
            self.run_hook(mode, {"hook_event_name": event, "reason": "other"}, NEEDS_YOU_BIN=slow)
            self.assertLess(time.time() - started, 2.5, event)
            self.assertEqual(len(self.calls()), n)
            self.assertFalse(os.path.exists(os.path.join(self.state, "019a-codex-sess")))

    def test_marker_carries_a_lease_for_flush(self):
        self.permission("Bash", {"command": "ls"})
        with open(os.path.join(self.state, "019a-codex-sess")) as fh:
            m = dict(l.rstrip("\n").split("=", 1) for l in fh)
        self.assertEqual(m["kind"], "permission")
        self.assertTrue(m["key"].startswith("agent:"))
        self.assertEqual(m["pid"], str(os.getpid()))

    def test_clear_resolves_the_old_sessions_card(self):
        self.permission("Bash", {"command": "ls"})
        key = opt(self.calls()[-1], "--key")
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "clear", "session_id": "019b-new"})
        self.assertEqual(self.calls()[-1], ["resolve", "--key", key])
        # Codex sessions don't leave the Claude model memo behind.
        self.assertEqual([n for n in os.listdir(self.state) if n.startswith(".model-")], [])

    def fake_app_server(self):
        """A process that looks like Codex's shared app-server daemon (`codex app-server
        --listen unix:// --managed-daemon`), the parent of every hook since Codex 0.159."""
        p = subprocess.Popen([BASH, "-c", 'exec -a "codex app-server --listen unix:// --managed-daemon" sleep 60'])
        self.addCleanup(p.wait)
        self.addCleanup(p.kill)
        time.sleep(0.2)
        return str(p.pid)

    def test_clear_leaves_other_sessions_of_a_shared_app_server_alone(self):
        # Two Codex TUIs share one app-server daemon, so both sessions' leases name it.
        # /clear in one of them must not resolve the other's card.
        daemon = self.fake_app_server()
        self.run_hook("notify", {"hook_event_name": "Stop", "session_id": "019a-other"}, NY_HOOK_PPID=daemon)
        other = opt(self.calls()[-1], "--key")
        self.run_hook("notify", {"hook_event_name": "Stop"}, NY_HOOK_PPID=daemon)
        n = len(self.calls())
        with open(os.path.join(self.state, "019a-other")) as fh:
            self.assertIn("pid=%s\n" % daemon, fh.read())  # flush still reaps them if it dies
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "clear", "session_id": "019b-new"},
                      NY_HOOK_PPID=daemon)
        time.sleep(0.3)
        self.assertNotIn(["resolve", "--key", other], self.calls()[n:])
        self.assertTrue(os.path.exists(os.path.join(self.state, "019a-other")))
        # Compaction keeps the session id: its own card goes, the other stays.
        self.run_hook("start", {"hook_event_name": "SessionStart", "source": "compact"}, NY_HOOK_PPID=daemon)
        self.assertEqual([c[2] for c in self.wait_calls(n + 1)[n:]], [opt(self.calls()[n - 1], "--key")])
        self.assertTrue(os.path.exists(os.path.join(self.state, "019a-other")))


class CodexHooksJson(unittest.TestCase):
    def test_registers_the_events(self):
        with open(CODEX_HOOKS_JSON) as fh:
            doc = json.load(fh)
        self.assertNotIn("_needs_you_version", doc["hooks"])
        hooks = doc["hooks"]
        cmds = {ev: g[0]["hooks"][0]["command"] for ev, g in hooks.items()}
        self.assertEqual({ev: c.split()[-2:] for ev, c in cmds.items()},
                         {"PermissionRequest": ["notify", "codex"], "Stop": ["notify", "codex"],
                          "UserPromptSubmit": ["resolve", "codex"], "PostToolUse": ["resolve", "codex"],
                          "Interrupt": ["resolve", "codex"], "SessionStart": ["start", "codex"],
                          "SessionEnd": ["end", "codex"]})
        for ev, groups in hooks.items():
            h = groups[0]["hooks"][0]
            self.assertTrue(h["command"].startswith('"$HOME/.codex/hooks/needs-you-hook.sh" '))
            if ev in ("SessionEnd", "Interrupt"):
                # Synchronous in Codex, with a 3 s ceiling.
                self.assertNotIn("async", h)
                self.assertLessEqual(h["timeout"], 3)
            else:
                # Async: Codex never waits on the network, and PermissionRequest can't decide.
                self.assertTrue(h["async"])


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-codex-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.codex = os.path.join(self.home, ".codex")
        self.hooks_json = os.path.join(self.codex, "hooks.json")

    def run_installer(self, *args, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        e.update(env)
        return subprocess.run([BASH, INSTALLER] + list(args), env=e, capture_output=True, text=True, timeout=60)

    def load(self):
        with open(self.hooks_json) as fh:
            return json.load(fh)

    def test_install_keeps_other_hooks_and_is_idempotent(self):
        os.makedirs(self.codex)
        with open(self.hooks_json, "w") as fh:
            json.dump({"hooks": {"Stop": [{"hooks": [OTHER_HOOK]}],
                                 "PreToolUse": [{"matcher": "Bash", "hooks": [OTHER_HOOK]}]}}, fh)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("/hooks", r.stdout)  # tells the user to trust them
        doc = self.load()
        # Others first and untouched (their trust is recorded by position), ours appended.
        self.assertEqual(doc["hooks"]["Stop"][0], {"hooks": [OTHER_HOOK]})
        self.assertEqual(doc["hooks"]["Stop"][1]["hooks"][0]["command"],
                         '"$HOME/.codex/hooks/needs-you-hook.sh" notify codex')
        self.assertEqual(doc["hooks"]["PreToolUse"], [{"matcher": "Bash", "hooks": [OTHER_HOOK]}])
        self.assertIn("PermissionRequest", doc["hooks"])
        hook = os.path.join(self.codex, "hooks", "needs-you-hook.sh")
        self.assertEqual(read(hook), read(HOOK))
        self.assertTrue(os.stat(hook).st_mode & stat.S_IXUSR)
        backups = [n for n in os.listdir(self.codex) if n.startswith("hooks.json.bak-")]
        self.assertEqual(len(backups), 1)
        # Again: nothing changes.
        r = self.run_installer()
        self.assertIn("already up to date", r.stdout)
        self.assertEqual(self.load(), doc)
        # Uninstall: ours go, the others and their hook stay.
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.load(), {"hooks": {"Stop": [{"hooks": [OTHER_HOOK]}],
                                                 "PreToolUse": [{"matcher": "Bash", "hooks": [OTHER_HOOK]}]}})
        self.assertFalse(os.path.exists(hook))

    def test_fresh_install_and_codex_home(self):
        other = os.path.join(self.home, "elsewhere")
        r = self.run_installer(CODEX_HOME=other)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(other, "hooks.json")) as fh:
            cmd = json.load(fh)["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(cmd, '"%s/hooks/needs-you-hook.sh" notify codex' % other)
        self.assertTrue(os.path.exists(os.path.join(other, "hooks", "needs-you-hook.sh")))
        self.assertFalse(os.path.exists(self.codex))

    def test_invalid_json_is_left_alone(self):
        os.makedirs(self.codex)
        with open(self.hooks_json, "w") as fh:
            fh.write("{not json")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not valid JSON", r.stderr)
        with open(self.hooks_json) as fh:
            self.assertEqual(fh.read(), "{not json")

    def test_dry_run_writes_nothing(self):
        r = self.run_installer("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry run", r.stdout)
        self.assertFalse(os.path.exists(self.codex))

    def test_symlinked_hooks_json_is_refused(self):
        os.makedirs(self.codex)
        target = os.path.join(self.home, "elsewhere.json")
        with open(target, "w") as fh:
            fh.write('{"hooks": {}}')
        os.symlink(target, self.hooks_json)
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        self.assertTrue(os.path.islink(self.hooks_json))
        with open(target) as fh:
            self.assertEqual(fh.read(), '{"hooks": {}}')
        self.assertEqual([n for n in os.listdir(self.home) if n.startswith("elsewhere")], ["elsewhere.json"])
        r = self.run_installer("--uninstall")
        self.assertNotEqual(r.returncode, 0)

    def test_malformed_shapes_are_left_alone(self):
        os.makedirs(self.codex)
        for text in ('[1, 2]', '{"hooks": []}', '"hooks"'):
            with open(self.hooks_json, "w") as fh:
                fh.write(text)
            r = self.run_installer()
            self.assertNotEqual(r.returncode, 0, text)
            with open(self.hooks_json) as fh:
                self.assertEqual(fh.read(), text)

    def test_hook_copy_replaces_a_symlink_instead_of_following_it(self):
        hooks = os.path.join(self.codex, "hooks")
        os.makedirs(hooks)
        victim = os.path.join(self.home, "victim.sh")
        with open(victim, "w") as fh:
            fh.write("keep\n")
        os.symlink(victim, os.path.join(hooks, "needs-you-hook.sh"))
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.islink(os.path.join(hooks, "needs-you-hook.sh")))
        with open(victim) as fh:
            self.assertEqual(fh.read(), "keep\n")

    def test_warns_when_hooks_are_disabled(self):
        os.makedirs(self.codex)
        with open(os.path.join(self.codex, "config.toml"), "w") as fh:
            fh.write('model = "x"\n\n[features]\nhooks = false\n')
        r = self.run_installer()
        self.assertIn("hooks = false", r.stdout)


class EndToEnd(HubTestCase):
    """The installed hook and the real CLI against a real hub."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.hub = self.make_hub("hub-a", peers=[])
        self.sender, self.reader = self.tokens(self.hub)
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.hook = os.path.join(self.home, ".codex", "hooks", "needs-you-hook.sh")

    def run_hook(self, mode, data, url):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URLS": url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}
        payload = {"session_id": "019a-e2e", "cwd": "/srv/my-repo"}
        payload.update(data)
        r = subprocess.run([BASH, self.hook, mode, "codex"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def items(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        return [i for i in body["items"] if i["key"].endswith(":019a-e2e")]

    def test_post_then_resolve(self):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                 "tool_input": {"command": "pytest -q"}}, self.hub.url)
        items = self.items()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["title"], "Codex wants to run pytest: my-repo")
        self.assertEqual(items[0]["kind"], "needs")
        self.assertEqual(items[0]["status"], "open")
        self.assertEqual(items[0]["source"]["agent"], "codex")
        self.run_hook("resolve", {"hook_event_name": "UserPromptSubmit"}, self.hub.url)
        self.assertTrue(wait_until(lambda: self.items()[0]["status"] == "resolved", timeout=10), self.items())

    def test_hub_down_still_exits_0_and_queues(self):
        dead = "http://127.0.0.1:%d" % free_port()
        self.run_hook("notify", {"hook_event_name": "Stop"}, dead)
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        queued = [n for n in os.listdir(outbox) if n.endswith(".json")] if os.path.isdir(outbox) else []
        self.assertEqual(len(queued), 1, os.listdir(os.path.join(self.home, ".local", "state", "needs-you")))
        self.assertEqual(self.items(), [])


class Doctor(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-codex-doc-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.codex = os.path.join(self.home, ".codex")

    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "codex hooks"]
        return rows[0] if rows else None

    def install(self):
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_no_codex_no_line(self):
        self.assertIsNone(self.check())

    def test_not_installed_is_info(self):
        os.makedirs(self.codex)
        row = self.check()
        self.assertEqual(row["status"], "INFO")
        self.assertIn("--codex-hooks user", row["hint"])

    def test_installed_is_ok_and_mentions_trust(self):
        self.install()
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("alerts on", row["detail"])
        self.assertIn("/hooks", row["hint"])

    def test_malformed_config_is_only_read(self):
        self.install()
        hooks_json = os.path.join(self.codex, "hooks.json")
        config = os.path.join(self.codex, "config.toml")
        # Garbage in config.toml (binary, a fake command) is data: doctor doesn't crash or run it.
        marker = os.path.join(self.home, "ran")
        with open(config, "wb") as fh:
            fh.write(b'\xff\xfe[features\nhooks = "$(touch %s)"\n[hooks.state."\n' % marker.encode())
        self.assertEqual(self.check()["status"], "OK")
        self.assertFalse(os.path.exists(marker))
        for text in ("[1, 2]", '{"hooks": {"PermissionRequest": "x"}}', "{not json"):
            with open(hooks_json, "w") as fh:
                fh.write(text + " needs-you-hook.sh" if text.startswith("{not") else text)
            row = self.check()
            self.assertIn(row["status"], ("OK", "WARN"), text)
        with open(hooks_json, "w") as fh:
            fh.write("{not json")
        self.assertEqual(self.check()["status"], "WARN")

    def test_disabled_missing_and_untrusted_warn(self):
        self.install()
        config = os.path.join(self.codex, "config.toml")
        with open(config, "w") as fh:
            fh.write("[features]\nhooks = false\n")
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("hooks = false", row["detail"])
        # Codex has recorded trust for this file, but not for our entry.
        with open(config, "w") as fh:
            fh.write('[hooks.state."%s/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:00"\n' % self.codex)
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("trusted", row["detail"])
        with open(config, "a") as fh:
            fh.write('[hooks.state."%s/hooks.json:permission_request:0:0"]\ntrusted_hash = "sha256:00"\n' % self.codex)
        self.assertEqual(self.check()["status"], "OK")
        os.remove(os.path.join(self.codex, "hooks", "needs-you-hook.sh"))
        row = self.check()
        self.assertEqual(row["status"], "WARN")
        self.assertIn("missing", row["detail"])


class Update(UpdateCase):
    """`needs-you update` keeps the Codex copy of the hook and its hooks.json entries current."""

    def files(self):
        f = current_files()
        f["install-codex-hooks.sh"] = read(INSTALLER)
        f["codex-hooks.json"] = read(CODEX_HOOKS_JSON)
        return f

    def test_codex_hook_and_entries(self):
        h = self.hub(files=self.files())
        hook = self.install(".codex/hooks/needs-you-hook.sh", mode=0o755)
        hooks_json = self.install(".codex/hooks.json", json.dumps({"hooks": {"Stop": [
            {"hooks": [OTHER_HOOK]},
            {"hooks": [{"type": "command", "command": '"$HOME/.codex/hooks/needs-you-hook.sh" notify codex'}]}]}}).encode())
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        files = sorted(c["file"] for c in json.loads(r.stdout)["changes"])
        self.assertEqual(files, ["codex-hooks.json", "needs-you", "needs-you-hook.sh"])
        r = self.run_cli("update", "--check", urls=[h.url])
        self.assertIn("would update needs-you-hook.sh (Codex)", r.stdout)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(hook), read(HOOK))
        with open(hooks_json) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["hooks"]["Stop"][0], {"hooks": [OTHER_HOOK]})
        self.assertIn("PermissionRequest", doc["hooks"])
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            st = json.load(fh)
        self.assertEqual(st["codex_hooks_json_sha256"], hashlib.sha256(read(CODEX_HOOKS_JSON)).hexdigest())
        self.assertIn("codex-needs-you-hook.sh", st["backups"])
        # Nothing left to do, and the Claude hook wasn't installed by it.
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))
        # Rollback puts the old Codex hook back.
        r = self.run_cli("update", "--rollback", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(read(hook), b"old\n# needs-you-version: 0.0.1\n")

    def test_symlinked_hook_and_config_are_not_written(self):
        h = self.hub(files=self.files())
        victim = self.install("victim.sh", b"keep\n")
        os.makedirs(os.path.join(self.home, ".codex", "hooks"))
        os.symlink(victim, os.path.join(self.home, ".codex", "hooks", "needs-you-hook.sh"))
        real_json = self.install("dotfiles/codex-hooks.json", json.dumps({"hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": '"$HOME/.codex/hooks/needs-you-hook.sh" notify codex'}]}]}}).encode())
        before = read(real_json)
        os.symlink(real_json, os.path.join(self.home, ".codex", "hooks.json"))
        r = self.run_cli("update", urls=[h.url])
        self.assertIn("symlink", r.stdout + r.stderr)
        self.assertEqual(read(victim), b"keep\n")
        self.assertEqual(read(real_json), before)


if __name__ == "__main__":
    unittest.main()
