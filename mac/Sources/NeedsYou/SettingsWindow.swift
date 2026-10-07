import AppKit
import NeedsYouCore
import ServiceManagement
import SwiftUI

/// The Settings window, in tabs: Hubs and access (the hub on this Mac, connecting with a
/// link, inviting machines, the manual hub list), Panel (name, look with a live preview,
/// visibility, the shortcut), Alerts, Integrations and Advanced.
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
    /// Extra Settings sections per tab (phase 3 adds its schedule and stream options).
    var extraSettings: [SettingsTab: () -> AnyView] = [:]

    init(model: AppModel, connect: ConnectController, localHub: LocalHubController, hotKeys: HotKeyController) {
        self.model = model
        self.connect = connect
        self.localHub = localHub
        self.hotKeys = hotKeys
    }

    /// `tab` switches to that tab (Invite a Machine and connect links open Hubs and access);
    /// nil keeps the last one.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let view = SettingsView(model: model, settings: model.settings, connect: connect, localHub: localHub,
                                    hotKeys: hotKeys, navigation: navigation, extra: extraSettings.mapValues { $0() },
                                    close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Needs You Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 600, height: 640))
            w.contentMinSize = NSSize(width: 560, height: 460)
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
}

/// The Settings tabs.
enum SettingsTab: String, CaseIterable, Hashable {
    case hubs, panel, alerts, integrations, updates, advanced

    var title: String {
        switch self {
        case .hubs: return "Hubs and access"
        case .panel: return "Panel"
        case .alerts: return "Alerts"
        case .integrations: return "Integrations"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }
}

/// Which tab is showing, so menu items can open a given one.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .hubs
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

/// What the Access section's confirmation alert is about.
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

    @State private var rows: [HubRow] = []
    @State private var message: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var linkDraft = ""
    @State private var inviteName = ""
    @State private var inviteRole: HubRole = .sender
    @State private var inviteUses = 1
    @State private var inviteExpiry: InviteExpiry = .day
    @State private var copied: String?
    @State private var visibilityMessage: String?
    @State private var pendingRevoke: PendingRevoke?
    @State private var automationStatus: String?

    /// Only when nothing works out of the box (the local hub is off and no hubs are set).
    private var isFirstRun: Bool { !settings.hasHubs && !settings.isDemo }

    var body: some View {
        TabView(selection: $navigation.tab) {
            tabForm {
                if isFirstRun { welcome }
                thisMacSection
                connectSection
                if connect.canInvite && !settings.isDemo {
                    inviteSection
                    accessSection
                }
                hubsSection
            }
            .tabItem { Label(SettingsTab.hubs.title, systemImage: "network") }
            .tag(SettingsTab.hubs)

            tabForm {
                youSection
                lookSection
                visibilitySection
                keyboardSection
                extra[.panel]
            }
            .tabItem { Label(SettingsTab.panel.title, systemImage: "rectangle.on.rectangle") }
            .tag(SettingsTab.panel)

            tabForm {
                alertStyleSection
                DeliverySection(settings: settings)
                breakthroughSection
                BypassRulesSection(settings: settings)
                WorkScreenSection(settings: settings)
                extra[.alerts]
            }
            .tabItem { Label(SettingsTab.alerts.title, systemImage: "bell.badge") }
            .tag(SettingsTab.alerts)

            tabForm {
                shortcutActionSection
                terminalJumpSection
                extra[.integrations]
                sendersSection
            }
            .tabItem { Label(SettingsTab.integrations.title, systemImage: "puzzlepiece.extension") }
            .tag(SettingsTab.integrations)

            // Filled by the app delegate (UpdatesSettingsView).
            tabForm {
                extra[.updates]
            }
            .tabItem { Label(SettingsTab.updates.title, systemImage: "arrow.down.circle") }
            .tag(SettingsTab.updates)

            tabForm {
                advancedSection
                extra[.advanced]
            }
            .tabItem { Label(SettingsTab.advanced.title, systemImage: "gearshape.2") }
            .tag(SettingsTab.advanced)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 460, idealHeight: 640)
        .onAppear(perform: load)
        .onChange(of: settings.hubURLStrings) { _, _ in load() }
    }

    /// One tab: a grouped form that scrolls when it's taller than the window.
    private func tabForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
    }

    // MARK: Sections

    private var welcome: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Needs You").font(.headline)
                Text("Needs You shows the things your machines, projects and agents need from you, as a small floating pill that stays out of the way until something's waiting.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Turn on “Run hub on this Mac”, paste a connect link from another Mac, or add a hub by hand below. Just looking? Try demo mode.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try demo mode") {
                    settings.demoMode = true
                    localHub.apply()
                    model.restartFeed()
                    close()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var thisMacSection: some View {
        Section {
            Toggle("Run hub on this Mac", isOn: Binding(
                get: { settings.runLocalHub },
                set: { on in
                    settings.runLocalHub = on
                    localHub.apply()
                    model.restartFeed()
                }
            ))
            .disabled(settings.isDemo)
            if settings.runLocalHub && !settings.isDemo {
                switch localHub.state {
                case .off:
                    EmptyView()
                case .starting:
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .running(let url):
                    HStack {
                        Text("Running. Agents and servers post to ").font(.caption).foregroundStyle(.secondary)
                            + Text(url).font(.caption.monospaced())
                        Spacer()
                        copyButton("Copy URL", url)
                    }
                case .failed(let text):
                    Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("The hub listens on 127.0.0.1 and this Mac's Tailscale address only. Items live in ~/Library/Application Support/NeedsYou/hub.db.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connectSection: some View {
        Section {
            HStack {
                TextField("Link", text: $linkDraft, prompt: Text("needsyou://connect?… or https://hub/join/…"))
                    .onSubmit(connectWithLink)
                Button("Connect", action: connectWithLink)
                    .disabled(linkDraft.trimmingCharacters(in: .whitespaces).isEmpty || isWorking(connect.status))
            }
            statusText(connect.status)
        } header: {
            Text("Connect with link")
        } footer: {
            Text("Tailscale recommended: use the hub's MagicDNS name (…ts.net). Any https URL also works.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inviteSection: some View {
        Section {
            TextField("Machine name", text: $inviteName, prompt: Text("build-box"))
            Picker("Role", selection: $inviteRole) {
                Text("Sender (a server or agent)").tag(HubRole.sender)
                Text("Another Mac (reader)").tag(HubRole.reader)
                Text("Owner (can invite too)").tag(HubRole.owner)
            }
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
                    if let copied {
                        Text("Copied \(copied).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Invite a machine")
        } footer: {
            Text("Paste the agent prompt into an agent on the new machine, or run the one-liner there. Send the Mac link to another Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accessSection: some View {
        Section {
            HStack {
                Text("Invites").bold()
                Spacer()
                Button("Refresh") { connect.refreshAccess() }
                    .disabled(isWorking(connect.accessStatus))
            }
            if connect.accessInvites.isEmpty {
                Text("No open invites.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(connect.accessInvites) { invite in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.name)
                        Text("\(invite.role?.rawValue ?? "?") · \(invite.left) of \(invite.uses) left\(invite.expiresAt.map { " · expires \(ConnectController.formatExpiry($0))" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { pendingRevoke = .invite(invite) }
                }
            }
            Text("Machines").bold()
            if connect.accessTokens.isEmpty {
                Text("Press Refresh to list the tokens on this hub.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(connect.accessTokens) { token in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.name)
                        Text("\(token.role?.rawValue ?? "?")\(token.openItems > 0 ? " · \(token.openItems) open" : "")\(token.current ? " · this Mac" : "")\(token.client["cli"].map { " · CLI \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !token.current {
                        Button("Revoke", role: .destructive) { pendingRevoke = .token(token) }
                    }
                }
            }
            statusText(connect.accessStatus)
        } header: {
            Text("Access")
        } footer: {
            Text("Revoking an invite stops new machines from using its link; machines it set up keep their own tokens. Revoking a machine's token stops it from posting.")
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

    // MARK: Panel tab

    private var youSection: some View {
        Section {
            TextField("Your name", text: $settings.userName, prompt: Text("you"))
        } header: {
            Text("You")
        } footer: {
            Text("The panel reads “\(settings.needsLabel)”.").font(.caption).foregroundStyle(.secondary)
        }
    }

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
            Picker(selection: $settings.ui.panelOpacity) {
                ForEach(PanelOpacity.choices, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
            } label: {
                LabelWithDetail("Opacity", "While the pointer isn't over the pill or the open panel. Hovering shows it fully.")
            }
        } header: {
            Text("Look")
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
            Text("Drag the pill anywhere. Reset Position is in the menu bar and right-click menus.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyboardSection: some View {
        Section {
            ShortcutRecorder(hotKeys: hotKeys)
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Works in every app and never takes focus from what you're typing. Needs ⌃, ⌥ or ⌘.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Alerts tab

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
            Text("How loud an arrival is: the glow and how many times it pulses, and the ring on the count. Bright also tints the pill. Reduce Motion makes the pulses gentler.")
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
        }
    }

    // MARK: Integrations tab

    private var shortcutActionSection: some View {
        Section {
            Toggle(isOn: $settings.hotKeyOpensTopLink) {
                LabelWithDetail("Hotkey also opens the top card's first link",
                                "\(settings.hotKey.display) runs the top card's Terminal jump or opens its VS Code window (or first link) instead of showing or hiding the panel. With nothing to open it shows or hides as usual.")
            }
        } header: {
            Text("Go to the top card")
        } footer: {
            Text("The panel still never takes focus; only the app the link opens comes forward.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

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
            Text("Claude Code hooks, Orca automations, CI jobs and scripts post to a hub; set a machine up from Hubs and access → Invite a machine. Their cards' links (Terminal, VS Code, pull requests) open from the panel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Senders")
        }
    }

    // MARK: Advanced tab

    private var advancedSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.demoMode },
                set: { settings.demoMode = $0; localHub.apply(); model.restartFeed() }
            )) {
                LabelWithDetail("Demo mode", "Fixture items and no hub, to try the app.")
            }
            .disabled(settings.demoForcedByEnvironment)
            if settings.demoForcedByEnvironment {
                Text("Demo mode is on via NEEDS_YOU_DEMO=1.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) })) {
                LabelWithDetail("Open at login", "Starts Needs You when you log in. Run it from /Applications first.")
            }
            if let loginMessage {
                Text(loginMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                LabelWithDetail("Look and alerts", "Size, text, cards, opacity and alert styles back to the original.")
                Spacer()
                Button("Reset to defaults") { settings.ui = UIPrefs.defaults }
                    .disabled(settings.ui == UIPrefs.defaults)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Settings live in `defaults read app.needsyou.mac`; tokens and the hub's data in ~/Library/Application Support/NeedsYou/.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hubsSection: some View {
        Section {
            if settings.tokensNeedReconnect && !settings.hubsMissingTokens.isEmpty {
                Text("Hub tokens are no longer kept in the Keychain. Re-connect \(settings.hubsMissingTokens.map(HubName.short).joined(separator: ", ")) once with a link from its owner (Connect with link), or paste its token below.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if settings.runLocalHub && !settings.isDemo {
                HStack {
                    Text("This Mac").bold()
                    Text(LocalHub.clientURL.absoluteString).foregroundStyle(.secondary).font(.callout.monospaced())
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
            Text("Hubs")
        } footer: {
            Text("Manual setup, if you have a hub URL and token instead of a link. Polled in order (this Mac first): the first reachable hub is used and the next takes over on errors. Tokens are stored in ~/Library/Application Support/NeedsYou/tokens.json (mode 600).")
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
        Button {
            connect.copy(text)
            copied = title.lowercased()
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }

    private func isWorking(_ status: ConnectController.Status?) -> Bool {
        if case .working = status { return true }
        return false
    }

    // MARK: Actions

    private func connectWithLink() {
        let text = linkDraft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        connect.connect(text)
        if ConnectLink.parse(text) != nil { linkDraft = "" }
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
            LabeledContent("Show / hide shortcut") {
                HStack(spacing: 8) {
                    Text(hotKeys.isRecording ? "Type a shortcut… (Esc cancels)" : hotKeys.combo.display)
                        .font(hotKeys.isRecording ? .body : .body.monospaced())
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
                                .help("Back to \(HotKeyCombo.standard.display)")
                        }
                    }
                }
            }
            if hotKeys.isRecording {
                EmptyView()
            } else if hotKeys.isRegistered {
                Label("Registered", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else {
                Label("Not registered: another app or macOS (input-source switching?) has \(hotKeys.combo.display). Pick another.",
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
