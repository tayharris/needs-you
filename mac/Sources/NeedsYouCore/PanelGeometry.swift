import CoreGraphics
import Foundation

/// A screen corner the panel snaps to. All maths uses AppKit screen coordinates
/// (origin bottom-left, y up).
public enum Corner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// Where the panel lives on one screen layout: which screen (by frame), which corner it
/// is anchored to, and how far from that corner.
///
/// `corner` is the screen quadrant the panel was dropped in. The panel's matching corner is
/// the anchor: it stays put while the panel grows, so the expanded list and the new-item
/// preview grow away from the nearest screen edges. `offset` is the distance from the
/// screen corner to the anchor (x and y, both towards the screen centre); nil means
/// "snapped" (the default margin), which is also what placements from older builds decode
/// to. Older builds ignore `offset` and snap, so a rollback loses nothing.
public struct PanelPlacement: Codable, Equatable, Sendable {
    public var corner: Corner
    /// `PanelGeometry.screenID(_:)` of the screen it was dropped on.
    public var screenID: String
    /// Free position: distance from the screen corner to the panel's anchor corner.
    public var offset: CGSize?

    public init(corner: Corner, screenID: String, offset: CGSize? = nil) {
        self.corner = corner
        self.screenID = screenID
        self.offset = offset
    }
}

public enum PanelGeometry {
    public static let margin: CGFloat = 10

    /// The corner whose quadrant holds the centre of `frame`.
    public static func nearestCorner(to frame: CGRect, in visible: CGRect) -> Corner {
        let top = frame.midY >= visible.midY
        let left = frame.midX < visible.midX
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// The panel frame of `size` pinned into `corner` of `visible`, inset by `margin`.
    /// Resizing keeps the corner fixed, so the pill grows away from the screen edge.
    public static func frame(size: CGSize, corner: Corner, in visible: CGRect, margin: CGFloat = margin) -> CGRect {
        let x = corner.isLeft ? visible.minX + margin : visible.maxX - margin - size.width
        let y = corner.isTop ? visible.maxY - margin - size.height : visible.minY + margin
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The panel frame of `size` for a placement in `bounds` (the screen's visible frame).
    /// Snapped placements sit `margin` from the corner; free ones at their offset. Either
    /// way the anchor corner stays fixed as the size changes (so the panel grows away from
    /// the nearest edges), and the result is clamped into `bounds` so it can't be lost.
    public static func frame(size: CGSize, placement: PanelPlacement, in bounds: CGRect, margin: CGFloat = margin) -> CGRect {
        clamp(unclampedFrame(size: size, placement: placement, in: bounds, margin: margin), to: bounds,
              prefer: placement.corner)
    }

    /// Move `frame` (not resize it) so it lies inside `bounds`. When it is larger than
    /// `bounds` on an axis, the side named by `prefer` stays visible (top / left by default).
    public static func clamp(_ frame: CGRect, to bounds: CGRect, prefer corner: Corner = .topLeft) -> CGRect {
        var f = frame
        if f.width >= bounds.width {
            f.origin.x = corner.isLeft ? bounds.minX : bounds.maxX - f.width
        } else {
            f.origin.x = min(max(f.minX, bounds.minX), bounds.maxX - f.width)
        }
        if f.height >= bounds.height {
            f.origin.y = corner.isTop ? bounds.maxY - f.height : bounds.minY
        } else {
            f.origin.y = min(max(f.minY, bounds.minY), bounds.maxY - f.height)
        }
        return f
    }

    /// The placement for a panel dropped at `frame` in `bounds` (the screen's visible frame).
    /// - snap on: the nearest corner at the default margin (the old behaviour);
    /// - snap off: exactly where it was dropped (clamped into `bounds`), anchored to the
    ///   nearest corner so later growth goes away from the nearest edges.
    public static func placement(forDropped frame: CGRect, in bounds: CGRect, screenID: String, snap: Bool) -> PanelPlacement {
        let corner = nearestCorner(to: frame, in: bounds)
        guard !snap else { return PanelPlacement(corner: corner, screenID: screenID) }
        let f = clamp(frame, to: bounds)
        let dx = corner.isLeft ? f.minX - bounds.minX : bounds.maxX - f.maxX
        let dy = corner.isTop ? bounds.maxY - f.maxY : f.minY - bounds.minY
        return PanelPlacement(corner: corner, screenID: screenID,
                              offset: CGSize(width: max(0, dx.rounded()), height: max(0, dy.rounded())))
    }

    /// The screen (by index into `screens`) that holds most of `frame`, else the one whose
    /// centre is closest.
    public static func bestScreen(for frame: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { s -> CGFloat in
            let i = s.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.indices.min(by: {
            hypot(screens[$0].midX - center.x, screens[$0].midY - center.y) < hypot(screens[$1].midX - center.x, screens[$1].midY - center.y)
        })
    }

    /// A stable ID for one screen within a layout.
    public static func screenID(_ frame: CGRect) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
    }

    /// A key for the set of connected screens, independent of their order, so docking and
    /// undocking each restore their own placement (mac/README.md, "Design").
    public static func configurationKey(_ screens: [CGRect]) -> String {
        screens.map(screenID).sorted().joined(separator: "|")
    }
}
