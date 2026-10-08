#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// What the app shows at launch: the panel opened once when the person starts it, only the
/// pill at login or after an update, and a saved placement that would put the pill off
/// every screen falling back to the default corner.
final class LaunchBehaviorTests: XCTestCase {
    static var allTests = [
        ("testPersonLaunchOpens", testPersonLaunchOpens),
        ("testLoginItemEventIsALoginLaunch", testLoginItemEventIsALoginLaunch),
        ("testEarlyInTheSessionIsALoginLaunch", testEarlyInTheSessionIsALoginLaunch),
        ("testUpdateRelaunchShowsOnlyThePill", testUpdateRelaunchShowsOnlyThePill),
        ("testOldUpdateAttemptIsThePersonsLaunch", testOldUpdateAttemptIsThePersonsLaunch),
        ("testSettingHiddenAndTourKeepItClosed", testSettingHiddenAndTourKeepItClosed),
        ("testOwnersThreeDisplayPlacementIsKept", testOwnersThreeDisplayPlacementIsKept),
        ("testDisconnectedDisplayFallsBack", testDisconnectedDisplayFallsBack),
        ("testOffsetPastTheEdgeFallsBack", testOffsetPastTheEdgeFallsBack),
        ("testBadOffsetFallsBack", testBadOffsetFallsBack),
        ("testSnappedPlacementOnEveryCornerIsKept", testSnappedPlacementOnEveryCornerIsKept),
        ("testNoSavedPlacementIsTheDefault", testNoSavedPlacementIsTheDefault),
        ("testFrameStillClampsAfterRefactor", testFrameStillClampsAfterRefactor),
    ]

    func testPersonLaunchOpens() {
        let kind = LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: 3600, updateAttemptAge: nil)
        XCTAssertEqual(kind, .byPerson)
        XCTAssertTrue(LaunchOpen.shouldOpen(kind: kind, settingOn: true, panelHidden: false))
        // Unknown session age: the person's launch.
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: nil, updateAttemptAge: nil), .byPerson)
    }

    func testLoginItemEventIsALoginLaunch() {
        let kind = LaunchOpen.kind(appleEventSaysLogin: true, secondsSinceLogin: 9999, updateAttemptAge: nil)
        XCTAssertEqual(kind, .atLogin)
        XCTAssertFalse(LaunchOpen.shouldOpen(kind: kind, settingOn: true, panelHidden: false))
    }

    func testEarlyInTheSessionIsALoginLaunch() {
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: 20, updateAttemptAge: nil), .atLogin)
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: LaunchOpen.loginWindow - 1,
                                       updateAttemptAge: nil), .atLogin)
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: LaunchOpen.loginWindow,
                                       updateAttemptAge: nil), .byPerson)
        // A clock that went backwards isn't a login.
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: -5, updateAttemptAge: nil), .byPerson)
    }

    func testUpdateRelaunchShowsOnlyThePill() {
        let kind = LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: 3600, updateAttemptAge: 6)
        XCTAssertEqual(kind, .afterUpdate)
        XCTAssertFalse(LaunchOpen.shouldOpen(kind: kind, settingOn: true, panelHidden: false))
    }

    func testOldUpdateAttemptIsThePersonsLaunch() {
        // Installed at quit (--no-launch) last night; the person starts it this morning.
        XCTAssertEqual(LaunchOpen.kind(appleEventSaysLogin: false, secondsSinceLogin: 3600, updateAttemptAge: 36_000), .byPerson)
    }

    func testSettingHiddenAndTourKeepItClosed() {
        XCTAssertFalse(LaunchOpen.shouldOpen(kind: .byPerson, settingOn: false, panelHidden: false))
        XCTAssertFalse(LaunchOpen.shouldOpen(kind: .byPerson, settingOn: true, panelHidden: true))
        XCTAssertFalse(LaunchOpen.shouldOpen(kind: .byPerson, settingOn: true, panelHidden: false, snapshotTour: true))
    }

    // MARK: Placement at launch

    /// Bounds as PanelController builds them: the visible frame widened by the glow padding (8).
    private func bounds(_ visible: CGRect) -> CGRect { visible.insetBy(dx: -8, dy: -8) }

    /// The owner's layout: a 2560×1440 main display, a 1080×1920 portrait one to its left
    /// and another 2560×1440 to its right; the pill dragged to the right display's top left.
    private var ownerScreens: [(id: String, bounds: CGRect)] {
        let frames = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                      CGRect(x: -1080, y: -367, width: 1080, height: 1920),
                      CGRect(x: 2560, y: 0, width: 2560, height: 1440)]
        let visible = [CGRect(x: 0, y: 0, width: 2560, height: 1415),
                       CGRect(x: -1080, y: -367, width: 1080, height: 1895),
                       CGRect(x: 2560, y: 0, width: 2560, height: 1416)]
        return zip(frames, visible).map { (PanelGeometry.screenID($0), bounds($1)) }
    }

    private let pill = CGSize(width: 85, height: 46)

    func testOwnersThreeDisplayPlacementIsKept() {
        let saved = PanelPlacement(corner: .topLeft, screenID: "2560,0,2560x1440", offset: CGSize(width: 26, height: 81))
        let result = PanelGeometry.launchPlacement(saved, size: pill, screens: ownerScreens)
        XCTAssertEqual(result.placement, saved)
        XCTAssertNil(result.problem)
    }

    func testDisconnectedDisplayFallsBack() {
        let saved = PanelPlacement(corner: .topLeft, screenID: "5120,0,2560x1440", offset: CGSize(width: 26, height: 81))
        let result = PanelGeometry.launchPlacement(saved, size: pill, screens: ownerScreens)
        XCTAssertNil(result.placement)
        XCTAssertEqual(result.problem, .screenGone("5120,0,2560x1440"))
    }

    func testOffsetPastTheEdgeFallsBack() {
        // An offset from a bigger display's coordinates: off the right display's bottom.
        let saved = PanelPlacement(corner: .topLeft, screenID: "2560,0,2560x1440", offset: CGSize(width: 26, height: 1500))
        let result = PanelGeometry.launchPlacement(saved, size: pill, screens: ownerScreens)
        XCTAssertNil(result.placement)
        XCTAssertEqual(result.problem, .offScreen)
        let wide = PanelPlacement(corner: .topRight, screenID: "0,0,2560x1440", offset: CGSize(width: 2540, height: 10))
        XCTAssertEqual(PanelGeometry.problem(with: wide, size: pill, screens: ownerScreens), .offScreen)
    }

    func testBadOffsetFallsBack() {
        for offset in [CGSize(width: -40, height: 10), CGSize(width: CGFloat.nan, height: 10),
                       CGSize(width: 10, height: CGFloat.infinity), CGSize(width: 1e9, height: 10)] {
            let saved = PanelPlacement(corner: .bottomLeft, screenID: "0,0,2560x1440", offset: offset)
            XCTAssertEqual(PanelGeometry.problem(with: saved, size: pill, screens: ownerScreens), .badOffset)
        }
    }

    func testSnappedPlacementOnEveryCornerIsKept() {
        for screen in ownerScreens {
            for corner in Corner.allCases {
                let saved = PanelPlacement(corner: corner, screenID: screen.id)
                XCTAssertNil(PanelGeometry.problem(with: saved, size: pill, screens: ownerScreens, margin: 12))
            }
        }
    }

    func testNoSavedPlacementIsTheDefault() {
        let result = PanelGeometry.launchPlacement(nil, size: pill, screens: ownerScreens)
        XCTAssertNil(result.placement)
        XCTAssertNil(result.problem)
    }

    func testFrameStillClampsAfterRefactor() {
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let p = PanelPlacement(corner: .topLeft, screenID: "x", offset: CGSize(width: 990, height: 20))
        let f = PanelGeometry.frame(size: CGSize(width: 100, height: 40), placement: p, in: b)
        XCTAssertEqual(f, CGRect(x: 900, y: 740, width: 100, height: 40))
        XCTAssertEqual(PanelGeometry.unclampedFrame(size: CGSize(width: 100, height: 40), placement: p, in: b),
                       CGRect(x: 990, y: 740, width: 100, height: 40))
    }
}
