#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Regression tests from the 2026-10-07 security audit (docs/security/audit-2026-10-07.md):
/// link and markdown bypasses, Orca jump argument injection, and rogue connect links.
final class SecurityAuditTests: XCTestCase {
    static var allTests = [
        ("testLinkPolicyRejectsSchemeTricks", testLinkPolicyRejectsSchemeTricks),
        ("testMarkdownNeverKeepsADisallowedLink", testMarkdownNeverKeepsADisallowedLink),
        ("testMarkdownStripsBidiControls", testMarkdownStripsBidiControls),
        ("testOrcaJumpRejectsInjection", testOrcaJumpRejectsInjection),
        ("testOrcaJumpArgumentsAreFixed", testOrcaJumpArgumentsAreFixed),
        ("testNewHubCannotRekeyKnownHubs", testNewHubCannotRekeyKnownHubs),
        ("testConnectConfirmationNamesTheHub", testConnectConfirmationNamesTheHub),
        ("testHubURLsRefuseUserInfo", testHubURLsRefuseUserInfo),
        ("testHubSessionRefusesRedirects", testHubSessionRefusesRedirects),
    ]

    /// Scan 2026-10-08: "https://hub-a.example.ts.net@evil.example" reads as the first host
    /// and is the second; it was stored, shown and used as the token key with the user@ in it.
    func testHubURLsRefuseUserInfo() {
        for raw in ["https://hub-a.example.ts.net@evil.example", "http://user:pw@100.64.1.2:8765",
                    "https://@evil.example"] {
            XCTAssertNil(ConnectLink.normalizedHubURL(raw), raw)
            let link = "needsyou://connect?hub=" + raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&code=nyi_abc"
            XCTAssertNil(ConnectLink.parse(link), link)
        }
        XCTAssertNotNil(ConnectLink.normalizedHubURL("https://hub-a.example.ts.net:8765"))
        XCTAssertEqual(ConnectLink.parse("https://hub-a.example.ts.net@evil.example/join/nyi_abc")?.hub.absoluteString,
                       "https://evil.example")
    }

    /// Scan 2026-10-08: the shared hub session followed redirects, re-sending the bearer token
    /// to whatever the Location named.
    func testHubSessionRefusesRedirects() {
        XCTAssertTrue(HubSession.shared.delegate is HubSession.RefuseRedirects)
        let task = HubSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/")!)
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:9/")!, statusCode: 302,
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": "http://203.0.113.9/"])!
        var next: URLRequest? = URLRequest(url: URL(string: "http://203.0.113.9/")!)
        HubSession.RefuseRedirects().urlSession(HubSession.shared, task: task, willPerformHTTPRedirection: response,
                                                newRequest: URLRequest(url: URL(string: "http://203.0.113.9/")!)) { next = $0 }
        XCTAssertNil(next)
    }

    func testLinkPolicyRejectsSchemeTricks() {
        let rejected = [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            " javascript:alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "%6Aavascript:alert(1)",
            "data:text/html,x",
            "file:///etc/passwd",
            "FILE:///etc/passwd",
            "vbscript:x",
            "http://a.example",
            "https:///no-host",
            "https://a.example/x y",
            "https://git\u{200B}hub.com/x",
            "\u{FEFF}https://a.example",
            "https://a.example/\u{202E}",
            "\u{FF48}ttps://a.example",
            "needsyou://connect?hub=http://x&code=y",
            "needsyou://evil/terminal?handle=term_12345678",
            "//a.example/x",
        ]
        for s in rejected {
            XCTAssertNil(LinkPolicy.openableURL(s), s)
            XCTAssertNil(LinkPolicy.externalURL(s), s)
        }
        XCTAssertNotNil(LinkPolicy.openableURL("https://a.example/x%20y"))
    }

    func testMarkdownNeverKeepsADisallowedLink() {
        let bodies = [
            "<javascript:alert(1)>",
            "[x](javascript:alert(1))",
            "[x](JAVASCRIPT:alert(1))",
            "[x]( javascript:alert(1) )",
            "[x](data:text/html;base64,PGI+)",
            "[x](file:///etc/passwd)",
            "[x](http://a.example)",
            "[x](needsyou://connect?hub=http://h&code=c)",
            "[[inner](javascript:a)](https://ok.example)",
            "[ref][r]\n\n[r]: javascript:alert(1)",
            "[x](<javascript:alert(1)>)",
            "[x](java&#115;cript:alert(1))",
            "[x](%6Aavascript:alert(1))",
            "![img](https://a.example/p.png)",
        ]
        for body in bodies {
            let out = LimitedMarkdown.render(body)
            for run in out.runs {
                XCTAssertNil(run.imageURL, body)
                if let link = run.link {
                    XCTAssertTrue(LinkPolicy.isAllowed(link), "\(body) kept \(link)")
                    XCTAssertNotEqual(link.scheme?.lowercased(), "javascript", body)
                }
            }
        }
        // The one app link that is allowed survives (it only switches an Orca tab).
        let jump = LimitedMarkdown.render("[t](needsyou://orca/terminal?handle=term_12345678)")
        XCTAssertTrue(jump.runs.contains { $0.link != nil })
    }

    func testMarkdownStripsBidiControls() {
        XCTAssertEqual(LimitedMarkdown.plainText("PR \u{202E}lmth.exe"), "PR lmth.exe")
        XCTAssertEqual(LimitedMarkdown.stripBidiControls("a\u{2066}b\u{2069}c\u{202A}"), "abc")
        // Implicit RTL text, marks and joiners are left alone.
        let keep = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{200F} \u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(LimitedMarkdown.stripBidiControls(keep), keep)
    }

    func testOrcaJumpRejectsInjection() {
        let rejected = [
            "needsyou://orca/terminal?handle=-x",
            "needsyou://orca/terminal?handle=--help",
            "needsyou://orca/terminal?handle=term_12345678;id",
            "needsyou://orca/terminal?handle=term_12345678%20--json",
            "needsyou://orca/terminal?handle=term_ABCDEF12",
            "needsyou://orca/terminal?handle=term_12345678&environment=-rf",
            "needsyou://orca/terminal?handle=term_12345678&environment=--json",
            "needsyou://orca/terminal?handle=term_12345678&environment=a;b",
            "needsyou://orca/terminal?handle=term_12345678&environment=%24(id)",
            "needsyou://orca/terminal?handle=term_12345678&environment=%D9%A1%D9%A2",
            "needsyou://orca/terminal?handle=term_12345678&environment=a%0Ab",
            "needsyou://orca/terminal?handle=term_12345678&cmd=x",
            "needsyou://orca/terminal?handle=term_12345678&handle=term_87654321",
            "needsyou://user@orca/terminal?handle=term_12345678",
            "needsyou://orca:1/terminal?handle=term_12345678",
            "needsyou://orca/terminal?handle=term_12345678#x",
            "needsyou://orca/terminal/../x?handle=term_12345678",
            "needsyou://orca/terminal",
        ]
        for s in rejected {
            XCTAssertNil(OrcaJump.parse(s), s)
        }
    }

    func testOrcaJumpArgumentsAreFixed() {
        let jump = OrcaJump.parse("needsyou://orca/terminal?handle=term_12345678&environment=dev%20box")
        XCTAssertNotNil(jump)
        guard let jump else { return }
        XCTAssertEqual(jump.arguments, ["terminal", "switch", "--terminal", "term_12345678", "--json",
                                        "--environment", "dev box"])
        for arg in [jump.handle, jump.environment ?? ""] {
            XCTAssertFalse(arg.hasPrefix("-"), arg)
        }
    }

    func testNewHubCannotRekeyKnownHubs() {
        let existing = ["http://home.t.ts.net:8765", "http://work.t.ts.net:8765"]
        // A link to an unknown hub names the hubs we already have: they keep their tokens.
        let rogue = HubListMerge.merge(existing: existing, given: URL(string: "http://rogue.t.ts.net:8765")!,
                                       returned: ["http://home.t.ts.net:8765", "http://new.t.ts.net:8765"])
        XCTAssertEqual(rogue.tokenHubs.map(HubName.key), ["http://rogue.t.ts.net:8765", "http://new.t.ts.net:8765"])
        XCTAssertEqual(rogue.skipped, ["http://home.t.ts.net:8765"])
        XCTAssertEqual(rogue.hubs, existing + ["http://rogue.t.ts.net:8765", "http://new.t.ts.net:8765"])
        // Reconnecting through a hub we know still refreshes every hub it names.
        let again = HubListMerge.merge(existing: existing, given: URL(string: "http://home.t.ts.net:8765")!,
                                       returned: ["http://work.t.ts.net:8765"])
        XCTAssertEqual(again.tokenHubs.map(HubName.key), ["http://home.t.ts.net:8765", "http://work.t.ts.net:8765"])
    }

    func testConnectConfirmationNamesTheHub() {
        let link = ConnectLink.parse("needsyou://connect?hub=http%3A%2F%2Fhub-a.example.ts.net%3A8765&code=nyi_abc")
        XCTAssertNotNil(link)
        guard let link else { return }
        let prompt = link.confirmation
        XCTAssertTrue(prompt.title.contains("hub-a.example.ts.net"), prompt.title)
        XCTAssertTrue(prompt.message.contains("http://hub-a.example.ts.net:8765"), prompt.message)
        XCTAssertFalse(prompt.message.contains("nyi_abc"), "the invite code is never shown")
    }
}
