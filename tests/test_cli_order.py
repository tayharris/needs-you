"""The CLI keeps per-key order across concurrent runs, and never fails or hangs its caller.

A run that finds the outbox busy (another run holds its lock while flushing) or non-empty
must not send ahead of what is queued: a `resolve K` overtaking a queued `add K` would leave
the item open for good."""
from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import threading
import time

from support import CLI, request
from test_cli import CliTestCase


class Order(CliTestCase):
    def hold_lock(self):
        os.makedirs(self.outbox, exist_ok=True)
        fh = open(os.path.join(self.outbox, ".lock"), "a")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        self.addCleanup(fh.close)
        return fh

    def item(self, hub, reader, key):
        got = [i for i in self.items(hub, reader) if i["key"] == key]
        return got[0] if got else None

    def test_waits_briefly_for_a_busy_outbox_then_sends_in_order(self):
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        self.run_cli("add", "--key", "K", "--title", "Decide", urls=[self.dead], token=sender)
        self.assertEqual(len(self.queued()), 1)
        lock = self.hold_lock()  # another run is flushing
        threading.Timer(0.7, lock.close).start()
        t0 = time.time()
        r = self.run_cli("resolve", "--key", "K", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(time.time() - t0, 10)
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.item(hub, reader, "K")["status"], "resolved")

    def test_queues_behind_a_busy_outbox_without_hanging(self):
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        self.run_cli("add", "--key", "K", "--title", "Decide", urls=[self.dead], token=sender)
        lock = self.hold_lock()
        t0 = time.time()
        r = self.run_cli("resolve", "--key", "K", urls=[hub.url], token=sender)
        took = time.time() - t0
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(took, 8, "the caller waited %.1fs" % took)
        self.assertIn("queued", r.stderr)
        self.assertIsNone(self.item(hub, reader, "K"))  # nothing went ahead of the queued add
        queued = self.queued()
        self.assertEqual(len(queued), 2)
        with open(os.path.join(self.outbox, queued[1])) as fh:
            self.assertEqual(json.load(fh)["path"], "/v1/items/resolve")  # behind the add
        lock.close()
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.item(hub, reader, "K")["status"], "resolved")

    def test_concurrent_runs_keep_add_before_resolve(self):
        """Many add/resolve pairs from parallel runs while the outbox drains: every key ends
        resolved."""
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        for i in range(5):  # a backlog, so the first runs flush for a while
            self.run_cli("add", "--key", "B%d" % i, "--title", "t", urls=[self.dead], token=sender)
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "2",
               "NEEDS_YOU_HOST": "testbox", "NEEDS_YOU_GH": "none", "NEEDS_YOU_URL": hub.url,
               "NEEDS_YOU_TOKEN": sender}

        def pair(i):
            subprocess.run([sys.executable, CLI, "add", "--key", "P%d" % i, "--title", "t"], env=env,
                           capture_output=True, cwd=self.tmp, timeout=60)
            subprocess.run([sys.executable, CLI, "resolve", "--key", "P%d" % i], env=env,
                           capture_output=True, cwd=self.tmp, timeout=60)

        threads = [threading.Thread(target=pair, args=(i,)) for i in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(self.queued(), [])
        for i in range(6):
            self.assertEqual(self.item(hub, reader, "P%d" % i)["status"], "resolved", "P%d" % i)


class TooManyOpen(CliTestCase):
    """429 too_many_open on a queued add is the volume guard: it may clear, so the entry
    stays queued (not outbox/failed/) and is retried later."""

    def test_queued_add_stays_queued_on_429(self):
        hub = self.make_hub("hub-a", max_open_per_token=1)
        sender, reader = self.tokens(hub)
        request("POST", hub.url + "/v1/items", sender, {"key": "first", "title": "t"})
        self.run_cli("add", "--key", "second", "--title", "t", urls=[self.dead], token=sender)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.queued()), 1)
        self.assertFalse(os.path.isdir(os.path.join(self.outbox, "failed"))
                         and os.listdir(os.path.join(self.outbox, "failed")))
        request("POST", hub.url + "/v1/items/resolve", sender, {"key": "first"})
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.item_status(hub, reader, "second"), "open")

    def test_later_entries_still_go_and_a_resolve_cancels_the_held_add(self):
        hub = self.make_hub("hub-a", max_open_per_token=1)
        sender, reader = self.tokens(hub)
        request("POST", hub.url + "/v1/items", sender, {"key": "first", "title": "t"})
        self.run_cli("add", "--key", "second", "--title", "t", urls=[self.dead], token=sender)
        self.run_cli("resolve", "--key", "second", urls=[self.dead], token=sender)
        self.run_cli("resolve", "--key", "first", urls=[self.dead], token=sender)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        # the resolve behind the held add went out (so the count could drop) and made the add moot
        self.assertEqual(self.queued(), [])
        self.assertEqual(self.item_status(hub, reader, "first"), "resolved")
        self.assertIsNone(self.item_status(hub, reader, "second"))
        self.assertFalse(os.path.isdir(os.path.join(self.outbox, "failed"))
                         and os.listdir(os.path.join(self.outbox, "failed")))

    def item_status(self, hub, reader, key):
        got = [i for i in self.items(hub, reader) if i["key"] == key]
        return got[0]["status"] if got else None


class Health(CliTestCase):
    def test_no_token_is_not_healthy(self):
        hub = self.make_hub("hub-a")
        r = self.run_cli("health", urls=[hub.url], token=None)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("no token", r.stdout + r.stderr)
