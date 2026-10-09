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

from support import ROOT, hubmod

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


def redact_fn(rel=COPIES[0]):
    ns = {"re": re}
    exec(compile(block(rel), "redaction", "exec"), ns)
    return ns["redact"]


def fake(*parts):
    """A made-up secret, built from pieces so no source line looks like a real key."""
    return "".join(parts)


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

    def test_pgp_private_key_block(self):
        body = "\n".join(["", "lQOYBF" + "x" * 60, "y" * 64, "=AbCd", ""])
        key = ("-----BEGIN PGP PRIVATE KEY BLOCK-----" + body
               + "-----END PGP PRIVATE KEY BLOCK-----")
        self.assertEqual(self.redact(key), "[redacted]")
        self.assertEqual(self.redact("before\n" + key + "\nafter"), "before\n[redacted]\nafter")
        # cut off before its end: everything after the header goes
        self.assertEqual(self.redact("-----BEGIN PGP PRIVATE KEY BLOCK-----" + body), "[redacted]")
        # the PEM kinds still go
        self.assertEqual(self.redact("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn\n"
                                     "-----END OPENSSH PRIVATE KEY-----"), "[redacted]")
        # a public key block is not a secret
        pub = "-----BEGIN PGP PUBLIC KEY BLOCK-----"
        self.check(pub, keep=(pub,))

    def test_webhook_urls(self):
        slack = fake("https://hooks.slack", ".com/services/T0FAKE000/B0FAKE000/", "fakeFAKEfake0000fake")
        out = self.check("posting to %s failed" % slack, "fakeFAKE", "B0FAKE000",
                         keep=("posting to https://hooks.slack.com/services/[redacted] failed",))
        self.check(fake("https://hooks.slack", ".com/workflows/T0FAKE/A0FAKE/123/", "fakeFAKEfake"),
                   "fakeFAKEfake")
        disc = fake("https://discord", ".com/api/webhooks/123456789012345678/", "fake-FAKE_fake0token")
        self.check("hook %s ok" % disc, "fake-FAKE", "123456789012345678",
                   keep=("hook https://discord.com/api/webhooks/[redacted] ok",))
        self.check(fake("https://discordapp", ".com/api/v10/webhooks/1234/", "fakefaketoken"),
                   "fakefaketoken")
        # Azure SAS and other signed URLs
        sas = fake("https://acme.blob.core.windows.net/c/f.txt?sv=2022-11-02&se=2026-01-01&sp=r",
                   "&sig=", "fAkEsIg%2Bfake%3D")
        self.check(sas, "fAkEsIg", keep=("&sig=",))
        self.check("X-Hub-Signature: sha256=0f0f", "0f0f", keep=("X-Hub-Signature: ",))
        self.check("signature=fakesig1 Sig: fakesig2", "fakesig1", "fakesig2")
        # the words in prose stay
        prose = ("Check the signature on the release, then sign it; signatures matter. "
                 "Design: a sig handler, sig_atomic_t, assign=3, config.signature_v2")
        self.check(prose, keep=(prose,))

    def test_vendor_prefixes(self):
        cases = (
            fake("AK", "IA", "FAKEFAKEFAKEFAKE"),
            fake("AS", "IA", "FAKEFAKEFAKEFAKE"),
            fake("sk", "_live_", "fakeFAKEfake0000"),
            fake("rk", "_test_", "fakeFAKEfake0000"),
            fake("np", "m_", "fake" * 9),
            fake("hf", "_", "fake" * 9),
            fake("glp", "tt-", "fake" * 5),
            fake("xa", "pp-", "1-FAKE-1234-fake"),
            fake("ya", "29.", "fake-FAKE_fake" * 2),
        )
        for secret in cases:
            with self.subTest(secret[:6]):
                self.assertEqual(self.redact("use %s now" % secret), "use [redacted] now")
        # look-alikes that aren't keys stay
        plain = "ASIAN market, sk_live_ alone, npm_config_cache, hf_hub, xapp-x, ya29.x, AKIA1"
        self.check(plain, keep=(plain,))


class HubSecrets(unittest.TestCase):
    MINTS = ("mint_token", "mint_peer_secret", "mint_invite_code")

    def test_every_secret_the_hub_mints_is_redacted_by_every_copy(self):
        # Sender, reader and owner tokens all come from mint_token; peer secrets and invite
        # codes have their own prefixes. Random values, so a pattern that only sometimes
        # matches (and leaves the rest to the base64 catch-all) shows up.
        for rel in COPIES:
            redact = redact_fn(rel)
            for name in self.MINTS:
                mint = getattr(hubmod, name)
                with self.subTest(rel=rel, mint=name):
                    for _ in range(200):
                        secret = mint()
                        out = redact("key %s here" % secret)
                        self.assertEqual(out, "key [redacted] here", secret)
                    # URL-encoded around it (%3D is =, %22 a quote, %20 a space): the word
                    # boundary before the prefix is gone, but the secret still goes, cut short too
                    secret = mint()
                    for text, want in (("x%3D" + secret, "x%3D[redacted]"),
                                       ("%22" + secret + "%22", "%22[redacted]%22"),
                                       ("a%20" + secret[:20], "a%20[redacted]")):
                        self.assertEqual(redact(text), want, text)

    def test_the_hub_log_redacts_them_too(self):
        for name in self.MINTS:
            for _ in range(50):
                secret = getattr(hubmod, name)()
                with self.subTest(mint=name):
                    for line in ("GET /?x=%s" % secret, "GET /?x%%3D%s" % secret, "GET /?q=%%22%s" % secret):
                        self.assertNotIn(secret.split("_", 1)[1], hubmod.redact_log(line), line)


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
              "eyJ-", "eyJa.", "sk-", "ny_-", "-----BEGIN RSA PRIVATE KEY-----", "@", ":@", "a:b@",
              "nyp_", "-----BEGIN PGP PRIVATE KEY BLOCK-----", "-----BEGIN A ", "hooks.slack.com/services/",
              "discord.com/api/webhooks/", "discordapp.com/api/v1/", "sig=", "&sig", "signature:",
              "AKIA", "ASIA", "sk_live_", "rk_test_", "npm_", "hf_", "glptt-", "xapp-", "ya29.",
              "%3D", "%2", "%3Dny_-", "%22nyp_")

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
