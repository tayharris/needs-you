#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Stale cards (stale-items.md, option D): the age badge and "Dismiss all from this host".
final class CardAgeTests: XCTestCase {
    static var allTests = [
        ("testShortAge", testShortAge),
        ("testBadgeThresholdsAndFormat", testBadgeThresholdsAndFormat),
        ("testStale", testStale),
        ("testHostOfItem", testHostOfItem),
        ("testItemsFromHost", testItemsFromHost),
    ]

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    func testShortAge() {
        // The meta line's original format.
        XCTAssertEqual(CardAge.short(0), "now")
        XCTAssertEqual(CardAge.short(-30), "now")
        XCTAssertEqual(CardAge.short(59), "now")
        XCTAssertEqual(CardAge.short(60), "1m")
        XCTAssertEqual(CardAge.short(3599), "59m")
        XCTAssertEqual(CardAge.short(2 * hour), "2h")
        XCTAssertEqual(CardAge.short(3 * day + 5), "3d")
    }

    func testBadgeThresholdsAndFormat() {
        func badge(_ age: TimeInterval) -> String? { CardAge.badge(createdAt: now.addingTimeInterval(-age), now: now) }
        XCTAssertNil(badge(0))
        XCTAssertNil(badge(CardAge.oldAfter - 1))
        XCTAssertEqual(badge(CardAge.oldAfter), "4 h")
        XCTAssertEqual(badge(5 * hour + 59 * 60), "5 h")
        XCTAssertEqual(badge(23 * hour), "23 h")
        XCTAssertEqual(badge(day), "1 d")
        XCTAssertEqual(badge(2 * day + 3 * hour), "2 d")
        XCTAssertEqual(badge(13 * day), "13 d")
        XCTAssertEqual(badge(14 * day), "2 w")
        XCTAssertEqual(badge(30 * day), "4 w")
        // A clock that's behind the sender's: no badge.
        XCTAssertNil(CardAge.badge(createdAt: now.addingTimeInterval(day), now: now))
    }

    func testStale() {
        XCTAssertFalse(CardAge.isStale(createdAt: now.addingTimeInterval(-day), now: now))
        XCTAssertTrue(CardAge.isStale(createdAt: now.addingTimeInterval(-CardAge.staleAfter), now: now))
        XCTAssertTrue(CardAge.staleAfter > CardAge.oldAfter)
    }

    private func item(_ id: String, host: String?, context: ItemContext = .work, kind: ItemKind = .needs, age: TimeInterval = 0) -> Item {
        Item(id: id, key: id, context: context, kind: kind, title: id,
             source: host.map { ItemSource(host: $0, agent: "claude") }, createdAt: now.addingTimeInterval(-age))
    }

    func testHostOfItem() {
        XCTAssertEqual(ItemStore.host(of: item("a", host: " devbox ")), "devbox")
        XCTAssertNil(ItemStore.host(of: item("b", host: "  ")))
        XCTAssertNil(ItemStore.host(of: item("c", host: nil)))
    }

    func testItemsFromHost() {
        var store = ItemStore(items: [
            item("old", host: "devbox", age: 3 * day),
            item("new", host: "DevBox", age: 60),
            item("info", host: "devbox", kind: .info, age: 10),
            item("other-host", host: "ci"),
            item("personal", host: "devbox", context: .personal),
            item("no-host", host: nil),
            item("snoozed", host: "devbox"),
        ])
        store.snoozeCard(id: "snoozed", until: now.addingTimeInterval(hour))

        let ids = store.visibleItems(fromHost: "devbox", in: .work, now: now).map(\.id)
        // Same host (any case), this context, needs and Recent rows, oldest first; not snoozed.
        XCTAssertEqual(ids, ["old", "new", "info"])
        XCTAssertEqual(store.visibleItems(fromHost: "ci", in: .work, now: now).map(\.id), ["other-host"])
        XCTAssertEqual(store.visibleItems(fromHost: "devbox", in: .personal, now: now).map(\.id), ["personal"])
        XCTAssertEqual(store.visibleItems(fromHost: " ", in: .work, now: now), [])

        // Dismissing them all locally leaves the rest.
        for id in ids { store.closeLocally(id: id, now: now) }
        XCTAssertEqual(Set(store.visibleItems(now: now).map(\.id)), ["other-host", "personal", "no-host"])
    }
}
