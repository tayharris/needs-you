"""`needs-you orca usage`: usage meters for every Orca-managed Claude/Codex account, from
`orca account list --json` (a fake `orca` on PATH serving fixtures), sent as `usage` status
records (ADR 0011) to a test hub. Temporary HOME; never the real Orca, crontab or ~/.claude."""
from __future__ import annotations

import hashlib
import json
import os
import sys
import textwrap
import time

from support import request
from test_cli import CliTestCase

FAKE_ORCA = textwrap.dedent('''\
    #!%s
    import json, os, sys, time
    d = os.environ["FAKE_ORCA_DIR"]
    with open(os.path.join(d, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(sys.argv[1:]) + "\\n")
    mode = open(os.path.join(d, "mode")).read().strip() if os.path.exists(os.path.join(d, "mode")) else ""
    if mode == "sleep":
        time.sleep(30)
    if mode == "fail":
        sys.stderr.write("Orca is not running\\n")
        sys.exit(1)
    with open(os.path.join(d, "account-list.json")) as fh:
        sys.stdout.write(fh.read())
''') % sys.executable

EMAILS = ("alice@example.com", "bob@example.com", "carol@example.com", "dave@example.com", "erin@example.com")


def label(account_id):
    return "orca-" + hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:8]


def window(pct, resets_in=None, minutes=300, now=None):
    now = time.time() if now is None else now
    return {"usedPercent": pct, "windowMinutes": minutes,
            "resetsAt": None if resets_in is None else int((now + resets_in) * 1000),
            "resetDescription": "soon"}


def provider(name, session, weekly, status="ok", age=60, **extra):
    d = {"provider": name, "session": session, "weekly": weekly,
         "updatedAt": int((time.time() - age) * 1000), "status": status}
    d.update(extra)
    return d


def account_list(claude_active=None, claude_ids=(), codex_active=None, codex_ids=(), rate_limits=None):
    def accounts(ids):
        return [{"id": i, "email": EMAILS[n % len(EMAILS)], "managedAuthPath": "/home/u/.orca/" + i,
                 "organizationName": "Acme Corp", "workspaceLabel": "Team Acme"} for n, i in enumerate(ids)]
    rl = {"claude": None, "codex": None, "gemini": None, "kimi": None, "grok": None,
          "claudeTarget": {"runtime": "host", "wslDistro": None},
          "codexTarget": {"runtime": "host", "wslDistro": None},
          "inactiveClaudeAccounts": [], "inactiveCodexAccounts": []}
    rl.update(rate_limits or {})
    return {"id": "req-1", "ok": True, "result": {
        "claude": {"accounts": accounts(claude_ids), "activeAccountId": claude_active,
                   "activeAccountIdsByRuntime": {"host": claude_active, "wsl": {}}},
        "codex": {"accounts": accounts(codex_ids), "activeAccountId": codex_active,
                  "activeAccountIdsByRuntime": {"host": codex_active, "wsl": {}},
                  "systemDefault": {"hasAuth": True, "authKind": "oauth", "email": "frank@example.com",
                                    "providerAccountId": "9206b6fb-0000-4674-bc77-27a160677802",
                                    "workspaceLabel": "Team Acme"}},
        "rateLimits": rl}, "_meta": {"runtimeId": "rt-1"}}


A = "3f0c9b1e-2a7d-4c58-b6e1-f0a9d2c4b7e1"
B = "7e2d4f10-9a3b-4d6e-8c21-5b0a1f2e3d4c"
C = "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"
D = "c0ffee00-1111-4222-8333-444455556666"


class OrcaUsage(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        self.odir = os.path.join(self.tmp, "orca")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.odir)
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "orca"), "w") as fh:
            fh.write(FAKE_ORCA)
        os.chmod(os.path.join(self.bin, "orca"), 0o755)

    def write(self, data):
        with open(os.path.join(self.odir, "account-list.json"), "w") as fh:
            fh.write(data if isinstance(data, str) else json.dumps(data))

    def mode(self, m):
        with open(os.path.join(self.odir, "mode"), "w") as fh:
            fh.write(m)

    def env(self, **extra):
        env = {"PATH": self.bin + ":/usr/bin:/bin", "FAKE_ORCA_DIR": self.odir}
        env.update(extra)
        return env

    def usage(self, *args, **extra):
        return self.run_cli("orca", "usage", *args, urls=[self.hub.url], token=self.sender,
                            extra_env=self.env(**extra))

    def calls(self):
        try:
            with open(os.path.join(self.odir, "calls.jsonl")) as fh:
                return [json.loads(line) for line in fh]
        except OSError:
            return []

    def statuses(self):
        return request("GET", self.hub.url + "/v1/status", self.reader)[1]["statuses"]

    def by_key(self):
        return {s["key"]: s for s in self.statuses()}

    def meter_state(self, provider_name, sent, account=""):
        d = os.path.join(self.home, ".local", "state", "needs-you", "usage")
        os.makedirs(d, exist_ok=True)
        name = "%s%s.meter.json" % (provider_name, "-" + account if account else "")
        with open(os.path.join(d, name), "w") as fh:
            json.dump({"sent": sent, "sig": "x"}, fh)

    def assertNoLeak(self, text):
        for s in EMAILS + ("frank@example.com", "Acme Corp", "Team Acme", "@", "/home/u/.orca",
                           A, B, C, D, "9206b6fb"):
            self.assertNotIn(s, text)

    # -- the records ---------------------------------------------------------------------

    def test_every_account_with_exact_records(self):
        now = time.time()
        self.write(account_list(
            claude_active=A, claude_ids=(A, B, C), codex_active=None, codex_ids=(D,),
            rate_limits={
                "claude": provider("claude", window(51, 3600, now=now), window(41.25, 5 * 86400, 10080, now=now),
                                   planType="max"),
                "codex": provider("codex", window(12, 7200, now=now), None),
                "gemini": provider("gemini", window(99, 3600, now=now), None),
                "kimi": {"weird": True},
                "inactiveClaudeAccounts": [
                    {"accountId": B, "rateLimits": provider("claude", window(7, 1800, now=now), None),
                     "updatedAt": int(now * 1000), "isFetching": False},
                    {"accountId": C, "rateLimits": provider("claude", window(80, 1800, now=now), None,
                                                            status="error", error="token expired"),
                     "updatedAt": int(now * 1000), "isFetching": False}],
                "inactiveCodexAccounts": [
                    {"accountId": D, "rateLimits": provider("codex", None, window(33, 3 * 86400, 10080, now=now)),
                     "updatedAt": int(now * 1000), "isFetching": True}],
                "inactiveGeminiAccounts": [{"accountId": "g1", "rateLimits": provider("gemini", window(5), None)}],
            }))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), [["account", "list", "--json"]])
        got = self.by_key()
        # A is active on the host: Orca copied its login into ~/.claude, where needs-you-usage
        # sees it, so it goes under the local producers' key (one row for it, not two).
        self.assertEqual(sorted(got), sorted(["usage:claude", "usage:claude:" + label(B),
                                              "usage:codex", "usage:codex:" + label(D)]))
        a = got["usage:claude"]
        self.assertEqual((a["type"], a["label"], a["detail"]), ("usage", "Claude", ""))
        self.assertEqual(a["source"], {"host": "testbox", "agent": "orca"})
        self.assertEqual(a["usage"]["provider"], "claude")
        self.assertEqual(a["usage"]["account"], "")
        self.assertEqual([(w["name"], w["used_pct"]) for w in a["usage"]["windows"]], [("5h", 51), ("7d", 41.2)])
        resets = [w["resets_at"] for w in a["usage"]["windows"]]
        self.assertTrue(all(resets))
        self.assertEqual(a["expires_at"][:19], resets[1][:19])  # the latest reset
        b = got["usage:claude:" + label(B)]
        self.assertEqual([(w["name"], w["used_pct"]) for w in b["usage"]["windows"]], [("5h", 7)])
        # The system default (no managed id) goes under the local producers' key, account "".
        cx = got["usage:codex"]
        self.assertEqual((cx["usage"]["provider"], cx["usage"]["account"], cx["label"]), ("codex", "", "Codex"))
        self.assertEqual([(w["name"], w["used_pct"]) for w in cx["usage"]["windows"]], [("5h", 12)])
        d = got["usage:codex:" + label(D)]
        self.assertEqual([(w["name"], w["used_pct"]) for w in d["usage"]["windows"]], [("7d", 33)])
        self.assertNoLeak(json.dumps(self.statuses()))
        self.assertNoLeak(r.stdout + r.stderr)
        self.assertIn("error", r.stdout)  # C was skipped and said so
        _, items = request("GET", self.hub.url + "/v1/items", self.reader)
        self.assertEqual(items["items"], [])  # meters, never cards
        self.assertEqual(self.queued(), [])  # and never queued

    def test_the_shape_orca_reports_on_a_mac_with_two_claude_accounts(self):
        # As seen on a Mac (values made up): activeAccountId stays null with two managed
        # accounts, the active one is rateLimits.claude, the other is an inactive entry. Extra
        # windows (fableWeekly, monthly, buckets) and providers (cursor, opencode, devin) are ignored.
        now = time.time()
        data = account_list(claude_active=None, claude_ids=(A, B), rate_limits={
            "claude": provider("claude", window(23, 3600, now=now), window(61, 4 * 86400, 10080, now=now),
                               fableWeekly=window(88, 4 * 86400, 10080, now=now), extraUsage=None, error=None,
                               usageMetadata={"source": "api"}),
            "codex": provider("codex", None, None, status="error", error="not logged in"),
            "opencodeGo": provider("opencode-go", None, None, status="unavailable"),
            "zcode": provider("zcode", None, None, status="unavailable"),
            "cursor": provider("cursor", None, None, planType="pro",
                               monthly=window(40, 20 * 86400, 44640, now=now),
                               buckets=[dict(window(10, 20 * 86400, 44640, now=now), name="auto")]),
            "zcodePlanApiKeyConfigured": False, "opencodeGoApiKeyConfigured": False, "cursorAuthConfigured": True,
            "inactiveClaudeAccounts": [{"accountId": B, "rateLimits": provider("claude", window(4, 3600, now=now),
                                                                              window(17, 86400, 10080, now=now)),
                                        "updatedAt": int(now * 1000), "isFetching": False}]})
        for a in data["result"]["claude"]["accounts"]:
            a.update({"managedAuthRuntime": "host", "wslDistro": None, "authMethod": "subscription-oauth",
                      "organizationUuid": "0f0f0f0f-aaaa-4bbb-8ccc-dddddddddddd", "createdAt": 1, "updatedAt": 2,
                      "lastAuthenticatedAt": 3})
        data["result"]["opencode"] = {"accounts": [], "activeAccountId": None}
        data["result"]["devin"] = {"accounts": [], "activeAccountId": None}
        self.write(data)
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        got = self.by_key()
        self.assertEqual(sorted(got), ["usage:claude", "usage:claude:" + label(B)])
        self.assertEqual([(w["name"], w["used_pct"]) for w in got["usage:claude"]["usage"]["windows"]],
                         [("5h", 23), ("7d", 61)])
        self.assertEqual(got["usage:claude"]["usage"]["account"], "")
        self.assertEqual([(w["name"], w["used_pct"]) for w in got["usage:claude:" + label(B)]["usage"]["windows"]],
                         [("5h", 4), ("7d", 17)])
        self.assertNoLeak(json.dumps(self.statuses()) + r.stdout + r.stderr)
        self.assertNotIn("0f0f0f0f", json.dumps(self.statuses()))

    def test_windows_are_cleaned(self):
        now = time.time()
        e = "e0e0e0e0-1111-4222-8333-444455556666"
        self.write(account_list(claude_active=A, claude_ids=(A, B, C, e), rate_limits={
            "claude": provider("claude", window(140, 3600, now=now), window(-3, None, 10080, now=now)),
            "inactiveClaudeAccounts": [
                {"accountId": B, "rateLimits": provider("claude", window("12", 3600), window(True, 3600))},
                {"accountId": C, "rateLimits": provider("claude", window(64, -60, now=now),
                                                        window(float("inf"), 3600))},
                {"accountId": e, "rateLimits": provider("claude", window(float("nan"), 3600), None)},
                {"accountId": 7, "rateLimits": provider("claude", window(1, 3600), None)},
                {"accountId": "", "rateLimits": provider("claude", window(1, 3600), None)},
                "junk"],
        }))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        got = self.by_key()
        self.assertEqual(sorted(got), sorted(["usage:claude", "usage:claude:" + label(C)]))
        a = got["usage:claude"]["usage"]["windows"]
        self.assertEqual([(w["name"], w["used_pct"]) for w in a], [("5h", 100), ("7d", 0)])
        self.assertIsNone(a[1]["resets_at"])
        c = got["usage:claude:" + label(C)]["usage"]["windows"]
        self.assertEqual([(w["name"], w["used_pct"], w["resets_at"]) for w in c], [("5h", 0, None)])  # reset since

    def test_stale_and_unknown_status_are_skipped(self):
        self.write(account_list(claude_active=A, claude_ids=(A, B, C), rate_limits={
            "claude": provider("claude", window(50, 3600), None, age=13 * 3600),
            "inactiveClaudeAccounts": [
                {"accountId": B, "rateLimits": provider("claude", window(5, 3600), None, status="unavailable")},
                {"accountId": C, "rateLimits": provider("claude", window(6, 3600), None, status="fetching")}],
        }))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(self.by_key()), ["usage:claude:" + label(C)])  # fetching keeps the last numbers

    def test_a_live_local_producer_keeps_the_default_account(self):
        now = time.time()
        self.write(account_list(rate_limits={"claude": provider("claude", window(20, 3600), None),
                                             "codex": provider("codex", window(30, 3600), None)}))
        self.meter_state("claude", now - 60)          # needs-you-usage sent a minute ago: it wins
        self.meter_state("codex", now - 3600)         # the Codex hook last sent an hour ago: not live
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(self.by_key()), ["usage:codex"])
        self.assertIn("local", r.stdout)

    def test_the_active_claude_account_is_the_one_in_the_home_directory(self):
        # On the host Orca copies the chosen Claude login into ~/.claude, so needs-you-usage
        # reports it under usage:claude: so does this command, and its own row goes.
        self.write(account_list(claude_active=None, claude_ids=(A, B), rate_limits={
            "claude": provider("claude", window(20, 3600), None),
            "inactiveClaudeAccounts": [{"accountId": A, "rateLimits": provider("claude", window(5, 3600), None)}]}))
        self.assertEqual(self.usage().returncode, 0)
        self.assertEqual(sorted(self.by_key()), ["usage:claude", "usage:claude:" + label(A)])
        self.write(account_list(claude_active=A, claude_ids=(A, B), rate_limits={
            "claude": provider("claude", window(6, 3600), None),
            "inactiveClaudeAccounts": [{"accountId": B, "rateLimits": provider("claude", window(9, 3600), None)}]}))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)  # usage:claude again inside 10 s is a 429: still 0
        self.assertEqual(sorted(self.by_key()), ["usage:claude", "usage:claude:" + label(B)])

    def test_a_wsl_claude_account_keeps_its_label(self):
        # In WSL Orca gives the account its own CLAUDE_CONFIG_DIR, which needs-you-usage labels.
        self.write(account_list(claude_ids=(A,), rate_limits={
            "claude": provider("claude", window(20, 3600), None),
            "claudeTarget": {"runtime": "wsl", "wslDistro": "Ubuntu"}}))
        data = json.loads(open(os.path.join(self.odir, "account-list.json")).read())
        data["result"]["claude"]["activeAccountIdsByRuntime"] = {"host": None, "wsl": {"Ubuntu": A}}
        self.write(data)
        self.assertEqual(self.usage().returncode, 0)
        self.assertEqual(sorted(self.by_key()), ["usage:claude:" + label(A)])

    def test_a_live_producer_in_an_orca_terminal_keeps_its_managed_account(self):
        # The Codex hook in an Orca terminal (CODEX_HOME in codex-accounts/<id>/home) sends the
        # same key with fresher numbers: this command leaves it alone, and never clears it.
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        self.assertEqual(self.usage().returncode, 0)
        self.assertEqual(sorted(self.by_key()), ["usage:codex:" + label(A)])
        self.meter_state("codex", time.time() - 60, account=label(A))
        r = self.usage("--dry-run")
        self.assertEqual(json.loads(r.stdout)["records"], [])
        self.assertIn({"key": "usage:codex:" + label(A), "reason": "a local producer reports it"},
                      json.loads(r.stdout)["skipped"])
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(sorted(self.by_key()), ["usage:codex:" + label(A)])  # still there

    def test_the_default_account_takes_the_local_account_label(self):
        self.write(account_list(rate_limits={"claude": provider("claude", window(20, 3600), None)}))
        r = self.usage(NEEDS_YOU_USAGE_ACCOUNT="work-1")
        self.assertEqual(r.returncode, 0, r.stderr)
        st = self.by_key()["usage:claude:work-1"]
        self.assertEqual(st["usage"]["account"], "work-1")

    def test_at_most_twelve_accounts(self):
        ids = ["acct-%02d" % i for i in range(20)]
        self.write(account_list(claude_active=ids[0], claude_ids=ids, rate_limits={
            "claude": provider("claude", window(1, 3600), None),
            "inactiveClaudeAccounts": [{"accountId": i, "rateLimits": provider("claude", window(2, 3600), None)}
                                       for i in ids[1:]]}))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.statuses()), 12)

    def test_accounts_gone_from_orca_are_cleared_but_never_the_default(self):
        self.write(account_list(claude_active=A, claude_ids=(A, B), rate_limits={
            "claude": provider("claude", window(10, 3600), None),
            "codex": provider("codex", window(30, 3600), None),
            "inactiveClaudeAccounts": [{"accountId": B, "rateLimits": provider("claude", window(5, 3600), None)}]}))
        self.assertEqual(self.usage().returncode, 0)
        self.assertEqual(len(self.statuses()), 3)
        # Orca not running: nothing changes.
        self.mode("fail")
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Orca is not running", r.stderr)
        self.assertEqual(len(self.statuses()), 3)
        # B removed in Orca, and no codex numbers this time: B is cleared, usage:codex stays.
        self.mode("")
        self.write(account_list(claude_active=A, claude_ids=(A,), rate_limits={
            "claude": provider("claude", window(10, 3600), None)}))
        r = self.usage()
        self.assertEqual(r.returncode, 0, r.stderr)  # A's rewrite inside 10 s is a 429: still 0
        self.assertEqual(sorted(self.by_key()), sorted(["usage:claude", "usage:codex"]))

    def test_dry_run_sends_nothing(self):
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        r = self.usage("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual([x["key"] for x in out["records"]], ["usage:codex:" + label(A)])
        self.assertEqual(out["records"][0]["body"]["usage"]["account"], label(A))
        self.assertNoLeak(r.stdout)
        self.assertEqual(self.statuses(), [])

    def test_json_summary(self):
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        r = self.usage("--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual((out["ok"], out["sent"], out["cleared"]), (True, ["usage:codex:" + label(A)], []))

    # -- failures never fail the caller ------------------------------------------------------

    def test_bad_orca_output(self):
        for raw in ("not json", "[]", '{"ok": false, "error": {"message": "boom"}}', '{"ok": true, "result": []}',
                    '{"ok": true, "result": {"claude": 5, "codex": [], "rateLimits": "x"}}',
                    json.dumps({"ok": True, "result": {"rateLimits": {"claude": {"status": "ok", "session": "x"},
                                                                      "inactiveClaudeAccounts": {"a": 1}}}})):
            with self.subTest(raw=raw[:40]):
                self.write(raw)
                r = self.usage()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn("Traceback", r.stderr)
                self.assertEqual(self.statuses(), [])

    def test_timeout(self):
        self.mode("sleep")
        start = time.time()
        r = self.usage(NEEDS_YOU_ORCA_TIMEOUT="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(time.time() - start, 20)
        self.assertIn("timed out", r.stderr)

    def test_no_orca(self):
        r = self.run_cli("orca", "usage", urls=[self.hub.url], token=self.sender,
                         extra_env={"PATH": "/usr/bin:/bin", "NEEDS_YOU_ORCA_BIN": os.path.join(self.tmp, "nope")})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("orca", r.stderr)

    def test_no_hub_configured(self):
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        r = self.run_cli("orca", "usage", urls=[self.dead], token=self.sender, extra_env=self.env())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.queued(), [])

    def test_usage_flags_need_usage(self):
        r = self.run_cli("orca", "--dry-run", extra_env=self.env())
        self.assertEqual(r.returncode, 2)

    # -- from the 5-minute flush -------------------------------------------------------------

    def env_file(self, text):
        d = os.path.join(self.home, ".config", "needs-you")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "env"), "w") as fh:
            fh.write(text)

    def flush(self, **extra):
        return self.run_cli("-q", "flush", urls=[self.hub.url], token=self.sender, extra_env=self.env(**extra))

    def test_flush_runs_it_only_when_on_and_at_most_every_few_minutes(self):
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        r = self.flush()
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertEqual(self.calls(), [])  # off by default
        self.env_file("NEEDS_YOU_ORCA_USAGE=1\n")
        r = self.flush()
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertEqual(self.calls(), [["account", "list", "--json"]])
        self.assertEqual(sorted(self.by_key()), ["usage:codex:" + label(A)])
        r = self.flush()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.calls()), 1)  # too soon: not again

    def test_flush_stays_quiet_when_orca_breaks(self):
        self.env_file("NEEDS_YOU_ORCA_USAGE=1\n")
        self.write("garbage")
        r = self.flush()
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.mode("sleep")
        state = os.path.join(self.home, ".local", "state", "needs-you", "orca-usage.json")
        os.remove(state)
        r = self.flush(NEEDS_YOU_ORCA_TIMEOUT="1")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        r = self.run_cli("-q", "flush", urls=[self.hub.url], token=self.sender,
                         extra_env={"PATH": "/usr/bin:/bin", "NEEDS_YOU_ORCA_BIN": os.path.join(self.tmp, "nope")})
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_enable_and_disable(self):
        self.write(account_list(codex_active=A, codex_ids=(A,), rate_limits={
            "codex": provider("codex", window(10, 3600), None)}))
        r = self.usage("--enable")
        self.assertEqual(r.returncode, 0, r.stderr)
        env_path = os.path.join(self.home, ".config", "needs-you", "env")
        with open(env_path) as fh:
            self.assertIn("NEEDS_YOU_ORCA_USAGE=1", fh.read())
        self.assertEqual(sorted(self.by_key()), ["usage:codex:" + label(A)])  # and ran once
        r = self.usage("--disable")
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(env_path) as fh:
            self.assertIn("NEEDS_YOU_ORCA_USAGE=0", fh.read())
        self.assertEqual(self.statuses(), [])  # its records are cleared


if __name__ == "__main__":
    import unittest
    unittest.main()
