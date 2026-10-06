import CoreGraphics
import Foundation

/// A screen corner the panel snaps to. All maths uses AppKit screen coordinates
/// (origin bottom-left, y up).
public enum Corner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// Where the panel lives on one screen layout: which screen (by frame) and which corner.
public struct PanelPlacement: Codable, Equatable, Sendable {
    public var corner: Corner
    /// `PanelGeometry.screenID(_:)` of the screen it was dropped on.
    public var screenID: String

    public init(corner: Corner, screenID: String) {
        self.corner = corner
        self.screenID = screenID
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
    /// undocking each restore their own placement (PLAN.md, "Display").
    public static func configurationKey(_ screens: [CGRect]) -> String {
        screens.map(screenID).sorted().joined(separator: "|")
    }
}
