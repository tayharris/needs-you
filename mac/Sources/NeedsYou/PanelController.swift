import AppKit
import Combine
import NeedsYouCore
import SwiftUI

/// NSHostingView that takes the first click (the panel is never key) and
/// routes right-clicks to the panel menu.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

/// Clear root view that hosts the material and tracks hover over the whole panel.
final class PanelContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Owns the panel: sizing per state, corner snapping, per-layout placement, menus,
/// click-outside and Escape handling.
@MainActor
final class PanelController {
    /// Transparent room around the visible shape for the glow.
    static let glowPadding: CGFloat = 8
    /// Gap between the visible shape and the screen edge.
    static let edgeMargin: CGFloat = 12

    private let model: AppModel
    private let panel = FloatingPanel()
    private let container = PanelContainerView()
    private let effect = NSVisualEffectView()
    private var hosting: PanelHostingView<RootView>!
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?
    private var escapeMonitors: [Any] = []
    private var escapeHotKey: HotKey?

    private var placement: PanelPlacement?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false
    private var lastDisplay: PanelDisplay?
    private var syncScheduled = false

    init(model: AppModel) {
        self.model = model

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.cornerCurve = .continuous

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container

        let inset = Self.glowPadding
        effect.frame = container.bounds.insetBy(dx: inset, dy: inset)
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        hosting = PanelHostingView(rootView: RootView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        container.addSubview(hosting)

        hosting.menuProvider = { [weak self] in self?.makeContextMenu() }
        container.onHover = { [weak model] inside in
            guard let model, model.hovering != inside else { return }
            model.hovering = inside
        }
        model.dragHandler = { [weak self] phase in self?.handleDrag(phase) }
        model.resetPositionHandler = { [weak self] in self?.resetPosition() }

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        model.settings.objectWillChange
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)

        loadPlacement()
        sync(animated: false)
    }

    // MARK: Sync with the model

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        // objectWillChange fires before the change lands; apply on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.sync(animated: true)
        }
    }

    private func sync(animated: Bool) {
        if !model.isPanelVisible {
            if panel.isVisible { panel.orderOut(nil) }
            setExpandedBehaviour(false)
            return
        }

        let display = model.display
        let size = panelSize(for: display)
        let target = frame(forPanelSize: size)
        let changedShape = display != lastDisplay
        lastDisplay = display

        if !panel.isVisible {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animated ? fade(to: alpha(for: display)) : (panel.alphaValue = alpha(for: display))
        } else if !isDragging, panel.frame != target {
            if animated, changedShape, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // Reduce Motion: fade between shapes instead of springing.
                panel.alphaValue = 0
                panel.setFrame(target, display: true)
                fade(to: alpha(for: display))
            } else if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = changedShape ? 0.28 : 0.18
                    ctx.timingFunction = Self.timing(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    ctx.allowsImplicitAnimation = true
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true)
            }
        }
        if panel.alphaValue != alpha(for: display) {
            animated ? fade(to: alpha(for: display)) : (panel.alphaValue = alpha(for: display))
        }

        effect.layer?.cornerRadius = cornerRadius(for: display)
        setExpandedBehaviour(display == .expanded)
    }

    /// A gentle overshoot for shape changes; linear-ish when Reduce Motion is on.
    static func timing(reduceMotion: Bool) -> CAMediaTimingFunction {
        reduceMotion
            ? CAMediaTimingFunction(name: .easeInEaseOut)
            : CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
    }

    private func fade(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = alpha
        }
    }

    /// Expanded-only helpers. None of these touch key status or activation.
    private func setExpandedBehaviour(_ expanded: Bool) {
        if expanded {
            if clickOutsideMonitor == nil {
                // Global monitors see clicks in *other* apps; mouse events need no permission.
                clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.collapse() }
                }
            }
            installEscape(swallow: model.expandedByUser)
        } else {
            if let monitor = clickOutsideMonitor {
                NSEvent.removeMonitor(monitor)
                clickOutsideMonitor = nil
            }
            removeEscape()
        }
    }

    /// Escape collapses without the panel ever being key:
    /// - local monitor: key events delivered to this app (e.g. while Settings is front);
    /// - global monitor: other apps' key events, only if the user granted Accessibility
    ///   (otherwise it silently sees nothing, and never prompts);
    /// - when the user opened the panel by clicking it, a Carbon Escape hotkey for as long
    ///   as it stays expanded (no permission needed). That one swallows Escape from the
    ///   front app while expanded, so it's never armed for automatic expansions such as
    ///   the morning summary.
    private func installEscape(swallow: Bool) {
        if escapeMonitors.isEmpty {
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { self?.model.collapse() }
                return nil
            }) { escapeMonitors.append(local) }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.model.collapse() }
            }) { escapeMonitors.append(global) }
        }
        if swallow, escapeHotKey == nil {
            escapeHotKey = HotKey(id: 2, keyCode: 53, modifiers: 0) { [weak self] in
                MainActor.assumeIsolated { self?.model.collapse() }
            }
        }
    }

    private func removeEscape() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors.removeAll()
        escapeHotKey = nil
    }

    // MARK: Sizes (visible shape; the panel adds glow padding around it)

    private func contentSize(for display: PanelDisplay) -> CGSize {
        let m = model.metrics
        switch display {
        case .idle:
            // PLAN.md: a faint "Nothing needs <you>" pill; on hover "all clear" and the last check.
            let text = (model.hovering ? model.idleHoverLine : model.idleRestLine) as NSString
            let width = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: m.idleFont)]).width
            return CGSize(width: m.idleWidth(textWidth: width), height: model.hovering ? m.idleHoverHeight : m.idleHeight)
        case .waiting:
            let digits = String(model.count).count + (model.otherCount > 0 ? String(model.otherCount).count + 2 : 0)
            return CGSize(width: m.countWidth(digits: digits), height: m.countHeight)
        case .preview:
            return CGSize(width: m.previewWidth, height: m.previewHeight)
        case .expanded:
            let list = ListHeightPolicy.height(content: model.expandedContentHeight, cardBottoms: model.cardBottoms,
                                               maxCards: model.settings.ui.maxVisibleCards,
                                               cap: maxListHeight(m), minimum: m.minListHeight)
            return CGSize(width: m.expandedWidth, height: m.headerHeight + list + m.footerHeight)
        }
    }

    private func maxListHeight(_ m: PanelMetrics) -> CGFloat {
        let screenHeight = currentScreen()?.visibleFrame.height ?? 800
        return min(m.maxListHeight, screenHeight - 140)
    }

    private func panelSize(for display: PanelDisplay) -> CGSize {
        let s = contentSize(for: display)
        return CGSize(width: s.width + Self.glowPadding * 2, height: s.height + Self.glowPadding * 2)
    }

    private func cornerRadius(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 11 : 9
        case .waiting: return 11
        case .preview: return 14
        case .expanded: return 14
        }
    }

    private func alpha(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 0.7 : (model.isConfigured ? 0.35 : 0.5)  // faint but findable; "set up" a little more
        case .waiting:
            return CGFloat(PanelOpacity.alpha(base: model.hovering ? 1.0 : 0.85, setting: model.settings.ui.panelOpacity, hovering: model.hovering))
        case .preview, .expanded:
            // Settings → Panel → Opacity; hovering always shows it at full strength.
            return CGFloat(PanelOpacity.alpha(base: 1.0, setting: model.settings.ui.panelOpacity, hovering: model.hovering))
        }
    }

    // MARK: Placement

    private func layoutKey() -> String {
        PanelGeometry.configurationKey(NSScreen.screens.map(\.frame))
    }

    private func loadPlacement() {
        placement = model.settings.placement(forLayout: layoutKey())
    }

    private func screensChanged() {
        loadPlacement()
        sync(animated: false)
    }

    /// The screen the placement names, else the primary display (the one with the menu bar).
    private func currentScreen() -> NSScreen? {
        if let placement, let screen = NSScreen.screens.first(where: { PanelGeometry.screenID($0.frame) == placement.screenID }) {
            return screen
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Where the panel may go on `screen`: its visible frame (below the menu bar, beside the
    /// Dock), widened by the glow padding so the visible shape itself can reach the edge.
    private func bounds(of screen: NSScreen) -> CGRect {
        screen.visibleFrame.insetBy(dx: -Self.glowPadding, dy: -Self.glowPadding)
    }

    /// The panel frame for `size`: anchored at the placement's corner (so it grows away
    /// from the nearest screen edges) and clamped to the screen. Default: top right.
    private func frame(forPanelSize size: CGSize) -> CGRect {
        guard let screen = currentScreen() else { return CGRect(origin: .zero, size: size) }
        let placement = placement ?? PanelPlacement(corner: .topRight, screenID: PanelGeometry.screenID(screen.frame))
        return PanelGeometry.frame(size: size, placement: placement, in: bounds(of: screen), margin: Self.edgeMargin)
    }

    /// Back to the default spot (top right of the main display) for this screen layout.
    func resetPosition() {
        model.settings.removePlacement(forLayout: layoutKey())
        placement = nil
        sync(animated: true)
    }

    private func handleDrag(_ phase: DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if !isDragging {
                isDragging = true
                dragStartMouse = mouse
                dragStartOrigin = panel.frame.origin
            }
            guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
            panel.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                         y: startOrigin.y + mouse.y - startMouse.y))
        case .ended:
            guard isDragging else { return }
            isDragging = false
            let screens = NSScreen.screens
            guard let index = PanelGeometry.bestScreen(for: panel.frame, screens: screens.map(\.frame)) else { return }
            let screen = screens[index]
            // Snap on: nearest corner. Off (default): exactly here, clamped to the screen.
            let newPlacement = PanelGeometry.placement(forDropped: panel.frame, in: bounds(of: screen),
                                                       screenID: PanelGeometry.screenID(screen.frame),
                                                       snap: model.settings.snapToCorners)
            placement = newPlacement
            model.settings.setPlacement(newPlacement, forLayout: layoutKey())
            sync(animated: true)
        }
    }

    // MARK: Debug snapshot

    /// Renders the panel's view hierarchy to a PNG (NEEDS_YOU_SNAPSHOT_DIR). Works without
    /// Screen Recording permission; the behind-window material renders as plain dark.
    func writeSnapshot(to url: URL) {
        guard let view = panel.contentView, panel.isVisible else { return }
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        view.bounds.fill()
        image.unlockFocus()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let composed = NSImage(size: view.bounds.size)
        composed.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        composed.unlockFocus()
        if let tiff = composed.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    // MARK: Menus

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for option in SnoozeOption.panelChoices {
            sub.addItem(ClosureMenuItem(title: option.title) { [weak model] in model?.snoozePanel(option) })
        }
        snooze.submenu = sub
        menu.addItem(snooze)
        let hide = ClosureMenuItem(title: "Hide Floating Panel") { [weak model] in model?.hidePanel() }
        if !model.canHidePanel {
            // The menu bar icon is off; hiding both would leave no way back.
            hide.isEnabled = false
            hide.toolTip = "Turn on the menu bar icon in Settings first"
        }
        menu.addItem(hide)
        menu.addItem(ClosureMenuItem(title: "Reset Position") { [weak model] in model?.resetPosition() })
        menu.addItem(.separator())

        let other = model.context.other
        menu.addItem(ClosureMenuItem(title: "Show \(other.rawValue.capitalized)") { [weak model] in model?.setContext(other) })
        menu.addItem(ClosureMenuItem(title: model.isExpanded ? "Collapse" : "Expand") { [weak model] in model?.toggleExpanded() })
        menu.addItem(ClosureMenuItem(title: "Refresh Now") { [weak model] in model?.pollNow(full: true) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak model] in model?.openSettings() })
        // A user click: one of the few places allowed to activate the app.
        menu.addItem(ClosureMenuItem(title: "About Needs You") { AboutPanel.show() })
        menu.addItem(ClosureMenuItem(title: "Quit Needs You") { NSApp.terminate(nil) })
        return menu
    }
}

/// NSMenuItem with a closure action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
