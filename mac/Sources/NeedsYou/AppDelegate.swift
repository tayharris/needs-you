import AppKit
import NeedsYouCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var panel: PanelController!
    private var settingsWindow: SettingsWindowController!
    private var hotKey: HotKey?
    private var phase3: Phase3Controller?
    private var localHub: LocalHubController!
    private var connect: ConnectController!
    private var menuBar: MenuBarController!
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

        hotKey = HotKey { [weak self] in
            // Refused (a beep) when hiding would leave neither the panel nor the menu bar icon.
            Task { @MainActor in if self?.model.toggleVisibility() == false { NSSound.beep() } }
        }
        if hotKey?.isRegistered != true {
            NSLog("NeedsYou: couldn't register ⌃⌥Space (status \(hotKey?.status ?? -1)); is it bound to input-source switching?")
        }

        settingsWindow = SettingsWindowController(model: model, connect: connect, localHub: localHub) { [weak self] in
            self?.hotKey?.isRegistered ?? false
        }
        // The only path that activates the app: the user clicked Settings (or the set-up pill).
        model.openSettingsHandler = { [weak self] in self?.settingsWindow.show() }
        model.openInviteHandler = { [weak self] in self?.settingsWindow.show() }
        if let phase3 { settingsWindow.extraSettings = { phase3.settingsSection } }

        panel = PanelController(model: model)
        menuBar = MenuBarController(model: model)
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
        launched = true
        let pending = pendingURLs
        pendingURLs = []
        pending.forEach(handleOpen)

        // Focus rule: nothing here opens a window or activates the app. With no hub set
        // up, the pill shows a "set up" state; clicking it is what opens Settings.
        if let dir = ProcessInfo.processInfo.environment["NEEDS_YOU_SNAPSHOT_DIR"] {
            runSnapshotTour(into: URL(fileURLWithPath: dir))
        }
    }

    /// Debug aid: step through the main states and write a PNG of each, so the layout can
    /// be checked without Screen Recording permission.
    private func runSnapshotTour(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let steps: [(String, (AppModel) -> Void)] = [
            ("1-collapsed", { _ in }),
            ("2-expanded", { $0.expand() }),
            ("3-expanded-recent", { $0.showRecent = true }),
            ("4-personal", { $0.setContext(.personal) }),
            ("5-collapsed-again", { $0.setContext(.work); $0.collapse() }),
            ("6-preview", { model in
                let item = Item(id: "tour", key: "tour", priority: .urgent,
                                title: "ACME-4700: prod deploy check is red",
                                source: ItemSource(host: "ci", agent: "deploy-check"), createdAt: Date())
                if let announcer = model.announcer { announcer(model, [item]) } else { model.requestPulse(times: 2, priority: .urgent) }
            }),
            ("7-summary", { [weak self] model in
                model.previewItem = nil
                self?.phase3?.showSummaryNow()
            }),
        ]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for (name, action) in steps {
                action(model)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("\(name).png"))
            }
            NSLog("NeedsYou: snapshots written to \(dir.path)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
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
    private func handleOpen(_ url: URL) {
        guard url.scheme?.lowercased() == ConnectLink.scheme else { return }
        connect.connect(url.absoluteString)
        settingsWindow.show()
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
