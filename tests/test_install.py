"""install.sh (from /join/<code>/install.sh) and scripts/install-hub.sh --user, end to end.

Everything runs with a temporary HOME and stub `crontab`, `launchctl` and `uname` commands
first on PATH, so the real ~/.claude, ~/.config, crontab and launchd are never touched.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import time
import unittest

from support import ROOT, HubTestCase, free_port, hubmod, request

with open(os.path.join(ROOT, "scripts", "install-hub.sh")) as _fh:
    INSTALLER_VERSION = __import__("re").search(r"^INSTALLER_VERSION=(\S+)", _fh.read(), __import__("re").M).group(1)

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

    def test_bin_dir_with_shell_characters_is_refused(self):
        inv = self.invite()
        for bad in ('/tmp/a"b', "/tmp/$(touch x)", "/tmp/a`b`"):
            r = self.install(inv, "--yes", NEEDS_YOU_BIN_DIR=bad)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertIn("NEEDS_YOU_BIN_DIR", r.stderr, bad)
            self.assertFalse(os.path.exists(os.path.join(self.home, ".bashrc")), bad)
            self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "needs-you")), bad)

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
        r = self.install(inv, "--yes", "--host", "lin", STUB_UNAME="Linux", SHELL="/bin/sh")
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
        with open(os.path.join(self.home, ".profile")) as fh:  # it made it: no blank line left in it
            self.assertEqual(fh.read(), "")
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

    def test_a_missing_orca_snippet_skips_only_that(self):
        # A hub that doesn't serve orca-snippet.md (an install-hub.sh from before 0.2.2): --orca
        # died with exit 1 ("nothing was installed") after the CLI, token and flush were set up.
        inst = os.path.join(self.tmp, "inst")
        for name, (rel, _) in hubmod.DOWNLOADS.items():
            if name != "orca-snippet.md":
                os.makedirs(os.path.dirname(os.path.join(inst, rel)), exist_ok=True)
                shutil.copy(os.path.join(ROOT, rel), os.path.join(inst, rel))
        self.hub = self.make_hub("hub-o", peers=[], install_dir=inst)
        self.hub.store.ensure_token("this-mac", "owner", OWNER)
        inv = self.invite()
        r = self.install(inv, "--yes", "--host", "o1", "--orca", "--skill", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)  # the skill went on: not exit 3
        self.assertIn("Not set up: Orca snippet", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.home, ".local", "bin", "needs-you")))
        self.assertIn("needs-you is set up", json.dumps(request("GET", self.hub.url + "/v1/items", OWNER)[1]))
        r = self.install(inv, "--yes", "--host", "o1", "--orca", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)  # the only thing asked for

    def test_uninstall_leaves_no_empty_directories(self):
        # Everything the installer can set up, on a machine with none of the agents' directories:
        # the uninstall takes the directories it made and emptied back out (they used to stay:
        # ~/.claude/skills, ~/.local/bin, ~/.local/state, ~/.copilot, ~/.config/opencode, ...).
        inv = self.invite(uses=1)
        flags = ("--claude-hooks user --codex-hooks user --gemini-hooks user --opencode-plugin "
                 "--copilot-hooks user --cursor-hooks user --cline-hooks user --aider --kimi-hooks user "
                 "--grok-hooks user --skill --usage --orca --mcp codex,gemini,opencode,copilot,cursor "
                 "--agent-instructions codex,gemini,opencode --alerts").split()
        r = self.install(inv, "--yes", "--host", "all", *flags, STUB_UNAME="Linux", SHELL="/bin/sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux", SHELL="/bin/sh")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("left in place", r.stderr)
        # (~/Documents, which the Cline installer makes on a machine without one, is the
        # person's folder: never removed.)
        empty = [os.path.relpath(dp, self.home) for dp, dns, fns in os.walk(self.home)
                 if dp != self.home and not dns and not fns]
        self.assertEqual(empty, ["Documents"])

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
            self.assertEqual(fh.read(), "alias ll='ls -l'\n")  # no blank line left behind
        with open(self.cron) as fh:  # a crontab holding only our line (pipefail used to stop here)
            self.assertEqual(fh.read().strip(), "")

    def test_orca_on_path_without_the_flag_gets_a_hint(self):
        inv = self.invite(uses=2)
        hint = "Orca is installed here. If its automations should reach you, re-run with --orca"
        r = self.install(inv, "--yes", "--host", "box3", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(hint, r.stdout)  # no orca on PATH
        orca = os.path.join(self.stubs, "orca")
        with open(orca, "w") as fh:
            fh.write(STUB)
        os.chmod(orca, 0o755)
        r = self.install(inv, "--yes", "--host", "box3", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(hint, r.stdout)
        self.assertNotIn("orca", self.stub_calls())  # only looked up on PATH, never run
        r = self.install(inv, "--yes", "--host", "box3", "--orca", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(hint, r.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.home, ".config", "needs-you", "orca-snippet.md")))

    def test_auto_update_is_on_by_default_and_kept_on_rerun(self):
        inv = self.invite(uses=3)
        r = self.install(inv, "--yes", "--host", "box9", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_AUTO_UPDATE"], "1")
        self.assertIn("update  -> daily", r.stdout)
        with open(self.cron) as fh:           # the flush that runs it is scheduled
            self.assertEqual(fh.read().count("needs-you-flush"), 1)
        # Opting out sticks: a later run without either flag keeps it off.
        r = self.install(inv, "--yes", "--host", "box9", "--no-auto-update", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_AUTO_UPDATE"], "0")
        self.assertIn("update  -> off", r.stdout)
        r = self.install(inv, "--yes", "--host", "box9", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_AUTO_UPDATE"], "0")
        r = self.install(inv, "--yes", "--host", "box9", "--auto-update", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_AUTO_UPDATE"], "1")
        with open(os.path.join(self.home, ".config", "needs-you", "env")) as fh:
            self.assertEqual(fh.read().count("NEEDS_YOU_AUTO_UPDATE="), 1)
        with open(self.cron) as fh:
            self.assertEqual(fh.read().count("needs-you-flush"), 1)

    def test_older_install_without_the_setting_gets_it_on_rerun(self):
        # A machine set up before auto-update was the default has no NEEDS_YOU_AUTO_UPDATE line
        # (and maybe no flush entry): re-running the one-liner turns both on.
        inv = self.invite(uses=2)
        r = self.install(inv, "--yes", "--host", "box10", "--no-schedule", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("won't run until you schedule", r.stderr)
        env_path = os.path.join(self.home, ".config", "needs-you", "env")
        with open(env_path) as fh:
            lines = [l for l in fh if not l.startswith("NEEDS_YOU_AUTO_UPDATE=")]
        with open(env_path, "w") as fh:
            fh.writelines(lines)
        self.assertFalse(os.path.exists(self.cron))
        r = self.install(inv, "--yes", "--host", "box10", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.envfile()["NEEDS_YOU_AUTO_UPDATE"], "1")
        with open(self.cron) as fh:
            self.assertEqual(fh.read().count("needs-you-flush"), 1)

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

    def test_a_rerun_never_downgrades_the_cli(self):
        # `needs-you update` refuses to go back, but re-running the one-liner replaced a newer
        # CLI with the hub's older one.
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--host", "dg1", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        with open(cli) as fh:
            newer = re.sub(r'^VERSION = "[0-9.]+"', 'VERSION = "99.0.0"', fh.read(), count=1, flags=re.M)
        with open(cli, "w") as fh:
            fh.write(newer)
        r = self.install(inv, "--yes", "--host", "dg1", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("kept %s (99.0.0, newer than the hub's)" % cli, r.stdout)
        with open(cli) as fh:
            self.assertEqual(fh.read(), newer)

    def test_needs_you_config_is_where_the_token_goes(self):
        # The flush schedule and the CLI read NEEDS_YOU_CONFIG, but the installer wrote the
        # token to ~/.config/needs-you/env: exit 0, and a machine that could never send.
        inv = self.invite(uses=1)
        conf = os.path.join(self.home, "my conf", "ny.env")
        r = self.install(inv, "--yes", "--host", "nc1", STUB_UNAME="Linux", NEEDS_YOU_CONFIG=conf)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(conf) as fh:
            self.assertIn("NEEDS_YOU_TOKEN=", fh.read())
        self.assertEqual(stat.S_IMODE(os.stat(conf).st_mode), 0o600)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "needs-you", "env")))
        h = subprocess.run([os.path.join(self.home, ".local", "bin", "needs-you"), "health"],
                           env=self.env(NEEDS_YOU_CONFIG=conf), capture_output=True, text=True, timeout=60)
        self.assertEqual(h.returncode, 0, h.stdout + h.stderr)
        r = self.install(inv, "--yes", "--host", "nc1", STUB_UNAME="Linux", NEEDS_YOU_CONFIG=conf)
        self.assertIn("kept the existing token", r.stdout)  # a re-run finds it there

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

    def test_a_broken_agent_config_skips_that_agent_only(self):
        # Gemini allows // comments in settings.json, which the merge can't read: the install
        # used to stop there (exit 2), before the opencode plugin, the skill and the summary.
        gemini = os.path.join(self.home, ".gemini")
        os.makedirs(gemini)
        broken = '{\n  // my settings\n  "theme": "dark"\n}\n'
        with open(os.path.join(gemini, "settings.json"), "w") as fh:
            fh.write(broken)
        inv = self.invite(uses=3)
        r = self.install(inv, "--yes", "--gemini-hooks", "user", "--opencode-plugin", "--skill",
                         "--host", "box6", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.home, ".config", "opencode", "plugins", "needs-you.js")))
        self.assertTrue(os.path.isfile(os.path.join(self.home, ".claude", "skills", "needs-you", "SKILL.md")))
        self.assertIn("Done.", r.stdout)
        self.assertIn("Not set up: Gemini CLI hooks", r.stdout + r.stderr)
        with open(os.path.join(gemini, "settings.json")) as fh:
            self.assertEqual(fh.read(), broken)  # untouched
        # Nothing of what was asked for could be set up: exit 3 (documented in --help)
        r = self.install(inv, "--yes", "--gemini-hooks", "user", "--host", "box6", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("Not set up: Gemini CLI hooks", r.stdout + r.stderr)
        self.assertTrue(os.access(os.path.join(self.home, ".local", "bin", "needs-you"), os.X_OK))
    def test_copilot_hooks(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--copilot-hooks", "user", "--alerts", "--host", "box6", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Copilot CLI", r.stdout)
        cp = os.path.join(self.home, ".copilot", "hooks")
        with open(os.path.join(cp, "needs-you.json")) as fh:
            self.assertIn("agentStop", json.load(fh)["hooks"])
        self.assertTrue(os.access(os.path.join(cp, "needs-you-hook.sh"), os.X_OK))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))  # Claude untouched
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        self.assertEqual(checks["copilot hooks"]["status"], "OK", checks["copilot hooks"])
        self.assertIn("alerts on", checks["copilot hooks"]["detail"])
        self.assertNotIn("Copilot", checks["update"]["detail"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(cp, "needs-you.json")))
        self.assertFalse(os.path.exists(os.path.join(cp, "needs-you-hook.sh")))
        r = self.install(inv, "--yes", "--copilot-hooks", "project")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--copilot-hooks must be user or none", r.stderr)

    def test_kimi_and_grok_hooks(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--kimi-hooks", "user", "--grok-hooks", "user", "--alerts",
                         "--host", "box7", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Kimi Code", r.stdout)
        self.assertIn("Grok Build", r.stdout)
        kimi = os.path.join(self.home, ".kimi-code")
        with open(os.path.join(kimi, "config.toml")) as fh:
            self.assertIn("# needs-you (managed by install-kimi-hooks.sh", fh.read())
        self.assertTrue(os.access(os.path.join(kimi, "hooks", "needs-you-hook.sh"), os.X_OK))
        grok = os.path.join(self.home, ".grok", "hooks")
        with open(os.path.join(grok, "needs-you.json")) as fh:
            self.assertIn("Notification", json.load(fh)["hooks"])
        self.assertTrue(os.access(os.path.join(grok, "needs-you-hook.sh"), os.X_OK))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))  # Claude untouched
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        for name in ("kimi hooks", "grok hooks"):
            self.assertEqual(checks[name]["status"], "OK", checks[name])
            self.assertIn("alerts on", checks[name]["detail"])
        self.assertNotIn("Kimi", checks["update"]["detail"])
        self.assertNotIn("Grok", checks["update"]["detail"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(os.path.join(kimi, "config.toml")) as fh:
            self.assertNotIn("needs-you", fh.read())
        self.assertFalse(os.path.exists(os.path.join(kimi, "hooks", "needs-you-hook.sh")))
        self.assertFalse(os.path.exists(os.path.join(grok, "needs-you.json")))
        for flag in ("--kimi-hooks", "--grok-hooks"):
            r = self.install(inv, "--yes", flag, "project")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("%s must be user or none" % flag, r.stderr)

    def test_kimi_config_it_cant_append_to_is_skipped(self):
        kimi = os.path.join(self.home, ".kimi-code")
        os.makedirs(kimi)
        with open(os.path.join(kimi, "config.toml"), "w") as fh:
            fh.write("hooks = []\n")
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--kimi-hooks", "user", "--grok-hooks", "user", "--host", "box8",
                         STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Not set up: Kimi Code hooks", r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.home, ".grok", "hooks", "needs-you.json")))
        with open(os.path.join(kimi, "config.toml")) as fh:
            self.assertEqual(fh.read(), "hooks = []\n")

    def test_cursor_cline_aider(self):
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--cursor-hooks", "user", "--cline-hooks", "user", "--aider", "--alerts",
                         "--host", "box7", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for label in ("Cursor (~/.cursor/hooks.json; finished turns only)", "Cline (", "Aider ("):
            self.assertIn(label, r.stdout)
        with open(os.path.join(self.home, ".cursor", "hooks.json")) as fh:
            self.assertEqual(sorted(json.load(fh)["hooks"]), ["beforeSubmitPrompt", "sessionEnd", "stop"])
        self.assertTrue(os.access(os.path.join(self.home, ".cursor", "hooks", "needs-you-hook.sh"), os.X_OK))
        self.assertTrue(os.access(os.path.join(self.home, "Documents", "Cline", "Hooks", "TaskComplete"), os.X_OK))
        with open(os.path.join(self.home, ".aider.conf.yml")) as fh:
            self.assertIn("notifications-command:", fh.read())
        self.assertFalse(os.path.exists(os.path.join(self.home, ".claude")))  # Claude untouched
        cli = os.path.join(self.home, ".local", "bin", "needs-you")
        d = subprocess.run([cli, "doctor", "--json"], env=self.env(NEEDS_YOU_GH="none"),
                           capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        for name in ("cursor hooks", "cline hooks", "aider notifications"):
            self.assertEqual(checks[name]["status"], "OK", checks[name])
            self.assertIn("alerts on", checks[name]["detail"])
        self.assertEqual(checks["update"]["status"], "OK", checks["update"])
        r = self.install(inv, "--uninstall", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".cursor", "hooks", "needs-you-hook.sh")))
        cline = os.path.join(self.home, "Documents", "Cline", "Hooks")
        self.assertEqual(os.listdir(cline) if os.path.isdir(cline) else [], [])
        self.assertFalse(os.path.exists(os.path.join(self.home, ".aider.conf.yml")))
        for flag in ("--cursor-hooks", "--cline-hooks"):
            r = self.install(inv, "--yes", flag, "project")
            self.assertIn("%s must be user or none" % flag, r.stderr)

    def test_aider_config_not_safe_to_change(self):
        # Aider's own notifications-command: not replaced; the lines are printed, and with
        # nothing else asked for the installer exits 3.
        mine = "model: gpt-4o\nnotifications-command: say done\n"
        with open(os.path.join(self.home, ".aider.conf.yml"), "w") as fh:
            fh.write(mine)
        inv = self.invite(uses=1)
        r = self.install(inv, "--yes", "--aider", "--host", "box8", STUB_UNAME="Linux")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("Not set up: Aider notifications", r.stdout + r.stderr)
        self.assertIn("notifications: true\nnotifications-command: '\"$HOME/.config/needs-you/aider/hooks/"
                      "needs-you-hook.sh\" notify aider'", r.stdout)
        with open(os.path.join(self.home, ".aider.conf.yml")) as fh:
            self.assertEqual(fh.read(), mine)

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
            self.assertIn("Installed the needs-you hub %s." % hubmod.VERSION, r.stdout)

            # a token in the DB before the upgrade
            admin = os.path.join(home, ".local", "bin", "needs-you-admin")
            r = subprocess.run([admin, "token", "add", "keep-me"], env=env, capture_output=True,
                               text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            db = cfg["db"]
            db_ino = os.stat(db).st_ino
            # as if an older release were installed
            installed = os.path.join(share, "hub", "needs_you_hub.py")
            with open(installed) as fh:
                old = re.sub(r'(?m)^VERSION = "[^"]*"', 'VERSION = "0.0.1"', fh.read())
            with open(installed, "w") as fh:
                fh.write(old)

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
            self.assertIn("Upgraded the needs-you hub from 0.0.1 to %s. Config and database kept (the hub backs "
                          "the database up before it migrates it)." % hubmod.VERSION, r.stdout)
            r = subprocess.run([BASH, script, "--user", "--no-start"], env=env, capture_output=True, text=True, timeout=120)
            self.assertIn("Reinstalled the needs-you hub %s (the same version). Config and database kept." % hubmod.VERSION,
                          r.stdout)
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

    def test_every_download_is_installed(self):
        # The hub serves /dl/<name> from its install directory: a file install-hub.sh doesn't
        # copy is missing from the manifest, so invites from that hub fail --orca, --mcp,
        # --agent-instructions and --usage, and `needs-you update` never refreshes it.
        self.install("--hub-id", "hub-a")
        prefix = os.path.join(self.home, ".local", "share", "needs-you")
        missing = [name for name, (rel, _) in sorted(hubmod.DOWNLOADS.items())
                   if not os.path.isfile(os.path.join(prefix, rel))]
        self.assertEqual(missing, [])
        self.assertEqual(sorted(hubmod.download_manifest(prefix)["files"]), sorted(hubmod.DOWNLOADS))

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


class InstallHubJoin(HubTestCase):
    """install-hub.sh --user --join <peer invite>: the server pairs with a hub (here an
    in-process one standing in for the Mac's) without a secret on the command line or the
    terminal. --no-start: no systemd is touched."""

    def setUp(self):
        super().setUp()
        self.mac = self.make_hub("mac", peer_secret="", maintenance_seconds=0)
        self.mac.store.ensure_token("this-mac", "owner", OWNER)
        self.home = os.path.join(self.tmp, "home")
        stub = os.path.join(self.tmp, "stub")
        os.makedirs(self.home)
        os.makedirs(stub)
        with open(os.path.join(stub, "tailscale"), "w") as fh:  # not on a tailnet
            fh.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(stub, "tailscale"), 0o755)
        self.env = {"HOME": self.home, "PATH": stub + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
                    # no real gh and never the real GitHub: a stand-in release (fake_release)
                    "NEEDS_YOU_GH": "none", "NEEDS_YOU_RELEASE_OFFLINE": "1"}
        self.script = os.path.join(ROOT, "scripts", "install-hub.sh")
        self.port = free_port()

    def fake_release(self, version=None, tar_version=None, manifest_version=None, tamper_sums=False,
                     private=True):
        """A stand-in GitHub release (SHA256SUMS, the server tarball, release-manifest.json)
        built from this checkout, and a fake `gh` that serves it and logs each call to
        self.gh_log. `tar_version`/`manifest_version`: what the tarball's top directory and the
        manifest claim, if not `version`. Returns env for the installer."""
        import hashlib
        import tarfile
        v = version or INSTALLER_VERSION
        rel = os.path.join(self.tmp, "release")
        shutil.rmtree(rel, ignore_errors=True)
        os.makedirs(rel)
        tarball = "needs-you-server-%s.tar.gz" % v
        with tarfile.open(os.path.join(rel, tarball), "w:gz") as tf:
            for d in ("hub", "cli", "scripts", "deploy", "integrations"):
                tf.add(os.path.join(ROOT, d), "needs-you-%s/%s" % (tar_version or v, d),
                       filter=lambda ti: None if "__pycache__" in ti.name else ti)

        def sha(name):
            with open(os.path.join(rel, name), "rb") as fh:
                return hashlib.sha256(fh.read()).hexdigest()
        with open(os.path.join(rel, "release-manifest.json"), "w") as fh:
            json.dump({"schema": 1, "version": manifest_version or v,
                       "assets": [{"name": tarball, "sha256": sha(tarball)}]}, fh)
        with open(os.path.join(rel, "SHA256SUMS"), "w") as fh:
            for n in (tarball, "release-manifest.json"):
                fh.write("%s  %s\n" % ("0" * 64 if tamper_sums and n == tarball else sha(n), n))
        self.gh_log = os.path.join(self.tmp, "gh.log")
        gh = os.path.join(self.tmp, "stub", "gh")
        with open(gh, "w") as fh:
            fh.write("""#!/bin/sh
# fake gh: release download copies the stand-in release; no attestations; the repo is private
echo "$*" >> "%s"
case "$1 $2" in
  "release download")
    dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir=$2; shift; done
    cp "%s"/* "$dir"/ ;;
  "attestation verify") echo "no attestations found" >&2; exit 1 ;;
  "api repos/tayharris/needs-you") echo %s ;;
  *) exit 2 ;;
esac
""" % (self.gh_log, rel, "true" if private else "false"))
        os.chmod(gh, 0o755)
        return dict(self.env, NEEDS_YOU_GH=gh)

    def peer_link(self):
        status, inv = request("POST", self.mac.url + "/v1/invites", OWNER, {"name": "server", "role": "peer"})
        self.assertEqual(status, 201, inv)
        return inv["join_url"]

    def install(self, *args, stdin=""):
        return subprocess.run([BASH, self.script, "--user", "--no-start", "--bind", "127.0.0.1",
                               "--port", str(self.port), "--hub-id", "srv",
                               "--public-url", "http://127.0.0.1:%d" % self.port] + list(args),
                              input=stdin, env=self.env, capture_output=True, text=True, timeout=120)

    def stub(self, name, body):
        path = os.path.join(self.tmp, "stub", name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def test_the_one_liner_keeps_the_code_out_of_sudos_command_line(self):
        """The peer invite's install_command, run as it is printed by a shell, with stand-ins
        for curl (this checkout's installer), sudo (records its argv, adds the test's --user
        flags) and crontab: it pairs, and sudo never sees the code."""
        status, inv = request("POST", self.mac.url + "/v1/invites", OWNER, {"name": "server", "role": "peer"})
        self.assertEqual(status, 201, inv)
        sudo_log = os.path.join(self.tmp, "sudo.log")
        self.stub("curl", 'exec cat "%s"\n' % self.script)
        self.stub("sudo", 'printf "%%s\\n" "$*" >> "%s"\nexec "$@" $NEEDS_YOU_TEST_ARGS\n' % sudo_log)
        self.stub("crontab", "exit 0\n")
        env = dict(self.fake_release(), NEEDS_YOU_TEST_ARGS="--user --no-start --bind 127.0.0.1 --port %d "
                   "--hub-id srv --public-url http://127.0.0.1:%d" % (self.port, self.port))
        cwd = os.path.join(self.tmp, "empty")
        os.makedirs(cwd, exist_ok=True)
        r = subprocess.run([BASH, "-c", inv["install_command"]], cwd=cwd, env=env, capture_output=True,
                           text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        (link,) = self.mac.store.peer_links()
        self.assertEqual(link["hub_id"], "srv")
        with open(sudo_log) as fh:
            argv = fh.read()
        self.assertEqual(argv, "bash -s -- --join -\n")
        self.assertNotIn("nyi_", argv)
        self.assertNotIn(inv["code"], r.stdout + r.stderr)

    def test_join_dash_reads_the_link_from_stdin(self):
        r = self.install("--join", "-", stdin="")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no peer invite link on stdin", r.stderr)
        r = self.install("--join", "-", stdin="  %s  \n" % self.peer_link())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual([l["hub_id"] for l in self.mac.store.peer_links()], ["srv"])

    def test_the_admin_wrapper_hands_the_link_over_on_stdin(self):
        """deploy/needs-you-admin.sh runs the tool with sudo -u needs-you: a link given as an
        argument goes to it on stdin, as `peer join -`, never on sudo's command line."""
        log = os.path.join(self.tmp, "sudo.log")
        self.stub("id", "echo someone\n")
        self.stub("sudo", 'printf "%%s\\n" "$*" >> "%s"\nprintf "stdin:%%s\\n" "$(cat)" >> "%s"\n' % (log, log))
        wrapper = os.path.join(ROOT, "deploy", "needs-you-admin.sh")
        link = "http://hub-a.example.ts.net:8765/join/nyi_secretcode"
        for args, want in ((["peer", "join", link], "peer join -"),
                           (["--json", "peer", "join", link], "--json peer join -")):
            open(log, "w").close()
            r = subprocess.run(["sh", wrapper] + args, env=self.env, capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(log) as fh:
                argv, got = fh.read().splitlines()
            self.assertTrue(argv.endswith(want), argv)
            self.assertNotIn("nyi_", argv)
            self.assertEqual(got, "stdin:" + link)
        open(log, "w").close()
        r = subprocess.run(["sh", wrapper, "peer", "list"], input="", env=self.env, capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(log) as fh:
            self.assertTrue(fh.read().splitlines()[0].endswith("--config /etc/needs-you/hub.json peer list"))

    def test_join_pairs_both_hubs_and_never_shows_the_secret(self):
        r = self.install("--join", self.peer_link())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        (link,) = self.mac.store.peer_links()
        self.assertEqual((link["url"], link["hub_id"]), ("http://127.0.0.1:%d" % self.port, "srv"))
        self.assertNotIn(link["secret"], r.stdout + r.stderr)
        self.assertNotIn("nyp_", r.stdout + r.stderr)
        self.assertNotIn("needsyou://", r.stdout)  # no owner invite: the Mac's owner replicates here
        self.assertIn("now replicates with", r.stdout)
        conf = os.path.join(self.home, ".config", "needs-you", "hub.json")
        with open(conf) as fh:
            cfg = json.load(fh)
        self.assertNotIn("peer_secret", cfg)  # the pair's secret lives in the database
        self.assertEqual(cfg.get("peers"), [])
        import sqlite3
        db = sqlite3.connect(cfg["db"])
        try:
            rows = db.execute("SELECT url, hub_id, secret FROM peer_links").fetchall()
        finally:
            db.close()
        self.assertEqual(rows, [(self.mac.url, "mac", link["secret"])])
        self.assertEqual(stat.S_IMODE(os.stat(cfg["db"]).st_mode), 0o600)
        self.assertIn("http://127.0.0.1:%d" % self.port, self.mac.hub_urls())

        # the admin wrapper lists it without the secret
        admin = os.path.join(self.home, ".local", "bin", "needs-you-admin")
        r = subprocess.run([admin, "peer", "list"], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(self.mac.url, r.stdout)
        self.assertNotIn(link["secret"], r.stdout)

    def piped(self, script_text, *args, env=None):
        """`curl <release>/install-hub.sh | bash -s -- ...`: the script on stdin, run from an
        empty directory with no checkout anywhere near it."""
        cwd = os.path.join(self.tmp, "empty")
        os.makedirs(cwd, exist_ok=True)
        return subprocess.run([BASH, "-s", "--", "--user", "--no-start", "--bind", "127.0.0.1",
                               "--port", str(self.port), "--hub-id", "srv",
                               "--public-url", "http://127.0.0.1:%d" % self.port] + list(args),
                              input=script_text, cwd=cwd, env=env or self.env, capture_output=True,
                              text=True, timeout=120)

    def _script(self):
        with open(os.path.join(ROOT, "scripts", "install-hub.sh")) as fh:
            return fh.read()

    def test_the_one_liner_comes_from_the_github_release(self):
        status, inv = request("POST", self.mac.url + "/v1/invites", OWNER, {"name": "server", "role": "peer"})
        self.assertEqual(status, 201)
        self.assertEqual(inv["install_command"],
                         "(curl -fsSL https://github.com/tayharris/needs-you/releases/download/v%s/install-hub.sh"
                         " && echo '%s') | sudo bash -s -- --join -" % (hubmod.VERSION, inv["join_url"]))
        # the hub serves no server code (only the sender's files)
        from support import OPENER
        import urllib.error
        for name in ("install-hub.sh", "needs_you_hub.py", "needs-you-hub.service"):
            with self.assertRaises(urllib.error.HTTPError):
                OPENER.open(self.mac.url + "/dl/" + name, timeout=10)

    def test_piped_installer_installs_its_own_release(self):
        link = self.peer_link()
        tmpdir = os.path.join(self.tmp, "t")
        os.makedirs(tmpdir)
        r = self.piped(self._script(), "--join", link, env=dict(self.fake_release(), TMPDIR=tmpdir))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(os.listdir(tmpdir), [])  # the downloaded copy is gone
        self.assertIn("installing release v%s from GitHub" % INSTALLER_VERSION, r.stdout)
        self.assertNotIn("nyp_", r.stdout + r.stderr)
        with open(self.gh_log) as fh:
            calls = fh.read()
        self.assertIn("release download v%s --repo tayharris/needs-you" % INSTALLER_VERSION, calls)
        share = os.path.join(self.home, ".local", "share", "needs-you")
        for rel in ("hub/needs_you_hub.py", "hub/needs_you_admin.py", "cli/needs-you",
                    "integrations/claude-code/needs-you-hook.sh", "integrations/kimi/kimi-hooks.toml"):
            with open(os.path.join(share, rel), "rb") as fh, open(os.path.join(ROOT, rel), "rb") as src:
                self.assertEqual(fh.read(), src.read(), rel)
        (link_row,) = self.mac.store.peer_links()
        self.assertEqual(link_row["hub_id"], "srv")

    def test_a_hub_claiming_an_older_version_changes_nothing(self):
        """Rollback: the inviting hub says it runs 0.0.1 (old, authentic, vulnerable code).
        The installer still downloads only its own release; the hub supplies no code."""
        old = hubmod.VERSION
        hubmod.VERSION = "0.0.1"
        self.addCleanup(setattr, hubmod, "VERSION", old)
        status, inv = request("POST", self.mac.url + "/v1/invites", OWNER, {"name": "server", "role": "peer"})
        self.assertIn("/download/v0.0.1/", inv["install_command"])
        r = self.piped(self._script(), "--join", inv["join_url"], env=self.fake_release())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(self.gh_log) as fh:
            calls = fh.read()
        self.assertNotIn("v0.0.1", calls)
        self.assertIn("release download v%s " % INSTALLER_VERSION, calls)

    def test_a_release_for_another_version_is_refused(self):
        for kw, why in (({"tar_version": "0.0.1"}, "not needs-you %s" % INSTALLER_VERSION),
                        ({"manifest_version": "0.0.1"}, "isn't for this installer's version"),
                        ({"tamper_sums": True}, "doesn't match its SHA256SUMS")):
            with self.subTest(**kw):
                r = self.piped(self._script(), "--join", self.peer_link(), env=self.fake_release(**kw))
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(why, r.stderr)
                self.assertFalse(os.path.exists(os.path.join(self.home, ".local", "share", "needs-you")))
        self.assertEqual(self.mac.store.peer_links(), [])  # no link was spent

    def test_the_release_repo_is_the_clis(self):
        import re
        with open(os.path.join(ROOT, "cli", "needs-you")) as fh:
            cli = re.search(r'^RELEASE_REPO = "([^"]+)"', fh.read(), re.M).group(1)
        self.assertIn('REPO = "%s"  # fixed here' % cli, self._script())
        self.assertEqual(hubmod.RELEASE_REPO, cli)

    def test_the_installer_version_is_the_release(self):
        with open(os.path.join(ROOT, "VERSION")) as fh:
            self.assertEqual(INSTALLER_VERSION, fh.read().strip())

    def test_unreachable_github_refuses(self):
        r = self.piped(self._script(), "--join", self.peer_link())  # no gh, GitHub "offline"
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("GitHub isn't reachable", r.stderr)
        self.assertIn("install from a checkout", r.stderr)
        self.assertEqual(self.mac.store.peer_links(), [])

    def test_a_public_release_without_provenance_is_refused(self):
        link = self.peer_link()
        r = self.piped(self._script(), "--join", link, env=self.fake_release(private=False))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no valid build provenance", r.stderr)

    def test_a_checkout_with_a_symlink_is_refused_as_root(self):
        src = self._checkout_copy()
        target = os.path.join(src, "hub", "needs_you_admin.py")
        os.rename(target, target + ".real")
        os.symlink(target + ".real", target)
        r = self._run_checkout(src)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)

    def _checkout_copy(self):
        src = os.path.join(self.tmp, "checkout")
        for d in ("hub", "cli", "deploy", "scripts", "integrations"):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(src, d),
                            ignore=shutil.ignore_patterns("__pycache__"))
        for d, _dirs, files in os.walk(src):  # whatever the umask: only the owner may write
            for p in [d] + [os.path.join(d, f) for f in files]:
                os.chmod(p, os.stat(p).st_mode & ~0o022)
        return src

    def _run_checkout(self, src, env=None):
        return subprocess.run([BASH, os.path.join(src, "scripts", "install-hub.sh"), "--user", "--no-start",
                               "--no-invite", "--bind", "127.0.0.1", "--hub-id", "srv"],
                              env=dict(env or self.env, NEEDS_YOU_INSTALL_CHECK_OWNERSHIP="1"),
                              capture_output=True, text=True, timeout=120)

    def test_as_root_only_the_private_copy_is_installed(self):
        """As root a clean checkout installs, from the private copy made while checking (each
        file is read through the descriptor its checks ran on)."""
        src = self._checkout_copy()
        r = self._run_checkout(src)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        share = os.path.join(self.home, ".local", "share", "needs-you")
        with open(os.path.join(share, "hub", "needs_you_hub.py"), "rb") as a, \
                open(os.path.join(src, "hub", "needs_you_hub.py"), "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_piped_run_never_takes_code_from_the_directory_around_it(self):
        """Under `curl | sudo bash` $0 is "bash": the script used to treat the parent of the
        current directory as a checkout, so a hub/ planted there was installed and run."""
        _, inv = request("POST", self.mac.url + "/v1/invites", OWNER, {"name": "server", "role": "peer"})
        planted = os.path.join(self.tmp, "shared")
        os.makedirs(os.path.join(planted, "hub"))
        os.makedirs(os.path.join(planted, "work"))
        with open(os.path.join(planted, "hub", "needs_you_hub.py"), "w") as fh:
            fh.write("PLANTED = True\n")
        with open(os.path.join(ROOT, "scripts", "install-hub.sh")) as fh:
            script = fh.read()
        r = subprocess.run(["bash", "-s", "--", "--user", "--no-start", "--bind", "127.0.0.1",
                            "--port", str(self.port), "--hub-id", "srv",
                            "--public-url", "http://127.0.0.1:%d" % self.port, "--join", inv["join_url"]],
                           input=script, cwd=os.path.join(planted, "work"), env=self.fake_release(), executable=BASH,
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("installing release v%s from GitHub" % INSTALLER_VERSION, r.stdout)
        with open(os.path.join(self.home, ".local", "share", "needs-you", "hub", "needs_you_hub.py")) as fh:
            self.assertNotIn("PLANTED", fh.read())

    def test_a_checkout_others_can_write_is_refused_when_run_as_root(self):
        """As root, a checkout (or its files) writable by others, or owned by someone other
        than root or the sudo user, is refused. Forced here by the check's test switch."""
        src = os.path.join(self.tmp, "checkout")
        for d in ("hub", "cli", "deploy", "scripts", "integrations"):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(src, d),
                            ignore=shutil.ignore_patterns("__pycache__"))
        for d, _dirs, files in os.walk(src):  # whatever the umask: only the owner may write
            for p in [d] + [os.path.join(d, f) for f in files]:
                os.chmod(p, os.stat(p).st_mode & ~0o022)
        os.chmod(os.path.join(src, "hub", "needs_you_hub.py"), 0o666)
        r = subprocess.run([BASH, os.path.join(src, "scripts", "install-hub.sh"), "--user", "--no-start",
                            "--no-invite", "--bind", "127.0.0.1", "--hub-id", "srv"],
                           env=dict(self.env, NEEDS_YOU_INSTALL_CHECK_OWNERSHIP="1"),
                           capture_output=True, text=True, timeout=120)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("writable by others", r.stderr)
        os.chmod(os.path.join(src, "hub", "needs_you_hub.py"), 0o644)
        r = subprocess.run([BASH, os.path.join(src, "scripts", "install-hub.sh"), "--user", "--no-start",
                            "--no-invite", "--bind", "127.0.0.1", "--hub-id", "srv"],
                           env=dict(self.env, NEEDS_YOU_INSTALL_CHECK_OWNERSHIP="1"),
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_used_or_bad_link_fails_loudly(self):
        link = self.peer_link()
        self.assertEqual(self.install("--join", link).returncode, 0)
        r = self.install("--join", link)  # one use
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown, expired or already used", r.stderr)
        self.assertIn("make a new peer invite", r.stderr)
        r = self.install("--join", "needsyou://connect?hub=x&code=nyi_x")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--join takes a peer invite link", r.stderr)


if __name__ == "__main__":
    unittest.main()
