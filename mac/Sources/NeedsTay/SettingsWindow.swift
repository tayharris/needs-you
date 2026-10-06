import AppKit
import NeedsTayCore
import SwiftUI

/// A minimal Settings window: hub URL (UserDefaults), token (Keychain), demo mode, and
/// the snooze breakthrough choice.
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
            let view = SettingsView(model: model, settings: model.settings, hotKeyRegistered: hotKeyStatus(), extra: extraSettings?())
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "NeedsTay Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        // An accessory app has to activate to put a normal window in front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let hotKeyRegistered: Bool
    var extra: AnyView?

    @State private var urlDraft = ""
    @State private var tokenDraft = ""
    @State private var hasToken = false
    @State private var message: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Hub") {
                TextField("Hub URL", text: $urlDraft, prompt: Text("http://hub.example.ts.net:8765"))
                SecureField("Token", text: $tokenDraft, prompt: Text(hasToken ? "Saved in Keychain (leave blank to keep)" : "Read/patch token"))
                HStack {
                    Button("Save & Connect") { save() }
                        .keyboardShortcut(.defaultAction)
                    Button("Test Connection") { test() }
                        .disabled(testing)
                    if hasToken {
                        Button("Forget Token") {
                            settings.tokenStore.delete()
                            hasToken = false
                            model.restartFeed()
                            message = "Token removed"
                        }
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Behaviour") {
                Toggle("Demo mode (fixture items, no hub)", isOn: Binding(
                    get: { settings.demoMode },
                    set: { settings.demoMode = $0; model.restartFeed() }
                ))
                .disabled(settings.demoForcedByEnvironment)
                if settings.demoForcedByEnvironment {
                    Text("Demo mode is on via NEEDS_TAY_DEMO=1.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Urgent items break through a snooze", isOn: $settings.urgentBreaksSnooze)
                LabeledContent("Show / hide shortcut") {
                    Text(hotKeyRegistered ? "⌃⌥Space" : "⌃⌥Space (unavailable: taken by another app or input-source switching)")
                        .foregroundStyle(hotKeyRegistered ? .primary : .secondary)
                }
            }

            if let extra { extra }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            urlDraft = settings.hubURLString
            // Checking for the token reads the Keychain; skip it in demo mode.
            hasToken = settings.isDemo ? false : (settings.tokenStore.read() != nil)
        }
    }

    private func save() {
        settings.hubURLString = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tokenDraft.isEmpty {
            if settings.tokenStore.write(tokenDraft) {
                hasToken = true
                tokenDraft = ""
            } else {
                message = "Couldn't save the token to the Keychain"
                return
            }
        }
        if settings.hubURL == nil {
            message = "Hub URL must be http(s)://host[:port]"
        } else if !hasToken {
            message = "Add a token to connect"
        } else {
            message = settings.isDemo ? "Saved (demo mode is on, so the hub isn't used)" : "Saved. Polling every \(Int(settings.pollInterval)) s"
        }
        model.restartFeed()
    }

    private func test() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            message = "Enter a hub URL first"
            return
        }
        let token = tokenDraft.isEmpty ? (settings.tokenStore.read() ?? "") : tokenDraft
        testing = true
        message = "Testing…"
        Task {
            let client = HubClient(config: HubConfig(baseURL: url, token: token))
            do {
                _ = try await client.fetchOpen(since: Date())
                message = "Connected"
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }
}
