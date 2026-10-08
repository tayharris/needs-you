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
/// click-outside and Escape handling, and the expanded list's resize grip.
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
    /// The user clicked in another app while the panel stayed open: Escape belongs to that
    /// app again until the pointer comes back over the panel.
    private var escapeReleased = false

    private var placement: PanelPlacement?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false
    /// The resize grip's drag: where it began, and the list height while it runs (saved
    /// to settings.ui.expandedListHeight when it ends).
    private var resizeStartMouseY: CGFloat?
    private var resizeStartHeight: CGFloat = 0
    private var liveListHeight: CGFloat?
    private var lastDisplay: PanelDisplay?
    private var syncScheduled = false
    /// The work display the current arrival peek is on (nil: the pill's home).
    private var peekScreenID: String?

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
        container.onHover = { [weak self, weak model] inside in
            // Back over the panel after clicking elsewhere: Escape collapses it again.
            if inside { self?.escapeReleased = false }
            guard let model, model.hovering != inside else { return }
            model.hovering = inside
        }
        model.dragHandler = { [weak self] phase in self?.handleDrag(phase) }
        model.resizeHandler = { [weak self] phase in self?.handleResize(phase) }
        model.resetPositionHandler = { [weak self] in self?.resetPosition() }

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        model.settings.objectWillChange
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        model.$palette
            .sink { [weak self] palette in self?.applyPalette(palette) }
            .store(in: &cancellables)
        model.$pulse
            .compactMap { $0 }
            .sink { [weak self] request in self?.scheduleArrival(request) }
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
        // The resize grip goes on the edge away from the anchored corner.
        let gripAtBottom = ListResize.gripAtBottom(anchor: placement?.corner ?? .topRight)
        if model.listGripAtBottom != gripAtBottom { model.listGripAtBottom = gripAtBottom }
        // Arrival peeks spring out on the display you're working on (Settings → Alerts),
        // then the pill goes back home. Chosen once per peek.
        if display.isPeek {
            if !(lastDisplay?.isPeek ?? false) {
                peekScreenID = model.settings.previewDisplay == .work
                    ? WorkDisplayProbe.screen().map { PanelGeometry.screenID($0.frame) } : nil
            }
        } else {
            peekScreenID = nil
        }
        let size = panelSize(for: display)
        let target = frame(forPanelSize: size)
        let changedShape = display != lastDisplay
        lastDisplay = display
        let screenFrames = NSScreen.screens.map(\.frame)
        let changesScreen = PanelGeometry.bestScreen(for: panel.frame, screens: screenFrames)
            != PanelGeometry.bestScreen(for: target, screens: screenFrames)

        if !panel.isVisible {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animated ? fade(to: alpha(for: display)) : (panel.alphaValue = alpha(for: display))
        } else if !isDragging, panel.frame != target {
            if animated, changedShape, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || changesScreen {
                // Reduce Motion, or a jump to another display: fade between shapes instead of springing.
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
                    MainActor.assumeIsolated { self?.clickedElsewhere() }
                }
            }
            installEscape(swallow: model.expandedByUser && !escapeReleased)
        } else {
            if let monitor = clickOutsideMonitor {
                NSEvent.removeMonitor(monitor)
                clickOutsideMonitor = nil
            }
            removeEscape()
            escapeReleased = false
            endResize()
        }
    }

    /// A click in another app. With Settings → Panel → Collapse when clicking elsewhere on
    /// (the default), the panel collapses. Off it stays open, so a card can still be read
    /// next to the link it opened, and stops swallowing Escape, which belongs to the app
    /// that was clicked. Escape, the chevron and the shortcut still close it. The panel the
    /// launch opened (not the person) always closes: the person is busy elsewhere.
    private func clickedElsewhere() {
        if model.settings.ui.collapseOnClickOutside || model.openedAtLaunch {
            model.collapse()
        } else {
            escapeReleased = true
            escapeHotKey = nil
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
        } else if !swallow {
            escapeHotKey = nil
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
            // mac/README.md "Design": a faint "Nothing needs <you>" pill; on hover "all clear" and the last check.
            let text = (model.hovering ? model.idleHoverLine : model.idleRestLine) as NSString
            let width = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: m.idleFont)]).width
                + (model.isFocused ? m.idleFont - 5 : 0)   // the moon is a little wider than the dot
                + (model.focusSetByLink ? m.idleFont + 4 : 0)
            return CGSize(width: m.idleWidth(textWidth: width), height: model.hovering ? m.idleHoverHeight : m.idleHeight)
        case .waiting:
            // Settings → Panel → Collapsed pill (PillContent; the defaults are the original size).
            return model.waitingPillSize
        case .preview(let item):
            // PreviewLayout: a long title wraps to a second line, and a link button gets
            // its own row below the text instead of a column beside it.
            let font = NSFont.systemFont(ofSize: m.titleFont, weight: .semibold)
            let wrapped = (item.title as NSString).boundingRect(
                with: CGSize(width: PreviewLayout.textWidth(m), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            let lines = PreviewLayout.titleLines(wrappedHeight: wrapped,
                                                 lineHeight: NSLayoutManager().defaultLineHeight(for: font))
            return CGSize(width: m.previewWidth,
                          height: PreviewLayout.height(m, titleLines: lines, hasLink: PreviewLink.primary(item) != nil,
                                                      questionRows: QuestionDisplay.previewRows(item)))
        case .digest:
            return CGSize(width: m.previewWidth, height: m.previewHeight)
        case .expanded:
            let automatic = ListHeightPolicy.height(content: model.expandedContentHeight, cardBottoms: model.cardBottoms,
                                                    maxCards: model.settings.ui.maxVisibleCards,
                                                    cap: maxListHeight(m), minimum: m.minListHeight)
            // A height dragged with the grip wins over the automatic one (double-click resets it).
            let chosen = liveListHeight ?? CGFloat(model.settings.ui.expandedListHeight)
            let list = ListResize.listHeight(chosen: chosen, automaticHeight: { automatic },
                                             minimum: m.minListHeight, cap: maxResizedListHeight(m))
            return CGSize(width: m.expandedWidth, height: m.headerHeight + list + m.footerHeight)
        }
    }

    private func maxListHeight(_ m: PanelMetrics) -> CGFloat {
        let screenHeight = currentScreen()?.visibleFrame.height ?? 800
        return min(m.maxListHeight, screenHeight - 140)
    }

    /// The tallest list the grip can drag to: the visible screen height less the header,
    /// footer and margins (not held to the size's automatic maximum).
    private func maxResizedListHeight(_ m: PanelMetrics) -> CGFloat {
        let screenHeight = currentScreen()?.visibleFrame.height ?? 800
        return screenHeight - m.headerHeight - m.footerHeight - Self.edgeMargin * 2
    }

    private func panelSize(for display: PanelDisplay) -> CGSize {
        let s = contentSize(for: display)
        return CGSize(width: s.width + Self.glowPadding * 2, height: s.height + Self.glowPadding * 2)
    }

    private func cornerRadius(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 11 : 9
        case .waiting: return model.pillCornerRadius
        case .preview, .digest: return 14
        case .expanded: return 14
        }
    }

    private func alpha(for display: PanelDisplay) -> CGFloat {
        switch display {
        case .idle: return model.hovering ? 0.7 : (model.isConfigured ? 0.35 : 0.5)  // faint but findable; "set up" a little more
        case .waiting:
            let ui = model.settings.ui
            return CGFloat(PanelOpacity.alpha(rest: ui.pillOpacity, hover: ui.pillHoverOpacity, hovering: model.hovering))
        case .preview, .digest, .expanded:
            // Settings → Panel → Opacity; hovering always shows it at full strength.
            let ui = model.settings.ui
            return CGFloat(PanelOpacity.alpha(rest: ui.panelOpacity, hover: ui.panelHoverOpacity, hovering: model.hovering))
        }
    }

    // MARK: Placement

    private func layoutKey() -> String {
        PanelGeometry.configurationKey(NSScreen.screens.map(\.frame))
    }

    /// The saved placement for this screen layout, if the collapsed pill lies fully on its
    /// display there. Otherwise (its display isn't connected, or the spot is off the
    /// display's usable area) the pill goes to the default corner of the main display and
    /// the log says why. The saved placement is kept: a drag replaces it.
    private func loadPlacement() {
        let saved = model.settings.placement(forLayout: layoutKey())
        let screens = NSScreen.screens.map { (id: PanelGeometry.screenID($0.frame), bounds: bounds(of: $0)) }
        // The collapsed pill's size: a peek or the open list is checked as the count pill.
        let shown = model.display
        let size = panelSize(for: shown.isPeek || shown == .expanded ? .waiting : shown)
        let checked = PanelGeometry.launchPlacement(saved, size: size, screens: screens, margin: Self.edgeMargin)
        if let problem = checked.problem {
            NSLog("NeedsYou: the saved pill position isn't used because \(problem.description); the pill goes to the top right of the main display")
        }
        placement = checked.placement
    }

    /// One log line at launch: which display the pill is on and where, so "I can't see
    /// it" can be checked from the log.
    func logPlacement() {
        let screens = NSScreen.screens
        let index = PanelGeometry.bestScreen(for: panel.frame, screens: screens.map(\.frame))
        let which = index.map { $0 == 0 ? "the main display" : "display \($0 + 1) of \(screens.count)" } ?? "no display"
        let corner = placement?.corner.rawValue ?? "topRight (default)"
        NSLog("NeedsYou: pill on \(which), \(corner), frame \(NSStringFromRect(panel.frame)), visible \(panel.isVisible)")
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
        let peek = peekScreenID.flatMap { id in NSScreen.screens.first { PanelGeometry.screenID($0.frame) == id } }
        guard let screen = peek ?? currentScreen() else { return CGRect(origin: .zero, size: size) }
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
            // A peek dragged off the work display stays where it was dropped, not pulled
            // back to the work display until it ends.
            peekScreenID = nil
            sync(animated: true)
        }
    }

    /// The resize grip (ExpandedView's ResizeGrip). Like moving, it reads the pointer from
    /// NSEvent, so it works without the panel ever becoming key. The edge away from the
    /// anchored corner follows the pointer; the anchored one stays put.
    private func handleResize(_ phase: DragPhase) {
        guard model.display == .expanded else {
            // Collapsed mid-drag (Escape, the shortcut): drop the half-finished resize.
            endResize()
            return
        }
        let m = model.metrics
        let mouseY = NSEvent.mouseLocation.y
        switch phase {
        case .changed:
            if resizeStartMouseY == nil {
                resizeStartMouseY = mouseY
                resizeStartHeight = contentSize(for: .expanded).height - m.headerHeight - m.footerHeight
            }
            guard let startY = resizeStartMouseY else { return }
            let height = ListResize.dragged(start: resizeStartHeight, deltaY: mouseY - startY,
                                            gripAtBottom: model.listGripAtBottom,
                                            minimum: m.minListHeight, cap: maxResizedListHeight(m)).rounded()
            guard height != liveListHeight else { return }
            liveListHeight = height
            sync(animated: false)
        case .ended:
            guard resizeStartMouseY != nil else { return }
            resizeStartMouseY = nil
            if let height = liveListHeight {
                model.settings.ui.expandedListHeight = Double(height)
            }
            liveListHeight = nil
        }
    }

    private func endResize() {
        resizeStartMouseY = nil
        liveListHeight = nil
    }

    // MARK: Arrival motion

    /// Bounce, shake and slide (Settings → Alerts → Arrival animation) move the glass and
    /// the content together. Bounce and shake start once a preview has sprung out (the
    /// shape change takes 0.28 s), so they play on the settled shape. Glow and ripple are drawn
    /// by RootView. Nothing here touches key status or activation.
    private func scheduleArrival(_ request: PulseRequest) {
        let plan = model.arrivalPlan(request)
        guard plan.animation.movesPanel, !plan.isEmpty else { return }
        // Slide in starts at once (it is the arrival); the others wait for the spring.
        let delay = plan.animation == .slide ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.playArrival(plan)
        }
    }

    private func playArrival(_ plan: ArrivalPlan) {
        guard panel.isVisible, let layer = container.layer else { return }
        let keys = ArrivalMotion.keyframes(plan)
        guard keys.times.count > 1 else { return }
        let amp = CGFloat(plan.amplitude)
        let transforms: [NSValue] = keys.values.map { value in
            let v = CGFloat(value)
            switch plan.animation {
            case .bounce: return NSValue(caTransform3D: CATransform3DMakeTranslation(0, v * amp, 0))   // up
            case .shake: return NSValue(caTransform3D: CATransform3DMakeTranslation(v * amp, 0, 0))
            case .slide: return NSValue(caTransform3D: CATransform3DMakeTranslation(0, (1 - v) * amp, 0))
            default: return NSValue(caTransform3D: CATransform3DIdentity)
            }
        }
        let move = CAKeyframeAnimation(keyPath: "sublayerTransform")
        move.values = transforms
        move.keyTimes = keys.times.map { NSNumber(value: $0) }
        move.timingFunctions = keys.curves.map(Self.timing(for:))
        move.duration = plan.totalSeconds
        layer.add(move, forKey: "arrivalMove")
        if plan.animation == .slide {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = keys.values.map { NSNumber(value: $0) }
            fade.keyTimes = move.keyTimes
            fade.timingFunctions = move.timingFunctions
            fade.duration = plan.totalSeconds
            layer.add(fade, forKey: "arrivalFade")
        }
    }

    private static func timing(for curve: ArrivalCurve) -> CAMediaTimingFunction {
        switch curve {
        case .easeOut: return CAMediaTimingFunction(name: .easeOut)
        case .easeIn: return CAMediaTimingFunction(name: .easeIn)
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        case .linear, .instant: return CAMediaTimingFunction(name: .linear)
        }
    }

    /// Settings → Appearance → Theme: dark glass (the original) or light glass.
    private func applyPalette(_ palette: PanelPalette) {
        effect.appearance = NSAppearance(named: palette.isDark ? .vibrantDark : .vibrantLight)
        effect.material = palette.isDark ? .hudWindow : .popover
    }

    // MARK: Debug snapshot

    /// Renders the panel's view hierarchy to a PNG (NEEDS_YOU_SNAPSHOT_DIR). Works without
    /// Screen Recording permission; the behind-window material renders as plain dark (light for a light theme).
    func writeSnapshot(to url: URL) {
        guard let view = panel.contentView, panel.isVisible else { return }
        let background = model.palette.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(model.palette.surface)
        try? SnapshotImage.png(of: view, background: background)?.write(to: url)
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
        menu.addItem(FocusMenu.item(model: model))
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

/// Debug snapshots (NEEDS_YOU_SNAPSHOT_DIR): a view drawn with cacheDisplay at a fixed
/// scale (2x by default, sharp on Retina whatever the Mac's own display), optionally over
/// a solid background. No Screen Recording permission needed.
@MainActor
enum SnapshotImage {
    static func png(of view: NSView, scale: CGFloat = 2, background: NSColor? = nil) -> Data? {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        func bitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                       pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = size   // points: drawing into it is scaled up
            return rep
        }
        guard let drawn = bitmap() else { return nil }
        view.cacheDisplay(in: view.bounds, to: drawn)
        guard let background else { return drawn.representation(using: .png, properties: [:]) }
        guard let out = bitmap(), let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        background.setFill()
        rect.fill()
        drawn.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
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
