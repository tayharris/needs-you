"""Every shape a sender can post, as one catalog (docs/API.md "POST /v1/items").

`ACCEPTED` items are posted by tests/test_format_cases.py (the hub takes each as given) and by
mac/scripts/format-fixtures.py, which turns them into the demo fixture that
mac/scripts/screenshots.sh draws card by card: so every format an agent can send is seen on a
card before it ships. `REPOSTS` update some of them under the same key, as a sender's next run
would. `REFUSED` must each be a 400 naming `field`. `CLI` maps `needs-you` flags to the item
they produce. Example names only (acme, devbox).
"""
from __future__ import annotations

LOREM = ("The migration plan touches the orders and invoices tables. It needs one decision before it "
         "edits anything, and the reasoning is in the PR thread. ")
LONG_URL = "https://github.com/acme/acme-web/blob/6f1c0d3e9b2a47e5a8c1f0d2b3e4a5c6d7e8f901/" + "very-long-path-segment-" * 12 + "file.py#L120-L180"
TERMINAL = {"label": "Terminal", "url": "needsyou://terminal/focus?app=wezterm&pane=3"}


def src(agent="claude-code", project="acme-web", host="devbox"):
    return {k: v for k, v in (("host", host), ("agent", agent), ("project", project)) if v}


def options(n, prefix="Option", desc=""):
    return [{"label": "%s %d" % (prefix, i + 1), "description": desc} for i in range(n)]


# (name, item). Keys are fmt:<nn>-<name> so the Mac draws them in this order.
ACCEPTED = [
    ("minimal", {"title": "Approve the deploy"}),
    ("title-max", {"title": ("Review the database migration plan for acme-web before the 5 pm freeze, "
                             "and pick a column name")[:100], "source": src()}),
    ("title-long-word", {"title": ("Check " + "acme-web-checkout-service-blue-green-canary-rollback-" * 2)[:100],
                         "body": "One unbroken word in the title.", "source": src()}),
    ("title-long-url", {"title": "Open https://github.com/acme/acme-web/pull/412/files#diff-6f1c0d3e9b2a47e5a8c1f0d2",
                        "source": src()}),
    ("body-max", {"title": "Read the plan: the body is at its 2,000-character limit",
                  "body": (LOREM * 20)[:2000], "source": src()}),
    ("body-lines", {"title": "Line breaks, blank lines and lists",
                    "body": ("First line.\nSecond line, after a single newline.\n\nA new paragraph after a "
                             "blank line.\n- a dash bullet\n* a star bullet\n+ a plus bullet\n  - an indented "
                             "bullet\n1. a numbered line\n2. another numbered line\n\tA tab-indented line."),
                    "source": src()}),
    ("body-markdown", {"title": "Every Markdown mark an agent might write",
                       "body": ("**bold**, *italic*, _underscore italic_, ***both***, `inline code`, "
                                "~~struck~~, [a link](https://github.com/acme/acme-web/pull/412), "
                                "[an http link](http://example.com), <b>html</b>, "
                                "![an image](https://example.com/x.png)\n"
                                "# A heading\n## A smaller heading\n> A quoted line\n"
                                "```\nmake migrate\n```\n| a | b |\n|---|---|\n| 1 | 2 |\n---\nAfter the rule."),
                       "source": src()}),
    ("body-long-url", {"title": "A long unbroken URL and hash in the body",
                       "body": "See " + LONG_URL + "\nsha256 " + "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" * 2,
                       "source": src()}),
    ("emoji", {"title": "\U0001F680 Ship it? \U0001F44D or \U0001F44E \U0001F468‍\U0001F469‍\U0001F467 \U0001F1EF\U0001F1F5",
               "body": "Emoji in text: ✅ tests pass, ⚠️ one warning, \U0001F9EA flaky test. "
                       "Skin tones \U0001F44B\U0001F3FD and a family \U0001F469‍\U0001F469‍\U0001F466.",
               "source": src()}),
    ("rtl", {"title": "אשר את הפריסה deploy v2.14",
             "body": "مرحبا: هل ننشر الآن؟ "
                     "Mixed with English and `code`.\nשורה שנייה "
                     "‏with a right-to-left mark.",
             "source": src()}),
    ("cjk", {"title": "请审批生产环境部署：数据库迁移计划"
                      "已准备好，需要在下午五点前确认"
                      "列名和回滚方案",
             "body": "日本語の本文も折り返されるはず"
                     "です。한국어 본문도.",
             "source": src()}),
    ("urgent", {"title": "Prod is down: approve the rollback", "priority": "urgent",
                "links": [{"label": "Rollback", "url": "https://ci.example.com/deploys/4182/rollback"}],
                "source": src("deploy-bot", "api", "build-box")}),
    ("low", {"title": "feature/old-search has 2 unpushed commits", "priority": "low",
             "source": src("cron:cleanup", None, "devbox")}),
    ("personal", {"title": "Renew example.org: it expires in 9 days", "context": "personal",
                  "source": src("cron:domains", None, "home-server")}),
    ("done", {"title": "Nightly e2e: 214 passed, 0 failed", "kind": "done",
              "links": [{"label": "Run", "url": "https://github.com/acme/acme-web/actions/runs/8841"}],
              "source": src("github-actions", "acme-web", "ci")}),
    ("info", {"title": "acme-web 1.4 is on staging", "kind": "info", "source": src("deploy-bot", "acme-web", "ci")}),
    ("links-web", {"title": "Links: every https-like scheme", "links": [
        {"label": "PR #412", "url": "https://github.com/acme/acme-web/pull/412/files"},
        {"label": "Slack", "url": "slack://channel?team=T0ACME&id=C0DEPLOY"},
        {"label": "Figma", "url": "figma://file/AbCdEf123/Checkout"},
        {"label": "Teams", "url": "msteams://teams.microsoft.com/l/channel/19%3Aabc/General"},
        {"label": "Discord", "url": "discord://discord.com/channels/1/2"},
        {"label": "Linear", "url": "linear://acme/issue/ACME-123"}], "source": src()}),
    ("links-editor", {"title": "Links: editors and the app's terminal actions", "links": [
        {"label": "VS Code", "url": "vscode://file/Users/dev/acme-web/src/app.py:42:7"},
        {"label": "Remote", "url": "vscode://vscode-remote/ssh-remote+devbox/home/dev/acme-web"},
        {"label": "Claude", "url": "vscode://anthropic.claude-code/open?session=0f1e2d3c-4b5a"},
        {"label": "Cursor", "url": "cursor://file/Users/dev/acme-web/README.md"},
        TERMINAL,
        {"label": "Orca", "url": "needsyou://orca/terminal?handle=term_0f1e2d3c4b5a&environment=devbox"}],
        "source": src()}),
    ("links-long", {"title": "Links: long labels and a long URL", "links": [
        {"label": "A link label that runs to the full eighty characters the hub allows, no more!!"[:80],
         "url": LONG_URL},
        {"label": "Canary", "url": "https://grafana.example.com/d/api-canary"},
        {"label": "Short", "url": "https://example.com"}], "source": src()}),
    ("steps-max", {"title": "Rotate the Stripe key before 3 pm",
                   "body": "The old key leaked in a CI log (build 812).",
                   "steps": [{"text": "Step %d: %s" % (i + 1, t)} for i, t in enumerate([
                       "Roll the key in the dashboard", "Paste it into the vault as `billing/stripe`",
                       "Restart the **billing** workers", "Check the *error rate*", "Tell #billing",
                       "Revoke the old key", "Close ACME-123", "Re-run the CI job", "Watch it for an hour",
                       "Resolve this card"])], "source": src("orca:secret-scanner", "billing")}),
    ("steps-shapes", {"title": "Steps: links, done, long text",
                      "steps": [
                          {"text": "Done by the sender", "done": True},
                          {"text": "With a link", "link": {"label": "Approve", "url": "https://ci.example.com/x"}},
                          {"text": ("A step at the 200-character limit, which wraps over several lines on a card "
                                    "so the checkbox, its number and the text must still line up properly when "
                                    "it does, and nothing is cut off.")[:200]},
                          {"text": "A terminal action", "link": TERMINAL},
                          {"text": "Unbroken " + "x" * 120}],
                      "source": src()}),
    ("q-single", {"title": "Claude asks “Which database?”: acme-api",
                  "body": "Answer in Claude.",
                  "question": {"id": "toolu_fmt1", "items": [{"header": "Database", "text": "Which database should the service use?",
                               "options": [{"label": "Postgres (Recommended)", "description": "Mature, already used by the team."},
                                           {"label": "SQLite", "description": "Zero ops, single file."},
                                           {"label": "DynamoDB"}]}]},
                  "links": [TERMINAL], "source": src(project="acme-api")}),
    ("q-multi", {"title": "Claude asks “Which extras?”: acme-api",
                 "question": {"items": [{"header": "Extras", "text": "Which extras should it ship with?", "multi_select": True,
                                         "options": [{"label": "Metrics"}, {"label": "Tracing", "description": "OpenTelemetry"},
                                                     {"label": "Profiling"}]}]},
                 "source": src(project="acme-api")}),
    ("q-many-long", {"title": "Claude asks about naming: 8 long options",
                     "question": {"items": [{"header": "A header of thirty characters"[:30],
                                             "text": ("Which name should the new column take? " * 12)[:500],
                                             "options": [{"label": ("Option %d: " % (i + 1)) + ("account_owner_identifier_" * 4)[:70],
                                                          "description": ("Why this one: " + "it matches the API field and the docs; " * 6)[:200]}
                                                         for i in range(8)]}]},
                     "source": src()}),
    ("q-free-text", {"title": "Claude asks “What should the file be called?”",
                     "body": "Answer in Claude.",
                     "question": {"items": [{"text": "What should the new config file be called?\nIt goes in `config/`."}]},
                     "links": [TERMINAL], "source": src()}),
    ("q-four", {"title": "Claude asks 4 questions: acme-web",
                "question": {"items": [
                    {"header": "Branch", "text": "Which branch?", "options": options(2, "Branch")},
                    {"text": "Which platforms?", "multi_select": True, "options": options(3, "Platform")},
                    {"header": "Name", "text": "What should it be called?"},
                    {"header": "Notify", "text": "Who should hear about it?", "options": options(2, "Team", "a channel")}]},
                "source": src()}),
    ("q-dup-readonly", {"title": "A read-only question may repeat a label",
                        "question": {"items": [{"text": "Which one?", "options": [{"label": "Yes", "description": "the first"},
                                                                                   {"label": "Yes", "description": "the second"}]}]},
                        "source": src()}),
    ("q-answerable-single", {"title": "opencode asks “Release from which branch?”",
                             "body": "Pick here or answer in opencode.",
                             "question": {"id": "que_fmt1", "answerable": True, "items": [
                                 {"header": "Branch", "text": "Which branch should the release come from?",
                                  "options": [{"label": "main", "description": "Everything merged today"},
                                              {"label": "release/1.4", "description": "Only the fixes"}]}]},
                             "links": [TERMINAL], "source": src("opencode")}),
    ("q-answerable-multi", {"title": "opencode asks 2 questions: acme-web",
                            "question": {"id": "que_fmt2", "answerable": True, "items": [
                                {"header": "Branch", "text": "Which branch?", "options": options(2, "Branch")},
                                {"header": "Platforms", "text": "Which platforms?", "multi_select": True,
                                 "options": [{"label": "macOS"}, {"label": "Linux"}, {"label": "Windows"}]}]},
                            "links": [TERMINAL], "source": src("opencode")}),
    ("q-answerable-max", {"title": "An answerable card at every limit: 4 questions of 8 options",
                          "question": {"id": "que_fmt3", "answerable": True, "items": [
                              {"header": "Q%d" % (q + 1), "text": "Question %d?" % (q + 1), "multi_select": q % 2 == 1,
                               "options": options(8, "Choice %d." % (q + 1))} for q in range(4)]},
                          "source": src("opencode")}),
    ("source-long", {"title": "Long source fields", "source": {"host": "h" * 100, "agent": "a" * 100, "project": "p" * 100}}),
]

# Re-posts under the same key (fmt:<nn>-<name>): what changes, and whether the hub says changed.
REPOSTS = [
    ("minimal", {"title": "Approve the deploy (now 2 regions waiting)", "priority": "urgent",
                 "body": "The re-post changed the title, added a body and raised the priority."}, True),
    ("steps-max", {"title": "Rotate the Stripe key before 3 pm",
                   "body": "The old key leaked in a CI log (build 812). Steps 1-2 are done.",
                   "steps": [{"text": "Step 1: Roll the key in the dashboard", "done": True},
                             {"text": "Step 2: Paste it into the vault as `billing/stripe`", "done": True},
                             {"text": "Step 3: Restart the **billing** workers"}],
                   "source": src("orca:secret-scanner", "billing")}, True),
    ("q-answerable-single", {"title": "opencode asks “Release from which tag?”",
                             "body": "A new question under the same key.",
                             "question": {"id": "que_fmt1b", "answerable": True, "items": [
                                 {"header": "Tag", "text": "Which tag should the release use?",
                                  "options": [{"label": "v1.4.0"}, {"label": "v1.4.1-rc1"}]}]},
                             "links": [TERMINAL], "source": src("opencode")}, True),
    ("q-answerable-multi", {"title": "opencode asks 2 questions: acme-web",
                            "question": {"id": "que_fmt2b", "answerable": True, "items": [
                                {"header": "Branch", "text": "Which branch?", "options": options(3, "Branch")},
                                {"header": "Platforms", "text": "Which platforms?", "multi_select": True,
                                 "options": [{"label": "macOS"}, {"label": "Linux"}]}]},
                            "links": [TERMINAL], "source": src("opencode")}, True),
    ("links-web", {"title": "Links: every https-like scheme",
                   "links": [{"label": "PR #413", "url": "https://github.com/acme/acme-web/pull/413/files"}],
                   "source": src()}, False),
]

# (name, item, field): each a 400 naming `field`.
REFUSED = [
    ("title-missing", {}, "title"),
    ("title-blank", {"title": "   "}, "title"),
    ("title-too-long", {"title": "x" * 101}, "title"),
    ("title-newline", {"title": "two\nlines"}, "title"),
    ("title-line-separator", {"title": "two lines"}, "title"),
    ("title-bidi-override", {"title": "evil‮moc.live"}, "title"),
    ("body-too-long", {"title": "t", "body": "x" * 2001}, "body"),
    ("body-control", {"title": "t", "body": "bell\x07"}, "body"),
    ("priority-unknown", {"title": "t", "priority": "high"}, "priority"),
    ("context-unknown", {"title": "t", "context": "home"}, "context"),
    ("kind-unknown", {"title": "t", "kind": "question"}, "kind"),
    ("status-given", {"title": "t", "status": "open"}, "status"),
    ("key-space", {"title": "t", "key": "a key"}, "key"),
    ("links-seven", {"title": "t", "links": [{"label": "l", "url": "https://example.com/%d" % i} for i in range(7)]}, "links"),
    ("link-http", {"title": "t", "links": [{"label": "l", "url": "http://example.com"}]}, "links[0].url"),
    ("link-javascript", {"title": "t", "links": [{"label": "l", "url": "javascript:alert(1)"}]}, "links[0].url"),
    ("link-label-too-long", {"title": "t", "links": [{"label": "x" * 81, "url": "https://example.com"}]}, "links[0].label"),
    ("link-label-blank", {"title": "t", "links": [{"label": " ", "url": "https://example.com"}]}, "links[0].label"),
    ("step-link-label-blank", {"title": "t", "steps": [{"text": "a", "link": {"label": "", "url": "https://example.com"}}]},
     "steps[0].link.label"),
    ("link-vscode-extension", {"title": "t", "links": [{"label": "l", "url": "vscode://acme.ext/run"}]}, "links[0].url"),
    ("link-needsyou-unknown", {"title": "t", "links": [{"label": "l", "url": "needsyou://settings/open"}]}, "links[0].url"),
    ("steps-eleven", {"title": "t", "steps": [{"text": "s%d" % i} for i in range(11)]}, "steps"),
    ("step-newline", {"title": "t", "steps": [{"text": "a\nb"}]}, "steps[0].text"),
    ("step-too-long", {"title": "t", "steps": [{"text": "x" * 201}]}, "steps[0].text"),
    ("step-done-string", {"title": "t", "steps": [{"text": "a", "done": "yes"}]}, "steps[0].done"),
    ("q-five", {"title": "t", "question": {"items": [{"text": "q%d" % i} for i in range(5)]}}, "question.items"),
    ("q-nine-options", {"title": "t", "question": {"items": [{"text": "q", "options": options(9)}]}}, "question.items[0].options"),
    ("q-label-too-long", {"title": "t", "question": {"items": [{"text": "q", "options": [{"label": "x" * 81}]}]}},
     "question.items[0].options[0].label"),
    ("q-description-too-long", {"title": "t", "question": {"items": [{"text": "q", "options": [
        {"label": "a", "description": "x" * 201}]}]}}, "question.items[0].options[0].description"),
    ("q-header-too-long", {"title": "t", "question": {"items": [{"header": "x" * 31, "text": "q"}]}}, "question.items[0].header"),
    ("q-text-too-long", {"title": "t", "question": {"items": [{"text": "x" * 501}]}}, "question.items[0].text"),
    ("q-no-items", {"title": "t", "question": {"items": []}}, "question.items"),
    ("q-multi-string", {"title": "t", "question": {"items": [{"text": "q", "multi_select": "yes"}]}},
     "question.items[0].multi_select"),
    ("q-answerable-free-text", {"title": "t", "question": {"answerable": True, "items": [{"text": "q"}]}}, "question.answerable"),
    ("q-answerable-dup", {"title": "t", "question": {"answerable": True, "items": [{"text": "q", "options": [
        {"label": "Yes"}, {"label": "Yes"}]}]}}, "question.items[0].options[1].label"),
]

# (argv after `needs-you`, fields the stored item must have). Run by tests/test_format_cases.py.
CLI = [
    (["add", "--key", "cli:basic", "--title", "Approve", "--body", "**Why**: canary green.\nSecond line.",
      "--priority", "urgent", "--context", "personal", "--agent", "orca:x", "--project", "acme"],
     {"title": "Approve", "body": "**Why**: canary green.\nSecond line.", "priority": "urgent",
      "context": "personal", "kind": "needs", "source": {"host": "testbox", "agent": "orca:x", "project": "acme"}}),
    (["add", "--key", "cli:links", "--title", "Links", "--link", "PR=https://github.com/acme/a/pull/1",
      "--link", "Term=needsyou://terminal/focus?app=wezterm&pane=3"],
     {"links": [{"label": "PR", "url": "https://github.com/acme/a/pull/1"},
                {"label": "Term", "url": "needsyou://terminal/focus?app=wezterm&pane=3"}]}),
    (["add", "--key", "cli:bare-link", "--title", "Bare", "--link", "https://example.com/?a=b"],
     {"links": [{"label": "Link", "url": "https://example.com/?a=b"}]}),
    (["add", "--key", "cli:steps", "--title", "Steps", "--step", "Roll it=https://example.com/roll",
      "--step", "Set MODE=live"],
     {"steps": [{"text": "Roll it", "done": False, "link": {"label": "Open", "url": "https://example.com/roll"}},
                {"text": "Set MODE=live", "done": False}]}),
    (["add", "--key", "cli:steps-json", "--title", "Steps", "--steps-json",
      '[{"text": "Approve", "link": {"label": "Approve", "url": "https://example.com/a"}}, {"text": "Done one", "done": true}]'],
     {"steps": [{"text": "Approve", "done": False, "link": {"label": "Approve", "url": "https://example.com/a"}},
                {"text": "Done one", "done": True}]}),
    (["add", "--key", "cli:question", "--title", "Pick", "--question-json",
      '{"id": "q1", "answerable": true, "items": [{"text": "Which?", "multi_select": true, "options": [{"label": "A"}, {"label": "B"}]}]}'],
     {"question": {"id": "q1", "answerable": True, "items": [
         {"header": "", "text": "Which?", "multi_select": True,
          "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]}]}}),
    (["done", "--key", "cli:done", "--title", "Finished"], {"kind": "done"}),
    (["info", "--key", "cli:info", "--title", "FYI"], {"kind": "info"}),
]
