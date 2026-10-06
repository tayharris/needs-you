#if NEEDSTAY_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsTayCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func item(
    _ id: String, key: String? = nil, context: ItemContext = .work, kind: ItemKind = .needs,
    priority: ItemPriority = .normal, title: String? = nil, body: String? = nil,
    status: ItemStatus = .open, created: Double = 0, updated: Double? = nil, expires: Double? = nil
) -> Item {
    Item(
        id: id, key: key ?? "k:\(id)", context: context, kind: kind, priority: priority,
        title: title ?? "title \(id)", body: body, status: status,
        createdAt: t0.addingTimeInterval(created),
        updatedAt: t0.addingTimeInterval(updated ?? created),
        expiresAt: expires.map { t0.addingTimeInterval($0) }
    )
}

final class ItemStoreMergeTests: XCTestCase {
    static var allTests = [
        ("testInsertsNewItems", testInsertsNewItems),
        ("testUpsertWithInvisibleChangeIsTouchedNotAnnounced", testUpsertWithInvisibleChangeIsTouchedNotAnnounced),
        ("testUpsertWithTitleBodyOrPriorityChangeIsAnnounced", testUpsertWithTitleBodyOrPriorityChangeIsAnnounced),
        ("testStaleUpdateIsIgnored", testStaleUpdateIsIgnored),
        ("testIncrementalPollKeepsUnmentionedItems", testIncrementalPollKeepsUnmentionedItems),
        ("testFullSnapshotDropsItemsNoLongerOpen", testFullSnapshotDropsItemsNoLongerOpen),
        ("testClosedStatusInResponseRemovesItem", testClosedStatusInResponseRemovesItem),
        ("testSameKeyNewIdReplacesOldItem", testSameKeyNewIdReplacesOldItem),
        ("testExpiredItemsArePruned", testExpiredItemsArePruned),
        ("testLatestUpdatedAtTracksNewest", testLatestUpdatedAtTracksNewest),
        ("testLocalCloseIsNotResurrectedByRacingPoll", testLocalCloseIsNotResurrectedByRacingPoll),
        ("testLocalCloseIsReopenedByNewerSenderUpdate", testLocalCloseIsReopenedByNewerSenderUpdate),
        ("testRestoreAfterFailedPatch", testRestoreAfterFailedPatch),
    ]

    func testInsertsNewItems() {
        var store = ItemStore()
        let r = store.merge([item("a"), item("b")], isFullSnapshot: true, now: t0)
        XCTAssertEqual(r.inserted.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(r.changed.isEmpty)
    }

    func testUpsertWithInvisibleChangeIsTouchedNotAnnounced() {
        var store = ItemStore()
        store.merge([item("a", title: "Same")], isFullSnapshot: true, now: t0)
        // An hourly automation re-posts the same key: updated_at moves, nothing visible changes.
        let r = store.merge([item("a", title: "Same", updated: 3600)], isFullSnapshot: false, now: t0)
        XCTAssertTrue(r.announce.isEmpty)
        XCTAssertEqual(r.touched.map(\.id), ["a"])
        XCTAssertEqual(store.items["a"]?.updatedAt, t0.addingTimeInterval(3600))
    }

    func testUpsertWithTitleBodyOrPriorityChangeIsAnnounced() {
        var store = ItemStore()
        store.merge([item("a", title: "One"), item("b", body: "x"), item("c")], isFullSnapshot: true, now: t0)
        let r = store.merge([
            item("a", title: "Two", updated: 10),
            item("b", body: "y", updated: 10),
            item("c", priority: .urgent, updated: 10),
        ], isFullSnapshot: false, now: t0)
        XCTAssertEqual(r.changed.map(\.id).sorted(), ["a", "b", "c"])
        XCTAssertTrue(r.inserted.isEmpty)
        XCTAssertEqual(store.items["a"]?.title, "Two")
    }

    func testStaleUpdateIsIgnored() {
        var store = ItemStore()
        store.merge([item("a", title: "New", updated: 100)], isFullSnapshot: true, now: t0)
        let r = store.merge([item("a", title: "Old", updated: 50)], isFullSnapshot: false, now: t0)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(store.items["a"]?.title, "New")
    }

    func testIncrementalPollKeepsUnmentionedItems() {
        var store = ItemStore()
        store.merge([item("a"), item("b")], isFullSnapshot: true, now: t0)
        let r = store.merge([item("c", created: 5)], isFullSnapshot: false, now: t0)
        XCTAssertEqual(r.inserted.map(\.id), ["c"])
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertEqual(Set(store.items.keys), ["a", "b", "c"])
    }

    func testFullSnapshotDropsItemsNoLongerOpen() {
        var store = ItemStore()
        store.merge([item("a"), item("b")], isFullSnapshot: true, now: t0)
        let r = store.merge([item("b")], isFullSnapshot: true, now: t0)
        XCTAssertEqual(r.removed.map(\.id), ["a"])
        XCTAssertEqual(Array(store.items.keys), ["b"])
    }

    func testClosedStatusInResponseRemovesItem() {
        var store = ItemStore()
        store.merge([item("a")], isFullSnapshot: true, now: t0)
        let r = store.merge([item("a", status: .resolved, updated: 10)], isFullSnapshot: false, now: t0)
        XCTAssertEqual(r.removed.map(\.id), ["a"])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSameKeyNewIdReplacesOldItem() {
        var store = ItemStore()
        store.merge([item("a", key: "acme:ACME-1:x", title: "v1")], isFullSnapshot: true, now: t0)
        let r = store.merge([item("b", key: "acme:ACME-1:x", title: "v2", updated: 10)], isFullSnapshot: false, now: t0)
        XCTAssertEqual(Array(store.items.keys), ["b"])
        XCTAssertEqual(r.changed.map(\.id), ["b"])
        XCTAssertTrue(r.inserted.isEmpty)
    }

    func testExpiredItemsArePruned() {
        var store = ItemStore()
        store.merge([item("done1", kind: .done, expires: 60), item("a")], isFullSnapshot: true, now: t0)
        XCTAssertEqual(store.items.count, 2)
        let dropped = store.prune(now: t0.addingTimeInterval(61))
        XCTAssertEqual(dropped.map(\.id), ["done1"])
        // And an already-expired item is never inserted.
        let r = store.merge([item("old", kind: .info, expires: -1)], isFullSnapshot: false, now: t0)
        XCTAssertTrue(r.inserted.isEmpty)
        XCTAssertNil(store.items["old"])
    }

    func testLatestUpdatedAtTracksNewest() {
        var store = ItemStore()
        store.merge([item("a", updated: 30), item("b", updated: 10)], isFullSnapshot: true, now: t0)
        XCTAssertEqual(store.latestUpdatedAt, t0.addingTimeInterval(30))
        store.merge([item("c", updated: 20)], isFullSnapshot: false, now: t0)
        XCTAssertEqual(store.latestUpdatedAt, t0.addingTimeInterval(30))
    }

    func testLocalCloseIsNotResurrectedByRacingPoll() {
        var store = ItemStore()
        store.merge([item("a", updated: 10)], isFullSnapshot: true, now: t0)
        XCTAssertNotNil(store.closeLocally(id: "a"))
        // The poll lands before the PATCH: the hub still says open, same updated_at.
        let r = store.merge([item("a", updated: 10)], isFullSnapshot: true, now: t0)
        XCTAssertTrue(r.inserted.isEmpty)
        XCTAssertNil(store.items["a"])
    }

    func testLocalCloseIsReopenedByNewerSenderUpdate() {
        var store = ItemStore()
        store.merge([item("a", updated: 10)], isFullSnapshot: true, now: t0)
        store.closeLocally(id: "a")
        let r = store.merge([item("a", title: "changed", updated: 20)], isFullSnapshot: false, now: t0)
        XCTAssertEqual(r.inserted.map(\.id), ["a"])
    }

    func testRestoreAfterFailedPatch() {
        var store = ItemStore()
        store.merge([item("a")], isFullSnapshot: true, now: t0)
        let closed = store.closeLocally(id: "a")!
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 0)
        store.restore(closed)
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 1)
    }
}

final class ItemStoreCountTests: XCTestCase {
    static var allTests = [
        ("testCountsOnlyOpenNeedsInContext", testCountsOnlyOpenNeedsInContext),
        ("testCardSnoozeHidesFromCountUntilItEnds", testCardSnoozeHidesFromCountUntilItEnds),
        ("testNeedsOrderedByPriorityThenAge", testNeedsOrderedByPriorityThenAge),
        ("testHighestPriorityIgnoresDoneAndInfo", testHighestPriorityIgnoresDoneAndInfo),
        ("testRecentHoldsDoneAndInfoNewestFirst", testRecentHoldsDoneAndInfoNewestFirst),
    ]

    func testCountsOnlyOpenNeedsInContext() {
        let store = ItemStore(items: [
            item("w1"), item("w2", priority: .urgent), item("w3", priority: .low),
            item("wdone", kind: .done), item("winfo", kind: .info),
            item("wclosed", status: .resolved),
            item("p1", context: .personal),
            item("pinfo", context: .personal, kind: .info),
        ])
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 3)
        XCTAssertEqual(store.needsCount(in: .personal, now: t0), 1)
    }

    func testCardSnoozeHidesFromCountUntilItEnds() {
        var store = ItemStore(items: [item("a"), item("b")])
        store.snoozeCard(id: "a", until: t0.addingTimeInterval(900))
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 1)
        XCTAssertEqual(store.needsCount(in: .work, now: t0.addingTimeInterval(901)), 2)
    }

    func testNeedsOrderedByPriorityThenAge() {
        let store = ItemStore(items: [
            item("low", priority: .low, created: 0),
            item("normalNew", priority: .normal, created: 20),
            item("urgent", priority: .urgent, created: 30),
            item("normalOld", priority: .normal, created: 10),
        ])
        XCTAssertEqual(store.needs(in: .work, now: t0).map(\.id), ["urgent", "normalOld", "normalNew", "low"])
    }

    func testHighestPriorityIgnoresDoneAndInfo() {
        let store = ItemStore(items: [
            item("n", priority: .low),
            item("d", kind: .done, priority: .urgent),
            item("p", context: .personal, priority: .urgent),
        ])
        XCTAssertEqual(store.highestPriority(in: .work, now: t0), .low)
        XCTAssertEqual(store.highestPriority(in: .personal, now: t0), .urgent)
        XCTAssertNil(ItemStore().highestPriority(in: .work, now: t0))
    }

    func testRecentHoldsDoneAndInfoNewestFirst() {
        let store = ItemStore(items: [
            item("d1", kind: .done, updated: 10),
            item("i1", kind: .info, updated: 20),
            item("n1"),
        ])
        XCTAssertEqual(store.recent(in: .work, now: t0).map(\.id), ["i1", "d1"])
    }
}
