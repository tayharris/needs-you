#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class LinkPolicyTests: XCTestCase {
    static var allTests = [
        ("testAllowedSchemesOpen", testAllowedSchemesOpen),
        ("testDisallowedSchemesAreRejected", testDisallowedSchemesAreRejected),
        ("testMalformedAndHostlessAreRejected", testMalformedAndHostlessAreRejected),
        ("testMarkdownKeepsAllowedLinksAndStripsOthers", testMarkdownKeepsAllowedLinksAndStripsOthers),
        ("testMarkdownDropsImagesAndKeepsInlineStyles", testMarkdownDropsImagesAndKeepsInlineStyles),
        ("testMarkdownBulletsAndLengthLimit", testMarkdownBulletsAndLengthLimit),
    ]

    func testAllowedSchemesOpen() {
        let allowed = [
            "https://acme.atlassian.net/browse/ACME-4170",
            "HTTPS://github.com/acme/acme-backend/pull/2137",
            "orca://worktree/acme-backend/ACME-4170",
            "slack://channel?team=T0&id=C0",
            "vscode://file/home/dev/x.py",
            "cursor://file/x",
            "figma://file/abc",
            "msteams://teams.microsoft.com/l/chat/0/0",
            "discord://discord.com/channels/1/2",
        ]
        for s in allowed {
            XCTAssertNotNil(LinkPolicy.openableURL(s), s)
        }
    }

    func testDisallowedSchemesAreRejected() {
        let rejected = [
            "http://example.com",          // plain http is not on the list
            "javascript:alert(1)",
            "file:///etc/passwd",
            "jira://ACME-4170",              // mentioned in PLAN.md prose but not allow-listed
            "data:text/html,<b>x</b>",
            "ssh://host",
            "x-apple.systempreferences:com.apple.preference.security",
            "smb://server/share",
            "mailto:someone@example.com",
        ]
        for s in rejected {
            XCTAssertNil(LinkPolicy.openableURL(s), s)
        }
    }

    func testMalformedAndHostlessAreRejected() {
        XCTAssertNil(LinkPolicy.openableURL(""))
        XCTAssertNil(LinkPolicy.openableURL("not a url"))
        XCTAssertNil(LinkPolicy.openableURL("https://"))
        XCTAssertNil(LinkPolicy.openableURL("https:///path-only"))
        XCTAssertNil(LinkPolicy.openableURL("//github.com/no-scheme"))
        XCTAssertNil(LinkPolicy.openableURL("https://exa mple.com"))
        XCTAssertNil(LinkPolicy.openableURL("https://example.com/\u{0007}bell"))
        XCTAssertNotNil(LinkPolicy.openableURL("  https://example.com/trimmed  "))
    }

    func testMarkdownKeepsAllowedLinksAndStripsOthers() {
        let rendered = LimitedMarkdown.render("See [runbook](https://example.com/rb) and [bad](javascript:alert(1)) and [plain](http://example.com).")
        let links = rendered.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/rb"])
        XCTAssertEqual(String(rendered.characters), "See runbook and bad and plain.")
    }

    func testMarkdownDropsImagesAndKeepsInlineStyles() {
        let rendered = LimitedMarkdown.render("**bold** *it* `code` ![alt](https://example.com/x.png)")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.imageURL == nil })
        let intents = rendered.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains(.stronglyEmphasized))
        XCTAssertTrue(intents.contains(.emphasized))
        XCTAssertTrue(intents.contains(.code))
        XCTAssertFalse(String(rendered.characters).contains("x.png"))
    }

    func testMarkdownBulletsAndLengthLimit() {
        XCTAssertEqual(LimitedMarkdown.plainText("a\n- one\n  * two"), "a\n• one\n  • two")
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(LimitedMarkdown.plainText(long).count, LimitedMarkdown.maxLength)
    }
}
