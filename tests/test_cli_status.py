"""`needs-you status set/clear` (ADR 0011): straight to the hub, never queued."""
from __future__ import annotations

import json
import time

from support import garbage_server, request
from test_cli import CliTestCase


class CliStatus(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def statuses(self):
        return request("GET", self.hub.url + "/v1/status", self.reader)[1]["statuses"]

    def test_usage_set_and_clear(self):
        resets = int(time.time()) + 3 * 3600
        r = self.run_cli("status", "set", "--key", "usage:claude", "--provider", "claude", "--label", "Claude",
                         "--window", "5h=51@%d" % resets, "--window", "7d=41.5", "--agent", "claude-code",
                         urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("status set: usage:claude", r.stdout)
        (st,) = self.statuses()
        self.assertEqual(st["type"], "usage")
        self.assertEqual(st["usage"]["windows"], [
            {"name": "5h", "used_pct": 51, "resets_at": st["usage"]["windows"][0]["resets_at"]},
            {"name": "7d", "used_pct": 41.5, "resets_at": None}])
        self.assertEqual(st["source"], {"host": "testbox", "agent": "claude-code"})
        # expiry defaults to the latest reset
        exp = time.mktime(time.strptime(st["expires_at"][:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
        self.assertAlmostEqual(exp, resets, delta=5)
        r = self.run_cli("status", "clear", "--key", "usage:claude", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cleared", r.stdout)
        self.assertEqual(self.statuses(), [])
        self.assertEqual(self.queued(), [])

    def test_progress_and_json(self):
        r = self.run_cli("--json", "status", "set", "--key", "job:nightly", "--label", "nightly import",
                         "--state", "working", "--progress", "40", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual((out["type"], out["state"], out["progress"]), ("progress", "working", 40))

    def test_never_queued_when_no_hub_answers(self):
        r = self.run_cli("status", "set", "--key", "usage:claude", "--provider", "claude", "--window", "5h=5",
                         urls=[self.dead], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("never queued", r.stderr)
        self.assertEqual(self.queued(), [])

    def test_fails_over_and_tolerates_an_old_hub(self):
        old = garbage_server(self, b"HTTP/1.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n"
                                   b'{"error": "not_found", "message": "no such endpoint"}')
        args = ("status", "set", "--key", "usage:claude", "--provider", "claude", "--window", "5h=5")
        r = self.run_cli(*args, urls=[old], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("predates statuses", r.stderr)
        r = self.run_cli(*args, urls=[self.dead, old, self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.statuses()), 1)

    def test_too_fast_exits_zero(self):
        args = ("status", "set", "--key", "usage:claude", "--provider", "claude", "--window", "5h=5")
        self.assertEqual(self.run_cli(*args, urls=[self.hub.url], token=self.sender).returncode, 0)
        r = self.run_cli(*args, urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("429", r.stderr)

    def test_bad_input(self):
        for args, err in (
            (("--key", "k"), "needs --label"),
            (("--key", "k", "--provider", "claude"), "--window"),
            (("--key", "k", "--label", "x", "--account", "a"), "--account needs --provider"),
            (("--key", "k", "--label", "x", "--expires-in", "nan"), "--expires-in"),
        ):
            with self.subTest(args=args):
                r = self.run_cli("status", "set", *args, urls=[self.hub.url], token=self.sender)
                self.assertEqual(r.returncode, 2)
                self.assertIn(err, r.stderr)
        r = self.run_cli("status", "set", "--key", "k", "--provider", "claude", "--window", "5h=150",
                         urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 2)
        r = self.run_cli("status", "set", "--key", "k", "--provider", "claude", "--account", "me@example.com",
                         "--window", "5h=5", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 2)
        self.assertIn("email", r.stderr)


if __name__ == "__main__":
    import unittest
    unittest.main()
