import AppKit
import NeedsYouCore
import ServiceManagement
import SwiftUI

/// The Settings window: a sidebar of short pages, like System Settings. General; the
/// "Inbox and machines" group (Your inbox, Connect a machine, Machines, Other hubs
/// (advanced)); then Panel, Alerts, Integrations, Updates and Advanced. The page list is `SettingsTab` in Core
/// (SettingsPages.swift). Each page is a grouped form that scrolls.
///
/// Focus rule: `show()` is the ONLY place the app activates or makes a window key, and it
/// is only called from an explicit user action (the Settings menu item / gear button,
/// clicking the "set up" pill, or opening a needsyou:// connect link). Never call it from
/// a timer, poll, hub restart or launch path.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel
    private let connect: ConnectController
    private let localHub: LocalHubController
    private let hotKeys: HotKeyController
    private let navigation = SettingsNavigation()
    /// Extra Settings sections per page (phase 3 adds its schedule and stream options;
    /// Updates is filled entirely this way).
    var extraSettings: [SettingsTab: () -> AnyView] = [:]

    init(model: AppModel, connect: ConnectController, localHub: LocalHubController, hotKeys: HotKeyController) {
        self.model = model
        self.connect = connect
        self.localHub = localHub
        self.hotKeys = hotKeys
    }

    /// Smallest window: the sidebar plus a page narrow enough for a 13" laptop.
    static let minSize = NSSize(width: 640, height: 420)
    /// First-open size, shrunk to fit short screens.
    static let preferredSize = NSSize(width: 760, height: 520)

    /// `tab` switches to that page (Connect a Machine… opens `.connect`, connect links open
    /// `.otherHubs`, setup cards open `.inbox`); nil keeps the last one.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        navigation.shown += 1
        if window == nil {
            let view = SettingsView(model: model, settings: model.settings, connect: connect, localHub: localHub,
                                    hotKeys: hotKeys, navigation: navigation, extra: extraSettings.mapValues { $0() },
                                    close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Needs You Settings"   // AppDelegate's focus checks look for the "Settings" suffix
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(Self.fittingSize(on: NSScreen.main))
            w.contentMinSize = Self.minSize
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        // User-initiated only (see above): an accessory app has to activate to bring a
        // normal window to the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Debug snapshot

    /// Debug aid (NEEDS_YOU_SNAPSHOT_DIR): renders one page to PNGs, `<name>.png` for the
    /// top and `<name>-2.png`, `-3`… scrolled down half a screen at a time (up to `shots`).
    /// The window is fully transparent and ignores the mouse: nobody sees it, it never
    /// becomes key and the app isn't activated, so it follows the focus rule. Uses
    /// cacheDisplay, so no Screen Recording permission. `showcase` draws the hub on this
    /// Mac as running (see SettingsView.showcase); the real Settings window is untouched.
    func writeSnapshot(of tab: SettingsTab, showcase: LocalHubReach, shots: Int = 1,
                       into dir: URL, name: String) async {
        let navigation = SettingsNavigation()
        navigation.tab = tab
        let view = SettingsView(model: model, settings: model.settings, connect: connect, localHub: localHub,
                                hotKeys: hotKeys, navigation: navigation, extra: extraSettings.mapValues { $0() },
                                close: {}, showcase: showcase)
        // Drawn like the front window (it never is one: it isn't key).
        let w = NSWindow(contentViewController: NSHostingController(rootView: view.environment(\.controlActiveState, .key)))
        w.title = "Needs You Settings"
        w.styleMask = [.titled, .closable, .resizable]
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setContentSize(Self.preferredSize)
        w.orderFrontRegardless()   // never key, never activates: alpha 0 and no mouse
        defer { w.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // The whole window, title bar included (the theme frame), else just the content.
        guard let content = w.contentView else { return }
        let frameView = content.superview ?? content
        let scroll = Self.firstScrollView(in: content)
        for screen in 0..<max(1, shots) {
            if screen > 0 {
                guard let scroll, let doc = scroll.documentView else { break }
                let visible = scroll.contentView.bounds.height
                let maxY = max(0, doc.frame.height - visible)
                let y = min(maxY, CGFloat(screen) * (visible / 2).rounded())
                if y <= scroll.contentView.bounds.origin.y { break }   // already at the bottom
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            frameView.layoutSubtreeIfNeeded()
            let file = screen == 0 ? "\(name).png" : "\(name)-\(screen + 1).png"
            try? SnapshotImage.png(of: frameView)?.write(to: dir.appendingPathComponent(file))
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView,
           doc.frame.height > scroll.contentView.bounds.height + 1 {
            return scroll
        }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// The preferred size, but never taller or wider than the screen's usable area (less a
    /// margin), and never below the minimum.
    private static func fittingSize(on screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame.size else { return preferredSize }
        return NSSize(width: max(minSize.width, min(preferredSize.width, visible.width - 80)),
                      height: max(minSize.height, min(preferredSize.height, visible.height - 80)))
    }
}

/// Which page is showing, so menu items and links can open a given one.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
    /// Bumped every time the window is shown, so a page can react to being opened again
    /// (Other hubs looks at the clipboard for a join link).
    @Published var shown = 0
}

/// One editable hub row.
private struct HubRow: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var tokenDraft = ""
    var hasToken = false
    var role: HubRole?
    var status: String?
}

/// What the Machines page's confirmation alert is about.
private enum PendingRevoke: Equatable {
    case invite(InviteSummary)
    case token(TokenSummary)

    var title: String {
        switch self {
        case .invite(let invite): return "Revoke invite “\(invite.name)”?"
        case .token(let token): return "Revoke “\(token.name)”?"
        }
    }

    var message: String {
        switch self {
        case .invite: return "Its link stops working. Machines it already set up keep their tokens."
        case .token: return "That machine can no longer post. Its open items stay until resolved or dismissed. This can't be undone; it needs a new invite to reconnect."
        }
    }
}

/// Invite expiry choices.
private enum InviteExpiry: Int, CaseIterable, Identifiable {
    case hour = 1, day = 24, week = 168, month = 720
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .hour: return "1 hour"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var connect: ConnectController
    @ObservedObject var localHub: LocalHubController
    @ObservedObject var hotKeys: HotKeyController
    @ObservedObject var navigation: SettingsNavigation
    var extra: [SettingsTab: AnyView] = [:]
    var close: () -> Void
    /// Snapshot tour only (NEEDS_YOU_SNAPSHOT_DIR): draw the pages as if the hub on this
    /// Mac were running at these addresses, even in demo mode. Never set in a real window.
    var showcase: LocalHubReach? = nil

    @State private var rows: [HubRow] = []
    @State private var message: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var linkDraft = ""
    @State private var inviteName = ""
    @State private var inviteRole: HubRole = .sender
    @State private var inviteUses = 1
    @State private var inviteExpiry: InviteExpiry = .day
    @State private var visibilityMessage: String?
    @State private var pendingRevoke: PendingRevoke?
    @State private var automationStatus: String?
    /// Other hubs → Join: "Found a link on your clipboard", or why Paste did nothing.
    @State private var clipboardNote: String?
    @State private var pasteProblem: String?
    /// The pasteboard's changeCount when Other hubs last looked, so the same clipboard is
    /// offered once, not every time the page shows.
    @State private var clipboardChangeCount = -1

    /// Only when nothing works out of the box (the local hub is off and no hubs are set).
    private var isFirstRun: Bool { !settings.hasHubs && !settings.isDemo && showcase == nil }

    /// Demo mode, as the pages describe it (a showcase snapshot draws a real inbox).
    private var demoUI: Bool { settings.isDemo && showcase == nil }

    /// An owner token (the local hub gives one) and not in demo mode.
    private var canInvite: Bool { showcase != nil || (connect.canInvite && !settings.isDemo) }

    /// The page to show (Machines falls back to Connect a machine without an owner token).
    private var page: SettingsTab { navigation.tab.resolved(canInvite: canInvite) }

    var body: some View {
        // The sidebar can't be collapsed: there's no toolbar button to bring it back.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: SettingsWindowController.minSize.width, idealWidth: SettingsWindowController.preferredSize.width,
               minHeight: SettingsWindowController.minSize.height, idealHeight: SettingsWindowController.preferredSize.height)
        .onAppear(perform: load)
        .onChange(of: settings.hubURLStrings) { _, _ in load() }
    }

    private var sidebar: some View {
        List(selection: Binding<SettingsTab?>(
            get: { page },
            set: { if let tab = $0 { navigation.tab = tab } }
        )) {
            ForEach(SettingsSidebarGroup.allCases) { group in
                Section {
                    ForEach(group.pages(canInvite: canInvite), id: \.self) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    /// The page's title and one-line summary, then its grouped form, which scrolls.
    private var detail: some View {
        // The header is the form's first row, so it scrolls with the page and is never
        // clipped under the title bar.
        Form {
            Section {
                SettingsPageHeader(tab: page)
            }
            pageContent(page)
        }
        .formStyle(.grouped)
        .id(page)   // each page starts scrolled to the top
    }

    /// Each page's sections, in order. `extra[page]` is where the app delegate plugs in
    /// sections from elsewhere (phase 3, Updates).
    @ViewBuilder
    private func pageContent(_ page: SettingsTab) -> some View {
        switch page {
        case .general:
            if isFirstRun { welcome }
            youSection
            startupSection
            demoSection
            extra[.general]
        case .inbox:
            howItWorksSection
            thisMacSection
            if let reach = runningReach {
                addressesSection(reach)
            }
            extra[.inbox]
        case .connect:
            if canInvite {
                if let warning = inviteReachWarning { inviteWarningSection(warning) }
                inviteSection
            } else {
                inviteUnavailableSection
            }
            extra[.connect]
        case .machines:
            machinesSection
            openInvitesSection
            extra[.machines]
        case .otherHubs:
            otherHubsIntroSection
            connectSection
            linkSourcesSection
            serverHubsSection
            hubsSection
            extra[.otherHubs]
        case .panel:
            lookSection
            PillSettingsSection(settings: settings)
            visibilitySection
            OpenPanelSettingsSection(settings: settings)
            OpacitySettingsSection(settings: settings)
            SetupTipsSettingsSection(settings: settings)
            keyboardSection
            extra[.panel]
        case .alerts:
            alertStyleSection
            ArrivalSettingsSection(settings: settings)
            DeliverySection(settings: settings)
            breakthroughSection
            BypassRulesSection(settings: settings)
            WorkScreenSection(settings: settings)
            extra[.alerts]
        case .integrations:
            terminalJumpSection
            extra[.integrations]
            sendersSection
        case .updates:
            // Filled by the app delegate (UpdatesSettingsView).
            if let updates = extra[.updates] {
                updates
            } else {
                Section { Text("Updates aren't available in this build.").foregroundStyle(.secondary) }
            }
        case .advanced:
            advancedSection
            extra[.advanced]
        }
    }

    private var localHubRunning: Bool {
        if case .running = localHub.state { return true }
        return false
    }

    /// The running local hub's addresses (the showcase's in a snapshot), or nil.
    private var runningReach: LocalHubReach? {
        if let showcase { return showcase }
        return settings.runLocalHub && !settings.isDemo && localHubRunning ? localHub.reach : nil
    }

    private var hubState: LocalHubController.State {
        showcase.map { .running(publicURL: $0.tailnetURL ?? $0.localURL) } ?? localHub.state
    }

    // MARK: General

    private var welcome: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Needs You").font(.headline)
                Text("Needs You shows what your machines, projects and agents need from you, in a small floating pill. It stays out of the way until something is waiting.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("To start, pick one. You can change it later in Your inbox.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use this Mac as my inbox") {
                        settings.runLocalHub = true
                        localHub.apply()
                        model.restartFeed()
                        navigation.tab = .inbox
                    }
                    Button("Join another hub with a link") { navigation.tab = .otherHubs }
                    Button("Try demo mode") {
                        settings.demoMode = true
                        localHub.apply()
                        model.restartFeed()
                        close()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var startupSection: some View {
        Section {
            Toggle(isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) })) {
                LabelWithDetail("Open at login", "Starts Needs You when you log in. Move the app to /Applications first.")
            }
            if let loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Startup")
        }
    }

    private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.demoMode },
                set: { settings.demoMode = $0; localHub.apply(); model.restartFeed() }
            )) {
                LabelWithDetail("Demo mode", "Shows sample items, with a new one now and then. No hub runs, so real alerts don't arrive.")
            }
            .disabled(settings.demoForcedByEnvironment)
            if settings.demoForcedByEnvironment {
                Text("Demo mode is on via NEEDS_YOU_DEMO=1.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Demo")
        }
    }

    // MARK: Your inbox

    /// Three lines on what the parts are, at the top of Your inbox.
    private var howItWorksSection: some View {
        Section {
            HowItWorksStep(symbol: "paperplane", text: "Your machines and agents send alerts.")
            HowItWorksStep(symbol: "tray.full", text: "This Mac holds them. It's the hub: it runs inside this app, nothing else to install.")
            HowItWorksStep(symbol: "capsule", text: "The pill shows them until they're handled.")
        } header: {
            Text("How it works")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Machines that only send alerts (servers, CI, agents) don't need this app, just the `needs-you` command. A link from Connect a machine installs it.")
                Link("What the words mean", destination: SettingsLinks.wordsGuide())
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var thisMacSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.runLocalHub },
                set: { on in
                    settings.runLocalHub = on
                    localHub.apply()
                    model.restartFeed()
                }
            )) {
                LabelWithDetail("Run hub on this Mac", "Your agents and servers send alerts to it. Nothing else to install.")
            }
            .disabled(demoUI)
            if demoUI {
                Text("Demo mode is on, so the hub isn't running. Turn demo mode off in General.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if settings.runLocalHub {
                switch hubState {
                case .off:
                    EmptyView()
                case .starting:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Starting…").font(.caption).foregroundStyle(.secondary)
                    }
                case .running:
                    Label("Running", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed(let text):
                    Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Off. To get alerts without it, join another hub in Other hubs (advanced).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Hub on this Mac")
        } footer: {
            Text("The hub only listens on this Mac (127.0.0.1) and on its Tailscale address, never on the open network. Its items are kept in ~/Library/Application Support/NeedsYou/hub.db.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Both addresses of the running hub, each with Copy; or why other machines can't
    /// reach it.
    private func addressesSection(_ reach: LocalHubReach) -> some View {
        Section {
            AddressRow(title: "On this Mac", url: reach.localURL,
                       detail: "For agents and scripts running on this Mac.")
            if let tailnet = reach.tailnetURL {
                AddressRow(title: "From your other machines (Tailscale)", url: tailnet, detail: reach.note)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Other machines can't reach this hub", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reach.note)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if reach.tailscale != .loopbackOnly {
                        Link("Tailscale setup guide", destination: LocalHubReach.tailscaleGuideURL)
                            .font(.caption)
                    }
                }
            }
            if canInvite {
                HStack {
                    Text("To connect a server, an agent or another Mac, make a link for it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Connect a machine…") { navigation.tab = .connect }
                }
            }
        } header: {
            Text("Addresses")
        } footer: {
            Text("Links from Connect a machine already contain the right address, so you rarely need to copy these by hand.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Other hubs (advanced)

    private var otherHubsIntroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("You don't need anything here: Your inbox already runs a hub on this Mac. Use this page only to:")
                Text("• **Join another hub:** see alerts from a hub another Mac or a server runs, with a link made for this Mac.")
                Text("• **Add an always-on server hub,** so alerts land somewhere while this Mac sleeps.")
                Text("• **Add a hub by URL and token,** if you were given those instead of a link.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serverHubsSection: some View {
        Section {
            Text("A server hub is the same hub, running all the time on a Linux server or VM on your tailnet. It keeps a copy of your alerts while this Mac sleeps, and senders fall back to it. There's no app screen for it: you set it up on the server from the command line with `scripts/install-hub.sh`, then join it here with a link from its admin.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Link("Server hub guide (HUB.md)", destination: SettingsLinks.serverHubGuide())
                .font(.callout)
        } header: {
            Text("Always-on server hubs")
        } footer: {
            Text("Optional. Most people never need one: senders queue alerts while this Mac sleeps and deliver them when it wakes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectSection: some View {
        Section {
            Text("Use this on the Mac that should show the alerts. Paste a link that was made for this Mac, then press Join.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Link", text: $linkDraft, prompt: Text("needsyou://connect?… or http://…/join/…"))
                    .labelsHidden()
                    .onSubmit(connectWithLink)
                Button("Paste", action: pasteLink)
                    .help("Paste a join link from the clipboard")
                Button("Join", action: connectWithLink)
                    .disabled(linkDraft.trimmingCharacters(in: .whitespaces).isEmpty || isWorking(connect.status))
            }
            if let clipboardNote {
                Label(clipboardNote, systemImage: "doc.on.clipboard").font(.caption).foregroundStyle(.secondary)
            }
            if let pasteProblem {
                Text(pasteProblem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            statusText(connect.status)
        } header: {
            Text("Join a hub with a link")
        } footer: {
            Text("Needs You asks that hub for a token, saves it, and adds the hub to your list. Its items then show in your panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: offerClipboardLink)
        .onChange(of: navigation.shown) { _, _ in offerClipboardLink() }
        .onChange(of: connect.lastLink) { _, link in
            // Joined (pasted, or opened as a needsyou:// link): don't leave it in the field.
            if let link, ConnectLink.parse(linkDraft) == link {
                linkDraft = ""
                clipboardNote = nil
            }
        }
    }

    private var linkSourcesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("**From another Mac:** on that Mac, open Settings → Connect a machine, pick “Another Mac that shows the same alerts”, press Create invite, then Mac link to copy it. Send it to yourself and paste it here.")
                Text("**From a server hub:** its admin runs `needs-you-admin invite create my-mac --role owner` and sends you the link it prints. (`--role reader` if this Mac shouldn't connect other machines.)")
                Text("**Clicked a needsyou://connect link?** Then there's nothing to paste: Needs You opens this page, asks first, and joins by itself.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if canInvite {
                HStack {
                    Text("Want another machine to send alerts to this Mac instead? Make a link for it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Connect a machine…") { navigation.tab = .connect }
                }
            }
        } header: {
            Text("Where links come from")
        } footer: {
            Text("A link works a set number of times, then expires. Links use a Tailscale name (…ts.net) or https://. Plain http:// only works over Tailscale or on your local network.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Connect a machine

    private var inviteSection: some View {
        Section {
            Picker(selection: $inviteRole) {
                ForEach([HubRole.sender, .reader, .owner], id: \.self) { role in
                    Text(role.connectTitle).tag(role)
                }
            } label: {
                LabelWithDetail("What is it?", inviteRole.connectDetail)
            }
            .pickerStyle(.radioGroup)
            TextField("Machine name", text: $inviteName, prompt: Text("devbox"))
            Stepper("Uses: \(inviteUses)", value: $inviteUses, in: InviteRequest.usesRange)
            Picker("Expires after", selection: $inviteExpiry) {
                ForEach(InviteExpiry.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Spacer()
                Button("Create invite") {
                    connect.createInvite(name: inviteName, role: inviteRole, uses: inviteUses, ttlHours: inviteExpiry.rawValue)
                }
                .disabled(isWorking(connect.inviteStatus))
            }
            statusText(connect.inviteStatus)
            if let invite = connect.invite {
                VStack(alignment: .leading, spacing: 6) {
                    Text(invite.joinURL).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        copyButton("Agent prompt", invite.agentPrompt)
                        copyButton("Shell one-liner", invite.shellOneLiner)
                        if connect.inviteRole != .sender, let mac = invite.macURL {
                            copyButton("Mac link", mac)
                        }
                    }
                }
            }
        } header: {
            Text("New invite")
        } footer: {
            Text("Then, on the new machine: paste the agent prompt into Claude Code (or another agent), or run the shell one-liner in a terminal. For another Mac, open the Mac link there, or paste it into its Settings → Other hubs (advanced).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Links from this Mac's hub carry its address; without Tailscale that's 127.0.0.1.
    private var inviteReachWarning: String? {
        guard showcase == nil, settings.runLocalHub, !settings.isDemo, let reach = localHub.reach,
              !reach.reachableFromOtherMachines else { return nil }
        return "This Mac isn't on Tailscale, so links made here point at 127.0.0.1 and only work on this Mac."
    }

    private func inviteWarningSection(_ warning: String) -> some View {
        Section {
            HStack(alignment: .top) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Your inbox…") { navigation.tab = .inbox }
            }
        }
    }

    private var inviteUnavailableSection: some View {
        Section {
            if settings.isDemo {
                Text("Demo mode is on, so there's no inbox to connect machines to. Turn demo mode off in General.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connecting machines needs an owner token. The hub on this Mac gives you one: turn on “Run hub on this Mac” in Your inbox.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("To connect machines to someone else's hub, ask its owner for an owner link, then join with it in Other hubs.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Your inbox…") { navigation.tab = .inbox }
                    Button("Other hubs…") { navigation.tab = .otherHubs }
                }
            }
        } header: {
            Text("Not available yet")
        }
    }

    // MARK: Machines

    private var machinesSection: some View {
        Section {
            HStack {
                Text("Machines that can use your inbox, with what they are and their open items.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Refresh") { connect.refreshAccess() }
                    .disabled(isWorking(connect.accessStatus))
            }
            if connect.accessTokens.isEmpty {
                Text("Press Refresh to list them.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(connect.accessTokens) { token in
                MachineRow(token: token, connect: connect) { pendingRevoke = .token(token) }
            }
            statusText(connect.accessStatus)
        } header: {
            Text("Connected machines")
        } footer: {
            Text("Revoke a machine to stop it from using your inbox. Its open items stay until they're resolved or dismissed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { connect.refreshAccess() }
        .alert(pendingRevoke?.title ?? "", isPresented: Binding(
            get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }
        ), presenting: pendingRevoke) { item in
            Button("Revoke", role: .destructive) {
                switch item {
                case .invite(let invite): connect.revoke(invite)
                case .token(let token): connect.revoke(token)
                }
                pendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: { item in
            Text(item.message)
        }
    }

    private var openInvitesSection: some View {
        Section {
            if connect.accessInvites.isEmpty {
                Text("None. Links you make in Connect a machine show here until they're used up or expire.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(connect.accessInvites) { invite in
                InviteRow(invite: invite) { pendingRevoke = .invite(invite) }
            }
        } header: {
            Text("Open invite links")
        } footer: {
            Text("Revoke a link to stop it from working. Machines it already set up keep working.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: General → You (shown on the General page)

    private var youSection: some View {
        Section {
            TextField("Your name", text: $settings.userName, prompt: Text("you"))
        } header: {
            Text("You")
        } footer: {
            Text("The pill reads “Nothing \(settings.needsLabel)” when all is clear.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Panel

    private var lookSection: some View {
        Section {
            PanelPreview(model: model, settings: settings)
            Picker(selection: $settings.ui.panelSize) {
                ForEach(PanelSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Size", "Scales the pill, the cards' type and the open panel's width.")
            }
            Picker(selection: $settings.ui.textSize) {
                ForEach(TextSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Card text size", "Body text only, so agents' step-by-step instructions are easy to read.")
            }
            Picker(selection: $settings.ui.cardBodies) {
                ForEach(CardBodyMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Card text", "All of it, the first \(CardBodyPolicy.previewLines) lines, or none until you click Show details.")
            }
            Toggle(isOn: $settings.ui.compactLinks) {
                LabelWithDetail("Compact links", "At most \(LinkRowPolicy.compactLinks) short links per card; +N shows the rest.")
            }
            Picker(selection: $settings.ui.maxVisibleCards) {
                ForEach(ListHeightPolicy.choices, id: \.self) { Text(ListHeightPolicy.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Cards before scrolling", "How many cards the open panel shows before its list scrolls.")
            }
        } header: {
            Text("Look")
        } footer: {
            Text("The sample card above shows your choices as you make them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var visibilitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.visibility != .hidden },
                set: { on in
                    if on { model.showPanel(); visibilityMessage = nil }
                    else if !model.hidePanel() { visibilityMessage = "Turn on the menu bar icon first: the panel and the icon can't both be hidden." }
                }
            )) {
                LabelWithDetail("Show floating panel", "While it's hidden, new items only update the menu bar.")
            }
            Toggle(isOn: Binding(
                get: { settings.showMenuBarIcon },
                set: { on in
                    visibilityMessage = model.setShowMenuBarIcon(on) ? nil
                        : "The floating panel is hidden, so the menu bar icon stays. Show the panel first."
                }
            )) {
                LabelWithDetail("Show menu bar icon", "The count and the top five items. It stays on while the panel is hidden.")
            }
            Toggle(isOn: $settings.showMenuBarCount) {
                LabelWithDetail("Show count in menu bar", "The number next to the icon, in the highest priority's colour.")
            }
            .disabled(!settings.showMenuBarIcon)
            Toggle(isOn: $settings.snapToCorners) {
                LabelWithDetail("Snap to corners", "A dropped pill snaps to the nearest corner instead of staying where you drop it.")
            }
            if let visibilityMessage {
                Text(visibilityMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Panel and menu bar")
        } footer: {
            Text("Drag the pill anywhere. To put it back in the top-right corner, use Reset Position in the menu bar or right-click menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyboardSection: some View {
        Section {
            ShortcutRecorder(hotKeys: hotKeys)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Opens the panel's cards, or collapses them, from any app (a hidden panel comes back open), without taking focus from what you're typing. A shortcut needs Control (⌃), Option (⌥) or Command (⌘).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Alerts

    private var alertStyleSection: some View {
        Section {
            AlertPreview(settings: settings)
            Picker(selection: $settings.ui.alertUrgent) {
                ForEach(AlertIntensity.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Urgent items", "Never fully off: urgent always pulses at least once, \(AlertStyle.urgentFloor.title.lowercased()).")
            }
            Picker(selection: $settings.ui.alertOther) {
                ForEach(AlertIntensity.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Normal and low items", "Off: no pulse, just a faint ring on the count.")
            }
        } header: {
            Text("New items")
        } footer: {
            Text("How loud a new item is: the glow, how many times it pulses, and the ring on the count. Bright also tints the pill. With Reduce Motion on, pulses are gentler.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var breakthroughSection: some View {
        Section {
            Toggle(isOn: $settings.urgentBreaksSnooze) {
                LabelWithDetail("Urgent items break through a snooze", "An urgent arrival ends a panel snooze and shows the panel.")
            }
            Toggle(isOn: $settings.urgentShowsHiddenPanel) {
                LabelWithDetail("Urgent items show the panel even when hidden", "Instead of one pulse of the menu bar icon.")
            }
        } header: {
            Text("Snoozed or hidden")
        } footer: {
            Text("Snooze from the moon button or by right-clicking the pill. Everything else waits until the snooze ends.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Integrations

    private var terminalJumpSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.terminalAppleScript },
                set: { on in
                    settings.terminalAppleScript = on
                    automationStatus = nil
                    if on { checkAutomation() }
                }
            )) {
                LabelWithDetail("Jump to iTerm2 and Terminal tabs",
                                "A card's Terminal button selects the tab its Claude Code session runs in, with AppleScript. macOS asks once per app to let Needs You control it (Automation). Off: the button only brings iTerm2 or Terminal forward.")
            }
            if settings.terminalAppleScript {
                HStack(alignment: .top) {
                    Text(automationStatus ?? "Checking…")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Check again") { checkAutomation() }
                }
            }
        } header: {
            Text("Terminal button")
        } footer: {
            Text("WezTerm and tmux need no permission: the app runs `wezterm cli activate-pane` or `tmux select-pane` with the card's pane id. Nothing from a card ever runs as a command or script; a terminal link from outside the panel asks first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Asks for (or re-checks) Automation for iTerm2 and Terminal. Only from this Settings
    /// click: the panel never prompts.
    private func checkAutomation() {
        automationStatus = nil
        TerminalJumpRunner.requestAutomation { automationStatus = $0 }
    }

    private var sendersSection: some View {
        Section {
            Text("Claude Code hooks, Orca automations, CI jobs and scripts send alerts to your inbox. To set up a machine, make a link for it in Connect a machine. Their cards' links (Terminal, VS Code, pull requests) open from the panel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if canInvite {
                HStack {
                    Spacer()
                    Button("Connect a machine…") { navigation.tab = .connect }
                }
            }
        } header: {
            Text("Senders")
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                LabelWithDetail("Look and alerts", "The pill, the cards' size and text, opacity and alert styles, back to how they started.")
                Spacer()
                Button("Reset to defaults") { settings.ui = UIPrefs.defaults }
                    .disabled(settings.ui == UIPrefs.defaults)
            }
        } header: {
            Text("Reset")
        } footer: {
            Text("Settings are kept in `defaults read app.needsyou.mac`. Tokens and the hub's data are in ~/Library/Application Support/NeedsYou/.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Other hubs → by URL and token

    private var hubsSection: some View {
        Section {
            if settings.tokensNeedReconnect && !settings.hubsMissingTokens.isEmpty {
                Text("Hub tokens are no longer kept in the Keychain. Re-connect \(settings.hubsMissingTokens.map(HubName.short).joined(separator: ", ")) once with a link from its owner (Join a hub with a link, above), or paste its token below.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if settings.runLocalHub && !settings.isDemo {
                HStack(alignment: .firstTextBaseline) {
                    Text("This Mac (your inbox)").bold()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalHub.clientURL.absoluteString).foregroundStyle(.secondary).font(.callout.monospaced())
                        if let tailnet = localHub.reach?.tailnetURL {
                            Text("Other machines: \(tailnet)").foregroundStyle(.secondary).font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Text("owner").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach($rows) { $row in
                HubRowView(row: $row,
                           index: rows.firstIndex(where: { $0.id == row.id }) ?? 0,
                           count: rows.count,
                           move: { move(row.id, by: $0) },
                           remove: { rows.removeAll { $0.id == row.id } },
                           test: { test(row.id) })
            }
            HStack {
                Button("Add Hub") { rows.append(HubRow(url: "")) }
                Spacer()
                Button("Save & Connect") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Hubs by URL and token")
        } footer: {
            Text("Only if you were given a hub URL and a token instead of a link; joining with a link is easier. Hubs are tried in order, this Mac first: the first one that answers is used, and the next takes over if it fails. Tokens are saved in ~/Library/Application Support/NeedsYou/tokens.json (mode 600).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusText(_ status: ConnectController.Status?) -> some View {
        switch status {
        case .none: EmptyView()
        case .working(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyButton(_ title: String, _ text: String) -> some View {
        CopyButton(title: title, text: text)
    }

    private func isWorking(_ status: ConnectController.Status?) -> Bool {
        if case .working = status { return true }
        return false
    }

    // MARK: Actions

    private func connectWithLink() {
        let text = linkDraft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        clipboardNote = nil
        pasteProblem = nil
        connect.connect(text)
        if ConnectLink.parse(text) != nil { linkDraft = "" }
    }

    /// Other hubs → Paste. Only a join link goes into the field; anything else on the
    /// clipboard (a password, a token) is left alone.
    private func pasteLink() {
        clipboardNote = nil
        switch ConnectLinkClipboard.paste(NSPasteboard.general.string(forType: .string)) {
        case .link(let text):
            linkDraft = text
            pasteProblem = nil
        case .notALink:
            pasteProblem = "The clipboard doesn't hold a join link. It starts with needsyou://connect, or has /join/ in it."
        case .empty:
            pasteProblem = "The clipboard is empty. Copy the link first."
        }
    }

    /// When Other hubs opens (the person opened Settings, so reading the clipboard is
    /// expected): prefill a join link from the clipboard, once per clipboard change.
    private func offerClipboardLink() {
        guard navigation.tab == .otherHubs, !isWorking(connect.status) else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount
        var own = [LocalHub.clientURL]
        if let tailnet = localHub.reach?.tailnetURL, let url = URL(string: tailnet) { own.append(url) }
        guard let text = ConnectLinkClipboard.suggestion(clipboard: pasteboard.string(forType: .string), draft: linkDraft,
                                                         ownHubs: own, ignoring: connect.lastLink.map { [$0] } ?? [])
        else { return }
        linkDraft = text
        pasteProblem = nil
        clipboardNote = "Found a link on your clipboard. Check it, then press Join."
    }

    private func load() {
        rows = settings.hubURLs.map { url in
            var row = HubRow(url: url.absoluteString)
            row.hasToken = settings.token(for: url) != nil
            row.role = settings.role(for: url)
            return row
        }
        if rows.isEmpty && !settings.runLocalHub { rows = [HubRow(url: "")] }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard rows.indices.contains(j) else { return }
        rows.swapAt(i, j)
    }

    private func save() {
        var urls: [String] = []
        var problems: [String] = []
        for i in rows.indices {
            let trimmed = rows[i].url.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let url = AppSettings.parseHubURL(trimmed), !LocalHub.isLocal(url) else {
                problems.append("“\(trimmed)” isn't an http(s)://host[:port] URL for another machine")
                continue
            }
            if !HubTransportPolicy.allows(url) {
                problems.append("\(HubName.short(url)): plain http:// only works for *.ts.net, local names and IP addresses; use https://")
            }
            if !rows[i].tokenDraft.isEmpty {
                // A hand-entered token's role is unknown.
                if settings.saveToken(rows[i].tokenDraft, role: nil, for: url) {
                    rows[i].hasToken = true
                    rows[i].tokenDraft = ""
                } else {
                    problems.append("Couldn't save the token for \(HubName.short(url)) to tokens.json")
                }
            }
            if !rows[i].hasToken { problems.append("\(HubName.short(url)) has no token") }
            urls.append(trimmed)
        }
        // Forget tokens and roles for hubs that were removed.
        let kept = Set(urls.compactMap(AppSettings.parseHubURL).map(HubName.key))
        for old in settings.hubURLs where !kept.contains(HubName.key(old)) {
            settings.removeToken(for: old)
        }
        settings.hubURLStrings = urls
        settings.pruneTokens()
        if settings.hubsMissingTokens.isEmpty { settings.tokensNeedReconnect = false }
        if (!urls.isEmpty || settings.runLocalHub), settings.demoMode, !settings.demoForcedByEnvironment {
            settings.demoMode = false
            localHub.apply()
        }
        model.restartFeed()
        if !problems.isEmpty {
            message = problems.joined(separator: "\n")
        } else if urls.isEmpty {
            message = settings.runLocalHub ? "Saved. Using the hub on this Mac" : "No hubs saved"
        } else {
            message = settings.isDemo ? "Saved (demo mode is on, so hubs aren't used)" : "Saved. Polling every \(Int(settings.pollInterval)) s"
        }
    }

    private func test(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        guard let url = AppSettings.parseHubURL(rows[i].url) else {
            rows[i].status = "Enter an http(s)://host[:port] URL"
            return
        }
        let token = rows[i].tokenDraft.isEmpty ? (settings.token(for: url) ?? "") : rows[i].tokenDraft
        rows[i].status = "Testing…"
        Task {
            let client = HubClient(config: HubConfig(baseURL: url, token: token))
            let result: String
            do {
                _ = try await client.fetchOpen(since: Date())
                result = "Connected"
            } catch {
                result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if let j = rows.firstIndex(where: { $0.id == id }) { rows[j].status = result }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch {
            loginMessage = "Couldn't change the login item: \(error.localizedDescription). Run the app from /Applications."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Approve Needs You in System Settings → General → Login Items."
        }
    }
}

/// The shortcut and its recorder. Lives in the Settings window only (never the panel):
/// recording listens for the next key press in this window.
private struct ShortcutRecorder: View {
    @ObservedObject var hotKeys: HotKeyController
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Open / collapse shortcut") {
                HStack(spacing: 8) {
                    Text(hotKeys.isRecording ? "Type a shortcut… (Escape cancels)" : hotKeys.combo.spokenAndSymbols)
                        .font(.body)
                        .foregroundStyle(hotKeys.isRecording ? .secondary : .primary)
                    if hotKeys.isRecording {
                        Button("Cancel") { hotKeys.stopRecording() }
                    } else {
                        Button("Change…") {
                            message = nil
                            hotKeys.startRecording { message = $0 }
                        }
                        if hotKeys.combo != .standard {
                            Button("Reset") { message = hotKeys.change(to: .standard) }
                                .help("Back to \(HotKeyCombo.standard.spokenAndSymbols)")
                        }
                    }
                }
            }
            if hotKeys.isRecording {
                EmptyView()
            } else if hotKeys.isRegistered {
                Label("Registered", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else {
                Label("Not registered: another app or macOS (input-source switching?) has \(hotKeys.combo.spokenAndSymbols). Pick another.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { hotKeys.stopRecording() }
    }
}

private struct HubRowView: View {
    @Binding var row: HubRow
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    let test: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                TextField("Hub URL", text: $row.url, prompt: Text("http://hub.example.ts.net:8765"))
                if let role = row.role {
                    Text(role.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).buttonStyle(.borderless).help("Try this hub earlier")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == count - 1).buttonStyle(.borderless).help("Try this hub later")
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this hub")
            }
            HStack {
                SecureField("Token", text: $row.tokenDraft,
                            prompt: Text(row.hasToken ? "Saved (leave blank to keep)" : "Read/patch token"))
                Button("Test", action: test)
            }
            if let status = row.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The top of each page: its icon, title and one-line summary (from `SettingsTab`).
private struct SettingsPageHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tab.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.title2.weight(.semibold))
                Text(tab.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// A Copy button that says "Copied" for a moment after a click.
private struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

/// One address of the hub on this Mac: what it's for, the URL (selectable) and Copy.
private struct AddressRow: View {
    let title: String
    let url: String
    let detail: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(url).font(.callout.monospaced()).textSelection(.enabled)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            CopyButton(title: "Copy", text: url)
        }
    }
}

/// One line of Your inbox → How it works.
private struct HowItWorksStep: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

/// One machine on Settings → Machines: its name, what it is (MachineRowText), and Revoke.
/// Kept on its own so per-machine buttons slot in before Revoke.
private struct MachineRow: View {
    let token: TokenSummary
    @ObservedObject var connect: ConnectController
    let revoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name)
                Text(MachineRowText.detail(token))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            MachineUpdateButton(token: token, connect: connect)
            if !token.current {
                Button("Revoke", role: .destructive, action: revoke)
            }
        }
    }
}

/// One open invite link on Settings → Machines, with Revoke. Never shows the code.
private struct InviteRow: View {
    let invite: InviteSummary
    let revoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.name)
                Text("\(invite.role?.machineLabel ?? "Unknown role") · \(invite.left) of \(invite.uses) left\(invite.expiresAt.map { " · expires \(ConnectController.formatExpiry($0))" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive, action: revoke)
        }
    }
}
