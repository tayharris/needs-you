#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

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
        ("testDoneWinsOverRacingSeenPatch", testDoneWinsOverRacingSeenPatch),
        ("testLocalCloseIsReopenedByContentUpdate", testLocalCloseIsReopenedByContentUpdate),
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

    func testDoneWinsOverRacingSeenPatch() {
        // The panel opened (seen_at PATCH) and Done was clicked before the next poll: the
        // poll brings the seen version (newer updated_at, nothing else changed) while the
        // Done PATCH is still in flight. The card stays gone.
        var store = ItemStore()
        store.merge([item("a", updated: 10)], isFullSnapshot: true, now: t0)
        store.markSeen(id: "a", at: t0.addingTimeInterval(15))
        store.closeLocally(id: "a")
        var seen = item("a", updated: 20)
        seen.seenAt = t0.addingTimeInterval(15)
        let r = store.merge([seen], isFullSnapshot: false, now: t0)
        XCTAssertTrue(r.inserted.isEmpty)
        XCTAssertNil(store.items["a"])
        // Also through a full snapshot, and an unchanged re-post with only a later updated_at.
        store.merge([seen], isFullSnapshot: true, now: t0)
        XCTAssertNil(store.items["a"])
        // Then the Done lands: the close settles and the tombstone goes.
        store.merge([item("a", status: .resolved, updated: 25)], isFullSnapshot: false, now: t0)
        XCTAssertNil(store.items["a"])
        XCTAssertEqual(store.closedTombstoneCount, 0)
    }

    func testLocalCloseIsReopenedByContentUpdate() {
        // content_updated_at moved (the sender changed steps, say): it's live again.
        var store = ItemStore()
        var a = item("a", updated: 10)
        a.contentUpdatedAt = t0.addingTimeInterval(10)
        store.merge([a], isFullSnapshot: true, now: t0)
        store.closeLocally(id: "a")
        a.updatedAt = t0.addingTimeInterval(20)
        a.contentUpdatedAt = t0.addingTimeInterval(20)
        let r = store.merge([a], isFullSnapshot: false, now: t0)
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

/// The Later list (docs/roadmap/focus-tiers.md, build step 4).
final class ItemStoreLaterTests: XCTestCase {
    static var allTests = [
        ("testHeldItemsLeaveTheCountAndList", testHeldItemsLeaveTheCountAndList),
        ("testReleaseDeliversEverythingOnce", testReleaseDeliversEverythingOnce),
        ("testOnlyOpenNeedsAreHeld", testOnlyOpenNeedsAreHeld),
        ("testHoldsGoAwayWithTheirItem", testHoldsGoAwayWithTheirItem),
        ("testTwinReplacementKeepsTheHold", testTwinReplacementKeepsTheHold),
        ("testLaterOrderAndContext", testLaterOrderAndContext),
        ("testHeldItemThatStopsBeingNeedsLeavesLater", testHeldItemThatStopsBeingNeedsLeavesLater),
    ]

    // An agent's "waiting" card held by a focus, re-posted as done: it's a Recent row now,
    // not also under Later (and not in the "3 waited" peek).
    func testHeldItemThatStopsBeingNeedsLeavesLater() {
        var store = ItemStore(items: [item("a"), item("old", key: "k:same")])
        store.holdForLater(id: "a", at: t0)
        store.holdForLater(id: "old", at: t0)
        store.merge([item("a", kind: .done, updated: 5), item("new", key: "k:same", kind: .info, updated: 5)],
                    isFullSnapshot: false, now: t0)
        XCTAssertFalse(store.isHeldForLater("a"))
        XCTAssertFalse(store.isHeldForLater("new"))
        XCTAssertTrue(store.laterItems(now: t0).isEmpty)
        XCTAssertEqual(Set(store.recent(in: .work, now: t0).map(\.id)), ["a", "new"])
        XCTAssertTrue(store.releaseLater(now: t0).isEmpty)
    }

    func testHeldItemsLeaveTheCountAndList() {
        var store = ItemStore(items: [item("a"), item("b", priority: .urgent)])
        store.holdForLater(id: "b", at: t0)
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 1)
        XCTAssertEqual(store.needs(in: .work, now: t0).map(\.id), ["a"])
        XCTAssertEqual(store.highestPriority(in: .work, now: t0), .normal, "a held urgent item doesn't colour the ring")
        XCTAssertEqual(store.laterItems(now: t0).map(\.id), ["b"])
        XCTAssertEqual(store.laterCount(in: .work, now: t0), 1)
        XCTAssertTrue(store.isHeldForLater("b"))
        store.unhold(id: "b")
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 2)
    }

    func testReleaseDeliversEverythingOnce() {
        var store = ItemStore(items: [item("a"), item("b"), item("c")])
        store.holdForLater(id: "a", at: t0)
        store.holdForLater(id: "b", at: t0.addingTimeInterval(5))
        XCTAssertEqual(store.releaseLater(now: t0).map(\.id), ["a", "b"])
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 3)
        XCTAssertTrue(store.releaseLater(now: t0).isEmpty)
    }

    func testOnlyOpenNeedsAreHeld() {
        var store = ItemStore(items: [item("d", kind: .done), item("i", kind: .info)])
        store.holdForLater(id: "d", at: t0)
        store.holdForLater(id: "i", at: t0)
        store.holdForLater(id: "missing", at: t0)
        XCTAssertTrue(store.heldForLater.isEmpty)
    }

    func testHoldsGoAwayWithTheirItem() {
        var store = ItemStore(items: [item("a"), item("b"), item("c", expires: 60), item("d")])
        for id in ["a", "b", "c", "d"] { store.holdForLater(id: id, at: t0) }
        // Resolved on the hub.
        store.merge([item("a", status: .resolved, updated: 10)], isFullSnapshot: false, now: t0)
        // Closed here.
        store.closeLocally(id: "b", now: t0)
        // Expired.
        store.prune(now: t0.addingTimeInterval(61))
        XCTAssertEqual(Set(store.heldForLater.keys), ["d"])
        // Missing from a full snapshot.
        store.merge([], isFullSnapshot: true, now: t0.addingTimeInterval(62))
        XCTAssertTrue(store.heldForLater.isEmpty)
    }

    func testTwinReplacementKeepsTheHold() {
        var store = ItemStore(items: [item("old", key: "k:same")])
        store.holdForLater(id: "old", at: t0)
        store.merge([item("new", key: "k:same", updated: 5)], isFullSnapshot: false, now: t0)
        XCTAssertTrue(store.isHeldForLater("new"))
        XCTAssertFalse(store.isHeldForLater("old"))
        XCTAssertEqual(store.needsCount(in: .work, now: t0), 0)
    }

    func testLaterOrderAndContext() {
        var store = ItemStore(items: [item("w1"), item("w2"), item("p1", context: .personal)])
        store.holdForLater(id: "w2", at: t0)
        store.holdForLater(id: "p1", at: t0.addingTimeInterval(1))
        store.holdForLater(id: "w1", at: t0.addingTimeInterval(2))
        store.holdForLater(id: "w2", at: t0.addingTimeInterval(9))   // keeps its first time
        XCTAssertEqual(store.laterItems(now: t0).map(\.id), ["w2", "p1", "w1"])
        XCTAssertEqual(store.laterItems(in: .work, now: t0).map(\.id), ["w2", "w1"])
        XCTAssertEqual(store.laterCount(in: .personal, now: t0), 1)
        // A card snooze hides it from Later too.
        store.snoozeCard(id: "w1", until: t0.addingTimeInterval(900))
        XCTAssertEqual(store.laterCount(in: .work, now: t0), 1)
    }
}
