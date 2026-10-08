"""Stale agent cards: the hook leases each card to its Claude process, `needs-you flush`
resolves the card once that process is gone, and every card expires after 48 h
without a re-post (docs/roadmap/stale-items.md, options A and B).

A stand-in "Claude" process runs the real hook through `sh -c`, as Claude Code
does, against a real hub and the real CLI.
"""
from __future__ import annotations

import calendar
import json
import os
import shutil
import subprocess
import sys
import time

from support import CLI, ROOT, HubTestCase, request, wait_until

BASH = shutil.which("bash") or "/bin/bash"
HOOK = os.path.join(ROOT, "integrations", "claude-code", "needs-you-hook.sh")

# Runs the hook as a grandchild (via sh -c), says "ready", then waits to be killed.
STAND_IN = """
import subprocess, sys, time
subprocess.run(["/bin/sh", "-c", '"$0" notify', sys.argv[1]], input=sys.argv[2].encode(),
               timeout=30)
print("ready", flush=True)
time.sleep(120)
"""


class LeaseTests(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.leases = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        host = subprocess.run([BASH, "-c", 'h=$(hostname -s 2>/dev/null || hostname); '
                               'printf %s "${h%%.*}" | tr -c "A-Za-z0-9._-" _ | cut -c1-80'],
                              capture_output=True, text=True).stdout.strip()
        self.prefix = "agent:%s:" % host

    def env(self, **extra):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "NEEDS_YOU_URL": self.hub.url, "NEEDS_YOU_TOKEN": self.sender,
               "NEEDS_YOU_TIMEOUT": "2", "NEEDS_YOU_HOST": "testbox",
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_BIN": CLI}
        env.update(extra)
        return env

    def start_session(self, session="s1", **extra):
        data = json.dumps({"session_id": session, "cwd": self.home, "message": "Allow Bash?",
                           "notification_type": "permission_prompt"})
        proc = subprocess.Popen([sys.executable, "-c", STAND_IN, HOOK, data], env=self.env(**extra),
                                stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait(), proc.stdout.close()))
        self.assertEqual(proc.stdout.readline().strip(), "ready")
        return proc

    def flush(self):
        r = subprocess.run([sys.executable, CLI, "flush"], env=self.env(), capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def item(self, key):
        items = request("GET", self.hub.url + "/v1/items?status=all", self.reader)[1]["items"]
        return {i["key"]: i for i in items}[key]

    def expires_in_hours(self, key):
        exp = self.item(key)["expires_at"]
        if exp is None:
            return None
        return (calendar.timegm(time.strptime(exp[:19], "%Y-%m-%dT%H:%M:%S")) - time.time()) / 3600

    def lease(self, name):
        with open(os.path.join(self.leases, name)) as fh:
            return dict(l.rstrip("\n").split("=", 1) for l in fh)

    def test_card_is_resolved_once_its_session_dies(self):
        proc = self.start_session()
        lease = self.lease("s1")
        self.assertEqual(lease["key"], self.prefix + "s1")
        self.assertEqual(lease["pid"], str(proc.pid))  # past the sh -c wrapper
        self.assertTrue(lease["start"])

        self.assertNotIn("resolved", self.flush().stdout)
        self.assertEqual(self.item(self.prefix + "s1")["status"], "open")

        proc.kill()
        proc.wait()
        r = self.flush()
        self.assertIn("resolved 1 from ended sessions", r.stdout)
        self.assertEqual(self.item(self.prefix + "s1")["status"], "resolved")
        self.assertFalse(os.path.exists(os.path.join(self.leases, "s1")))
        self.assertEqual(os.listdir(self.leases), [])

    def test_a_live_session_in_another_time_zone_is_left_alone(self):
        # `ps -o lstart` prints local time: the hook runs with the agent's TZ (a shell profile
        # setting), the 5-minute flush with cron's (the system's). The lease must still match.
        self.start_session(TZ="Pacific/Kiritimati")
        r = subprocess.run([sys.executable, CLI, "flush"], env=self.env(TZ="UTC"), capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("resolved", r.stdout)
        self.assertEqual(self.item(self.prefix + "s1")["status"], "open")
        self.assertTrue(os.path.exists(os.path.join(self.leases, "s1")))

    def test_reused_pid_counts_as_ended(self):
        os.makedirs(self.leases)
        request("POST", self.hub.url + "/v1/items", self.sender,
                {"key": "agent:testbox:old", "title": "Waiting", "context": "work",
                 "source": {"host": "testbox"}})
        with open(os.path.join(self.leases, "old"), "w") as fh:
            fh.write("key=agent:testbox:old\npid=%d\nstart=Thu Jan  1 00:00:00 1970\n" % os.getpid())
        self.flush()
        self.assertEqual(self.item("agent:testbox:old")["status"], "resolved")

    def test_a_failing_ps_says_nothing_about_a_live_process(self):
        # ps that can't run properly (sandboxed, a broken PATH entry) prints nothing: the
        # process is alive (kill 0 says so), so its card stays.
        os.makedirs(self.leases)
        request("POST", self.hub.url + "/v1/items", self.sender,
                {"key": "agent:testbox:live", "title": "Waiting", "context": "work",
                 "source": {"host": "testbox"}})
        with open(os.path.join(self.leases, "live"), "w") as fh:
            fh.write("key=agent:testbox:live\npid=%d\nstart=Thu Jan  1 00:00:00 1970\n" % os.getpid())
        stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(stubs)
        with open(os.path.join(stubs, "ps"), "w") as fh:
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(stubs, "ps"), 0o755)
        r = subprocess.run([sys.executable, CLI, "flush"], capture_output=True, text=True, timeout=60,
                           env=self.env(PATH=stubs + ":" + os.environ.get("PATH", "/usr/bin:/bin")))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.item("agent:testbox:live")["status"], "open")
        self.assertTrue(os.path.exists(os.path.join(self.leases, "live")))

    def test_markers_without_a_lease_are_left_alone(self):
        os.makedirs(self.leases)
        for name, text in (("legacy", ""), ("nokey", "pid=1\nstart=x\n"),
                           ("other", "key=work:ACME-1:x\npid=999999\nstart=x\n")):
            with open(os.path.join(self.leases, name), "w") as fh:
                fh.write(text)
        self.flush()
        self.assertEqual(sorted(os.listdir(self.leases)), ["legacy", "nokey", "other"])

    def test_cards_expire_after_48_hours_by_default(self):
        self.start_session()
        self.assertAlmostEqual(self.expires_in_hours(self.prefix + "s1"), 48, delta=0.1)

    def test_expiry_setting_and_zero_turns_it_off(self):
        self.start_session("s2", NEEDS_YOU_AGENT_EXPIRY_HOURS="3")
        self.assertAlmostEqual(self.expires_in_hours(self.prefix + "s2"), 3, delta=0.1)
        self.start_session("s3", NEEDS_YOU_AGENT_EXPIRY_HOURS="0")
        self.assertIsNone(self.expires_in_hours(self.prefix + "s3"))

    def test_resolve_hook_still_clears_the_lease(self):
        self.start_session()
        data = json.dumps({"session_id": "s1"})
        r = subprocess.run([BASH, HOOK, "resolve"], input=data, env=self.env(), capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertTrue(wait_until(lambda: self.item(self.prefix + "s1")["status"] == "resolved"))
        self.assertEqual(os.listdir(self.leases), [])


if __name__ == "__main__":
    import unittest
    unittest.main()
