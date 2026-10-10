import NeedsYouCore
import SwiftUI

/// The panel's visible shape in the chosen Settings → Appearance → Pill → Shape: the corners
/// come from PanelCorners for the rectangle it's drawn in, so the clip, the priority ring,
/// the hairline, the arrival glow and the ripple all follow the shape at whatever height
/// the state has (Capsule's round ends included). Insetting (strokeBorder, the ripple's
/// outset) moves the corners with the edge, as RoundedRectangle does.
struct PanelOutline: InsettableShape {
    let shape: PanelShape
    let surface: PanelSurface
    let pill: PillMetrics
    var inset: CGFloat = 0

    init(_ ui: UIPrefs, _ surface: PanelSurface) {
        self.shape = ui.panelShape
        self.surface = surface
        self.pill = ui.pillMetrics
    }

    func path(in rect: CGRect) -> Path {
        let radius = PanelCorners.radius(shape, surface, height: rect.height, pill: pill)
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        let half = min(r.width, r.height) / 2
        let corner = min(max(0, radius - inset), half)
        // Capsule's fully round ends are circular: a continuous corner as big as half the
        // height bends past the ends of a short pill, and the ring then shows flat spikes at
        // its sides. Rounded keeps its original continuous corners.
        let round = shape == .capsule && corner >= half - 0.5
        return RoundedRectangle(cornerRadius: corner, style: round ? .circular : .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PanelOutline {
        var copy = self
        copy.inset += amount
        return copy
    }
}
