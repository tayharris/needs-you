"""Configuration, one place: docs/guides/configuration.md, the code, and the checks agree.

- Every NEEDS_YOU_* variable the code reads (cli/, hub/, integrations/, scripts/, deploy/) is
  on the page, and every one on the page is read somewhere; the CLI's SETTINGS table (what
  `needs-you doctor` knows) is the same list, with the same kind (env only, set by needs-you,
  a hub's, development) as the page's section or "*Env only*" mark.
- Every hub.json key the hub knows (CONFIG_KEYS) is in the page's hub.json table and the
  other way round, with the defaults load_config really uses; hub-update.json likewise.
- The pollers share one settings block, byte for byte.
- The checks themselves: the hub's load_config and --check-config, the CLI's and the pollers'
  warnings, and `needs-you doctor`'s settings, key files and hub config checks. None of them
  ever prints a value.
"""
from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

from support import CLI, ROOT, hubmod
from test_doctor import DoctorTestCase, load_cli

PAGE = os.path.join(ROOT, "docs", "guides", "configuration.md")
CODE_DIRS = ["cli", "hub", "integrations", "scripts", "deploy"]
ENV = re.compile(r"\bNEEDS_YOU_[A-Z0-9_]*[A-Z0-9]\b")
# Words in scripts/rollout.sh's remote output, not variables.
NOT_VARIABLES = {"NEEDS_YOU_MISSING", "NEEDS_YOU_SPLIT"}
SECTION_KIND = {"Set by needs-you itself": "internal", "Development and release": "dev",
                "Hub environment variables": "hub"}
POLLERS = ["integrations/github/needs-you-github", "integrations/linear/needs-you-linear",
           "integrations/jira/needs-you-jira", "integrations/expiry/needs-you-expiry"]
SECRET = "nyt_SECRETVALUE0123456789abcdef"
sys.path.insert(0, os.path.join(ROOT, "scripts"))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def code_vars():
    out = {}
    for d in CODE_DIRS:
        for dirpath, dirnames, files in os.walk(os.path.join(ROOT, d)):
            dirnames[:] = [x for x in dirnames if x not in ("__pycache__", "node_modules")]
            for f in files:
                if f.endswith((".md", ".pyc")):
                    continue
                p = os.path.join(dirpath, f)
                try:
                    text = read(p)
                except (OSError, UnicodeDecodeError):
                    continue
                for v in ENV.findall(text):
                    out.setdefault(v, os.path.relpath(p, ROOT))
    for v in NOT_VARIABLES:
        out.pop(v, None)
    return out


def page_sections():
    """{"## heading": text} for the page's top-level sections."""
    text = read(PAGE)
    parts = re.split(r"(?m)^## (.+)$", text)
    return {parts[i].strip(): parts[i + 1] for i in range(1, len(parts), 2)}


def page_vars():
    """{name: kind} for every variable a table row on the page starts with."""
    out = {}
    for title, body in page_sections().items():
        for row in re.findall(r"(?m)^\| (.*)$", body):
            first = row.split("|")[0]
            for v in ENV.findall(first):
                if title in SECTION_KIND:
                    out[v] = SECTION_KIND[title]
                else:
                    out[v] = "env" if "*Env only" in row else "both"
    return out


def table(section, heading=None):
    """[[cells]] of the first table in a section (or under a ### heading in it)."""
    body = page_sections()[section]
    if heading:
        body = body[body.index("### " + heading):]
    rows = []
    for line in body.splitlines():
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif rows:
            break
    return rows[1:]


class PageAndCode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = code_vars()
        cls.page = page_vars()
        cls.cli = load_cli()

    def test_every_variable_the_code_reads_is_on_the_page(self):
        for var, where in sorted(self.code.items()):
            with self.subTest(var=var):
                self.assertIn(var, self.page, "%s (in %s) isn't in docs/guides/configuration.md" % (var, where))

    def test_every_variable_on_the_page_is_read_somewhere(self):
        for var in sorted(self.page):
            with self.subTest(var=var):
                self.assertIn(var, self.code, "nothing in %s reads %s: drop it from the page" % (CODE_DIRS, var))

    def test_doctor_knows_the_same_variables_as_the_page(self):
        self.assertEqual(sorted(self.cli.SETTINGS), sorted(self.page))

    def test_doctor_and_the_page_agree_on_where_each_is_read(self):
        for var, (where, _rule) in sorted(self.cli.SETTINGS.items()):
            with self.subTest(var=var):
                self.assertEqual(self.page.get(var), where)

    def test_every_rule_is_one_setting_problem_understands(self):
        for var, (_where, rule) in sorted(self.cli.SETTINGS.items()):
            with self.subTest(var=var):
                self.assertTrue(rule in ("", "secret", "onoff", "urls", "url", "exe", "file")
                                or (isinstance(rule, tuple) and rule[0] in ("enum", "re", "num", "int")))
                self.cli.setting_problem(var, "x")  # never raises

    def test_hub_json_keys_match_the_page(self):
        rows = table("Hub: hub.json")
        keys = [re.sub(r"`", "", r[0]) for r in rows]
        self.assertEqual(sorted(keys), sorted(hubmod.CONFIG_KEYS))

    def test_hub_json_defaults_match_load_config(self):
        cfg = hubmod.load_config(None, {"db": ":memory:"})
        for row in table("Hub: hub.json"):
            key = row[0].strip("`")
            m = re.fullmatch(r"`(-?[0-9.]+)`", row[2])
            if m and isinstance(cfg.get(key), (int, float)) and not isinstance(cfg.get(key), bool):
                with self.subTest(key=key):
                    self.assertEqual(float(cfg[key]), float(m.group(1)))

    def test_hub_update_json_keys_match_the_page(self):
        sys.path.insert(0, os.path.join(ROOT, "hub"))
        import needs_you_hub_update as upd
        keys = [r[0].strip("`") for r in table("Hub: hub-update.json")]
        self.assertEqual(sorted(keys), sorted(upd.SETTINGS_KEYS))

    def test_the_pollers_share_one_settings_block(self):
        blocks = set()
        for p in POLLERS:
            text = read(os.path.join(ROOT, p))
            start = text.index("# --- needs-you settings (begin) ---")
            end = text.index("# --- needs-you settings (end) ---")
            blocks.add(text[start:end])
        self.assertEqual(len(blocks), 1, "change the block the same way in every poller")

    def test_the_page_is_on_the_site_index_and_in_the_readme(self):
        import build_site_guides as gen
        self.assertIn("docs/guides/configuration.md", {g[1] for g in gen.CURATED})
        self.assertIn("](docs/guides/configuration.md)", read(os.path.join(ROOT, "README.md")))


# ---------------------------------------------------------------------------------------------
# The hub
# ---------------------------------------------------------------------------------------------

class HubConfig(unittest.TestCase):
    def load(self, cfg, overrides=None):
        d = tempfile.mkdtemp(prefix="ny-cfg-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        path = os.path.join(d, "hub.json")
        with open(path, "w") as fh:
            json.dump(cfg, fh)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            try:
                return hubmod.load_config(path, overrides), err.getvalue(), None
            except SystemExit as e:
                return None, err.getvalue(), str(e)

    def test_bad_values_are_refused_naming_every_key_and_never_the_value(self):
        cfg, _, error = self.load({"port": "eighty", "quiet": "false", "peers": "http://hub-b:8765",
                                   "peer_secret": 12345, "retention_days": -1, "max_connections": 1.5,
                                   "db": ":memory:"})
        self.assertIsNone(cfg)
        for says in ("port must be a whole number", "quiet must be true or false", "peers must be a list of strings",
                     "peer_secret must be a string", "retention_days must be a number of at least 0",
                     "max_connections must be a whole number", "configuration.md"):
            self.assertIn(says, error)
        self.assertNotIn("12345", error)
        self.assertNotIn("eighty", error)

    def test_a_secret_of_the_wrong_type_is_never_shown(self):
        _, _, error = self.load({"peer_secret": [SECRET], "db": ":memory:"})
        self.assertIn("peer_secret must be a string", error)
        self.assertNotIn(SECRET, error)

    def test_unknown_keys_warn_with_did_you_mean_and_are_ignored(self):
        cfg, err, error = self.load({"retension_days": 3, "db": ":memory:"})
        self.assertIsNone(error)
        self.assertIn("unknown key 'retension_days' (did you mean retention_days?); ignored", err)
        self.assertEqual(cfg["retention_days"], hubmod.DEFAULT_RETENTION_DAYS)

    def test_numeric_strings_still_work_and_null_means_the_default(self):
        cfg, err, error = self.load({"retention_days": "14", "port": "8766", "vacuum_hours": None, "db": ":memory:"})
        self.assertIsNone(error, error)
        self.assertEqual((cfg["retention_days"], cfg["port"], cfg["vacuum_hours"]), (14.0, 8766, 24.0))
        self.assertEqual(err, "")

    def test_the_example_config_is_valid(self):
        r = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "hub", "needs_you_hub.py"), "--check-config",
                            "--config", os.path.join(ROOT, "deploy", "hub.example.json")],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("hub config OK", r.stdout)
        self.assertEqual(r.stderr, "")

    def test_check_config_reports_hub_update_json_too(self):
        d = tempfile.mkdtemp(prefix="ny-cfg-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        with open(os.path.join(d, "hub.json"), "w") as fh:
            json.dump({"db": os.path.join(d, "x.db"), "port": 0}, fh)
        with open(os.path.join(d, "hub-update.json"), "w") as fh:
            json.dump({"auto_update": "yes", "chanel": "beta", "soak_hours": 9999, "gh": "gh"}, fh)
        r = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "hub", "needs_you_hub.py"), "--check-config",
                            "--config", os.path.join(d, "hub.json")], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)  # it turns updates off; the hub still starts
        for says in ("unknown key 'chanel' (did you mean channel?)", "auto_update must be true or false",
                     "soak_hours must be a number of hours from 0 to 720", 'gh must be "" (gh on PATH) or an absolute path',
                     "so automatic updates are off"):
            self.assertIn(says, r.stderr)
        self.assertEqual(sorted(os.listdir(d)), ["hub-update.json", "hub.json"])  # nothing written

    def test_check_config_fails_on_what_would_stop_the_hub(self):
        d = tempfile.mkdtemp(prefix="ny-cfg-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, True))
        with open(os.path.join(d, "hub.json"), "w") as fh:
            json.dump({"db": os.path.join(d, "x.db"), "peers": ["http://hub-b:8765"], "peer_secret": "short"}, fh)
        r = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "hub", "needs_you_hub.py"), "--check-config",
                            "--config", os.path.join(d, "hub.json")], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 1)
        self.assertIn("peer_secret is missing or shorter than 16 chars", r.stderr)
        self.assertNotIn("short", r.stderr.replace("shorter", ""))


# ---------------------------------------------------------------------------------------------
# The pollers and the CLI
# ---------------------------------------------------------------------------------------------

def load_script(rel, name):
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(ROOT, rel))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class PollerContexts(unittest.TestCase):
    """Work or personal per team, project, owner or repo (the Mac's Settings → Integrations
    pickers write these lines): only the context, never what's watched."""

    def config(self, rel, env):
        return PollerWarnings.config(self, rel, env)

    def test_linear_contexts_per_team_and_star(self):
        cfg, err = self.config(POLLERS[1], {"NEEDS_YOU_DEFAULT_CONTEXT": "work",
                                            "NEEDS_YOU_LINEAR_CONTEXTS": "acme=personal,*=personal,OPS=work,bad"})
        self.assertIn("NEEDS_YOU_LINEAR_CONTEXTS: 1 item isn't KEY=work|personal", err)
        self.assertEqual(cfg.team_of("ACME"), ("personal", "low"))
        self.assertEqual(cfg.team_of("OPS"), ("work", "low"))
        self.assertEqual(cfg.team_of("HOME"), ("personal", "low"))   # "*"
        # With NEEDS_YOU_LINEAR_TEAMS: still only those teams; CONTEXTS wins for a listed team.
        cfg, _ = self.config(POLLERS[1], {"NEEDS_YOU_LINEAR_TEAMS": "ACME=work:normal,OPS=work:urgent",
                                          "NEEDS_YOU_LINEAR_CONTEXTS": "ACME=personal,*=personal"})
        self.assertEqual(cfg.team_of("ACME"), ("personal", "normal"))
        self.assertEqual(cfg.team_of("OPS"), ("work", "urgent"))    # its TEAMS context beats "*"
        self.assertIsNone(cfg.team_of("HOME"))                       # still not watched
        cfg, _ = self.config(POLLERS[1], {})
        self.assertEqual(cfg.team_of("ACME"), ("work", "low"))

    def test_jira_contexts_per_project_and_star(self):
        cfg, _ = self.config(POLLERS[2], {"NEEDS_YOU_JIRA_CONTEXTS": "ACME=personal,*=personal,OPS=work"})
        self.assertEqual(cfg.errors, [])
        self.assertEqual(cfg.project_rule("ACME"), ("personal", "low"))
        self.assertEqual(cfg.project_rule("OPS"), ("work", "low"))
        self.assertEqual(cfg.project_rule("HOME"), ("personal", "low"))
        cfg, _ = self.config(POLLERS[2], {"NEEDS_YOU_JIRA_PROJECTS": "ACME=work:normal,OPS=work:urgent",
                                          "NEEDS_YOU_JIRA_CONTEXTS": "ACME=personal,*=personal"})
        self.assertEqual(cfg.project_rule("ACME"), ("personal", "normal"))
        self.assertEqual(cfg.project_rule("OPS"), ("work", "urgent"))
        self.assertEqual(sorted(cfg.projects), ["ACME", "OPS"])      # CONTEXTS never widens the watch list
        cfg, _ = self.config(POLLERS[2], {"NEEDS_YOU_JIRA_CONTEXTS": "acme-1=work"})
        self.assertTrue(any("NEEDS_YOU_JIRA_CONTEXTS" in e for e in cfg.errors))

    def test_github_contexts_per_repo_owner_and_star(self):
        cfg, _ = self.config(POLLERS[0], {"NEEDS_YOU_GITHUB_CONTEXTS": "acme=work,acme/side=personal,*=personal"})
        self.assertEqual(cfg.context("acme/api"), "work")
        self.assertEqual(cfg.context("Acme/Side"), "personal")       # the repo wins over its owner
        self.assertEqual(cfg.context("example-user/dotfiles"), "personal")
        cfg, _ = self.config(POLLERS[0], {"NEEDS_YOU_DEFAULT_CONTEXT": "personal"})
        self.assertEqual(cfg.context("acme/api"), "personal")


class PollerWarnings(unittest.TestCase):
    def config(self, rel, env):
        mod = load_script(rel, "poller_" + os.path.basename(rel).replace("-", "_"))
        home = tempfile.mkdtemp(prefix="ny-poll-")
        self.addCleanup(lambda: __import__("shutil").rmtree(home, True))
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update({"HOME": home, "PATH": "/usr/bin:/bin", "NEEDS_YOU_CONFIG": os.path.join(home, "env")})
        os.environ.update(env)
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                cfg = mod.Config()
        finally:
            os.environ.clear()
            os.environ.update(saved)
        return cfg, err.getvalue()

    def test_github_names_bad_values_and_uses_the_defaults(self):
        cfg, err = self.config(POLLERS[0], {"NEEDS_YOU_GITHUB_INTERVAL": SECRET, "NEEDS_YOU_GITHUB_PR_DAYS": "7.5",
                                            "NEEDS_YOU_GITHUB_MAX_CARDS": "0",
                                            "NEEDS_YOU_GITHUB_SECURITY_PRIORITY": "loud",
                                            "NEEDS_YOU_GITHUB_REASONS": "review,mentoin",
                                            "NEEDS_YOU_GITHUB_CONTEXTS": "acme=wrk"})
        self.assertEqual((cfg.interval_min, cfg.pr_days, cfg.max_cards, cfg.security_priority), (5.0, 14, 1, "low"))
        self.assertEqual(cfg.reasons, {"review"})
        for says in ("NEEDS_YOU_GITHUB_INTERVAL takes a number of at least 1; using 5",
                     "NEEDS_YOU_GITHUB_PR_DAYS takes a whole number of at least 1; using 14",
                     "NEEDS_YOU_GITHUB_MAX_CARDS takes a whole number of at least 1; using 1",
                     "NEEDS_YOU_GITHUB_SECURITY_PRIORITY takes one of urgent, normal, low; using low",
                     "NEEDS_YOU_GITHUB_REASONS: 1 item isn't a reason",
                     "NEEDS_YOU_GITHUB_CONTEXTS: 1 item isn't owner=work, owner/repo=personal or *=work"):
            self.assertIn(says, err)
        self.assertNotIn(SECRET, err)
        self.assertNotIn("mentoin", err)

    def test_linear_jira_and_expiry_too(self):
        _, err = self.config(POLLERS[1], {"NEEDS_YOU_LINEAR_INTERVAL": "soon", "NEEDS_YOU_LINEAR_TEAMS": "ENG=wrk",
                                          "NEEDS_YOU_LINEAR_STATUSES": "Done=never"})
        self.assertIn("NEEDS_YOU_LINEAR_INTERVAL takes a number of at least 1; using 5", err)
        self.assertIn("NEEDS_YOU_LINEAR_TEAMS: 1 item isn't KEY=work|personal:urgent|normal|low", err)
        self.assertIn("NEEDS_YOU_LINEAR_STATUSES: 1 item isn't Name=urgent|normal|low|off", err)
        _, err = self.config(POLLERS[2], {"NEEDS_YOU_JIRA_MAX_CARDS": "many", "NEEDS_YOU_JIRA_EVENTS": "status,typo"})
        self.assertIn("NEEDS_YOU_JIRA_MAX_CARDS takes a whole number of at least 1; using 20", err)
        self.assertIn("NEEDS_YOU_JIRA_EVENTS: 1 item isn't an event", err)
        cfg, err = self.config(POLLERS[3], {"NEEDS_YOU_EXPIRY_TIMEOUT": "600", "NEEDS_YOU_EXPIRY_CONTEXT": "home",
                                            "NEEDS_YOU_DEFAULT_CONTEXT": "personal",
                                            "NEEDS_YOU_EXPIRY_DAYS": "30=low,soon=urgent"})
        self.assertEqual((cfg.timeout, cfg.context), (60.0, "personal"))  # an unknown context: the default one
        self.assertIn("NEEDS_YOU_EXPIRY_TIMEOUT takes a number from 1 to 60; using 60", err)
        self.assertIn("NEEDS_YOU_EXPIRY_CONTEXT takes one of work, personal; using personal", err)
        self.assertIn("NEEDS_YOU_EXPIRY_DAYS: 1 item isn't days=urgent|normal|low", err)

    def test_good_values_say_nothing(self):
        for rel in POLLERS:
            with self.subTest(poller=rel):
                _, err = self.config(rel, {"NEEDS_YOU_DEFAULT_CONTEXT": "personal"})
                self.assertEqual(err, "")


class CliWarnings(DoctorTestCase):
    def test_bad_values_are_named_never_shown(self):
        r = self.run_cli("health", urls=[self.hub.url], token=self.sender,
                         extra_env={"NEEDS_YOU_TIMEOUT": SECRET, "NEEDS_YOU_DEFAULT_CONTEXT": "wrok"})
        self.assertIn("NEEDS_YOU_TIMEOUT takes a number of at least 0.1; using 3", r.stderr)
        self.assertIn("NEEDS_YOU_DEFAULT_CONTEXT takes one of work, personal; using work", r.stderr)
        self.assertNotIn(SECRET, r.stdout + r.stderr)
        self.assertNotIn("wrok", r.stdout + r.stderr)

    def test_the_outbox_caps_are_read_from_the_env_file_too(self):
        self.write_env(["NEEDS_YOU_OUTBOX_MAX=2"])
        for n in range(4):
            self.run_cli("add", "--key", "k%d" % n, "--title", "t", urls=[self.dead], token="t")
        self.assertEqual(len(self.queued()), 2)


# ---------------------------------------------------------------------------------------------
# needs-you doctor
# ---------------------------------------------------------------------------------------------

class DoctorSettings(DoctorTestCase):
    def setUp(self):
        super().setUp()
        self.base = ["NEEDS_YOU_URLS=%s" % self.hub.url, "NEEDS_YOU_TOKEN=%s" % self.sender]

    def test_known_good_settings_are_ok(self):
        self.write_env(self.base + ["NEEDS_YOU_AGENT_ALERTS=1", "export NEEDS_YOU_DEFAULT_CONTEXT=personal",
                                    "NEEDS_YOU_GITHUB_INTERVAL = 10", "# NEEDS_YOU_TYPO=1 in a comment"])
        _, _, checks = self.doctor_json()
        self.assertEqual(checks["settings"]["status"], "OK", checks["settings"])
        self.assertNotIn("key files", checks)
        self.assertNotIn("hub config", checks)

    def test_typos_bad_values_and_lines_that_do_nothing(self):
        self.write_env(self.base + [
            "NEEDS_YOU_AGENT_ALERT=1",                 # a typo
            "NEEDS_YOU_OUTBOX_MAX_DAYS=%s" % SECRET,   # a bad value: named, never shown
            "NEEDS_YOU_AGENT_ALERTS=On",               # the hook matches lowercase only
            "NEEDS_YOU_LINEAR_KEY=%s" % SECRET,        # env only
            "NEEDS_YOU_HOOK_LOG=/tmp/x.log",           # env only
            "NEEDS_YOU_WATCH_PID=1",                   # needs-you sets it
            "NEEDS_YOU_PEER_SECRET=%s" % SECRET,       # a hub's
            SECRET,                                    # a token pasted on its own line
            "GITHUB_TOKEN=%s" % SECRET,                # not ours
            "NEEDS_YOU_CONTEXT_ALERT_PCT=80", "NEEDS_YOU_CONTEXT_ALERT_PCT=90",
        ])
        r, data, checks = self.doctor_json(extra_env={"NEEDS_YOU_GITHUB_INTERVL": "5",
                                                      "NEEDS_YOU_JIRA_AUTH": "server"})
        s = checks["settings"]
        self.assertEqual(s["status"], "WARN", s)
        for says in ("NEEDS_YOU_AGENT_ALERT (env file): not a needs-you setting (did you mean NEEDS_YOU_AGENT_ALERTS?)",
                     "NEEDS_YOU_OUTBOX_MAX_DAYS (env file) takes a number of at least 0.01",
                     "NEEDS_YOU_AGENT_ALERTS (env file) takes one of 1, true, yes, on, 0, false, no, off (lowercase)",
                     "NEEDS_YOU_LINEAR_KEY (env file): read only from the environment, so this line does nothing; "
                     "put the key in the key file instead",
                     "NEEDS_YOU_HOOK_LOG (env file): read only from the environment",
                     "NEEDS_YOU_WATCH_PID (env file): needs-you sets it itself; remove the line",
                     "NEEDS_YOU_PEER_SECRET (env file): read by a hub, never a sender",
                     "line 10 isn't NAME=VALUE, so it's ignored",
                     "GITHUB_TOKEN (env file): needs-you reads only NEEDS_YOU_* names from this file",
                     "NEEDS_YOU_CONTEXT_ALERT_PCT is on 2 lines of the env file; the last one wins",
                     "NEEDS_YOU_GITHUB_INTERVL (environment): not a needs-you setting (did you mean NEEDS_YOU_GITHUB_INTERVAL?)",
                     "NEEDS_YOU_JIRA_AUTH (environment) takes one of cloud, dc"):
            self.assertIn(says, s["detail"])
        self.assertIn("configuration.md", s["hint"])
        self.assertNotIn(SECRET, r.stdout + r.stderr)
        self.assertNotIn("server", s["detail"])

    def test_key_files_with_the_wrong_mode(self):
        self.write_env(self.base)
        d = os.path.join(self.home, ".config", "needs-you")
        key = os.path.join(d, "linear-key")
        with open(key, "w") as fh:
            fh.write(SECRET + "\n")
        os.chmod(key, 0o644)
        r, _, checks = self.doctor_json(extra_env={"NEEDS_YOU_JIRA_TOKEN_FILE": os.path.join(self.home, "no-such")})
        k = checks["key files"]
        self.assertEqual(k["status"], "WARN", k)
        self.assertIn("Linear key file ~/.config/needs-you/linear-key (mode 644): others can read or write it", k["detail"])
        self.assertIn("Jira token file ~/no-such doesn't exist", k["detail"])
        self.assertIn("chmod 600", k["hint"])
        self.assertNotIn(SECRET, r.stdout)
        os.chmod(key, 0o600)
        _, _, checks = self.doctor_json()
        self.assertEqual(checks["key files"]["status"], "OK", checks["key files"])

    def hub_install(self, cfg, mode=0o600):
        code = os.path.join(self.home, ".local", "share", "needs-you", "hub")
        os.makedirs(code, exist_ok=True)
        for f in ("needs_you_hub.py", "needs_you_hub_update.py"):
            with open(os.path.join(ROOT, "hub", f)) as src, open(os.path.join(code, f), "w") as dst:
                dst.write(src.read())
        conf = os.path.join(self.home, ".config", "needs-you", "hub.json")
        os.makedirs(os.path.dirname(conf), exist_ok=True)
        with open(conf, "w") as fh:
            json.dump(cfg, fh)
        os.chmod(conf, mode)
        return conf

    def test_a_hub_on_this_machine_gets_its_config_checked(self):
        self.write_env(self.base)
        conf = self.hub_install({"db": os.path.join(self.tmp, "h.db"), "port": 0, "peer_secret": SECRET})
        _, _, checks = self.doctor_json()
        self.assertEqual(checks["hub config"]["status"], "OK", checks["hub config"])
        self.hub_install({"db": os.path.join(self.tmp, "h.db"), "port": "x", "retension_days": 1,
                          "peer_secret": SECRET})
        r, data, checks = self.doctor_json()
        h = checks["hub config"]
        self.assertEqual(h["status"], "FAIL", h)
        self.assertIn("port must be a whole number", h["detail"])
        self.assertIn("--check-config", h["hint"])
        self.assertNotIn(SECRET, r.stdout)
        self.assertFalse(data["ok"])
        os.chmod(conf, 0o644)
        _, _, checks = self.doctor_json()
        self.assertEqual(checks["hub config"]["status"], "WARN")
        self.assertIn("chmod 600", checks["hub config"]["hint"])


if __name__ == "__main__":
    unittest.main()
