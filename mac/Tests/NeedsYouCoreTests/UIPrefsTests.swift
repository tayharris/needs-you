#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// The look-and-feel prefs: defaults are the original look, bad values fall back, and
/// loading never writes. Each test uses its own throwaway suite.
final class UIPrefsTests: XCTestCase {
    static var allTests = [
        ("testFreshPrefsAreTheOriginalLook", testFreshPrefsAreTheOriginalLook),
        ("testRoundTrip", testRoundTrip),
        ("testUnknownValuesFallBack", testUnknownValuesFallBack),
        ("testSaveOnlyWritesChanges", testSaveOnlyWritesChanges),
        ("testPanelBehaviourDefaults", testPanelBehaviourDefaults),
        ("testPanelBehaviourRoundTripAndFallback", testPanelBehaviourRoundTripAndFallback),
    ]

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = "needsyou-uiprefs-test-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
    }

    private var storedKeys: Set<String> {
        Set((store.persistentDomain(forName: suite) ?? [:]).keys)
    }

    func testFreshPrefsAreTheOriginalLook() {
        let p = UIPrefs.load(from: store)
        XCTAssertEqual(p, UIPrefs.defaults)
        XCTAssertEqual(p.panelSize, .regular)
        XCTAssertEqual(p.textSize, .standard)
        XCTAssertEqual(p.metrics, PanelStyle.regular)
        XCTAssertEqual(p.bodyFont, 12)
        // Loading wrote nothing.
        XCTAssertEqual(storedKeys, [])
    }

    func testRoundTrip() {
        var p = UIPrefs()
        p.panelSize = .large
        p.textSize = .extraLarge
        p.alertUrgent = .bright
        p.alertOther = .off
        p.save(to: store)
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.alertUrgent), "bright")
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.alertOther), "off")
        XCTAssertEqual(UIPrefs.load(from: store), p)
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.panelSize), "large")
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.textSize), "extraLarge")
    }

    func testUnknownValuesFallBack() {
        store.set("gigantic", forKey: UIPrefs.Key.panelSize)
        store.set(42, forKey: UIPrefs.Key.textSize)
        XCTAssertEqual(UIPrefs.load(from: store), UIPrefs.defaults)
        // And they're left alone (a newer build may know them).
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.panelSize), "gigantic")
    }

    func testSaveOnlyWritesChanges() {
        let old = UIPrefs()
        var new = old
        new.textSize = .large
        new.save(to: store, previous: old)
        XCTAssertEqual(storedKeys, [UIPrefs.Key.textSize])
    }

    /// Arrival peeks stay out 14 s, the open panel stays open on clicks elsewhere, and the
    /// list height is automatic. None of it is written until changed.
    func testPanelBehaviourDefaults() {
        let p = UIPrefs.load(from: store)
        XCTAssertEqual(p.previewSeconds, 14)
        XCTAssertFalse(p.collapseOnClickOutside)
        XCTAssertEqual(p.expandedListHeight, 0)
        XCTAssertEqual(storedKeys, [])
    }

    func testPanelBehaviourRoundTripAndFallback() {
        var p = UIPrefs()
        p.previewSeconds = PeekDuration.untilDismissed
        p.collapseOnClickOutside = true
        p.expandedListHeight = 380
        p.save(to: store, previous: UIPrefs())
        XCTAssertEqual(storedKeys, [UIPrefs.Key.previewSeconds, UIPrefs.Key.collapseOnClickOutside, UIPrefs.Key.expandedListHeight])
        XCTAssertEqual(UIPrefs.load(from: store), p)

        store.set(4, forKey: UIPrefs.Key.previewSeconds)          // not offered: the default
        store.set(-20.0, forKey: UIPrefs.Key.expandedListHeight)  // bad: automatic
        let loaded = UIPrefs.load(from: store)
        XCTAssertEqual(loaded.previewSeconds, PeekDuration.standard)
        XCTAssertEqual(loaded.expandedListHeight, 0)
        XCTAssertTrue(loaded.collapseOnClickOutside)
    }
}
