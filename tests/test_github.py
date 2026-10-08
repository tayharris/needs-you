"""integrations/github/needs-you-github against a real local hub, with a fake `gh` that
serves fixture JSON (tests/fixtures/github). Covers every reason, dedupe, resolve when a
condition clears, If-Modified-Since / 304, config, and gh missing or failing."""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import textwrap

from support import CLI, ROOT, free_port, request
from support import HubTestCase

POLLER = os.path.join(ROOT, "integrations", "github", "needs-you-github")
FIXTURES = os.path.join(ROOT, "tests", "fixtures", "github")

FAKE_GH = textwrap.dedent('''\
    #!%s
    """Fake gh: serves $FAKE_GH_DIR fixtures and logs each argv to calls.jsonl."""
    import json, os, sys
    d = os.environ["FAKE_GH_DIR"]
    args = sys.argv[1:]
    with open(os.path.join(d, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps(args) + "\\n")
    if os.path.exists(os.path.join(d, "fail")):
        sys.stderr.write("gh: Bad credentials (HTTP 401)\\n")
        sys.exit(1)
    def read(name):
        with open(os.path.join(d, name)) as fh:
            return fh.read()
    if args[:2] == ["api", "graphql"] and any("pullRequest(number:" in a for a in args):
        # The merged lookup: answer each alias pN from pr_states.json ({"owner/repo#N": {...}};
        # a PR not listed is still open, null is one GitHub doesn't show us).
        if os.path.exists(os.path.join(d, "lookup_fail")):
            sys.stderr.write("gh: HTTP 502\\n")
            sys.exit(1)
        states = json.loads(read("pr_states.json")) if os.path.exists(os.path.join(d, "pr_states.json")) else {}
        v = {}
        for flag, kv in zip(args, args[1:]):
            if flag in ("-f", "-F") and not kv.startswith("query="):
                k, _, val = kv.partition("=")
                v[k] = val
        data = {}
        i = 0
        while "o%%d" %% i in v:
            ref = "%%s/%%s#%%s" %% (v["o%%d" %% i], v["n%%d" %% i], v["r%%d" %% i])
            st = states.get(ref, {"merged": False, "state": "OPEN", "title": "x", "url": ""})
            data["p%%d" %% i] = None if st is None else {"pullRequest": st}
            i += 1
        sys.stdout.write(json.dumps({"data": data}))
        sys.exit(1 if None in data.values() else 0)
    if args[:2] == ["api", "graphql"]:
        sys.stdout.write(read("prs.json"))
        sys.exit(0)
    if args[:1] == ["api"] and any(a.startswith("/notifications") for a in args):
        status = read("notif_status").strip() if os.path.exists(os.path.join(d, "notif_status")) else "200"
        if status == "304":
            sys.stdout.write("HTTP/2.0 304 Not Modified\\r\\nX-Poll-Interval: 60\\r\\n\\r\\n")
            sys.stderr.write("gh: HTTP 304\\n")
            sys.exit(1)
        sys.stdout.write("HTTP/2.0 200 OK\\r\\nLast-Modified: Wed, 07 Oct 2026 09:10:00 GMT\\r\\n"
                         "X-Poll-Interval: 60\\r\\n\\r\\n" + read("notifications.json"))
        sys.exit(0)
    sys.stderr.write("fake gh: unexpected %%r\\n" %% (args,))
    sys.exit(2)
''') % sys.executable


class GithubPoller(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.ghdir = os.path.join(self.tmp, "gh")
        os.makedirs(self.ghdir)
        self.gh = os.path.join(self.ghdir, "gh")
        with open(self.gh, "w") as fh:
            fh.write(FAKE_GH)
        os.chmod(self.gh, 0o755)
        for name in ("notifications.json", "prs.json"):
            shutil.copy(os.path.join(FIXTURES, name), os.path.join(self.ghdir, name))
        self.state = os.path.join(self.home, ".local", "state", "needs-you", "github.json")
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)
        self.urls = [self.hub.url]

    def poll(self, extra=None, *args):
        env = {"HOME": self.home, "PATH": os.environ.get("PATH", ""), "NEEDS_YOU_TIMEOUT": "1",
               "NEEDS_YOU_HOST": "devbox", "NEEDS_YOU_URL": ",".join(self.urls), "NEEDS_YOU_TOKEN": self.sender,
               "NEEDS_YOU_BIN": CLI, "NEEDS_YOU_GITHUB_GH": self.gh, "FAKE_GH_DIR": self.ghdir,
               "NEEDS_YOU_GITHUB_CONTEXTS": "example-user=personal"}
        env.update(extra or {})
        r = subprocess.run([sys.executable, POLLER] + list(args), env=env, capture_output=True, text=True,
                           timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def open_items(self):
        items = request("GET", self.hub.url + "/v1/items?status=open", self.reader)[1]["items"]
        return {i["key"]: i for i in items}

    def all_items(self):
        return request("GET", self.hub.url + "/v1/items?status=all", self.reader)[1]["items"]

    def edit(self, name, fn):
        path = os.path.join(self.ghdir, name)
        with open(path) as fh:
            data = json.load(fh)
        data = fn(data) or data
        with open(path, "w") as fh:
            json.dump(data, fh)

    def calls(self):
        try:
            with open(os.path.join(self.ghdir, "calls.jsonl")) as fh:
                return [json.loads(line) for line in fh]
        except OSError:
            return []

    def force_notification_poll(self):
        with open(self.state) as fh:
            st = json.load(fh)
        st["notif_at"] = 0
        with open(self.state, "w") as fh:
            json.dump(st, fh)

    # ------------------------------------------------------------------

    def test_card_catalogue(self):
        self.poll()
        items = self.open_items()
        expect = {
            "work:gh:acme/app#12:review": ("Review acme/app#12: Add retry to the importer", "normal"),
            "work:gh:deploy:acme/app:9001": ("Approve the deploy: acme/app: Deploy to production", "urgent"),
            "work:gh:acme/app:ci:main": ("CI failed on main: acme/app: CI workflow run failed for main branch",
                                          "normal"),
            "work:gh:acme/web#7:mention": ("You were mentioned in acme/web#7: Broken layout on Safari", "low"),
            "personal:gh:example-user/dotfiles#3:review": ("Review example-user/dotfiles#3: Tidy zsh config", "normal"),
            "work:gh:acme/app#20:merge": ("Merge acme/app#20: Cache the session store", "normal"),
            "work:gh:acme/app#21:changes": ("Changes requested on acme/app#21: Rename the billing flag", "normal"),
            "work:gh:acme/app#22:conflict": ("Resolve conflicts in acme/app#22: Upgrade the ORM", "normal"),
            "work:gh:acme/app#23:checks": ("Fix failing checks on acme/app#23: Feature X", "normal"),
        }
        for key, (title, prio) in expect.items():
            with self.subTest(key=key):
                self.assertIn(key, items)
                self.assertEqual(items[key]["title"], title)
                self.assertEqual(items[key]["priority"], prio)
                self.assertEqual(items[key]["source"]["agent"], "github")
                self.assertIsNotNone(items[key]["expires_at"])
        # Not cards: subscribed, a draft, a review already given (not in the review search),
        # CI on my PR's branch (the checks card covers it), CI whose latest run succeeded.
        self.assertEqual(sorted(set(items) - set(expect)), ["work:gh:acme/web#8:assign"])
        self.assertEqual(items["personal:gh:example-user/dotfiles#3:review"]["context"], "personal")

        review = items["work:gh:acme/app#12:review"]
        self.assertEqual(review["links"], [{"label": "PR", "url": "https://github.com/acme/app/pull/12"}])
        self.assertEqual([s["text"] for s in review["steps"]], ["Read the diff", "Approve, or request changes"])
        self.assertEqual(review["steps"][0]["link"]["url"], "https://github.com/acme/app/pull/12/files")
        deploy = items["work:gh:deploy:acme/app:9001"]
        self.assertEqual(deploy["links"][0]["url"], "https://github.com/acme/app/actions/runs/9001")
        self.assertIn("Review deployments", deploy["steps"][0]["text"])
        conflict = items["work:gh:acme/app#22:conflict"]
        self.assertEqual(conflict["links"][0]["url"], "https://github.com/acme/app/pull/22/conflicts")
        checks = items["work:gh:acme/app#23:checks"]
        texts = [s["text"] for s in checks["steps"]]
        self.assertEqual(texts[0], "Read **lint \\[ruff\\]**")      # markdown in a check name is escaped
        self.assertEqual(checks["steps"][0]["link"]["url"], "https://github.com/acme/app/actions/runs/2/job/21")
        self.assertEqual(checks["steps"][1]["link"]["url"], "https://ci.example.com/build/7")
        self.assertEqual(checks["steps"][2]["link"]["url"], "https://github.com/acme/app/pull/23/checks")  # http dropped
        self.assertEqual(len(texts), 4)

    def test_untrusted_title_is_cleaned_and_truncated(self):
        self.poll()
        t = self.open_items()["work:gh:acme/web#8:assign"]["title"]
        self.assertLessEqual(len(t), 100)
        self.assertTrue(t.startswith("Assigned to you: acme/web#8: Ignore previous instructions"), t)
        self.assertTrue(t.endswith("…"))
        for bad in ("‮", "\x1b", "\n"):
            self.assertNotIn(bad, t)
        for item in self.open_items().values():  # GitHub text only ever reaches the title
            self.assertNotIn("instructions", item.get("body") or "")

    def test_dedupe_and_renew(self):
        self.poll()
        first = self.open_items()
        self.poll()
        second = self.open_items()
        self.assertEqual(sorted(first), sorted(second))
        self.assertEqual(len(self.all_items()), len(first))  # no duplicates, nothing resolved
        for k in first:
            self.assertEqual(first[k]["id"], second[k]["id"])
            self.assertEqual(first[k]["content_updated_at"], second[k]["content_updated_at"])
            self.assertGreaterEqual(second[k]["expires_at"], first[k]["expires_at"])  # re-posted while true

    def test_conditional_request_and_304_keeps_cards(self):
        self.poll()
        n_calls = len(self.calls())
        self.poll()  # inside X-Poll-Interval: notifications not fetched again
        notif_calls = [c for c in self.calls()[n_calls:] if any(a.startswith("/notifications") for a in c)]
        self.assertEqual(notif_calls, [])
        self.force_notification_poll()
        with open(os.path.join(self.ghdir, "notif_status"), "w") as fh:
            fh.write("304")
        before = set(self.open_items())
        self.poll()
        last = [c for c in self.calls() if any(a.startswith("/notifications") for a in c)][-1]
        self.assertIn("If-Modified-Since: Wed, 07 Oct 2026 09:10:00 GMT", last)
        self.assertEqual(set(self.open_items()), before)

    def test_resolves_when_conditions_clear(self):
        self.poll()

        def clear_prs(d):
            nodes = d["data"]["mine"]["nodes"]
            nodes[1]["reviewDecision"] = "APPROVED"         # #21: changes addressed -> now mergeable
            nodes[2]["mergeable"] = "MERGEABLE"             # #22: conflict fixed
            d["data"]["mine"]["nodes"] = [n for n in nodes if n["number"] != 23]  # #23 merged
            d["data"]["review"]["nodes"] = [n for n in d["data"]["review"]["nodes"] if n["number"] != 12]
        self.edit("prs.json", clear_prs)
        self.edit("notifications.json", lambda d: [t for t in d if t["id"] not in ("1002", "1007")])
        self.force_notification_poll()
        self.poll()
        items = self.open_items()
        for gone in ("work:gh:acme/app#21:changes", "work:gh:acme/app#22:conflict", "work:gh:acme/app#23:checks",
                     "work:gh:acme/app#12:review", "work:gh:deploy:acme/app:9001", "work:gh:acme/web#7:mention"):
            self.assertNotIn(gone, items)
        self.assertIn("work:gh:acme/app#21:merge", items)
        # #23's branch has no PR now, so the CI notification for feature-x becomes its own card.
        self.assertIn("work:gh:acme/app:ci:feature-x", items)
        resolved = {i["key"] for i in self.all_items() if i["status"] == "resolved"}
        self.assertIn("work:gh:acme/app#21:changes", resolved)
        with open(self.state) as fh:
            posted = json.load(fh)["posted"]
        self.assertNotIn("work:gh:acme/app#21:changes", posted)

    def lookups(self):
        return [c for c in self.calls() if any("pullRequest(number:" in a for a in c)]

    def pr_states(self, states):
        with open(os.path.join(self.ghdir, "pr_states.json"), "w") as fh:
            json.dump(states, fh)

    def drop_mine(self, numbers):
        def fn(d):
            d["data"]["mine"]["nodes"] = [n for n in d["data"]["mine"]["nodes"] if n["number"] not in numbers]
        self.edit("prs.json", fn)

    MERGED_20 = {"merged": True, "state": "MERGED", "title": "Cache the session store",
                 "url": "https://github.com/acme/app/pull/20"}

    def test_merged_pr_gets_one_done_card(self):
        self.poll()
        self.assertFalse([k for k in self.open_items() if k.endswith(":merged")])  # first run: nothing to compare
        self.assertEqual(self.lookups(), [])
        # #20 merged, #21 closed unmerged, #22 went quiet (still open), #24 (a draft) GitHub no longer shows.
        self.drop_mine({20, 21, 22, 24})
        self.pr_states({"acme/app#20": dict(self.MERGED_20, title="Cache the session store ‮!"),
                        "acme/app#21": {"merged": False, "state": "CLOSED", "title": "x", "url": ""},
                        "acme/app#24": None})
        self.poll()
        items = self.open_items()
        done = items["work:gh:acme/app#20:merged"]
        self.assertEqual(done["kind"], "done")
        self.assertEqual(done["priority"], "low")
        self.assertEqual(done["title"], "Merged acme/app#20: Cache the session store !")
        self.assertEqual(done["links"], [{"label": "PR", "url": "https://github.com/acme/app/pull/20"}])
        self.assertEqual(done["source"]["agent"], "github")
        self.assertIsNotNone(done["expires_at"])
        self.assertNotIn("work:gh:acme/app#20:merge", items)  # the "Merge" card resolved
        self.assertEqual([k for k in items if k.endswith(":merged")], ["work:gh:acme/app#20:merged"])
        with open(self.state) as fh:
            mine = json.load(fh)["mine"]
        self.assertEqual(sorted(mine), ["acme/app#22", "acme/app#23"])  # #22 still open: kept

        # Later runs neither re-post nor resolve it; #22 is looked up again (still within PR_DAYS).
        n = len(self.lookups())
        self.poll()
        self.poll()
        self.assertEqual(len([i for i in self.all_items() if i["key"] == "work:gh:acme/app#20:merged"]), 1)
        again = self.open_items()["work:gh:acme/app#20:merged"]
        self.assertEqual((again["id"], again["content_updated_at"]), (done["id"], done["content_updated_at"]))
        self.assertGreater(len(self.lookups()), n)

    def test_merged_pr_seen_open_long_ago_is_forgotten(self):
        self.poll()
        with open(self.state) as fh:
            st = json.load(fh)
        st["mine"]["acme/app#22"]["seen"] = 1.0  # last seen open in 1970
        with open(self.state, "w") as fh:
            json.dump(st, fh)
        self.drop_mine({22})
        self.poll()
        with open(self.state) as fh:
            self.assertNotIn("acme/app#22", json.load(fh)["mine"])

    def test_merged_lookup_failing_keeps_tracking(self):
        self.poll()
        self.drop_mine({20})
        open(os.path.join(self.ghdir, "lookup_fail"), "w").close()
        r = self.poll()
        self.assertIn("merged lookup", r.stderr)
        self.assertNotIn("work:gh:acme/app#20:merged", self.open_items())
        self.assertFalse([k for k in self.open_items() if k.endswith(":poller-failing")])
        os.remove(os.path.join(self.ghdir, "lookup_fail"))
        self.pr_states({"acme/app#20": self.MERGED_20})
        self.poll()
        self.assertIn("work:gh:acme/app#20:merged", self.open_items())

    def test_merged_can_be_turned_off(self):
        self.poll({"NEEDS_YOU_GITHUB_REASONS": "-merged"})
        self.drop_mine({20})
        self.pr_states({"acme/app#20": self.MERGED_20})
        self.poll({"NEEDS_YOU_GITHUB_REASONS": "-merged"})
        self.assertFalse([k for k in self.open_items() if k.endswith(":merged")])
        self.assertEqual(self.lookups(), [])
        with open(self.state) as fh:
            self.assertNotIn("mine", json.load(fh))

    def test_merged_respects_exclude(self):
        self.poll()
        self.drop_mine({20})
        self.pr_states({"acme/app#20": self.MERGED_20})
        self.poll({"NEEDS_YOU_GITHUB_EXCLUDE": "acme"})
        self.assertNotIn("work:gh:acme/app#20:merged", self.open_items())

    def test_merged_dry_run(self):
        self.poll()
        self.drop_mine({20})
        self.pr_states({"acme/app#20": self.MERGED_20})
        r = self.poll(None, "--dry-run")
        self.assertIn("done work:gh:acme/app#20:merged [low] Merged acme/app#20: Cache the session store", r.stdout)
        self.assertNotIn("work:gh:acme/app#20:merged", self.open_items())

    def test_gh_failing_exits_zero_without_spam_then_one_card(self):
        self.poll()
        before = self.open_items()
        open(os.path.join(self.ghdir, "fail"), "w").close()
        r = self.poll()
        self.assertIn("Bad credentials", r.stderr)
        self.assertNotIn(self.sender, r.stderr + r.stdout)
        self.assertEqual(set(self.open_items()), set(before))  # nothing resolved: we couldn't look
        self.poll()
        self.assertEqual(set(self.open_items()), set(before))
        for _ in range(3):
            self.force_notification_poll()
            self.poll()
        health = [k for k in self.open_items() if k.endswith(":poller-failing")]
        self.assertEqual(health, ["work:gh:devbox:poller-failing"])
        self.assertEqual(len([i for i in self.all_items() if i["key"] == health[0]]), 1)
        self.assertIsNone(self.open_items()[health[0]]["expires_at"])
        os.remove(os.path.join(self.ghdir, "fail"))
        self.force_notification_poll()
        self.poll()
        self.assertNotIn("work:gh:devbox:poller-failing", self.open_items())

    def test_gh_missing_exits_zero_and_posts_nothing(self):
        r = self.poll({"NEEDS_YOU_GITHUB_GH": os.path.join(self.tmp, "no-such-gh")})
        self.assertIn("gh", r.stderr)
        self.assertEqual(self.open_items(), {})

    def test_config_filters(self):
        self.poll({"NEEDS_YOU_GITHUB_EXCLUDE": "acme/web", "NEEDS_YOU_GITHUB_REASONS": "-merge,-conflict"})
        keys = set(self.open_items())
        self.assertFalse([k for k in keys if "acme/web" in k])
        self.assertNotIn("work:gh:acme/app#20:merge", keys)
        self.assertNotIn("work:gh:acme/app#22:conflict", keys)
        self.assertIn("work:gh:acme/app#21:changes", keys)

    def test_include_only_and_cap(self):
        self.poll({"NEEDS_YOU_GITHUB_INCLUDE": "example-user"})
        self.assertEqual(sorted(self.open_items()), ["personal:gh:example-user/dotfiles#3:review"])
        os.remove(self.state)
        self.poll({"NEEDS_YOU_GITHUB_MAX_CARDS": "2"})
        keys = sorted(self.open_items())
        self.assertIn("work:gh:deploy:acme/app:9001", keys)  # urgent goes first
        self.assertEqual(len(keys), 2)

    def test_state_file_is_private_and_holds_no_token(self):
        self.poll()
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o600)
        with open(self.state) as fh:
            self.assertNotIn(self.sender, fh.read())

    def test_hub_down_queues_and_exits_zero(self):
        self.urls = ["http://127.0.0.1:%d" % free_port()]
        self.poll()
        outbox = os.path.join(self.home, ".local", "state", "needs-you", "outbox")
        n = len([f for f in os.listdir(outbox) if f.endswith(".json")])
        self.assertGreater(n, 5)
        self.poll()  # unchanged cards aren't renewed while the outbox has a backlog
        self.assertEqual(len([f for f in os.listdir(outbox) if f.endswith(".json")]), n)

    def test_dry_run_changes_nothing(self):
        r = self.poll(None, "--dry-run")
        self.assertIn("post work:gh:acme/app#20:merge [normal] Merge acme/app#20", r.stdout)
        self.assertEqual(self.open_items(), {})
        self.assertFalse(os.path.exists(self.state))


if __name__ == "__main__":
    import unittest
    unittest.main()
