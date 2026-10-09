from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import time
import unittest
import sys

from support import CLI, HubTestCase, free_port, garbage_server, request


class CliTestCase(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        self.dead = "http://127.0.0.1:%d" % free_port()

    def run_cli(self, *args, urls=None, token="t", config_file=None, extra_env=None, cli=CLI, cwd=None):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "testbox", "NEEDS_YOU_GH": "none"}
        env.update(extra_env or {})
        if urls is not None:
            env["NEEDS_YOU_URL"] = ",".join(urls)
        if token is not None:
            env["NEEDS_YOU_TOKEN"] = token
        # cwd: a temp dir by default, so project-level hooks in a checkout are never seen
        return subprocess.run([sys.executable, cli] + list(args), env=env, capture_output=True, cwd=cwd or self.tmp,
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

    def test_post_is_add(self):
        r = self.run_cli("post", "--key", "work:x:y", "--title", "Decide", urls=[self.dead])
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.outbox, self.queued()[0])) as fh:
            body = json.load(fh)["body"]
        self.assertEqual((body["key"], body.get("kind", "needs")), ("work:x:y", "needs"))

    def test_every_invocation_flushes_first(self):
        self.run_cli("add", "--key", "a", "--title", "queued", urls=[self.dead])
        self.assertEqual(len(self.queued()), 1)
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("add", "--key", "b", "--title", "direct", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])
        items = {i["key"]: i for i in self.items(hub, reader, "open")}
        self.assertEqual(sorted(items), ["a", "b"])
        # The queued one went first. Ids made in the same millisecond can sort either
        # way, so compare timestamps, not list order.
        self.assertLessEqual(items["a"]["created_at"], items["b"]["created_at"])

    def test_rejected_queued_entry_moves_to_failed(self):
        self.run_cli("add", "--key", "a", "--title", "x" * 150, urls=[self.dead])
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.queued(), [])
        self.assertEqual(len(os.listdir(os.path.join(self.outbox, "failed"))), 1)

    def test_malformed_queued_entries_move_to_failed(self):
        """Valid JSON of the wrong shape in the outbox must not crash every later
        invocation (they all flush first): it goes to failed/ like unreadable JSON."""
        os.makedirs(self.outbox)
        bad = ["[]", "null", '{"method": "POST"}', '{"method": 1, "path": "/v1/items"}',
               '{"method": "POST", "path": "/v1/items", "body": "x"}', "{not json"]
        for i, text in enumerate(bad):
            with open(os.path.join(self.outbox, "%020d-%05d.json" % (time.time_ns() + i, 1)), "w") as fh:
                fh.write(text)
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("add", "--key", "after", "--title", "t", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("created", r.stdout)
        self.assertEqual(self.queued(), [])
        self.assertEqual(len(os.listdir(os.path.join(self.outbox, "failed"))), len(bad))
        self.assertEqual([i["key"] for i in self.items(hub, reader, "open")], ["after"])

    def test_queued_entries_only_replay_what_the_cli_queues(self):
        """An outbox file is replayed with this machine's token. Only the two requests the CLI
        ever queues are sent: a planted `path` like "@evil.example/x" would otherwise turn
        url + path into http://hub@evil.example/x and hand the token to another host."""
        caught = []

        class Catch(threading.Thread):
            daemon = True

            def __init__(self):
                super().__init__()
                self.srv = socket.socket()
                self.srv.bind(("127.0.0.1", 0))
                self.srv.listen(4)

            def run(self):
                while True:
                    try:
                        conn, _ = self.srv.accept()
                    except OSError:
                        return
                    caught.append(conn.recv(65536))
                    conn.close()

        evil = Catch()
        evil.start()
        self.addCleanup(evil.srv.close)
        os.makedirs(self.outbox)
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        planted = [
            {"method": "POST", "path": "@127.0.0.1:%d/steal" % evil.srv.getsockname()[1], "body": {}},
            {"method": "DELETE", "path": "/v1/tokens/x", "body": None},
            {"method": "GET", "path": "/v1/items", "body": None},
            {"method": "POST", "path": "/v1/items?x=1", "body": {"title": "t"}},
        ]
        for i, entry in enumerate(planted):
            with open(os.path.join(self.outbox, "%020d-%05d.json" % (time.time_ns() + i, 1)), "w") as fh:
                json.dump(entry, fh)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        time.sleep(0.2)
        self.assertEqual(caught, [], "the token went to another host")
        self.assertEqual(self.queued(), [])
        self.assertEqual(len(os.listdir(os.path.join(self.outbox, "failed"))), len(planted))

    def test_failed_dir_symlink_is_not_followed(self):
        os.makedirs(self.outbox)
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, os.path.join(self.outbox, "failed"))
        with open(os.path.join(self.outbox, "%020d-%05d.json" % (time.time_ns(), 1)), "w") as fh:
            fh.write("[]")
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.listdir(elsewhere), [])
        self.assertEqual(self.queued(), [])

    def test_missing_config_still_exits_zero(self):
        r = self.run_cli("add", "--key", "a", "--title", "t", urls=None, token=None)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.queued()), 1)


class ReadOnlyOutbox(CliTestCase):
    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_flush_with_an_outbox_it_cant_change_does_not_crash(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        self.run_cli("add", "--key", "ro", "--title", "t", urls=[self.dead], token=sender)
        self.assertEqual(len(self.queued()), 1)
        os.chmod(self.outbox, 0o500)
        self.addCleanup(os.chmod, self.outbox, 0o700)
        for args in (["flush"], ["add", "--key", "ro2", "--title", "t"]):
            r = self.run_cli(*args, urls=[a.url], token=sender)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(sorted(i["key"] for i in self.items(a, reader, "open")), ["ro", "ro2"])

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_a_direct_send_never_overtakes_the_queue(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        self.run_cli("add", "--key", "K", "--title", "t", urls=[self.dead], token=sender)
        os.chmod(self.outbox, 0o500)  # the resolve can't be queued behind the add
        self.addCleanup(os.chmod, self.outbox, 0o700)
        r = self.run_cli("resolve", "--key", "K", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([i["status"] for i in self.items(a, reader) if i["key"] == "K"], ["resolved"])


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

    def test_broken_http_fails_over_and_queues(self):
        """A URL that answers with something that isn't HTTP (another service on the port) or
        cuts the response short raises http.client.HTTPException, which isn't an OSError: the
        CLI must treat it like a dead hub, not crash with a traceback (hard rule 8)."""
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        for name, payload in (("not http", b"SSH-2.0-OpenSSH_9.6\r\n"),
                              ("truncated", b"HTTP/1.1 201 Created\r\nContent-Length: 500\r\n\r\n{\"id\"")):
            with self.subTest(name):
                bad = garbage_server(self, payload)
                r = self.run_cli("add", "--key", "g-" + name[:3], "--title", "t", urls=[bad, a.url],
                                 token=sender)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("created", r.stdout)
                self.assertNotIn("Traceback", r.stderr)
                r = self.run_cli("add", "--key", "q-" + name[:3], "--title", "t", urls=[bad], token=sender)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("queued", r.stderr)
                self.assertNotIn("Traceback", r.stderr)
                r = self.run_cli("health", urls=[bad, a.url], token=sender)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("DOWN", r.stdout)
                self.assertNotIn("Traceback", r.stderr)
        # `health` flushed the queued ones through the second URL
        self.assertEqual(self.queued(), [])
        self.assertEqual(sorted(i["key"] for i in self.items(a, reader, "open")),
                         ["g-not", "g-tru", "q-not", "q-tru"])

    def test_redirect_is_not_followed(self):
        """A hub URL that answers 3xx (a captive portal, a proxy, a moved host) must not get
        the item turned into a GET, nor the token sent to wherever it points: next hub."""
        import http.server
        import threading
        seen = []

        class Catch(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.command, self.headers.get("Authorization")))
                body = b'{"id":"FAKE","created":true}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            do_POST = do_GET

            def log_message(self, *a):
                pass

        catch = http.server.HTTPServer(("127.0.0.1", 0), Catch)
        target = "http://127.0.0.1:%d" % catch.server_address[1]

        class Moved(Catch):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", target + self.path)
                self.send_header("Content-Length", "0")
                self.end_headers()
            do_POST = do_GET

        moved = http.server.HTTPServer(("127.0.0.1", 0), Moved)
        for srv in (catch, moved):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.addCleanup(srv.server_close)
            self.addCleanup(srv.shutdown)
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        url = "http://127.0.0.1:%d" % moved.server_address[1]
        r = self.run_cli("add", "--key", "r1", "--title", "t", urls=[url, a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(a.url, r.stdout)
        r = self.run_cli("add", "--key", "r2", "--title", "t", urls=[url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued", r.stderr)
        self.assertEqual(seen, [])
        self.assertEqual([i["key"] for i in self.items(a, reader, "open")], ["r1"])

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


class ResolveEveryHub(CliTestCase):
    """Hubs that don't replicate to each other (the Mac's built-in hub has no peers yet) each
    hold only what was posted to them. A card that went to hub B while A was down must still
    be resolved when A is back: a resolve that finds nothing open goes on to the next hub."""

    def two_hubs(self):
        a = self.make_hub("hub-a", port=free_port())
        b = self.make_hub("hub-b")
        sender, reader_a = self.tokens(a)
        b.store.ensure_token("sender-shared", "sender", sender)
        _, reader_b = self.tokens(b)
        return a, b, sender, reader_a, reader_b

    def restart(self, hub):
        """The same hub (port, database) started again after hub.stop()."""
        return self.make_hub(hub.hub_id, port=hub.cfg["port"], db=hub.cfg["db"])

    def post_while_a_is_down(self, a, b, key, sender):
        a.stop()
        r = self.run_cli("add", "--key", key, "--title", "waiting", urls=[a.url, b.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b.url, r.stdout)
        return self.restart(a)  # A is back, and doesn't have the card

    def test_card_on_the_second_hub_is_resolved(self):
        a, b, sender, reader_a, reader_b = self.two_hubs()
        a = self.post_while_a_is_down(a, b, "agent:testbox:s1", sender)
        r = self.run_cli("resolve", "--key", "agent:testbox:s1", urls=[a.url, b.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("resolved", r.stdout)
        self.assertEqual(self.items(b, reader_b, "open"), [])
        self.assertEqual(self.queued(), [])

    def test_stops_at_the_first_hub_that_resolves(self):
        a, b, sender, reader_a, reader_b = self.two_hubs()
        for hub in (a, b):
            self.run_cli("add", "--key", "k", "--title", "t", urls=[hub.url], token=sender)
        r = self.run_cli("resolve", "--key", "k", urls=[a.url, b.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.items(a, reader_a, "open"), [])
        self.assertEqual([i["key"] for i in self.items(b, reader_b, "open")], ["k"])

    def test_nothing_open_anywhere_is_still_ok(self):
        a, b, sender, _, _ = self.two_hubs()
        r = self.run_cli("resolve", "--key", "never", urls=[a.url, b.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("nothing open", r.stdout)
        self.assertEqual(self.queued(), [])

    def test_a_hub_down_at_resolve_time_gets_it_on_flush(self):
        port = free_port()
        a = self.make_hub("hub-a")
        sender, reader_a = self.tokens(a)
        b = self.make_hub("hub-b", port=port)
        b.store.ensure_token("sender-shared", "sender", sender)
        _, reader_b = self.tokens(b)
        url_b = b.url
        self.run_cli("add", "--key", "agent:testbox:s2", "--title", "waiting", urls=[url_b], token=sender)
        b.stop()
        # A: nothing open; B: down. Exit 0 (rule 8), the resolve kept for B.
        r = self.run_cli("resolve", "--key", "agent:testbox:s2", urls=[a.url, url_b], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])  # the outbox proper isn't held up by it
        b2 = self.make_hub("hub-b", port=port, db=b.cfg["db"])
        r = self.run_cli("flush", urls=[a.url, url_b], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.items(b2, reader_b, "open"), [])
        # sent: nothing left to retry
        r = self.run_cli("flush", urls=[a.url, url_b], token=sender)
        self.assertNotIn("resolve", r.stderr)

    def test_a_new_card_of_the_key_cancels_the_kept_resolve(self):
        port = free_port()
        a = self.make_hub("hub-a")
        sender, _ = self.tokens(a)
        b = self.make_hub("hub-b", port=port)
        b.store.ensure_token("sender-shared", "sender", sender)
        _, reader_b = self.tokens(b)
        url_b = b.url
        self.run_cli("add", "--key", "k3", "--title", "old", urls=[url_b], token=sender)
        b.stop()
        self.run_cli("resolve", "--key", "k3", urls=[a.url, url_b], token=sender)
        b2 = self.make_hub("hub-b", port=port, db=b.cfg["db"])
        # The next wait's card (same key) goes out first: the old resolve must not close it.
        self.run_cli("add", "--key", "k3", "--title", "new", urls=[url_b], token=sender)
        self.run_cli("flush", urls=[a.url, url_b], token=sender)
        self.assertEqual([i["title"] for i in self.items(b2, reader_b, "open")], ["new"])

    def test_lease_reaping_reaches_the_second_hub(self):
        a, b, sender, _, reader_b = self.two_hubs()
        a = self.post_while_a_is_down(a, b, "agent:testbox:s4", sender)
        leases = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        os.makedirs(leases)
        dead = subprocess.Popen(["true"])
        dead.wait()
        with open(os.path.join(leases, "s4"), "w") as fh:
            fh.write("key=agent:testbox:s4\npid=%d\nstart=Thu Jan  1 00:00:00 1970\n" % dead.pid)
        r = self.run_cli("flush", urls=[a.url, b.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.items(b, reader_b, "open"), [])

    def test_the_claude_hooks_resolve_reaches_the_second_hub(self):
        # The hook's own resolve goes through the CLI: an idle card posted while A was down
        # is closed by the reply once A is back.
        a, b, sender, _, reader_b = self.two_hubs()
        hook_sh = os.path.join(os.path.dirname(CLI), "..", "integrations", "claude-code", "needs-you-hook.sh")
        cli = os.path.join(self.tmp, "needs-you")
        with open(cli, "w") as fh:
            fh.write("#!/bin/sh\nexec %s %s \"$@\"\n" % (sys.executable, CLI))
        os.chmod(cli, 0o755)
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_URLS": "%s,%s" % (a.url, b.url), "NEEDS_YOU_TOKEN": sender, "NEEDS_YOU_BIN": cli,
               "NEEDS_YOU_AGENT_ALERTS": "1", "NEEDS_YOU_HOOK_PLATFORM": "linux"}

        def hook(mode, event, **extra):
            payload = dict({"session_id": "s5", "cwd": self.tmp, "hook_event_name": event}, **extra)
            r = subprocess.run(["bash", hook_sh, mode], input=json.dumps(payload), env=env, capture_output=True,
                               text=True, timeout=60, cwd=self.tmp)
            self.assertEqual(r.returncode, 0, r.stderr)

        a.stop()
        hook("notify", "Notification", notification_type="idle_prompt")
        self.assertEqual(len(self.items(b, reader_b, "open")), 1)
        self.restart(a)
        hook("resolve", "UserPromptSubmit", prompt="go on")
        self.assertEqual(self.items(b, reader_b, "open"), [])


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


    def test_a_zero_cap_never_drops_the_request_being_made(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        for n, env in enumerate(({"NEEDS_YOU_OUTBOX_MAX": "0"}, {"NEEDS_YOU_OUTBOX_MAX_DAYS": "0"},
                                 {"NEEDS_YOU_OUTBOX_MAX": "-5"})):
            key = "cap-%d" % n
            r = self.run_cli("add", "--key", key, "--title", "t", urls=[a.url], token=sender, extra_env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("created", r.stdout, (env, r.stderr))
            r = self.run_cli("add", "--key", key + "-q", "--title", "t", urls=[self.dead], token=sender,
                             extra_env=env)
            self.assertIn("queued", r.stderr)
            self.assertEqual(len(self.queued()), 1, env)  # the newest is kept
            os.remove(os.path.join(self.outbox, self.queued()[0]))

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


class PostRate(CliTestCase):
    """ADR 0010: the hub's 429 rate_limited never fails the caller: the post is queued (exit
    0), held until the hub's retry_after, one per key, and sent by a later run. Resolves go."""

    def test_rate_limited_posts_are_queued_and_sent_later(self):
        a = self.make_hub("hub-a", post_rate_limit=2, post_rate_window_seconds=2)
        sender, reader = self.tokens(a)
        for key in ("a", "b"):
            r = self.run_cli("add", "--key", key, "--title", "t", urls=[a.url], token=sender)
            self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("add", "--key", "c", "--title", "first", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("slow down", r.stderr)
        self.assertEqual(len(self.queued()), 1)
        # held, not sent: a later post of the same key replaces it in the outbox
        r = self.run_cli("add", "--key", "c", "--title", "second", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("add", "--key", "d", "--title", "t", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.queued()), 2)  # c (second) and d
        # a resolve still goes at once, and cancels the held post of its key
        r = self.run_cli("resolve", "--key", "d", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.queued()), 1)
        self.assertEqual(sorted(i["key"] for i in self.items(a, reader, "open")), ["a", "b"])
        time.sleep(2.5)  # the hub's retry_after
        r = self.run_cli("flush", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])
        got = {i["key"]: i["title"] for i in self.items(a, reader, "open")}
        self.assertEqual(got, {"a": "t", "b": "t", "c": "second"})


    def test_a_held_post_and_a_kept_resolve_of_its_key(self):
        # The kept resolve is for the card before the held post: it goes to its hub while the
        # post waits, and the post, once it goes out, isn't closed by it.
        port = free_port()
        a = self.make_hub("hub-a", post_rate_limit=1, post_rate_window_seconds=2)
        sender, reader_a = self.tokens(a)
        b = self.make_hub("hub-b", port=port)
        b.store.ensure_token("sender-shared", "sender", sender)
        _, reader_b = self.tokens(b)
        url_b = b.url
        self.run_cli("add", "--key", "k", "--title", "old", urls=[url_b], token=sender)
        b.stop()
        self.run_cli("resolve", "--key", "k", urls=[a.url, url_b], token=sender)  # kept for B
        b2 = self.make_hub("hub-b", port=port, db=b.cfg["db"])
        self.run_cli("add", "--key", "x", "--title", "t", urls=[a.url, url_b], token=sender)
        r = self.run_cli("add", "--key", "k", "--title", "new", urls=[a.url, url_b], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("slow down", r.stderr)
        r = self.run_cli("flush", urls=[a.url, url_b], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.items(b2, reader_b, "open"), [])  # the old card went
        self.assertEqual(len(self.queued()), 1)                  # the new one still waits
        time.sleep(2.5)
        r = self.run_cli("flush", urls=[a.url, url_b], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])
        self.assertEqual({i["key"]: i["title"] for i in self.items(a, reader_a, "open")}, {"x": "t", "k": "new"})
        kept = os.path.join(self.outbox, "kept-resolves")
        self.assertEqual([n for n in os.listdir(kept) if n.endswith(".json")] if os.path.isdir(kept) else [], [])


class LineSeparators(CliTestCase):
    def test_title_line_separators_become_spaces(self):
        # ADR 0010: the hub refuses U+2028/U+2029 in a title; the CLI turns them into spaces
        # so a sender that passes one (text copied from a web page) keeps its card.
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        r = self.run_cli("add", "--key", "ls", "--title", "Deploy api now", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([i["title"] for i in self.items(a, reader, "open")], ["Deploy api now"])


def load_cli():
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("needs_you_cli", CLI)
    spec = importlib.util.spec_from_loader("needs_you_cli", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TerminalText(unittest.TestCase):
    """Text from a hub, an item, a release or a peer is printed with its control
    characters shown, not acted on (ANSI, OSC 8 links, OSC 52 clipboard writes)."""

    EVIL = "a\x1b]52;c;cHduZWQ=\x07b\x1b[2Jc\x1b]8;;https://x\x1b\\d\x9b2J\re\u202ef"

    def test_clean_escapes_controls(self):
        cli = load_cli()
        out = cli.clean(self.EVIL + "\n\tg")
        for raw in ("\x1b", "\x07", "\x9b", "\r", "\n", "\t", "\u202e"):
            self.assertNotIn(raw, out)
        self.assertEqual(cli.clean(out), out)  # idempotent: cleaning twice changes nothing
        self.assertTrue(out.startswith("a\\x1b]52;c;cHduZWQ=\\x07b\\x1b[2Jc"), out)

    def test_multiline_keeps_newlines_and_tabs_only(self):
        out = load_cli().clean(self.EVIL + "\n\tg", multiline=True)
        self.assertTrue(out.endswith("\n\tg"), out)
        for raw in ("\x1b", "\x07", "\x9b", "\r", "\u202e"):
            self.assertNotIn(raw, out)

    def test_warn_cleans(self):
        import contextlib
        import io
        cli = load_cli()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            cli.warn("hub said: " + self.EVIL)
        self.assertNotIn("\x1b", err.getvalue())
        self.assertNotIn("\x07", err.getvalue())
        self.assertIn("\\x1b[2J", err.getvalue())


class Steps(CliTestCase):
    def test_parse_step(self):
        parse = load_cli().parse_step
        cases = [
            ("Approve the deploy", {"text": "Approve the deploy"}),
            ("Set FOO=bar in .env", {"text": "Set FOO=bar in .env"}),       # '=' in text, no URL
            ("Run a=b:c", {"text": "Run a=b:c"}),                          # not a scheme we know
            ("Approve=https://ci/x?a=b&c=d",                               # '=' in the query kept
             {"text": "Approve", "link": {"label": "Open", "url": "https://ci/x?a=b&c=d"}}),
            ("Set FOO=bar = https://x/y",                                  # first '=' that starts a URL
             {"text": "Set FOO=bar", "link": {"label": "Open", "url": "https://x/y"}}),
            ("Reply=slack://channel?team=T&id=C",
             {"text": "Reply", "link": {"label": "Open", "url": "slack://channel?team=T&id=C"}}),
            ("Insecure=http://x",                                          # split; the hub rejects it
             {"text": "Insecure", "link": {"label": "Open", "url": "http://x"}}),
        ]
        for raw, want in cases:
            with self.subTest(raw):
                self.assertEqual(parse(raw), want)

    def test_steps_end_to_end(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        path = os.path.join(self.tmp, "steps.json")
        with open(path, "w") as fh:
            json.dump([{"text": "Check **staging**", "done": True}], fh)
        r = self.run_cli("add", "--key", "s", "--title", "Ship",
                         "--steps-json", "@" + path,
                         "--step", "Approve=https://ci/run/9?x=1",
                         "--step", "Set MODE=live", urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        item = self.items(a, reader, "open")[0]
        self.assertEqual(item["steps"], [
            {"text": "Check **staging**", "done": True},
            {"text": "Approve", "done": False, "link": {"label": "Open", "url": "https://ci/run/9?x=1"}},
            {"text": "Set MODE=live", "done": False},
        ])
        r = self.run_cli("add", "--key", "j", "--title", "t", "--steps-json",
                         '[{"text": "a", "link": {"label": "Doc", "url": "https://d"}}]',
                         urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_question_end_to_end(self):
        a = self.make_hub("hub-a")
        sender, reader = self.tokens(a)
        question = {"id": "toolu_1", "items": [{"header": "DB", "text": "Which?",
                                                 "options": [{"label": "Postgres", "description": "Durable"}]}]}
        path = os.path.join(self.tmp, "question.json")
        with open(path, "w") as fh:
            json.dump(question, fh)
        r = self.run_cli("add", "--key", "q", "--title", "Claude asks", "--question-json", "@" + path,
                         urls=[a.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        want = {"id": "toolu_1", "answerable": False, "items": [{"header": "DB", "text": "Which?", "multi_select": False,
                                            "options": [{"label": "Postgres", "description": "Durable"}]}]}
        self.assertEqual(self.items(a, reader, "open")[0]["question"], want)
        for bad in ("{not json", '["a list"]', '{"items": []}', "@" + os.path.join(self.tmp, "missing.json")):
            with self.subTest(bad):
                r = self.run_cli("add", "--key", "k", "--title", "t", "--question-json", bad,
                                 urls=[a.url], token=sender)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(self.queued(), [])

    def test_bad_steps_exit_2_and_are_not_queued(self):
        a = self.make_hub("hub-a")
        sender, _ = self.tokens(a)
        eleven = []
        for i in range(11):
            eleven += ["--step", "s%d" % i]
        cases = [
            ["--step", "x=http://insecure"],            # the hub rejects the scheme
            ["--steps-json", "{not json"],
            ["--steps-json", '{"text": "not a list"}'],
            ["--steps-json", "@" + os.path.join(self.tmp, "missing.json")],
            eleven,
        ]
        for extra in cases:
            with self.subTest(extra[:2]):
                r = self.run_cli("add", "--key", "k", "--title", "t", *extra, urls=[a.url], token=sender)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertEqual(self.queued(), [])


class AnswerWait(CliTestCase):
    """needs-you answer-wait against a real hub: the answer as JSON (0), a timeout (3), no
    answer coming (4), and a hub that doesn't know the item yet."""
    QUESTION = {"id": "toolu_1", "answerable": True, "items": [
        {"text": "Which database?", "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]}

    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def ask(self, key="q", question=None):
        r = self.run_cli("add", "--key", key, "--title", "Claude asks",
                         "--question-json", json.dumps(question or self.QUESTION),
                         urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.items(self.hub, self.reader, "open")[0]

    def click(self, item, label="SQLite"):
        return request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], self.reader,
                       {"question_id": "toolu_1", "content_updated_at": item["content_updated_at"],
                        "answers": [{"selected": [label]}]})

    def test_waits_for_the_click(self):
        item = self.ask()
        threading.Timer(1.0, self.click, args=(item,)).start()
        started = time.time()
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "20", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(time.time() - started, 10)
        got = json.loads(r.stdout)
        self.assertEqual((got["id"], got["question_id"], got["answers"]),
                         (item["id"], "toolu_1", [{"selected": ["SQLite"]}]))
        # already answered: at once
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "0", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_prints_typed_words(self):
        q = {"id": "toolu_1", "answerable": True, "items": [
            {"text": "Which database?", "allow_other": True, "options": [{"label": "Postgres"}]}]}
        item = self.ask("typed", q)
        owner, _ = self.hub.store.add_token("mac", "owner")  # typed words come from the owner only
        st, body = request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], owner,
                           {"question_id": "toolu_1", "content_updated_at": item["content_updated_at"],
                            "answers": [{"selected": [], "text": "MySQL"}]})
        self.assertEqual(st, 200, body)
        r = self.run_cli("answer-wait", "--key", "typed", "--timeout", "5", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["answers"], [{"selected": [], "text": "MySQL"}])
        # Typed words print as escaped JSON: nothing in them can act on the terminal.
        q2 = dict(q, id="toolu_2")
        self.ask("typed2", q2)
        item = [i for i in self.items(self.hub, self.reader, "open") if i["key"] == "typed2"][0]
        st, body = request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], owner,
                           {"question_id": "toolu_2", "content_updated_at": item["content_updated_at"],
                            "answers": [{"selected": [], "text": "café \u2067rtl\u2069? no: \u2028 refused"}]})
        self.assertEqual((st, body.get("field")), (400, "answers[0].text"))
        st, body = request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], owner,
                           {"question_id": "toolu_2", "content_updated_at": item["content_updated_at"],
                            "answers": [{"selected": [], "text": "café \U0001F600 ok"}]})
        self.assertEqual(st, 200, body)
        r = self.run_cli("answer-wait", "--key", "typed2", "--timeout", "5", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.isascii() and "\x1b" not in r.stdout, r.stdout)
        self.assertEqual(json.loads(r.stdout)["answers"][0]["text"], "café \U0001F600 ok")

    def test_timeout_is_exit_3_and_never_an_answer(self):
        self.ask()
        started = time.time()
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "1", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertLess(time.time() - started, 10)
        self.assertIsNone(self.items(self.hub, self.reader, "open")[0]["answer"])

    def test_no_answer_will_come_is_exit_4(self):
        self.ask("plain", {"items": [{"text": "Ok?", "options": [{"label": "Yes"}]}]})
        r = self.run_cli("answer-wait", "--key", "plain", "--timeout", "5", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.ask("closed")
        self.run_cli("resolve", "--key", "closed", urls=[self.hub.url], token=self.sender)
        r = self.run_cli("answer-wait", "--key", "closed", "--timeout", "5", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 4, r.stderr)

    def test_unknown_item_or_hub_waits_out_the_timeout(self):
        for urls in ([self.hub.url], [self.dead]):
            r = self.run_cli("answer-wait", "--key", "nope", "--timeout", "1", urls=urls, token=self.sender)
            self.assertEqual(r.returncode, 3, r.stderr)

    def test_failover_to_the_hub_that_answers(self):
        item = self.ask()
        self.click(item, "Postgres")
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "5", urls=[self.dead, self.hub.url],
                         token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["answers"], [{"selected": ["Postgres"]}])

    def test_an_earlier_questions_answer_is_never_taken_for_this_one(self):
        # Security review 0.2: the hub reads back the last item with the key once none is
        # open, so while this run's post is still in the outbox (or went to another hub) the
        # answer to an earlier run's question came back as if the person had just clicked.
        item = self.ask("deploy", dict(self.QUESTION, id="run-1"))
        request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], self.reader,
                {"question_id": "run-1", "content_updated_at": item["content_updated_at"],
                 "answers": [{"selected": ["Postgres"]}]})
        self.run_cli("resolve", "--key", "deploy", urls=[self.hub.url], token=self.sender)
        r = self.run_cli("answer-wait", "--key", "deploy", "--question-id", "run-2", "--timeout", "2",
                         urls=[self.hub.url], token=self.sender)
        self.assertEqual((r.returncode, r.stdout), (3, ""), r.stderr)
        # The question it names, once posted and clicked, is answered as usual.
        item = self.ask("deploy", dict(self.QUESTION, id="run-2"))
        request("POST", self.hub.url + "/v1/items/%s/answer" % item["id"], self.reader,
                {"question_id": "run-2", "content_updated_at": item["content_updated_at"],
                 "answers": [{"selected": ["SQLite"]}]})
        r = self.run_cli("answer-wait", "--key", "deploy", "--question-id", "run-2", "--timeout", "5",
                         urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        got = json.loads(r.stdout)
        self.assertEqual((got["question_id"], got["answers"]), ("run-2", [{"selected": ["SQLite"]}]))

    def test_refused_token_and_usage(self):
        self.ask()
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "1", urls=[self.hub.url], token=self.reader)
        self.assertEqual(r.returncode, 2, r.stderr)
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "1", urls=None, token=None)
        self.assertEqual(r.returncode, 2, r.stderr)
        r = self.run_cli("answer-wait", "--key", "q", "--timeout", "-1", urls=[self.hub.url], token=self.sender)
        self.assertEqual(r.returncode, 2, r.stderr)


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
        r = self.run_cli("self-update", urls=[a.url, self.dead], cli=target)
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


class UsageErrors(CliTestCase):
    """Bad arguments are a usage error (exit 2, one line), never a traceback."""

    def test_unreadable_body_file_and_bad_expiry(self):
        for extra in (["--body-file", os.path.join(self.tmp, "missing")], ["--expires-in", "nan"],
                      ["--expires-in", "inf"], ["--expires-in", "1e300"]):
            r = self.run_cli("add", "--key", "k", "--title", "t", *extra, urls=[self.dead])
            self.assertEqual(r.returncode, 2, (extra, r.stderr))
            self.assertNotIn("Traceback", r.stderr)
            self.assertEqual(self.queued(), [])
        r = self.run_cli("run", "--expires-in", "nan", "--", "true", urls=[self.dead])
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        bad = os.path.join(self.tmp, "latin1.txt")
        with open(bad, "wb") as fh:
            fh.write(b"caf\xe9")
        r = self.run_cli("add", "--key", "k", "--title", "t", "--body-file", bad, urls=[self.dead])
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertNotIn("Traceback", r.stderr)

    def test_blank_resolve_target_is_not_queued(self):
        # The hub refuses it, so queued offline it would only sit in the outbox until dropped.
        for flag, value in (("--id", ""), ("--key", ""), ("--id", "  ")):
            r = self.run_cli("resolve", flag, value, urls=[self.dead])
            self.assertEqual(r.returncode, 2, (flag, value, r.stderr))
            self.assertNotIn("Traceback", r.stderr)
            self.assertEqual(self.queued(), [])


class NoConfigNoOutbox(CliTestCase):
    def test_says_so_and_exits_0(self):
        # No config and an outbox that can't be written: the post is lost, but the caller's
        # job must not fail (it used to be a PermissionError traceback, exit 1).
        ro = os.path.join(self.tmp, "ro")
        os.makedirs(ro)
        os.chmod(ro, 0o500)
        self.addCleanup(lambda: os.path.isdir(ro) and os.chmod(ro, 0o700))
        if os.access(ro, os.W_OK):
            self.skipTest("running as root")
        r = self.run_cli("add", "--key", "k", "--title", "t", token=None,
                         extra_env={"NEEDS_YOU_OUTBOX": os.path.join(ro, "outbox")})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("dropped", r.stderr)


class SessionItemById(CliTestCase):
    """One card for one wait: the note that keeps a session's "waiting" card off goes away
    when the agent resolves its item by id, as it does when it resolves by key."""
    SESSION = {"CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "sess-1"}

    def notes(self):
        d = os.path.join(self.home, ".local", "state", "needs-you", "session-items", "sess-1")
        try:
            return os.listdir(d)
        except OSError:
            return []

    def add(self, urls, token, key="work:ACME-1:decide"):
        r = self.run_cli("--json", "add", "--key", key, "--title", "Choose", urls=urls, token=token,
                         extra_env=self.SESSION)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)["id"] if r.stdout.strip() else None

    def test_resolve_by_id_online(self):
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        item_id = self.add([hub.url], sender)
        self.add([hub.url], sender, key="work:ACME-2:other")
        self.assertEqual(len(self.notes()), 2)
        r = self.run_cli("resolve", "--id", item_id, urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.notes()), 1)  # only that item's note

    def test_resolve_by_id_while_the_hub_is_down(self):
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        item_id = self.add([hub.url], sender)
        r = self.run_cli("resolve", "--id", item_id, urls=[self.dead], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued", r.stderr)
        self.assertEqual(self.notes(), [])

    def test_an_item_born_expired_keeps_no_note(self):
        # --expires-in 0 (or less) makes an item that is already gone: no session waits on it,
        # so the "waiting" card must not be held back for the note's 48 hours.
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        self.add([hub.url], sender)
        self.assertEqual(len(self.notes()), 1)
        for hours in ("0", "-1"):
            r = self.run_cli("add", "--key", "work:ACME-1:decide", "--title", "Choose", "--expires-in", hours,
                             urls=[hub.url], token=sender, extra_env=self.SESSION)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.notes(), [], hours)

    def test_queued_add_learns_its_id_when_sent(self):
        self.assertIsNone(self.add([self.dead], "t"))
        self.assertEqual(len(self.notes()), 1)
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("flush", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        item_id = self.items(hub, reader, "open")[0]["id"]
        r = self.run_cli("resolve", "--id", item_id, urls=[self.dead], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.notes(), [])


if __name__ == "__main__":
    import unittest
    unittest.main()
