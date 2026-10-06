from __future__ import annotations

import json
import os
import subprocess
import sys

from support import CLI, HubTestCase, free_port, request


class CliTestCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.dead = "http://127.0.0.1:%d" % free_port()

    def run_cli(self, *args, urls=None, token="t", config_file=None):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "testbox"}
        if urls is not None:
            env["NEEDS_YOU_URL"] = ",".join(urls)
        if token is not None:
            env["NEEDS_YOU_TOKEN"] = token
        return subprocess.run([sys.executable, CLI] + list(args), env=env, capture_output=True,
                              text=True, timeout=60)

    def queued(self):
        try:
            return sorted(n for n in os.listdir(self.outbox) if n.endswith(".json"))
        except OSError:
            return []

    def items(self, hub, reader, status="all"):
        return request("GET", hub.url + "/v1/items?status=" + status, reader)[1]["items"]


class Outbox(CliTestCase):
    def test_hub_down_queues_and_exits_zero_then_flushes(self):
        r = self.run_cli("add", "--key", "acme:ACME-1:x", "--title", "Decide", "--link",
                         "Jira=https://j/ACME-1?a=b", "--agent", "orca:redo", urls=[self.dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued", r.stderr)
        r = self.run_cli("resolve", "--key", "acme:ACME-1:x", urls=[self.dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("done", "--key", "run", "--title", "Finished", urls=[self.dead])
        self.assertEqual(r.returncode, 0)
        files = self.queued()
        self.assertEqual(len(files), 3)
        self.assertEqual(oct(os.stat(os.path.join(self.outbox, files[0])).st_mode & 0o777), "0o600")
        with open(os.path.join(self.outbox, files[0])) as fh:
            entry = json.load(fh)
        self.assertEqual(entry["body"]["source"], {"host": "testbox", "agent": "orca:redo"})
        self.assertEqual(entry["body"]["links"], [{"label": "Jira", "url": "https://j/ACME-1?a=b"}])

        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("flush", urls=[self.dead, hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sent 3", r.stdout)
        self.assertEqual(self.queued(), [])
        items = {i["key"]: i for i in self.items(hub, reader)}
        self.assertEqual(items["acme:ACME-1:x"]["status"], "resolved")  # order preserved
        self.assertEqual(items["run"]["kind"], "done")
        self.assertIsNotNone(items["run"]["expires_at"])

    def test_every_invocation_flushes_first(self):
        self.run_cli("add", "--key", "a", "--title", "queued", urls=[self.dead])
        self.assertEqual(len(self.queued()), 1)
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("add", "--key", "b", "--title", "direct", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])
        items = self.items(hub, reader, "open")
        self.assertEqual([i["key"] for i in items], ["a", "b"])

    def test_rejected_queued_entry_moves_to_failed(self):
        self.run_cli("add", "--key", "a", "--title", "x" * 150, urls=[self.dead])
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.queued(), [])
        self.assertEqual(len(os.listdir(os.path.join(self.outbox, "failed"))), 1)

    def test_missing_config_still_exits_zero(self):
        r = self.run_cli("add", "--key", "a", "--title", "t", urls=None, token=None)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.queued()), 1)


class Failover(CliTestCase):
    def test_tries_hubs_in_order(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        r = self.run_cli("add", "--key", "k", "--title", "t", urls=[self.dead, a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("created", r.stdout)
        self.assertIn(a.url, r.stdout)
        self.assertEqual(self.queued(), [])
        r = self.run_cli("add", "--key", "k", "--title", "t", urls=[a.url], token=sender)
        self.assertIn("unchanged", r.stdout)

    def test_rejections_are_not_queued(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        cases = [
            (["add", "--key", "k", "--title", "t", "--link", "x=http://insecure"], sender),
            (["add", "--key", "k", "--title", "t"], reader),        # wrong role
            (["add", "--key", "k", "--title", "t"], "bogus-token"),  # unknown token
        ]
        for args, tok in cases:
            with self.subTest(args=args, tok=tok[:5]):
                r = self.run_cli(*args, urls=[a.url], token=tok)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(self.queued(), [])

    def test_resolve_nothing_open_is_ok(self):
        a = self.make_hub("hub-a")
        sender, _ = self.tokens(a)
        r = self.run_cli("resolve", "--key", "never", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0)

    def test_health(self):
        a = self.make_hub("hub-a")
        sender, _ = self.tokens(a)
        r = self.run_cli("health", urls=[self.dead, a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DOWN", r.stdout)
        self.assertIn("role=sender", r.stdout)
        r = self.run_cli("health", urls=[self.dead], token=sender)
        self.assertEqual(r.returncode, 1)

    def test_urls_precedence(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        cfg_dir = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "env"), "w") as fh:
            fh.write("NEEDS_YOU_URLS=%s,%s\nNEEDS_YOU_URL=%s\nNEEDS_YOU_TOKEN=%s\n"
                     "NEEDS_YOU_AGENT_CLAUDE=1\n" % (self.dead, a.url, self.dead, sender))
        # file: NEEDS_YOU_URLS beats NEEDS_YOU_URL
        r = self.run_cli("add", "--key", "u1", "--title", "t", urls=None, token=None)
        self.assertIn("created", r.stdout, r.stderr)
        # env NEEDS_YOU_URL beats the file
        r = self.run_cli("add", "--key", "u2", "--title", "t", urls=[self.dead], token=None)
        self.assertIn("queued", r.stderr)

    def test_env_file_config(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        cfg_dir = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "env"), "w") as fh:
            fh.write("# comment\nexport NEEDS_YOU_URL=\"%s,%s\"\nNEEDS_YOU_TOKEN='%s'\n"
                     % (self.dead, a.url, sender))
        r = self.run_cli("info", "--key", "i", "--title", "fyi", urls=None, token=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([i["kind"] for i in self.items(a, reader, "open")], ["info"])


if __name__ == "__main__":
    import unittest
    unittest.main()
