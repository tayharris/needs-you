"""Finished turns vs turns that end on a question, and the session's name and where it runs.

When an agent's turn ends, the shared hook posts "<Agent> finished: <session> (<project>)",
or "<Agent> asks: <question> · <session>" when the turn's final message ends on a question
to the person. The text comes from the agent (Claude Code's transcript, Codex's and
opencode's last_assistant_message, Gemini's prompt_response, Cline's task result), so it is
redacted as a whole before it is cut. Session names: Claude Code's /rename name (a
custom-title transcript entry) or auto title (ai-title), a Codex thread name, Kimi's and
opencode's session_title. NEEDS_YOU_TURN_TEXT=0 keeps the old cards.

Everything runs with a temporary HOME and a fake CLI (tests/hook_case.py)."""
from __future__ import annotations

import json
import os
import time
import unittest

from hook_case import HookCase, opt, posted_item

SECRET = "sk-test-SECRET-0123456789"
TOKENS = ("sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345", "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
          "ny_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")
CLAUDE_SID = "2d96751d-6b16-4ec4-b154-51a2c7524b2d"


def entry(kind, text=None, **extra):
    """A Claude Code transcript line, shaped as 2.1.294 writes them (live)."""
    if kind == "assistant":
        d = {"parentUuid": "p", "isSidechain": False, "type": "assistant", "sessionId": CLAUDE_SID,
             "message": {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                         "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                         "usage": {"input_tokens": 10, "output_tokens": 5}}}
    elif kind == "user":
        d = {"parentUuid": "p", "isSidechain": False, "type": "user", "sessionId": CLAUDE_SID,
             "message": {"role": "user", "content": text}}
    elif kind == "ai-title":
        d = {"type": "ai-title", "aiTitle": text, "sessionId": CLAUDE_SID}
    elif kind == "custom-title":
        d = {"type": "custom-title", "customTitle": text, "sessionId": CLAUDE_SID}
    else:
        d = {"type": kind, "sessionId": CLAUDE_SID}
    d.update(extra)
    return d


class ClaudeTurns(HookCase):
    AGENT = "claude"

    def transcript(self, *entries):
        path = os.path.join(self.home, "transcript.jsonl")
        with open(path, "w") as fh:
            fh.write(json.dumps(entry("mode")) + "\n")
            for e in entries:
                fh.write(json.dumps(e) + "\n")
        return path

    def idle(self, *entries, **env):
        payload = {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "Notification",
                   "message": "Claude is waiting for your input", "notification_type": "idle_prompt",
                   "transcript_path": self.transcript(*entries)}
        self.run_hook(["notify"], payload, **env)
        argv = self.calls()[-1]
        posted_item(argv)  # within the hub's limits
        return argv

    def test_finished_with_auto_title(self):
        argv = self.idle(entry("ai-title", "Fake auto title"), entry("user", "fix it"),
                         entry("assistant", "All done. The tests pass."))
        self.assertEqual(opt(argv, "--title"), "Claude finished: Fake auto title (my-repo)")
        self.assertIn("Claude finished its turn; your next message continues it.", opt(argv, "--body"))
        self.assertEqual(self.read_marker(CLAUDE_SID)["kind"], "notify")

    def test_rename_wins_over_auto_title_wherever_it_is(self):
        # live: /rename writes one custom-title line; ai-title lines keep coming after it
        filler = [entry("user", "x" * 1000), entry("assistant", "ok")] * 400  # over 256 KB after it
        argv = self.idle(entry("ai-title", "Fake auto title"), entry("custom-title", "Login fix (prod)"),
                         *(filler + [entry("ai-title", "Later auto title"), entry("assistant", "Done.")]))
        self.assertEqual(opt(argv, "--title"), "Claude finished: Login fix (prod) (my-repo)")

    def test_no_title_no_transcript(self):
        argv = self.idle(entry("assistant", "Done."))
        self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo")
        self.run_hook(["notify"], {"session_id": CLAUDE_SID, "hook_event_name": "Notification",
                                   "notification_type": "idle_prompt", "transcript_path": "/nonexistent"})
        self.assertEqual(opt(self.calls()[-1], "--title"), "Claude finished: my-repo")

    def test_question(self):
        argv = self.idle(entry("custom-title", "Login fix (prod)"),
                         entry("assistant", "I looked at the code.\n\nShould I also update the migration for the users table?"))
        self.assertEqual(opt(argv, "--title"),
                         "Claude asks: Should I also update the migration for the users table? · Login fix (prod) (my-repo)")
        body = opt(argv, "--body")
        self.assertTrue(body.startswith("Should I also update the migration for the users table?"), body)
        self.assertIn("your reply continues it", body)
        self.assertNotIn("I looked at the code", body)  # only the last paragraph

    def test_question_sentence_after_a_statement(self):
        argv = self.idle(entry("assistant", "The build passes now. **Want me to open a PR?**"))
        self.assertEqual(opt(argv, "--title"), "Claude asks: Want me to open a PR? · my-repo")
        argv = self.idle(entry("assistant", "Two ways:\n\n1. Keep it\n2. Drop it\n\nWhich do you prefer: 1 or 2?"))
        self.assertEqual(opt(argv, "--title"), "Claude asks: Which do you prefer: 1 or 2? · my-repo")

    def test_statements_are_finished(self):
        for text in ("Done. Why did it fail? A stale cache. Fixed now.",
                     "Should I? No: it's done.",
                     "Here is the query:\n\n```sql\nSELECT * FROM t WHERE a = ?\n```",
                     "| col | q? |\n|---|---|\n| a | b? |",
                     "    indented code?",
                     "Let me know if you want anything else.",
                     "?",
                     ""):
            argv = self.idle(entry("assistant", text))
            self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo", text)

    def test_only_the_final_assistant_text_counts(self):
        # A question earlier in the turn, then a tool call and its result: the turn ended elsewhere.
        tool_use = entry("assistant", "x")
        tool_use["message"]["content"] = [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]
        argv = self.idle(entry("assistant", "Shall I run it?"), tool_use,
                         entry("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok?"}]))
        self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo")
        # An interruption after a question
        argv = self.idle(entry("assistant", "Shall I run it?"), entry("user", "[Request interrupted by user]"))
        self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo")
        # A subagent's question (sidechain) and meta entries after the real final text are skipped
        side = entry("assistant", "Subagent: which file?", isSidechain=True)
        meta = entry("user", "<system-reminder>The user named this session</system-reminder>", isMeta=True)
        argv = self.idle(entry("assistant", "Shall I run it?"), side, meta, entry("ai-title", "T"))
        self.assertEqual(opt(argv, "--title"), "Claude asks: Shall I run it? · T (my-repo)")
        # A synthetic message (an API error, "No response requested.") isn't the model's
        synth = entry("assistant", "Should I retry?")
        synth["message"]["model"] = "<synthetic>"
        argv = self.idle(synth)
        self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo")

    def test_tokens_in_the_question_are_redacted(self):
        argv = self.idle(entry("assistant", "Deploy with %s and %s, or with token=%s?" % TOKENS))
        title, body = opt(argv, "--title"), opt(argv, "--body")
        self.assertTrue(title.startswith("Claude asks: Deploy with [redacted]"), title)
        for t in TOKENS:
            for part in (t, t[:12], t[-12:]):
                self.assertNotIn(part, title + body)

    def test_a_link_in_agent_text_shows_where_it_goes(self):
        """Agent text is shown, never trusted (prompt injection can write it): a markdown link
        in it can't put a label over a destination, so the card shows the URL itself."""
        argv = self.idle(entry("assistant", "Ready. [Approve the deploy](https://evil.example/x) or "
                                            "![logo](https://evil.example/i.png) - should I go ahead?"))
        body = opt(argv, "--body")
        self.assertIn("\\[Approve the deploy](https://evil.example/x)", body)  # shown as typed
        self.assertIn("!\\[logo](https://evil.example/i.png)", body)

    def test_token_straddling_the_clamp(self):
        # The token starts just before the title's cut: redacted first, then cut, so no prefix of
        # it survives in the title or the body.
        for pad in range(50, 100, 7):
            argv = self.idle(entry("assistant", "Should I use " + "w " * (pad // 2) + TOKENS[1] + " for the push?"))
            title, body = opt(argv, "--title"), opt(argv, "--body")
            self.assertLessEqual(len(title), 100)
            self.assertNotIn("ghp_AbCd", title + body)
            self.assertNotIn("AbCdEfGh", title + body)

    def test_long_message_cut_at_the_front_is_redacted(self):
        # A message longer than the hook reads: the cut can't leave a token's tail behind.
        long = "a " * 100500 + TOKENS[0] + " and the rest?"
        argv = self.idle(entry("assistant", long))
        self.assertNotIn("AbCdEfGhIjKl", opt(argv, "--title") + opt(argv, "--body"))

    def test_token_in_the_session_names(self):
        for kind in ("custom-title", "ai-title"):
            argv = self.idle(entry(kind, "deploy %s now" % TOKENS[0]), entry("assistant", "Done."))
            self.assertEqual(opt(argv, "--title"), "Claude finished: my-repo")  # the name is dropped
            self.assertNotIn("AbCdEfGh", json.dumps(argv))
        argv = self.idle(entry("custom-title", "password=hunter2hunter2"), entry("assistant", "Done."))
        self.assertNotIn("hunter2", json.dumps(argv))

    def test_name_is_cleaned_and_clamped(self):
        argv = self.idle(entry("custom-title", "evil\x1b[31m‮name\n" + "x" * 300), entry("assistant", "Done."))
        title = opt(argv, "--title")
        self.assertLessEqual(len(title), 100)
        self.assertTrue(title.startswith("Claude finished: evil [31mname xxx"), title)
        self.assertTrue(title.endswith("… (my-repo)"), title)
        self.assertNotIn("\x1b", title)
        long_q = "Should we " + "really " * 40 + "ship it?"
        argv = self.idle(entry("custom-title", "N" * 60), entry("assistant", long_q))
        self.assertLessEqual(len(opt(argv, "--title")), 100)

    def cache(self):
        with open(os.path.join(self.state, ".title-" + CLAUDE_SID)) as fh:
            return json.load(fh)

    def write_lines(self, path, entries, mode="w"):
        with open(path, mode) as fh:
            for e in entries:
                fh.write(json.dumps(e) + "\n")

    def idle_at(self, path, **env):
        self.run_hook(["notify"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "Notification",
                                   "notification_type": "idle_prompt", "transcript_path": path}, **env)
        return opt(self.calls()[-1], "--title")

    def test_name_cache_reads_only_what_was_appended(self):
        path = os.path.join(self.home, "t.jsonl")
        filler = [entry("user", "x" * 1000), entry("assistant", "ok")] * 10  # the title past the first 4 KB
        self.write_lines(path, filler + [entry("custom-title", "Alpha")] + filler + [entry("assistant", "Done.")])
        self.assertEqual(self.idle_at(path), "Claude finished: Alpha (my-repo)")
        c = self.cache()
        self.assertEqual((c["path"], c["offset"], c["custom"]), (path, os.path.getsize(path), "Alpha"))
        self.assertEqual(os.stat(os.path.join(self.state, ".title-" + CLAUDE_SID)).st_mode & 0o777, 0o600)
        # Change the old title in place: a card that re-read the head would see "Omega".
        with open(path, "r+b") as fh:
            data = fh.read()
            fh.seek(data.index(b'"Alpha"'))
            fh.write(b'"Omega"')
        self.write_lines(path, [entry("assistant", "Done again.")], "a")
        self.assertEqual(self.idle_at(path), "Claude finished: Alpha (my-repo)")
        self.assertEqual(self.cache()["offset"], os.path.getsize(path))
        # A rename appended later is found in the new tail.
        self.write_lines(path, [entry("custom-title", "Gamma"), entry("ai-title", "Auto"), entry("assistant", "Ok.")], "a")
        self.assertEqual(self.idle_at(path), "Claude finished: Gamma (my-repo)")
        # A line still being written isn't counted yet, and is read whole next time.
        with open(path, "a") as fh:
            fh.write(json.dumps(entry("custom-title", "Delta"))[:-5])
        self.assertEqual(self.idle_at(path), "Claude finished: Gamma (my-repo)")
        with open(path, "a") as fh:
            fh.write(json.dumps(entry("custom-title", "Delta"))[-5:] + "\n")
        self.assertEqual(self.idle_at(path), "Claude finished: Delta (my-repo)")
        # A different transcript (a new session file, or one rewritten in its place) is read anew.
        self.write_lines(path, [entry("ai-title", "Fresh"), entry("assistant", "Done.")])
        self.assertEqual(self.idle_at(path), "Claude finished: Fresh (my-repo)")
        # SessionEnd removes the cache.
        self.run_hook(["end"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "SessionEnd"})
        self.assertFalse(os.path.exists(os.path.join(self.state, ".title-" + CLAUDE_SID)))

    def test_a_big_transcript_is_read_once(self):
        # Timing guard: about 48 MB, the title at the top. The first card reads it all, the
        # next ones only the tail (the cache's offset), so they stay fast.
        path = os.path.join(self.home, "big.jsonl")
        line = (json.dumps(entry("user", "y" * 4000)) + "\n").encode()
        with open(path, "wb") as fh:
            fh.write((json.dumps(entry("custom-title", "Big one")) + "\n").encode())
            fh.write(line * (48 * 1024 * 1024 // len(line)))
            fh.write((json.dumps(entry("assistant", "Done.")) + "\n").encode())
        self.assertEqual(self.idle_at(path), "Claude finished: Big one (my-repo)")
        self.assertEqual(self.cache()["offset"], os.path.getsize(path))
        times = []
        for _ in range(3):
            self.write_lines(path, [entry("assistant", "More.")], "a")
            started = time.time()
            self.assertEqual(self.idle_at(path), "Claude finished: Big one (my-repo)")
            times.append(time.time() - started)
        self.assertLess(min(times), 1.0, times)  # the hook's own start-up, not 48 MB of reading

    def test_session_title_from_the_prompt(self):
        # UserPromptSubmit carries session_title after /rename (live, 2.1.294): kept for the cards.
        self.run_hook(["resolve"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "UserPromptSubmit",
                                    "prompt": "go", "session_title": "From prompt"})
        self.assertEqual(self.cache()["prompt"], "From prompt")
        self.assertEqual(self.calls(), [])  # nothing posted or resolved: no card was open
        path = os.path.join(self.home, "p.jsonl")
        self.write_lines(path, [entry("ai-title", "Auto"), entry("assistant", "Done.")])
        self.assertEqual(self.idle_at(path), "Claude finished: From prompt (my-repo)")
        self.write_lines(path, [entry("custom-title", "Renamed")], "a")
        self.assertEqual(self.idle_at(path), "Claude finished: Renamed (my-repo)")
        # A prompt that only quotes the key isn't a title.
        self.run_hook(["resolve"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "UserPromptSubmit",
                                    "prompt": 'say "session_title": "evil"'})
        self.assertEqual(self.cache()["prompt"], "From prompt")

    def test_name_on_other_cards(self):
        self.transcript(entry("custom-title", "Login fix"))
        self.run_hook(["notify"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "PermissionRequest",
                                   "tool_name": "Bash", "tool_input": {"command": "make"},
                                   "transcript_path": os.path.join(self.home, "transcript.jsonl")})
        self.assertEqual(opt(self.calls()[-1], "--title"), "Claude wants to run make: Login fix (my-repo)")

    def test_turn_text_off_keeps_the_old_card(self):
        argv = self.idle(entry("custom-title", "Login fix"), entry("assistant", "Shall I?"), NEEDS_YOU_TURN_TEXT="0")
        self.assertEqual(opt(argv, "--title"), "Claude is waiting for you: my-repo")
        self.assertEqual(opt(argv, "--body").split("\n\n")[0], "Claude is waiting for your input")

    def test_an_open_permission_card_is_kept(self):
        self.run_hook(["notify"], {"session_id": CLAUDE_SID, "cwd": self.cwd, "hook_event_name": "PermissionRequest",
                                   "tool_name": "Bash", "tool_input": {"command": "make"}})
        n = len(self.calls())
        self.idle(entry("assistant", "Shall I?"))
        self.assertEqual(len(self.calls()), n)


class Where(HookCase):
    AGENT = "claude"

    def where(self, **env):
        self.run_hook(["notify"], {"session_id": "s-where", "cwd": self.cwd, "hook_event_name": "Notification",
                                   "notification_type": "idle_prompt"}, **env)
        return opt(self.calls()[-1], "--body").split("\n\n")[1]

    def test_terminal_apps(self):
        for env, name in (({"TERM_PROGRAM": "iTerm.app"}, "iTerm"), ({"TERM_PROGRAM": "Apple_Terminal"}, "Terminal"),
                          ({"TERM_PROGRAM": "ghostty"}, "Ghostty"), ({"TERM_PROGRAM": "WezTerm"}, "WezTerm"),
                          ({"TERM_PROGRAM": "WarpTerminal"}, "Warp"), ({"KITTY_WINDOW_ID": "1"}, "kitty"),
                          ({"ALACRITTY_WINDOW_ID": "1"}, "Alacritty"), ({"ITERM_SESSION_ID": "w0t0p0:x"}, "iTerm"),
                          ({"TERM_PROGRAM": "NewTerm.app"}, "NewTerm")):
            self.assertTrue(self.where(**env).endswith(", " + name), (env, self.where(**env)))
        self.assertNotIn(",", self.where(TERM_PROGRAM="bad`name;rm"))
        self.assertTrue(self.where(SSH_CONNECTION="1 2 3 4", LC_TERMINAL="iTerm2").endswith(", SSH from iTerm"))
        self.assertTrue(self.where(SSH_CONNECTION="1 2 3 4", LC_NEEDS_YOU_TERM="app=ghostty").endswith(", SSH from Ghostty"))
        self.assertTrue(self.where(SSH_CONNECTION="1 2 3 4").endswith(", SSH"))

    def test_ide_workspace_from_claudes_lock_file(self):
        ide = os.path.join(self.home, ".claude", "ide")
        os.makedirs(ide)
        with open(os.path.join(ide, "51234.lock"), "w") as fh:
            json.dump({"pid": 1, "workspaceFolders": ["/home/u/src/acme-web"], "ideName": "Visual Studio Code",
                       "transport": "ws", "authToken": "6f1c2b9a-SECRET-AUTH-TOKEN"}, fh)
        line = self.where(TERM_PROGRAM="vscode", CLAUDE_CODE_SSE_PORT="51234")
        self.assertTrue(line.endswith(", VS Code `acme-web`"), line)
        self.assertNotIn("SECRET-AUTH", json.dumps(self.calls()))
        with open(os.path.join(ide, "51234.lock"), "w") as fh:
            json.dump({"workspaceFolders": ["/w/acme-api"], "ideName": "Cursor"}, fh)
        self.assertTrue(self.where(TERM_PROGRAM="vscode", CLAUDE_CODE_SSE_PORT="51234").endswith(", Cursor `acme-api`"))
        self.assertTrue(self.where(TERM_PROGRAM="vscode", CURSOR_TRACE_ID="x").endswith(", Cursor"))
        self.assertTrue(self.where(TERM_PROGRAM="vscode", CLAUDE_CODE_SSE_PORT="../x").endswith(", VS Code"))


class OtherAgents(HookCase):
    AGENT = "turns"

    def post(self, args, payload, **env):
        env.setdefault("NY_KIMI_TURN_WAIT", "0")
        env.setdefault("NY_COPILOT_TURN_WAIT", "0")
        n = len(self.calls())
        self.run_hook(args, payload, **env)
        argv = self.wait_calls(n + 1)[-1]
        posted_item(argv)
        return argv

    def test_codex(self):
        ask = {"session_id": "019a-codex", "cwd": self.cwd, "hook_event_name": "Stop", "turn_id": "t",
               "stop_hook_active": False, "last_assistant_message": "Patched it.\n\nRun the migration now?"}
        argv = self.post(["notify", "codex"], ask)
        self.assertEqual(opt(argv, "--title"), "Codex asks: Run the migration now? · my-repo")
        argv = self.post(["notify", "codex"], dict(ask, last_assistant_message="Patched it. Key: %s" % SECRET))
        self.assertEqual(opt(argv, "--title"), "Codex finished: my-repo")
        self.assertNotIn(SECRET, json.dumps(self.calls()))
        argv = self.post(["notify", "codex"], dict(ask, last_assistant_message=None))
        self.assertEqual(opt(argv, "--title"), "Codex finished: my-repo")
        argv = self.post(["notify", "codex"], ask, NEEDS_YOU_TURN_TEXT="0")
        self.assertEqual(opt(argv, "--title"), "Codex is waiting for you: my-repo")

    def test_codex_thread_name(self):
        codex_home = os.path.join(self.home, "codex-home")
        os.makedirs(codex_home)
        with open(os.path.join(codex_home, "session_index.jsonl"), "w") as fh:
            for sid, name in (("019a-codex", "Old name"), ("019a-other", "Other"), ("019a-codex", "Billing cleanup")):
                fh.write(json.dumps({"id": sid, "thread_name": name, "updated_at": "2026-10-08T00:00:00Z"}) + "\n")
        argv = self.post(["notify", "codex"], {"session_id": "019a-codex", "cwd": self.cwd, "hook_event_name": "Stop"},
                         CODEX_HOME=codex_home)
        self.assertEqual(opt(argv, "--title"), "Codex finished: Billing cleanup (my-repo)")

    def test_gemini(self):
        p = {"session_id": "gem-1", "cwd": self.cwd, "hook_event_name": "AfterAgent", "prompt": SECRET,
             "prompt_response": "Found two configs. Which one should I keep?", "stop_hook_active": False}
        argv = self.post(["notify", "gemini"], p, CLAUDE_PROJECT_DIR=self.cwd)
        self.assertEqual(opt(argv, "--title"), "Gemini asks: Which one should I keep? · my-repo")
        self.assertNotIn(SECRET, json.dumps(argv))

    def test_opencode(self):
        p = {"session_id": "ses_1", "cwd": self.cwd, "hook_event_name": "Stop", "session_title": "Refactor auth",
             "last_assistant_message": "Done. Should I push the branch?"}
        argv = self.post(["notify", "opencode"], p)
        self.assertEqual(opt(argv, "--title"), "opencode asks: Should I push the branch? · Refactor auth (my-repo)")
        argv = self.post(["notify", "opencode"], dict(p, last_assistant_message="Done."))
        self.assertEqual(opt(argv, "--title"), "opencode finished: Refactor auth (my-repo)")

    def test_kimi_title_and_finished(self):
        p = {"session_id": "session_k", "cwd": self.cwd, "hook_event_name": "Stop", "client_type": "kimi_code_cli",
             "session_title": "Fix flaky test", "stop_hook_active": False}
        argv = self.post(["notify", "kimi"], p)
        self.assertEqual(opt(argv, "--title"), "Kimi finished: Fix flaky test (my-repo)")
        argv = self.post(["notify", "kimi"], dict(p, session_title="key %s" % SECRET))
        self.assertEqual(opt(argv, "--title"), "Kimi finished: my-repo")

    def test_cline_result(self):
        p = {"taskId": "conv_1", "workspaceRoots": [self.cwd], "hookName": "agent_end", "parent_agent_id": None,
             "taskComplete": {"taskMetadata": {"result": "I added the tests. Do you want CI wired up too?"}}}
        argv = self.post(["notify", "cline", "TaskComplete"], p, cwd=self.home)
        self.assertEqual(opt(argv, "--title"), "Cline asks: Do you want CI wired up too? · my-repo")

    def test_finished_only_agents(self):
        argv = self.post(["notify", "copilot"], {"sessionId": "cp-1", "cwd": self.cwd, "stopReason": "end_turn"})
        self.assertEqual(opt(argv, "--title"), "Copilot finished: my-repo")
        argv = self.post(["notify", "grok"], {"session_id": "g-1", "cwd": self.cwd, "hook_event_name": "Notification",
                                              "notificationType": "idle_prompt"})
        self.assertEqual(opt(argv, "--title"), "Grok finished: my-repo")
        argv = self.post(["notify", "cursor"], {"conversation_id": "c-1", "workspace_roots": [self.cwd],
                                                "hook_event_name": "stop", "status": "completed"}, cwd=self.home)
        self.assertEqual(opt(argv, "--title"), "Cursor finished: my-repo")
        argv = self.post(["notify", "copilot"], {"sessionId": "cp-2", "cwd": self.cwd, "stopReason": "end_turn"},
                         NEEDS_YOU_TURN_TEXT="0")
        self.assertEqual(opt(argv, "--title"), "Copilot is waiting for you: my-repo")


if __name__ == "__main__":
    unittest.main()
