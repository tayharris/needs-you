import AppKit
import NeedsYouCore
import ServiceManagement
import SwiftUI

/// The Settings window: your name, the hub list (URLs in UserDefaults, one token per hub
/// in the Keychain), demo mode, snooze breakthrough, open at login.
///
/// Focus rule: `show()` is the ONLY place the app activates or makes a window key, and it
/// is only called from an explicit user action (the Settings menu item / gear button, or
/// clicking the "set up" pill). Never call it from a timer, poll or launch path.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel
    private let hotKeyStatus: () -> Bool
    /// Extra Settings sections (phase 3 adds its schedule options here).
    var extraSettings: (() -> AnyView)?

    init(model: AppModel, hotKeyStatus: @escaping () -> Bool) {
        self.model = model
        self.hotKeyStatus = hotKeyStatus
    }

    func show() {
        if window == nil {
            let view = SettingsView(model: model, settings: model.settings, hotKeyRegistered: hotKeyStatus(),
                                    extra: extraSettings?(), close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "needs-you Settings"
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
    var status: String?
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let hotKeyRegistered: Bool
    var extra: AnyView?
    var close: () -> Void

    @State private var rows: [HubRow] = []
    @State private var message: String?
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    private var isFirstRun: Bool { !settings.hasHubs && !settings.isDemo }

    var body: some View {
        Form {
            if isFirstRun {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to needs-you").font(.headline)
                        Text("needs-you shows the things your machines, projects and agents need from you, as a small floating pill that stays out of the way until something's waiting. Items come from a needs-you hub on your network.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Add your hub's URL and the read/patch token you were given below. No hub yet? Try demo mode to see how it works.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try demo mode") {
                            settings.demoMode = true
                            model.restartFeed()
                            close()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("You") {
                TextField("Your name", text: $settings.userName, prompt: Text("you"))
                Text("The panel reads “\(settings.needsLabel)”.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
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
                Text("Polled in order: the first reachable hub is used and the next takes over on errors. Hubs replicate to each other, so any of them works. Tokens are stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Demo mode (fixture items, no hub)", isOn: Binding(
                    get: { settings.demoMode },
                    set: { settings.demoMode = $0; model.restartFeed() }
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
    }

    // MARK: Actions

    private func load() {
        rows = settings.hubURLStrings.map { s in
            var row = HubRow(url: s)
            // Reads the Keychain; Settings is only ever opened by the user.
            if let url = AppSettings.parseHubURL(s) { row.hasToken = settings.tokenStore(for: url).read() != nil }
            return row
        }
        if rows.isEmpty { rows = [HubRow(url: "")] }
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
            guard let url = AppSettings.parseHubURL(trimmed) else {
                problems.append("“\(trimmed)” isn't an http(s)://host[:port] URL")
                continue
            }
            if !rows[i].tokenDraft.isEmpty {
                if settings.tokenStore(for: url).write(rows[i].tokenDraft) {
                    rows[i].hasToken = true
                    rows[i].tokenDraft = ""
                } else {
                    problems.append("Couldn't save the token for \(HubName.short(url)) to the Keychain")
                }
            }
            if !rows[i].hasToken { problems.append("\(HubName.short(url)) has no token") }
            urls.append(trimmed)
        }
        // Forget tokens for hubs that were removed.
        let kept = Set(urls.compactMap(AppSettings.parseHubURL).map(HubName.key))
        for old in settings.hubURLs where !kept.contains(HubName.key(old)) {
            settings.tokenStore(for: old).delete()
        }
        settings.hubURLStrings = urls
        if !urls.isEmpty, settings.demoMode, !settings.demoForcedByEnvironment {
            settings.demoMode = false
        }
        model.restartFeed()
        if !problems.isEmpty {
            message = problems.joined(separator: "\n")
        } else if urls.isEmpty {
            message = "No hubs saved"
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
        let token = rows[i].tokenDraft.isEmpty ? (settings.tokenStore(for: url).read() ?? "") : rows[i].tokenDraft
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
            loginMessage = "Approve needs-you in System Settings → General → Login Items."
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
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).buttonStyle(.borderless).help("Try this hub earlier")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == count - 1).buttonStyle(.borderless).help("Try this hub later")
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this hub")
            }
            HStack {
                SecureField("Token", text: $row.tokenDraft,
                            prompt: Text(row.hasToken ? "Saved in Keychain (leave blank to keep)" : "Read/patch token"))
                Button("Test", action: test)
            }
            if let status = row.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
