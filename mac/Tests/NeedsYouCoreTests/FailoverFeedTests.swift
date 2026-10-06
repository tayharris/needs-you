#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// A scriptable hub.
private actor FakeHub: ItemFeed {
    var items: [Item]
    var failing = false
    private(set) var sinceSeen: [Date?] = []
    private(set) var patches: [String] = []

    init(items: [Item]) { self.items = items }

    func setFailing(_ value: Bool) { failing = value }

    func fetchOpen(since: Date?) async throws -> [Item] {
        sinceSeen.append(since)
        if failing { throw URLError(.timedOut) }
        return items
    }

    func patch(id: String, _ patch: ItemPatch) async throws {
        if failing { throw URLError(.cannotConnectToHost) }
        patches.append(id)
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func item(_ id: String, title: String = "t", updated: Double = 0) -> Item {
    Item(id: id, key: "k:\(id)", title: title, createdAt: base, updatedAt: base.addingTimeInterval(updated))
}

final class FailoverFeedTests: XCTestCase {
    static var allTests: [(String, (FailoverFeedTests) -> () throws -> Void)] = [
        ("testHubNames", testHubNames),
    ]
    static var asyncTests = [
        ("testUsesFirstReachableHubAndFailsOver", testUsesFirstReachableHubAndFailsOver),
        ("testSwitchingHubForcesFullSnapshot", testSwitchingHubForcesFullSnapshot),
        ("testReturnsToPrimaryAfterCooldown", testReturnsToPrimaryAfterCooldown),
        ("testPatchGoesToCurrentHub", testPatchGoesToCurrentHub),
        ("testAllHubsDownThrows", testAllHubsDownThrows),
        ("testMergeAcrossHubsIsLastWriterWins", testMergeAcrossHubsIsLastWriterWins),
    ]

    func testHubNames() {
        XCTAssertEqual(HubName.short(URL(string: "http://hub2.example.ts.net:8765")!), "hub2")
        XCTAssertEqual(HubName.short(URL(string: "http://100.64.0.7:8765")!), "100.64.0.7")
        XCTAssertEqual(HubName.key(URL(string: "HTTP://Hub1.Example.com:8765/")!), "http://hub1.example.com:8765")
        XCTAssertEqual(HubName.key(URL(string: "https://x.example.com/needs/")!), "https://x.example.com/needs")
    }

    func testUsesFirstReachableHubAndFailsOver() async throws {
        let a = FakeHub(items: [item("1")]), b = FakeHub(items: [item("1"), item("2")])
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        var page = try await feed.fetchPage(since: nil)
        XCTAssertEqual(page.source, "hub1")
        XCTAssertEqual(page.items.count, 1)

        await a.setFailing(true)
        page = try await feed.fetchPage(since: base)
        XCTAssertEqual(page.source, "hub2")
        XCTAssertEqual(page.items.count, 2)
        let current = await feed.currentHubName
        XCTAssertEqual(current, "hub2")
    }

    func testSwitchingHubForcesFullSnapshot() async throws {
        let a = FakeHub(items: []), b = FakeHub(items: [])
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        _ = try await feed.fetchPage(since: nil)
        let incremental = try await feed.fetchPage(since: base)
        XCTAssertFalse(incremental.isFullSnapshot)           // same hub: since is kept

        await a.setFailing(true)
        let switched = try await feed.fetchPage(since: base)
        XCTAssertTrue(switched.isFullSnapshot)               // new hub: full snapshot
        let bSince = await b.sinceSeen
        XCTAssertEqual(bSince.count, 1)
        XCTAssertNil(bSince.first ?? base)

        let next = try await feed.fetchPage(since: base)     // sticking with hub2: incremental again
        XCTAssertFalse(next.isFullSnapshot)
    }

    func testReturnsToPrimaryAfterCooldown() async throws {
        let clock = Clock()
        let a = FakeHub(items: []), b = FakeHub(items: [])
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)],
                                cooldown: 60, clock: { clock.now })
        await a.setFailing(true)
        var page = try await feed.fetchPage(since: nil)
        XCTAssertEqual(page.source, "hub2")
        await a.setFailing(false)

        page = try await feed.fetchPage(since: nil)          // hub1 still cooling down
        XCTAssertEqual(page.source, "hub2")
        let aCallsDuringCooldown = await a.sinceSeen.count
        XCTAssertEqual(aCallsDuringCooldown, 1)

        clock.now = clock.now.addingTimeInterval(61)
        page = try await feed.fetchPage(since: nil)
        XCTAssertEqual(page.source, "hub1")
    }

    func testPatchGoesToCurrentHub() async throws {
        let a = FakeHub(items: []), b = FakeHub(items: [])
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        await a.setFailing(true)
        _ = try await feed.fetchPage(since: nil)             // now reading from hub2
        await a.setFailing(false)
        try await feed.patch(id: "x", ItemPatch(status: .resolved))
        let aPatches = await a.patches, bPatches = await b.patches
        XCTAssertEqual(bPatches, ["x"])
        XCTAssertEqual(aPatches, [])

        await b.setFailing(true)                             // current hub down: fall back
        try await feed.patch(id: "y", ItemPatch(status: .dismissed))
        let aAfter = await a.patches
        XCTAssertEqual(aAfter, ["y"])
    }

    func testAllHubsDownThrows() async {
        let a = FakeHub(items: []), b = FakeHub(items: [])
        await a.setFailing(true)
        await b.setFailing(true)
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        do {
            _ = try await feed.fetchPage(since: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
        do {
            _ = try await FailoverFeed(hubs: []).fetchPage(since: nil)
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? HubError, .notConfigured)
        }
    }

    func testMergeAcrossHubsIsLastWriterWins() async throws {
        // hub1 has the newer version of item 1; hub2 lags behind.
        let a = FakeHub(items: [item("1", title: "new", updated: 20)])
        let b = FakeHub(items: [item("1", title: "old", updated: 10), item("2", updated: 5)])
        let feed = FailoverFeed(hubs: [.init(name: "hub1", feed: a), .init(name: "hub2", feed: b)])
        var store = ItemStore()
        var page = try await feed.fetchPage(since: nil)
        store.merge(page.items, isFullSnapshot: page.isFullSnapshot)
        await a.setFailing(true)
        page = try await feed.fetchPage(since: store.latestUpdatedAt)
        store.merge(page.items, isFullSnapshot: page.isFullSnapshot)
        XCTAssertEqual(store.items["1"]?.title, "new")       // the lagging hub doesn't roll it back
        XCTAssertNotNil(store.items["2"])
    }
}
