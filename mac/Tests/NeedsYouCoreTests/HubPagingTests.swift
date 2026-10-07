#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// docs/API.md "The polling loop": the hub's opaque `next` cursor goes back with `since`, and
/// paging follows it; hubs without it are paged by `server_time` as before.
final class HubPagingTests: XCTestCase {
    static var allTests: [(String, (HubPagingTests) -> () throws -> Void)] = [
        ("testListURLSendsCursorOnlyWithSince", testListURLSendsCursorOnlyWithSince),
        ("testPageDecodesNext", testPageDecodesNext),
    ]
    static var asyncTests = [
        ("testPagingFollowsNext", testPagingFollowsNext),
        ("testPagingWithoutNextUsesServerTime", testPagingWithoutNextUsesServerTime),
        ("testFailoverPassesCursorOnlyToTheSameHub", testFailoverPassesCursorOnlyToTheSameHub),
    ]

    override func setUp() {
        StubURLProtocol.handler = nil
        StubURLProtocol.recorded = []
    }

    private static func body(_ ids: [String], serverTime: String, more: Bool, next: String?) -> Data {
        let rows = ids.map {
            #"{"id":"\#($0)","key":"k:\#($0)","title":"T","status":"open","created_at":"2026-10-06T10:00:00Z","updated_at":"2026-10-06T10:05:00Z"}"#
        }
        let nextField = next.map { #","next":"\#($0)""# } ?? ""
        return Data(#"{"items":[\#(rows.joined(separator: ","))],"server_time":"\#(serverTime)","hub_id":"hub-a","more":\#(more)\#(nextField)}"#.utf8)
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let config = HubConfig(baseURL: URL(string: "http://hub-a.example.ts.net:8765")!, token: "tok")
    private let since = Date(timeIntervalSince1970: 1_790_000_000.5)

    func testListURLSendsCursorOnlyWithSince() {
        let base = URL(string: "http://hub.example.ts.net:8765")!
        XCTAssertEqual(HubClient.listURL(base: base, since: since, cursor: "E1.42.1790000000500").absoluteString,
                       "http://hub.example.ts.net:8765/v1/items?status=open&since=2026-09-21T14:13:20.500Z&cursor=E1.42.1790000000500")
        // A full poll never carries one (the cursor is a since poll's position).
        XCTAssertEqual(HubClient.listURL(base: base, since: nil, cursor: "E1.42.1").absoluteString,
                       "http://hub.example.ts.net:8765/v1/items?status=open")
    }

    func testPageDecodesNext() throws {
        let page = try HubClient.page(from: Self.body(["a"], serverTime: "2026-10-06T17:04:05.122Z", more: false, next: "E1.7.99"),
                                      since: since)
        XCTAssertEqual(page.next, "E1.7.99")
        let old = try HubClient.page(from: Self.body(["a"], serverTime: "2026-10-06T17:04:05.122Z", more: false, next: nil),
                                     since: since)
        XCTAssertNil(old.next)
        XCTAssertNotNil(old.cursor)
    }

    func testPagingFollowsNext() async throws {
        // The hub's same-millisecond case: server_time doesn't move between pages, `next` does.
        StubURLProtocol.handler = { request in
            let q = Self.query(request)
            switch q["cursor"] {
            case "E1.10.5": return (200, Self.body(["a", "b"], serverTime: "2026-10-06T17:04:05.122Z", more: true, next: "E1.12.5"))
            case "E1.12.5": return (200, Self.body(["c"], serverTime: "2026-10-06T17:04:05.122Z", more: false, next: "E1.13.9"))
            default: return (500, Data())
            }
        }
        let client = HubClient(config: config, session: StubURLProtocol.session())
        let page = try await client.fetchPage(since: since, cursor: "E1.10.5")
        XCTAssertEqual(page.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(page.next, "E1.13.9")
        XCTAssertFalse(page.more)
        let sent = StubURLProtocol.recorded.map { Self.query($0.request) }
        XCTAssertEqual(sent.map { $0["cursor"] }, ["E1.10.5", "E1.12.5"])
        // `since` goes along every time, for a hub that ignores the cursor
        XCTAssertEqual(sent[1]["since"], "2026-10-06T17:04:05.122Z")
    }

    func testPagingWithoutNextUsesServerTime() async throws {
        // A hub before `next`: page by server_time, and send no cursor.
        StubURLProtocol.handler = { request in
            switch Self.query(request)["since"] {
            case "2026-09-21T14:13:20.500Z": return (200, Self.body(["a"], serverTime: "2026-10-06T17:04:05.122Z", more: true, next: nil))
            case "2026-10-06T17:04:05.122Z": return (200, Self.body(["b"], serverTime: "2026-10-06T17:04:06.000Z", more: false, next: nil))
            default: return (500, Data())
            }
        }
        let client = HubClient(config: config, session: StubURLProtocol.session())
        let page = try await client.fetchPage(since: since, cursor: nil)
        XCTAssertEqual(page.items.map(\.id), ["a", "b"])
        XCTAssertNil(page.next)
        XCTAssertEqual(page.cursor, HubJSON.parseDate("2026-10-06T17:04:06.000Z"))
        XCTAssertTrue(StubURLProtocol.recorded.allSatisfy { Self.query($0.request)["cursor"] == nil })
    }

    func testFailoverPassesCursorOnlyToTheSameHub() async throws {
        let one = CursorHub(failing: false), two = CursorHub(failing: false)
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: one), .init(name: "hub2", feed: two)])
        _ = try await feed.fetchPage(since: nil, cursor: nil)
        _ = try await feed.fetchPage(since: since, cursor: "E1.3.4")
        await one.setFailing(true)
        _ = try await feed.fetchPage(since: since, cursor: "E1.3.4")   // hub2 answers: full poll
        let seen1 = await one.cursors, seen2 = await two.cursors
        XCTAssertEqual(seen1, [nil, "E1.3.4", "E1.3.4"])
        XCTAssertEqual(seen2, [nil])
        let since2 = await two.sinceSeen
        XCTAssertEqual(since2, [nil])
    }
}

private actor CursorHub: ItemFeed {
    var failing: Bool
    private(set) var cursors: [String?] = []
    private(set) var sinceSeen: [Date?] = []

    init(failing: Bool) { self.failing = failing }

    func setFailing(_ value: Bool) { failing = value }

    func fetchOpen(since: Date?) async throws -> [Item] { [] }
    func fetchPage(since: Date?, cursor: String?) async throws -> FeedPage {
        cursors.append(cursor)
        sinceSeen.append(since)
        if failing { throw URLError(.timedOut) }
        return FeedPage(items: [], isFullSnapshot: since == nil, next: "N")
    }
    func patch(id: String, _ patch: ItemPatch) async throws {}
}
