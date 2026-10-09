"""`needs-you status set/clear` (ADR 0011): straight to the hub, never queued."""
from __future__ import annotations

import calendar
import json
import time

import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from support import CLI, ROOT, request, wait_until
from test_cli import CliTestCase

USAGE = os.path.join(ROOT, "integrations", "claude-code", "needs-you-usage")


def old_hub(test):
    """A hub that predates statuses: 404 not_found for every request, after reading the body
    (a canned reply that hangs up unread can reset the connection instead)."""
    class Old(BaseHTTPRequestHandler):
        def do_PUT(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            data = b'{"error": "not_found", "message": "no such endpoint"}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Old)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    test.addCleanup(srv.server_close)
    test.addCleanup(srv.shutdown)
    return "http://127.0.0.1:%d" % srv.server_address[1]


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
        exp = calendar.timegm(time.strptime(st["expires_at"][:19], "%Y-%m-%dT%H:%M:%S"))
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
        old = old_hub(self)
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


    def test_the_claude_status_line_helper_reaches_the_hub(self):
        now = int(time.time())
        data = {"rate_limits": {"five_hour": {"used_percentage": 37.2, "resets_at": now + 3600},
                                "seven_day": {"used_percentage": 12, "resets_at": now + 86400}}}
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_URL": self.hub.url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_HOST": "testbox"}
        r = subprocess.run([sys.executable, USAGE, "--print"], input=json.dumps(data), env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "5h 37% · 7d 12%\n")
        self.assertTrue(wait_until(lambda: self.statuses(), timeout=15))
        (st,) = self.statuses()
        self.assertEqual((st["key"], st["usage"]["provider"]), ("usage:claude", "claude"))
        self.assertEqual([w["used_pct"] for w in st["usage"]["windows"]], [37, 12])
        _, body = request("GET", self.hub.url + "/v1/items", self.reader)
        self.assertEqual(body["items"], [])  # a meter, never a card


if __name__ == "__main__":
    import unittest
    unittest.main()
