import AppKit
import NeedsYouCore
import ServiceManagement
import SwiftUI

/// The Settings window: your name, the hub on this Mac, connecting with a link, inviting
/// machines, the manual hub list (URLs in UserDefaults, one token per hub in tokens.json),
/// demo mode, snooze breakthrough, open at login.
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
    private let hotKeyStatus: () -> Bool
    /// Extra Settings sections (phase 3 adds its schedule options here).
    var extraSettings: (() -> AnyView)?

    init(model: AppModel, connect: ConnectController, localHub: LocalHubController, hotKeyStatus: @escaping () -> Bool) {
        self.model = model
        self.connect = connect
        self.localHub = localHub
        self.hotKeyStatus = hotKeyStatus
    }

    func show() {
        if window == nil {
            let view = SettingsView(model: model, settings: model.settings, connect: connect, localHub: localHub,
                                    hotKeyRegistered: hotKeyStatus(), extra: extraSettings?(),
                                    close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Needs You Settings"
            w.styleMask = [.titled, .closable]
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

/// One editable hub row.
private struct HubRow: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var tokenDraft = ""
    var hasToken = false
    var role: HubRole?
    var status: String?
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
    let hotKeyRegistered: Bool
    var extra: AnyView?
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

    /// Only when nothing works out of the box (the local hub is off and no hubs are set).
    private var isFirstRun: Bool { !settings.hasHubs && !settings.isDemo }

    var body: some View {
        Form {
            if isFirstRun { welcome }

            Section("You") {
                TextField("Your name", text: $settings.userName, prompt: Text("you"))
                Text("The panel reads “\(settings.needsLabel)”.").font(.caption).foregroundStyle(.secondary)
            }

            thisMacSection
            connectSection
            if connect.canInvite && !settings.isDemo { inviteSection }
            hubsSection
            menuBarSection

            Section("Behaviour") {
                Toggle("Demo mode (fixture items, no hub)", isOn: Binding(
                    get: { settings.demoMode },
                    set: { settings.demoMode = $0; localHub.apply(); model.restartFeed() }
                ))
                .disabled(settings.demoForcedByEnvironment)
                if settings.demoForcedByEnvironment {
                    Text("Demo mode is on via NEEDS_YOU_DEMO=1.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Urgent items break through a snooze", isOn: $settings.urgentBreaksSnooze)
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Show / hide shortcut") {
                    Text(hotKeyRegistered ? "⌃⌥Space" : "⌃⌥Space (unavailable: taken by another app or input-source switching)")
                        .foregroundStyle(hotKeyRegistered ? .primary : .secondary)
                }
            }

            if let extra { extra }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .onChange(of: settings.hubURLStrings) { _, _ in load() }
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

    private var menuBarSection: some View {
        Section {
            Toggle("Show menu bar icon", isOn: Binding(
                get: { settings.showMenuBarIcon },
                set: { on in
                    visibilityMessage = model.setShowMenuBarIcon(on) ? nil
                        : "The floating panel is hidden, so the menu bar icon stays. Show the panel first."
                }
            ))
            Toggle("Show count in menu bar", isOn: $settings.showMenuBarCount)
                .disabled(!settings.showMenuBarIcon)
            Toggle("Show floating panel", isOn: Binding(
                get: { model.visibility != .hidden },
                set: { on in
                    if on { model.showPanel(); visibilityMessage = nil }
                    else if !model.hidePanel() { visibilityMessage = "Turn on the menu bar icon first: the panel and the icon can't both be hidden." }
                }
            ))
            Toggle("Urgent items show the panel even when hidden", isOn: $settings.urgentShowsHiddenPanel)
            Toggle("Snap to corners", isOn: $settings.snapToCorners)
            if let visibilityMessage {
                Text(visibilityMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Menu bar and panel")
        } footer: {
            Text("While the panel is hidden, new items only update the menu bar; an urgent one pulses the icon once. ⌃⌥Space shows or hides the panel. Drag the pill anywhere; Reset Position is in the menu bar and right-click menus.")
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
