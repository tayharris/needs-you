#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import AppKit
import NeedsYouCore

/// Regression guard for the focus rule: the panel must never take key/main status or
/// activate the app (it stole focus from the user's typing before this was enforced).
final class FloatingPanelTests: XCTestCase {
    static var allTests = [
        ("testPanelNeverTakesFocus", testPanelNeverTakesFocus),
        ("testPanelJoinsAllSpacesAndFullScreen", testPanelJoinsAllSpacesAndFullScreen),
    ]

    func testPanelNeverTakesFocus() {
        _ = NSApplication.shared
        let panel = FloatingPanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        // Even an explicit request can't make it key.
        panel.makeKey()
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testPanelJoinsAllSpacesAndFullScreen() {
        _ = NSApplication.shared
        let panel = FloatingPanel()
        XCTAssertEqual(panel.level, .floating)
        for behaviour: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            XCTAssertTrue(panel.collectionBehavior.contains(behaviour))
        }
    }
}
