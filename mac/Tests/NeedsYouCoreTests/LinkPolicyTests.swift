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
        ("testEditorLinksOpenOnlyKnownShapes", testEditorLinksOpenOnlyKnownShapes),
        ("testEditorLinkTricksAreRejected", testEditorLinkTricksAreRejected),
        ("testMarkdownDropsExtensionHandlerLinks", testMarkdownDropsExtensionHandlerLinks),
        ("testMarkdownKeepsAllowedLinksAndStripsOthers", testMarkdownKeepsAllowedLinksAndStripsOthers),
        ("testMarkdownDropsImagesAndKeepsInlineStyles", testMarkdownDropsImagesAndKeepsInlineStyles),
        ("testMarkdownBulletsAndLengthLimit", testMarkdownBulletsAndLengthLimit),
    ]

    func testAllowedSchemesOpen() {
        let allowed = [
            "https://acme.atlassian.net/browse/ACME-4170",
            "HTTPS://github.com/acme/acme-api/pull/2137",
            "slack://channel?team=T0&id=C0",
            "vscode://file/home/dev/x.py",
            "cursor://file/x",
            "figma://file/abc",
            "msteams://teams.microsoft.com/l/chat/0/0",
            "discord://discord.com/channels/1/2",
            "linear://acme/issue/ACME-12",
            "LINEAR://acme/issue/ACME-12",
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
            "jira://ACME-4170",              // an app scheme that isn't allow-listed
            "data:text/html,<b>x</b>",
            "ssh://host",
            "x-apple.systempreferences:com.apple.preference.security",
            "smb://server/share",
            "mailto:someone@example.com",
            "linearx://acme/issue/ACME-12",
            "orca://skills/share/abc123",    // dropped (security audit #14)
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

    // Security audit #14: the same shapes as the hub's EDITOR_LINK_PATTERN (tests/test_editor_links.py).
    func testEditorLinksOpenOnlyKnownShapes() {
        let allowed = [
            "vscode://file/home/dev/x.py",
            "vscode://file/Users/me/My%20Project",
            "vscode://file/Users/me/repo/src/app.py:12:3",
            "vscode://file/Users/jos%C3%A9/repo/",
            "VSCODE://file/home/dev/x.py",
            "cursor://file/x",
            "vscode://vscode-remote/ssh-remote+devbox/home/me/repo",
            "vscode://vscode-remote/ssh-remote+devbox",
            "vscode://vscode-remote/ssh-remote+me@devbox/home/me",
            "vscode://vscode-remote/ssh-remote+hub-a.example.ts.net/srv/app",
            "cursor://vscode-remote/ssh-remote+devbox/home/me/repo",
            "vscode://vscode-remote/tunnel+my-box/home/me",
            "vscode://anthropic.claude-code/open?session=sess-1234-abcd",
            "vscode://anthropic.claude-code/open?session=0f8e6c4a-1b2c-4d5e-8f90-123456789abc",
        ]
        for s in allowed {
            XCTAssertNotNil(LinkPolicy.openableURL(s), s)
        }
    }

    func testEditorLinkTricksAreRejected() {
        let rejected = [
            "vscode://settings/editor.fontSize",
            "vscode://ms-python.python/run?x=1",
            "vscode://vscode.git/clone?url=https://evil.example/r.git",
            "cursor://anysphere.cursor-retrieval/x",
            "vscode://File/x",
            "vscode://Anthropic.Claude-Code/open?session=sess-1234-abcd",
            "vscode://anthropic%2Eclaude-code/open?session=sess-1234-abcd",
            "vscode://%66ile/x",
            "vscode://u@file/x",
            "vscode://evil.example@file/x",
            "vscode://file@evil.example/x",
            "vscode://file:80/x",
            "vscode:file/x",
            "vscode:///file/x",
            "vscode://file//server/share",
            "vscode://file",
            "vscode://file/x?windowId=_blank",
            "vscode://file/x#L1",
            "vscode://file/x%0a",
            "vscode://file/x%00",
            "vscode://file/x%1b",
            "vscode://file/x%7F",
            "vscode://file/x%2",
            "vscode://vscode-remote/ssh-remote+-oProxyCommand=touch%20x/",
            "vscode://vscode-remote/ssh-remote+%2DoProxyCommand=x/",
            "vscode://vscode-remote/ssh-remote+7b22686f73744e616d65223a222d6f78227d/x",
            "vscode://vscode-remote/ssh-remote+-x@devbox/x",
            "vscode://vscode-remote/wsl+Ubuntu/home/me",
            "vscode://vscode-remote/dev-container+7b7d/x",
            "vscode://vscode-remote/ssh-remote+devbox/x?windowId=_blank",
            "vscode://vscode-remote/ssh-remote+devbox//etc",
            "vscode://anthropic.claude-code/open?prompt=rm%20-rf",
            "vscode://anthropic.claude-code/open?session=sess-1234-abcd&prompt=x",
            "vscode://anthropic.claude-code/open?session=short",
            "vscode://anthropic.claude-code/new?session=sess-1234-abcd",
            "vscode://anthropic.claude-code/open?session=sess-1234-abcd#x",
        ]
        for s in rejected {
            XCTAssertNil(LinkPolicy.openableURL(s), s)
        }
    }

    func testMarkdownDropsExtensionHandlerLinks() {
        let rendered = LimitedMarkdown.render("[file](vscode://file/home/me/x.py) and [ext](vscode://ms-python.python/run)")
        let links = rendered.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["vscode://file/home/me/x.py"])
        XCTAssertEqual(String(rendered.characters), "file and ext")
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
