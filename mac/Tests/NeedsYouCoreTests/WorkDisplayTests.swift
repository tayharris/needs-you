#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// Two displays in AppKit coordinates: the primary (with the menu bar) and one to its right,
/// taller and lower.
private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let side = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
private let screens = [primary, side]
private let me: Int32 = 99

/// A window-list rect (top-left origin, y down) for an AppKit rect.
private func cg(_ appKit: CGRect) -> CGRect {
    CGRect(x: appKit.minX, y: primary.height - appKit.maxY, width: appKit.width, height: appKit.height)
}

private func pick(_ windows: [WindowRecord], front: Int32?, mouse: CGPoint? = nil) -> Int? {
    WorkDisplay.screenIndex(screens: screens, primaryScreenHeight: primary.height, windows: windows,
                            frontmostPID: front, ownPID: me, mouse: mouse)
}

final class WorkDisplayTests: XCTestCase {
    static var allTests = [
        ("testCoordinateFlip", testCoordinateFlip),
        ("testFrontmostWindowWins", testFrontmostWindowWins),
        ("testSmallAndOverlayWindowsDontCount", testSmallAndOverlayWindowsDontCount),
        ("testWindowAcrossDisplaysGoesToTheLargerPart", testWindowAcrossDisplaysGoesToTheLargerPart),
        ("testFallsBackToThePointer", testFallsBackToThePointer),
        ("testNothingToGoOn", testNothingToGoOn),
        ("testSettingsDefaults", testSettingsDefaults),
    ]

    func testCoordinateFlip() {
        let appKit = CGRect(x: 1500, y: 100, width: 800, height: 600)
        XCTAssertEqual(cg(appKit), CGRect(x: 1500, y: 200, width: 800, height: 600))
        XCTAssertEqual(WorkDisplay.appKitRect(cg(appKit), primaryScreenHeight: primary.height), appKit)
        // A display below the primary has positive window-list y beyond its height.
        let below = CGRect(x: 0, y: -1000, width: 1000, height: 800)
        XCTAssertEqual(WorkDisplay.appKitRect(cg(below), primaryScreenHeight: primary.height), below)
    }

    func testFrontmostWindowWins() {
        let editor = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 1600, y: 0, width: 1200, height: 800)))
        let other = WindowRecord(pid: 20, layer: 0, bounds: cg(CGRect(x: 100, y: 100, width: 800, height: 600)))
        // The front app's first (frontmost) window decides, even with the pointer elsewhere.
        XCTAssertEqual(pick([other, editor], front: 10, mouse: CGPoint(x: 10, y: 10)), 1)
        XCTAssertEqual(pick([other, editor], front: 20, mouse: CGPoint(x: 2000, y: 10)), 0)
        // Our own windows (the panel) never count: the pointer decides.
        let panel = WindowRecord(pid: me, layer: 0, bounds: cg(CGRect(x: 1600, y: 0, width: 400, height: 400)))
        XCTAssertEqual(pick([panel], front: me, mouse: CGPoint(x: 10, y: 10)), 0)
    }

    func testSmallAndOverlayWindowsDontCount() {
        let palette = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 1600, y: 0, width: 80, height: 300)))
        let menu = WindowRecord(pid: 10, layer: 101, bounds: cg(CGRect(x: 1600, y: 0, width: 400, height: 400)))
        let main = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 100, y: 100, width: 800, height: 600)))
        XCTAssertEqual(pick([palette, menu, main], front: 10), 0)
    }

    func testWindowAcrossDisplaysGoesToTheLargerPart() {
        let straddling = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 1200, y: 100, width: 1000, height: 600)))
        XCTAssertEqual(pick([straddling], front: 10), 1)
        let mostlyLeft = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 600, y: 100, width: 1000, height: 600)))
        XCTAssertEqual(pick([mostlyLeft], front: 10), 0)
    }

    func testFallsBackToThePointer() {
        XCTAssertEqual(pick([], front: 10, mouse: CGPoint(x: 2000, y: -100)), 1)
        XCTAssertEqual(pick([], front: nil, mouse: CGPoint(x: 1440, y: 900)), 0, "edges count; the first match wins")
        // A front window off every display: the pointer.
        let lost = WindowRecord(pid: 10, layer: 0, bounds: cg(CGRect(x: 9000, y: 9000, width: 500, height: 500)))
        XCTAssertEqual(pick([lost], front: 10, mouse: CGPoint(x: 3000, y: 0)), 1)
    }

    func testNothingToGoOn() {
        XCTAssertNil(pick([], front: nil))
        XCTAssertNil(pick([], front: 10, mouse: CGPoint(x: -5000, y: 0)))
        XCTAssertNil(WorkDisplay.screenIndex(screens: [], primaryScreenHeight: 0, windows: [], frontmostPID: 1, ownPID: me,
                                             mouse: .zero))
    }

    func testSettingsDefaults() {
        XCTAssertEqual(PreviewDisplay.standard, .pill)
        XCTAssertEqual(EdgeGlowMode.standard, .off, "the edge glow is opt-in")
        XCTAssertEqual(PreviewDisplay(rawValue: "pill"), .pill)
        XCTAssertNil(EdgeGlowMode(rawValue: "always"))
    }
}
