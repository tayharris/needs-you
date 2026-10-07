import CoreGraphics
import Foundation

// How long arrival peeks stay out, and the expanded panel's dragged height. Pure, so
// they're unit-tested; PanelController, AppModel and Phase3 only read the answers.

/// Settings → Alerts → Show new items for: how long the new-item preview (and the
/// "3 waited while you were focused" peek) stays out. Pointing at it holds it open.
public enum PeekDuration {
    /// Seconds; `untilDismissed` (0) keeps it out until it's clicked, or pointed at and left.
    public static let choices = [5, 10, 14, 20, 30, 0]
    /// 10 s longer than the original 4 s, which went by too fast to read.
    public static let standard = 14
    public static let untilDismissed = 0
    /// After the pointer leaves a peek it stays at least this long, so it doesn't vanish
    /// the moment you move off it.
    public static let hoverGrace: TimeInterval = 2

    /// A stored value this build offers, else the default.
    public static func sanitized(_ seconds: Int) -> Int {
        choices.contains(seconds) ? seconds : standard
    }

    public static func title(_ seconds: Int) -> String {
        seconds == untilDismissed ? "Until I click or point at it" : "\(seconds) seconds"
    }
}

/// The countdown behind an arrival peek. Time only runs while the pointer is away: pointing
/// at the peek holds it, and leaving resumes the countdown with at least `hoverGrace` left.
/// With `untilDismissed` there's no countdown until the pointer has been over it once.
public struct PeekCountdown: Equatable, Sendable {
    /// Seconds left; nil while it waits to be clicked or pointed at.
    public private(set) var remaining: TimeInterval?

    public init(seconds: Int) {
        let s = PeekDuration.sanitized(seconds)
        remaining = s == PeekDuration.untilDismissed ? nil : TimeInterval(s)
    }

    /// Moves the clock on by `elapsed`. Returns true when the peek should go away.
    public mutating func advance(by elapsed: TimeInterval, hovering: Bool) -> Bool {
        if hovering {
            remaining = max(remaining ?? PeekDuration.hoverGrace, PeekDuration.hoverGrace)
            return false
        }
        guard let left = remaining else { return false }
        let next = left - max(0, elapsed)
        remaining = next
        return next <= 0
    }
}

/// The expanded list's height when the user drags the panel's resize grip. 0 means
/// automatic (ListHeightPolicy and Cards before scrolling decide).
public enum ListResize {
    public static let automatic: CGFloat = 0
    /// Stored heights above this are treated as bad data (automatic).
    public static let maxStored: CGFloat = 10_000

    /// A stored height, or automatic when it's missing, negative or absurd.
    public static func sanitized(_ stored: Double) -> Double {
        guard stored.isFinite, stored > 0, CGFloat(stored) <= maxStored else { return Double(automatic) }
        return stored.rounded()
    }

    /// `height` kept between `minimum` and `cap` (the cap never goes below the minimum).
    public static func clamp(_ height: CGFloat, minimum: CGFloat, cap: CGFloat) -> CGFloat {
        guard height.isFinite else { return minimum }
        return min(max(height, minimum), max(cap, minimum))
    }

    /// The grip sits on the edge away from the anchored corner: the bottom when the panel
    /// hangs from a top corner (it grows down), the top when it sits on a bottom corner.
    public static func gripAtBottom(anchor corner: Corner) -> Bool { corner.isTop }

    /// The list height while dragging the grip. `deltaY` is the pointer's movement since the
    /// drag began in screen coordinates (y up): dragging the bottom grip down, or the top grip
    /// up, makes the list taller.
    public static func dragged(start: CGFloat, deltaY: CGFloat, gripAtBottom: Bool, minimum: CGFloat, cap: CGFloat) -> CGFloat {
        clamp(gripAtBottom ? start - deltaY : start + deltaY, minimum: minimum, cap: cap)
    }

    /// The expanded list's height: the dragged height (clamped to this screen and size) when
    /// one is set, else the automatic one.
    public static func listHeight(chosen: CGFloat, automaticHeight: () -> CGFloat, minimum: CGFloat, cap: CGFloat) -> CGFloat {
        chosen > 0 ? clamp(chosen, minimum: minimum, cap: cap) : automaticHeight()
    }
}
