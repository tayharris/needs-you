#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// Alert intensity curves: normal is the original look, the levels get louder in order,
/// and urgent items keep a floor so they can't be made invisible.
final class AlertStyleTests: XCTestCase {
    static var allTests = [
        ("testNormalIsTheOriginalLook", testNormalIsTheOriginalLook),
        ("testLevelsGetLouderInOrder", testLevelsGetLouderInOrder),
        ("testUrgentFloor", testUrgentFloor),
        ("testOffSilencesOtherItems", testOffSilencesOtherItems),
        ("testGlowFitsThePadding", testGlowFitsThePadding),
        ("testReducedMotionAndPrefs", testReducedMotionAndPrefs),
    ]

    func testNormalIsTheOriginalLook() {
        // Urgent arrivals pulsed twice, others once; peak 1, radius 7, ring 0.9 at 1.25 pt.
        let urgent = AlertStyle.look(.normal, priority: .urgent, basePulses: 2)
        XCTAssertEqual(urgent.pulses, 2)
        let normal = AlertStyle.look(.normal, priority: .normal, basePulses: 1)
        XCTAssertEqual(normal.pulses, 1)
        XCTAssertEqual(normal.glowPeak, 1)
        XCTAssertEqual(normal.glowRadius, 7)
        XCTAssertEqual(normal.strokeWidth, 2)
        XCTAssertEqual(normal.ringOpacity, 0.9)
        XCTAssertEqual(normal.ringWidth, 1.25)
        XCTAssertEqual(normal.fillOpacity, 0)
        XCTAssertEqual(normal.riseSeconds, 0.35)
        XCTAssertEqual(normal.holdSeconds, 0.45)
        XCTAssertEqual(normal.fallSeconds, 0.5)
        XCTAssertEqual(normal.gapSeconds, 0.55)
        XCTAssertEqual(UIPrefs.defaults.alertUrgent, .normal)
        XCTAssertEqual(UIPrefs.defaults.alertOther, .normal)
    }

    func testLevelsGetLouderInOrder() {
        XCTAssertEqual(AlertIntensity.allCases, [.off, .subtle, .normal, .bright])
        XCTAssertEqual(AlertIntensity.allCases.map(\.rawValue), ["off", "subtle", "normal", "bright"])
        let looks = AlertIntensity.allCases.map { AlertStyle.look($0, priority: .normal, basePulses: 1) }
        for (a, b) in zip(looks, looks.dropFirst()) {
            XCTAssertTrue(a.pulses <= b.pulses)
            XCTAssertTrue(a.glowPeak <= b.glowPeak)
            XCTAssertTrue(a.glowRadius <= b.glowRadius)
            XCTAssertTrue(a.ringOpacity < b.ringOpacity)
            XCTAssertTrue(a.ringWidth <= b.ringWidth)
            XCTAssertTrue(a.fillOpacity <= b.fillOpacity)
        }
        // Bright adds a pulse and a tint.
        XCTAssertEqual(AlertStyle.look(.bright, priority: .urgent, basePulses: 2).pulses, 3)
        XCTAssertTrue(AlertStyle.look(.bright, priority: .normal).fillOpacity > 0)
    }

    func testUrgentFloor() {
        XCTAssertEqual(AlertStyle.effective(.off, for: .urgent), AlertStyle.urgentFloor)
        XCTAssertEqual(AlertStyle.effective(.off, for: .normal), .off)
        XCTAssertEqual(AlertStyle.effective(.off, for: .low), .off)
        XCTAssertEqual(AlertStyle.effective(.bright, for: .urgent), .bright)
        for chosen in AlertIntensity.allCases {
            let look = AlertStyle.look(chosen, priority: .urgent, basePulses: 2)
            XCTAssertTrue(look.pulses >= 1, "urgent always pulses at \(chosen)")
            XCTAssertTrue(look.glowPeak >= 0.5, "urgent glow stays visible at \(chosen)")
            XCTAssertTrue(look.ringOpacity >= 0.6, "urgent ring stays visible at \(chosen)")
            XCTAssertTrue(look.ringWidth >= 1)
        }
        // A UIPrefs that turns urgent off still gets the floor.
        var prefs = UIPrefs()
        prefs.alertUrgent = .off
        XCTAssertEqual(prefs.alertIntensity(for: .urgent), .off)
        XCTAssertEqual(prefs.alertLook(for: .urgent), AlertStyle.look(.subtle, priority: .urgent))
    }

    func testOffSilencesOtherItems() {
        let off = AlertStyle.look(.off, priority: .normal, basePulses: 1)
        XCTAssertEqual(off.pulses, 0)
        XCTAssertEqual(off.glowPeak, 0)
        XCTAssertEqual(off.totalSeconds, 0)
        // The count pill still shows its priority, faintly.
        XCTAssertTrue(off.ringOpacity > AlertStyle.otherContextRingOpacity)
    }

    func testGlowFitsThePadding() {
        for chosen in AlertIntensity.allCases {
            for priority in ItemPriority.allCases {
                let look = AlertStyle.look(chosen, priority: priority, basePulses: 3)
                XCTAssertTrue(look.glowRadius <= AlertStyle.maxGlowRadius)
                XCTAssertTrue((0...1).contains(look.glowPeak))
                XCTAssertTrue((0...1).contains(look.ringOpacity))
                XCTAssertTrue((0...1).contains(look.fillOpacity))
                XCTAssertTrue(look.pulses <= 4)
            }
        }
    }

    func testReducedMotionAndPrefs() {
        let r = AlertStyle.look(.bright, priority: .urgent, basePulses: 2).reducedMotion()
        XCTAssertTrue(r.riseSeconds >= 0.4)
        XCTAssertTrue(r.fallSeconds >= 0.6)
        XCTAssertEqual(r.pulses, 3)
        XCTAssertTrue(abs(AlertStyle.look(.normal, priority: .normal).totalSeconds - 1.0) < 0.0001)

        var prefs = UIPrefs()
        prefs.alertOther = .subtle
        XCTAssertEqual(prefs.alertIntensity(for: .normal), .subtle)
        XCTAssertEqual(prefs.alertIntensity(for: .low), .subtle)
        XCTAssertEqual(prefs.alertIntensity(for: .urgent), .normal)
    }
}
