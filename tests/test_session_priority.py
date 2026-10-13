"""`needs-you session priority`: the person says "this session is critical", and the hooks post
that session's cards (waiting, question, finished, error) at that priority.

The CLI writes a local file the hook reads (<state>/session-priority/<session>); nothing goes
to a hub. Everything runs in a temporary HOME with a fake CLI for the hook, so the real
~/.claude, ~/.local/state and the crontab are never touched."""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import time

from hook_case import HookCase, opt
from support import CLI

SID = "sess-crit-1234"


class SessionPriorityCase(HookCase):
    AGENT = "prio"

    def setUp(self):
        super().setUp()
        self.prio = os.path.join(self.home, ".local", "state", "needs-you", "session-priority")

    def cli_env(self, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_URLS": "http://127.0.0.1:9", "NEEDS_YOU_TOKEN": "x"}
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def ny(self, *args, **extra):
        return subprocess.run([sys.executable, CLI] + list(args), env=self.cli_env(**extra),
                              capture_output=True, text=True, timeout=30, cwd=self.cwd)

    def in_claude(self, *args, **extra):
        return self.ny(*args, CLAUDECODE="1", CLAUDE_CODE_SESSION_ID=SID, **extra)

    def record(self, name=SID):
        with open(os.path.join(self.prio, name)) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh if "=" in l)

    def write(self, name, priority, expires, start=None):
        os.makedirs(self.prio, exist_ok=True)
        with open(os.path.join(self.prio, name), "w") as fh:
            fh.write("priority=%s\nexpires=%d\n" % (priority, expires))
            if start:
                fh.write("start=%s\n" % start)

    def permission(self, sid=SID, agent=(), **extra):
        self.run_hook(["notify"] + list(agent),
                      {"session_id": sid, "cwd": self.cwd, "hook_event_name": "PermissionRequest",
                       "tool_name": "Bash", "tool_input": {"command": "make deploy"}}, **extra)
        return self.wait_calls(1)[-1]


class CliTests(SessionPriorityCase):
    def test_sets_the_session_override_privately(self):
        r = self.in_claude("session", "priority", "urgent")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("urgent", r.stdout)
        rec = self.record()
        self.assertEqual(rec["priority"], "urgent")
        left = int(rec["expires"]) - time.time()
        self.assertTrue(11.9 * 3600 < left <= 12 * 3600, left)  # 12 h by default
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.prio, SID)).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.prio).st_mode), 0o700)
        # Local only: nothing queued for a hub.
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state", "needs-you", "outbox"))
                         and os.listdir(os.path.join(self.home, ".local", "state", "needs-you", "outbox")))

    def test_critical_means_urgent_and_hours_bound_it(self):
        self.assertEqual(self.in_claude("session", "priority", "critical", "--hours", "2").returncode, 0)
        rec = self.record()
        self.assertEqual(rec["priority"], "urgent")
        self.assertLessEqual(int(rec["expires"]) - time.time(), 2 * 3600)
        for bad in ("0", "-1", "169", "nan", "inf"):
            r = self.in_claude("session", "priority", "urgent", "--hours", bad)
            self.assertEqual(r.returncode, 2, bad)

    def test_show_and_clear(self):
        self.in_claude("session", "priority", "low")
        r = self.in_claude("--json", "session", "priority")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual((out["session"], out["priority"]), (SID, "low"))
        self.assertEqual(self.in_claude("session", "priority", "clear").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.prio, SID)))
        self.assertIsNone(json.loads(self.in_claude("--json", "session", "priority").stdout)["priority"])
        self.assertEqual(self.in_claude("session", "priority", "clear").returncode, 0)  # twice is fine

    def test_outside_a_session_it_says_so(self):
        r = self.ny("session", "priority", "urgent")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--session", r.stderr)
        self.assertFalse(os.path.exists(self.prio))
        r = self.ny("session", "priority", "urgent", "--session", SID)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.record()["priority"], "urgent")

    def test_session_named_as_the_hook_names_it(self):
        # The Orca terminal handle wins, as in the hook; odd characters become _.
        self.in_claude("session", "priority", "urgent", ORCA_TERMINAL_HANDLE="term/1:2")
        self.assertEqual(self.record("term_1_2")["priority"], "urgent")
        self.ny("session", "priority", "urgent", "--session", ".hidden")
        self.assertEqual(self.record("_hidden")["priority"], "urgent")
        self.ny("session", "priority", "urgent", CODEX_SESSION_ID="019a-codex")
        self.assertEqual(self.record("019a-codex")["priority"], "urgent")

    def test_never_writes_through_a_symlink(self):
        target = os.path.join(self.home, "elsewhere")
        with open(target, "w") as fh:
            fh.write("keep\n")
        os.makedirs(self.prio)
        os.symlink(target, os.path.join(self.prio, SID))
        self.assertEqual(self.in_claude("session", "priority", "urgent").returncode, 0)
        self.assertFalse(os.path.islink(os.path.join(self.prio, SID)))
        with open(target) as fh:
            self.assertEqual(fh.read(), "keep\n")

    def test_prunes_expired_overrides(self):
        self.write("old-session", "urgent", time.time() - 10)
        self.in_claude("session", "priority", "urgent")
        self.assertEqual(sorted(os.listdir(self.prio)), [SID])


class HookTests(SessionPriorityCase):
    def test_cards_post_at_the_session_priority(self):
        self.assertEqual(self.in_claude("session", "priority", "urgent").returncode, 0)
        self.assertEqual(opt(self.permission(), "--priority"), "urgent")

    def test_it_wins_over_the_machine_default(self):
        self.write(SID, "urgent", time.time() + 3600)
        self.assertEqual(opt(self.permission(NEEDS_YOU_AGENT_PRIORITY="low"), "--priority"), "urgent")

    def test_without_one_the_default_holds(self):
        self.assertEqual(opt(self.permission(), "--priority"), "normal")
        os.remove(self.log)
        self.assertEqual(opt(self.permission(NEEDS_YOU_AGENT_PRIORITY="low"), "--priority"), "low")

    def test_expired_or_other_sessions_dont_count(self):
        self.write(SID, "urgent", time.time() - 5)
        self.write("someone-else", "urgent", time.time() + 3600)
        self.assertEqual(opt(self.permission(), "--priority"), "normal")

    def test_garbage_is_ignored(self):
        self.write(SID, "critical!!", time.time() + 3600)
        self.assertEqual(opt(self.permission(), "--priority"), "normal")

    def test_turn_and_question_cards_too(self):
        self.write(SID, "urgent", time.time() + 3600)
        self.run_hook(["notify"], {"session_id": SID, "cwd": self.cwd, "hook_event_name": "Notification",
                                   "notification_type": "idle_prompt", "message": "Claude is waiting"})
        self.assertEqual(opt(self.wait_calls(1)[-1], "--priority"), "urgent")

    def test_codex_shares_it(self):
        self.write("019a-codex", "urgent", time.time() + 3600)
        argv = self.permission(sid="019a-codex", agent=["codex"])
        self.assertEqual(opt(argv, "--priority"), "urgent")

    def test_session_end_removes_it(self):
        self.write(SID, "urgent", time.time() + 3600)
        self.run_hook(["end"], {"session_id": SID, "cwd": self.cwd, "hook_event_name": "SessionEnd"})
        self.assertFalse(os.path.exists(os.path.join(self.prio, SID)))


if __name__ == "__main__":
    import unittest
    unittest.main()
