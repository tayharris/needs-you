"""`needs-you run -- CMD`: exit code and output pass through; card on failure, resolve on
success, a done FYI after a long run; output scrubbed, or left out with --no-output."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import sys
import unittest

from support import CLI
from test_cli import CliTestCase


def load_cli():
    loader = importlib.machinery.SourceFileLoader("needs_you_cli_run", CLI)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


PY = sys.executable


class RunCommand(CliTestCase):
    def setUp(self):
        super().setUp()
        self.hub = self.make_hub("hub-a")
        self.sender, self.reader = self.tokens(self.hub)

    def run_wrapped(self, *args, urls=None):
        return self.run_cli("run", *args, urls=urls or [self.hub.url], token=self.sender)

    def by_key(self):
        return {i["key"]: i for i in self.items(self.hub, self.reader)}

    def test_failure_posts_card_with_exit_code_and_scrubbed_tail(self):
        script = ("import sys; print('to stdout'); "
                  "sys.stderr.write('\\x1b[31mboom\\x1b[0m one\\n\\u202eevil\\nAuthorization: Bearer abcdefghijklmnop12345\\n"
                  "password=hunter2\\nprogress 10%\\rprogress 100%\\nlast line ```fence```\\n'); sys.exit(3)")
        r = self.run_wrapped("--key", "work:devbox:nightly", "--title", "Nightly import failed",
                             "--link", "Logs=https://logs.example.com/x", "--done-after", "0", "--", PY, "-c", script)
        self.assertEqual(r.returncode, 3)
        self.assertIn("to stdout", r.stdout)           # stdout passes through
        self.assertIn("boom", r.stderr)                 # stderr too, unscrubbed, to the terminal
        item = self.by_key()["work:devbox:nightly"]
        self.assertEqual(item["status"], "open")
        self.assertEqual(item["kind"], "needs")
        self.assertEqual(item["title"], "Nightly import failed")
        self.assertEqual(item["links"], [{"label": "Logs", "url": "https://logs.example.com/x"}])
        body = item["body"]
        self.assertIn("exited 3 on `testbox`", body)
        self.assertNotIn("boom", body)                  # 6 lines: only the last 5 are kept
        self.assertIn("\nevil\n", body)                  # bidi override dropped, text kept
        self.assertNotIn("\x1b", body)
        self.assertNotIn("‮", body)
        self.assertNotIn("abcdefghijklmnop12345", body)
        self.assertNotIn("hunter2", body)
        self.assertIn("progress 100%", body)
        self.assertNotIn("progress 10%", body)
        self.assertEqual(body.count("```"), 2)          # only our own fence
        self.assertNotIn("to stdout", body)             # stdout never goes in the card

    def test_no_output_leaves_stderr_out_and_still_passes_it_through(self):
        r = self.run_wrapped("--key", "work:devbox:secretjob", "--no-output", "--",
                             PY, "-c", "import sys; sys.stderr.write('SECRET-VALUE\\n'); sys.exit(1)")
        self.assertEqual(r.returncode, 1)
        self.assertIn("SECRET-VALUE", r.stderr)
        body = self.by_key()["work:devbox:secretjob"]["body"]
        self.assertNotIn("SECRET-VALUE", body)
        self.assertNotIn("stderr", body)

    def test_success_resolves_and_short_run_posts_no_done(self):
        self.run_wrapped("--key", "work:devbox:job", "--", PY, "-c", "raise SystemExit(2)")
        self.assertEqual(self.by_key()["work:devbox:job"]["status"], "open")
        r = self.run_wrapped("--key", "work:devbox:job", "--", PY, "-c", "print('ok')")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "ok")
        items = [i for i in self.items(self.hub, self.reader) if i["key"] == "work:devbox:job"]
        self.assertEqual([i["status"] for i in items], ["resolved"])

    def test_long_success_posts_done(self):
        r = self.run_wrapped("--key", "work:devbox:build", "--done-after", "0", "--done-title", "Build finished",
                             "--", PY, "-c", "pass")
        self.assertEqual(r.returncode, 0)
        open_items = self.items(self.hub, self.reader, "open")
        self.assertEqual([(i["key"], i["kind"], i["title"]) for i in open_items],
                         [("work:devbox:build", "done", "Build finished")])
        self.assertIsNotNone(open_items[0]["expires_at"])
        r = self.run_wrapped("--key", "work:devbox:build2", "--done-after", "-1", "--", PY, "-c", "pass")
        self.assertNotIn("work:devbox:build2", self.by_key())

    def test_default_key_title_and_context(self):
        self.run_wrapped("--", "false")
        item = self.by_key()["work:testbox:run:false"]
        self.assertEqual(item["title"], "false failed on testbox")
        self.assertEqual(item["source"]["agent"], "run:false")
        self.run_wrapped("--key", "personal:nas:backup", "--", "false")
        self.assertEqual(self.by_key()["personal:nas:backup"]["context"], "personal")

    def test_missing_command_exits_127_and_posts(self):
        r = self.run_wrapped("--key", "work:devbox:nope", "--", "/nonexistent/tool-xyz")
        self.assertEqual(r.returncode, 127)
        self.assertIn("could not start", self.by_key()["work:devbox:nope"]["body"])

    def test_signal_exit_code(self):
        r = self.run_wrapped("--key", "work:devbox:killed", "--", PY, "-c",
                             "import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(r.returncode, 128 + 15)

    def test_hub_down_queues_and_keeps_the_exit_code(self):
        r = self.run_wrapped("--key", "work:devbox:offline", "--", PY, "-c", "raise SystemExit(4)", urls=[self.dead])
        self.assertEqual(r.returncode, 4)
        self.assertEqual(len(self.queued()), 1)
        r = self.run_wrapped("--key", "work:devbox:offline", "--", PY, "-c", "pass", urls=[self.dead])
        self.assertEqual(r.returncode, 0)
        self.assertEqual(len(self.queued()), 2)

    def test_hub_rejection_keeps_the_exit_code(self):
        r = self.run_cli("run", "--key", "work:devbox:x", "--", PY, "-c", "raise SystemExit(5)",
                         urls=[self.hub.url], token="bogus")
        self.assertEqual(r.returncode, 5)
        r = self.run_cli("run", "--key", "work:devbox:x", "--", PY, "-c", "pass", urls=[self.hub.url], token="bogus")
        self.assertEqual(r.returncode, 0)

    def test_no_command_is_usage_error(self):
        r = self.run_wrapped("--key", "k")
        self.assertEqual(r.returncode, 2)


class ScrubTail(unittest.TestCase):
    def test_lines_truncated_and_tokens_redacted(self):
        cli = load_cli()
        raw = ("a" * 500 + "\nuse ghp_" + "x" * 30 + " here\nny_" + "y" * 40 + "\n\n\n").encode()
        lines = cli.scrub_tail(raw)
        self.assertEqual(len(lines), 3)
        self.assertLessEqual(len(lines[0]), cli.RUN_LINE_MAX)
        self.assertEqual(lines[1], "use <redacted> here")
        self.assertEqual(lines[2], "<redacted>")
        self.assertEqual(len(cli.scrub_tail(b"\n".join(b"l%d" % i for i in range(20)))), cli.RUN_TAIL_LINES)
        self.assertEqual(cli.scrub_tail(b"\xff\xfe bad utf8"), ["�� bad utf8"])


if __name__ == "__main__":
    unittest.main()
