"""Aider integration (integrations/aider/): the shared hook in `aider` mode.

Aider runs its --notifications-command once each time it waits for the person after an LLM
reply (the next prompt or a yes/no question), through `sh -c`, with no arguments, no payload,
and the terminal as stdin (checked live with aider 0.86.2: a command that reads stdin eats
what the person types). It waits for the command to exit. So in this mode the hook never
reads stdin, returns at once, and names the session after the Aider process.
"""
from __future__ import annotations

import os
import subprocess
import time

from hook_case import BASH, HOOK, HookCase, opt


class AiderHook(HookCase):
    AGENT = "aider"

    def run_like_aider(self, *args, **extra):
        """`sh -c '<hook> notify aider'`, with a stdin pipe that is never closed: a hook that
        read it would hang (and in Aider, swallow the person's typing)."""
        started = time.time()
        rfd, wfd = os.pipe()
        try:
            p = subprocess.Popen(["sh", "-c", '"%s" "%s" notify aider' % (BASH, HOOK)] + list(args),
                                 stdin=rfd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=self.env(**extra), cwd=self.cwd)
            os.close(rfd)
            try:
                out, err = p.communicate(timeout=3)
            finally:
                if p.poll() is None:
                    p.kill()
                    p.communicate()
        finally:
            os.close(wfd)
        self.assertEqual((p.returncode, out, err), (0, b"", b""))
        self.assertLess(time.time() - started, 2)

    def test_waiting_card(self):
        self.run_like_aider()
        argv = self.wait_calls(1)[-1]
        sid = "aider-%d" % os.getpid()
        self.assertEqual(opt(argv, "--title"), "Aider is waiting for you: my-repo")
        self.assertEqual(opt(argv, "--agent"), "aider")
        self.assertEqual(opt(argv, "--project"), "my-repo")
        self.assertEqual(opt(argv, "--key").split(":")[-1], sid)
        # No event tells us the person answered: a short expiry, and the lease on Aider's pid.
        self.assertEqual(opt(argv, "--expires-in"), "1")
        self.wait_marker(sid)
        self.assertEqual(self.read_marker(sid)["pid"], str(os.getpid()))
        # The next wait updates the same card.
        self.run_like_aider()
        self.assertEqual(opt(self.wait_calls(2)[-1], "--key"), opt(argv, "--key"))

    def test_expiry_setting(self):
        self.run_like_aider(NEEDS_YOU_AIDER_EXPIRY_HOURS="0.25")
        self.assertEqual(opt(self.wait_calls(1)[-1], "--expires-in"), "0.25")

    def test_quiet_cases(self):
        self.run_like_aider(NEEDS_YOU_AGENT_ALERTS="")
        self.run_like_aider(NEEDS_YOU_AGENT_TURN_CARDS="0")
        self.run_like_aider(NY_HOOK_PPID=self.gone_pid())
        time.sleep(0.8)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    import unittest
    unittest.main()
