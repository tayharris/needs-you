#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// The menu bar icon's rules: visibility (never both hidden), arrivals while hidden, and
/// the text it shows.
final class MenuBarTests: XCTestCase {
    static var allTests = [
        ("testIconAndPanelCantBothBeHidden", testIconAndPanelCantBothBeHidden),
        ("testArrivalsWhileHidden", testArrivalsWhileHidden),
        ("testCountTitle", testCountTitle),
        ("testStatusLine", testStatusLine),
        ("testItemTitlesAndTopItems", testItemTitlesAndTopItems),
        ("testMenuItemAction", testMenuItemAction),
        ("testPanelMenuCheckmark", testPanelMenuCheckmark),
    ]

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ priority: ItemPriority, title: String = "Title", links: [ItemLink] = []) -> Item {
        Item(id: id, key: id, priority: priority, title: title, links: links, createdAt: now)
    }

    func testIconAndPanelCantBothBeHidden() {
        XCTAssertTrue(VisibilityRules.canHidePanel(showMenuBarIcon: true))
        XCTAssertFalse(VisibilityRules.canHidePanel(showMenuBarIcon: false))
        XCTAssertTrue(VisibilityRules.canHideMenuBarIcon(panelHidden: false))
        XCTAssertFalse(VisibilityRules.canHideMenuBarIcon(panelHidden: true))

        // Stored prefs that hide both are repaired by keeping the icon.
        XCTAssertTrue(VisibilityRules.normalized(showMenuBarIcon: false, panelHidden: true) == (true, true))
        XCTAssertTrue(VisibilityRules.normalized(showMenuBarIcon: false, panelHidden: false) == (false, false))
        XCTAssertTrue(VisibilityRules.normalized(showMenuBarIcon: true, panelHidden: true) == (true, true))
        XCTAssertTrue(VisibilityRules.normalized(showMenuBarIcon: true, panelHidden: false) == (true, false))
    }

    func testArrivalsWhileHidden() {
        let urgent = item("u", .urgent), normal = item("n", .normal)
        let snoozed = PanelVisibility.snoozed(until: now.addingTimeInterval(600))
        func decide(_ v: PanelVisibility, _ items: [Item], breaks: Bool = true, shows: Bool = false) -> HiddenArrival {
            HiddenArrivalPolicy.decide(visibility: v, announced: items, urgentBreaksSnooze: breaks,
                                       urgentShowsHiddenPanel: shows, now: now)
        }
        // Shown: not this policy's business.
        XCTAssertEqual(decide(.shown, [urgent]), .none)
        // Hidden: urgent pulses the icon once; the panel stays hidden unless the setting is on.
        XCTAssertEqual(decide(.hidden, [urgent]), .pulseMenuBar)
        XCTAssertEqual(decide(.hidden, [urgent], shows: true), .showPanel)
        XCTAssertEqual(decide(.hidden, [normal]), .none)
        XCTAssertEqual(decide(.hidden, [normal], shows: true), .none)
        // Snoozed: the existing "urgent breaks through a snooze" setting.
        XCTAssertEqual(decide(snoozed, [normal, urgent]), .showPanel)
        XCTAssertEqual(decide(snoozed, [urgent], breaks: false), .pulseMenuBar)
        XCTAssertEqual(decide(snoozed, [normal]), .none)
        // An expired snooze hides nothing.
        XCTAssertEqual(decide(.snoozed(until: now), [urgent]), .none)
        // Closed or non-needs urgent items don't count.
        var done = urgent; done.status = .resolved
        var info = urgent; info.kind = .info
        XCTAssertEqual(decide(.hidden, [done, info]), .none)
    }

    func testCountTitle() {
        XCTAssertNil(MenuBarFormat.countTitle(count: 0, showCount: true))
        XCTAssertEqual(MenuBarFormat.countTitle(count: 3, showCount: true), "3")
        XCTAssertNil(MenuBarFormat.countTitle(count: 3, showCount: false))
        XCTAssertEqual(MenuBarFormat.countTitle(count: 150, showCount: true), "99+")
    }

    func testStatusLine() {
        XCTAssertEqual(MenuBarFormat.statusLine(count: 0, hub: "this Mac", configured: true), "All clear · This Mac")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 3, hub: "hub2", configured: true), "3 need you · Hub2")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 1, userName: " Sam ", hub: "this Mac", configured: true), "1 needs Sam · This Mac")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 2, hub: nil, configured: true, demo: true), "2 need you · Demo")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 0, hub: nil, configured: true), "All clear · Hub")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 2, hub: "hub2", configured: true, error: "Hub unreachable"), "Hub unreachable · 2 waiting")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 0, hub: "hub2", configured: true, error: "Hub unreachable"), "Hub unreachable")
        XCTAssertEqual(MenuBarFormat.statusLine(count: 0, hub: nil, configured: false), "Not set up · open Settings")
        XCTAssertEqual(MenuBarFormat.hubLabel(""), "")
    }

    func testItemTitlesAndTopItems() {
        XCTAssertEqual(MenuBarFormat.itemTitle(item("a", .low, title: "Short")), "Short")
        XCTAssertEqual(MenuBarFormat.itemTitle(item("a", .low, title: "line one\nline two")), "line one line two")
        let long = MenuBarFormat.itemTitle(item("a", .low, title: String(repeating: "x", count: 100)), maxLength: 20)
        XCTAssertEqual(long.count, 20)
        XCTAssertTrue(long.hasSuffix("…"))

        let items = (0..<8).map { item("i\($0)", .normal) }
        XCTAssertEqual(MenuBarFormat.topItems(items).map(\.id), ["i0", "i1", "i2", "i3", "i4"])
        XCTAssertEqual(MenuBarFormat.topItems(Array(items.prefix(2))).count, 2)
        XCTAssertEqual(MenuBarFormat.topItems(items, limit: 0).count, 0)
    }

    func testMenuItemAction() {
        let blocked = ItemLink(label: "x", url: "javascript:alert(1)")
        let file = ItemLink(label: "f", url: "file:///etc/passwd")
        let web = ItemLink(label: "pr", url: "https://github.com/o/r/pull/1")
        let slack = ItemLink(label: "s", url: "slack://channel?id=1")
        XCTAssertEqual(MenuItemAction.forItem(item("a", .urgent, links: [blocked, file, web, slack])), .open(URL(string: "https://github.com/o/r/pull/1")!))
        XCTAssertEqual(MenuItemAction.forItem(item("b", .urgent, links: [slack, web])), .open(URL(string: "slack://channel?id=1")!))
        XCTAssertEqual(MenuItemAction.forItem(item("c", .urgent, links: [blocked])), .showPanel)
        XCTAssertEqual(MenuItemAction.forItem(item("d", .urgent)), .showPanel)
    }

    func testPanelMenuCheckmark() {
        XCTAssertTrue(MenuBarFormat.panelMenuChecked(visibility: .shown, now: now))
        XCTAssertFalse(MenuBarFormat.panelMenuChecked(visibility: .hidden, now: now))
        XCTAssertFalse(MenuBarFormat.panelMenuChecked(visibility: .snoozed(until: now.addingTimeInterval(60)), now: now))
        XCTAssertTrue(MenuBarFormat.panelMenuChecked(visibility: .snoozed(until: now.addingTimeInterval(-1)), now: now))
    }
}

/// Free positioning: the pill goes anywhere, stays on screen, and grows away from the
/// nearest edges; snapping to corners is optional.
final class PanelPositionTests: XCTestCase {
    static var allTests = [
        ("testClampToVisibleFrame", testClampToVisibleFrame),
        ("testSnapOnAndOff", testSnapOnAndOff),
        ("testGrowsAwayFromNearestEdges", testGrowsAwayFromNearestEdges),
        ("testDropRoundTripsExactly", testDropRoundTripsExactly),
        ("testPlacementDecodingIsBackwardCompatible", testPlacementDecodingIsBackwardCompatible),
        ("testResetRemovesLayout", testResetRemovesLayout),
    ]

    // A screen whose visible frame doesn't start at 0,0 (menu bar above, Dock on the left).
    private let bounds = CGRect(x: 70, y: 0, width: 1370, height: 875)
    private let pill = CGSize(width: 60, height: 38)
    private let big = CGSize(width: 376, height: 500)

    func testClampToVisibleFrame() {
        // Off every edge: pulled back in, size unchanged.
        XCTAssertEqual(PanelGeometry.clamp(CGRect(x: -500, y: -40, width: 60, height: 38), to: bounds), CGRect(x: 70, y: 0, width: 60, height: 38))
        XCTAssertEqual(PanelGeometry.clamp(CGRect(x: 5000, y: 5000, width: 60, height: 38), to: bounds), CGRect(x: 1380, y: 837, width: 60, height: 38))
        // Inside: unchanged.
        let inside = CGRect(x: 400, y: 300, width: 60, height: 38)
        XCTAssertEqual(PanelGeometry.clamp(inside, to: bounds), inside)
        // Larger than the screen: the preferred side stays visible.
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        XCTAssertEqual(PanelGeometry.clamp(huge, to: bounds, prefer: .topLeft).minX, 70)
        XCTAssertEqual(PanelGeometry.clamp(huge, to: bounds, prefer: .topLeft).maxY, 875)
        XCTAssertEqual(PanelGeometry.clamp(huge, to: bounds, prefer: .bottomRight).maxX, 1440)
        XCTAssertEqual(PanelGeometry.clamp(huge, to: bounds, prefer: .bottomRight).minY, 0)
        // A free placement far outside the screen (another layout's numbers) still lands on it.
        let lost = PanelPlacement(corner: .bottomLeft, screenID: "s", offset: CGSize(width: 9000, height: 9000))
        XCTAssertTrue(bounds.contains(PanelGeometry.frame(size: pill, placement: lost, in: bounds)))
    }

    func testSnapOnAndOff() {
        let dropped = CGRect(x: 900, y: 700, width: 60, height: 38)   // upper half, right half
        let snapped = PanelGeometry.placement(forDropped: dropped, in: bounds, screenID: "s", snap: true)
        XCTAssertEqual(snapped.corner, .topRight)
        XCTAssertNil(snapped.offset)
        XCTAssertEqual(PanelGeometry.frame(size: pill, placement: snapped, in: bounds, margin: 12),
                       CGRect(x: 1440 - 12 - 60, y: 875 - 12 - 38, width: 60, height: 38))

        let free = PanelGeometry.placement(forDropped: dropped, in: bounds, screenID: "s", snap: false)
        XCTAssertEqual(free.corner, .topRight)
        XCTAssertEqual(free.offset, CGSize(width: 1440 - 960, height: 875 - 738))
        XCTAssertEqual(PanelGeometry.frame(size: pill, placement: free, in: bounds, margin: 12), dropped)

        // Dropped partly off screen with snapping off: kept, but clamped.
        let off = CGRect(x: -30, y: -10, width: 60, height: 38)
        let clamped = PanelGeometry.placement(forDropped: off, in: bounds, screenID: "s", snap: false)
        XCTAssertEqual(clamped.corner, .bottomLeft)
        XCTAssertEqual(clamped.offset, CGSize(width: 0, height: 0))
        XCTAssertEqual(PanelGeometry.frame(size: pill, placement: clamped, in: bounds), CGRect(x: 70, y: 0, width: 60, height: 38))
    }

    /// Near each corner and edge, the expanded panel keeps the pill's corner fixed and grows
    /// towards the middle of the screen.
    func testGrowsAwayFromNearestEdges() {
        let cases: [(CGPoint, Corner)] = [
            (CGPoint(x: 80, y: 820), .topLeft),        // top-left corner
            (CGPoint(x: 1360, y: 820), .topRight),     // top-right corner
            (CGPoint(x: 80, y: 10), .bottomLeft),      // bottom-left corner
            (CGPoint(x: 1360, y: 10), .bottomRight),   // bottom-right corner
            (CGPoint(x: 700, y: 830), .topLeft),       // top edge, left of centre
            (CGPoint(x: 1370, y: 300), .bottomRight),  // right edge, below centre
            (CGPoint(x: 75, y: 500), .topLeft),        // left edge, above centre
            (CGPoint(x: 900, y: 5), .bottomRight),     // bottom edge, right of centre
        ]
        for (origin, corner) in cases {
            let dropped = CGRect(origin: origin, size: pill)
            let p = PanelGeometry.placement(forDropped: dropped, in: bounds, screenID: "s", snap: false)
            XCTAssertEqual(p.corner, corner, "\(origin)")
            let small = PanelGeometry.frame(size: pill, placement: p, in: bounds)
            let grown = PanelGeometry.frame(size: big, placement: p, in: bounds)
            XCTAssertEqual(small, dropped, "\(origin)")
            XCTAssertTrue(bounds.contains(grown), "\(origin) grew off screen: \(grown)")
            // The anchor corner (nearest the screen corner) doesn't move.
            if corner.isLeft { XCTAssertEqual(grown.minX, small.minX, "\(origin)") } else { XCTAssertEqual(grown.maxX, small.maxX, "\(origin)") }
            if corner.isTop { XCTAssertEqual(grown.maxY, small.maxY, "\(origin)") } else { XCTAssertEqual(grown.minY, small.minY, "\(origin)") }
        }
        // In the middle of a small screen the grown panel can't keep its anchor; it's
        // clamped instead of running off the edge.
        let tiny = CGRect(x: 0, y: 0, width: 500, height: 400)
        let p = PanelGeometry.placement(forDropped: CGRect(x: 200, y: 150, width: 60, height: 38), in: tiny, screenID: "s", snap: false)
        XCTAssertTrue(tiny.contains(PanelGeometry.frame(size: CGSize(width: 376, height: 300), placement: p, in: tiny)))
    }

    func testDropRoundTripsExactly() {
        // Wherever it's dropped (on screen), re-deriving the frame puts it back exactly.
        for x in stride(from: 70.0, to: 1380.0, by: 173.0) {
            for y in stride(from: 0.0, to: 837.0, by: 131.0) {
                let f = CGRect(x: x, y: y, width: 60, height: 38)
                let p = PanelGeometry.placement(forDropped: f, in: bounds, screenID: "s", snap: false)
                XCTAssertEqual(PanelGeometry.frame(size: pill, placement: p, in: bounds), f)
            }
        }
    }

    func testPlacementDecodingIsBackwardCompatible() throws {
        // Written by an older build (no offset): decodes as snapped.
        let old = Data(#"{"corner":"bottomLeft","screenID":"s1"}"#.utf8)
        let decoded = try JSONDecoder().decode(PanelPlacement.self, from: old)
        XCTAssertEqual(decoded, PanelPlacement(corner: .bottomLeft, screenID: "s1"))
        // Round trip with an offset.
        let free = PanelPlacement(corner: .topRight, screenID: "s2", offset: CGSize(width: 40, height: 120))
        XCTAssertEqual(try JSONDecoder().decode(PanelPlacement.self, from: JSONEncoder().encode(free)), free)
    }

    func testResetRemovesLayout() {
        var book = PlacementBook()
        book.set(PanelPlacement(corner: .bottomLeft, screenID: "s", offset: CGSize(width: 5, height: 5)), forLayout: "L")
        XCTAssertTrue(book.remove(forLayout: "L"))
        XCTAssertNil(book.placement(forLayout: "L"))
        XCTAssertFalse(book.remove(forLayout: "L"))
    }
}
