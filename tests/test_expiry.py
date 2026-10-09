"""integrations/expiry/needs-you-expiry against a real local hub, with a loopback TLS server
(a self-signed certificate made by `openssl` at test time; those tests skip without it) and
a fake RDAP server (bootstrap file and domain answers) on loopback http. No network."""
from __future__ import annotations

import calendar
import io
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from support import CLI, ROOT, HubTestCase, free_port, hubmod, request

POLLER = os.path.join(ROOT, "integrations", "expiry", "needs-you-expiry")
OPENSSL = shutil.which("openssl")


def load_poller():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("needs_you_expiry", POLLER)
    spec = importlib.util.spec_from_loader("needs_you_expiry", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


poller = load_poller()


def day(offset: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(time.time() + offset * 86400))


class FakeRdap:
    """Loopback http: /dns.json (the bootstrap) and /rdap/domain/<name>."""

    def __init__(self, test):
        self.domains = {}  # name -> ISO date, or an int HTTP status
        self.bootstrap_status = 200
        self.hits = {"bootstrap": 0, "domain": 0}
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                port = self.server.server_address[1]
                if self.path == "/dns.json":
                    outer.hits["bootstrap"] += 1
                    if outer.bootstrap_status != 200:
                        return self.answer(outer.bootstrap_status, {})
                    return self.answer(200, {"version": "1.0", "services": [
                        [["com", "net"], ["http://127.0.0.1:%d/rdap/" % port]],
                        [["co.uk"], ["http://127.0.0.1:%d/rdap/" % port]],
                    ]})
                if self.path.startswith("/rdap/domain/"):
                    outer.hits["domain"] += 1
                    name = self.path[len("/rdap/domain/"):]
                    v = outer.domains.get(name, 404)
                    if isinstance(v, int):
                        return self.answer(v, {"errorCode": v})
                    return self.answer(200, {"objectClassName": "domain", "ldhName": name, "events": [
                        {"eventAction": "registration", "eventDate": "2001-01-01T00:00:00Z"},
                        {"eventAction": "expiration", "eventDate": v}]})
                self.answer(404, {})

            def answer(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/rdap+json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        test.addCleanup(self.srv.server_close)
        test.addCleanup(self.srv.shutdown)
        self.url = "http://127.0.0.1:%d/dns.json" % self.srv.server_address[1]


def make_cert(tmp: str, days: int):
    key, crt = os.path.join(tmp, "key.pem"), os.path.join(tmp, "cert.pem")
    subprocess.run([OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                    "-days", str(days), "-subj", "/CN=localhost"], check=True, capture_output=True)
    return crt, key


def tls_server(test, crt: str, key: str) -> int:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)

    def serve():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            try:
                conn.settimeout(5)
                with ctx.wrap_socket(conn, server_side=True) as tls:
                    tls.recv(1)
            except (OSError, ssl.SSLError):
                pass
            finally:
                conn.close()

    threading.Thread(target=serve, daemon=True).start()
    test.addCleanup(srv.close)
    return srv.getsockname()[1]


class ExpiryPoller(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.conf = os.path.join(self.home, ".config", "needs-you", "expiry.conf")
        os.makedirs(os.path.dirname(self.conf))
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "expiry.json")
        self.rdap = FakeRdap(self)
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        self.url = self.hub.url

    def write(self, *lines):
        with open(self.conf, "w") as fh:
            fh.write("\n".join(lines) + "\n")

    def poll(self, extra=None, *args):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "devbox", "NEEDS_YOU_URL": self.url, "NEEDS_YOU_TOKEN": self.sender,
               "NEEDS_YOU_BIN": CLI, "NEEDS_YOU_EXPIRY_RDAP_BOOTSTRAP": self.rdap.url,
               "NEEDS_YOU_EXPIRY_TIMEOUT": "3"}
        env.update(extra or {})
        r = subprocess.run([sys.executable, POLLER] + list(args), env=env, capture_output=True, text=True,
                           timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def open_items(self):
        items = request("GET", self.hub.url + "/v1/items?status=open", self.reader)[1]["items"]
        return {i["key"]: i for i in items}

    # ------------------------------------------------------------------

    def test_not_opted_in_posts_nothing(self):
        r = self.poll(None, "-v")
        self.assertIn("not set up", r.stderr)
        self.assertEqual(self.open_items(), {})
        self.assertFalse(os.path.exists(self.state))
        self.assertEqual(self.rdap.hits, {"bootstrap": 0, "domain": 0})

    def test_key_thresholds(self):
        self.write('key "Far key" %s' % day(40),
                   'key "Figma PAT" %s renew=https://www.figma.com/settings' % day(20),
                   'key "Deploy key" %s context=personal' % day(5),
                   'key "Tomorrow key" %s' % day(1),
                   'key "Old key" 2020-01-01')
        self.poll()
        items = self.open_items()
        self.assertNotIn("work:expiry:key:Far-key", items)
        pat = items["work:expiry:key:Figma-PAT"]
        self.assertEqual(pat["priority"], "low")
        self.assertEqual(pat["title"], "Figma PAT expires %s" % day(20))
        self.assertEqual(pat["links"], [{"label": "Renew", "url": "https://www.figma.com/settings"}])
        self.assertEqual(pat["context"], "work")
        self.assertEqual(pat["source"]["agent"], "expiry")
        self.assertNotIn("event", pat["source"])
        self.assertIsNotNone(pat["expires_at"])  # 3x the interval, so a stopped poller leaves nothing
        self.assertEqual(items["personal:expiry:key:Deploy-key"]["priority"], "normal")
        self.assertEqual(items["work:expiry:key:Tomorrow-key"]["priority"], "urgent")
        old = items["work:expiry:key:Old-key"]
        self.assertEqual((old["priority"], old["title"]), ("urgent", "Old key expired 2020-01-01"))
        self.assertEqual(len(items), 4)

        # Custom thresholds: the 40-day key now shows, as normal.
        self.poll({"NEEDS_YOU_EXPIRY_DAYS": "60=normal,2=urgent"})
        items = self.open_items()
        self.assertEqual(items["work:expiry:key:Far-key"]["priority"], "normal")
        self.assertEqual(items["work:expiry:key:Figma-PAT"]["priority"], "normal")

    def test_renewal_and_removal_resolve(self):
        self.write('key "A" %s' % day(5), 'key "B" %s' % day(5), 'key "C" %s' % day(5))
        self.poll()
        self.assertEqual(set(self.open_items()), {"work:expiry:key:A", "work:expiry:key:B", "work:expiry:key:C"})
        # A renewed (date out of the window), B removed.
        self.write('key "A" %s' % day(400), 'key "C" %s' % day(5))
        self.poll()
        self.assertEqual(set(self.open_items()), {"work:expiry:key:C"})
        # The whole list removed: everything it posted resolves, then nothing more happens.
        os.remove(self.conf)
        self.poll()
        self.assertEqual(self.open_items(), {})
        self.poll()
        self.assertEqual(self.open_items(), {})

    def test_same_content_does_not_repost_changes(self):
        self.write('key "A" %s' % day(5))
        self.poll()
        first = self.open_items()["work:expiry:key:A"]
        self.poll()
        again = self.open_items()["work:expiry:key:A"]
        self.assertEqual(first["id"], again["id"])
        self.assertEqual(first["title"], again["title"])

    def test_card_cap_keeps_the_nearest(self):
        self.write('key "A" %s' % day(20), 'key "B" %s' % day(3), 'key "C" %s' % day(10))
        self.poll({"NEEDS_YOU_EXPIRY_MAX_CARDS": "2"})
        self.assertEqual(set(self.open_items()), {"work:expiry:key:B", "work:expiry:key:C"})

    def test_domain_via_rdap(self):
        self.rdap.domains["example.com"] = day(10) + "T04:00:00Z"
        self.rdap.domains["acme.co.uk"] = day(300) + "T00:00:00.000+01:00"
        self.write("domain example.com renew=https://registrar.example.com/renew", "domain acme.co.uk")
        self.poll()
        items = self.open_items()
        self.assertEqual(set(items), {"work:expiry:domain:example.com"})
        card = items["work:expiry:domain:example.com"]
        self.assertEqual((card["title"], card["priority"]), ("Domain example.com expires %s" % day(10), "low"))
        # loopback http RDAP links never reach a card: only https ones do
        self.assertEqual(card["links"], [{"label": "Renew", "url": "https://registrar.example.com/renew"}])
        self.assertEqual(self.rdap.hits["domain"], 2)
        # Renewed at the registrar: resolves. The bootstrap came from the cache.
        self.rdap.domains["example.com"] = day(375) + "T04:00:00Z"
        self.poll()
        self.assertEqual(self.open_items(), {})
        self.assertEqual(self.rdap.hits["bootstrap"], 1)
        cache = os.path.join(os.path.dirname(self.state), "rdap-dns.json")
        self.assertEqual(os.stat(cache).st_mode & 0o777, 0o600)

    def test_failing_checks_card_after_n_runs(self):
        self.rdap.domains["example.com"] = 500
        dead = free_port()
        self.write("domain example.com", "tls 127.0.0.1:%d" % dead, 'key "A" %s' % day(400), "nonsense here")
        key = "work:expiry:devbox:checks-failing"
        r = self.poll()
        self.assertIn("RDAP HTTP 500", r.stderr)
        self.assertEqual(self.open_items(), {})  # one bad run is not a card
        self.poll()
        items = self.open_items()
        self.assertEqual(set(items), {key})
        card = items[key]
        self.assertEqual((card["priority"], card["title"]), ("low", "Expiry checks failing on devbox: 3 checks"))
        self.assertIn("RDAP HTTP 500", card["body"])
        self.assertIn("connection refused", card["body"])
        self.assertIn("line 4", card["body"])
        self.assertIsNone(card["expires_at"])
        # Fixed: the card resolves and the domain gets its own.
        self.rdap.domains["example.com"] = day(3) + "T00:00:00Z"
        self.write("domain example.com", 'key "A" %s' % day(400))
        self.poll()
        self.assertEqual(set(self.open_items()), {"work:expiry:domain:example.com"})

    def test_failing_check_keeps_the_last_date(self):
        self.rdap.domains["example.com"] = day(3) + "T00:00:00Z"
        self.write("domain example.com")
        self.poll()
        self.rdap.domains["example.com"] = 503
        self.poll()
        self.assertEqual(set(self.open_items()), {"work:expiry:domain:example.com"})

    def test_no_rdap_server_for_tld_and_bootstrap_down(self):
        self.rdap.bootstrap_status = 500
        self.write("domain example.com")
        r = self.poll({"NEEDS_YOU_EXPIRY_FAILS": "1"})
        self.assertIn("bootstrap", r.stderr)
        self.assertIn("work:expiry:devbox:checks-failing", self.open_items())
        self.rdap.bootstrap_status = 200
        self.write("domain example.org")
        r = self.poll({"NEEDS_YOU_EXPIRY_FAILS": "1"})
        self.assertIn("no RDAP server for .org", r.stderr)

    def test_bad_renew_link_is_refused(self):
        for bad in ("http://example.com/x", "javascript:alert(1)", "https://user@example.com/",
                    "https://example.com/a b", "vscode://file/x"):
            with self.subTest(bad=bad):
                things, errors = poller.parse_list_text('key "A" 2030-01-01 renew=%s' % bad)
                self.assertEqual(things, [])
                self.assertEqual(len(errors), 1)

    def test_hub_down_exits_zero_and_queues(self):
        self.url = "http://127.0.0.1:%d" % free_port()
        self.write('key "A" %s' % day(5))
        self.poll()
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        queued = [n for n in os.listdir(outbox) if n.endswith(".json")]
        self.assertEqual(len(queued), 1)
        self.poll()  # unchanged card, outbox backlog: not queued again
        self.assertEqual(len([n for n in os.listdir(outbox) if n.endswith(".json")]), 1)

    def test_cli_missing_exits_zero(self):
        self.write('key "A" %s' % day(5))
        r = self.poll({"NEEDS_YOU_BIN": os.path.join(self.tmp, "nope")})
        self.assertIn("cannot run needs-you", r.stderr)

    def test_dry_run_changes_nothing(self):
        self.write('key "A" %s' % day(5))
        r = self.poll(None, "--dry-run")
        self.assertIn("post work:expiry:key:A [normal] A expires", r.stdout)
        self.assertEqual(self.open_items(), {})
        self.assertFalse(os.path.exists(self.state))


class ExpiryTls(HubTestCase):
    def setUp(self):
        if not OPENSSL:
            self.skipTest("openssl not installed")
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.conf = os.path.join(self.home, ".config", "needs-you", "expiry.conf")
        os.makedirs(os.path.dirname(self.conf))
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def poll(self, *lines, **env_extra):
        with open(self.conf, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "devbox", "NEEDS_YOU_URL": self.hub.url, "NEEDS_YOU_TOKEN": self.sender,
               "NEEDS_YOU_BIN": CLI, "NEEDS_YOU_EXPIRY_TIMEOUT": "3"}
        env.update(env_extra)
        r = subprocess.run([sys.executable, POLLER, "-v"], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def open_items(self):
        items = request("GET", self.hub.url + "/v1/items?status=open", self.reader)[1]["items"]
        return {i["key"]: i for i in items}

    def test_self_signed_cert_with_verify_no(self):
        crt, key = make_cert(self.tmp, 5)
        port = tls_server(self, crt, key)
        r = self.poll("tls localhost:%d verify=no" % port)
        self.assertIn("tls localhost:%d: %s" % (port, day(5)), r.stderr)
        card = self.open_items()["work:expiry:tls:localhost:%d" % port]
        self.assertEqual(card["priority"], "normal")
        self.assertEqual(card["title"], "TLS certificate for localhost:%d expires %s" % (port, day(5)))

    def test_cert_far_away_is_no_card(self):
        crt, key = make_cert(self.tmp, 90)
        port = tls_server(self, crt, key)
        self.poll("tls localhost:%d verify=no" % port)
        self.assertEqual(self.open_items(), {})

    def test_untrusted_cert_is_its_own_urgent_card_at_once(self):
        crt, key = make_cert(self.tmp, 300)  # far from expiry: a date alone would look healthy
        port = tls_server(self, crt, key)
        r = self.poll("tls localhost:%d" % port)
        self.assertIn("certificate not trusted", r.stderr)
        items = self.open_items()
        self.assertEqual(set(items), {"work:expiry:tls:localhost:%d" % port})
        card = items["work:expiry:tls:localhost:%d" % port]
        self.assertEqual(card["priority"], "urgent")
        self.assertTrue(card["title"].startswith("TLS certificate for localhost:%d not trusted" % port), card["title"])
        self.assertNotIn(day(300), card["title"])
        # verify=no (a private CA): the date again, and far away, so the card resolves
        self.poll("tls localhost:%d verify=no" % port)
        self.assertEqual(self.open_items(), {})

    def test_rdap_over_https_verifies_the_certificate(self):
        """The RDAP fetch uses the default verifying context: a self-signed RDAP server is
        an error, never read."""
        crt, key = make_cert(self.tmp, 30)
        port = tls_server(self, crt, key)
        cfg = poller.Config()
        cfg.timeout = 3
        with self.assertRaises(poller.CheckError):
            poller.fetch_json(cfg, "https://localhost:%d/dns.json" % port, "application/json")

    def test_der_parse_matches_openssl(self):
        crt, _ = make_cert(self.tmp, 12)
        with open(crt) as fh:
            der = ssl.PEM_cert_to_DER_cert(fh.read())
        out = subprocess.run([OPENSSL, "x509", "-noout", "-enddate", "-in", crt], capture_output=True,
                             text=True, check=True).stdout.strip().split("=", 1)[1]
        want = calendar.timegm(time.strptime(out.replace(" GMT", ""), "%b %d %H:%M:%S %Y"))
        self.assertEqual(poller.cert_not_after(der), want)


class ExpiryInProcess(HubTestCase):
    """main() in this process, so a check (or the whole run) can be made to raise."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.conf = os.path.join(self.home, ".config", "needs-you", "expiry.conf")
        os.makedirs(os.path.dirname(self.conf))
        self.state = os.path.join(self.home, "state.json")
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        env = {"HOME": self.home, "NEEDS_YOU_TIMEOUT": "1", "NEEDS_YOU_HOST": "devbox",
               "NEEDS_YOU_URL": self.hub.url, "NEEDS_YOU_TOKEN": self.sender, "NEEDS_YOU_BIN": CLI,
               "NEEDS_YOU_EXPIRY_CONFIG": self.conf, "NEEDS_YOU_CONFIG": os.path.join(self.home, "env"),
               "NEEDS_YOU_EXPIRY_FAILS": "1"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for k in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "NEEDS_YOU_OUTBOX"):
            os.environ.pop(k, None)
        with open(self.conf, "w") as fh:
            fh.write('tls a.example.com\ntls b.example.com\nkey "A" %s\n' % day(5))

    def run_main(self):
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            self.assertEqual(poller.main(["--state", self.state]), 0)
        return stderr.getvalue()

    def open_items(self):
        items = request("GET", self.hub.url + "/v1/items?status=open", self.reader)[1]["items"]
        return {i["key"]: i for i in items}

    def test_a_bug_in_one_check_does_not_stop_the_others(self):
        calls = []

        def flaky(cfg, t):
            calls.append(t["host"])
            if t["host"] == "a.example.com":
                raise ZeroDivisionError("boom")
            return time.time() + 3 * 86400

        with mock.patch.object(poller, "check_tls", flaky):
            err = self.run_main()
        self.assertEqual(calls, ["a.example.com", "b.example.com"])
        self.assertIn("unexpected ZeroDivisionError", err)
        items = self.open_items()
        self.assertEqual(set(items), {"work:expiry:tls:b.example.com", "work:expiry:key:A",
                                      "work:expiry:devbox:checks-failing"})
        self.assertIn("a.example.com", items["work:expiry:devbox:checks-failing"]["body"])

    def test_a_bug_in_the_run_posts_the_poller_failing_card(self):
        with mock.patch.object(poller, "run_once", side_effect=KeyError("x")):
            err = self.run_main()
            self.run_main()  # posted once, not again
        self.assertIn("unexpected error: KeyError", err)
        key = "work:expiry:devbox:poller-failing"
        items = self.open_items()
        self.assertEqual(set(items), {key})
        self.assertEqual(items[key]["priority"], "low")
        # The next good run resolves it.
        with mock.patch.object(poller, "check_tls", lambda cfg, t: time.time() + 300 * 86400):
            self.run_main()
        self.assertNotIn(key, self.open_items())
        self.assertIn("work:expiry:key:A", self.open_items())

    def test_garbage_state_does_not_crash(self):
        with open(self.state, "w") as fh:
            json.dump({"posted": {"x": "y"}, "things": {"tls:a.example.com": {"fails": "many", "when": "soon"}}}, fh)
        with mock.patch.object(poller, "check_tls", side_effect=poller.CheckError("timed out")):
            err = self.run_main()
        self.assertNotIn("unexpected error", err)
        self.assertIn("work:expiry:devbox:checks-failing", self.open_items())


class ExpiryUnits(HubTestCase):
    def test_link_grammar_matches_the_hub(self):
        self.assertEqual(poller.LINK_RAW_PATTERN, hubmod.LINK_RAW_PATTERN)
        self.assertEqual(poller.HTTPS_HOST_PATTERN, hubmod.HTTPS_HOST_PATTERN)

    def test_thresholds(self):
        self.assertEqual(poller.parse_thresholds("30=low,7=normal,1=urgent"),
                         [(1.0, "urgent"), (7.0, "normal"), (30.0, "low")])
        self.assertEqual(poller.parse_thresholds("garbage"), poller.parse_thresholds(poller.DEFAULT_DAYS))
        self.assertEqual(poller.parse_thresholds("14=NORMAL,x=low,0=urgent"), [(14.0, "normal")])

    def test_rdap_dates_and_bootstrap_match(self):
        self.assertEqual(poller.parse_rdap_date("2027-08-13T04:00:00Z"),
                         calendar.timegm((2027, 8, 13, 4, 0, 0)))
        self.assertEqual(poller.parse_rdap_date("2027-08-13T04:00:00.123+02:00"),
                         calendar.timegm((2027, 8, 13, 2, 0, 0)))
        boot = {"services": [[["uk"], ["https://uk.example/"]], [["co.uk"], ["https://co.example/"]],
                             [["com"], ["http://x.example/", "https://com.example/"]]]}
        self.assertEqual(poller.rdap_base(boot, "acme.co.uk"), "https://co.example/")
        self.assertEqual(poller.rdap_base(boot, "acme.uk"), "https://uk.example/")
        self.assertEqual(poller.rdap_base(boot, "example.com"), "https://com.example/")
        self.assertEqual(poller.rdap_base(boot, "example.org"), "")

    def test_parse_lines(self):
        things, errors = poller.parse_list_text("\n".join([
            "# comment", "", "tls example.com", "tls mail.example.com:993  # trailing comment",
            "TLS example.com", "domain Example.COM.", 'key "Figma PAT" 2026-12-31 context=personal',
            "tls example.com:99999", "key nodate", "key x 2026-02-30", "domain localhost",
            "tls example.com verify=maybe", 'key "unclosed 2026-01-01', "ftp example.com"]))
        self.assertEqual([t["id"] for t in things],
                         ["tls:example.com", "tls:mail.example.com:993", "domain:example.com", "key:Figma PAT"])
        self.assertEqual(things[3]["context"], "personal")
        self.assertEqual([e["name"] for e in errors],
                         ["line 8", "line 9", "line 10", "line 11", "line 12", "line 13", "line 14"])
