"""Run the protocol conformance suite (protocol/conformance/) against two peered hubs started
as separate processes, the way CI checks the reference hub."""
from __future__ import annotations

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from support import PEER_SECRET, ROOT, free_port, request

SUITE = os.path.join(ROOT, "protocol", "conformance", "test_conformance.py")
HUB = os.path.join(ROOT, "hub", "needs_you_hub.py")
OWNER = "conformance-owner-0123456789abcdef"


class Conformance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="needs-you-conformance-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        owner_file = os.path.join(self.tmp, "owner.token")
        with open(owner_file, "w") as fh:
            fh.write(OWNER + "\n")
        self.ports = [free_port(), free_port()]
        self.urls = ["http://127.0.0.1:%d" % p for p in self.ports]
        self.procs = []
        for i, name in enumerate(("hub-a", "hub-b")):
            args = [sys.executable, HUB, "--bind", "127.0.0.1", "--port", str(self.ports[i]),
                    "--db", os.path.join(self.tmp, name + ".db"), "--hub-id", name,
                    "--owner-token-file", owner_file, "--peer", self.urls[1 - i], "--quiet",
                    "--set", "anti_entropy_seconds=0.5", "--set", "outbox_poll_seconds=0.1",
                    "--set", "retry_base_seconds=0.05", "--set", "retry_max_seconds=0.5",
                    "--set", "maintenance_seconds=0"]
            env = dict(os.environ, NEEDS_YOU_PEER_SECRET=PEER_SECRET)
            p = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.procs.append(p)
            self.addCleanup(self._stop, p)
        for url in self.urls:
            deadline = time.time() + 30
            while time.time() < deadline:
                try:
                    if request("GET", url + "/v1/health", timeout=1)[0] == 200:
                        break
                except OSError:
                    pass
                time.sleep(0.1)
            else:
                self.fail("hub at %s didn't start" % url)

    @staticmethod
    def _stop(p):
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        if p.stderr:
            p.stderr.close()

    def test_the_reference_hub_passes(self):
        env = {"NEEDS_YOU_CONFORMANCE_URL": self.urls[0], "NEEDS_YOU_CONFORMANCE_URL_B": self.urls[1],
               "NEEDS_YOU_CONFORMANCE_OWNER": OWNER, "NEEDS_YOU_CONFORMANCE_PEER_SECRET": PEER_SECRET,
               "NEEDS_YOU_CONFORMANCE_WAIT": "30"}
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            spec = importlib.util.spec_from_file_location("needs_you_conformance", SUITE)
            mod = importlib.util.module_from_spec(spec)
            # unittest finds setUpModule through sys.modules
            sys.modules[spec.name] = mod
            self.addCleanup(sys.modules.pop, spec.name, None)
            spec.loader.exec_module(mod)
            suite = unittest.TestLoader().loadTestsFromModule(mod)
            out = io.StringIO()
            # A module's setUpModule/tearDownModule run when its tests run in a suite.
            result = unittest.TextTestRunner(stream=out, verbosity=2).run(suite)
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        if os.environ.get("NEEDS_YOU_CONFORMANCE_SHOW"):
            sys.stderr.write(out.getvalue())
        self.assertTrue(result.wasSuccessful(), out.getvalue())
        self.assertGreaterEqual(result.testsRun, 20)
        self.assertEqual(result.skipped, [], "every case should run against the reference hub")


if __name__ == "__main__":
    unittest.main()
