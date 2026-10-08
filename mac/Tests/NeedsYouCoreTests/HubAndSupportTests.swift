#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

final class HubClientTests: XCTestCase {
    static var allTests = [
        ("testListURL", testListURL),
        ("testItemURLAndAuthHeader", testItemURLAndAuthHeader),
        ("testPatchBodyOnlyHasSetFields", testPatchBodyOnlyHasSetFields),
        ("testDecodesBareArrayAndWrappedList", testDecodesBareArrayAndWrappedList),
        ("testLenientDecoding", testLenientDecoding),
        ("testDateFormats", testDateFormats),
        ("testPollPlannerAlternatesFullAndIncremental", testPollPlannerAlternatesFullAndIncremental),
        ("testMisdirectedErrorNamesTheHostCheck", testMisdirectedErrorNamesTheHostCheck),
        ("testIncrementalPageKeepsClosedItemsAndServerTime", testIncrementalPageKeepsClosedItemsAndServerTime),
        ("testFullPageIsOpenOnlyAndAuthoritative", testFullPageIsOpenOnlyAndAuthoritative),
        ("testTruncatedFullPageIsNotAuthoritative", testTruncatedFullPageIsNotAuthoritative),
    ]

    private static func listJSON(_ items: [(id: String, status: String)], serverTime: String = "2026-10-06T17:04:05.122Z",
                                 more: Bool = false) -> Data {
        let rows = items.map {
            #"{"id":"\#($0.id)","key":"k:\#($0.id)","title":"T","status":"\#($0.status)","created_at":"2026-10-06T10:00:00Z","updated_at":"2026-10-06T10:05:00Z"}"#
        }
        return Data(#"{"items":[\#(rows.joined(separator: ","))],"server_time":"\#(serverTime)","hub_id":"hub-a","more":\#(more)}"#.utf8)
    }

    // docs/API.md "The polling loop": a `since` response holds items in any status, so a
    // sender's resolve reaches the Mac on the next poll, and `server_time` is the next cursor.
    func testIncrementalPageKeepsClosedItemsAndServerTime() throws {
        let since = Date(timeIntervalSince1970: 1_791_280_000)
        let page = try HubClient.page(from: Self.listJSON([("a", "open"), ("b", "resolved"), ("c", "dismissed")]), since: since)
        XCTAssertEqual(page.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(page.isFullSnapshot)
        XCTAssertEqual(page.cursor, HubJSON.parseDate("2026-10-06T17:04:05.122Z"))
        XCTAssertFalse(page.more)

        // Merged, the resolved one leaves the open set without waiting for a full poll.
        let t = Date(timeIntervalSince1970: 1_791_280_000)
        var store = ItemStore(items: [Item(id: "b", key: "k:b", title: "T", createdAt: t)])
        let result = store.merge(page.items, isFullSnapshot: page.isFullSnapshot, now: t)
        XCTAssertNil(store.items["b"])
        XCTAssertEqual(result.removed.map(\.id), ["b"])
        XCTAssertNil(store.items["c"])
        XCTAssertNotNil(store.items["a"])
    }

    func testFullPageIsOpenOnlyAndAuthoritative() throws {
        let page = try HubClient.page(from: Self.listJSON([("a", "open"), ("b", "resolved")]), since: nil)
        XCTAssertEqual(page.items.map(\.id), ["a"])   // belt and braces: a full snapshot is open items
        XCTAssertTrue(page.isFullSnapshot)
        XCTAssertNotNil(page.cursor)
        // A bare array (an older hub) still works, with no cursor.
        let bare = try HubClient.page(from: Data(#"[{"id":"a","title":"T","created_at":"2026-10-06T10:00:00Z"}]"#.utf8), since: nil)
        XCTAssertEqual(bare.items.map(\.id), ["a"])
        XCTAssertNil(bare.cursor)
    }

    // A full snapshot cut off at the hub's limit doesn't list every open item, so it must
    // not close the ones it left out.
    func testTruncatedFullPageIsNotAuthoritative() throws {
        let page = try HubClient.page(from: Self.listJSON([("a", "open")], more: true), since: nil)
        XCTAssertFalse(page.isFullSnapshot)
        XCTAssertTrue(page.more)
    }

    // Security audit #16: a 421 from the hub's Host check says what to change.
    func testMisdirectedErrorNamesTheHostCheck() {
        let text = HubError.misdirected.errorDescription ?? ""
        XCTAssertTrue(text.contains("421"), text)
        XCTAssertTrue(text.contains("allowed_hosts"), text)
        XCTAssertNotEqual(HubError.misdirected, HubError.http(status: 421))
    }

    func testListURL() {
        let base = URL(string: "http://hub.example.ts.net:8765")!
        XCTAssertEqual(HubClient.listURL(base: base, since: nil).absoluteString,
                       "http://hub.example.ts.net:8765/v1/items?status=open")
        let since = Date(timeIntervalSince1970: 1_790_000_000.5)
        XCTAssertEqual(HubClient.listURL(base: base, since: since).absoluteString,
                       "http://hub.example.ts.net:8765/v1/items?status=open&since=2026-09-21T14:13:20.500Z")
        // A base with a path prefix keeps it.
        let prefixed = URL(string: "https://example.com/needs/")!
        XCTAssertEqual(HubClient.listURL(base: prefixed, since: nil).absoluteString,
                       "https://example.com/needs/v1/items?status=open")
    }

    func testItemURLAndAuthHeader() {
        let base = URL(string: "http://hub:8765")!
        let url = HubClient.itemURL(base: base, id: "01J9ABC")
        XCTAssertEqual(url.absoluteString, "http://hub:8765/v1/items/01J9ABC")
        let req = HubClient.makeRequest(url: url, method: "PATCH", token: "tok", body: Data("{}".utf8))
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testPatchBodyOnlyHasSetFields() throws {
        let enc = HubJSON.makeEncoder()
        XCTAssertEqual(String(data: try enc.encode(ItemPatch(status: .dismissed)), encoding: .utf8), #"{"status":"dismissed"}"#)
        let seen = ItemPatch(seenAt: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(String(data: try enc.encode(seen), encoding: .utf8), #"{"seen_at":"2026-09-21T14:13:20.000Z"}"#)
    }

    func testDecodesBareArrayAndWrappedList() throws {
        let one = #"{"id":"01J1","key":"k","context":"work","kind":"needs","priority":"urgent","title":"T","links":[{"label":"Jira","url":"https://x.y/z"}],"source":{"host":"h","agent":"a"},"status":"open","created_at":"2026-10-06T10:00:00Z","updated_at":"2026-10-06T10:05:00.123Z","seen_at":null,"expires_at":null}"#
        let bare = try HubJSON.decodeItemList(Data("[\(one)]".utf8))
        let wrapped = try HubJSON.decodeItemList(Data(#"{"items":[\#(one)],"now":"x"}"#.utf8))
        XCTAssertEqual(bare, wrapped)
        let item = try XCTUnwrap(bare.first)
        XCTAssertEqual(item.priority, .urgent)
        XCTAssertEqual(item.links.first?.label, "Jira")
        XCTAssertEqual(item.source?.displayParts, ["h", "a"])
        XCTAssertNil(item.seenAt)
    }

    func testLenientDecoding() throws {
        // Unknown enum values and missing optional fields must not break a poll.
        let json = #"[{"id":"01J2","kind":"alert","priority":"p0","context":"WORK","status":"open","title":"x","created_at":"2026-10-06T10:00:00Z"}]"#
        let item = try XCTUnwrap(try HubJSON.decodeItemList(Data(json.utf8)).first)
        XCTAssertEqual(item.kind, .info)        // unknown kinds never count
        XCTAssertEqual(item.priority, .normal)
        XCTAssertEqual(item.context, .work)
        XCTAssertEqual(item.key, "01J2")
        XCTAssertEqual(item.updatedAt, item.createdAt)
        XCTAssertTrue(item.links.isEmpty)
    }

    func testDateFormats() {
        let expected = Date(timeIntervalSince1970: 1_791_280_800) // 2026-10-06T10:00:00Z
        XCTAssertEqual(HubJSON.parseDate("2026-10-06T10:00:00Z"), expected)
        XCTAssertEqual(HubJSON.parseDate("2026-10-06T10:00:00.000Z"), expected)
        XCTAssertEqual(HubJSON.parseDate("2026-10-06T10:00:00.000000+00:00"), expected)   // Python isoformat, UTC
        XCTAssertEqual(HubJSON.parseDate("2026-10-06T04:00:00-06:00"), expected)          // Mountain
        XCTAssertEqual(HubJSON.parseDate("2026-10-06T10:00:00"), expected)                // naive = UTC
        XCTAssertEqual(HubJSON.parseDate("2026-10-06 10:00:00"), expected)                // SQLite style
        XCTAssertNil(HubJSON.parseDate("yesterday"))
    }

    func testPollPlannerAlternatesFullAndIncremental() {
        var planner = PollPlanner(fullEvery: 3)
        let latest = Date(timeIntervalSince1970: 100)
        XCTAssertNil(planner.nextSince(latest: latest))           // first: full
        XCTAssertEqual(planner.nextSince(latest: latest), latest)
        XCTAssertEqual(planner.nextSince(latest: latest), latest)
        XCTAssertNil(planner.nextSince(latest: latest))           // every 3rd: full
        XCTAssertEqual(planner.nextSince(latest: latest), latest)
        planner.forceFull()
        XCTAssertNil(planner.nextSince(latest: latest))           // forced (wake, error)
        var p2 = PollPlanner()
        _ = p2.nextSince(latest: nil)
        XCTAssertNil(p2.nextSince(latest: nil))                   // nothing seen yet: still full
    }
}

final class SupportTests: XCTestCase {
    static var allTests = [
        ("testSnoozeDurations", testSnoozeDurations),
        ("testUrgentBreakthrough", testUrgentBreakthrough),
        ("testCornerSnapping", testCornerSnapping),
        ("testScreenConfigurationKeyIsOrderIndependent", testScreenConfigurationKeyIsOrderIndependent),
        ("testBestScreen", testBestScreen),
    ]

    func testSnoozeDurations() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 22, minute: 15))!
        XCTAssertEqual(SnoozeOption.minutes15.until(from: now, calendar: cal).timeIntervalSince(now), 900)
        XCTAssertEqual(SnoozeOption.hours3.until(from: now, calendar: cal).timeIntervalSince(now), 10_800)
        let tomorrow = SnoozeOption.tomorrow.until(from: now, calendar: cal)
        let c = cal.dateComponents([.day, .hour, .minute], from: tomorrow)
        XCTAssertEqual(c.day, 7)
        XCTAssertEqual(c.hour, SnoozeOption.tomorrowHour)
        XCTAssertEqual(c.minute, 0)
    }

    func testUrgentBreakthrough() {
        let now = Date(timeIntervalSince1970: 1_000)
        let urgent = Item(id: "u", key: "u", priority: .urgent, title: "u", createdAt: now)
        let normal = Item(id: "n", key: "n", title: "n", createdAt: now)
        let urgentDone = Item(id: "d", key: "d", kind: .done, priority: .urgent, title: "d", createdAt: now)
        let snoozed = PanelVisibility.snoozed(until: now.addingTimeInterval(60))

        XCTAssertTrue(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [normal, urgent], urgentBreaksThrough: true, now: now))
        XCTAssertTrue(SnoozeBreakthrough.shouldBreakThrough(visibility: .hidden, announced: [urgent], urgentBreaksThrough: true, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [urgent], urgentBreaksThrough: false, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [normal, urgentDone], urgentBreaksThrough: true, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: .shown, announced: [urgent], urgentBreaksThrough: true, now: now))
        // An expired snooze isn't hiding anything.
        XCTAssertFalse(PanelVisibility.snoozed(until: now).isHidden(at: now))
    }

    func testCornerSnapping() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(PanelGeometry.nearestCorner(to: CGRect(x: 900, y: 700, width: 44, height: 22), in: visible), .topRight)
        XCTAssertEqual(PanelGeometry.nearestCorner(to: CGRect(x: 10, y: 10, width: 44, height: 22), in: visible), .bottomLeft)
        XCTAssertEqual(PanelGeometry.nearestCorner(to: CGRect(x: 100, y: 600, width: 44, height: 22), in: visible), .topLeft)
        XCTAssertEqual(PanelGeometry.nearestCorner(to: CGRect(x: 800, y: 100, width: 44, height: 22), in: visible), .bottomRight)

        let size = CGSize(width: 44, height: 22)
        XCTAssertEqual(PanelGeometry.frame(size: size, corner: .topRight, in: visible, margin: 10),
                       CGRect(x: 946, y: 768, width: 44, height: 22))
        XCTAssertEqual(PanelGeometry.frame(size: size, corner: .bottomLeft, in: visible, margin: 10),
                       CGRect(x: 10, y: 10, width: 44, height: 22))
        // Growing from the top-right keeps the top-right edge fixed.
        let big = PanelGeometry.frame(size: CGSize(width: 360, height: 400), corner: .topRight, in: visible, margin: 10)
        XCTAssertEqual(big.maxX, 990)
        XCTAssertEqual(big.maxY, 790)
    }

    func testScreenConfigurationKeyIsOrderIndependent() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(PanelGeometry.configurationKey([laptop, external]), PanelGeometry.configurationKey([external, laptop]))
        XCTAssertNotEqual(PanelGeometry.configurationKey([laptop]), PanelGeometry.configurationKey([laptop, external]))
    }

    func testBestScreen() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        XCTAssertEqual(PanelGeometry.bestScreen(for: CGRect(x: 980, y: 10, width: 44, height: 22), screens: [a, b]), 1)
        XCTAssertEqual(PanelGeometry.bestScreen(for: CGRect(x: -500, y: 10, width: 44, height: 22), screens: [a, b]), 0)
        XCTAssertNil(PanelGeometry.bestScreen(for: .zero, screens: []))
    }
}

final class DemoFeedTests: XCTestCase {
    static var allTests: [(String, (DemoFeedTests) -> () throws -> Void)] = []
    static var asyncTests = [
        ("testDemoFeedBehavesLikeHub", testDemoFeedBehavesLikeHub),
    ]

    func testDemoFeedBehavesLikeHub() async throws {
        let now = Date()
        let feed = DemoFeed(now: now)
        var store = ItemStore()
        let all = try await feed.fetchOpen(since: nil)
        store.merge(all, isFullSnapshot: true, now: now)
        XCTAssertEqual(store.needsCount(in: .work, now: now), 5)
        XCTAssertEqual(store.needsCount(in: .personal, now: now), 1)

        let injected = await feed.injectNext(now: now.addingTimeInterval(1))
        let delta = try await feed.fetchOpen(since: store.latestUpdatedAt)
        let r = store.merge(delta, isFullSnapshot: false, now: now)
        XCTAssertEqual(r.inserted.map(\.id), [injected.id])

        try await feed.patch(id: injected.id, ItemPatch(status: .resolved))
        let full = try await feed.fetchOpen(since: nil)
        let r2 = store.merge(full, isFullSnapshot: true, now: now)
        XCTAssertEqual(r2.removed.map(\.id), [injected.id])
    }
}
