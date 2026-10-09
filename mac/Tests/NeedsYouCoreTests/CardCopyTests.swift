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
        ("testChipLabel", testChipLabel),
        ("testTitleAndText", testTitleAndText),
        ("testLinkURLs", testLinkURLs),
        ("testItemJSON", testItemJSON),
        ("testItemJSONRoundTrips", testItemJSONRoundTrips),
        ("testDebugReport", testDebugReport),
        ("testDebugReportFenceOutgrowsBackticks", testDebugReportFenceOutgrowsBackticks),
        ("testShellQuote", testShellQuote),
        ("testAddCommand", testAddCommand),
        ("testAddCommandRoundTripsThroughAShell", testAddCommandRoundTripsThroughAShell),
        ("testSecretsAreRedacted", testSecretsAreRedacted),
    ]

    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(body: String? = nil, links: [ItemLink] = [], steps: [ItemStep] = [],
                      question: ItemQuestion? = nil, kind: ItemKind = .needs) -> Item {
        Item(id: "itm_1", key: "work:ACME-123:redo-blocked", kind: kind, priority: .urgent,
             title: "Redo blocked on ACME-123", body: body, links: links, steps: steps, question: question,
             source: ItemSource(host: "devbox", agent: "orca:redo-fixer", project: "acme-api"),
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
        let body = "Run this:\n```bash\nsudo systemctl restart hub\njournalctl -u hub -n 50\n```\nthen `x`.\n~~~\nls\n~~~"
        XCTAssertEqual(CardCopy.snippets(in: body),
                       ["sudo systemctl restart hub\njournalctl -u hub -n 50", "ls"])
        // Inside a fence, backticks aren't inline code.
        XCTAssertEqual(CardCopy.snippets(in: "```\necho `date`\n```"), ["echo `date`"])
        // A short fenced block is still offered: the sender fenced it on purpose.
        XCTAssertEqual(CardCopy.snippets(in: "```\nmake\n```"), ["make"])
        // An empty fence is not.
        XCTAssertEqual(CardCopy.snippets(in: "```\n\n```"), [])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(CardCopy.snippets(in: "Then:\n```\nmake test\nmake bundle"), ["make test\nmake bundle"])
    }

    func testDoubleBacktickSpans() {
        XCTAssertEqual(CardCopy.snippets(in: "Run `` echo `whoami` `` now"), ["echo `whoami`"])
    }

    func testDedupeCapAndLength() {
        let body = "`ls -la /tmp` `ls -la /tmp` `cmd one` `cmd two` `cmd three` `cmd four` `cmd five`"
        XCTAssertEqual(CardCopy.snippets(in: body), ["ls -la /tmp", "cmd one", "cmd two", "cmd three"])
        let long = String(repeating: "a ", count: 600)  // 1,199 characters: over the cap, inside the body limit
        XCTAssertEqual(CardCopy.snippets(in: "```\n\(long)\n```\n`ok then`"), ["ok then"])
    }

    func testBidiControlsAreStripped() {
        XCTAssertEqual(CardCopy.snippets(in: "`rm -rf \u{202E}gpj.exe`"), ["rm -rf gpj.exe"])
    }

    func testChipLabel() {
        XCTAssertEqual(CardCopy.chipLabel("make test\n  make bundle"), "make test \u{21B5} make bundle")
        let label = CardCopy.chipLabel(String(repeating: "x", count: 100), maxLength: 10)
        XCTAssertEqual(label.count, 10)
        XCTAssertTrue(label.hasSuffix("\u{2026}"))
        XCTAssertEqual(CardCopy.chipLabel("short"), "short")
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
        XCTAssertEqual(CardCopy.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(CardCopy.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(CardCopy.shellQuote("a\nb"), "'a\nb'")
    }

    func testAddCommand() {
        let q = ItemQuestion(items: [ItemQuestionItem(text: "Which?", options: [ItemQuestionOption(label: "A")])],
                             answerable: true, expiresAt: created)
        let i = item(body: "It's `blocked`", links: [ItemLink(label: "PR=1", url: "https://x.example/1"),
                                                      ItemLink(label: "", url: "https://y.example/?a=b")],
                     steps: [ItemStep(text: "Do it")], question: q, kind: .info)
        let command = CardCopy.addCommand(i)
        let lines = command.components(separatedBy: " \\\n  ")
        XCTAssertEqual(lines, [
            "needs-you add",
            "--key=work:ACME-123:redo-blocked",
            "--title='Redo blocked on ACME-123'",
            "--body='It'\\''s `blocked`'",
            "--context=work",
            "--priority=urgent",
            "--kind=info",
            "--link=PR-1=https://x.example/1",
            "--link='https://y.example/?a=b'",
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

    func testAddCommandRoundTripsThroughAShell() throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        guard FileManager.default.isExecutableFile(atPath: sh.path) else { return }
        let body = "Line one with 'quotes' and \"doubles\"\n$(not run) `nor this` \\ backslash"
        let command = CardCopy.addCommand(item(body: body))
        // Print each argument after "needs-you add" on its own NUL-terminated record.
        let script = "printf '%s\\0' " + command.replacingOccurrences(of: "needs-you add", with: "")
        let p = Process()
        p.executableURL = sh
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        XCTAssertTrue(args.contains("--body=" + body), "\(args)")
        XCTAssertTrue(args.contains("--title=Redo blocked on ACME-123"), "\(args)")
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
        XCTAssertEqual(CardCopy.snippets(in: "`export NY_TOKEN=\(token)`"), ["export NY_TOKEN=ny_<redacted>"])
        // Ordinary words that merely contain the prefixes stay.
        XCTAssertEqual(CardCopy.redactSecrets("sunny_day company_name"), "sunny_day company_name")
    }
}
