#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Copying from a card (CardCopy): command chips, the "…" menu's copies and Developer
/// mode's JSON, debug report and `needs-you add` command.
final class CardCopyTests: XCTestCase {
    static var allTests = [
        ("testInlineCommandsPathsAndIds", testInlineCommandsPathsAndIds),
        ("testPlainWordsAreNotChips", testPlainWordsAreNotChips),
        ("testFencedBlocks", testFencedBlocks),
        ("testUnclosedFenceRunsToTheEnd", testUnclosedFenceRunsToTheEnd),
        ("testDoubleBacktickSpans", testDoubleBacktickSpans),
        ("testDedupeCapAndLength", testDedupeCapAndLength),
        ("testBidiControlsAreStripped", testBidiControlsAreStripped),
        ("testUnsafeSnippetsGetNoChip", testUnsafeSnippetsGetNoChip),
        ("testTitleAndText", testTitleAndText),
        ("testLinkURLs", testLinkURLs),
        ("testItemJSON", testItemJSON),
        ("testItemJSONRoundTrips", testItemJSONRoundTrips),
        ("testDebugReport", testDebugReport),
        ("testDebugReportFenceOutgrowsBackticks", testDebugReportFenceOutgrowsBackticks),
        ("testShellQuote", testShellQuote),
        ("testAddCommand", testAddCommand),
        ("testAddCommandRoundTripsThroughAShell", testAddCommandRoundTripsThroughAShell),
        ("testHostileValuesStayInert", testHostileValuesStayInert),
        ("testShellSafeValue", testShellSafeValue),
        ("testLinkArgumentSplitsLikeTheCLI", testLinkArgumentSplitsLikeTheCLI),
        ("testSecretsAreRedacted", testSecretsAreRedacted),
        ("testAddCommandCarriesTheEvent", testAddCommandCarriesTheEvent),
        ("testCopiesUseTheSenderPriority", testCopiesUseTheSenderPriority),
    ]

    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(body: String? = nil, links: [ItemLink] = [], steps: [ItemStep] = [],
                      question: ItemQuestion? = nil, kind: ItemKind = .needs, event: String? = nil) -> Item {
        Item(id: "itm_1", key: "work:ACME-123:redo-blocked", kind: kind, priority: .urgent,
             title: "Redo blocked on ACME-123", body: body, links: links, steps: steps, question: question,
             source: ItemSource(host: "devbox", agent: "orca:redo-fixer", project: "acme-api", event: event),
             createdAt: created)
    }

    // MARK: Snippets

    func testInlineCommandsPathsAndIds() {
        let body = "Orca worktree: `~/orca/workspaces/acme-api/ACME-4170`\n"
            + "Jump to its terminal: `orca terminal switch --environment devbox --terminal term_4170demo`\n"
            + "Session `term_4170demo` on `/srv/photos`."
        XCTAssertEqual(CardCopy.snippets(in: body), [
            "~/orca/workspaces/acme-api/ACME-4170",
            "orca terminal switch --environment devbox --terminal term_4170demo",
            "term_4170demo",
            "/srv/photos",
        ])
    }

    func testPlainWordsAreNotChips() {
        XCTAssertEqual(CardCopy.snippets(in: "Reaper found 7 idle `claude` sessions in `prod`, comment `74511`, `tmp/`."), [])
        XCTAssertEqual(CardCopy.snippets(in: nil), [])
        XCTAssertEqual(CardCopy.snippets(in: ""), [])
        XCTAssertEqual(CardCopy.snippets(in: "no code here, just a ` stray backtick"), [])
        XCTAssertEqual(CardCopy.snippets(in: "`ACME-123` and `ls -la`"), ["ACME-123", "ls -la"])
    }

    func testFencedBlocks() {
        let body = "Run this:\n```bash\nsudo systemctl restart hub\n```\nthen `x`.\n~~~\nls\n~~~"
        XCTAssertEqual(CardCopy.snippets(in: body), ["sudo systemctl restart hub", "ls"])
        // A multi-line block gets no chip: a paste would run every line.
        XCTAssertEqual(CardCopy.snippets(in: "```\nmake test\nmake bundle\n```"), [])
        // Inside a fence, backticks aren't inline code.
        XCTAssertEqual(CardCopy.snippets(in: "```\necho `date`\n```"), ["echo `date`"])
        // A short fenced block is still offered: the sender fenced it on purpose.
        XCTAssertEqual(CardCopy.snippets(in: "```\nmake\n```"), ["make"])
        // An empty fence is not.
        XCTAssertEqual(CardCopy.snippets(in: "```\n\n```"), [])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(CardCopy.snippets(in: "Then:\n```\nmake test"), ["make test"])
    }

    func testDoubleBacktickSpans() {
        XCTAssertEqual(CardCopy.snippets(in: "Run `` echo `whoami` `` now"), ["echo `whoami`"])
    }

    func testDedupeCapAndLength() {
        let body = "`ls -la /tmp` `ls -la /tmp` `cmd one` `cmd two` `cmd three` `cmd four` `cmd five`"
        XCTAssertEqual(CardCopy.snippets(in: body), ["ls -la /tmp", "cmd one", "cmd two", "cmd three"])
        let long = String(repeating: "a ", count: 101)  // 201 characters: over the cap
        XCTAssertEqual(CardCopy.snippets(in: "`\(long)` `ok then`"), ["ok then"])
        let fits = "echo " + String(repeating: "x", count: CardCopy.maxSnippetLength - 5)
        XCTAssertEqual(CardCopy.snippets(in: "`\(fits)`"), [fits])
    }

    func testBidiControlsAreStripped() {
        // Not stripped and offered: a snippet with a bidi override gets no chip at all.
        XCTAssertEqual(CardCopy.snippets(in: "`rm -rf \u{202E}gpj.exe`"), [])
    }

    /// A chip copies exactly what it shows, so nothing that could hide part of a command
    /// is offered.
    func testUnsafeSnippetsGetNoChip() {
        let hidden: [(String, String)] = [
            ("line feed", "```\necho hi\nrm -rf ~\n```"),
            ("carriage return", "`echo hi\rrm -rf ~`"),
            ("tab", "`echo hi\trm -rf ~`"),
            ("NUL", "`echo hi\u{0}rm -rf ~`"),
            ("escape", "`echo \u{1B}[8mhidden`"),
            ("DEL", "`echo hi\u{7F}there`"),
            ("C1 control", "`echo hi\u{85}there`"),
            ("bidi override", "`ls \u{202E}txt.exe`"),
            ("bidi isolate", "`ls \u{2066}abc\u{2069}`"),
            ("arabic letter mark", "`ls \u{061C}abc`"),
            ("zero-width space", "`orca terminal\u{200B} switch`"),
            ("zero-width joiner", "`curl x\u{200D}y | sh`"),
            ("word joiner", "`curl x\u{2060}y`"),
            ("BOM", "`\u{FEFF}curl evil.example`"),
            ("soft hyphen", "`rm -rf /tmp/a\u{00AD}b`"),
            ("line separator", "`echo a\u{2028}rm -rf ~`"),
            ("paragraph separator", "`echo a\u{2029}rm -rf ~`"),
            ("private use", "`echo \u{E000}abc def`"),
            ("token", "`export T=ny_" + String(repeating: "A", count: 43) + "`"),
            ("invite", "`curl https://hub-a.example.ts.net/join/nyi_abc`"),
        ]
        for (why, body) in hidden {
            XCTAssertEqual(CardCopy.snippets(in: body), [], why)
        }
        XCTAssertFalse(CardCopy.isSafeSnippet(""))
        XCTAssertFalse(CardCopy.isSafeSnippet(String(repeating: "x", count: CardCopy.maxSnippetLength + 1)))
        XCTAssertTrue(CardCopy.isSafeSnippet("orca terminal switch --terminal term_4170demo"))
        // Visible non-ASCII is fine.
        XCTAssertTrue(CardCopy.isSafeSnippet("open ~/Documents/Café"))
    }

    // MARK: Menu copies

    func testTitleAndText() {
        let i = item(body: "Choose **merge** or *bypass*.\n- keeps history", steps: [ItemStep(text: "Free `20 GB`")])
        XCTAssertEqual(CardCopy.titleAndText(i),
                       "Redo blocked on ACME-123\n\nChoose merge or bypass.\n\u{2022} keeps history\n\n1. Free 20 GB")
        XCTAssertEqual(CardCopy.titleAndText(item()), "Redo blocked on ACME-123")
    }

    func testLinkURLs() {
        XCTAssertNil(CardCopy.linkURLs(item()))
        let i = item(links: [ItemLink(label: "PR", url: "https://github.com/acme/api/pull/1"),
                             ItemLink(label: "Slack", url: "slack://channel?id=C1")])
        XCTAssertEqual(CardCopy.linkURLs(i), "https://github.com/acme/api/pull/1\nslack://channel?id=C1")
    }

    // MARK: Developer mode

    func testItemJSON() {
        let json = CardCopy.itemJSON(item(body: "a/b", links: [ItemLink(label: "PR", url: "https://x.example/1")]))
        XCTAssertTrue(json.contains("\"created_at\" : \"2027-01-15T08:00:00.000Z\""), json)
        XCTAssertTrue(json.contains("\"key\" : \"work:ACME-123:redo-blocked\""), json)
        XCTAssertTrue(json.contains("\"body\" : \"a/b\""), "slashes aren't escaped: \(json)")
        XCTAssertTrue(json.contains("\n  "), "pretty-printed")
        // Sorted keys: body before created_at before key before title.
        let order = ["\"body\"", "\"created_at\"", "\"key\"", "\"title\""].map { json.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
    }

    func testItemJSONRoundTrips() throws {
        let original = item(body: "Body", links: [ItemLink(label: "PR", url: "https://x.example/1")],
                            steps: [ItemStep(text: "one", done: true)])
        let decoded = try HubJSON.makeDecoder().decode(Item.self, from: Data(CardCopy.itemJSON(original).utf8))
        XCTAssertEqual(decoded.key, original.key)
        XCTAssertEqual(decoded.body, original.body)
        XCTAssertEqual(decoded.links, original.links)
        XCTAssertEqual(decoded.steps, original.steps)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.source, original.source)
    }

    func testDebugReport() {
        let rule = BypassRule(match: .keyPrefix, value: "work:", action: .alwaysInterrupt)!
        let info = CardCopy.DebugInfo(appVersion: "0.3.1 (42)", osVersion: "Version 14.5 (Build 23F79)",
                                      feed: "This Mac", delivery: DeliveryDecision(tier: .interrupt, reason: .rule),
                                      rule: rule, focus: "Off", capturedAt: created)
        let report = CardCopy.debugReport(item(), info: info)
        XCTAssertTrue(report.hasPrefix("## Needs You debug report\n"), report)
        for line in ["- App: Needs You 0.3.1 (42)", "- macOS: Version 14.5 (Build 23F79)", "- Feed: This Mac",
                     "- Delivery now: Interrupt (rule)", "- Bypass rule: Key starts with \u{201C}work:\u{201D} \u{2192} Always interrupt",
                     "- Focus: Off", "- Captured: 2027-01-15T08:00:00.000Z", "```json"] {
            XCTAssertTrue(report.contains(line), "missing \(line): \(report)")
        }
        XCTAssertTrue(report.contains(CardCopy.itemJSON(item())))
        let bare = CardCopy.debugReport(item(), info: CardCopy.DebugInfo(appVersion: "dev", osVersion: "14"))
        XCTAssertTrue(bare.contains("- Bypass rule: none"))
        XCTAssertFalse(bare.contains("- Feed:"))
    }

    func testDebugReportFenceOutgrowsBackticks() {
        let report = CardCopy.debugReport(item(body: "```\ncode\n```"), info: CardCopy.DebugInfo(appVersion: "1", osVersion: "14"))
        XCTAssertTrue(report.contains("\n````json\n"), report)
    }

    func testShellQuote() {
        XCTAssertEqual(CardCopy.shellQuote("work:ACME-123:redo"), "work:ACME-123:redo")
        XCTAssertEqual(CardCopy.shellQuote(""), "''")
        XCTAssertEqual(CardCopy.shellQuote("two words"), "'two words'")
        XCTAssertEqual(CardCopy.shellQuote("it's"), "'it'\"'\"'s'")
        XCTAssertEqual(CardCopy.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(CardCopy.shellQuote("a\nb"), "$'a\\nb'")
        XCTAssertEqual(CardCopy.shellQuote("a'\\\tb\n"), "$'a\\'\\\\\\tb\\n'")
        XCTAssertEqual(CardCopy.shellQuote("bell\u{7}\n"), "$'bell\\n'", "other controls are dropped")
    }

    func testAddCommand() {
        let q = ItemQuestion(items: [ItemQuestionItem(text: "Which?", options: [ItemQuestionOption(label: "A")])],
                             answerable: true, expiresAt: created)
        let i = item(body: "It's `blocked`", links: [ItemLink(label: "PR=1", url: "https://x.example/1"),
                                                      ItemLink(label: "", url: "https://y.example/?a=b")],
                     steps: [ItemStep(text: "Do it")], question: q, kind: .info)
        let command = CardCopy.addCommand(i)
        XCTAssertFalse(command.contains("\n"), "one line")
        let lines = command.components(separatedBy: " --").enumerated().map { $0 == 0 ? $1 : "--" + $1 }
        XCTAssertEqual(lines, [
            "needs-you add",
            "--key=work:ACME-123:redo-blocked",
            "--title='Redo blocked on ACME-123'",
            "--body='It'\"'\"'s `blocked`'",
            "--context=work",
            "--priority=urgent",
            "--kind=info",
            "--link=PR-1=https://x.example/1",
            "--link='Link=https://y.example/?a=b'",
            "--steps-json='[{\"done\":false,\"text\":\"Do it\"}]'",
            "--question-json='{\"answerable\":true,\"items\":[{\"allow_other\":false,\"header\":\"\",\"multi_select\":false,"
                + "\"options\":[{\"description\":\"\",\"label\":\"A\"}],\"text\":\"Which?\"}]}'",
            "--agent=orca:redo-fixer",
            "--project=acme-api",
            "--host=devbox",
        ])
        // A plain card: no kind, links, steps or question flags.
        XCTAssertFalse(CardCopy.addCommand(item()).contains("--kind"))
        XCTAssertFalse(CardCopy.addCommand(item()).contains("--body"))
    }

    func testAddCommandCarriesTheEvent() {
        let command = CardCopy.addCommand(item(event: "question"))
        XCTAssertTrue(command.hasSuffix(" --host=devbox --event=question"), command)
        XCTAssertFalse(CardCopy.addCommand(item()).contains("--event"), "no event, no flag")
    }

    /// A bypass rule's "Treat as low" changes `priority` in the app; the copies repost or show
    /// what the sender sent.
    func testCopiesUseTheSenderPriority() throws {
        let rules = RuleBook([BypassRule(match: .keyPrefix, value: "work:", action: .low)!])
        let card = rules.applied(to: item())
        XCTAssertEqual(card.priority, .low, "the rule applied")
        XCTAssertEqual(card.senderPriority, .urgent)
        let command = CardCopy.addCommand(card)
        XCTAssertTrue(command.contains(" --priority=urgent "), command)
        XCTAssertFalse(command.contains("--priority=low"), command)
        let json = CardCopy.itemJSON(card)
        XCTAssertTrue(json.contains("\"priority\" : \"urgent\""), json)
        let decoded = try HubJSON.makeDecoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.priority, .urgent)
        // Without a rule, the item's own priority.
        XCTAssertTrue(CardCopy.itemJSON(item()).contains("\"priority\" : \"urgent\""))
    }

    /// Runs `command` (a `needs-you add` line) with `printf` in its place under `shell`,
    /// and returns the arguments the shell passed. nil when the shell isn't there.
    private func shellArguments(_ command: String, shell: String) throws -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        XCTAssertTrue(command.hasPrefix("needs-you add "))
        let script = "printf '%s\\0' " + command.dropFirst("needs-you add ".count)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-c", script]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(shell): \(command)")
        var args = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        if args.last == "" { args.removeLast() }
        return args
    }

    func testAddCommandRoundTripsThroughAShell() throws {
        let body = "Line one with 'quotes' and \"doubles\"\n$(not run) `nor this` \\ backslash"
        let command = CardCopy.addCommand(item(body: body))
        for shell in ["/bin/bash", "/bin/zsh"] {
            guard let args = try shellArguments(command, shell: shell) else { continue }
            XCTAssertTrue(args.contains("--body=" + body), "\(shell): \(args)")
            XCTAssertTrue(args.contains("--title=Redo blocked on ACME-123"), "\(shell): \(args)")
        }
    }

    /// Card text is untrusted: whatever a sender put in it, the command is one line, runs
    /// nothing but needs-you when pasted, and the shell hands back the cleaned value.
    func testHostileValuesStayInert() throws {
        let token = "ny_" + String(repeating: "B", count: 43)
        // Anything that ran would create the marker file.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cardcopy-pwned-\(UUID().uuidString)")
        let run = "touch \(marker.path)"
        let hostile = [
            "'; \(run) #",
            "$(\(run))",
            "`\(run)`",
            "${HOME}",
            "a\n\(run)",
            "a\r\n\(run)",
            "a\r\(run)",
            "\u{202E}gpj.exe",
            "zero\u{200B}width",
            "nul\u{0}byte; \(run)",
            "esc\u{1B}]0;title\u{7}",
            "quote'\\'\"mix\\",
            "-starts-with-dash",
            "it's \(token)' ; \(run) ; echo '",
            "x=\(token)'$(\(run))'",
            "!event !! ~user *glob ?",
            "\u{2028}\(run)\u{2029}",
        ]
        for value in hostile + [hostile.joined(separator: "\n")] {
            let card = Item(id: "itm_x", key: value, title: value, body: value,
                            links: [ItemLink(label: value, url: "https://x.example/" + value)],
                            source: ItemSource(host: value, agent: value, project: value), createdAt: created)
            let command = CardCopy.addCommand(card)
            XCTAssertFalse(command.contains("\n") || command.contains("\r"), "one line: \(command)")
            XCTAssertFalse(command.unicodeScalars.contains { CardCopy.isHiddenOrControl($0) }, command)
            XCTAssertFalse(command.contains(token), command)
            let expected = CardCopy.shellSafeValue(CardCopy.redactSecrets(value))
            for shell in ["/bin/bash", "/bin/zsh"] {
                guard let args = try shellArguments(command, shell: shell) else { continue }
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(shell) ran something: \(command)")
                XCTAssertTrue(args.contains("--title=" + expected), "\(shell): \(args) for \(command)")
                XCTAssertTrue(args.contains("--body=" + expected), "\(shell): \(args)")
                XCTAssertTrue(args.contains("--host=" + expected), "\(shell): \(args)")
            }
        }
        try? FileManager.default.removeItem(at: marker)
    }

    /// cli/needs-you `parse_link`: split at the first "="; bare URL (label "Link") when
    /// there's no "=", the left side has "://", or it's blank.
    private func parseLink(_ raw: String) -> ItemLink {
        guard let eq = raw.firstIndex(of: "=") else { return ItemLink(label: "Link", url: raw.trimmingCharacters(in: .whitespaces)) }
        let label = String(raw[..<eq]), url = String(raw[raw.index(after: eq)...])
        if label.contains("://") || label.trimmingCharacters(in: .whitespaces).isEmpty {
            return ItemLink(label: "Link", url: raw.trimmingCharacters(in: .whitespaces))
        }
        return ItemLink(label: label.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespaces))
    }

    func testLinkArgumentSplitsLikeTheCLI() {
        let cases: [(ItemLink, ItemLink)] = [
            // Empty label, URL with "=" and no "://": the CLI would have split it wrongly.
            (ItemLink(label: "", url: "slack:open?team=T1&id=C2"), ItemLink(label: "Link", url: "slack:open?team=T1&id=C2")),
            (ItemLink(label: "  ", url: "msteams:l/chat?users=a=b"), ItemLink(label: "Link", url: "msteams:l/chat?users=a=b")),
            // A label with "=".
            (ItemLink(label: "a=b", url: "https://x.example/?q=1"), ItemLink(label: "a-b", url: "https://x.example/?q=1")),
            // A label with "://".
            (ItemLink(label: "https://evil.example", url: "https://x.example/?q=1"), ItemLink(label: "Link", url: "https://x.example/?q=1")),
            // A label with hidden characters.
            (ItemLink(label: "P\u{202E}R\u{200B}", url: "linear:issue?id=1"), ItemLink(label: "PR", url: "linear:issue?id=1")),
            (ItemLink(label: "PR", url: "https://github.com/acme/api/pull/1"), ItemLink(label: "PR", url: "https://github.com/acme/api/pull/1")),
        ]
        for (link, expected) in cases {
            let argument = CardCopy.linkArgument(link)
            XCTAssertEqual(parseLink(argument), expected, argument)
            XCTAssertTrue(argument.hasPrefix(expected.label + "="), argument)
        }
    }

    func testShellSafeValue() {
        XCTAssertEqual(CardCopy.shellSafeValue("a\r\nb\rc\u{2028}d"), "a\nb\nc\nd")
        XCTAssertEqual(CardCopy.shellSafeValue("tab\tkept"), "tab\tkept")
        XCTAssertEqual(CardCopy.shellSafeValue("\u{202E}x\u{200B}y\u{0}z\u{1B}\u{FEFF}"), "xyz")
    }

    func testSecretsAreRedacted() {
        let token = "ny_" + String(repeating: "A", count: 43)
        let body = "token \(token) invite nyi_abcDEF123 peer nyp_secret-1 join https://hub-a.example.ts.net/join/nyi_x9"
        let i = item(body: body)
        for copy in [CardCopy.titleAndText(i), CardCopy.itemJSON(i), CardCopy.addCommand(i),
                     CardCopy.debugReport(i, info: CardCopy.DebugInfo(appVersion: "1", osVersion: "14"))] {
            XCTAssertFalse(copy.contains(token), copy)
            XCTAssertFalse(copy.contains("abcDEF123"), copy)
            XCTAssertFalse(copy.contains("secret-1"), copy)
            XCTAssertFalse(copy.contains("nyi_x9"), copy)
        }
        XCTAssertEqual(CardCopy.snippets(in: "`export NY_TOKEN=\(token)`"), [], "no chip rather than a copy that differs")
        // Ordinary words that merely contain the prefixes stay.
        XCTAssertEqual(CardCopy.redactSecrets("sunny_day company_name"), "sunny_day company_name")
    }
}
