#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

private let p0 = Date(timeIntervalSince1970: 1_790_000_000)

private func pillItem(_ id: String, _ priority: ItemPriority = .normal, context: ItemContext = .work,
                      kind: ItemKind = .needs, title: String? = nil, created: Double = 0,
                      updated: Double? = nil, contentUpdated: Double? = nil) -> Item {
    Item(id: id, key: "k:\(id)", context: context, kind: kind, priority: priority, title: title ?? "title \(id)",
         createdAt: p0.addingTimeInterval(created), updatedAt: p0.addingTimeInterval(updated ?? created),
         contentUpdatedAt: contentUpdated.map { p0.addingTimeInterval($0) })
}

/// The original pill's width formula (PanelController before pill options), kept here so
/// the default pill provably doesn't change size.
private func originalUnits(count: Int, other: Int, later: Int, focused: Bool, link: Bool) -> Int {
    String(count).count + (other > 0 ? String(other).count + 2 : 0)
        + (later > 0 ? String(later).count + 1 : 0) + (focused ? 2 : 0) + (link ? 2 : 0)
}

final class PillContentTests: XCTestCase {
    static var allTests = [
        ("testDefaultsAreTheOriginalPill", testDefaultsAreTheOriginalPill),
        ("testDefaultUnitsMatchTheOriginalFormula", testDefaultUnitsMatchTheOriginalFormula),
        ("testZeroCountIsDim", testZeroCountIsDim),
        ("testNewBadgeFollowsTheCount", testNewBadgeFollowsTheCount),
        ("testNewBadgeCanBeTurnedOff", testNewBadgeCanBeTurnedOff),
        ("testContextSplit", testContextSplit),
        ("testContextSplitFromPersonal", testContextSplitFromPersonal),
        ("testPrioritySplitHidesEmptyBuckets", testPrioritySplitHidesEmptyBuckets),
        ("testPrioritySplitWithNothingHereShowsZero", testPrioritySplitWithNothingHereShowsZero),
        ("testTopItemTitle", testTopItemTitle),
        ("testTopItemTitleIsTruncatedToOneLine", testTopItemTitleIsTruncatedToOneLine),
        ("testTopItemWithNothingHere", testTopItemWithNothingHere),
        ("testDotAtRestAndCountOnHover", testDotAtRestAndCountOnHover),
        ("testDotWithOnlyOtherSideIsFaint", testDotWithOnlyOtherSideIsFaint),
        ("testHelpDefault", testHelpDefault),
        ("testHelpWithEverything", testHelpWithEverything),
        ("testTruncate", testTruncate),
    ]

    private let three = [pillItem("u", .urgent), pillItem("n1", .normal), pillItem("n2", .normal)]

    func testDefaultsAreTheOriginalPill() {
        XCTAssertEqual(PillOptions.defaults, PillOptions(size: .medium, detail: .count, split: .none, showNew: true))
        let c = PillContent.make(PillInput(context: .work, items: three, otherCount: 1, laterCount: 2),
                                 options: .defaults, hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["3", "· 1", "+2"])
        XCTAssertEqual(c.segments.map(\.style), [.count(dim: false), .other, .later])
        XCTAssertNil(c.title)
        XCTAssertFalse(c.isDot)
        XCTAssertEqual(c.dotPriority, .urgent)
    }

    func testDefaultUnitsMatchTheOriginalFormula() {
        for count in [0, 1, 12] {
            for other in [0, 3, 140] {
                for later in [0, 7] {
                    for (focused, link) in [(false, false), (true, false), (true, true)] {
                        let items = (0..<count).map { pillItem("i\($0)") }
                        let input = PillInput(context: .work, items: items, otherCount: other, laterCount: later,
                                              focused: focused, focusSetByLink: link)
                        let c = PillContent.make(input, options: .defaults, hovering: false)
                        XCTAssertEqual(c.units, originalUnits(count: count, other: other, later: later, focused: focused, link: link),
                                       "count \(count) other \(other) later \(later)")
                    }
                }
            }
        }
    }

    func testZeroCountIsDim() {
        let c = PillContent.make(PillInput(context: .work, items: [], otherCount: 2), options: .defaults, hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["0", "· 2"])
        XCTAssertEqual(c.segments.first?.style, .count(dim: true))
        XCTAssertNil(c.dotPriority)
    }

    func testNewBadgeFollowsTheCount() {
        let c = PillContent.make(PillInput(context: .work, items: three, otherCount: 1, newCount: 2),
                                 options: .defaults, hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["3", "2 new", "· 1"])
        XCTAssertEqual(c.segments[1].style, .new)
        XCTAssertEqual(c.units, 1 + (1 + 4) + (1 + 2))
    }

    func testNewBadgeCanBeTurnedOff() {
        var options = PillOptions.defaults
        options.showNew = false
        let c = PillContent.make(PillInput(context: .work, items: three, newCount: 2), options: options, hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["3"])
        XCTAssertFalse(c.help.contains("new"))
    }

    func testContextSplit() {
        let options = PillOptions(split: .context)
        let c = PillContent.make(PillInput(context: .work, items: three, otherCount: 1, laterCount: 4),
                                 options: options, hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["3", "|", "1", "+4"])
        XCTAssertEqual(c.segments.map(\.label), ["W", nil, "P", nil])
        XCTAssertEqual(c.segments[0].style, .context(.work, current: true))
        XCTAssertEqual(c.segments[2].style, .context(.personal, current: false))
        // No separate faint "· 1": the split already shows it.
        XCTAssertFalse(c.segments.contains { $0.style == .other })
        XCTAssertEqual(c.units, (1 + 2) + 1 + (1 + 2) + (1 + 1))
    }

    func testContextSplitFromPersonal() {
        let c = PillContent.make(PillInput(context: .personal, items: [pillItem("p", context: .personal)], otherCount: 0),
                                 options: PillOptions(split: .context), hovering: false)
        // Work stays on the left; zero still shows so the sides don't jump.
        XCTAssertEqual(c.segments.map(\.text), ["0", "|", "1"])
        XCTAssertEqual(c.segments[0].style, .context(.work, current: false))
        XCTAssertEqual(c.segments[2].style, .context(.personal, current: true))
    }

    func testPrioritySplitHidesEmptyBuckets() {
        let items = [pillItem("u", .urgent), pillItem("l1", .low), pillItem("l2", .low)]
        let c = PillContent.make(PillInput(context: .work, items: items, otherCount: 5),
                                 options: PillOptions(split: .priority), hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["1", "2", "· 5"])
        XCTAssertEqual(c.segments.map(\.style), [.priority(.urgent), .priority(.low), .other])
        XCTAssertEqual(c.units, 2 + 2 + 3)
        XCTAssertTrue(c.help.contains("(1 urgent, 2 low)"), c.help)
    }

    func testPrioritySplitWithNothingHereShowsZero() {
        let c = PillContent.make(PillInput(context: .work, items: [], laterCount: 1),
                                 options: PillOptions(split: .priority), hovering: false)
        XCTAssertEqual(c.segments.map(\.text), ["0", "+1"])
        XCTAssertEqual(c.segments.first?.style, .count(dim: true))
    }

    func testTopItemTitle() {
        let items = [pillItem("u", .urgent, title: "Approve the deploy"), pillItem("n", title: "Other")]
        let c = PillContent.make(PillInput(context: .work, items: items), options: PillOptions(detail: .topItem), hovering: false)
        XCTAssertEqual(c.title, "Approve the deploy")
        XCTAssertEqual(c.segments.map(\.text), ["2"])
        XCTAssertEqual(c.units, 1)
        XCTAssertTrue(c.help.hasSuffix(" · Top: Approve the deploy"), c.help)
    }

    func testTopItemTitleIsTruncatedToOneLine() {
        let long = "Approve the production deploy\nfor ACME-4700 and then watch the canary for ten minutes"
        let c = PillContent.make(PillInput(context: .work, items: [pillItem("a", title: long)]),
                                 options: PillOptions(detail: .topItem), hovering: false)
        let title = c.title
        XCTAssertEqual(title?.count, PillContent.titleLimit)
        XCTAssertTrue(title?.hasSuffix("…") ?? false)
        XCTAssertFalse(title?.contains("\n") ?? true)
    }

    func testTopItemWithNothingHere() {
        let c = PillContent.make(PillInput(context: .work, items: [], otherCount: 1),
                                 options: PillOptions(detail: .topItem), hovering: false)
        XCTAssertNil(c.title)
    }

    func testDotAtRestAndCountOnHover() {
        let options = PillOptions(detail: .dot, split: .priority)
        let input = PillInput(context: .work, items: [pillItem("n"), pillItem("u", .urgent)], newCount: 1)
        let rest = PillContent.make(input, options: options, hovering: false)
        XCTAssertTrue(rest.isDot)
        XCTAssertEqual(rest.segments, [])
        XCTAssertEqual(rest.units, 0)
        XCTAssertEqual(rest.dotPriority, .urgent)
        XCTAssertTrue(rest.help.contains("2 work items (1 urgent, 1 normal)"), rest.help)
        let hover = PillContent.make(input, options: options, hovering: true)
        XCTAssertFalse(hover.isDot)
        XCTAssertEqual(hover.segments.map(\.text), ["1", "1", "1 new"])
        XCTAssertEqual(hover.help, rest.help)
    }

    func testDotWithOnlyOtherSideIsFaint() {
        let c = PillContent.make(PillInput(context: .work, items: [], otherCount: 2),
                                 options: PillOptions(detail: .dot), hovering: false)
        XCTAssertTrue(c.isDot)
        XCTAssertNil(c.dotPriority)
    }

    func testHelpDefault() {
        // The original tooltip, before the focus and status line the app appends.
        XCTAssertEqual(PillContent.make(PillInput(context: .work, items: three), options: .defaults, hovering: false).help,
                       "needs you: 3 work items")
        XCTAssertEqual(PillContent.make(PillInput(context: .personal, items: [pillItem("a", context: .personal)], laterCount: 2,
                                                  needsLabel: "needs Sam"), options: .defaults, hovering: false).help,
                       "needs Sam: 1 personal item, 2 under Later")
    }

    func testHelpWithEverything() {
        let input = PillInput(context: .work, items: three, otherCount: 1, laterCount: 2, newCount: 2)
        XCTAssertEqual(PillContent.make(input, options: PillOptions(split: .priority), hovering: false).help,
                       "needs you: 3 work items (1 urgent, 2 normal), 2 new since you last opened it, 1 personal, 2 under Later")
    }

    func testTruncate() {
        XCTAssertEqual(PillContent.truncate("short", limit: 10), "short")
        XCTAssertEqual(PillContent.truncate("  two\n lines  ", limit: 10), "two lines")
        XCTAssertEqual(PillContent.truncate("abcdefghijkl", limit: 5), "abcd…")
        XCTAssertEqual(PillContent.truncate("abc defghijkl", limit: 5), "abc…")
    }
}

final class PillMetricsTests: XCTestCase {
    static var allTests = [
        ("testMediumIsThePanelSizesCountPill", testMediumIsThePanelSizesCountPill),
        ("testSizesGrowInOrder", testSizesGrowInOrder),
        ("testWidthWithTitleIsCapped", testWidthWithTitleIsCapped),
        ("testCornerRadiusNeverExceedsHalfTheHeight", testCornerRadiusNeverExceedsHalfTheHeight),
    ]

    func testMediumIsThePanelSizesCountPill() {
        for size in PanelSize.allCases {
            let m = PanelStyle.metrics(size)
            let pm = PillMetrics.make(m, size: .medium)
            XCTAssertEqual(pm.font, m.countFont)
            XCTAssertEqual(pm.height, m.countHeight)
            XCTAssertEqual(pm.cornerRadius, PillMetrics.baseCornerRadius)
            for units in 0...12 {
                XCTAssertEqual(pm.width(units: units), m.countWidth(digits: units))
            }
        }
        // The regular panel's pill is the original 44×22.
        let pm = UIPrefs.defaults.pillMetrics
        XCTAssertEqual(pm.width(units: 1), 44)
        XCTAssertEqual(pm.height, 22)
    }

    func testSizesGrowInOrder() {
        let m = PanelStyle.regular
        let small = PillMetrics.make(m, size: .small)
        let medium = PillMetrics.make(m, size: .medium)
        let large = PillMetrics.make(m, size: .large)
        XCTAssertTrue(small.font < medium.font && medium.font < large.font)
        XCTAssertTrue(small.height < medium.height && medium.height < large.height)
        XCTAssertTrue(small.width(units: 2) < medium.width(units: 2) && medium.width(units: 2) < large.width(units: 2))
        XCTAssertEqual(large.height, 29.5)
        XCTAssertEqual(large.font, 16)
        XCTAssertEqual(small.height, 18.5)
    }

    func testWidthWithTitleIsCapped() {
        let pm = PillMetrics.make(PanelStyle.regular, size: .medium)
        XCTAssertEqual(pm.width(units: 1, titleWidth: 100.2), 18 + 8 + 6 + 101)
        XCTAssertEqual(pm.width(units: 1, titleWidth: 0), 44)
        XCTAssertEqual(pm.width(units: 1, titleWidth: 5000), pm.maxWidth)
        XCTAssertEqual(pm.dotWidth, pm.height)
    }

    func testCornerRadiusNeverExceedsHalfTheHeight() {
        for panel in PanelSize.allCases {
            for size in PillSize.allCases {
                let pm = PillMetrics.make(PanelStyle.metrics(panel), size: size)
                // Medium keeps the original 11 pt (SwiftUI clamps it on the 20 pt compact pill).
                if size != .medium { XCTAssertTrue(pm.cornerRadius <= pm.height / 2, "\(panel) \(size)") }
                XCTAssertTrue(pm.dotSize < pm.height)
            }
        }
    }
}

/// "New since last opened": created, changed or turned into `needs` after the panel was
/// last open (ItemStore.freshAt / newNeedsCount).
final class PillNewCountTests: XCTestCase {
    static var allTests = [
        ("testNeverOpenedCountsNothing", testNeverOpenedCountsNothing),
        ("testCreatedAfterLastOpen", testCreatedAfterLastOpen),
        ("testContentChangeCountsAsNew", testContentChangeCountsAsNew),
        ("testInvisibleUpdateIsNotNew", testInvisibleUpdateIsNotNew),
        ("testTurnedIntoNeedsCountsAsNew", testTurnedIntoNeedsCountsAsNew),
        ("testOnlyCountedItemsInTheContext", testOnlyCountedItemsInTheContext),
        ("testDecodesContentUpdatedAt", testDecodesContentUpdatedAt),
    ]

    func testNeverOpenedCountsNothing() {
        let store = ItemStore(items: [pillItem("a", created: 100)])
        XCTAssertEqual(store.newNeedsCount(in: .work, since: nil, now: p0), 0)
    }

    func testCreatedAfterLastOpen() {
        let store = ItemStore(items: [pillItem("old", created: 0), pillItem("new", created: 100)])
        let since = p0.addingTimeInterval(50)
        XCTAssertEqual(store.newNeedsCount(in: .work, since: since, now: since), 1)
        XCTAssertEqual(store.newNeedsCount(in: .work, since: p0.addingTimeInterval(100), now: since), 0)
    }

    func testContentChangeCountsAsNew() {
        let store = ItemStore(items: [pillItem("a", created: 0, updated: 100, contentUpdated: 100)])
        XCTAssertEqual(store.newNeedsCount(in: .work, since: p0.addingTimeInterval(50), now: p0), 1)
    }

    func testInvisibleUpdateIsNotNew() {
        // Seen, re-posted unchanged, links changed: updated_at moves, content_updated_at doesn't.
        let store = ItemStore(items: [pillItem("a", created: 0, updated: 100, contentUpdated: 0)])
        XCTAssertEqual(store.newNeedsCount(in: .work, since: p0.addingTimeInterval(50), now: p0), 0)
    }

    func testTurnedIntoNeedsCountsAsNew() {
        var store = ItemStore()
        store.merge([pillItem("a", kind: .info, created: 0, contentUpdated: 0)], isFullSnapshot: true, now: p0)
        store.merge([pillItem("a", kind: .needs, created: 0, updated: 100, contentUpdated: 0)], isFullSnapshot: false, now: p0)
        XCTAssertEqual(store.promotedToNeeds["a"], p0.addingTimeInterval(100))
        XCTAssertEqual(store.newNeedsCount(in: .work, since: p0.addingTimeInterval(50), now: p0), 1)
        // Gone from the store: the note goes too.
        store.merge([], isFullSnapshot: true, now: p0)
        XCTAssertEqual(store.promotedToNeeds, [:])
    }

    func testOnlyCountedItemsInTheContext() {
        var store = ItemStore(items: [
            pillItem("w", created: 100), pillItem("p", context: .personal, created: 100),
            pillItem("d", kind: .done, created: 100), pillItem("later", created: 100),
        ])
        store.holdForLater(id: "later", at: p0)
        let since = p0.addingTimeInterval(50)
        XCTAssertEqual(store.newNeedsCount(in: .work, since: since, now: since), 1)
        XCTAssertEqual(store.newNeedsCount(in: .personal, since: since, now: since), 1)
    }

    func testDecodesContentUpdatedAt() {
        let json = """
        [{"id": "a", "key": "a", "title": "t", "created_at": "2026-10-06T17:00:00Z",
          "updated_at": "2026-10-06T17:10:00Z", "content_updated_at": "2026-10-06T17:04:05.123Z"},
         {"id": "b", "key": "b", "title": "t", "created_at": "2026-10-06T17:00:00Z", "content_updated_at": "junk"},
         {"id": "c", "key": "c", "title": "t", "created_at": "2026-10-06T17:00:00Z"}]
        """
        guard let items = try? HubJSON.makeDecoder().decode([Item].self, from: Data(json.utf8)) else {
            XCTFail("didn't decode")
            return
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertNotNil(items[0].contentUpdatedAt)
        XCTAssertTrue((items[0].contentUpdatedAt ?? .distantPast) > items[0].createdAt)
        XCTAssertNil(items[1].contentUpdatedAt)
        XCTAssertNil(items[2].contentUpdatedAt)
    }
}
