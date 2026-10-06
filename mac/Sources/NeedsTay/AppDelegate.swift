import AppKit
import NeedsTayCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var panel: PanelController!
    private var settingsWindow: SettingsWindowController!
    private var hotKey: HotKey?
    private var phase3: Phase3Controller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        settings = AppSettings()
        model = AppModel(settings: settings)
        phase3 = Phase3Controller(model: model)   // phase 3; remove with the Phase3 folder

        hotKey = HotKey { [weak self] in
            Task { @MainActor in self?.model.toggleVisibility() }
        }
        if hotKey?.isRegistered != true {
            NSLog("NeedsTay: couldn't register ⌃⌥Space (status \(hotKey?.status ?? -1)); is it bound to input-source switching?")
        }

        settingsWindow = SettingsWindowController(model: model) { [weak self] in self?.hotKey?.isRegistered ?? false }
        model.openSettingsHandler = { [weak self] in self?.settingsWindow.show() }
        if let phase3 { settingsWindow.extraSettings = { phase3.settingsSection } }

        panel = PanelController(model: model)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.handleWake() }
        }

        model.start()

        if let dir = ProcessInfo.processInfo.environment["NEEDS_TAY_SNAPSHOT_DIR"] {
            runSnapshotTour(into: URL(fileURLWithPath: dir))
        } else if !settings.isDemo, settings.hubURL == nil {
            settingsWindow.show()
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
            ("8-settings", { [weak self] model in
                model.collapse()
                self?.settingsWindow.show()
            }),
        ]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for (name, action) in steps {
                action(model)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("\(name).png"))
            }
            NSLog("NeedsTay: snapshots written to \(dir.path)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Accessory apps have no visible menu bar, but text fields still need an Edit menu
    /// for ⌘V / ⌘C / ⌘A to work (pasting the token into Settings).
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit NeedsTay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
