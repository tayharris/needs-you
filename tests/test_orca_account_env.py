"""orca_managed_account: the label of the Orca-managed account a process runs under, from the
path Orca puts in its terminals' environment (CODEX_HOME, or CLAUDE_CONFIG_DIR for Orca's
WSL Claude accounts). The CLI's poller, the Claude usage producer and the Codex hook each
carry a copy: they must be byte-identical, and label an account as `needs-you orca usage`
does ("orca-" + 8 hex of sha256(the account id))."""
from __future__ import annotations

import hashlib
import os
import re
import unittest

from support import ROOT

COPIES = ("cli/needs-you", "integrations/claude-code/needs-you-usage", "integrations/claude-code/needs-you-hook.sh")
ID = "3f0c9b1e-2a7d-4c58-b6e1-f0a9d2c4b7e1"


def extract(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^def orca_managed_account\(.*?^    return \"orca-\".*?\n", text, re.S | re.M)
    assert m, rel
    return m.group(0)


def load():
    ns = {"re": re, "hashlib": hashlib}
    exec(extract(COPIES[0]), ns)  # noqa: S102 - our own source, from the repo
    return ns["orca_managed_account"]


def label(account_id):
    return "orca-" + hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:8]


class OrcaAccountEnv(unittest.TestCase):
    def test_copies_are_byte_identical(self):
        first = extract(COPIES[0])
        for rel in COPIES[1:]:
            self.assertEqual(extract(rel), first, rel)

    def test_the_cli_labels_accounts_the_same_way(self):
        with open(os.path.join(ROOT, COPIES[0]), encoding="utf-8") as fh:
            self.assertIn('return "orca-" + hashlib.sha256(account_id.encode("utf-8")).hexdigest()[:8]', fh.read())

    def test_paths(self):
        f = load()
        mac = "/Users/u/Library/Application Support/Orca"
        cases = [
            ("codex", {"CODEX_HOME": mac + "/codex-accounts/%s/home" % ID}, label(ID)),
            ("codex", {"CODEX_HOME": "/home/u/.config/Orca/codex-accounts/%s/home/" % ID}, label(ID)),
            ("codex", {"CODEX_HOME": "C:\\Users\\u\\AppData\\Roaming\\Orca\\codex-accounts\\%s\\home" % ID},
             label(ID)),
            ("claude", {"CLAUDE_CONFIG_DIR": "/home/u/.local/share/orca/claude-accounts/%s/auth" % ID}, label(ID)),
            ("claude", {"CLAUDE_CONFIG_DIR": " /home/u/.local/share/orca/claude-accounts/%s/auth \n" % ID},
             label(ID)),
            # Not Orca's managed shapes: the default account, someone else's layout, the wrong variable.
            ("codex", {}, ""),
            ("codex", {"CODEX_HOME": ""}, ""),
            ("codex", {"CODEX_HOME": "/home/u/.codex"}, ""),
            ("codex", {"CODEX_HOME": mac + "/codex-runtime-home"}, ""),
            ("codex", {"CODEX_HOME": mac + "/codex-accounts/%s/home/sessions" % ID}, ""),
            ("codex", {"CODEX_HOME": mac + "/codex-accounts/%s/auth" % ID}, ""),
            ("codex", {"CLAUDE_CONFIG_DIR": mac + "/codex-accounts/%s/home" % ID}, ""),
            ("claude", {"CODEX_HOME": mac + "/claude-accounts/%s/auth" % ID}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": "/home/u/.claude"}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": mac + "/claude-accounts/%s/home" % ID}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": "claude-accounts/%s/auth" % ID}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": mac + "/claude-accounts/../auth"}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": mac + "/claude-accounts/a b/auth"}, ""),
            ("claude", {"CLAUDE_CONFIG_DIR": mac + "/claude-accounts/%s/auth" % ("x" * 201)}, ""),
        ]
        for provider, env, want in cases:
            with self.subTest(provider=provider, env=env):
                self.assertEqual(f(env, provider), want)


if __name__ == "__main__":
    unittest.main()
