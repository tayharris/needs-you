#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Arrival animations and their timing: the default is the original glow pulse exactly,
/// speed and repeats change the timing predictably, nothing moves past the panel's padding,
/// Reduce Motion becomes a fade, urgent can't be set to None, and the repeat reminder only
/// fires when it should.
final class ArrivalMotionTests: XCTestCase {
    static var allTests = [
        ("testDefaultIsTheOriginalPulse", testDefaultIsTheOriginalPulse),
        ("testSpeedScalesEveryFrame", testSpeedScalesEveryFrame),
        ("testRepeats", testRepeats),
        ("testOffAndNone", testOffAndNone),
        ("testUrgentNeverNone", testUrgentNeverNone),
        ("testMotionFitsThePadding", testMotionFitsThePadding),
        ("testReduceMotionFades", testReduceMotionFades),
        ("testSlideAndRipple", testSlideAndRipple),
        ("testKeyframes", testKeyframes),
        ("testPrefsRoundTripAndFallback", testPrefsRoundTripAndFallback),
        ("testReminder", testReminder),
    ]

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = "needsyou-arrival-test-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    func testDefaultIsTheOriginalPulse() {
        let p = UIPrefs.defaults
        XCTAssertEqual(p.arrivalUrgent, .glow)
        XCTAssertEqual(p.arrivalOther, .glow)
        XCTAssertEqual(p.arrivalRepeats, ArrivalRepeats.automatic)
        XCTAssertEqual(p.arrivalSpeed, .normal)
        XCTAssertEqual(p.urgentReminderMinutes, 0)
        // Urgent pulses twice, others once, each 1.0 s: fade in 0.35, hold to 0.45, fade out
        // 0.5, pause to 0.55 (PulseRunner's timing).
        let urgent = p.arrivalPlan(for: .urgent, basePulses: 2)
        XCTAssertEqual(urgent.animation, .glow)
        XCTAssertEqual(urgent.look, AlertStyle.look(.normal, priority: .urgent, basePulses: 2))
        XCTAssertTrue(close(urgent.totalSeconds, urgent.look.totalSeconds))
        XCTAssertTrue(close(urgent.totalSeconds, 2.0))
        let normal = p.arrivalPlan(for: .normal)
        XCTAssertEqual(normal.frames.map(\.value), [1, 1, 0, 0])
        XCTAssertEqual(normal.frames.map(\.curve), [.easeOut, .linear, .easeIn, .linear])
        let seconds = normal.frames.map(\.seconds)
        XCTAssertTrue(close(seconds[0], 0.35) && close(seconds[1], 0.1) && close(seconds[2], 0.5) && close(seconds[3], 0.05))
        XCTAssertEqual(normal.restValue, 0)
    }

    func testSpeedScalesEveryFrame() {
        let look = AlertStyle.look(.normal, priority: .normal)
        for animation in ArrivalAnimation.allCases where animation != .none {
            let normal = ArrivalMotion.plan(animation, look: look, speed: .normal)
            let slow = ArrivalMotion.plan(animation, look: look, speed: .slow)
            let fast = ArrivalMotion.plan(animation, look: look, speed: .fast)
            XCTAssertTrue(normal.totalSeconds > 0, animation.rawValue)
            XCTAssertTrue(close(slow.totalSeconds, normal.totalSeconds * PulseSpeed.slow.factor), animation.rawValue)
            XCTAssertTrue(close(fast.totalSeconds, normal.totalSeconds * PulseSpeed.fast.factor), animation.rawValue)
            XCTAssertTrue(fast.totalSeconds < normal.totalSeconds && normal.totalSeconds < slow.totalSeconds)
            XCTAssertEqual(slow.frames.map(\.value), normal.frames.map(\.value), "speed changes timing only")
            // Nothing runs on forever.
            XCTAssertTrue(ArrivalMotion.plan(animation, look: look, speed: .slow, repeats: 5).totalSeconds < 15)
        }
        XCTAssertEqual(PulseSpeed.allCases.map(\.rawValue), ["slow", "normal", "fast"])
    }

    func testRepeats() {
        let look = AlertStyle.look(.normal, priority: .urgent, basePulses: 2)
        let auto = ArrivalMotion.plan(.glow, look: look)
        XCTAssertEqual(auto.frames.count, 2 * 4, "automatic: the loudness's pulses")
        XCTAssertEqual(ArrivalMotion.plan(.glow, look: look, repeats: 1).frames.count, 4)
        XCTAssertEqual(ArrivalMotion.plan(.glow, look: look, repeats: 5).frames.count, 20)
        XCTAssertEqual(ArrivalMotion.plan(.shake, look: look, repeats: 3).frames.count, 3 * 7)
        XCTAssertEqual(ArrivalMotion.plan(.bounce, look: look, repeats: 3).frames.count, 3 * 5)
        XCTAssertEqual(ArrivalMotion.plan(.ripple, look: look, repeats: 2).frames.count, 2 * 4)
        XCTAssertEqual(ArrivalMotion.plan(.glow, look: look, repeats: 99).frames.count, ArrivalRepeats.maximum * 4)
        XCTAssertEqual(ArrivalRepeats.sanitized(4), ArrivalRepeats.automatic)
        XCTAssertEqual(ArrivalRepeats.sanitized(3), 3)
        XCTAssertEqual(ArrivalRepeats.title(0), "Automatic")
        XCTAssertEqual(ArrivalRepeats.title(2), "Twice")
    }

    func testOffAndNone() {
        // Alerts → Off for normal items: nothing plays, whatever the animation or repeats.
        let off = AlertStyle.look(.off, priority: .normal)
        for animation in ArrivalAnimation.allCases {
            XCTAssertTrue(ArrivalMotion.plan(animation, look: off, repeats: 3).isEmpty, animation.rawValue)
        }
        var p = UIPrefs()
        p.arrivalOther = .none
        XCTAssertTrue(p.arrivalPlan(for: .normal).isEmpty)
        XCTAssertTrue(p.arrivalPlan(for: .low).isEmpty)
        XCTAssertFalse(p.arrivalPlan(for: .urgent).isEmpty, "the other choice doesn't touch urgent")
    }

    func testUrgentNeverNone() {
        XCTAssertFalse(ArrivalAnimation.choices(for: .urgent).contains(.none))
        XCTAssertTrue(ArrivalAnimation.choices(for: .normal).contains(.none))
        XCTAssertEqual(ArrivalAnimation.effective(.none, for: .urgent), .glow)
        XCTAssertEqual(ArrivalAnimation.effective(.none, for: .low), .none)
        var p = UIPrefs()
        p.arrivalUrgent = .none
        p.alertUrgent = .off
        XCTAssertEqual(p.arrivalAnimation(for: .urgent), .glow)
        XCTAssertFalse(p.arrivalPlan(for: .urgent).isEmpty, "urgent always moves at least once")
        store.set("none", forKey: UIPrefs.Key.arrivalUrgent)
        XCTAssertEqual(UIPrefs.load(from: store).arrivalUrgent, .glow)
    }

    func testMotionFitsThePadding() {
        for intensity in AlertIntensity.allCases {
            for priority in ItemPriority.allCases {
                let look = AlertStyle.look(intensity, priority: priority, basePulses: 2)
                for animation in ArrivalAnimation.allCases {
                    let plan = ArrivalMotion.plan(animation, look: look)
                    let reach = plan.amplitude * (plan.frames.map { abs($0.value) }.max() ?? 0)
                    XCTAssertTrue(reach <= ArrivalMotion.padding, "\(animation) reaches \(reach)")
                    XCTAssertTrue(plan.frames.allSatisfy { (-1...1).contains($0.value) && $0.seconds >= 0 })
                }
            }
        }
        // Louder shakes further.
        let subtle = ArrivalMotion.plan(.shake, look: AlertStyle.look(.subtle, priority: .normal))
        let bright = ArrivalMotion.plan(.shake, look: AlertStyle.look(.bright, priority: .normal))
        XCTAssertTrue(subtle.amplitude < bright.amplitude)
        XCTAssertTrue(ArrivalMotion.plan(.bounce, look: AlertStyle.look(.normal, priority: .normal)).amplitude >= 4,
                      "a hop you can see")
    }

    func testReduceMotionFades() {
        let look = AlertStyle.look(.normal, priority: .urgent, basePulses: 2)
        for animation in [ArrivalAnimation.glow, .bounce, .shake, .slide, .ripple] {
            let plan = ArrivalMotion.plan(animation, look: look, reduceMotion: true)
            XCTAssertEqual(plan.animation, .glow, "\(animation) becomes a fade")
            XCTAssertFalse(plan.animation.movesPanel)
            XCTAssertTrue(plan.look.riseSeconds >= 0.4 && plan.look.fallSeconds >= 0.6, "gentle fades")
        }
        XCTAssertTrue(ArrivalMotion.plan(.none, look: AlertStyle.look(.normal, priority: .low), reduceMotion: true).isEmpty)
        var p = UIPrefs()
        p.arrivalUrgent = .shake
        XCTAssertEqual(p.arrivalPlan(for: .urgent, reduceMotion: true).animation, .glow)
        XCTAssertEqual(p.arrivalPlan(for: .urgent).animation, .shake)
    }

    func testSlideAndRipple() {
        let look = AlertStyle.look(.normal, priority: .normal)
        let slide = ArrivalMotion.plan(.slide, look: look, repeats: 3)
        XCTAssertEqual(slide.restValue, 1)
        XCTAssertEqual(slide.frames.first, ArrivalFrame(0, 0, .instant), "starts out of place")
        XCTAssertEqual(slide.frames.last?.value, 1, "ends in place")
        XCTAssertEqual(slide.frames.count, 2, "slide in plays once")
        XCTAssertTrue(ArrivalAnimation.slide.movesPanel && ArrivalAnimation.bounce.movesPanel && ArrivalAnimation.shake.movesPanel)
        XCTAssertFalse(ArrivalAnimation.glow.movesPanel || ArrivalAnimation.ripple.movesPanel)

        let ripple = ArrivalMotion.plan(.ripple, look: look)
        XCTAssertEqual(ripple.frames.last?.value, 0, "the ring is gone afterwards")
        XCTAssertEqual(ArrivalMotion.ripple(progress: 0, plan: ripple).opacity, 0)
        let half = ArrivalMotion.ripple(progress: 0.5, plan: ripple)
        XCTAssertTrue(close(half.outset, ripple.amplitude / 2) && close(half.opacity, 0.5))
        XCTAssertTrue(close(ArrivalMotion.ripple(progress: 1, plan: ripple).opacity, 0))
    }

    func testKeyframes() {
        let plan = ArrivalMotion.plan(.shake, look: AlertStyle.look(.normal, priority: .normal))
        let k = ArrivalMotion.keyframes(plan)
        XCTAssertEqual(k.times.count, plan.frames.count + 1)
        XCTAssertEqual(k.values.count, k.times.count)
        XCTAssertEqual(k.curves.count, plan.frames.count)
        XCTAssertEqual(k.times.first, 0)
        XCTAssertTrue(close(k.times.last ?? 0, 1))
        XCTAssertEqual(k.values.first, plan.restValue)
        XCTAssertEqual(k.times, k.times.sorted(), "key times never go back")
        XCTAssertTrue(ArrivalMotion.keyframes(.idle(AlertStyle.look(.off, priority: .low))).times.isEmpty)
    }

    func testPrefsRoundTripAndFallback() {
        XCTAssertEqual(UIPrefs.load(from: store), UIPrefs.defaults)
        var p = UIPrefs()
        p.arrivalUrgent = .shake
        p.arrivalOther = .ripple
        p.arrivalRepeats = 3
        p.arrivalSpeed = .fast
        p.urgentReminderMinutes = 10
        p.save(to: store, previous: UIPrefs())
        XCTAssertEqual(Set((store.persistentDomain(forName: suite) ?? [:]).keys),
                       [UIPrefs.Key.arrivalUrgent, UIPrefs.Key.arrivalOther, UIPrefs.Key.arrivalRepeats,
                        UIPrefs.Key.arrivalSpeed, UIPrefs.Key.urgentReminderMinutes])
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.arrivalUrgent), "shake")
        XCTAssertEqual(UIPrefs.load(from: store), p)

        store.set("wobble", forKey: UIPrefs.Key.arrivalOther)
        store.set(7, forKey: UIPrefs.Key.arrivalRepeats)
        store.set("ludicrous", forKey: UIPrefs.Key.arrivalSpeed)
        store.set(3, forKey: UIPrefs.Key.urgentReminderMinutes)
        let loaded = UIPrefs.load(from: store)
        XCTAssertEqual(loaded.arrivalOther, .glow)
        XCTAssertEqual(loaded.arrivalRepeats, ArrivalRepeats.automatic)
        XCTAssertEqual(loaded.arrivalSpeed, .normal)
        XCTAssertEqual(loaded.urgentReminderMinutes, UrgentReminder.off)
        XCTAssertEqual(loaded.arrivalUrgent, .shake)
    }

    func testReminder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = UrgentReminder.Input(intervalMinutes: 5, unseenUrgent: 1, panelShown: true, expanded: false,
                                       peekShowing: false, urgentWouldInterrupt: true,
                                       lastAlertAt: now.addingTimeInterval(-300), now: now)
        XCTAssertTrue(UrgentReminder.isDue(due))
        var i = due
        i.lastAlertAt = now.addingTimeInterval(-299)
        XCTAssertFalse(UrgentReminder.isDue(i), "not before the interval")
        i = due; i.intervalMinutes = 0
        XCTAssertFalse(UrgentReminder.isDue(i), "off by default")
        i = due; i.unseenUrgent = 0
        XCTAssertFalse(UrgentReminder.isDue(i), "nothing unseen")
        i = due; i.panelShown = false
        XCTAssertFalse(UrgentReminder.isDue(i), "hidden or snoozed")
        i = due; i.expanded = true
        XCTAssertFalse(UrgentReminder.isDue(i), "already open")
        i = due; i.peekShowing = true
        XCTAssertFalse(UrgentReminder.isDue(i), "a preview is out")
        i = due; i.urgentWouldInterrupt = false
        XCTAssertFalse(UrgentReminder.isDue(i), "the focus holds urgent")
        i = due; i.lastAlertAt = nil
        XCTAssertFalse(UrgentReminder.isDue(i), "no clock yet")
        XCTAssertEqual(UrgentReminder.choices.first, 0)
        XCTAssertEqual(UrgentReminder.sanitized(7), 0)
        XCTAssertEqual(UrgentReminder.title(0), "Off")
        XCTAssertEqual(UrgentReminder.title(10), "Every 10 min")
    }
}
