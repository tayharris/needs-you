"""needs-you notes add (ADR 0014): a line in the person's notes, queued like a post."""
from __future__ import annotations

from support import request
from test_cli import CliTestCase


class NotesAdd(CliTestCase):
    def notes(self, hub, reader):
        return request("GET", hub.url + "/v1/notes", reader)[1]["text"]

    def test_add_sends_and_offline_queues(self):
        hub = self.make_hub("hub-a")
        sender, reader = self.tokens(hub)
        r = self.run_cli("notes", "add", "check the [deploy](https://acme.example/d)", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("added to the notes", r.stdout)
        self.assertNotIn("deploy", r.stdout, "a sender never sees the notes")
        r = self.run_cli("notes", "add", "call  back", "--section", "Today", "--plain",
                         urls=[self.dead], token=sender)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("queued", r.stderr)
        self.assertEqual(len(self.queued()), 1)
        self.assertEqual(self.run_cli("flush", urls=[hub.url], token=sender).returncode, 0)
        self.assertEqual(self.notes(hub, reader),
                         "## Inbox\n- [ ] check the [deploy](https://acme.example/d)\n\n## Today\n- call back\n")

    def test_usage_errors(self):
        self.assertEqual(self.run_cli("notes", urls=[self.dead]).returncode, 2)
        self.assertEqual(self.run_cli("notes", "add", "  ", urls=[self.dead]).returncode, 2)

    def test_a_refused_line_is_reported(self):
        hub = self.make_hub("hub-a")
        sender, _ = self.tokens(hub)
        r = self.run_cli("notes", "add", "x", "--section", "## bad", urls=[hub.url], token=sender)
        self.assertEqual(r.returncode, 2)
        self.assertIn("section", r.stderr)


if __name__ == "__main__":
    import unittest
    unittest.main()
