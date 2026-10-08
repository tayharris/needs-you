"""No script or test kills processes by name or pattern. A `pkill -f` once matched far more than
intended and took down the owner's apps (macOS pkill stops reading options at the first
pattern, so `-U user` became more patterns). Kill only PIDs a job saved itself; find a
process by its exact, escaped path."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import unittest

from support import ROOT

BASH = shutil.which("bash") or "/bin/bash"
KILL_BY_NAME = re.compile(r"\b(pkill|killall)\b")


def tracked_code():
    files = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True,
                           check=True).stdout.split()
    for rel in files:
        if rel == "tests/test_no_broad_kills.py" or rel.startswith("site/"):
            continue
        path = os.path.join(ROOT, rel)
        if rel.endswith((".sh", ".py", ".swift", ".js", ".yml", ".yaml")):
            yield rel, path
            continue
        try:
            with open(path, "rb") as fh:
                head = fh.read(64)
        except OSError:
            continue
        if head.startswith(b"#!"):
            yield rel, path


def shell_function(path, name):
    """The one-line or multi-line definition of `name()` in a bash script."""
    with open(path) as fh:
        text = fh.read()
    m = re.search(r"^%s\(\) \{.*?^\}$|^%s\(\) \{[^\n]*\}$" % (name, name), text, re.M | re.S)
    if m is None or "\n}" not in m.group(0) and not m.group(0).rstrip().endswith("}"):
        raise AssertionError("no %s() in %s" % (name, path))
    return m.group(0)


@unittest.skipUnless(shutil.which("git"), "needs git")
class NoKillByName(unittest.TestCase):
    def test_no_pkill_or_killall_anywhere(self):
        found = []
        for rel, path in tracked_code():
            with open(path, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    if KILL_BY_NAME.search(line):
                        found.append("%s:%d: %s" % (rel, n, line.strip()))
        self.assertEqual(found, [], "kill only PIDs you started; never by name or pattern")


class InstallerPatterns(unittest.TestCase):
    INSTALL = os.path.join(ROOT, "mac", "scripts", "install.sh")

    def bash(self, script, *args):
        return subprocess.run([BASH, "-c", script, "bash"] + list(args), capture_output=True, text=True,
                              timeout=30)

    def test_paths_are_escaped_in_process_patterns(self):
        """grep -E reads a pattern the way pgrep -f does (extended regex)."""
        fn = shell_function(self.INSTALL, "re_escape")
        for app in ("/Applications/NeedsYou.app", "/tmp/a.b (x)+[y]{2}|z^$\\q/NeedsYou.app"):
            lines = "\n".join([app + "/Contents/MacOS/NeedsYou", app.replace(".", "X") + "/Contents/MacOS/NeedsYou",
                               "/other" + app + "/Contents/MacOS/NeedsYou"]) + "\n"
            r = subprocess.run([BASH, "-c", fn + '\npat="^$(re_escape "$1")/Contents/MacOS/NeedsYou( |$)"; '
                                'grep -E -- "$pat"', "bash", app], input=lines, capture_output=True,
                               text=True, timeout=30)
            self.assertEqual(r.stdout.splitlines(), [app + "/Contents/MacOS/NeedsYou"], (app, r.stderr))

    def test_an_empty_or_root_app_path_is_refused(self):
        fn = shell_function(self.INSTALL, "app_path_ok")
        for path, ok in (("", False), ("/", False), ("/.app", False), ("NeedsYou.app", False),
                         ("/Applications", False), ("/Applications/NeedsYou.app", True),
                         ("/Applications/NeedsYou.app.previous", True), ("/x/NeedsYou.app\n/y", False)):
            r = self.bash(fn + '\napp_path_ok "$1"', path)
            self.assertEqual(r.returncode == 0, ok, repr(path))


if __name__ == "__main__":
    unittest.main()
