import CoreGraphics
import Foundation

// Settings → Alerts → Arrival animation: how a new item announces itself on the pill, and
// its timing. The motion is pure keyframes here (ArrivalMotionTests); the app only plays
// them. `.glow` at normal speed with automatic repeats is the original pulse exactly.

/// What the pill does when an item arrives. Chosen separately for urgent and other items.
public enum ArrivalAnimation: String, CaseIterable, Codable, Sendable {
    /// The priority-coloured glow brightens and fades (the original).
    case glow
    /// The pill hops up and lands with a small rebound.
    case bounce
    /// A quick side-to-side shake.
    case shake
    /// The pill slides in and fades up, once.
    case slide
    /// A ring spreads out from the pill's edge and fades.
    case ripple
    /// No motion; the ring and the preview still show. Not offered for urgent items.
    case none

    public var title: String {
        switch self {
        case .glow: return "Glow pulse"
        case .bounce: return "Bounce"
        case .shake: return "Shake"
        case .slide: return "Slide in"
        case .ripple: return "Ripple"
        case .none: return "None"
        }
    }

    /// The choices for a priority: urgent can't be set to None (it always moves at least
    /// once, like the alert floor).
    public static func choices(for priority: ItemPriority) -> [ArrivalAnimation] {
        priority == .urgent ? allCases.filter { $0 != .none } : allCases
    }

    /// The animation actually used: urgent never gets None.
    public static func effective(_ chosen: ArrivalAnimation, for priority: ItemPriority) -> ArrivalAnimation {
        priority == .urgent && chosen == .none ? .glow : chosen
    }

    /// Moves the whole panel (its glass too), rather than drawing in the glow padding.
    public var movesPanel: Bool { self == .bounce || self == .shake || self == .slide }
}

/// How fast each pulse plays. Stored under `arrivalSpeed`.
public enum PulseSpeed: String, CaseIterable, Codable, Sendable {
    case slow, normal, fast

    public var title: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    /// Every duration is multiplied by this.
    public var factor: Double {
        switch self {
        case .slow: return 1.6
        case .normal: return 1
        case .fast: return 0.6
        }
    }
}

/// How many times the arrival animation plays. Stored under `arrivalRepeats`; 0 is
/// automatic: what the alert loudness gives (urgent twice, others once, Bright one more).
public enum ArrivalRepeats {
    public static let automatic = 0
    public static let choices = [0, 1, 2, 3, 5]
    public static let maximum = 5

    public static func sanitized(_ value: Int) -> Int { choices.contains(value) ? value : automatic }

    public static func title(_ value: Int) -> String {
        switch value {
        case 0: return "Automatic"
        case 1: return "Once"
        case 2: return "Twice"
        default: return "\(value) times"
        }
    }
}

/// Repeat reminder: an urgent item nobody has looked at plays its arrival animation again
/// every N minutes. Stored under `urgentReminderMinutes`; 0 (the default) is off.
public enum UrgentReminder {
    public static let off = 0
    public static let choices = [0, 2, 5, 10, 15, 30, 60]

    public static func sanitized(_ value: Int) -> Int { choices.contains(value) ? value : off }

    public static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Off"
        case 60: return "Every hour"
        default: return "Every \(minutes) min"
        }
    }

    /// What decides whether a reminder plays now.
    public struct Input: Equatable, Sendable {
        public var intervalMinutes: Int
        /// Open urgent `needs` items in the shown context that arrived or changed since the
        /// panel was last open.
        public var unseenUrgent: Int
        /// The panel is on screen (not hidden or snoozed).
        public var panelShown: Bool
        public var expanded: Bool
        /// A preview or Later peek is out.
        public var peekShowing: Bool
        /// The current focus would let an urgent arrival interrupt (DeliveryPolicy).
        public var urgentWouldInterrupt: Bool
        /// The last urgent arrival or reminder.
        public var lastAlertAt: Date?
        public var now: Date

        public init(intervalMinutes: Int, unseenUrgent: Int, panelShown: Bool, expanded: Bool, peekShowing: Bool,
                    urgentWouldInterrupt: Bool, lastAlertAt: Date?, now: Date) {
            self.intervalMinutes = intervalMinutes
            self.unseenUrgent = unseenUrgent
            self.panelShown = panelShown
            self.expanded = expanded
            self.peekShowing = peekShowing
            self.urgentWouldInterrupt = urgentWouldInterrupt
            self.lastAlertAt = lastAlertAt
            self.now = now
        }
    }

    /// True when a reminder is due: on, something urgent unseen, the pill in view and
    /// collapsed, nothing else showing, the focus allows urgent, and `interval` since the
    /// last urgent alert. With no last alert (e.g. after a relaunch) it waits one interval
    /// from `now`, so the caller should set `lastAlertAt` then.
    public static func isDue(_ i: Input) -> Bool {
        guard i.intervalMinutes > 0, i.unseenUrgent > 0, i.panelShown, !i.expanded, !i.peekShowing,
              i.urgentWouldInterrupt, let last = i.lastAlertAt else { return false }
        return i.now.timeIntervalSince(last) >= Double(i.intervalMinutes) * 60
    }
}

/// How one segment of an arrival moves.
public enum ArrivalCurve: String, Sendable {
    /// Jump to the value with no animation.
    case instant
    case easeOut, easeIn, easeInOut, linear
}

/// Animate to `value` over `seconds`, then go on to the next frame.
public struct ArrivalFrame: Equatable, Sendable {
    public var value: Double
    public var seconds: Double
    public var curve: ArrivalCurve

    public init(_ value: Double, _ seconds: Double, _ curve: ArrivalCurve) {
        self.value = value
        self.seconds = seconds
        self.curve = curve
    }
}

/// One arrival, ready to play: the animation, the frames of its driving value, and how far
/// that value moves things.
///
/// The driving value means, per animation:
/// - glow: the glow's strength, 0...1 (times `look.glowPeak`);
/// - bounce: the pill is `value × amplitude` points up (the hop, then a small rebound);
/// - shake: the sideways offset is `value × amplitude` points;
/// - slide: 0 = `amplitude` points up and invisible, 1 = in place;
/// - ripple: how far the ring has spread, 0...1 (`amplitude` points at 1), fading as it goes.
public struct ArrivalPlan: Equatable, Sendable {
    public var animation: ArrivalAnimation
    public var frames: [ArrivalFrame]
    public var amplitude: Double
    /// The colour and strength of the glow and ripple (and how loud the arrival is).
    public var look: AlertLook
    /// The value before the first frame and after the last.
    public var restValue: Double {
        animation == .slide ? 1 : 0
    }

    public var isEmpty: Bool { frames.isEmpty }
    public var totalSeconds: Double { frames.reduce(0) { $0 + $1.seconds } }

    public static func idle(_ look: AlertLook) -> ArrivalPlan {
        ArrivalPlan(animation: .none, frames: [], amplitude: 0, look: look)
    }
}

public enum ArrivalMotion {
    /// Hop height and shake distance in points at Normal loudness (Bright goes a bit
    /// further, Subtle less).
    static let hopPoints = 5.0
    static let shakePoints = 5.0
    /// The animated value never crosses the panel's transparent padding.
    public static let padding = Double(AlertStyle.maxGlowRadius)

    /// The arrival for `animation` at `look`'s loudness.
    ///
    /// - `look.pulses == 0` (Alerts → Off): nothing plays.
    /// - `repeats` (ArrivalRepeats; 0 = automatic) sets how many times it plays, else
    ///   `look.pulses`. Slide in plays once.
    /// - `speed` stretches or shortens every frame.
    /// - Reduce Motion: anything that moves becomes a gentle glow fade.
    /// - Every motion is a shift of at most `padding` points, so it never leaves the panel's
    ///   transparent margin, whatever the panel's size.
    public static func plan(_ animation: ArrivalAnimation, look: AlertLook, speed: PulseSpeed = .normal,
                            repeats: Int = ArrivalRepeats.automatic, reduceMotion: Bool = false) -> ArrivalPlan {
        guard look.pulses > 0, animation != .none else { return .idle(look) }
        var look = look
        var animation = animation
        if reduceMotion {
            animation = .glow
            look = look.reducedMotion()
        }
        let count = min(ArrivalRepeats.maximum, repeats > 0 ? repeats : look.pulses)
        let f = speed.factor
        var frames: [ArrivalFrame] = []
        var amplitude = 0.0
        switch animation {
        case .glow:
            // The original PulseRunner: fade in, hold until `hold`, fade out, pause until `gap`.
            for _ in 0..<count {
                frames.append(ArrivalFrame(1, look.riseSeconds * f, .easeOut))
                frames.append(ArrivalFrame(1, max(0, look.holdSeconds - look.riseSeconds) * f, .linear))
                frames.append(ArrivalFrame(0, look.fallSeconds * f, .easeIn))
                frames.append(ArrivalFrame(0, max(0, look.gapSeconds - look.fallSeconds) * f, .linear))
            }
            amplitude = Double(look.glowRadius)
        case .bounce:
            amplitude = loudness(look) * hopPoints
            for _ in 0..<count {
                frames.append(ArrivalFrame(1, 0.18 * f, .easeOut))
                frames.append(ArrivalFrame(0, 0.16 * f, .easeIn))
                frames.append(ArrivalFrame(0.3, 0.1 * f, .easeOut))
                frames.append(ArrivalFrame(0, 0.1 * f, .easeIn))
                frames.append(ArrivalFrame(0, look.gapSeconds * f, .linear))
            }
        case .shake:
            amplitude = loudness(look) * shakePoints
            for _ in 0..<count {
                for v in [1.0, -1.0, 0.7, -0.7, 0.35, 0] {
                    frames.append(ArrivalFrame(v, 0.06 * f, .easeInOut))
                }
                frames.append(ArrivalFrame(0, look.gapSeconds * f, .linear))
            }
        case .slide:
            amplitude = padding
            frames.append(ArrivalFrame(0, 0, .instant))
            frames.append(ArrivalFrame(1, 0.45 * f, .easeOut))
        case .ripple:
            amplitude = Double(look.glowRadius)
            for _ in 0..<count {
                frames.append(ArrivalFrame(0, 0, .instant))
                frames.append(ArrivalFrame(1, 0.7 * f, .easeOut))
                frames.append(ArrivalFrame(0, 0, .instant))
                frames.append(ArrivalFrame(0, look.gapSeconds * 0.5 * f, .linear))
            }
        case .none:
            return .idle(look)
        }
        return ArrivalPlan(animation: animation, frames: frames, amplitude: amplitude, look: look)
    }

    /// 0.6 (Subtle) to 1.3 (Bright): how far a motion goes, capped at the padding.
    static func loudness(_ look: AlertLook) -> Double {
        min((padding - 1) / max(hopPoints, shakePoints), max(0.6, look.glowPeak) * (look.fillOpacity > 0 ? 1.3 : 1))
    }

    /// The ripple ring at `progress` 0...1: how far out it is and how strongly it shows.
    public static func ripple(progress: Double, plan: ArrivalPlan) -> (outset: Double, opacity: Double) {
        let p = min(1, max(0, progress))
        guard p > 0 else { return (0, 0) }
        return (p * plan.amplitude, (1 - p) * plan.look.glowPeak)
    }

    /// Key times (0...1) and values for Core Animation: the frames as one keyframe track.
    /// Instant frames become a zero-length step.
    public static func keyframes(_ plan: ArrivalPlan) -> (times: [Double], values: [Double], curves: [ArrivalCurve]) {
        let total = plan.totalSeconds
        guard total > 0 else { return ([], [], []) }
        var times = [0.0]
        var values = [plan.restValue]
        var curves: [ArrivalCurve] = []
        var t = 0.0
        for frame in plan.frames {
            t += frame.seconds
            times.append(min(1, t / total))
            values.append(frame.value)
            curves.append(frame.curve)
        }
        return (times, values, curves)
    }
}
