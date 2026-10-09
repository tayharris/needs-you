"""Kimi Code CLI integration (integrations/kimi/): the shared hook in `kimi` mode.

The payloads are the ones Kimi Code 2.1.1 sends (captured live with a temporary
KIMI_CODE_HOME and a stub model server): snake_case keys, `session_id` like
`session_<uuid>`, `client_type: kimi_code_cli`. Kimi awaits Stop, UserPromptSubmit,
PreToolUse and the session hooks, starts every hook through `sh -c` in a process group of
its own, and kills that group when a hook runs past its timeout: the hook hands its work to
a copy in a new session and returns at once, so the tests wait for the fake CLI's log.
Everything runs with a temporary HOME, so the real ~/.kimi-code, ~/.claude and ~/.config
are never touched.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from hook_case import fixture, posted_item, step_texts, choice_texts
from support import CLI, ROOT, HubTestCase, free_port, request, wait_until
from test_cli_update import UpdateCase, current_files, read

try:
    import tomllib  # Python 3.11+: checks the TOML the installer writes; 3.9 skips that part
except ImportError:  # pragma: no cover
    tomllib = None

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")
KIMI_HOOKS_TOML = os.path.join(ROOT, "integrations", "kimi", "kimi-hooks.toml")
INSTALLER = os.path.join(ROOT, "integrations", "kimi", "install-kimi-hooks.sh")
REAL_HOME = os.path.expanduser("~")
START = "# needs-you (managed by install-kimi-hooks.sh; do not edit between these markers)"
END = "# end needs-you"

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys, time
time.sleep(float(os.environ.get("FAKE_CLI_SLEEP") or 0))
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""

SECRET = "sk-test-SECRET-0123456789"
SESSION = "session_68842dd7-40c1-4f7d-8df5-31ccf7275b7b"


def opt(argv, name):
    for i, a in enumerate(argv):
        if a.startswith(name + "="):
            return a[len(name) + 1:]
        if a == name:
            return argv[i + 1]
    raise ValueError(name)


class KimiHook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-kimi-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.cwd = os.path.join(self.home, "src", "my-repo")
        os.makedirs(self.cwd)

    def env(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_AGENT_ALERTS": "1",
               "NEEDS_YOU_HOOK_PLATFORM": "linux", "NY_KIMI_TURN_WAIT": "0"}
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def payload(self, event, data):
        p = {"hook_event_name": event, "session_id": SESSION, "cwd": self.cwd, "client_type": "kimi_code_cli"}
        p.update(data)
        return json.dumps(p)

    def run_hook(self, mode, event, data, **extra):
        started = time.time()
        r = subprocess.run([BASH, HOOK, mode, "kimi"], input=self.payload(event, data), env=self.env(**extra),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        # Kimi appends a UserPromptSubmit hook's stdout to the model's context, and reads a
        # Stop hook's JSON as a decision: the hook prints nothing and returns at once.
        self.assertEqual((r.stdout, r.stderr), ("", ""))
        self.assertLess(time.time() - started, 5)
        return r

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh]
        except OSError:
            return []

    def wait_calls(self, n):
        self.assertTrue(wait_until(lambda: len(self.calls()) >= n, timeout=10), self.calls())
        time.sleep(0.1)
        return self.calls()

    def marker(self):
        path = os.path.join(self.state, SESSION)
        self.assertTrue(wait_until(lambda: os.path.exists(path), timeout=10))
        with open(path) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)

    def permission(self, tool, display, tool_input, n):
        self.run_hook("notify", "PermissionRequest", {
            "id": "approval_1", "agent_id": "main", "turn_id": "t1", "tool_call_id": "call_1",
            "tool_name": tool, "action": "Running: " + json.dumps(tool_input), "display": display,
            "tool_input": tool_input, "session_title": SECRET})
        return self.wait_calls(n)[-1]

    def test_permission_card_names_only_the_program(self):
        cmd = "API_KEY=%s make deploy" % SECRET
        argv = self.permission("Bash", {"kind": "command", "command": cmd, "cwd": self.cwd,
                                        "description": SECRET, "language": "bash"}, {"command": cmd}, 1)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to run make: my-repo")
        self.assertEqual(opt(argv, "--agent"), "kimi-code")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], SESSION)
        self.assertEqual(self.marker()["kind"], "permission")
        argv = self.permission("Write", {"kind": "file"}, {"path": "/x/secrets/.env.prod", "content": SECRET}, 2)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to edit .env.prod: my-repo")
        argv = self.permission("Edit", {}, {"file_path": "/x/a.py", "old_string": SECRET}, 3)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to edit a.py: my-repo")
        argv = self.permission("FetchURL", {}, {"url": "https://example.com/?t=" + SECRET}, 4)
        self.assertEqual(opt(argv, "--title"), "Kimi wants to fetch a page: my-repo")
        argv = self.permission("ExitPlanMode", {"kind": "plan_review", "plan": "Use %s" % SECRET}, {}, 5)
        self.assertEqual(opt(argv, "--title"), "Kimi wants approval for a plan: my-repo")
        self.assertIn("Use [redacted]", opt(argv, "--body"))
        argv = self.permission("mcp__github__create_issue", {}, {"body": SECRET}, 6)
        self.assertEqual(opt(argv, "--title"), "Kimi needs permission for github create_issue: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_question_card_from_the_captured_payload(self):
        data = fixture("kimi-ask-user-question.json")
        data.update(session_id=SESSION, cwd=self.cwd)
        subprocess.run([BASH, HOOK, "notify", "kimi"], input=json.dumps(data), env=self.env(),
                       capture_output=True, text=True, timeout=30)
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"),
                         "Kimi asks \u201cWhich database should the service use?\u201d and 1 more: please ask me (my-repo)")
        body = opt(argv, "--body")
        self.assertTrue(body.startswith(
            "**Database** \u00b7 choose one\nWhich database should the service use?\n"
            "- Postgres (Recommended) \u2014 Mature, already used by the team.\n- SQLite \u2014 Zero ops, single file."
            "\n\n**Question 2** \u00b7 choose any\nWhich extras do you want?\n- Metrics\n- Tracing \u2014 OpenTelemetry"), body)
        self.assertEqual(json.loads(opt(argv, "--question-json"))["id"], "call_AskUserQuestion_1")
        self.assertIn("Answer in Kimi", body)
        self.assertEqual(choice_texts(argv), [
            "Database: Postgres (Recommended) \u2014 Mature, already used by the team.",
            "Database: SQLite \u2014 Zero ops, single file.", "Metrics", "Tracing \u2014 OpenTelemetry"])
        self.assertEqual(self.marker()["kind"], "question")
        # NEEDS_YOU_AGENT_QUESTIONS=0: the old card, no text, no steps
        subprocess.run([BASH, HOOK, "notify", "kimi"], input=json.dumps(data),
                       env=self.env(NEEDS_YOU_AGENT_QUESTIONS="0"), capture_output=True, text=True, timeout=30)
        argv = self.wait_calls(2)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi asked you a question: please ask me (my-repo)")
        self.assertNotIn("database", json.dumps(argv).lower())
        self.assertFalse(posted_item(argv)["steps"])

    def test_plan_card_from_the_captured_payload(self):
        data = fixture("kimi-exit-plan-mode.json")
        data.update(session_id=SESSION, cwd=self.cwd)
        subprocess.run([BASH, HOOK, "notify", "kimi"], input=json.dumps(data), env=self.env(),
                       capture_output=True, text=True, timeout=30)
        argv = self.wait_calls(1)[-1]
        # the captured payload's session_title names the session
        self.assertEqual(opt(argv, "--title"), "Kimi wants approval for a plan: plan it (my-repo)")
        self.assertTrue(opt(argv, "--body").startswith("**Plan**\n1. Do the thing.\n\nApprove or reject it in Kimi."))
        self.assertEqual(step_texts(argv), ["Small refactor (Recommended) \u2014 Touch two files.",
                                            "Rewrite \u2014 Start over."])
        self.assertEqual(self.marker()["kind"], "permission")

    def test_huge_plan_through_the_background_copy(self):
        # Kimi's hooks hand their work to a detached copy (setsid, or perl on macOS): a payload
        # over 200 KB still reaches it and its Python, and leaves no file behind.
        plan = "# Big plan\n\n" + "".join("%d. Step %s\n" % (i, "y" * 70) for i in range(3500))
        self.assertGreater(len(plan), 200 * 1024)
        tmp = os.path.join(self.home, "tmp")
        os.makedirs(tmp)
        self.run_hook("notify", "PermissionRequest", {
            "tool_name": "ExitPlanMode", "tool_call_id": "c9", "tool_input": {},
            "display": {"kind": "plan_review", "plan": plan}}, TMPDIR=tmp)
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi wants approval for a plan: my-repo")
        self.assertTrue(opt(argv, "--body").startswith("**Big plan**\n0. Step yyy"))
        posted_item(argv)
        self.marker()
        self.assertEqual(os.listdir(tmp), [])

    def test_question_turn_end_and_failure(self):
        self.run_hook("notify", "PreToolUse", {"tool_name": "AskUserQuestion", "tool_call_id": "c2",
                                               "tool_input": {"questions": [{"question": SECRET}]}})
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi asks \u201c[redacted]\u201d: my-repo")
        # PreToolUse for any other tool (a wider matcher by hand) posts nothing
        self.run_hook("notify", "PreToolUse", {"tool_name": "Bash", "tool_input": {"command": "ls"}})
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        # the question card the turn ended under is resolved, then the turn-end card posts
        calls = self.wait_calls(3)
        self.assertEqual(calls[1][0], "resolve")
        argv = calls[2]
        self.assertEqual(opt(argv, "--title"), "Kimi finished: my-repo")
        self.run_hook("notify", "StopFailure", {"error_type": "rate_limit", "error_message": "429 Too Many Requests"})
        argv = self.wait_calls(4)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi stopped on an error: my-repo")
        self.assertIn("429 Too Many Requests", opt(argv, "--body"))
        self.assertEqual(self.marker()["kind"], "failure")
        time.sleep(0.3)
        self.assertEqual(len(self.calls()), 4)
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_turn_cards_can_be_turned_off_and_opt_in_is_required(self):
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NEEDS_YOU_AGENT_ALERTS=None)
        self.run_hook("notify", "PermissionRequest", {"tool_name": "Bash", "display": {"command": "ls"}},
                      NEEDS_YOU_AGENT_ALERTS="0")
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])

    def test_no_turn_card_from_a_one_shot_run(self):
        # `kimi -p` ends its turn (Stop) and exits a moment later: nobody is waiting, so no
        # card. The turn-end card waits that moment and checks Kimi is still there.
        gone = subprocess.Popen(["true"])
        gone.wait()
        self.run_hook("notify", "Stop", {"stop_hook_active": False}, NY_HOOK_PPID=str(gone.pid),
                      NY_KIMI_TURN_WAIT="0.5")
        time.sleep(1.5)
        self.assertEqual(self.calls(), [])
        self.assertFalse(os.path.exists(os.path.join(self.state, SESSION)))

    def test_answer_prompt_tool_interrupt_and_session_end_resolve(self):
        self.permission("Bash", {"command": "make"}, {"command": "make"}, 1)
        key = opt(self.calls()[-1], "--key")
        self.marker()
        self.run_hook("resolve", "PermissionResult", {"tool_name": "Bash", "decision": "approved",
                                                      "feedback": SECRET})
        self.assertEqual(self.wait_calls(2)[-1], ["resolve", "--key", key])
        self.run_hook("resolve", "PostToolUse", {"tool_name": "Bash", "tool_output": SECRET})
        time.sleep(0.5)
        self.assertEqual(len(self.calls()), 2)  # nothing open: no network call
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(3)
        self.marker()
        self.run_hook("resolve", "UserPromptSubmit", {"prompt": [{"type": "text", "text": SECRET}],
                                                      "is_steer": False})
        self.assertEqual(self.wait_calls(4)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(5)
        self.marker()
        self.run_hook("resolve", "Interrupt", {"turn_id": "t2", "reason": "user"})
        self.assertEqual(self.wait_calls(6)[-1], ["resolve", "--key", key])
        self.run_hook("notify", "Stop", {"stop_hook_active": False})
        self.wait_calls(7)
        self.marker()
        self.run_hook("end", "SessionEnd", {"reason": "exit"})
        self.assertEqual(self.wait_calls(8)[-1], ["resolve", "--key", key])
        self.assertNotIn(SECRET, json.dumps(self.calls()))

    def test_lease_names_kimi_not_the_shell_it_starts_hooks_with(self):
        # Kimi runs `sh -c '<command>'`; by the time the background copy looks, that shell has
        # exited, so the foreground names its parent (Kimi) for the lease.
        script = '"$0" "$@"; exit 0'  # a shell between "Kimi" (this test) and the hook, gone at once
        r = subprocess.run(["sh", "-c", script, BASH, HOOK, "notify", "kimi"],
                           input=self.payload("PermissionRequest", {"tool_name": "Bash", "display": {"command": "make"}}),
                           env=self.env(), capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.wait_calls(1)
        self.assertEqual(self.marker()["pid"], str(os.getpid()))

    def test_background_work_survives_the_process_group_kill(self):
        # Kimi kills a hook's whole process group (SIGTERM, then SIGKILL) when it runs past its
        # timeout. The background copy runs in a session of its own, so a slow hub doesn't
        # lose the card.
        p = subprocess.Popen([BASH, HOOK, "notify", "kimi"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, env=self.env(FAKE_CLI_SLEEP="1.5"),
                             start_new_session=True, text=True)
        p.communicate(self.payload("PermissionRequest", {"tool_name": "Bash", "display": {"command": "make"}}),
                      timeout=10)
        time.sleep(0.3)
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        argv = self.wait_calls(1)[-1]
        self.assertEqual(opt(argv, "--title"), "Kimi wants to run make: my-repo")


def hook_tables(text):
    """The [[hooks]] tables in a block, parsed by hand (Python 3.9 has no tomllib)."""
    tables, cur = [], None
    for line in text.splitlines():
        line = line.strip()
        if line == "[[hooks]]":
            cur = {}
            tables.append(cur)
        elif cur is not None and "=" in line and not line.startswith("#"):
            k, v = (x.strip() for x in line.split("=", 1))
            cur[k] = v
    return tables


class KimiHooksToml(unittest.TestCase):
    def test_registers_the_events_with_only_the_keys_kimi_allows(self):
        text = read(KIMI_HOOKS_TOML).decode()
        lines = text.splitlines()
        self.assertEqual(lines[0], START)
        self.assertEqual(lines[-1], END)
        self.assertRegex(lines[1], r"^# needs-you-version: \d+\.\d+\.\d+$")
        tables = hook_tables(text)
        got = {}
        for t in tables:
            # Any key besides these four makes Kimi refuse the whole config.
            self.assertLessEqual(set(t), {"event", "matcher", "command", "timeout"}, t)
            self.assertTrue(t["command"].startswith("'\"$HOME/.kimi-code/hooks/needs-you-hook.sh\" "), t)
            self.assertLessEqual(int(t["timeout"]), 30)
            got[t["event"].strip('"')] = t["command"].strip("'").split()[-2:]
        self.assertEqual(got, {
            "PermissionRequest": ["notify", "kimi"], "PreToolUse": ["notify", "kimi"], "Stop": ["notify", "kimi"],
            "StopFailure": ["notify", "kimi"], "PermissionResult": ["resolve", "kimi"],
            "UserPromptSubmit": ["resolve", "kimi"], "PostToolUse": ["resolve", "kimi"],
            "PostToolUseFailure": ["resolve", "kimi"], "Interrupt": ["resolve", "kimi"],
            "SessionStart": ["start", "kimi"], "SessionEnd": ["end", "kimi"]})
        self.assertEqual([t.get("matcher") for t in tables if t["event"] == '"PreToolUse"'], ['"^AskUserQuestion$"'])
        if tomllib:
            doc = tomllib.loads(text)
            self.assertEqual(len(doc["hooks"]), len(tables))


USER_CONFIG = """# my Kimi config
default_model = "kimi"

[[hooks]]
event = "Stop"
command = "notify-send done"

[providers.kimi]
type = "kimi"
api_key = "x"
"""


class Installer(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-kimi-inst-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.assertNotEqual(self.home, REAL_HOME)
        self.kimi = os.path.join(self.home, ".kimi-code")
        self.conf = os.path.join(self.kimi, "config.toml")
        self.hook = os.path.join(self.kimi, "hooks", "needs-you-hook.sh")

    def run_installer(self, *args, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        e.update(env)
        e = {k: v for k, v in e.items() if v is not None}
        return subprocess.run([BASH, INSTALLER] + list(args), env=e, capture_output=True, text=True, timeout=60)

    def write_conf(self, text, path=None):
        path = path or self.conf
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)

    def text(self, path=None):
        with open(path or self.conf) as fh:
            return fh.read()

    def backups(self):
        return [n for n in os.listdir(self.kimi) if n.startswith("config.toml.bak-")]

    def test_install_rerun_and_uninstall_keep_the_rest_byte_for_byte(self):
        self.write_conf(USER_CONFIG.rstrip("\n"))  # no trailing newline
        os.chmod(self.conf, 0o600)
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("added the needs-you block", r.stdout)
        self.assertIn("kimi doctor", r.stdout)
        text = self.text()
        self.assertTrue(text.startswith(USER_CONFIG.rstrip("\n") + "\n\n" + START + "\n"), text)
        self.assertTrue(text.endswith(END + "\n"))
        self.assertEqual(text.count(START), 1)
        self.assertEqual(os.stat(self.conf).st_mode & 0o777, 0o600)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(read(self.hook), read(HOOK))
        self.assertTrue(os.access(self.hook, os.X_OK))
        if tomllib:
            doc = tomllib.loads(text)
            self.assertEqual(doc["hooks"][0], {"event": "Stop", "command": "notify-send done"})
            self.assertEqual(doc["providers"]["kimi"]["type"], "kimi")
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count("already up to date"), 2)
        self.assertEqual(self.text(), text)
        self.assertEqual(len(self.backups()), 1)
        # an older block is replaced in place, not added twice
        self.write_conf(text.replace("timeout = 10", "timeout = 9"))
        r = self.run_installer()
        self.assertIn("updated the needs-you block", r.stdout)
        self.assertEqual(self.text(), text)
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.text(), USER_CONFIG.rstrip("\n"))  # no newline added for good
        self.assertFalse(os.path.exists(self.hook))
        r = self.run_installer("--uninstall")
        self.assertIn("no needs-you block", r.stdout)
        # the CLI's offline uninstall gives it back the same way
        self.assertEqual(self.run_installer().returncode, 0)
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--kimi"],
                           env={"HOME": self.home, "PATH": os.environ["PATH"]},
                           capture_output=True, text=True, timeout=60, cwd=self.home)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.text(), USER_CONFIG.rstrip("\n"))

    def test_fresh_home_and_kimi_code_home(self):
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.text(), read(KIMI_HOOKS_TOML).decode())
        self.assertEqual(self.backups(), [])
        other = os.path.join(self.home, "k2")
        r = self.run_installer(KIMI_CODE_HOME=other)
        self.assertEqual(r.returncode, 0, r.stderr)
        text = self.text(os.path.join(other, "config.toml"))
        self.assertIn("command = '\"%s/hooks/needs-you-hook.sh\" notify kimi'" % other, text)
        self.assertNotIn("$HOME", text)
        self.assertTrue(os.path.isfile(os.path.join(other, "hooks", "needs-you-hook.sh")))
        r = self.run_installer("--kimi-home", os.path.join(self.home, "k3"))
        self.assertIn("only when it runs with KIMI_CODE_HOME=", r.stdout)
        r = self.run_installer("--kimi-home", os.path.join(self.home, "it's"))
        self.assertNotEqual(r.returncode, 0)

    def test_dry_run_writes_nothing(self):
        self.write_conf(USER_CONFIG)
        r = self.run_installer("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry run", r.stdout)
        self.assertEqual(self.text(), USER_CONFIG)
        self.assertFalse(os.path.exists(self.hook))
        self.assertEqual(self.backups(), [])

    def test_refuses_what_it_cant_append_to(self):
        for bad in ('hooks = []\n', '[hooks]\nx = 1\n', '[hooks.Stop]\ncommand = "x"\n',
                    'matrix = [\n  [1, 2],\n  ["a"],\n]\nhooks = []\n',  # rows of a root array aren't tables
                    START + "\n[[hooks]]\n"):  # a block with no end marker
            self.write_conf(bad)
            r = self.run_installer()
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertIn("nothing was changed", r.stderr.lower(), bad)
            self.assertEqual(self.text(), bad)
            self.assertFalse(os.path.exists(self.hook))
        # `hooks = ...` inside another table is that table's key, not a conflict
        self.write_conf('[plugins.x]\nhooks = ["a"]\n')
        self.assertEqual(self.run_installer().returncode, 0)

    def test_symlinks_are_refused(self):
        os.makedirs(self.kimi)
        victim = os.path.join(self.home, "victim.toml")
        with open(victim, "w") as fh:
            fh.write("keep\n")
        os.symlink(victim, self.conf)
        for args in ((), ("--uninstall",)):
            r = self.run_installer(*args)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("symlink", r.stderr)
        self.assertEqual(self.text(victim), "keep\n")
        self.assertFalse(os.path.exists(self.hook))


class EndToEnd(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.hub = self.make_hub("hub-a", peers=[])
        self.sender, self.reader = self.tokens(self.hub)
        r = subprocess.run([BASH, INSTALLER], env={"HOME": self.home, "PATH": os.environ.get("PATH", "")},
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.hook = os.path.join(self.home, ".kimi-code", "hooks", "needs-you-hook.sh")

    def run_hook(self, mode, data, url):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URLS": url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux", "NY_KIMI_TURN_WAIT": "0"}
        payload = {"session_id": "session_e2e", "cwd": "/srv/my-repo", "client_type": "kimi_code_cli"}
        payload.update(data)
        r = subprocess.run([BASH, self.hook, mode, "kimi"], input=json.dumps(payload), env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def items(self):
        _, body = request("GET", self.hub.url + "/v1/items?status=all", self.reader)
        return [i for i in body["items"] if i["key"].endswith(":session_e2e")]

    def test_post_then_resolve(self):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                 "display": {"kind": "command", "command": "make --version"}}, self.hub.url)
        self.assertTrue(wait_until(lambda: len(self.items()) == 1, timeout=10))
        item = self.items()[0]
        self.assertEqual(item["title"], "Kimi wants to run make: my-repo")
        self.assertEqual(item["source"]["agent"], "kimi-code")
        self.assertNotIn("--version", json.dumps(item))
        marker = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks", "session_e2e")
        self.assertTrue(wait_until(lambda: os.path.exists(marker), timeout=10))
        self.run_hook("resolve", {"hook_event_name": "PermissionResult", "decision": "approved"}, self.hub.url)
        self.assertTrue(wait_until(lambda: self.items()[0]["status"] == "resolved", timeout=10), self.items())

    def test_hub_down_queues(self):
        self.run_hook("notify", {"hook_event_name": "Stop", "stop_hook_active": False},
                      "http://127.0.0.1:%d" % free_port())
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.assertTrue(wait_until(lambda: os.path.isdir(outbox) and
                                   any(n.endswith(".json") for n in os.listdir(outbox)), timeout=30))  # the hook posts after its turn wait, in the background


class Doctor(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-kimi-doc-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.kimi = os.path.join(self.home, ".kimi-code")

    def check(self, **env):
        e = {"HOME": self.home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_URLS": "http://127.0.0.1:%d" % free_port(),
             "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_GH": "none"}
        e.update(env)
        r = subprocess.run([sys.executable, CLI, "doctor", "--json"], env=e, capture_output=True, text=True, timeout=60)
        rows = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "kimi hooks"]
        return rows[0] if rows else None

    def install(self, **env):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", "")}
        e.update(env)
        r = subprocess.run([BASH, INSTALLER], env=e, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_states(self):
        self.assertIsNone(self.check())
        os.makedirs(self.kimi)
        row = self.check()
        self.assertEqual(row["status"], "INFO")
        self.assertEqual(row["hint"], "to install: curl -fsSL <invite link>/install.sh | bash -s -- --yes "
                                      "--kimi-hooks user --alerts")
        self.install()
        row = self.check(NEEDS_YOU_AGENT_ALERTS="1")
        self.assertEqual(row["status"], "OK", row)
        self.assertIn("~/.kimi-code/config.toml", row["detail"])
        self.assertIn("alerts on", row["detail"])
        self.assertIn("restart Kimi Code", row["hint"])
        conf = os.path.join(self.kimi, "config.toml")
        with open(conf) as fh:
            text = fh.read()
        # the block gone (the hook copy still there), or cut short: one next step, the installer
        for broken in ("default_model = \"x\"\n", text.replace(END + "\n", "")):
            with open(conf, "w") as fh:
                fh.write(broken)
            row = self.check()
            self.assertEqual(row["status"], "WARN", row)
            self.assertTrue(row["hint"].startswith("re-run the installer: curl -fsSL <invite link>/install.sh | "
                                                   "bash -s -- --yes --kimi-hooks user"), row)
        with open(conf, "w") as fh:
            fh.write(text)
        os.chmod(os.path.join(self.kimi, "hooks", "needs-you-hook.sh"), 0o644)
        self.assertIn("not executable", self.check()["detail"])
        os.remove(os.path.join(self.kimi, "hooks", "needs-you-hook.sh"))
        self.assertIn("is missing", self.check()["detail"])
        # KIMI_CODE_HOME moves it, as it moves Kimi's own config.
        other = os.path.join(self.home, "k2")
        self.install(KIMI_CODE_HOME=other)
        self.assertEqual(self.check(KIMI_CODE_HOME=other)["status"], "OK")


class UninstallHooks(unittest.TestCase):
    def test_offline_removal_keeps_the_rest_of_the_config(self):
        home = tempfile.mkdtemp(prefix="ny-kimi-un-")
        self.addCleanup(shutil.rmtree, home, True)
        env = {"HOME": home, "PATH": os.environ.get("PATH", "")}
        conf = os.path.join(home, ".kimi-code", "config.toml")
        os.makedirs(os.path.dirname(conf))
        with open(conf, "w") as fh:
            fh.write(USER_CONFIG)
        subprocess.run([BASH, INSTALLER], env=env, capture_output=True, timeout=60)
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--kimi", "--dry-run"], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would remove the needs-you hooks from ~/.kimi-code/config.toml", r.stdout)
        with open(conf) as fh:
            self.assertIn(START, fh.read())
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks"], env=env, capture_output=True, text=True,
                           timeout=60, cwd=home)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(conf) as fh:
            self.assertEqual(fh.read(), USER_CONFIG)
        self.assertFalse(os.path.exists(os.path.join(home, ".kimi-code", "hooks")))
        self.assertTrue(any(n.startswith("config.toml.bak-") for n in os.listdir(os.path.dirname(conf))))
        # an unterminated block is left for a person to fix
        with open(conf, "w") as fh:
            fh.write(START + "\n[[hooks]]\ncommand = 'needs-you-hook.sh'\n")
        r = subprocess.run([sys.executable, CLI, "uninstall-hooks", "--kimi"], env=env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 1)
        self.assertIn("config.toml", r.stderr)


class Update(UpdateCase):
    def test_block_and_hook_copy(self):
        files = current_files()
        files["install-kimi-hooks.sh"] = read(INSTALLER)
        files["kimi-hooks.toml"] = read(KIMI_HOOKS_TOML)
        h = self.hub(files=files)
        conf = self.install(".kimi-code/config.toml",
                            ('default_model = "x"\n\n' + read(KIMI_HOOKS_TOML).decode().replace("timeout = 10", "timeout = 9")
                             ).encode())
        hook = self.install(".kimi-code/hooks/needs-you-hook.sh", mode=0o755)
        r = self.run_cli("update", "--check", urls=[h.url])
        self.assertIn("needs-you-hook.sh (Kimi)", r.stdout)
        self.assertIn("kimi-hooks.toml", r.stdout)
        r = self.run_cli("update", urls=[h.url])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(conf).decode(), 'default_model = "x"\n\n' + read(KIMI_HOOKS_TOML).decode())
        self.assertEqual(read(hook), read(HOOK))
        with open(self.cli, "wb") as fh:
            fh.write(read(CLI))
        r = self.run_cli("--json", "update", "--check", urls=[h.url])
        self.assertEqual(json.loads(r.stdout)["changes"], [])

    def test_nothing_installed_nothing_written(self):
        h = self.hub()
        self.run_cli("update", urls=[h.url])
        self.assertFalse(os.path.exists(os.path.join(self.home, ".kimi-code")))


if __name__ == "__main__":
    unittest.main()
