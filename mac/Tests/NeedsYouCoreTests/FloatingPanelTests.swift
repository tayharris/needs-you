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
        ("testEdgeGlowNeverTakesFocusAndIsClickThrough", testEdgeGlowNeverTakesFocusAndIsClickThrough),
        ("testAnswerWindowIsSeparateAndThePanelStillNeverTakesFocus",
         testAnswerWindowIsSeparateAndThePanelStillNeverTakesFocus),
    ]

    /// Typed answers ("Other…") go in their own window, opened by an explicit click: it may
    /// become key, but it is an ordinary titled window, not the panel, and the panel's rule
    /// doesn't change because the window exists.
    func testAnswerWindowIsSeparateAndThePanelStillNeverTakesFocus() {
        _ = NSApplication.shared
        let answer = AnswerWindow()
        XCTAssertTrue(answer.canBecomeKey)
        XCTAssertFalse((answer as NSWindow) is FloatingPanel)
        XCTAssertFalse(answer.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(answer.styleMask.contains(.titled))
        XCTAssertTrue(answer.styleMask.contains(.closable))
        XCTAssertFalse(answer.isReleasedWhenClosed)
        let panel = FloatingPanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.makeKey()
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testEdgeGlowNeverTakesFocusAndIsClickThrough() {
        _ = NSApplication.shared
        let glow = EdgeGlowWindow()
        XCTAssertFalse(glow.canBecomeKey)
        XCTAssertFalse(glow.canBecomeMain)
        XCTAssertTrue(glow.ignoresMouseEvents)
        XCTAssertTrue(glow.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(glow.hidesOnDeactivate)
        XCTAssertFalse(glow.isOpaque)
        XCTAssertEqual(glow.level, .statusBar)
        for behaviour: NSWindow.CollectionBehavior in [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle] {
            XCTAssertTrue(glow.collectionBehavior.contains(behaviour))
        }
        glow.makeKey()
        XCTAssertFalse(glow.isKeyWindow)
    }

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
