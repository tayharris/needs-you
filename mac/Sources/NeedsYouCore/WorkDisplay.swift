import CoreGraphics
import Foundation

// "Visible on the work screen" (docs/roadmap/human-gates.md, build step 6): which display
// an arrival peeks on, chosen from the on-screen window list (owner pid, layer, bounds),
// which needs no Screen Recording or Accessibility permission. Pure, so it's tested here;
// the app reads the window list and the screens.

/// One entry of `CGWindowListCopyWindowInfo` (titles are never read).
public struct WindowRecord: Equatable, Sendable {
    public var pid: Int32
    /// 0 is a normal app window; menus, the Dock and overlays sit above it.
    public var layer: Int
    /// Window-list coordinates: origin at the top left of the primary display, y down.
    public var bounds: CGRect

    public init(pid: Int32, layer: Int, bounds: CGRect) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

/// Settings → Alerts → On the work screen: where the arrival preview springs out.
public enum PreviewDisplay: String, CaseIterable, Sendable {
    /// The display with the frontmost app's window (else the pointer); the pill goes back home after.
    case work
    /// Always where the pill lives (the default: an alert never jumps between monitors).
    case pill

    public static let defaultsKey = "previewDisplay"
    public static let standard = PreviewDisplay.pill

    public var title: String {
        switch self {
        case .work: return "The display you're working on"
        case .pill: return "The pill's display"
        }
    }
}

/// Settings → Alerts → On the work screen: a click-through glow around that display's edge.
public enum EdgeGlowMode: String, CaseIterable, Sendable {
    case off
    case urgent

    public static let defaultsKey = "edgeGlow"
    public static let standard = EdgeGlowMode.off

    public var title: String {
        switch self {
        case .off: return "Off"
        case .urgent: return "Urgent arrivals"
        }
    }
}

public enum WorkDisplay {
    /// Smaller windows (palettes, badges, tooltips) don't say where you're working.
    public static let minWindowSide: CGFloat = 100

    /// A window-list rect in AppKit screen coordinates (origin bottom left, y up).
    public static func appKitRect(_ windowBounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: windowBounds.minX, y: primaryScreenHeight - windowBounds.maxY,
               width: windowBounds.width, height: windowBounds.height)
    }

    /// The display to peek on (an index into `screens`, AppKit frames with the primary
    /// first): the one holding most of the frontmost app's frontmost normal window, else
    /// the one under the pointer, else nil (stay home). `windows` is front to back, as the
    /// window list returns it. This app's own windows never count.
    public static func screenIndex(screens: [CGRect], primaryScreenHeight: CGFloat, windows: [WindowRecord],
                                   frontmostPID: Int32?, ownPID: Int32, mouse: CGPoint?) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let front = frontmostPID, front != ownPID,
           let window = windows.first(where: {
               $0.pid == front && $0.layer == 0
                   && $0.bounds.width >= minWindowSide && $0.bounds.height >= minWindowSide
           }) {
            let frame = appKitRect(window.bounds, primaryScreenHeight: primaryScreenHeight)
            if let index = screenHolding(frame, screens: screens) { return index }
        }
        if let mouse {
            // Edges count: the pointer can rest on the very top row of a display.
            if let index = screens.firstIndex(where: {
                mouse.x >= $0.minX && mouse.x <= $0.maxX && mouse.y >= $0.minY && mouse.y <= $0.maxY
            }) { return index }
        }
        return nil
    }

    /// The screen with the largest overlap with `frame`, or nil when it's on none.
    static func screenHolding(_ frame: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }
}
