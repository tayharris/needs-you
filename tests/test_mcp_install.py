"""The MCP server and the agent instructions as the invite installer sets them up:
`--mcp AGENTS` and `--agent-instructions AGENTS`, the CLI's `install-mcp` and
`install-instructions` they run, `uninstall-hooks --mcp/--instructions`, doctor and
`needs-you update`.

Everything runs with a temporary HOME (and a stub `claude`, `crontab`, `launchctl` and
`uname` first on PATH), so the real ~/.claude, ~/.codex, ~/.gemini, ~/.config and crontab
are never touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import test_install
from support import CLI, OPENER, ROOT, HubTestCase, request
import test_cli_update
from test_cli_update import FakeHub, current_files, read  # noqa: F401 (functions only: no TestCase)

MCP = os.path.join(ROOT, "integrations", "mcp", "needs_you_mcp.py")
INSTR = os.path.join(ROOT, "integrations", "agent-instructions", "needs-you.md")
REAL_HOME = os.path.expanduser("~")

# A stand-in for Claude Code's `claude mcp add-json/remove --scope user`: it edits
# $HOME/.claude.json the way the real one documents (user scope: top-level mcpServers).
CLAUDE_STUB = r'''#!/usr/bin/env python3
import json, os, sys
home = os.environ["HOME"]
with open(os.path.join(home, "claude-calls.log"), "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
path = os.path.join(home, ".claude.json")
try:
    data = json.load(open(path))
except (OSError, ValueError):
    data = {}
a = sys.argv[1:]
if a[:2] == ["mcp", "add-json"] and "--scope" in a and a[a.index("--scope") + 1] == "user":
    rest = [x for i, x in enumerate(a[2:]) if x != "--scope" and a[2:][i - 1] != "--scope"]
    data.setdefault("mcpServers", {})[rest[0]] = json.loads(rest[1])
elif a[:2] == ["mcp", "remove"]:
    name = a[2]
    if name not in data.get("mcpServers", {}):
        sys.exit(1)
    del data["mcpServers"][name]
else:
    sys.exit(2)
json.dump(data, open(path, "w"), indent=2)
'''


class CliCase(unittest.TestCase):
    """The CLI and the server installed side by side in a temp HOME, as the installer does."""

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="ny-mcp-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.home, ".local", "bin")
        self.stubs = os.path.join(self.tmp, "stubs")
        for d in (self.bin, self.stubs):
            os.makedirs(d)
        self.assertNotEqual(self.home, REAL_HOME)
        self.cli = os.path.join(self.bin, "needs-you")
        self.server = os.path.join(self.bin, "needs-you-mcp")
        shutil.copy(CLI, self.cli)
        shutil.copy(MCP, self.server)
        os.chmod(self.cli, 0o755)
        os.chmod(self.server, 0o755)
        claude = os.path.join(self.stubs, "claude")
        with open(claude, "w") as fh:
            fh.write(CLAUDE_STUB)
        os.chmod(claude, 0o755)
        self.python = shutil.which("python3", path="/usr/bin:/bin")

    def run_cli(self, *args, path=None, **env):
        e = {"HOME": self.home, "PATH": path or (self.stubs + ":/usr/bin:/bin"), "LANG": "C"}
        e.update(env)
        return subprocess.run([sys.executable, self.cli] + list(args), env=e, capture_output=True, text=True,
                              timeout=60, cwd=self.tmp)

    def p(self, *parts):
        return os.path.join(self.home, *parts)

    def write(self, rel, text):
        path = self.p(rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def text(self, rel):
        with open(self.p(rel)) as fh:
            return fh.read()

    def json(self, rel):
        return json.loads(self.text(rel))

    def backups(self, rel):
        d = os.path.dirname(self.p(rel))
        return sorted(f for f in os.listdir(d) if f.startswith(os.path.basename(rel) + ".bak-"))


class InstallMcp(CliCase):
    def seed(self):
        """Configs with the person's own settings in them (Claude's file: written by `claude`)."""
        self.write(".claude.json", json.dumps({"numStartups": 3, "mcpServers": {"mine": {"command": "x"}}}))
        self.write(".codex/config.toml", 'model = "o3"\n\n[mcp_servers.docs]\ncommand = "docs-mcp"\n')
        self.write(".gemini/settings.json", json.dumps({"theme": "dark", "mcpServers": {"mine": {"command": "y"}}}))
        # opencode and Copilot CLI: no config yet

    def test_registers_with_every_agent_idempotently(self):
        self.seed()
        r = self.run_cli("install-mcp", "claude,codex,gemini,opencode,copilot")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        server = self.server
        claude = self.json(".claude.json")
        self.assertEqual(claude["numStartups"], 3)
        self.assertEqual(claude["mcpServers"]["mine"], {"command": "x"})
        self.assertEqual(claude["mcpServers"]["needs-you"],
                         {"type": "stdio", "command": self.python, "args": [server]})
        toml = self.text(".codex/config.toml")
        self.assertTrue(toml.startswith('model = "o3"\n\n[mcp_servers.docs]\ncommand = "docs-mcp"\n'))
        self.assertIn('[mcp_servers.needs-you]\ncommand = "%s"\nargs = ["%s"]\n' % (self.python, server), toml)
        if sys.version_info >= (3, 11):
            import tomllib  # only to check the TOML parses; the CLI never needs it
            parsed = tomllib.loads(toml)
            self.assertEqual(parsed["mcp_servers"]["needs-you"], {"command": self.python, "args": [server]})
            self.assertEqual(parsed["mcp_servers"]["docs"], {"command": "docs-mcp"})
        gem = self.json(".gemini/settings.json")
        self.assertEqual(gem["theme"], "dark")
        self.assertEqual(gem["mcpServers"]["needs-you"], {"command": self.python, "args": [server]})
        oc = self.json(".config/opencode/opencode.json")
        self.assertEqual(oc["mcp"]["needs-you"], {"type": "local", "command": [self.python, server], "enabled": True})
        cp = self.json(".copilot/mcp-config.json")
        self.assertEqual(cp["mcpServers"]["needs-you"],
                         {"type": "local", "command": self.python, "args": [server], "tools": ["*"]})
        # the files that were there are backed up; the new ones have nothing to back up
        self.assertEqual(len(self.backups(".codex/config.toml")), 1)
        self.assertEqual(len(self.backups(".gemini/settings.json")), 1)
        self.assertEqual(self.backups(".copilot/mcp-config.json"), [])
        self.assertEqual(oct(os.stat(self.p(".copilot/mcp-config.json")).st_mode & 0o777), "0o600")

        # again: nothing changes, no new backups, `claude` isn't asked to add it twice
        before = {rel: self.text(rel) for rel in (".claude.json", ".codex/config.toml", ".gemini/settings.json",
                                                  ".config/opencode/opencode.json", ".copilot/mcp-config.json")}
        r = self.run_cli("install-mcp", "claude,codex,gemini,opencode,copilot")
        self.assertEqual(r.returncode, 0, r.stderr)
        for rel, text in before.items():
            self.assertEqual(self.text(rel), text, rel)
        self.assertEqual(len(self.backups(".codex/config.toml")), 1)
        self.assertEqual(self.text("claude-calls.log").count("add-json"), 1)

    def test_uninstall_removes_exactly_what_was_added(self):
        self.seed()
        before = {rel: self.text(rel) for rel in (".claude.json", ".codex/config.toml", ".gemini/settings.json")}
        self.assertEqual(self.run_cli("install-mcp", "claude,codex,gemini,opencode,copilot").returncode, 0)
        r = self.run_cli("uninstall-hooks", "--mcp", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would remove the needs-you MCP server from ~/.codex/config.toml", r.stdout)
        self.assertIn("needs-you", self.json(".gemini/settings.json")["mcpServers"])
        r = self.run_cli("uninstall-hooks", "--mcp")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.text(".codex/config.toml"), before[".codex/config.toml"])
        self.assertEqual(self.json(".gemini/settings.json"), json.loads(before[".gemini/settings.json"]))
        self.assertEqual(self.json(".claude.json"), json.loads(before[".claude.json"]))
        self.assertIn("mcp remove needs-you --scope user", self.text("claude-calls.log"))
        # files needs-you created are gone again, and so is the server
        self.assertFalse(os.path.exists(self.p(".config/opencode/opencode.json")))
        self.assertFalse(os.path.exists(self.p(".copilot/mcp-config.json")))
        self.assertFalse(os.path.exists(self.server))
        self.assertTrue(os.path.exists(self.cli))
        # nothing left: a second run finds nothing and changes nothing
        r = self.run_cli("uninstall-hooks", "--mcp")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.text(".codex/config.toml"), before[".codex/config.toml"])

    def test_plain_uninstall_hooks_includes_the_mcp_server(self):
        self.assertEqual(self.run_cli("install-mcp", "gemini").returncode, 0)
        self.write(".gemini/settings.json", json.dumps(dict(self.json(".gemini/settings.json"), theme="dark")))
        r = self.run_cli("uninstall-hooks")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.json(".gemini/settings.json"), {"theme": "dark"})

    def test_a_symlink_or_broken_config_skips_that_agent_only(self):
        real = self.write("dotfiles/settings.json", "{}")
        os.makedirs(self.p(".gemini"))
        os.symlink(real, self.p(".gemini", "settings.json"))
        self.write(".copilot/mcp-config.json", "{not json")
        r = self.run_cli("install-mcp", "gemini,copilot,codex")
        self.assertEqual(r.returncode, 1)
        self.assertIn("is a symlink", r.stderr)
        self.assertIn("can't read it", r.stderr)
        with open(real) as fh:
            self.assertEqual(fh.read(), "{}")                    # never written through the link
        self.assertEqual(self.text(".copilot/mcp-config.json"), "{not json")
        self.assertIn("[mcp_servers.needs-you]", self.text(".codex/config.toml"))  # the rest went on

    def test_someone_elses_needs_you_server_is_left_alone(self):
        self.write(".gemini/settings.json", json.dumps({"mcpServers": {"needs-you": {"command": "/opt/other"}}}))
        self.write(".codex/config.toml", '[mcp_servers.needs-you]\ncommand = "/opt/other"\n')
        r = self.run_cli("install-mcp", "gemini,codex")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.json(".gemini/settings.json")["mcpServers"]["needs-you"], {"command": "/opt/other"})
        self.assertEqual(self.text(".codex/config.toml"), '[mcp_servers.needs-you]\ncommand = "/opt/other"\n')
        r = self.run_cli("uninstall-hooks", "--mcp")
        self.assertEqual(self.json(".gemini/settings.json")["mcpServers"]["needs-you"], {"command": "/opt/other"})

    def test_opencode_jsonc_and_missing_claude_say_what_to_do(self):
        self.write(".config/opencode/opencode.jsonc", "// mine\n{}\n")
        r = self.run_cli("install-mcp", "opencode,claude", path="/usr/bin:/bin")  # no `claude` on PATH
        self.assertEqual(r.returncode, 1)
        self.assertIn("opencode.jsonc", r.stderr)
        self.assertIn("claude mcp add-json --scope user needs-you", r.stderr)
        self.assertFalse(os.path.exists(self.p(".config/opencode/opencode.json")))

    def test_needs_the_server_and_known_agents(self):
        os.remove(self.server)
        r = self.run_cli("install-mcp", "gemini")
        self.assertEqual(r.returncode, 1)
        self.assertIn("needs-you-mcp", r.stderr)
        shutil.copy(MCP, self.server)
        r = self.run_cli("install-mcp", "gemini,cursorx")
        self.assertEqual(r.returncode, 2)

    def test_doctor(self):
        os.makedirs(self.p(".gemini"))
        r = self.run_cli("doctor", "--json", path="/usr/bin:/bin")
        mcp = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "mcp server"]
        self.assertEqual(mcp[0]["status"], "INFO", mcp)
        self.assertIn("--mcp gemini", mcp[0]["hint"])
        self.assertEqual(self.run_cli("install-mcp", "gemini,codex").returncode, 0)
        r = self.run_cli("doctor", "--json")
        mcp = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "mcp server"][0]
        self.assertEqual(mcp["status"], "OK", mcp)
        self.assertIn("Codex", mcp["detail"])
        self.assertIn("Gemini CLI", mcp["detail"])
        os.remove(self.server)
        r = self.run_cli("doctor", "--json")
        mcp = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "mcp server"][0]
        self.assertEqual(mcp["status"], "WARN")
        self.assertIn("--mcp codex,gemini", mcp["hint"])
        self.assertIn("re-run the installer", mcp["hint"])


class InstallInstructions(CliCase):
    def test_marked_block_added_kept_current_and_removed_exactly(self):
        mine = "# My rules\n\nAlways run the tests.\n"
        self.write(".codex/AGENTS.md", mine)
        r = self.run_cli("install-instructions", "--from", INSTR, "codex,gemini,opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(INSTR) as fh:
            body = fh.read()
        codex = self.text(".codex/AGENTS.md")
        self.assertTrue(codex.startswith(mine + "\n<!-- needs-you:begin"))
        self.assertIn(body, codex)
        self.assertTrue(codex.endswith("<!-- needs-you:end -->\n"))
        self.assertEqual(len(self.backups(".codex/AGENTS.md")), 1)
        self.assertIn(body, self.text(".gemini/GEMINI.md"))
        self.assertIn(body, self.text(".config/opencode/AGENTS.md"))
        # again: unchanged
        r = self.run_cli("install-instructions", "--from", INSTR, "codex")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.text(".codex/AGENTS.md"), codex)
        self.assertEqual(len(self.backups(".codex/AGENTS.md")), 1)
        # a newer text replaces the block in place, the person's lines stay
        newer = self.write("newer.md", body.replace("post rarely", "post very rarely"))
        self.run_cli("install-instructions", "--from", newer, "codex")
        self.write(".codex/AGENTS.md", self.text(".codex/AGENTS.md") + "\nMore of mine.\n")
        codex = self.text(".codex/AGENTS.md")
        self.assertEqual(codex.count("needs-you:begin"), 1)
        self.assertIn("post very rarely", codex)
        # uninstall: the person's text exactly; files needs-you created are gone
        r = self.run_cli("uninstall-hooks", "--instructions")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.text(".codex/AGENTS.md"), mine + "\nMore of mine.\n")
        self.assertFalse(os.path.exists(self.p(".gemini/GEMINI.md")))
        self.assertFalse(os.path.exists(self.p(".config/opencode/AGENTS.md")))

    def test_symlinked_file_and_broken_block_are_left_alone(self):
        real = self.write("dotfiles/GEMINI.md", "mine\n")
        os.makedirs(self.p(".gemini"))
        os.symlink(real, self.p(".gemini", "GEMINI.md"))
        self.write(".codex/AGENTS.md", "<!-- needs-you:begin -->\nhalf a block\n")
        r = self.run_cli("install-instructions", "--from", INSTR, "gemini,codex,opencode")
        self.assertEqual(r.returncode, 1)
        with open(real) as fh:
            self.assertEqual(fh.read(), "mine\n")
        self.assertEqual(self.text(".codex/AGENTS.md"), "<!-- needs-you:begin -->\nhalf a block\n")
        self.assertTrue(os.path.exists(self.p(".config/opencode/AGENTS.md")))

    def test_refuses_text_that_isnt_the_instructions(self):
        bad = self.write("bad.md", "hello <!-- needs-you:end --> world\n")
        r = self.run_cli("install-instructions", "--from", bad, "codex")
        self.assertEqual(r.returncode, 1)
        self.assertFalse(os.path.exists(self.p(".codex/AGENTS.md")))

    def test_doctor(self):
        os.makedirs(self.p(".codex"))
        r = self.run_cli("doctor", "--json")
        check = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "agent instructions"][0]
        self.assertEqual(check["status"], "INFO")
        self.assertIn("--agent-instructions codex", check["hint"])
        self.run_cli("install-instructions", "--from", INSTR, "codex")
        r = self.run_cli("doctor", "--json")
        check = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "agent instructions"][0]
        self.assertEqual(check["status"], "OK", check)
        self.assertIn("~/.codex/AGENTS.md", check["detail"])
        # Codex reads AGENTS.override.md instead when there is one
        self.write(".codex/AGENTS.override.md", "override\n")
        r = self.run_cli("doctor", "--json")
        check = [c for c in json.loads(r.stdout)["checks"] if c["check"] == "agent instructions"][0]
        self.assertEqual(check["status"], "WARN", check)
        self.assertIn("AGENTS.override.md", check["detail"])


class UpdateRefreshes(CliCase):
    def test_update_refreshes_the_server_and_the_block(self):
        files = current_files()
        files["needs_you_mcp.py"] = read(MCP)
        files["agent-instructions.md"] = read(INSTR)
        h = FakeHub(files)
        self.addCleanup(h.stop)
        with open(self.server, "wb") as fh:
            fh.write(read(MCP).replace(b'VERSION = "', b'VERSION = "0.0.1" or "', 1))
        old = read(INSTR).decode().replace("post rarely", "post seldom")
        stale = self.write("old.md", old)
        self.assertEqual(self.run_cli("install-instructions", "--from", stale, "gemini").returncode, 0)
        env = {"NEEDS_YOU_URLS": h.url, "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_GH": "none", "NEEDS_YOU_TIMEOUT": "2"}
        r = self.run_cli("--json", "update", "--check", **env)
        files_changed = sorted(c["file"] for c in json.loads(r.stdout)["changes"])
        self.assertIn("needs_you_mcp.py", files_changed)
        self.assertIn("agent-instructions.md", files_changed)
        r = self.run_cli("update", **env)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(read(self.server), read(MCP))
        self.assertEqual(os.stat(self.server).st_mode & 0o777, 0o755)
        gem = self.text(".gemini/GEMINI.md")
        self.assertIn(read(INSTR).decode(), gem)
        self.assertNotIn("post seldom", gem)
        r = self.run_cli("--json", "update", "--check", **env)
        self.assertEqual(json.loads(r.stdout)["changes"], [])
        # rollback puts the old block back
        r = self.run_cli("update", "--rollback", **env)
        self.assertIn("post seldom", self.text(".gemini/GEMINI.md"))

    def test_update_never_adds_what_isnt_installed(self):
        files = current_files()
        files["needs_you_mcp.py"] = read(MCP)
        files["agent-instructions.md"] = read(INSTR)
        h = FakeHub(files)
        self.addCleanup(h.stop)
        os.remove(self.server)
        self.write(".codex/AGENTS.md", "mine\n")
        env = {"NEEDS_YOU_URLS": h.url, "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_GH": "none", "NEEDS_YOU_TIMEOUT": "2"}
        r = self.run_cli("update", **env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(self.server))
        self.assertEqual(self.text(".codex/AGENTS.md"), "mine\n")





class Installer(HubTestCase):
    """The invite installer's --mcp and --agent-instructions, end to end against a test hub."""
    env = test_install.InstallScript.env
    invite = test_install.InstallScript.invite
    install = test_install.InstallScript.install

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        self.stubs = os.path.join(self.tmp, "stubs")
        os.makedirs(self.home)
        os.makedirs(self.stubs)
        for name in ("crontab", "launchctl", "uname"):
            p = os.path.join(self.stubs, name)
            with open(p, "w") as fh:
                fh.write(test_install.STUB)
            os.chmod(p, 0o755)
        with open(os.path.join(self.stubs, "claude"), "w") as fh:
            fh.write(CLAUDE_STUB)
        os.chmod(os.path.join(self.stubs, "claude"), 0o755)
        self.log = os.path.join(self.tmp, "stub.log")
        self.cron = os.path.join(self.tmp, "crontab")
        self.hub = self.make_hub("hub-a", peers=[])
        self.hub.store.ensure_token("this-mac", "owner", test_install.OWNER)
        self.assertNotEqual(self.home, REAL_HOME)

    def p(self, *parts):
        return os.path.join(self.home, *parts)

    def test_hub_serves_both_with_checksums(self):
        _, manifest = request("GET", self.hub.url + "/dl/manifest.json")
        for name, src in (("needs_you_mcp.py", MCP), ("agent-instructions.md", INSTR)):
            self.assertEqual(manifest["files"][name]["sha256"], hashlib.sha256(read(src)).hexdigest())
            self.assertEqual(manifest["files"][name]["version"], manifest["version"])
        inv = self.invite()
        with OPENER.open(inv["join_url"] + "/install.sh", timeout=10) as resp:
            script = resp.read().decode()
        self.assertIn("needs_you_mcp.py=" + manifest["files"]["needs_you_mcp.py"]["sha256"], script)

    def test_mcp_and_instructions_install_and_uninstall(self):
        os.makedirs(self.p(".codex"))
        with open(self.p(".codex", "config.toml"), "w") as fh:
            fh.write('model = "o3"\n')
        inv = self.invite()
        r = self.install(inv, "--yes", "--mcp", "claude,codex,gemini", "--agent-instructions", "codex,opencode")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("mcp     -> ", r.stdout)
        server = self.p(".local", "bin", "needs-you-mcp")
        self.assertTrue(os.access(server, os.X_OK))
        self.assertEqual(read(server), read(MCP))
        with open(self.p(".codex", "config.toml")) as fh:
            self.assertIn("[mcp_servers.needs-you]", fh.read())
        with open(self.p(".claude.json")) as fh:
            self.assertIn(os.path.realpath(server), json.load(fh)["mcpServers"]["needs-you"]["args"])
        with open(self.p(".gemini", "settings.json")) as fh:
            self.assertIn("needs-you", json.load(fh)["mcpServers"])
        with open(self.p(".codex", "AGENTS.md")) as fh:
            self.assertIn(read(INSTR).decode(), fh.read())
        self.assertTrue(os.path.exists(self.p(".config", "opencode", "AGENTS.md")))
        d = subprocess.run([self.p(".local", "bin", "needs-you"), "doctor", "--json"],
                           env=self.env(NEEDS_YOU_GH="none"), capture_output=True, text=True, timeout=60)
        checks = {c["check"]: c for c in json.loads(d.stdout)["checks"]}
        self.assertEqual(checks["mcp server"]["status"], "OK", checks["mcp server"])
        self.assertEqual(checks["agent instructions"]["status"], "OK", checks["agent instructions"])
        self.assertNotIn("needs_you_mcp.py", checks["update"]["detail"])
        self.assertNotIn("agent-instructions", checks["update"]["detail"])

        r = self.install(inv, "--uninstall")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(server))
        with open(self.p(".codex", "config.toml")) as fh:
            self.assertEqual(fh.read(), 'model = "o3"\n')
        self.assertFalse(os.path.exists(self.p(".codex", "AGENTS.md")))
        self.assertFalse(os.path.exists(self.p(".config", "opencode", "AGENTS.md")))
        with open(self.p(".claude.json")) as fh:
            self.assertNotIn("needs-you", json.load(fh).get("mcpServers", {}))

    def test_one_agent_failing_skips_only_it(self):
        os.makedirs(self.p(".gemini"))
        with open(self.p(".gemini", "settings.json"), "w") as fh:
            fh.write("{broken")
        inv = self.invite()
        r = self.install(inv, "--yes", "--mcp", "gemini,codex")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Not set up: MCP server for gemini", r.stdout)
        with open(self.p(".codex", "config.toml")) as fh:
            self.assertIn("[mcp_servers.needs-you]", fh.read())

    def test_bad_agent_names_fail_before_anything(self):
        inv = self.invite()
        for flags in (("--mcp", "cursorx"), ("--agent-instructions", "claude"), ("--mcp", "")):
            r = self.install(inv, "--yes", *flags)
            self.assertEqual(r.returncode, 1, flags)
            self.assertFalse(os.path.exists(self.p(".local", "bin", "needs-you")), flags)

    def test_agent_prompt_mentions_the_flags(self):
        inv = self.invite()
        self.assertIn("--mcp", inv["agent_prompt"])
        self.assertIn("--agent-instructions", inv["agent_prompt"])
        with OPENER.open(inv["join_url"], timeout=10) as resp:
            page = resp.read().decode()
        self.assertIn("`--mcp ", page)
        self.assertIn("`--agent-instructions ", page)


if __name__ == "__main__":
    unittest.main()
