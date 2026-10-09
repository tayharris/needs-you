import CoreGraphics
import Foundation

// How loud a new or waiting item is: the glow pulse when it arrives, and the steady ring
// and tint on the count pill. Pure numbers, so the urgent floor is unit-tested.
// `.normal` is the original look (AlertStyleTests pins it).

/// Settings → Appearance → Alert style: off, subtle, normal or bright. Chosen separately for urgent items and
/// for everything else.
public enum AlertIntensity: String, CaseIterable, Codable, Sendable, Comparable {
    case off, subtle, normal, bright

    public var title: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .bright: return "Bright"
        }
    }

    var rank: Int {
        switch self {
        case .off: return 0
        case .subtle: return 1
        case .normal: return 2
        case .bright: return 3
        }
    }

    public static func < (lhs: AlertIntensity, rhs: AlertIntensity) -> Bool { lhs.rank < rhs.rank }
}

/// What the panel draws for one priority at one intensity.
public struct AlertLook: Equatable, Sendable {
    /// Glow pulses when an item arrives (0 = no pulse).
    public var pulses: Int
    /// Glow opacity at the top of a pulse, 0...1.
    public var glowPeak: Double
    /// Outer glow radius. At most `AlertStyle.maxGlowRadius` (the panel's glow padding).
    public var glowRadius: CGFloat
    /// Width of the glowing edge stroke during a pulse.
    public var strokeWidth: CGFloat
    /// The steady priority ring on the count pill and preview, 0...1.
    public var ringOpacity: Double
    public var ringWidth: CGFloat
    /// A steady tint of the count pill in the priority colour, 0...1.
    public var fillOpacity: Double
    /// One pulse: fade in, hold, fade out, pause before the next.
    public var riseSeconds: Double
    public var holdSeconds: Double
    public var fallSeconds: Double
    public var gapSeconds: Double

    /// Reduce Motion: the same pulses with gentler fades.
    public func reducedMotion() -> AlertLook {
        var l = self
        l.riseSeconds = max(l.riseSeconds, 0.4)
        l.fallSeconds = max(l.fallSeconds, 0.6)
        return l
    }

    /// Seconds from the first fade-in to the end of the last pause.
    public var totalSeconds: Double {
        Double(pulses) * (holdSeconds + gapSeconds)
    }
}

public enum AlertStyle {
    /// Urgent items are never quieter than this, so they can't be made invisible.
    public static let urgentFloor: AlertIntensity = .subtle
    /// The panel leaves this much transparent room around the pill for the glow.
    public static let maxGlowRadius: CGFloat = 8
    /// The ring when only the other context has items (faint, whatever the setting).
    public static let otherContextRingOpacity = 0.25

    /// The intensity actually used: the choice, raised to the floor for urgent items.
    public static func effective(_ chosen: AlertIntensity, for priority: ItemPriority) -> AlertIntensity {
        priority == .urgent ? max(chosen, urgentFloor) : chosen
    }

    /// An ambient arrival (delivery tiers): one soft brighten, never louder than Subtle.
    /// Off stays off, except that urgent keeps its floor.
    public static func ambientLook(_ chosen: AlertIntensity, priority: ItemPriority) -> AlertLook {
        var l = look(min(effective(chosen, for: priority), .subtle), priority: priority, basePulses: 1)
        l.pulses = min(l.pulses, 1)
        return l
    }

    /// The look for `priority` at the chosen intensity. `basePulses` is what the caller
    /// would pulse at normal (the original: 2 for urgent arrivals, 1 otherwise).
    public static func look(_ chosen: AlertIntensity, priority: ItemPriority, basePulses: Int = 1) -> AlertLook {
        let base = max(1, basePulses)
        switch effective(chosen, for: priority) {
        case .off:
            return AlertLook(pulses: 0, glowPeak: 0, glowRadius: 0, strokeWidth: 0,
                             ringOpacity: 0.45, ringWidth: 1, fillOpacity: 0,
                             riseSeconds: 0.35, holdSeconds: 0.45, fallSeconds: 0.5, gapSeconds: 0.55)
        case .subtle:
            return AlertLook(pulses: 1, glowPeak: 0.5, glowRadius: 5, strokeWidth: 1.5,
                             ringOpacity: 0.65, ringWidth: 1, fillOpacity: 0,
                             riseSeconds: 0.45, holdSeconds: 0.5, fallSeconds: 0.6, gapSeconds: 0.55)
        case .normal:
            // The original look.
            return AlertLook(pulses: base, glowPeak: 1, glowRadius: 7, strokeWidth: 2,
                             ringOpacity: 0.9, ringWidth: 1.25, fillOpacity: 0,
                             riseSeconds: 0.35, holdSeconds: 0.45, fallSeconds: 0.5, gapSeconds: 0.55)
        case .bright:
            return AlertLook(pulses: base + 1, glowPeak: 1, glowRadius: maxGlowRadius, strokeWidth: 3,
                             ringOpacity: 1, ringWidth: 2, fillOpacity: 0.16,
                             riseSeconds: 0.3, holdSeconds: 0.45, fallSeconds: 0.45, gapSeconds: 0.45)
        }
    }
}
