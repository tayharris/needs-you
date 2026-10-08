"""Security audit #16: the hub answers only to Host names that are its own (DNS rebinding
from a browser). IP literals, localhost, bind names, public_url, this machine's names and
MagicDNS names, and allowed_hosts pass; anything else is 421, a malformed Host is 400."""
from __future__ import annotations

import http.client
import json
import os
import socket
import unittest
from unittest import mock

from support import HubTestCase, hubmod, request  # noqa: E402

ME = socket.gethostname().lower().rstrip(".")
SHORT = ME.split(".")[0]


class HostCheck(HubTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a", public_url="http://hub-a.example.ts.net:8765",
                                 allowed_hosts=["needs-you.internal.example"], maintenance_seconds=0)

    def get(self, host, path="/v1/health", hub=None):
        hub = hub or self.hub
        addr, port = hub.server.server_address[:2]
        conn = http.client.HTTPConnection(addr, port, timeout=5)
        try:
            headers = {} if host is None else {"Host": host}
            if host is None:
                conn.putrequest("GET", path, skip_host=True)
                conn.endheaders()
            else:
                conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read().decode("utf-8") or "{}")
        finally:
            conn.close()

    def test_own_names_pass(self):
        port = self.hub.port
        # The hub read the host name when it started, just now: read it again here, not at
        # import (a Mac waking on another network renames itself mid-run).
        me = socket.gethostname().lower().rstrip(".")
        short = me.split(".")[0]
        for host in ("127.0.0.1:%d" % port, "127.0.0.1", "localhost:%d" % port, "LOCALHOST",
                     "[::1]:%d" % port, "100.101.102.103:8765", "[fd7a:115c:a1e0::1]:8765",
                     "hub-a.example.ts.net:8765", "hub-a.example.ts.net.", "HUB-A.Example.TS.NET",
                     "hub-a", "hub-a.other-tailnet.ts.net", "needs-you.internal.example:443",
                     me, short, short + ".local", short + ".tail1234.ts.net"):
            with self.subTest(host):
                st, body = self.get(host)
                self.assertEqual(st, 200, body)

    def test_a_rename_is_picked_up_on_a_miss(self):
        # A Mac waking on another network renames itself (<name>.local changes) while the hub
        # runs; it read its names once at start and answered the new name 421 until a restart.
        calls = []

        def renamed():
            calls.append(1)
            return "Renamed-Mac.example.lan"

        with mock.patch.object(hubmod.socket, "gethostname", renamed):
            st, _ = self.get("renamed-mac.local")
            self.assertEqual(st, 421)  # just read at start: not again yet (rate-limited)
            self.assertEqual(calls, [])
            self.hub._host_names_read -= hubmod.HOST_NAMES_REREAD_SECONDS + 1
            for host in ("renamed-mac.local", "renamed-mac", "Renamed-Mac.example.lan:8765"):
                with self.subTest(host):
                    st, body = self.get(host)
                    self.assertEqual(st, 200, body)
            self.assertEqual(len(calls), 1)
            # a name that still isn't ours: 421, and no re-read for every such request
            for _ in range(5):
                self.assertEqual(self.get("evil.example")[0], 421)
            self.assertEqual(len(calls), 1)
            # A rebinding Host that makes the hub re-read: the names come from this machine
            # (gethostname) and the config only, never from the request, so it is still 421,
            # and so is every request after it.
            self.hub._host_names_read -= hubmod.HOST_NAMES_REREAD_SECONDS + 1
            for host in ("attacker.example", "attacker.example", "renamed-mac.attacker.example"):
                st, body = self.get(host)
                self.assertEqual(st, 421, body)
            self.assertEqual(len(calls), 2)
            self.assertNotIn("attacker.example", self.hub.host_names)

    def test_missing_host_passes(self):
        # HTTP/1.0 clients may leave it out; a browser always sends one.
        st, body = self.get(None)
        self.assertEqual(st, 200, body)

    def test_other_names_are_421(self):
        for host in ("evil.example", "evil.example:8765", "rebind.attacker.example",
                     "hub-a.example.ts.net.evil.example", "xhub-a.example.ts.net",
                     "localhost.evil.example", "evil.ts.net", "ts.net", "attacker.tail1234.ts.net"):
            with self.subTest(host):
                for path in ("/v1/health", "/dl/manifest.json", "/join/nyi_x", "/v1/items"):
                    st, body = self.get(host, path)
                    self.assertEqual(st, 421, (path, body))
                    self.assertEqual(body["error"], "misdirected")

    def test_malformed_host_is_400(self):
        for host in ("evil.example:port", "a b", "user@hub-a", "[::1", "hub/a", "hub-a:99999999"):
            with self.subTest(host):
                st, body = self.get(host)
                self.assertEqual(st, 400, body)

    def test_star_turns_it_off(self):
        hub = self.make_hub("hub-b", allowed_hosts="*")
        st, _ = self.get("anything.example", hub=hub)
        self.assertEqual(st, 200)

    def test_env_and_flag_add_names(self):
        with mock.patch.dict(os.environ, {"NEEDS_YOU_HUB_ALLOWED_HOSTS": "Mac-Studio.lan., other.example"}):
            cfg = hubmod.load_config(None, {"allowed_hosts": ["flag.example"], "db": ":memory:"})
        self.assertEqual(cfg["allowed_hosts"], ["flag.example", "mac-studio.lan", "other.example"])
        names, labels = hubmod.known_host_names(cfg)
        self.assertIn("mac-studio.lan", names)
        self.assertIn(SHORT, labels)

    def test_urllib_clients_still_work(self):
        # what the CLI, peers and the Mac app send: Host = the URL's host:port
        sender, _ = self.tokens(self.hub)
        st, body = request("POST", self.hub.url + "/v1/items", sender, {"key": "work:h:x", "title": "t"})
        self.assertEqual(st, 201, body)

    def test_cli_fails_over_on_421(self):
        import importlib.machinery
        import importlib.util
        from support import CLI
        loader = importlib.machinery.SourceFileLoader("needs_you_cli_host", CLI)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        answers = {"http://a": (421, {"error": "misdirected"}), "http://b": (201, {"id": "x"})}
        cfg = mock.Mock(urls=["http://a", "http://b"], token="t", timeout=1)
        with mock.patch.object(cli, "_call", side_effect=lambda url, *a: answers[url]):
            self.assertEqual(cli.send(cfg, "POST", "/v1/items", {})[0], "http://b")
        answers["http://a"] = (400, {"error": "invalid"})
        with mock.patch.object(cli, "_call", side_effect=lambda url, *a: answers[url]):
            with self.assertRaises(cli.Rejected):
                cli.send(cfg, "POST", "/v1/items", {})


class HostHeaderParsing(unittest.TestCase):
    def test_parse(self):
        p = hubmod.host_header_name
        self.assertEqual(p("Hub-A.example.ts.net:8765"), "hub-a.example.ts.net")
        self.assertEqual(p("hub-a.example.ts.net."), "hub-a.example.ts.net")
        self.assertEqual(p("[::1]:8765"), "::1")
        self.assertEqual(p("127.0.0.1"), "127.0.0.1")
        for bad in ("", "a b", "a@b", "[::1", "a:b", "a/b", "a:123456"):
            self.assertIsNone(p(bad), bad)


if __name__ == "__main__":
    unittest.main()
