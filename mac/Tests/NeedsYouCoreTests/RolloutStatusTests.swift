#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Settings → Updates → Sender machines: versions from GET /v1/tokens.
final class RolloutStatusTests: XCTestCase {
    static var allTests = [
        ("testDecodesClientFields", testDecodesClientFields),
        ("testCountsBehindRecentSenders", testCountsBehindRecentSenders),
        ("testSummaries", testSummaries),
        ("testMergeKeepsNewestPerToken", testMergeKeepsNewestPerToken),
    ]

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecodesClientFields() throws {
        let json = """
        {"tokens":[{"id":"1","name":"devbox","role":"sender","open_items":0,"current":false,
                    "client":{"cli":"0.1.1","hook":"none","future":7},"last_seen_at":"2026-10-07T09:12:00.000Z"},
                   {"id":"2","name":"old-hub-token","role":"sender"}]}
        """
        struct Body: Decodable { var tokens: [TokenSummary] }
        let tokens = try JSONDecoder().decode(Body.self, from: Data(json.utf8)).tokens
        XCTAssertEqual(tokens[0].client, ["cli": "0.1.1", "hook": "none"])
        XCTAssertEqual(tokens[0].lastSeenAt, HubJSON.parseDate("2026-10-07T09:12:00.000Z"))
        XCTAssertEqual(tokens[1].client, [:])
        XCTAssertNil(tokens[1].lastSeenAt)
    }

    private func token(_ name: String, role: HubRole = .sender, client: [String: String], seenAgo: TimeInterval?) -> TokenSummary {
        TokenSummary(id: name, name: name, role: role, client: client, lastSeenAt: seenAgo.map { now.addingTimeInterval(-$0) })
    }

    func testCountsBehindRecentSenders() {
        let tokens = [
            token("current", client: ["cli": "0.2.0", "hook": "0.2.0", "skill": "none"], seenAgo: 3600),
            token("old-cli", client: ["cli": "0.1.1", "hook": "0.2.0"], seenAgo: 60),
            token("old-hook", client: ["cli": "0.2.0", "hook": "0.1.9"], seenAgo: 86_400),
            token("silent", client: [:], seenAgo: 10),
            token("gone", client: ["cli": "0.0.1"], seenAgo: 15 * 86_400),
            token("never", client: [:], seenAgo: nil),
            token("the-mac", role: .owner, client: ["cli": "0.0.1"], seenAgo: 1),
        ]
        let s = RolloutStatus(tokens: tokens, target: SemVer(0, 2, 0), now: now)
        XCTAssertEqual(s.recent, 4)
        XCTAssertEqual(s.behind, 2)
        XCTAssertEqual(s.unreported, 1)
        XCTAssertEqual(s.rows.map(\.name), ["old-cli", "old-hook", "current", "silent"])
        XCTAssertEqual(s.rows[0].detail, "CLI 0.1.1 · hook 0.2.0 · seen 1m ago")
        XCTAssertEqual(s.rows[3].detail, "no versions reported (old CLI) · seen now")
        XCTAssertFalse(s.rows[2].behind)
        // No target version (a dev build): nothing is "behind".
        XCTAssertEqual(RolloutStatus(tokens: tokens, target: nil, now: now).behind, 0)
    }

    func testSummaries() {
        XCTAssertEqual(RolloutStatus(tokens: [], target: SemVer(0, 2, 0), now: now).summary,
                       "No sender machines seen in the last 14 days.")
        let one = [token("a", client: ["cli": "0.2.0"], seenAgo: 5)]
        XCTAssertEqual(RolloutStatus(tokens: one, target: SemVer(0, 2, 0), now: now).summary, "All 1 machine up to date.")
        let two = one + [token("b", client: ["cli": "0.1.0"], seenAgo: 5), token("c", client: [:], seenAgo: 5)]
        XCTAssertEqual(RolloutStatus(tokens: two, target: SemVer(0, 2, 0), now: now).summary,
                       "1 of 3 machines out of date. 1 not reporting versions yet.")
    }

    func testMergeKeepsNewestPerToken() {
        let a = [token("x", client: ["cli": "0.1.0"], seenAgo: 3600), token("y", client: [:], seenAgo: nil)]
        let b = [token("x", client: ["cli": "0.2.0"], seenAgo: 60), token("z", client: [:], seenAgo: 5)]
        let merged = RolloutStatus.merge([a, b])
        XCTAssertEqual(merged.map(\.id), ["x", "y", "z"])
        XCTAssertEqual(merged[0].client["cli"], "0.2.0")
    }
}
