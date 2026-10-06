import AppKit
import Combine
import NeedsTayCore
import SwiftUI

/// The floating panel. Non-activating, so clicking it never steals focus from the app
/// you're typing in; it only takes key status while expanded (for Escape).
final class NeedsPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // PLAN.md "Window behaviour": the part that went wrong before.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false            // dragging is handled explicitly so it can snap
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// NSHostingView that takes the first click (the panel is never key when collapsed) and
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
    private let panel = NeedsPanel()
    private let container = PanelContainerView()
    private let effect = NSVisualEffectView()
    private var hosting: PanelHostingView<RootView>!
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?

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
        panel.onCancel = { [weak model] in model?.collapse() }
        model.dragHandler = { [weak self] phase in self?.handleDrag(phase) }

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
        let now = Date()
        if model.visibility.isHidden(at: now) {
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
            if animated {
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

    private func setExpandedBehaviour(_ expanded: Bool) {
        panel.allowsKey = expanded
        if expanded {
            if !panel.isKeyWindow { panel.makeKey() }
            if clickOutsideMonitor == nil {
                // Global monitors see clicks in *other* apps; no Accessibility permission needed for mouse events.
                clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    Task { @MainActor in self?.model.collapse() }
                }
            }
        } else {
            if panel.isKeyWindow { panel.resignKey() }
            if let monitor = clickOutsideMonitor {
                NSEvent.removeMonitor(monitor)
                clickOutsideMonitor = nil
            }
        }
    }

    // MARK: Sizes (visible shape; the panel adds glow padding around it)

    private func contentSize(for display: PanelDisplay) -> CGSize {
        switch display {
        case .idle:
            // PLAN.md: 28×10 at ~10%; on hover it shows "all clear" and the last check.
            return model.hovering ? CGSize(width: 190, height: 22) : CGSize(width: 28, height: 10)
        case .waiting:
            let digits = String(model.count).count + (model.otherCount > 0 ? String(model.otherCount).count + 2 : 0)
            return CGSize(width: max(44, CGFloat(18 + digits * 8)), height: 22)
        case .preview:
            return CGSize(width: 320, height: 52)
        case .expanded:
            let header: CGFloat = 44
            let footer: CGFloat = 26
            let list = min(max(model.expandedContentHeight, 64), maxListHeight())
            return CGSize(width: 360, height: header + list + footer)
        }
    }

    private func maxListHeight() -> CGFloat {
        let screenHeight = currentScreen()?.visibleFrame.height ?? 800
        return min(520, screenHeight - 140)
    }

    private func panelSize(for display: PanelDisplay) -> CGSize {
        let s = contentSize(for: display)
        return CGSize(width: s.width + Self.glowPadding * 2, height: s.height + Self.glowPadding * 2)
    }

    private func cornerRadius(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 11 : 5
        case .waiting: return 11
        case .preview: return 14
        case .expanded: return 14
        }
    }

    private func alpha(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 0.7 : 0.10
        case .waiting: return model.hovering ? 1.0 : 0.85
        case .preview, .expanded: return 1.0
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

    private func frame(forPanelSize size: CGSize) -> CGRect {
        guard let screen = currentScreen() else { return CGRect(origin: .zero, size: size) }
        let corner = placement?.corner ?? .topRight
        return PanelGeometry.frame(size: size, corner: corner, in: screen.visibleFrame,
                                   margin: Self.edgeMargin - Self.glowPadding)
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
            let corner = PanelGeometry.nearestCorner(to: panel.frame, in: screen.visibleFrame)
            let newPlacement = PanelPlacement(corner: corner, screenID: PanelGeometry.screenID(screen.frame))
            placement = newPlacement
            model.settings.setPlacement(newPlacement, forLayout: layoutKey())
            sync(animated: true)
        }
    }

    // MARK: Debug snapshot

    /// Renders the panel's view hierarchy to a PNG (NEEDS_TAY_SNAPSHOT_DIR). Works without
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
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for option in SnoozeOption.panelChoices {
            sub.addItem(ClosureMenuItem(title: option.title) { [weak model] in model?.snoozePanel(option) })
        }
        snooze.submenu = sub
        menu.addItem(snooze)
        menu.addItem(ClosureMenuItem(title: "Hide (⌃⌥Space to show)") { [weak model] in model?.hidePanel() })
        menu.addItem(.separator())

        let other = model.context.other
        menu.addItem(ClosureMenuItem(title: "Show \(other.rawValue.capitalized)") { [weak model] in model?.setContext(other) })
        menu.addItem(ClosureMenuItem(title: model.isExpanded ? "Collapse" : "Expand") { [weak model] in model?.toggleExpanded() })
        menu.addItem(ClosureMenuItem(title: "Refresh Now") { [weak model] in model?.pollNow(full: true) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak model] in model?.openSettings() })
        menu.addItem(ClosureMenuItem(title: "Quit NeedsTay") { NSApp.terminate(nil) })
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
