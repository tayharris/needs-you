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
import time
import unittest

from support import ROOT, HubTestCase, free_port, request

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

    def install(self, inv, *flags, cwd=None, **env):
        cmd = "curl -fsSL %s/install.sh | bash -s -- %s" % (inv["join_url"], " ".join(flags))
        return subprocess.run([BASH, "-c", cmd], env=self.env(**env), capture_output=True,
                              text=True, timeout=120, cwd=cwd or self.home)

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
        # the hooks.json it merged is recorded, so doctor doesn't call fresh hooks out of date
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            sha = json.load(fh)["hooks_json_sha256"]
        _, manifest = request("GET", self.hub.url + "/dl/manifest.json")
        self.assertEqual(sha, manifest["files"]["hooks.json"]["sha256"])
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        update = [c for c in json.loads(d.stdout)["checks"] if c["check"] == "update"][0]
        self.assertNotIn("hooks.json", update["detail"])
        # the closing lines point at doctor and a test item
        self.assertIn("needs-you doctor", r.stdout)
        self.assertIn('resolve --key "personal:test:box1"', r.stdout)
        self.assertNotIn("is not on PATH", r.stdout)
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

    def test_uninstall_removes_project_hooks_locally(self):
        inv = self.invite(uses=1)
        proj = os.path.join(self.home, "src", "app")
        os.makedirs(proj)
        r = self.install(inv, "--yes", "--host", "p1", "--claude-hooks", "project", cwd=proj, STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = self.install(inv, "--yes", "--host", "p1", "--claude-hooks", "user", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        project_settings = os.path.join(proj, ".claude", "settings.json")
        with open(project_settings) as fh:
            self.assertIn("needs-you-hook.sh", fh.read())
        # Run from the home directory: the recorded project install goes too, via the CLI.
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("removed the needs-you hooks from ~/src/app/.claude/settings.json", r.stdout)
        for settings in (project_settings, os.path.join(self.home, ".claude", "settings.json")):
            with open(settings) as fh:
                self.assertNotIn("needs-you-hook.sh", fh.read())
        self.assertFalse(os.path.exists(os.path.join(proj, ".claude", "hooks", "needs-you-hook.sh")))

    def test_uninstall_without_the_cli_still_uses_the_hub(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--host", "u1", "--claude-hooks", "user", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        os.remove(os.path.join(self.home, ".local", "bin", "needs-you"))
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(self.home, ".claude", "settings.json")) as fh:
            self.assertNotIn("needs-you-hook.sh", fh.read())

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

    def test_schedule_keeps_the_rest_of_the_crontab_as_it_was(self):
        mine = "MAILTO=me\n\n# backups\n0 3 * * * /usr/local/bin/backup\n\n# end\n"
        with open(self.cron, "w") as fh:
            fh.write(mine)
        inv = self.invite(uses=2)
        r = self.install(inv, "--yes", "--host", "box8", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.cron) as fh:
            cron = fh.read()
        self.assertTrue(cron.startswith(mine), cron)
        self.assertEqual(cron.count("needs-you-flush"), 1)
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.cron) as fh:
            self.assertEqual(fh.read(), mine)

    def test_flush_schedule_finds_xdg_config_and_state(self):
        # cron and launchd run the flush without the shell's XDG_CONFIG_HOME / XDG_STATE_HOME:
        # it found no config and silently sent nothing, every 5 minutes.
        inv = self.invite(uses=2)
        xdg = {"XDG_CONFIG_HOME": os.path.join(self.home, "xdg config"),
               "XDG_STATE_HOME": os.path.join(self.home, "xdg-state")}
        r = self.install(inv, "--yes", "--host", "box9", STUB_UNAME="Linux", **xdg)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.cron) as fh:
            line = [l for l in fh.read().splitlines() if "needs-you-flush" in l][0]
        command = line.split(None, 5)[5]
        outbox = os.path.join(xdg["XDG_STATE_HOME"], "needs-you", "outbox")
        os.makedirs(outbox, exist_ok=True)
        with open(os.path.join(outbox, "%020d-00001.json" % time.time_ns()), "w") as fh:
            json.dump({"method": "POST", "path": "/v1/items", "queued_at": "2026-10-07T00:00:00Z",
                       "body": {"key": "work:cron:x", "title": "queued", "source": {"host": "box9"}}}, fh)
        # as cron runs it: sh, HOME and a bare PATH, nothing else
        subprocess.run(["/bin/sh", "-c", command], env={"HOME": self.home, "PATH": "/usr/bin:/bin"},
                       timeout=60)
        self.assertEqual(os.listdir(outbox), [".lock"] if os.path.exists(os.path.join(outbox, ".lock")) else [])
        s, items = request("GET", self.hub.url + "/v1/items?status=open",
                           self.hub.store.add_token("reader-x", "reader")[0])
        self.assertIn("work:cron:x", [i["key"] for i in items["items"]])
        # the LaunchAgent gets them as EnvironmentVariables
        r = self.install(inv, "--yes", "--host", "box9", **xdg)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        import plistlib
        with open(os.path.join(self.home, "Library", "LaunchAgents", "io.needs-you.flush.plist"), "rb") as fh:
            self.assertEqual(plistlib.load(fh)["EnvironmentVariables"], xdg)

    def test_codex_hooks(self):
        inv = self.invite(uses=1)
        codex = os.path.join(self.home, ".codex")
        os.makedirs(codex)
        with open(os.path.join(codex, "hooks.json"), "w") as fh:
            json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/bin/true"}]}]}}, fh)
        r = self.install(inv, "--yes", "--codex-hooks", "user", "--alerts", "--host", "box3",
                         STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Codex CLI", r.stdout)
        self.assertIn("/hooks", r.stdout)
        with open(os.path.join(codex, "hooks.json")) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["hooks"]["Stop"][0]["hooks"][0]["command"], "/bin/true")
        self.assertIn("needs-you-hook.sh", doc["hooks"]["PermissionRequest"][0]["hooks"][0]["command"])
        self.assertTrue(os.access(os.path.join(codex, "hooks", "needs-you-hook.sh"), os.X_OK))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))  # Claude untouched
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            sha = json.load(fh)["codex_hooks_json_sha256"]
        _, manifest = request("GET", self.hub.url + "/dl/manifest.json")
        self.assertEqual(sha, manifest["files"]["codex-hooks.json"]["sha256"])
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        self.assertEqual(checks["codex hooks"]["status"], "OK", checks["codex hooks"])
        self.assertIn("alerts on", checks["codex hooks"]["detail"])
        self.assertNotIn("codex", checks["update"]["detail"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(codex, "hooks.json")) as fh:
            self.assertEqual(json.load(fh), {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/bin/true"}]}]}})
        self.assertFalse(os.path.exists(os.path.join(codex, "hooks", "needs-you-hook.sh")))
        r = self.install(inv, "--yes", "--codex-hooks", "project")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--codex-hooks must be user or none", r.stderr)

    def test_opencode_plugin(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--opencode-plugin", "--host", "box5", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        oc = os.path.join(self.home, ".config", "opencode")
        self.assertTrue(os.path.isfile(os.path.join(oc, "plugins", "needs-you.js")))
        self.assertTrue(os.access(os.path.join(oc, "hooks", "needs-you-hook.sh"), os.X_OK))
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        self.assertEqual(checks["opencode plugin"]["status"], "OK", checks["opencode plugin"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(oc, "plugins", "needs-you.js")))
        self.assertFalse(os.path.exists(os.path.join(oc, "hooks", "needs-you-hook.sh")))

    def test_gemini_hooks(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--gemini-hooks", "user", "--host", "box4", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Gemini CLI", r.stdout)
        gemini = os.path.join(self.home, ".gemini")
        with open(os.path.join(gemini, "settings.json")) as fh:
            doc = json.load(fh)
        self.assertEqual(doc["hooks"]["Notification"][0]["matcher"], "ToolPermission")
        self.assertTrue(os.access(os.path.join(gemini, "hooks", "needs-you-hook.sh"), os.X_OK))
        with open(os.path.join(self.home, ".local", "state", "needs-you", "update.json")) as fh:
            sha = json.load(fh)["gemini_hooks_json_sha256"]
        _, manifest = request("GET", self.hub.url + "/dl/manifest.json")
        self.assertEqual(sha, manifest["files"]["gemini-hooks.json"]["sha256"])
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        self.assertEqual(checks["gemini hooks"]["status"], "OK", checks["gemini hooks"])
        self.assertNotIn("gemini", checks["update"]["detail"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(gemini, "settings.json")) as fh:
            self.assertNotIn("hooks", json.load(fh))
        self.assertFalse(os.path.exists(os.path.join(gemini, "hooks", "needs-you-hook.sh")))

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

    def test_unreachable_hub_says_how_to_check(self):
        inv = self.invite()
        r = self.install(inv, "--yes", "--hub", "http://127.0.0.1:%d" % free_port())
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("can't reach the hub", r.stderr)
        self.assertIn("/v1/health", r.stderr)
        self.assertIn("tailscale.md", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "bin", "needs-you")))
        self.assertEqual(self.hub.store.list_invites()[0]["left"], 1)  # no use spent

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


class InstallHubUserPaths(unittest.TestCase):
    """install-hub.sh --user on a machine without Tailscale, and with XDG_CONFIG_HOME set."""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="needs-you-ih2-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        stub = os.path.join(self.tmp, "stub")
        os.makedirs(self.home)
        os.makedirs(stub)
        with open(os.path.join(stub, "tailscale"), "w") as fh:  # this machine isn't on a tailnet
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(stub, "tailscale"), 0o755)
        self.env = {"HOME": self.home, "PATH": stub + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
        self.script = os.path.join(ROOT, "scripts", "install-hub.sh")

    def install(self, *args, **env):
        r = subprocess.run([BASH, self.script, "--user", "--no-start", "--no-invite", "--bind", "127.0.0.1"]
                           + list(args), env=dict(self.env, **env), capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def test_hub_id_without_tailscale_keeps_the_host_name_in_public_url(self):
        # --hub-id used to drop the host name from the default public_url: every invite link
        # pointed at http://localhost:8765.
        self.install("--hub-id", "hub-a")
        with open(os.path.join(self.home, ".config", "needs-you", "hub.json")) as fh:
            cfg = json.load(fh)
        host = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
        self.assertEqual(cfg["hub_id"], "hub-a")
        self.assertEqual(cfg["public_url"], "http://%s:8765" % host)

    def test_unit_uses_the_config_it_wrote_with_xdg_config_home(self):
        # The unit hard-coded %h/.config/needs-you/hub.json, so with XDG_CONFIG_HOME set the
        # service started without the config the installer had just written.
        xdg = os.path.join(self.home, "xdg conf")
        self.install("--hub-id", "hub-a", XDG_CONFIG_HOME=xdg)
        conf = os.path.join(xdg, "needs-you", "hub.json")
        self.assertTrue(os.path.isfile(conf))
        with open(os.path.join(xdg, "systemd", "user", "needs-you-hub.service")) as fh:
            unit = fh.read()
        exec_start = [l for l in unit.splitlines() if l.startswith("ExecStart=")][0]
        import shlex
        argv = shlex.split(exec_start[len("ExecStart="):])
        self.assertEqual(argv[1:], [os.path.join(self.home, ".local", "share", "needs-you", "hub", "needs_you_hub.py"),
                                    "--config", conf])
        self.assertTrue(os.path.isfile(argv[1]))


if __name__ == "__main__":
    unittest.main()
