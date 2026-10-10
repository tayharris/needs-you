import CoreGraphics
import Foundation

// The floating panel's corners (Settings → Appearance → Pill → Shape). One choice shapes
// the idle pill, the waiting pill, the arrival preview (and the Later digest) and the open
// panel together; the menu bar icon is unchanged. Pure, so every shape in every state is
// unit-tested; RootView's outline (the clip, the priority ring, the hairline, the glow and
// the ripple) and PanelController's glass both take their radius from here, so they always
// agree. `.rounded` is the original look, and PanelShapeTests pins its numbers.

/// How round the panel's corners are.
public enum PanelShape: String, CaseIterable, Codable, Sendable {
    /// The original look: soft corners, the pill's ends round at the medium size.
    case rounded
    /// Nearly square corners, on everything.
    case square
    /// Fully round ends on the pill and the preview; the open panel gets its roundest corners.
    case capsule

    public var title: String {
        switch self {
        case .rounded: return "Rounded"
        case .square: return "Square"
        case .capsule: return "Capsule"
        }
    }
}

/// Which of the panel's states is drawn (PanelDisplay in the app, plus the dot and hover).
public enum PanelSurface: Equatable, Sendable {
    /// "Nothing needs <you>": smaller at rest, taller on hover.
    case idle(hovering: Bool)
    /// The waiting pill with its count.
    case pill
    /// "Minimal dot" at rest: a circle (Rounded and Capsule).
    case dot
    /// The arrival preview and the Later digest.
    case peek
    /// The open panel.
    case panel
}

public enum PanelCorners {
    /// Square's radius on every surface: just enough to soften the corner.
    public static let squareRadius: CGFloat = 3
    /// Rounded's preview and open panel (the original 14).
    public static let roundedPanelRadius: CGFloat = 14
    /// Capsule's preview: fully round ends up to this radius (a taller preview, with a
    /// second title line, a question or a link row, keeps this, so its text isn't clipped).
    public static let capsulePeekMaxRadius: CGFloat = 30
    /// Capsule's open panel: its roundest corners that still clear the header's and the
    /// footer's text (a panel can't have round ends).
    public static let capsulePanelRadius: CGFloat = 22

    /// The corner radius of `surface` drawn `height` points tall (the visible shape, glow
    /// padding left out) in `shape`. `pill` gives the pill size's own radii (Rounded).
    /// Square and Capsule are never more than half the height; Rounded returns the original
    /// numbers as they were (the drawing clamps them), so the default look and the usage
    /// meters' insets (PillMeterLayout.barInset) don't move by a point.
    public static func radius(_ shape: PanelShape, _ surface: PanelSurface, height: CGFloat, pill: PillMetrics) -> CGFloat {
        let half = max(0, height / 2)
        switch shape {
        case .rounded:
            switch surface {
            case .idle(let hovering): return hovering ? pill.idleHoverCornerRadius : pill.idleCornerRadius
            case .pill: return pill.cornerRadius
            case .dot: return half
            case .peek, .panel: return roundedPanelRadius
            }
        case .square:
            return min(squareRadius, half)
        case .capsule:
            switch surface {
            case .idle, .pill, .dot: return half
            case .peek: return min(half, capsulePeekMaxRadius)
            case .panel: return min(half, capsulePanelRadius)
            }
        }
    }
}
