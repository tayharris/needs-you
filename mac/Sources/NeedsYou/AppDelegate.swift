import AppKit
import NeedsYouCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var panel: PanelController!
    private var settingsWindow: SettingsWindowController!
    private var answerWindow: AnswerWindowController!
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
    /// The launch's open-application Apple event said "launched as a login item". Read in
    /// applicationWillFinishLaunching, while that event is still the current one.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = LaunchContext.appleEventSaysLoginItem()
    }

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
        model.openSettingsPageHandler = { [weak self] page in self?.settingsWindow.show(tab: page) }
        // The other one: the user clicked "Other…" / "Answer…" on a question card, to type.
        answerWindow = AnswerWindowController(model: model)
        model.openAnswerWindowHandler = { [weak self] item, question in self?.answerWindow.show(item: item, question: question) }
        // Setup cards: a click on a card's button (Settings may activate the app then).
        model.setupActionHandler = { [weak self] action, tip in self?.runSetup(action, tip: tip) }
        model.setupProbeHandler = { [weak self] in self?.connect.refreshAccess() }
        if let phase3 {
            settingsWindow.extraSettings = [.alerts: { phase3.scheduleSection }, .integrations: { phase3.streamSection }]
        }
        // Self-update (docs/roadmap/rollout-updates.md). Checks and installs never activate
        // the app; Settings → Updates has the detail, the open panel's footer one quiet line.
        updates = UpdateController(defaults: settings.defaults, model: model)
        let updates = self.updates!, connect = self.connect!
        settingsWindow.extraSettings[.updates] = { AnyView(UpdatesSettingsView(updates: updates, connect: connect)) }

        panel = PanelController(model: model)
        menuBar = MenuBarController(model: model)
        edgeGlow = EdgeGlowController(model: model)
        installTerminationSignal()

        // Focus-rule tripwire: activation is only legitimate right after the user opens
        // Settings or clicks "Other…" for the answer window. Anything else is a regression;
        // log it loudly.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let settingsFront = NSApp.windows.contains { $0.isVisible && $0.title.hasSuffix("Settings") }
                let answerFront = NSApp.windows.contains { $0.isVisible && $0 is AnswerWindow }
                NSLog("NeedsYou focus: app became active (settings window visible: \(settingsFront), answer window visible: \(answerFront))")
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
        // After a move to Applications, the login item follows this copy (silent). A copy
        // outside Applications never touches it and shows no alert: Settings → General and
        // the menu bar menu offer Move to Applications instead.
        LoginItem.reconcileAtLaunch(location: AppMover.shared.location, defaults: settings.defaults)
        AppMover.shared.runTestMoveIfAsked()
        launched = true
        let pending = pendingURLs
        pendingURLs = []
        pending.forEach(handleOpen)

        // Focus rule: nothing here opens a window or activates the app. With no hub set
        // up, the pill shows a "set up" state; clicking it is what opens Settings.
        if let dir = AppSettings.snapshotDirectory {
            if AppSettings.formatTour { runFormatTour(into: dir) } else { runSnapshotTour(into: dir) }
        }
        openPanelIfLaunchedByPerson()
    }

    /// LaunchOpen: started by the person, the panel opens once (after the first poll, or
    /// LaunchOpen.firstPollWait at most) so they see their items and where the pill is. At
    /// login or right after an update relaunch, only the pill. Never key, never activates.
    private func openPanelIfLaunchedByPerson() {
        let attempt = updates.updatesDirectory.appendingPathComponent(UpdatePaths.attemptFile)
        let kind = LaunchOpen.kind(appleEventSaysLogin: launchedAsLoginItem,
                                   secondsSinceLogin: LaunchContext.secondsSinceConsoleLogin(),
                                   updateAttemptAge: LaunchContext.age(ofFileAt: attempt))
        let open = LaunchOpen.shouldOpen(kind: kind, settingOn: settings.openPanelAtLaunch,
                                         panelHidden: model.visibility == .hidden,
                                         snapshotTour: AppSettings.snapshotDirectory != nil)
        let sinceLogin = LaunchContext.secondsSinceConsoleLogin().map { "\(Int($0)) s" } ?? "unknown"
        NSLog("NeedsYou: launch \(kind.rawValue) (login-item event: \(launchedAsLoginItem), since console login: \(sinceLogin)); \(open ? "opening the panel once" : "pill only")")
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(LaunchOpen.firstPollWait)
            while open, let model = self?.model, model.lastCheck == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self else { return }
            if open { self.model.openAtLaunch() }
            // Once the panel has its new shape (the sync runs on the next turn).
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.panel.logPlacement()
            // Debug aid (NEEDS_YOU_LAUNCH_SNAPSHOT_DIR, mac/scripts/launch-test.sh): the panel
            // just after launch and once the launch open has closed by itself.
            if let dir = AppSettings.launchSnapshotDirectory {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.panel.writeSnapshot(to: dir.appendingPathComponent("launch-1-open.png"))
                try? await Task.sleep(nanoseconds: UInt64(LaunchOpen.seconds + 3) * 1_000_000_000)
                self.panel.writeSnapshot(to: dir.appendingPathComponent("launch-2-after.png"))
                self.panel.logPlacement()
            }
        }
    }

    /// Debug aid (NEEDS_YOU_SNAPSHOT_DIR): step through the main states and write a PNG of
    /// each, then some Settings pages, so the layout can be checked (and the site's
    /// screenshots made, mac/scripts/screenshots.sh) without Screen Recording permission.
    /// Nothing here activates the app or makes a window key. The Settings pages are drawn
    /// with the default look; the look settings are put back afterwards. Best run on a test
    /// copy with its own defaults suite, as screenshots.sh does.
    private static let tourTypedAnswer = "accounts_v2, to match the API naming"

    /// The tour's Claude card that takes typed words (screenshots.sh), until it's answered.
    private static func tourOtherItem(_ model: AppModel) -> Item? {
        model.needsItems.first { $0.key.hasPrefix("claude") && $0.answer == nil && $0.question?.answerable == true
            && $0.question?.items.first?.allowOther == true }
    }

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
            ("6h-question-picked", { model in
                // An answerable question: options are buttons; picks wait for Send.
                guard let item = model.needsItems.first(where: { $0.question?.answerable == true }),
                      let q = item.question else { return }
                model.settings.ui.cardBodies = .full  // every option shown, as by default
                model.scrollTarget = item.id  // the whole card, Send included, in view
                for (i, qi) in q.items.enumerated() {
                    if let label = qi.options.first?.label { model.pickOption(item, question: i, label: label) }
                    if qi.multiSelect, qi.options.count > 1 { model.pickOption(item, question: i, label: qi.options[1].label) }
                }
            }),
            ("6i-question-answered", { model in
                // Send: the demo feed takes it like a hub, and the card shows the answer.
                if let item = model.needsItems.first(where: { $0.question?.answerable == true }) {
                    model.sendPickedAnswer(item)
                    model.scrollTarget = item.id
                }
            }),
            ("6j-question-other", { model in
                // A question whose agent takes typed words: "Other…" below its options.
                if let item = Self.tourOtherItem(model) {
                    model.scrollTarget = item.id
                }
            }),
            ("6l-question-other-sent", { model in
                // Send in the answer window (6k): the words are the answer, shown on the card.
                if let item = Self.tourOtherItem(model) {
                    _ = model.submitTypedAnswer(itemID: item.id, question: 0, text: Self.tourTypedAnswer,
                                                seenVersion: item.contentUpdatedAtRaw)
                    model.scrollTarget = item.id
                }
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
            // Settings → Appearance: a few themes on the open panel and the pill.
            ("10-theme-midnight", { model in
                model.settings.ui.pillDetail = .count
                model.settings.ui.theme = .midnight
                model.expand()
            }),
            ("11-theme-paper", { $0.settings.ui.theme = .paper }),
            ("12-theme-high-contrast", { $0.settings.ui.theme = .highContrast }),
            ("13-theme-sunset-pill", { model in
                model.collapse()
                model.settings.ui.theme = .sunset
            }),
            // Settings → Alerts → Preview on the pill: a sample urgent item arriving.
            ("14-arrival-preview", { model in
                model.settings.ui.theme = .standard
                model.previewArrival(.urgent)
            }),
            // Usage meters (DemoFeed.statusFixture): the panel's section, then the pill's meters.
            ("15-usage-panel", { model in
                model.previewItem = nil
                model.expand()
                model.scrollTarget = nil
            }),
            // The pill's meter styles (Settings → Usage → On the pill) at an everyday 31 % / 10 %:
            // the waiting pill, then the idle one (nothing waiting).
            ("16-usage-pill", { model in
                model.collapse()
                Task { await model.applyDemoStatuses(DemoFeed.quietUsageFixture()) }
            }),
            ("16b-usage-pill-thin", { $0.settings.usage.pillStyle = .thin }),
            ("16c-usage-pill-percent", { $0.settings.usage.pillStyle = .percent }),
            ("16d-usage-pill-warning", { model in
                model.settings.usage.pillStyle = .bars
                Task { await model.applyDemoStatuses(DemoFeed.statusFixture()) }
            }),
            ("16e-usage-idle", { model in
                Task {
                    await model.applyDemoStatuses(DemoFeed.quietUsageFixture())
                    await model.applyDemoOpenSet([])
                }
            }),
            ("16f-usage-idle-thin", { $0.settings.usage.pillStyle = .thin }),
            ("16g-usage-idle-percent", { $0.settings.usage.pillStyle = .percent }),
            ("16h-usage-off", { model in
                model.settings.usage.pillStyle = .bars
                model.settings.usage.onPill = false
            }),
        ]
        // Settings pages, drawn as a running hub on this Mac at example addresses.
        let showcase = LocalHubReach(magicDNSName: "hub-a.example.ts.net", tailnetIP: "100.64.0.1",
                                     tailscaleInstalled: true, loopbackOnly: false, port: LocalHub.port)
        let pages: [(SettingsTab, Int)] = [(.inbox, 3), (.connect, 1), (.panel, 14), (.appearance, 2), (.alerts, 3), (.usage, 1)]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for (name, action) in steps {
                action(model)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("\(name).png"))
                // Progress for screenshots.sh, so a slow run shows where it got to.
                NSLog("NeedsYou: snapshot \(name)")
                if name == "6j-question-other",
                   let item = Self.tourOtherItem(model) {
                    // The answer window "Other…" opens, with words typed (drawn offscreen).
                    await answerWindow.writeSnapshot(item: item, question: 0, text: Self.tourTypedAnswer,
                                                     to: dir.appendingPathComponent("6k-answer-window.png"))
                }
            }
            // The pages show the out-of-the-box look and alerts settings.
            model.collapse()
            settings.ui = UIPrefs()
            settings.usage = UsagePrefs()
            for (tab, shots) in pages {
                await settingsWindow.writeSnapshot(of: tab, showcase: showcase, shots: shots,
                                                   into: dir, name: "settings-\(tab.rawValue)")
            }
            // The Appearance sample in a light and a colourful theme: the desktop stays put.
            for theme in [PanelTheme.paper, .sunset] {
                settings.ui.theme = theme
                await settingsWindow.writeSnapshot(of: .appearance, showcase: showcase, shots: 2,
                                                   into: dir, name: "settings-appearance-\(theme.rawValue)")
            }
            settings.ui = savedUI
            NSLog("NeedsYou: snapshots written to \(dir.path)")
        }
    }

    /// Debug aid (NEEDS_YOU_SNAPSHOT_TOUR=formats, mac/scripts/screenshots.sh): every demo
    /// card (tests/format_cases.py, through a hub) on its own, in each card text mode, and
    /// its arrival preview; then picks and answers on the answerable questions, a ticked
    /// step, and the cards again after NEEDS_YOU_DEMO_REPOST's re-posts under their keys.
    /// Files are named after the item's key: `fmt:05-body-max` draws `05-body-max-full.png`.
    private func runFormatTour(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedUI = settings.ui
        func name(_ item: Item) -> String {
            String(item.key.split(separator: ":").last ?? Substring(item.id))
        }
        func items() -> [Item] { model.store.items.values.sorted { $0.key < $1.key } }
        func card(_ item: Item, _ suffix: String) async {
            guard let current = model.store.items[item.id] else { return }
            await CardSnapshot.write(current, model: model, to: dir.appendingPathComponent("\(name(item))-\(suffix).png"))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let before = items()
            for mode in CardBodyMode.allCases {
                settings.ui.cardBodies = mode
                for item in before { await card(item, mode.rawValue) }
            }
            settings.ui.cardBodies = .full
            for item in before where item.kind == .needs {
                // The pill, not the open panel (the morning summary may have opened it).
                model.collapse()
                if item.context != model.context { model.setContext(item.context) }
                model.previewItem = item
                try? await Task.sleep(nanoseconds: 900_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("\(name(item))-arrival.png"))
            }
            model.previewItem = nil
            model.setContext(.work)

            // What the person does before the senders re-post: picks, answers, a tick.
            for item in before {
                // Typed-only questions (no options) are answered in the answer window, not by a click.
                guard let q = item.question, q.answerable, q.items.allSatisfy({ !$0.options.isEmpty }) else { continue }
                if AnswerPolicy.sendsOnClick(q) {
                    model.pickOption(item, question: 0, label: q.items[0].options[0].label)
                } else {
                    for (i, qi) in q.items.enumerated() {
                        model.pickOption(item, question: i, label: qi.options[0].label)
                        if qi.multiSelect, qi.options.count > 1 { model.pickOption(item, question: i, label: qi.options[1].label) }
                    }
                    await card(item, "picked")
                    model.sendPickedAnswer(item)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await card(item, "answered")
            }
            if let steps = before.first(where: { $0.steps.count > 2 }) { model.toggleStep(steps, 2) }

            if let url = AppSettings.demoRepostURL, let reposts = try? DemoFeed.loadFixture(at: url) {
                await model.applyDemoRepost(reposts)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
                for item in reposts where old[item.id].map({ $0.updatedAt != item.updatedAt }) ?? true {
                    await card(item, "reposted")
                }
            }
            // The header with 9, 12 and 128 open work items in each panel size (the title must
            // stay whole), and the footer's update lines.
            model.previewItem = nil
            for n in [9, 12, 128] {
                let now = Date()
                var open = (0..<n).map { i in
                    Item(id: String(format: "01HEAD%05d%015d", n, i), key: "header:\(n):\(i)", title: "Header check \(i + 1) of \(n)",
                         source: ItemSource(host: "devbox", agent: "format-tour"), createdAt: now)
                }
                open.append(Item(id: String(format: "01HEADP%05d%014d", n, 0), key: "header:\(n):personal", context: .personal,
                                 title: "A personal item", createdAt: now))
                await model.applyDemoOpenSet(open)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                for size in PanelSize.allCases {
                    settings.ui.panelSize = size
                    model.expand()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    panel.writeSnapshot(to: dir.appendingPathComponent("header-\(n)-\(size.rawValue).png"))
                }
                settings.ui.panelSize = savedUI.panelSize
            }
            let footers = [("available", UpdateFooter(text: "Update available: 0.3.0 \u{2192} 0.3.1", failed: false, available: true)),
                           ("installed", UpdateFooter(text: "Updated to 0.3.1", failed: false)),
                           ("rolled-back", UpdateFooter(text: "Update failed \u{2014} rolled back to 0.3.0", failed: true))]
            for (name, line) in footers {
                model.updateFooter = line
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                panel.writeSnapshot(to: dir.appendingPathComponent("footer-update-\(name).png"))
            }
            model.updateFooter = nil
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
        // Only a connect link may show Settings (and so activate the app). Any other
        // needsyou:// host does nothing: a web page must not be able to take focus with one.
        guard url.host?.lowercased() == "connect" else {
            NSLog("NeedsYou: ignored a needsyou:// link with an unknown host")
            yieldActivation()
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
            let settingsFront = NSApp.windows.contains {
                $0.isVisible && ($0.title.hasSuffix("Settings") || $0 is AnswerWindow)
            }
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
