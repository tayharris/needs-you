#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// Card bodies, the links row, panel opacity and the list height limit. Every default
/// must be the original behaviour.
final class CardLayoutTests: XCTestCase {
    static var allTests = [
        ("testBodyModes", testBodyModes),
        ("testLongBodies", testLongBodies),
        ("testLinkRowPlans", testLinkRowPlans),
        ("testLinkLabels", testLinkLabels),
        ("testOpacity", testOpacity),
        ("testListHeight", testListHeight),
        ("testDefaultsAreTheOriginalBehaviour", testDefaultsAreTheOriginalBehaviour),
        ("testPrefsRoundTripAndValidation", testPrefsRoundTripAndValidation),
    ]

    private func links(_ n: Int) -> [ItemLink] {
        (1...max(1, n)).prefix(n).map { ItemLink(label: "Link number \($0) with a long label", url: "https://example.com/\($0)") }
    }

    func testBodyModes() {
        XCTAssertTrue(CardBodyPolicy.showsBody(.full, expanded: false))
        XCTAssertTrue(CardBodyPolicy.showsBody(.preview, expanded: false))
        XCTAssertFalse(CardBodyPolicy.showsBody(.hidden, expanded: false))
        XCTAssertTrue(CardBodyPolicy.showsBody(.hidden, expanded: true))

        XCTAssertNil(CardBodyPolicy.lineLimit(.full, expanded: false))
        XCTAssertEqual(CardBodyPolicy.lineLimit(.preview, expanded: false), CardBodyPolicy.previewLines)
        XCTAssertNil(CardBodyPolicy.lineLimit(.preview, expanded: true))

        XCTAssertFalse(CardBodyPolicy.canExpand(body: "x\ny\nz\nw\nv", mode: .full))
        XCTAssertTrue(CardBodyPolicy.canExpand(body: "short", mode: .hidden))
        XCTAssertFalse(CardBodyPolicy.canExpand(body: "  \n ", mode: .hidden))
        XCTAssertFalse(CardBodyPolicy.canExpand(body: nil, mode: .hidden))
        XCTAssertFalse(CardBodyPolicy.canExpand(body: "short", mode: .preview))
        XCTAssertTrue(CardBodyPolicy.canExpand(body: "1. a\n2. b\n3. c\n4. d", mode: .preview))

        XCTAssertEqual(CardBodyPolicy.toggleTitle(.preview, expanded: false), "Show more")
        XCTAssertEqual(CardBodyPolicy.toggleTitle(.hidden, expanded: false), "Show details")
        XCTAssertEqual(CardBodyPolicy.toggleTitle(.hidden, expanded: true), "Show less")
    }

    func testLongBodies() {
        XCTAssertFalse(CardBodyPolicy.isLong("one line"))
        XCTAssertFalse(CardBodyPolicy.isLong("a\nb\nc"))
        XCTAssertTrue(CardBodyPolicy.isLong("a\nb\nc\nd"))
        // One long paragraph wraps to several lines.
        XCTAssertTrue(CardBodyPolicy.isLong(String(repeating: "word ", count: 50)))
        XCTAssertFalse(CardBodyPolicy.isLong(String(repeating: "x", count: 100)))
    }

    func testLinkRowPlans() {
        // The original: up to six, no overflow marker, labels untouched.
        let full = LinkRowPolicy.plan(links(8), compact: false, expanded: false)
        XCTAssertEqual(full.shown.count, 6)
        XCTAssertEqual(full.overflow, 0)
        XCTAssertNil(full.maxLabelLength)

        let compact = LinkRowPolicy.plan(links(5), compact: true, expanded: false)
        XCTAssertEqual(compact.shown.count, 3)
        XCTAssertEqual(compact.overflow, 2)
        XCTAssertEqual(compact.maxLabelLength, LinkRowPolicy.compactLabelLength)

        // +N expands the card: everything shows, full labels.
        let opened = LinkRowPolicy.plan(links(5), compact: true, expanded: true)
        XCTAssertEqual(opened.shown.count, 5)
        XCTAssertEqual(opened.overflow, 0)

        XCTAssertEqual(LinkRowPolicy.plan(links(2), compact: true, expanded: false).overflow, 0)
        XCTAssertEqual(LinkRowPolicy.plan([], compact: true, expanded: false).shown, [])
    }

    func testLinkLabels() {
        let link = ItemLink(label: "Open the pull request", url: "https://example.com")
        XCTAssertEqual(LinkRowPolicy.label(link, maxLength: nil), "Open the pull request")
        let short = LinkRowPolicy.label(link, maxLength: 10)
        XCTAssertEqual(short, "Open the…")
        XCTAssertTrue(short.count <= 10)
        XCTAssertEqual(LinkRowPolicy.label(ItemLink(label: " ", url: "https://e.com"), maxLength: nil), "https://e.com")
    }

    func testOpacity() {
        XCTAssertEqual(PanelOpacity.alpha(base: 1, setting: 1, hovering: false), 1)
        XCTAssertEqual(PanelOpacity.alpha(base: 0.85, setting: 1, hovering: false), 0.85)
        XCTAssertEqual(PanelOpacity.alpha(base: 1, setting: 0.7, hovering: false), 0.7)
        // Hovering always shows full strength.
        XCTAssertEqual(PanelOpacity.alpha(base: 1, setting: 0.6, hovering: true), 1)
        // Never below the minimum, whatever is stored.
        XCTAssertEqual(PanelOpacity.alpha(base: 1, setting: 0.1, hovering: false), PanelOpacity.minimum)
        XCTAssertEqual(PanelOpacity.alpha(base: 1, setting: .nan, hovering: false), 1)
        XCTAssertEqual(PanelOpacity.nearestChoice(0.84), 0.8)
        XCTAssertEqual(PanelOpacity.nearestChoice(5), 1)
        XCTAssertEqual(PanelOpacity.nearestChoice(0), 0.6)
        XCTAssertEqual(PanelOpacity.nearestChoice(.infinity), 1)
    }

    func testListHeight() {
        let bottoms: [CGFloat] = [300, 100, 200, 400]   // any order
        // No limit: the content, capped (the original).
        XCTAssertEqual(ListHeightPolicy.height(content: 410, cardBottoms: bottoms, maxCards: 0, cap: 520, minimum: 64), 410)
        XCTAssertEqual(ListHeightPolicy.height(content: 900, cardBottoms: bottoms, maxCards: 0, cap: 520, minimum: 64), 520)
        XCTAssertEqual(ListHeightPolicy.height(content: 10, cardBottoms: [], maxCards: 0, cap: 520, minimum: 64), 64)
        // Two cards, then a peek of the third.
        XCTAssertEqual(ListHeightPolicy.height(content: 410, cardBottoms: bottoms, maxCards: 2, cap: 520, minimum: 64), 200 + ListHeightPolicy.peek)
        // Fewer cards than the limit: no cut.
        XCTAssertEqual(ListHeightPolicy.height(content: 410, cardBottoms: bottoms, maxCards: 5, cap: 520, minimum: 64), 410)
        // The screen cap still wins.
        XCTAssertEqual(ListHeightPolicy.height(content: 900, cardBottoms: [500, 800, 900], maxCards: 2, cap: 520, minimum: 64), 520)
        XCTAssertEqual(ListHeightPolicy.title(0), "As many as fit")
        XCTAssertEqual(ListHeightPolicy.title(3), "3")
    }

    func testDefaultsAreTheOriginalBehaviour() {
        let p = UIPrefs.defaults
        XCTAssertEqual(p.panelOpacity, 1)
        XCTAssertEqual(p.maxVisibleCards, 0)
        XCTAssertEqual(p.cardBodies, .full)
        XCTAssertFalse(p.compactLinks)
        XCTAssertEqual(CardBodyMode.allCases.map(\.rawValue), ["full", "preview", "hidden"])
    }

    func testPrefsRoundTripAndValidation() {
        let suite = "needsyou-cardlayout-test-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer {
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
        }
        var p = UIPrefs()
        p.panelOpacity = 0.7
        p.maxVisibleCards = 3
        p.cardBodies = .preview
        p.compactLinks = true
        p.save(to: store)
        XCTAssertEqual(UIPrefs.load(from: store), p)

        // Hand-edited values: opacity snaps to a choice, an unknown card count is ignored.
        store.set(0.83, forKey: UIPrefs.Key.panelOpacity)
        store.set(7, forKey: UIPrefs.Key.maxVisibleCards)
        store.set("tiny", forKey: UIPrefs.Key.cardBodies)
        let loaded = UIPrefs.load(from: store)
        XCTAssertEqual(loaded.panelOpacity, 0.8)
        XCTAssertEqual(loaded.maxVisibleCards, 0)
        XCTAssertEqual(loaded.cardBodies, .full)
        XCTAssertTrue(loaded.compactLinks)
    }
}
