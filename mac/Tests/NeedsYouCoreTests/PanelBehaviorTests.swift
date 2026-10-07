#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// How long arrival peeks stay out (and hover holding them), and the dragged list height.
final class PanelBehaviorTests: XCTestCase {
    static var allTests = [
        ("testPeekDurationChoicesAndDefault", testPeekDurationChoicesAndDefault),
        ("testCountdownRunsOut", testCountdownRunsOut),
        ("testHoverHoldsAndResumesWithGrace", testHoverHoldsAndResumesWithGrace),
        ("testHoverKeepsRemainingTimeWhenLonger", testHoverKeepsRemainingTimeWhenLonger),
        ("testUntilDismissedWaitsForHover", testUntilDismissedWaitsForHover),
        ("testListResizeClamp", testListResizeClamp),
        ("testDraggingGrowsAwayFromTheAnchor", testDraggingGrowsAwayFromTheAnchor),
        ("testGripSitsAwayFromTheAnchoredCorner", testGripSitsAwayFromTheAnchoredCorner),
        ("testChosenHeightOverridesAutomatic", testChosenHeightOverridesAutomatic),
        ("testStoredHeightSanitized", testStoredHeightSanitized),
    ]

    func testPeekDurationChoicesAndDefault() {
        XCTAssertEqual(PeekDuration.standard, 14)
        XCTAssertTrue(PeekDuration.choices.contains(PeekDuration.standard))
        XCTAssertTrue(PeekDuration.choices.contains(PeekDuration.untilDismissed))
        XCTAssertEqual(PeekDuration.sanitized(20), 20)
        XCTAssertEqual(PeekDuration.sanitized(0), 0)
        XCTAssertEqual(PeekDuration.sanitized(4), 14)
        XCTAssertEqual(PeekDuration.sanitized(-3), 14)
        XCTAssertEqual(PeekDuration.title(10), "10 seconds")
        XCTAssertEqual(PeekDuration.title(0), "Until I click or point at it")
    }

    func testCountdownRunsOut() {
        var c = PeekCountdown(seconds: 5)
        XCTAssertEqual(c.remaining, 5)
        for _ in 0..<4 { XCTAssertFalse(c.advance(by: 1, hovering: false)) }
        XCTAssertTrue(c.advance(by: 1, hovering: false))
        // A stored value this build doesn't offer runs for the default.
        XCTAssertEqual(PeekCountdown(seconds: 7).remaining, 14)
    }

    func testHoverHoldsAndResumesWithGrace() {
        var c = PeekCountdown(seconds: 5)
        XCTAssertFalse(c.advance(by: 4.5, hovering: false))
        XCTAssertEqual(c.remaining, 0.5)
        // Pointing at it: nothing runs out, however long.
        for _ in 0..<100 { XCTAssertFalse(c.advance(by: 1, hovering: true)) }
        // Leaving resumes with at least the grace left.
        XCTAssertEqual(c.remaining, PeekDuration.hoverGrace)
        XCTAssertFalse(c.advance(by: 1, hovering: false))
        XCTAssertTrue(c.advance(by: 1, hovering: false))
    }

    func testHoverKeepsRemainingTimeWhenLonger() {
        var c = PeekCountdown(seconds: 30)
        XCTAssertFalse(c.advance(by: 1, hovering: true))
        XCTAssertEqual(c.remaining, 30)
        XCTAssertFalse(c.advance(by: 10, hovering: false))
        XCTAssertEqual(c.remaining, 20)
    }

    func testUntilDismissedWaitsForHover() {
        var c = PeekCountdown(seconds: PeekDuration.untilDismissed)
        XCTAssertNil(c.remaining)
        for _ in 0..<1000 { XCTAssertFalse(c.advance(by: 1, hovering: false)) }
        // Pointed at, then left: it goes after the grace.
        XCTAssertFalse(c.advance(by: 1, hovering: true))
        XCTAssertFalse(c.advance(by: 1.5, hovering: false))
        XCTAssertTrue(c.advance(by: 0.5, hovering: false))
    }

    func testListResizeClamp() {
        XCTAssertEqual(ListResize.clamp(300, minimum: 64, cap: 500), 300)
        XCTAssertEqual(ListResize.clamp(10, minimum: 64, cap: 500), 64)
        XCTAssertEqual(ListResize.clamp(900, minimum: 64, cap: 500), 500)
        // A tiny screen: the cap never goes below the minimum.
        XCTAssertEqual(ListResize.clamp(300, minimum: 64, cap: 20), 64)
        XCTAssertEqual(ListResize.clamp(.nan, minimum: 64, cap: 500), 64)
        XCTAssertEqual(ListResize.clamp(.infinity, minimum: 64, cap: 500), 64)
    }

    func testDraggingGrowsAwayFromTheAnchor() {
        // Hanging from a top corner, grip at the bottom: pulling down (y falls) makes it taller.
        XCTAssertEqual(ListResize.dragged(start: 300, deltaY: -100, gripAtBottom: true, minimum: 64, cap: 800), 400)
        XCTAssertEqual(ListResize.dragged(start: 300, deltaY: 100, gripAtBottom: true, minimum: 64, cap: 800), 200)
        // Sitting on a bottom corner, grip at the top: pulling up makes it taller.
        XCTAssertEqual(ListResize.dragged(start: 300, deltaY: 100, gripAtBottom: false, minimum: 64, cap: 800), 400)
        XCTAssertEqual(ListResize.dragged(start: 300, deltaY: -1000, gripAtBottom: false, minimum: 64, cap: 800), 64)
        XCTAssertEqual(ListResize.dragged(start: 300, deltaY: -1000, gripAtBottom: true, minimum: 64, cap: 800), 800)
    }

    func testGripSitsAwayFromTheAnchoredCorner() {
        XCTAssertTrue(ListResize.gripAtBottom(anchor: .topRight))
        XCTAssertTrue(ListResize.gripAtBottom(anchor: .topLeft))
        XCTAssertFalse(ListResize.gripAtBottom(anchor: .bottomLeft))
        XCTAssertFalse(ListResize.gripAtBottom(anchor: .bottomRight))
    }

    func testChosenHeightOverridesAutomatic() {
        XCTAssertEqual(ListResize.listHeight(chosen: 0, automaticHeight: { 123 }, minimum: 64, cap: 500), 123)
        XCTAssertEqual(ListResize.listHeight(chosen: 350, automaticHeight: { 123 }, minimum: 64, cap: 500), 350)
        // Clamped to this screen and panel size.
        XCTAssertEqual(ListResize.listHeight(chosen: 2000, automaticHeight: { 123 }, minimum: 64, cap: 500), 500)
        XCTAssertEqual(ListResize.listHeight(chosen: 5, automaticHeight: { 123 }, minimum: 64, cap: 500), 64)
    }

    func testStoredHeightSanitized() {
        XCTAssertEqual(ListResize.sanitized(420.4), 420)
        XCTAssertEqual(ListResize.sanitized(0), 0)
        XCTAssertEqual(ListResize.sanitized(-5), 0)
        XCTAssertEqual(ListResize.sanitized(.nan), 0)
        XCTAssertEqual(ListResize.sanitized(1e9), 0)
    }
}
