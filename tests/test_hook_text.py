"""Agent text on a card is shown, never trusted (prompt injection can write it).

The Mac renders a card's body, step text and question text as inline Markdown
(LimitedMarkdown: AttributedString(markdown:), CommonMark), so a link there shows only its
label. Whatever the agent wrote, the hook must not hand those fields a link: every link in
CommonMark starts at an unescaped "[" (an inline link, a reference link, an image), so the
hook escapes them, whatever the nesting, instead of rewriting the links it recognises (a
one-pass rewrite can leave or reassemble a link it didn't see). Invisible and control
characters go before redaction, so they can't split a secret the card then shows whole."""
from __future__ import annotations

import json
import re
import unittest

from hook_case import posted_item
from test_hook_events import HookHarness

# Inputs that render as a clickable link in CommonMark; the one-pass rewrite missed each.
LINKS = [
    "[[Approve](https://a.example/x)](https://evil.example/nested)",   # rewrite reassembles it
    "[a [b] c](https://evil.example/brackets)",                       # brackets in the label
    "[Approve](https://evil.example/a(b))",                           # parentheses in the URL
    "[Approve](https://evil.example/t 'a title')",                    # a single-quoted title
    "[Approve](<https://evil.example/a b>)",                          # an angle-bracket URL
    "\\[x\\][Approve](https://evil.example/escaped)",                  # escapes before it
    "\\\\[Approve](https://evil.example/backslash)",                  # an escaped backslash
    "[Ap\u200bprove](https://evil.example/zw)",                        # invisible in the label
    "[Approve]\u200b(https://evil.example/zw2)",                       # invisible in the syntax
    "[Approve][r]\n\n[r]: https://evil.example/reference",            # a reference link
]


def live_brackets(text):
    """Positions of "[" not escaped by an odd run of backslashes: where a link could start."""
    return [m.end(1) for m in re.finditer(r"(?<!\\)((?:\\\\)*)\[", text)]


def assert_inert(test, text, where):
    """No link: CommonMark needs "](" (inline) or "]:" (a reference definition) for one."""
    if re.search(r"\][(:]", text):
        test.assertEqual(live_brackets(text), [], "%s can render a link: %r" % (where, text))


class LinksInAgentText(HookHarness):
    def test_no_link_survives_in_a_question_card(self):
        for link in LINKS:
            argv = self.permission_question(link)
            item = posted_item(argv)
            assert_inert(self, item["body"], "the body of %r" % link)
            for q in (item.get("question") or {}).get("items", []):
                assert_inert(self, q["text"], "the question text of %r" % link)

    def test_no_link_survives_in_choices_shown_as_steps(self):
        for link in LINKS:
            argv = self.permission_question("Which one?", label="Yes " + link.replace("\n", " "),
                                            NEEDS_YOU_BIN=self.old_cli())
            for s in posted_item(argv).get("steps") or []:
                assert_inert(self, s["text"], "a step of %r" % link)

    def test_no_link_survives_in_a_plan(self):
        for link in LINKS:
            self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "ExitPlanMode",
                                     "tool_input": {"plan": "1. do it\n" + link}, "permission_mode": "default"})
            assert_inert(self, posted_item(self.last())["body"], "the plan body of %r" % link)

    def test_the_link_stays_readable(self):
        argv = self.permission_question("Go? [Approve](https://evil.example/x)")
        q = posted_item(argv)["question"]["items"][0]["text"]
        self.assertIn("https://evil.example/x", q)
        self.assertIn("Approve", q)

    def test_text_without_links_is_unchanged(self):
        argv = self.permission_question("Index `arr[0]` or [1]?")
        self.assertEqual(posted_item(argv)["question"]["items"][0]["text"], "Index `arr[0]` or [1]?")

    def permission_question(self, text, label="Yes", **extra):
        self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
                                 "tool_input": {"questions": [{"question": text, "header": "Q", "multiSelect": False,
                                                               "options": [{"label": label, "description": ""},
                                                                           {"label": "No", "description": ""}]}]},
                                 "permission_mode": "default"}, **extra)
        return self.last()

    def old_cli(self):
        """A CLI without --question-json: the choices go out as steps."""
        import os
        path = os.path.join(self.home, "old-needs-you")
        with open(path, "w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json, os, sys\n"
                     "with open(os.environ['FAKE_CLI_LOG'], 'a') as fh:\n"
                     "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                     "sys.exit(2 if any(a.startswith('--question-json') for a in sys.argv) else 0)\n")
        os.chmod(path, 0o755)
        return path


# One of each class of character a card must not carry (shown, they hide or reorder text,
# or move the terminal): C0, ESC sequences, DEL, C1 (CSI), bidi overrides and isolates,
# zero-width and joiners, the BOM, line and paragraph separators, soft hyphen, the Arabic
# letter mark, Mongolian and other variation selectors, Hangul fillers, the combining
# grapheme joiner, interlinear annotation, musical format marks and tag characters (invisible
# "ASCII smuggling").
INVISIBLE = ["\x00", "\x07", "\x1b[2J", "\x1b]52;c;aGk=\x07", "\x7f", "\x85", "\x9b", "\u202e", "\u2067",
             "\u200b", "\u200d", "\u2060", "\ufeff", "\u2028", "\u2029", "\u00ad", "\u061c", "\u180b",
             "\ufe0f", "\U000e0100", "\u115f", "\u3164", "\uffa0", "\u034f", "\ufff9", "\U0001d173",
             "\U000e0041", "\U000e007f", "\u17b4"]
STRIPPED = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f"
                      "\u200b-\u200f\u2028-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0\ufff9-\ufffb"
                      "\U0001d173-\U0001d17a\U000e0000-\U000e0fff]")


class InvisibleCharacters(HookHarness):
    def test_every_class_is_stripped_from_every_field(self):
        for ch in INVISIBLE:
            text = "Ship%sit now?" % ch
            self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
                                     "tool_input": {"questions": [{"question": text, "header": "H%sx" % ch,
                                                                   "multiSelect": False,
                                                                   "options": [{"label": "Y%ses" % ch,
                                                                                "description": "d%sd" % ch},
                                                                               {"label": "No", "description": ""}]}]},
                                     "permission_mode": "default"})
            item = posted_item(self.last())
            shown = json.dumps(item, ensure_ascii=False)
            self.assertIsNone(STRIPPED.search(shown.replace("\\n", "")), "%r reaches the card" % ch)

    def test_an_invisible_character_cant_split_a_secret(self):
        """Removed before redaction, so the token it split is redacted, not shown whole."""
        token = "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        for ch in ("\U000e0041", "\ufe0f", "\u3164", "\u034f", "\u200b"):
            split = token[:6] + ch + token[6:]
            self.run_hook("notify", {"hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
                                     "tool_input": {"questions": [{"question": "Use %s?" % split, "header": "Q",
                                                                   "multiSelect": False, "options": []}]},
                                     "permission_mode": "default"})
            shown = STRIPPED.sub("", json.dumps(posted_item(self.last()), ensure_ascii=False))
            self.assertNotIn(token[6:20], shown, repr(ch))

    def test_the_project_name_is_cleaned(self):
        import os
        odd = os.path.join(self.home, "src", "re\u202epo\u200b\U000e0041x")
        os.makedirs(odd)
        self.cwd = odd
        self.run_hook("notify", {"hook_event_name": "Notification", "message": "Claude needs your permission",
                                 "cwd": odd})
        item = posted_item(self.last())
        self.assertIsNone(STRIPPED.search(item["title"] + item["body"]), item["title"])


if __name__ == "__main__":
    unittest.main()
