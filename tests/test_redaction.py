"""Redaction of token-shaped text before untrusted text reaches a card.

One block of code (between the "needs-you redaction" markers) does it, byte for byte the same in
the agent hook, the CLI (`needs-you run`'s output), the MCP server and the GitHub poller. These
tests check the copies match, what the block catches and keeps, and that it runs in linear time
on input built to make regular expressions backtrack.
"""
from __future__ import annotations

import os
import re
import time
import unittest

from support import ROOT

BEGIN = "# --- needs-you redaction (begin) ---\n"
END = "# --- needs-you redaction (end) ---\n"
COPIES = ("integrations/claude-code/needs-you-hook.sh", "cli/needs-you",
          "integrations/mcp/needs_you_mcp.py", "integrations/github/needs-you-github")


def block(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        src = fh.read()
    i, j = src.find(BEGIN), src.find(END)
    if i < 0 or j < i:
        raise AssertionError("%s has no redaction block" % rel)
    return src[i:j + len(END)]


def redact_fn():
    ns = {"re": re}
    exec(compile(block(COPIES[0]), "redaction", "exec"), ns)
    return ns["redact"]


class Mirror(unittest.TestCase):
    def test_every_copy_is_the_same(self):
        first = block(COPIES[0])
        for rel in COPIES[1:]:
            with self.subTest(rel):
                self.assertEqual(block(rel), first)


class Catches(unittest.TestCase):
    def setUp(self):
        self.redact = redact_fn()

    def check(self, text, *leaks, keep=()):
        out = self.redact(text)
        for s in leaks:
            self.assertNotIn(s, out, "%r -> %r" % (text, out))
        for s in keep:
            self.assertIn(s, out, "%r -> %r" % (text, out))
        return out

    def test_url_encoded_separators(self):
        self.check("GET /cb?token%3Dqv81kd&x=1", "qv81kd", keep=("token%3D",))
        self.check("next=%2Fhome%3Fpassword%3Dzw40hb", "zw40hb")
        self.check("api_key%3Amn55tt", "mn55tt")

    def test_url_password_with_a_slash_or_an_at(self):
        self.check("postgres://app:hunter2/pw@db.example/app", "hunter2", "/pw@db", keep=(
            "postgres://app:", "@db.example/app"))
        self.check("https://bot:p@ss@git.example/repo.git", "p@ss", keep=("@git.example/repo.git",))
        self.check("redis://:qq83ll@cache:6379 and https://example.com/a:b@c", "qq83ll",
                   keep=("https://example.com/a:b@c",))
        self.check("https://example.com/user@host?q=a:b@c", keep=("https://example.com/user@host?q=a:b@c",))
        self.check("x=postgres://app:" + "q" * 300 + "@db", "q" * 20)

    def test_short_keywords(self):
        for name in ("pwd", "pw", "auth", "credentials", "PWD", "db_pw", "x-auth", "credential"):
            with self.subTest(name):
                self.check("%s=kz62rr ok" % name, "kz62rr", keep=(name, "ok"))
        # pwd and cwd as words in a sentence stay
        self.check("Run `pwd` and check the cwd: /home/me/src, then pwd again; cwd=/tmp",
                   keep=("Run `pwd` and check the cwd: /home/me/src, then pwd again; cwd=/tmp",))
        # not a keyword at a word's end
        self.check("bypass=yes maxtoken=12 author: Jo", keep=("bypass=yes", "maxtoken=12", "author: Jo"))

    def test_what_earlier_passes_caught(self):
        self.check('{"password":"qx81"} {\'api_key\': \'pv72\'} auth_token => rt55 mysql --opt-password mk40 '
                   "DB_PASS=wc48 passphrase: lq09 PGPASSWORD=sw0r " + "a" * 80 + "_password=vb62",
                   "qx81", "pv72", "rt55", "mk40", "wc48", "lq09", "sw0r", "vb62")
        self.check("ghp_abcdefghijklmnopqrstuvwxyz0123 and eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.sig-x",
                   "ghp_abcdef", "eyJhbGciOiJIUzI1")
        self.check("Authorization: Bearer abcdefgh12345678", "abcdefgh12345678")


class Callers(unittest.TestCase):
    def test_github_titles_are_redacted(self):
        # PR and notification titles are untrusted text from GitHub that reach a card.
        import importlib.machinery
        import importlib.util
        path = os.path.join(ROOT, "integrations", "github", "needs-you-github")
        loader = importlib.machinery.SourceFileLoader("ny_github_for_test", path)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        out = mod.safe_text("Rotate ghp_abcdefghijklmnopqrstuvwxyz0123 and DB_PASS=wc48rr", 200)
        self.assertNotIn("abcdefghij", out)
        self.assertNotIn("wc48rr", out)
        self.assertTrue(out.startswith("Rotate [redacted]"), out)


class LinearTime(unittest.TestCase):
    CHUNKS = ("a_", "a=", "x:", "//user", "a://", "a://b:", "a://b:c/", "://x@", "a-", "--a-", "--token-",
              "token_", "x_password_", "password ", 'password="', "-password-", "a-password ", "token%3",
              "eyJ-", "eyJa.", "sk-", "ny_-", "-----BEGIN RSA PRIVATE KEY-----", "@", ":@", "a:b@")

    def test_100_kb_of_crafted_text(self):
        redact = redact_fn()
        for chunk in self.CHUNKS:
            text = chunk * (100000 // len(chunk))
            started = time.time()
            redact(text)
            with self.subTest(chunk=chunk):
                self.assertLess(time.time() - started, 1.5)


if __name__ == "__main__":
    unittest.main()
