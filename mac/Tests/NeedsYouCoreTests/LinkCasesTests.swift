#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Security audit #14: the same link decisions as the hub, from one shared fixture file
/// (tests/fixtures/link_cases.json, which tests/test_link_mirror.py runs against the hub).
final class LinkCasesTests: XCTestCase {
    static var allTests = [
        ("testSharedLinkCases", testSharedLinkCases),
        ("testAppIsStricterOnlyForAppActions", testAppIsStricterOnlyForAppActions),
    ]

    private struct Case: Decodable {
        let url: String
        let allowed: Bool
    }

    private struct Stricter: Decodable {
        let url: String
        let hub: Bool
        let app: Bool
    }

    private struct Fixture: Decodable {
        let cases: [Case]
        let app_stricter: [Stricter]
    }

    /// <repo>/tests/fixtures/link_cases.json. This file sits three directories below the repo
    /// root both in Tests/NeedsYouCoreTests and as its symlink in Sources/NeedsYouSelfTest.
    private func fixture() throws -> Fixture {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/link_cases.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testSharedLinkCases() throws {
        let f = try fixture()
        XCTAssertTrue(f.cases.count > 100, "fixture looks truncated")
        for c in f.cases {
            XCTAssertEqual(LinkPolicy.isAllowed(c.url), c.allowed, c.url)
        }
    }

    func testAppIsStricterOnlyForAppActions() throws {
        let f = try fixture()
        for c in f.app_stricter {
            XCTAssertTrue(c.url.lowercased().hasPrefix("needsyou://"), c.url)
            XCTAssertEqual(LinkPolicy.isAllowed(c.url), c.app, c.url)
        }
    }
}
