"""integrations/claude-code/needs-you-usage: the status line helper that posts a low `info`
card when Claude's 5-hour or weekly limit passes a threshold, and the usage status behind the
Mac's meters (MeterStatus below; the card tests turn the meter off).

Runs with a temporary HOME and a fake `needs-you` CLI that records its argv, so nothing
touches the real ~/.claude or ~/.config.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from support import ROOT

SCRIPT = os.path.join(ROOT, "integrations", "claude-code", "needs-you-usage")

FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_CLI_LOG"], "a") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
"""


class UsageCase(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="ny-usage-")
        self.addCleanup(shutil.rmtree, self.home, True)
        self.cli = os.path.join(self.home, "fake-needs-you")
        with open(self.cli, "w") as fh:
            fh.write(FAKE_CLI)
        os.chmod(self.cli, 0o755)
        self.log = os.path.join(self.home, "calls.log")
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "usage", "claude.json")
        self.now = int(time.time())

    def payload(self, five=None, week=None):
        rl = {}
        if five is not None:
            rl["five_hour"] = {"used_percentage": five, "resets_at": self.now + 3600}
        if week is not None:
            rl["seven_day"] = {"used_percentage": week, "resets_at": self.now + 4 * 86400}
        d = {"session_id": "s-1", "model": {"display_name": "Opus"}}
        if rl:
            d["rate_limits"] = rl
        return d

    def run_it(self, data, args=(), expect_calls=None, **extra):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "NEEDS_YOU_BIN": self.cli, "FAKE_CLI_LOG": self.log, "NEEDS_YOU_USAGE_METER": "0"}
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}
        r = subprocess.run([sys.executable, SCRIPT] + list(args), input=json.dumps(data), env=env,
                           capture_output=True, text=True, timeout=30)
        if expect_calls is not None:
            deadline = time.time() + 10
            while len(self.calls()) < expect_calls and time.time() < deadline:
                time.sleep(0.05)
            time.sleep(0.1)
            self.assertEqual(len(self.calls()), expect_calls, self.calls())
        return r

    def calls(self):
        try:
            with open(self.log) as fh:
                return [json.loads(l) for l in fh if l.strip()]
        except OSError:
            return []


class UsageMeterTest(UsageCase):
    def test_card_off_by_default(self):
        r = self.run_it(self.payload(99, 99), expect_calls=0)
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertFalse(os.path.exists(os.path.dirname(self.state)))

    def test_posts_low_info_card_once_then_steps_then_resolves(self):
        on = {"NEEDS_YOU_USAGE_ALERT_PCT": "80"}
        r = self.run_it(self.payload(85, 10), expect_calls=1, **on)
        self.assertEqual(r.stdout, "")
        args = self.calls()[0]
        self.assertEqual(args[:7], ["add", "--kind", "info", "--priority", "low", "--key",
                                    "agent:%s:claude-usage:5h" % args[6].split(":")[1]])
        title = [a for a in args if a.startswith("--title=")][0]
        self.assertIn("Claude 5-hour limit 85% used", title)
        hours = float(args[args.index("--expires-in") + 1])
        self.assertTrue(0.9 < hours <= 1.0, hours)
        # Same level: no re-post. Five points more: one.
        self.run_it(self.payload(88, 10), expect_calls=1, **on)
        self.run_it(self.payload(90, 10), expect_calls=2, **on)
        # Back under the line: resolve, and the state file goes.
        self.run_it(self.payload(20, 10), expect_calls=3, **on)
        self.assertEqual(self.calls()[2][:2], ["resolve", "--key"])
        self.assertTrue(self.calls()[2][2].endswith(":claude-usage:5h"))
        self.assertFalse(os.path.exists(self.state))

    def test_weekly_threshold_and_account_label(self):
        env = {"NEEDS_YOU_USAGE_ALERT_PCT": "0", "NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT": "70",
               "NEEDS_YOU_USAGE_ACCOUNT": "team"}
        self.run_it(self.payload(99, 75), expect_calls=1, **env)
        args = self.calls()[0]
        self.assertTrue(args[6].endswith(":claude-usage:team:7d"), args)
        self.assertIn("(team)", [a for a in args if a.startswith("--title=")][0])

    def test_settings_from_env_file_and_missing_windows_keep_card(self):
        conf = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(conf)
        with open(os.path.join(conf, "env"), "w") as fh:
            fh.write("NEEDS_YOU_USAGE_ALERT_PCT='50'\nNEEDS_YOU_AGENT_CONTEXT=personal\n")
        self.run_it(self.payload(60, None), expect_calls=1)
        self.assertIn("personal", self.calls()[0])
        # No rate_limits (API key login, or before the first response): nothing changes.
        self.run_it(self.payload(None, None), expect_calls=1)
        self.assertTrue(os.path.exists(self.state))

    def test_wraps_existing_status_line_and_prints_meter(self):
        r = self.run_it(self.payload(23.5, 41.2),
                        args=["--print", "--", sys.executable, "-c",
                              "import sys,json; print('mine', json.load(sys.stdin)['session_id'])"],
                        expect_calls=0)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "mine s-1\n5h 23% · 7d 41%\n")

    def test_wrapped_exit_status_and_garbage_input(self):
        env = {"PATH": os.environ.get("PATH", ""), "HOME": self.home, "NEEDS_YOU_BIN": self.cli,
               "FAKE_CLI_LOG": self.log, "NEEDS_YOU_USAGE_ALERT_PCT": "10"}
        r = subprocess.run([sys.executable, SCRIPT, "--", sys.executable, "-c", "raise SystemExit(3)"],
                           input="not json", env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (3, ""))
        self.assertEqual(self.calls(), [])

    def test_python39_syntax_and_executable(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        with open(SCRIPT) as fh:
            src = fh.read()
        self.assertIn("from __future__ import annotations", src)
        compile(src, SCRIPT, "exec")


if __name__ == "__main__":
    unittest.main()


class MeterStatus(UsageCase):
    """The meter is on by default: a `status set` per change, throttled; never a card."""

    def meter_state(self, account=""):
        return os.path.join(os.path.dirname(self.state), "claude%s.meter.json" % ("-" + account if account else ""))

    def age_meter(self, seconds, account=""):
        with open(self.meter_state(account)) as fh:
            st = json.load(fh)
        st["sent"] -= seconds
        with open(self.meter_state(account), "w") as fh:
            json.dump(st, fh)

    def test_on_by_default_and_throttled(self):
        on = {"NEEDS_YOU_USAGE_METER": None}
        r = self.run_it(self.payload(23, 41), expect_calls=1, **on)
        self.assertEqual(r.returncode, 0)
        args = self.calls()[0]
        self.assertEqual(args[:5], ["-q", "status", "set", "--key", "usage:claude"])
        self.assertIn("--provider", args)
        self.assertNotIn("add", args)  # never a card
        self.assertIn("5h=23@%d" % (self.now + 3600), args)
        self.assertIn("7d=41@%d" % (self.now + 4 * 86400), args)
        self.run_it(self.payload(23, 41), expect_calls=1, **on)  # right after: nothing
        self.age_meter(20)
        self.run_it(self.payload(23, 41), expect_calls=1, **on)  # unchanged: waits for the refresh
        self.run_it(self.payload(24, 41), expect_calls=2, **on)  # changed, 15 s since: sent
        self.age_meter(400)
        self.run_it(self.payload(24, 41), expect_calls=3, **on)  # unchanged, 5 min since: sent

    def test_off_and_no_numbers(self):
        self.run_it(self.payload(23, 41), expect_calls=0, NEEDS_YOU_USAGE_METER="0")
        self.run_it(self.payload(), expect_calls=0, NEEDS_YOU_USAGE_METER=None)

    def test_account_label_and_card_together(self):
        self.run_it(self.payload(90, 10), expect_calls=2, NEEDS_YOU_USAGE_METER=None,
                    NEEDS_YOU_USAGE_ACCOUNT="team-2", NEEDS_YOU_USAGE_ALERT_PCT="80",
                    NEEDS_YOU_USAGE_WEEKLY_ALERT_PCT="0")
        meter = [c for c in self.calls() if "status" in c][0]
        self.assertIn("usage:claude:team-2", meter)
        self.assertEqual(meter[meter.index("--account") + 1], "team-2")
        self.assertTrue([c for c in self.calls() if "add" in c])  # the card still comes
