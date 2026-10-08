import AppKit
import NeedsYouCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var panel: PanelController!
    private var settingsWindow: SettingsWindowController!
    private var hotKeys: HotKeyController!
    private var phase3: Phase3Controller?
    private var localHub: LocalHubController!
    private var connect: ConnectController!
    private var menuBar: MenuBarController!
    private var edgeGlow: EdgeGlowController!
    private var updates: UpdateController!
    private var termSource: DispatchSourceSignal?
    /// needsyou:// URLs that arrived before launch finished.
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        settings = AppSettings()
        model = AppModel(settings: settings)
        localHub = LocalHubController(settings: settings, model: model)
        connect = ConnectController(settings: settings, model: model)
        // Load (or mint) the local hub's owner token before the first feed is built, so
        // "this Mac" is in the hub list from the start. The hub itself starts below.
        localHub.prepareToken()
        phase3 = Phase3Controller(model: model, defaults: settings.defaults)   // phase 3; remove with the Phase3 folder

        hotKeys = HotKeyController(settings: settings) { [weak self] in
            Task { @MainActor in self?.hotKeyPressed() }
        }

        settingsWindow = SettingsWindowController(model: model, connect: connect, localHub: localHub, hotKeys: hotKeys)
        // The only path that activates the app: the user clicked Settings (or the set-up pill).
        model.openSettingsHandler = { [weak self] in self?.settingsWindow.show() }
        model.openInviteHandler = { [weak self] in self?.settingsWindow.show(tab: .connect) }
        // Setup cards: a click on a card's button (Settings may activate the app then).
        model.setupActionHandler = { [weak self] action, tip in self?.runSetup(action, tip: tip) }
        model.setupProbeHandler = { [weak self] in self?.connect.refreshAccess() }
        if let phase3 {
            settingsWindow.extraSettings = [.alerts: { phase3.scheduleSection }, .integrations: { phase3.streamSection }]
        }
        // Self-update (docs/roadmap/rollout-updates.md). Checks and installs never activate
        // the app; Settings → Updates is the only UI.
        updates = UpdateController(defaults: settings.defaults, model: model)
        let updates = self.updates!, connect = self.connect!
        settingsWindow.extraSettings[.updates] = { AnyView(UpdatesSettingsView(updates: updates, connect: connect)) }

        panel = PanelController(model: model)
        menuBar = MenuBarController(model: model)
        edgeGlow = EdgeGlowController(model: model)
        installTerminationSignal()

        // Focus-rule tripwire: activation is only legitimate right after the user opens
        // Settings. Anything else is a regression; log it loudly.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let settingsFront = NSApp.windows.contains { $0.isVisible && $0.title.hasSuffix("Settings") }
                NSLog("NeedsYou focus: app became active (settings window visible: \(settingsFront))")
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if note.object is FloatingPanel { NSLog("NeedsYou focus: REGRESSION, the panel became key") }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.handleWake()
                self?.localHub.networkMayHaveChanged()
            }
        }

        model.start()
        // Starting (and later restarting) the hub child never activates the app.
        localHub.apply()
        updates.start()
        launched = true
        let pending = pendingURLs
        pendingURLs = []
        pending.forEach(handleOpen)

        // Focus rule: nothing here opens a window or activates the app. With no hub set
        // up, the pill shows a "set up" state; clicking it is what opens Settings.
        if let dir = AppSettings.snapshotDirectory {
            runSnapshotTour(into: dir)
        }
    }

    /// Debug aid (NEEDS_YOU_SNAPSHOT_DIR): step through the main states and write a PNG of
    /// each, then some Settings pages, so the layout can be checked (and the site's
    /// screenshots made, mac/scripts/screenshots.sh) without Screen Recording permission.
    /// Nothing here activates the app or makes a window key. The Settings pages are drawn
    /// with the default look; the look settings are put back afterwards. Best run on a test
    /// copy with its own defaults suite, as screenshots.sh does.
    private func runSnapshotTour(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedUI = settings.ui
        let steps: [(String, (AppModel) -> Void)] = [
            ("1-collapsed", { _ in }),
            ("2-expanded", { $0.expand() }),
            ("3-expanded-recent", { $0.showRecent = true }),
            ("4-personal", { $0.setContext(.personal) }),
            ("5-collapsed-again", { $0.showRecent = false; $0.setContext(.work); $0.collapse() }),
            ("6-preview", { model in
                // The most urgent open item, as if it had just arrived.
                let item = model.needsItems.first { $0.priority == .urgent }
                    ?? Item(id: "tour", key: "tour", priority: .urgent,
                            title: "ACME-4700: prod deploy check is red",
                            source: ItemSource(host: "ci", agent: "deploy-check"), createdAt: Date())
                if let announcer = model.announcer { announcer(model, [item]) } else { model.requestPulse(times: 2, priority: .urgent) }
            }),
            ("6b-opened-at-card", { model in
                // Clicking a preview opens the panel scrolled to that card, outlined.
                model.previewItem = nil
                model.expand(byUser: true, focusing: model.needsItems.last?.id)
            }),
            ("6c-preview-long-title", { model in
                // A title too long for one line wraps to two (then is cut); the link
                // button keeps its own row below the text.
                model.collapse()
                model.previewItem = Item(
                    id: "tour-long", key: "tour-long", priority: .normal,
                    title: "Review the database migration plan for acme-web before the 5 pm freeze, and pick a column name",
                    links: [ItemLink(label: "Pull request", url: "https://github.com/acme/acme-web/pull/412")],
                    source: ItemSource(host: "devbox", agent: "claude-code", project: "acme-web"),
                    createdAt: Date())
            }),
            ("6d-preview-no-link", { model in
                // No allowed link: no button row, the original one-line size.
                model.previewItem = Item(
                    id: "tour-plain", key: "tour-plain", priority: .low,
                    title: "feature/old-search has 2 unpushed commits",
                    source: ItemSource(host: "devbox", agent: "cron:cleanup"), createdAt: Date())
            }),
            ("6e-preview-question", { model in
                // An agent's question arriving: the question and its first choices.
                model.previewItem = model.needsItems.first { $0.question != nil }
            }),
            ("6f-question-compact", { model in
                // Card text "First lines": the question card says "Asks: … · N choices".
                model.previewItem = nil
                model.settings.ui.cardBodies = .preview
                model.expand(byUser: true, focusing: model.needsItems.first { $0.question != nil }?.id)
            }),
            ("6g-question-all", { model in
                // Clicking the summary shows every question and choice.
                if let item = model.needsItems.first(where: { $0.question != nil }) { model.toggleCardExpanded(item) }
            }),
            ("7-summary", { [weak self] model in
                model.settings.ui.cardBodies = .full
                model.collapse()
                model.previewItem = nil
                self?.phase3?.showSummaryNow()
            }),
            ("8-pill-split", { model in
                model.collapse()
                model.settings.ui.pillSplit = .context
            }),
            ("9-pill-top-item", { model in
                model.settings.ui.pillSplit = .none
                model.settings.ui.pillDetail = .topItem
            }),
        ]
        // Settings pages, drawn as a running hub on this Mac at example addresses.
        let showcase = LocalHubReach(magicDNSName: "hub-a.example.ts.net", tailnetIP: "100.64.0.1",
                                     tailscaleInstalled: true, loopbackOnly: false, port: LocalHub.port)
        let pages: [(SettingsTab, Int)] = [(.inbox, 3), (.connect, 1), (.panel, 14)]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for (name, action) in steps {
                action(model)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("\(name).png"))
            }
            // The pages show the out-of-the-box look and alerts settings.
            model.collapse()
            settings.ui = UIPrefs()
            for (tab, shots) in pages {
                await settingsWindow.writeSnapshot(of: tab, showcase: showcase, shots: shots,
                                                   into: dir, name: "settings-\(tab.rawValue)")
            }
            settings.ui = savedUI
            NSLog("NeedsYou: snapshots written to \(dir.path)")
        }
    }

    /// The global shortcut opens the panel's card list, or collapses it when it's open. A
    /// hidden or snoozed panel comes back open. It never makes the panel key or activates
    /// this app.
    private func hotKeyPressed() {
        model.toggleExpanded()
    }

    /// A setup card's button, from a click in the panel. Open Settings is a user click, so
    /// it may activate the app. Copy agent prompt makes a sender invite through the normal
    /// invite flow and puts its prompt on the pasteboard; the card only says it was copied,
    /// never the link or the code.
    private func runSetup(_ action: SetupAction, tip: SetupTip) {
        switch action {
        case .openSettings(let page):
            settingsWindow.show(tab: SettingsTab(setupPage: page))
        case .restartLocalHub:
            // In place: no window, no activation. The card goes once the hub answers.
            model.setupNotice = SetupNotice(tip: tip, text: "Restarting the hub…", failed: false)
            localHub.restart()
        case .copyAgentPrompt:
            model.setupNotice = SetupNotice(tip: tip, text: "Creating an invite…", failed: false)
            connect.createInvite(name: SetupChecklist.inviteName, role: .sender, uses: SetupChecklist.inviteUses,
                                 ttlHours: SetupChecklist.inviteHours) { [weak self] invite in
                guard let self else { return }
                if let invite {
                    self.connect.copy(invite.agentPrompt)
                    self.model.setupNotice = SetupNotice(
                        tip: tip,
                        text: "Agent prompt copied. Paste it into Claude Code; it works once, for \(SetupChecklist.inviteHours) hours.",
                        failed: false)
                } else {
                    var reason = "Couldn't create an invite."
                    if case .failure(let message)? = self.connect.inviteStatus { reason = message }
                    self.model.setupNotice = SetupNotice(tip: tip, text: reason, failed: true)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        updates?.appWillTerminate()
        localHub?.stop()
    }

    /// SIGTERM (scripts/install.sh's fallback, `kill`) quits like the Quit menu item, so the
    /// local hub is stopped cleanly instead of being orphaned until it notices.
    private func installTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    // MARK: needsyou:// links

    /// needsyou://connect?hub=…&code=… opened from a browser, chat or Terminal (`open`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if launched { handleOpen(url) } else { pendingURLs.append(url) }
        }
    }

    /// The user clicked a connect link, so showing Settings (and activating) is allowed.
    /// An Orca terminal link opened from outside runs the Orca jump and never shows
    /// Settings; a needsyou://terminal link asks first.
    private func handleOpen(_ url: URL) {
        guard url.scheme?.lowercased() == ConnectLink.scheme else { return }
        if url.host?.lowercased() == OrcaJump.host {
            if let jump = OrcaJump.parse(url) { OrcaJumpRunner.run(jump) }
            return
        }
        if url.host?.lowercased() == TerminalJump.host {
            // needsyou://terminal/focus from outside the panel (a web page, chat, `open`).
            // A card's Terminal button is trusted; this asks first, since any page can
            // open one. The alert may activate this app (an explicit question); the jump
            // then brings the terminal forward.
            guard let jump = TerminalJump.parse(url) else {
                NSLog("NeedsYou: ignored a needsyou://terminal link that doesn't parse")
                return
            }
            let prompt = jump.confirmation
            let alert = NSAlert()
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            let ok = alert.runModal() == .alertFirstButtonReturn
            yieldActivation()
            if ok { model.run(.terminal(jump)) }
            return
        }
        if url.host?.lowercased() == FocusLink.host {
            // needsyou://focus?level=…&minutes=… from Shortcuts or a script: set the focus,
            // never show a window. Anything that doesn't parse does nothing.
            // Any web page can open one, so unless Settings → Alerts allows focus links, ask
            // first (an explicit question, so the alert may activate the app; the panel never
            // does). A link focus always ends and never holds back urgent items (FocusLink).
            guard let link = FocusLink.parse(url) else {
                NSLog("NeedsYou: ignored a needsyou://focus link that doesn't parse")
                return
            }
            if link.needsConfirmation && !settings.allowFocusLinks {
                let prompt = link.confirmation
                let alert = NSAlert()
                alert.messageText = prompt.title
                alert.informativeText = prompt.message
                alert.addButton(withTitle: "Turn On")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                let ok = alert.runModal() == .alertFirstButtonReturn
                yieldActivation()
                if ok { model.setFocus(link.state(now: Date())) }
            } else {
                model.setFocus(link.state(now: Date()))
                yieldActivation()
            }
            return
        }
        settingsWindow.show(tab: .otherHubs)
        guard let link = ConnectLink.parse(url.absoluteString) else {
            connect.connect(url.absoluteString)   // shows why the link isn't usable
            return
        }
        // Any web page can open a needsyou:// link, so ask before joining its hub.
        let prompt = link.confirmation
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { connect.connect(link) }
    }

    /// Opening a URL without `open -g` (Shortcuts' Open URLs) can make Launch Services
    /// activate this app. A focus link must not take focus from what the person is doing,
    /// so hand activation back unless the Settings window is up.
    private func yieldActivation() {
        func handBack() {
            let settingsFront = NSApp.windows.contains { $0.isVisible && $0.title.hasSuffix("Settings") }
            if NSApp.isActive && !settingsFront { NSApp.deactivate() }
        }
        handBack()
        DispatchQueue.main.async { MainActor.assumeIsolated { handBack() } }
    }

    /// Accessory apps have no visible menu bar, but text fields still need an Edit menu
    /// for ⌘V / ⌘C / ⌘A to work (pasting the token into Settings).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Needs You", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
