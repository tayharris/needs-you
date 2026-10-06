import AppKit
import Combine
import NeedsYouCore

/// The menu bar icon (NSStatusItem): a monochrome template pill, the open count tinted with
/// the highest priority colour, a small dot when the hub can't be reached, and a menu.
///
/// Focus rule: opening the menu or clicking its items never activates the app, except
/// Settings…, Invite a Machine… and About, which are explicit user requests for a window.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var updateScheduled = false

    init(model: AppModel) {
        self.model = model
        super.init()
        model.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        model.settings.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        model.$menuBarPulse.dropFirst().compactMap { $0 }.sink { [weak self] _ in self?.pulse() }.store(in: &cancellables)
        update()
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        // objectWillChange fires before the change lands; apply on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    // MARK: Button

    private func update() {
        guard model.settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? makeStatusItem()
        guard let button = item.button else { return }

        let unreachable = model.isConfigured && !model.isDemo && model.lastError != nil
        button.image = Self.icon(unreachable: unreachable)
        let title = MenuBarFormat.countTitle(count: model.count, showCount: model.settings.showMenuBarCount)
        if let title {
            let color = Self.color(model.highestPriority)
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .baselineOffset: 0.5,
            ])
            button.imagePosition = .imageLeading
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        button.toolTip = statusLine
        button.setAccessibilityLabel("Needs You: \(statusLine)")
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        return item
    }

    private var statusLine: String {
        MenuBarFormat.statusLine(count: model.count, userName: model.settings.userName,
                                 hub: model.activeHub ?? (model.settings.runLocalHub ? LocalHub.displayName : nil),
                                 configured: model.isConfigured,
                                 error: model.lastError, demo: model.isDemo)
    }

    /// A single brief pulse (urgent arrival while the panel is hidden). A fade, so it's
    /// fine under Reduce Motion too.
    private func pulse() {
        guard let button = statusItem?.button else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            button.animator().alphaValue = 0.25
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                button.animator().alphaValue = 1
            }
        })
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let top = MenuBarFormat.topItems(model.needsItems)
        if !top.isEmpty {
            menu.addItem(.separator())
            for item in top {
                let row = ClosureMenuItem(title: MenuBarFormat.itemTitle(item)) { [weak model] in model?.activate(item) }
                row.image = Self.dot(Self.color(item.priority))
                row.toolTip = Format.meta(item, now: now)
                menu.addItem(row)
            }
            if model.count > top.count {
                let more = ClosureMenuItem(title: "\(model.count - top.count) more…") { [weak model] in model?.showExpanded() }
                menu.addItem(more)
            }
        }

        menu.addItem(.separator())
        let show = ClosureMenuItem(title: "Show Floating Panel") { [weak model] in
            guard let model else { return }
            if !model.toggleVisibility() { NSSound.beep() }
        }
        show.state = MenuBarFormat.panelMenuChecked(visibility: model.visibility, now: now) ? .on : .off
        show.keyEquivalent = " "
        show.keyEquivalentModifierMask = [.control, .option]   // shown as a hint; ⌃⌥Space is the global hotkey
        menu.addItem(show)

        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if case .snoozed(let until) = model.visibility, until > now {
            let info = NSMenuItem(title: "Snoozed until \(AppModel.timeFormatter.string(from: until))", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(ClosureMenuItem(title: "End Snooze") { [weak model] in model?.showPanel() })
            sub.addItem(.separator())
        }
        for option in SnoozeOption.panelChoices {
            sub.addItem(ClosureMenuItem(title: option.title) { [weak model] in model?.snoozePanel(option) })
        }
        snooze.submenu = sub
        menu.addItem(snooze)
        menu.addItem(ClosureMenuItem(title: "Reset Position") { [weak model] in model?.resetPosition() })

        menu.addItem(.separator())
        for ctx in ItemContext.allCases {
            let n = model.store.needsCount(in: ctx, now: now)
            let row = ClosureMenuItem(title: ctx.rawValue.capitalized + (n > 0 ? "  \(n)" : "")) { [weak model] in model?.setContext(ctx) }
            row.state = ctx == model.context ? .on : .off
            menu.addItem(row)
        }

        menu.addItem(.separator())
        if model.settings.hasOwnerHub && !model.isDemo {
            menu.addItem(ClosureMenuItem(title: "Invite a Machine…") { [weak model] in model?.openInvite() })
        }
        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak model] in model?.openSettings() })
        menu.addItem(ClosureMenuItem(title: "About Needs You") { AboutPanel.show() })
        menu.addItem(.separator())
        // Terminating runs applicationWillTerminate, which stops the local hub cleanly.
        menu.addItem(ClosureMenuItem(title: "Quit Needs You") { NSApp.terminate(nil) })
    }

    // MARK: Images

    /// A small capsule outline (the pill), as a template image so it follows the menu bar's
    /// light/dark appearance. With `unreachable`, a subtle dot sits at the bottom right.
    static func icon(unreachable: Bool) -> NSImage {
        let key = unreachable ? 1 : 0
        if let cached = iconCache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let pill = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 5.5, width: 13, height: 7), xRadius: 3.5, yRadius: 3.5)
            pill.lineWidth = 1.5
            NSColor.black.setStroke()
            pill.stroke()
            if unreachable {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 1, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = unreachable ? "Needs You (hub unreachable)" : "Needs You"
        iconCache[key] = image
        return image
    }

    private static var iconCache: [Int: NSImage] = [:]

    static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    /// Theme's priority colours (red 400, amber 300, slate 400) as NSColor.
    static func color(_ priority: ItemPriority?) -> NSColor {
        switch priority {
        case .urgent: return NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)
        case .normal: return NSColor(srgbRed: 252 / 255, green: 211 / 255, blue: 77 / 255, alpha: 1)
        case .low, nil: return NSColor(srgbRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 1)
        }
    }
}

/// About Needs You: an explicit user request, so one of the few places that activates the app.
enum AboutPanel {
    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Needs You"])
    }
}
