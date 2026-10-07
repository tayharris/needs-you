import AppKit
import Combine
import NeedsYouCore

/// The display you're working on, for arrival peeks and the edge glow. Reads the on-screen
/// window list (owner pid, layer, bounds; never titles), which needs no Screen Recording or
/// Accessibility permission. The choice itself is `WorkDisplay` in Core.
@MainActor
enum WorkDisplayProbe {
    static func screen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let windows = info.compactMap { entry -> WindowRecord? in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            return WindowRecord(pid: pid, layer: layer, bounds: bounds)
        }
        let index = WorkDisplay.screenIndex(
            screens: screens.map(\.frame), primaryScreenHeight: primary.frame.height, windows: windows,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier, mouse: NSEvent.mouseLocation)
        return index.map { screens[$0] }
    }
}

/// Settings → Alerts → Urgent edge glow: a few seconds of red glow along the work display's
/// edge when an urgent item interrupts. The window ignores the mouse and is never key or
/// main (EdgeGlowWindow), so it can't take focus or a click.
@MainActor
final class EdgeGlowController {
    private let window = EdgeGlowWindow()
    private var cancellable: AnyCancellable?
    private var task: Task<Void, Never>?

    init(model: AppModel) {
        window.contentView = EdgeGlowView()
        cancellable = model.$edgeGlowRequest.dropFirst().compactMap { $0 }.sink { [weak self] _ in self?.flash() }
    }

    private func flash() {
        guard let screen = WorkDisplayProbe.screen() ?? NSScreen.main else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let pulses = reduceMotion ? 1 : 2
            for _ in 0..<pulses {
                self?.fade(to: 1, duration: reduceMotion ? 0.6 : 0.3)
                try? await Task.sleep(nanoseconds: 900_000_000)
                self?.fade(to: 0, duration: reduceMotion ? 0.8 : 0.5)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
            }
            self?.window.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            window.animator().alphaValue = alpha
        }
    }
}

/// Three strokes along the edge, soft to sharp, in the urgent colour.
final class EdgeGlowView: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)
        let rings: [(width: CGFloat, alpha: CGFloat)] = [(22, 0.16), (10, 0.32), (3, 0.9)]
        for ring in rings {
            let path = NSBezierPath(rect: bounds.insetBy(dx: ring.width / 2, dy: ring.width / 2))
            path.lineWidth = ring.width
            color.withAlphaComponent(ring.alpha).setStroke()
            path.stroke()
        }
    }
}
