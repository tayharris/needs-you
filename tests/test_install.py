"""install.sh (from /join/<code>/install.sh) and scripts/install-hub.sh --user, end to end.

Everything runs with a temporary HOME and stub `crontab`, `launchctl` and `uname` commands
first on PATH, so the real ~/.claude, ~/.config, crontab and launchd are never touched.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import unittest

from support import ROOT, HubTestCase, request

OWNER = "owner-secret-0123456789abcdef"
REAL_HOME = os.path.expanduser("~")
BASH = shutil.which("bash") or "/bin/bash"

STUB = """#!/bin/sh
# test stub: record the call, emulate just enough
echo "$(basename "$0") $*" >> "$STUB_LOG"
case "$(basename "$0")" in
  crontab)
    if [ "$1" = "-l" ]; then [ -f "$STUB_CRON" ] && cat "$STUB_CRON"; exit 0; fi
    if [ "$1" = "-" ]; then cat > "$STUB_CRON"; exit 0; fi ;;
  uname) echo "${STUB_UNAME:-Darwin}" ;;
esac
exit 0
"""


class InstallScript(HubTestCase):
    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(self.home)
        os.makedirs(self.stubs)
        for name in ("crontab", "launchctl", "uname"):
            p = os.path.join(self.stubs, name)
            with open(p, "w") as fh:
                fh.write(STUB)
            os.chmod(p, 0o755)
        self.log = os.path.join(self.tmp, "stub.log")
        self.cron = os.path.join(self.tmp, "crontab")
        self.hub = self.make_hub("hub-a", peers=[])
        self.hub.store.ensure_token("this-mac", "owner", OWNER)
        self.assertNotEqual(self.home, REAL_HOME)

    def env(self, **extra):
        env = {"HOME": self.home, "PATH": self.stubs + ":/usr/bin:/bin:/usr/sbin:/sbin",
               "STUB_LOG": self.log, "STUB_CRON": self.cron, "NO_PROXY": "*", "LANG": "C"}
        env.update(extra)
        return env

    def invite(self, **body):
        body.setdefault("name", "srv")
        status, inv = request("POST", self.hub.url + "/v1/invites", OWNER, body)
        self.assertEqual(status, 201, inv)
        return inv

    def install(self, inv, *flags, **env):
        cmd = "curl -fsSL %s/install.sh | bash -s -- %s" % (inv["join_url"], " ".join(flags))
        return subprocess.run([BASH, "-c", cmd], env=self.env(**env), capture_output=True,
                              text=True, timeout=120, cwd=self.home)

    def envfile(self):
        out = {}
        with open(os.path.join(self.home, ".config", "needs-you", "env")) as fh:
            for line in fh:
                if "=" in line and not line.startswith("#"):
                    k, v = line.strip().split("=", 1)
                    out[k] = v
        return out

    def stub_calls(self):
        try:
            with open(self.log) as fh:
                return fh.read()
        except OSError:
            return ""

    def test_full_install_on_macos_and_rerun(self):
        inv = self.invite(uses=2)
        r = self.install(inv, "--yes", "--skill", "--orca", "--claude-hooks", "user",
                         "--context", "personal", "--host", "box1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        self.assertTrue(os.access(cli, os.X_OK))
        env_path = os.path.join(self.home, ".config", "needs-you", "env")
        self.assertEqual(stat.S_IMODE(os.stat(env_path).st_mode), 0o600)
        env = self.envfile()
        self.assertEqual(env["NEEDS_YOU_URLS"], self.hub.url)
        self.assertEqual(env["NEEDS_YOU_DEFAULT_CONTEXT"], "personal")
        token = env["NEEDS_YOU_TOKEN"]
        self.assertNotIn(token, r.stdout + r.stderr)  # never printed
        self.assertEqual(request("GET", self.hub.url + "/v1/health", token)[1]["token"],
                         {"name": "srv-box1", "role": "sender"})
        # skill, hooks, orca snippet, LaunchAgent
        self.assertTrue(os.path.exists(os.path.join(self.home, ".claude", "skills", "needs-you", "SKILL.md")))
        with open(os.path.join(self.home, ".claude", "settings.json")) as fh:
            self.assertIn("needs-you-hook.sh", fh.read())
        self.assertTrue(os.path.exists(os.path.join(self.home, ".claude", "hooks", "needs-you-hook.sh")))
        self.assertIn("needs-you add", r.stdout)  # the orca snippet is printed
        plist = os.path.join(self.home, "Library", "LaunchAgents", "io.needs-you.flush.plist")
        with open(plist) as fh:
            body = fh.read()
        self.assertIn("<integer>300</integer>", body)
        self.assertIn(cli, body)
        self.assertIn("launchctl bootstrap", self.stub_calls())
        # health ran, and the test item arrived with the machine's default context
        self.assertIn("OK", r.stdout)
        _, items = request("GET", self.hub.url + "/v1/items", OWNER)
        test = [i for i in items["items"] if i["key"] == "setup:box1:test"]
        self.assertEqual(len(test), 1)
        self.assertEqual((test[0]["kind"], test[0]["context"]), ("info", "personal"))

        # re-run: keeps the token, doesn't spend a use
        r = self.install(inv, "--yes", "--host", "box1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("kept the existing token", r.stdout)
        self.assertEqual(self.envfile()["NEEDS_YOU_TOKEN"], token)
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 1)
        self.assertEqual(self.envfile()["NEEDS_YOU_DEFAULT_CONTEXT"], "personal")

        # --force: a new token
        r = self.install(inv, "--yes", "--force", "--host", "box1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotEqual(self.envfile()["NEEDS_YOU_TOKEN"], token)
        # used up now: --force can't redeem again, and says so with exit 1
        before = self.envfile()["NEEDS_YOU_TOKEN"]
        r = self.install(inv, "--yes", "--force", "--host", "box1")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("no uses left", r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_TOKEN"], before)
        # but a plain re-run still works on this machine
        r = self.install(inv, "--yes", "--host", "box1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("kept the existing token", r.stdout)

    def test_uninstall_and_linux_cron(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--host", "lin", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.cron) as fh:
            cron = fh.read()
        self.assertEqual(cron.count("needs-you-flush"), 1)
        self.assertIn("*/5 * * * *", cron)
        # the link is used up after one redeem; re-running it is still idempotent
        r = self.install(inv, "--yes", "--host", "lin", "--claude-hooks", "user", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("setup-sender.sh", r.stdout)  # the installer has just installed the CLI
        with open(self.cron) as fh:
            self.assertEqual(fh.read().count("needs-you-flush"), 1)
        with open(self.cron, "a") as fh:
            fh.write("0 1 * * * other-job\n")
        state = os.path.join(self.home, ".local", "state", "needs-you", "claude-hooks")
        os.makedirs(state)
        # and --uninstall works from the used-up link too
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.cron) as fh:
            self.assertEqual(fh.read().strip(), "0 1 * * * other-job")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "bin", "needs-you")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "needs-you", "env")))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "state", "needs-you")))
        with open(os.path.join(self.home, ".claude", "settings.json")) as fh:
            self.assertNotIn("needs-you-hook.sh", fh.read())
        # a new machine can't use it
        r = self.install(inv, "--yes", "--host", "lin2", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no uses left", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "bin", "needs-you")))

    def test_one_line_claude_setup_settings_and_path(self):
        inv = self.invite(uses=1)
        zshrc = os.path.join(self.home, ".zshrc")
        with open(zshrc, "w") as fh:
            fh.write("alias ll='ls -l'\n")
        flags = ["--yes", "--host", "box2", "--claude-hooks", "user", "--alerts", "--context-alert", "70",
                 "--ssh-alias", "devbox", "--agent-link", "'VS Code=vscode://file{cwd}'",
                 "--orca-environment", "'My Devbox'"]
        r = self.install(inv, *flags, SHELL="/bin/zsh", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        env = self.envfile()
        self.assertEqual(env["NEEDS_YOU_AGENT_ALERTS"], "1")
        self.assertEqual(env["NEEDS_YOU_CONTEXT_ALERT_PCT"], "70")
        self.assertEqual(env["NEEDS_YOU_SSH_ALIAS"], "devbox")
        self.assertEqual(env["NEEDS_YOU_AGENT_LINK"], "'VS Code=vscode://file{cwd}'")
        self.assertEqual(env["NEEDS_YOU_ORCA_ENVIRONMENT"], "'My Devbox'")
        self.assertIn("Alerts are on for every Claude Code session here", r.stdout)
        self.assertNotIn(env["NEEDS_YOU_TOKEN"], r.stdout + r.stderr)
        with open(zshrc) as fh:
            rc = fh.read()
        self.assertIn("alias ll='ls -l'\n", rc)
        self.assertEqual(rc.count('export PATH="$HOME/.local/bin:$PATH"  # added by needs-you'), 1)
        # the hook reads the quoted values back
        hook = os.path.join(self.home, ".claude", "hooks", "needs-you-hook.sh")
        self.assertTrue(os.access(hook, os.X_OK))

        # re-run with no settings flags: same token, settings kept, one PATH line, one cron line
        r = self.install(inv, "--yes", "--host", "box2", "--claude-hooks", "user", SHELL="/bin/zsh",
                         STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile(), env)
        with open(zshrc) as fh:
            self.assertEqual(fh.read(), rc)
        self.assertIn("already adds", r.stdout)
        with open(self.cron) as fh:
            self.assertEqual(fh.read().count("needs-you-flush"), 1)
        # a new value replaces the old one in place
        r = self.install(inv, "--yes", "--host", "box2", "--context-alert", "0", SHELL="/bin/zsh",
                         STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_CONTEXT_ALERT_PCT"], "0")
        with open(os.path.join(self.home, ".config", "needs-you", "env")) as fh:
            self.assertEqual(fh.read().count("NEEDS_YOU_CONTEXT_ALERT_PCT="), 1)

        # --uninstall takes the PATH line back out and leaves the rest
        r = self.install(inv, "--uninstall", SHELL="/bin/zsh", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(zshrc) as fh:
            self.assertEqual(fh.read().strip(), "alias ll='ls -l'")
        with open(self.cron) as fh:  # a crontab holding only our line (pipefail used to stop here)
            self.assertEqual(fh.read().strip(), "")

    def test_no_path_prints_the_line_and_bad_values_fail(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--host", "box3", "--no-path", "--no-schedule")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('export PATH="$HOME/.local/bin:$PATH"', r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".profile")))
        r = self.install(inv, "--yes", "--host", "box3", "--no-schedule", SHELL="/bin/sh")  # -> ~/.profile
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(self.home, ".profile")) as fh:
            self.assertIn("# added by needs-you", fh.read())
        for bad in (["--context-alert", "101"], ["--context-alert", "x"], ["--ssh-alias", "'a b'"],
                    ["--agent-link", "nolink"], ["--agent-link", "'X=https://a/$(id)'"],
                    ["--orca-environment", "';rm'"]):
            r = self.install(inv, "--yes", *bad)
            self.assertEqual(r.returncode, 1, bad)
        self.assertNotIn("NEEDS_YOU_SSH_ALIAS", self.envfile())

    def test_dead_link_fails_loudly(self):
        inv = self.invite()
        self.hub.store.revoke_invite("srv")
        r = self.install(inv, "--yes")
        self.assertEqual(r.returncode, 1)
        self.assertIn("unknown, expired or revoked", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "bin", "needs-you")))

    def test_help_when_piped(self):
        r = self.install(self.invite(), "--help")
        self.assertEqual(r.returncode, 0)
        for opt in ("--claude-hooks", "--uninstall", "--hub", "--context"):
            self.assertIn(opt, r.stdout)
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 1)

    def test_hub_flag_is_saved_first(self):
        hub = self.make_hub("hub-z", peers=[], public_url="http://hub-z.example.ts.net:8765")
        hub.store.ensure_token("this-mac", "owner", OWNER)
        _, inv = request("POST", hub.url + "/v1/invites", OWNER, {"name": "mac", "uses": 1})
        given = hub.url.replace("127.0.0.1", "localhost")
        # the link's name doesn't resolve here (the case --hub is for), so fetch the script locally
        local = dict(inv, join_url=hub.url + "/join/" + inv["code"])
        r = self.install(local, "--yes", "--no-schedule", "--hub", given, "--host", "my-mac")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # --hub first, then (redeemed from this machine) the loopback URL, then public_url
        self.assertEqual(self.envfile()["NEEDS_YOU_URLS"],
                         ",".join([given, hub.url, "http://hub-z.example.ts.net:8765"]))
        self.assertEqual(self.envfile()["NEEDS_YOU_URL"], given)
        # the test card carries the --host name, not the real hostname
        _, items = request("GET", hub.url + "/v1/items", OWNER)
        card = [i for i in items["items"] if i["key"] == "setup:my-mac:test"][0]
        self.assertEqual(card["source"]["host"], "my-mac")

    def test_reader_invite_points_to_the_mac(self):
        inv = self.invite(role="owner", name="mac")
        r = self.install(inv, "--yes")
        self.assertEqual(r.returncode, 1)
        self.assertIn("needsyou://connect?hub=", r.stdout)
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 1)  # not spent
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "needs-you", "env")))

    def test_needs_yes_without_a_terminal(self):
        inv = self.invite()
        r = subprocess.run([BASH, "-c", "curl -fsSL %s/install.sh | bash -s" % inv["join_url"]],
                           env=self.env(), capture_output=True, text=True, timeout=60,
                           stdin=subprocess.DEVNULL, start_new_session=True)  # no controlling tty
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--yes", r.stderr)
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 1)


class InstallHubUser(unittest.TestCase):
    def test_user_install_files_config_and_invite(self):
        import tempfile
        tmp = tempfile.mkdtemp(prefix="needs-you-ih-")
        try:
            home = os.path.join(tmp, "home")
            os.makedirs(home)
            env = {"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
            script = os.path.join(ROOT, "scripts", "install-hub.sh")
            r = subprocess.run([BASH, script, "--user", "--no-start", "--bind", "127.0.0.1",
                                "--hub-id", "hub-a", "--public-url", "http://hub-a.example.ts.net:8765",
                                "--peer", "http://hub-b.example.ts.net:8765", "--generate-peer-secret"],
                               env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            share = os.path.join(home, ".local", "share", "needs-you")
            for rel in ("hub/needs_you_hub.py", "hub/needs_you_admin.py", "hub/join-install.sh",
                        "cli/needs-you", "integrations/claude-code/install-hooks.sh",
                        "integrations/claude-code/needs-you-hook.sh", "integrations/claude-code/hooks.json",
                        "integrations/claude-code/skill/needs-you/SKILL.md"):
                self.assertTrue(os.path.exists(os.path.join(share, rel)), rel)
            conf = os.path.join(home, ".config", "needs-you", "hub.json")
            self.assertEqual(stat.S_IMODE(os.stat(conf).st_mode), 0o600)
            with open(conf) as fh:
                cfg = json.load(fh)
            self.assertEqual(cfg["bind"], ["127.0.0.1"])
            self.assertEqual(cfg["peers"], ["http://hub-b.example.ts.net:8765"])
            self.assertEqual(cfg["db"], os.path.join(home, ".local", "state", "needs-you", "hub.db"))
            secret = cfg["peer_secret"]
            self.assertIn(secret, r.stdout)  # printed once
            self.assertIn("needsyou://connect?hub=http%3A%2F%2Fhub-a.example.ts.net%3A8765&code=nyi_",
                          r.stdout)
            unit = os.path.join(home, ".config", "systemd", "user", "needs-you-hub.service")
            with open(unit) as fh:
                self.assertIn("Restart=always", fh.read())
            self.assertTrue(os.access(os.path.join(home, ".local", "bin", "needs-you-admin"), os.X_OK))

            # a token in the DB before the upgrade
            admin = os.path.join(home, ".local", "bin", "needs-you-admin")
            r = subprocess.run([admin, "token", "add", "keep-me"], env=env, capture_output=True,
                               text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            db = cfg["db"]
            db_ino = os.stat(db).st_ino

            # re-run: upgrade in place, keep config + secret + DB, apply the flag passed, no new invite
            r = subprocess.run([BASH, script, "--user", "--no-start", "--public-url",
                                "http://hub-a2.example.ts.net:8765"],
                               env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with open(conf) as fh:
                cfg2 = json.load(fh)
            self.assertEqual(cfg2["peer_secret"], secret)
            self.assertEqual(cfg2["public_url"], "http://hub-a2.example.ts.net:8765")
            self.assertEqual(cfg2["peers"], cfg["peers"])
            self.assertNotIn("needsyou://", r.stdout)
            self.assertNotIn(secret, r.stdout)
            self.assertEqual(os.stat(db).st_ino, db_ino)  # same database file
            r = subprocess.run([admin, "token", "list"], env=env, capture_output=True, text=True, timeout=60)
            self.assertIn("keep-me", r.stdout)

            # the admin wrapper works against the user config
            r = subprocess.run([os.path.join(home, ".local", "bin", "needs-you-admin"), "invite", "list"],
                               env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("mac", r.stdout)

            # peers without a secret are refused
            home2 = os.path.join(tmp, "home2")
            os.makedirs(home2)
            r = subprocess.run([BASH, script, "--user", "--no-start", "--peer", "http://x.example.ts.net:8765"],
                               env=dict(env, HOME=home2), capture_output=True, text=True, timeout=120)
            self.assertNotEqual(r.returncode, 0)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
