from __future__ import annotations

import json
import os
import subprocess
import time
import sys

from support import CLI, HubTestCase, free_port, request


class CliTestCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.dead = "http://127.0.0.1:%d" % free_port()

    def run_cli(self, *args, urls=None, token="t", config_file=None, extra_env=None, cli=CLI):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "testbox"}
        env.update(extra_env or {})
        if urls is not None:
            env["NEEDS_YOU_URL"] = ",".join(urls)
        if token is not None:
            env["NEEDS_YOU_TOKEN"] = token
        return subprocess.run([sys.executable, cli] + list(args), env=env, capture_output=True,
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
        r = self.run_cli("add", "--key", "work:ACME-1:x", "--title", "Decide", "--link",
                         "Jira=https://j/ACME-1?a=b", "--agent", "orca:redo", urls=[self.dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued", r.stderr)
        r = self.run_cli("resolve", "--key", "work:ACME-1:x", urls=[self.dead])
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
        self.assertEqual(items["work:ACME-1:x"]["status"], "resolved")  # order preserved
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


class Caps(CliTestCase):
    def test_outbox_is_capped_by_count_and_age(self):
        os.makedirs(self.outbox)
        old = "%020d-00001.json" % int((time.time() - 8 * 86400) * 1e9)
        with open(os.path.join(self.outbox, old), "w") as fh:
            json.dump({"method": "POST", "path": "/v1/items", "body": {"title": "old"}}, fh)
        env = {"NEEDS_YOU_OUTBOX_MAX": "3"}
        for i in range(5):
            r = self.run_cli("add", "--key", "k%d" % i, "--title", "t", urls=[self.dead], extra_env=env)
            self.assertEqual(r.returncode, 0)
        files = self.queued()
        self.assertEqual(len(files), 3)
        self.assertNotIn(old, files)
        bodies = []
        for f in files:
            with open(os.path.join(self.outbox, f)) as fh:
                bodies.append(json.load(fh)["body"]["key"])
        self.assertEqual(bodies, ["k2", "k3", "k4"])  # the oldest were dropped
        self.assertIn("dropped", r.stderr)


class BackwardCompatible(CliTestCase):
    def test_outbox_and_env_from_the_previous_cli(self):
        """Files exactly as main's CLI (f43bf2f) wrote them: a URL-only env file and an outbox entry."""
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        cfg_dir = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "env"), "w") as fh:
            fh.write("NEEDS_YOU_URL=%s\nNEEDS_YOU_TOKEN=%s\n" % (a.url, sender))
        os.makedirs(self.outbox)
        name = "%020d-%05d.json" % (time.time_ns() - 60 * 10 ** 9, 4242)
        with open(os.path.join(self.outbox, name), "w") as fh:
            json.dump({"method": "POST", "path": "/v1/items", "queued_at": "2026-10-06T10:00:00Z",
                       "body": {"key": "old:queued", "title": "from the old CLI", "kind": "needs",
                                "context": "work", "priority": "normal", "source": {"host": "x"}}}, fh)
        with open(os.path.join(self.outbox, "not-our-name.json"), "w") as fh:  # unknown name: kept by age
            json.dump({"method": "POST", "path": "/v1/items", "body": {"key": "odd", "title": "odd"}}, fh)
        r = self.run_cli("flush", urls=None, token=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sent 2", r.stdout)
        keys = sorted(i["key"] for i in self.items(a, reader, "open"))
        self.assertEqual(keys, ["odd", "old:queued"])


class DefaultContext(CliTestCase):
    def test_env_file_default_context(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        cfg_dir = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "env"), "w") as fh:
            fh.write("NEEDS_YOU_URLS=%s\nNEEDS_YOU_TOKEN=%s\nNEEDS_YOU_DEFAULT_CONTEXT=personal\n"
                     % (a.url, sender))
        self.run_cli("add", "--key", "a", "--title", "t", urls=None, token=None)
        self.run_cli("add", "--key", "b", "--title", "t", "--context", "work", urls=None, token=None)
        items = {i["key"]: i["context"] for i in self.items(a, reader, "open")}
        self.assertEqual(items, {"a": "personal", "b": "work"})


class SelfUpdate(CliTestCase):
    def test_replaces_itself_atomically(self):
        a = self.make_hub("hub-a")
        bindir = os.path.join(self.home, "bin")
        os.makedirs(bindir)
        target = os.path.join(bindir, "needs-you")
        with open(CLI) as fh:
            src = fh.read()
        with open(target, "w") as fh:
            fh.write(src.replace('VERSION = "', 'VERSION = "0.0.1-old" or "', 1))
        os.chmod(target, 0o755)
        r = self.run_cli("self-update", urls=[self.dead, a.url], cli=target)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("updated", r.stdout)
        with open(target) as fh:
            self.assertEqual(fh.read(), src)
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o755)
        self.assertEqual(sorted(os.listdir(bindir)), ["needs-you"])  # no temp files left
        r = self.run_cli("self-update", urls=[a.url], cli=target)
        self.assertIn("already up to date", r.stdout)
        r = self.run_cli("self-update", urls=[self.dead], cli=target)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    import unittest
    unittest.main()
