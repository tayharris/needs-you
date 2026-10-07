import NeedsYouCore
import SwiftUI

/// Settings → Updates: this app's version, the update checks and installs, and which
/// sender machines are behind. Lives in the Settings window only, never in the panel.
struct UpdatesSettingsView: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var connect: ConnectController

    var body: some View {
        Group {
            if let notice = updates.notice {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green)
                        Text(notice).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("OK") { updates.dismissNotice() }
                    }
                }
            }
            versionSection
            settingsSection
        }
    }

    private var versionSection: some View {
        Section {
            HStack {
                LabelWithDetail("This Mac", "Needs You \(updates.current?.description ?? "?") (build \(updates.build))")
                Spacer()
                Button("Check now") { updates.check(manual: true) }
                    .disabled(isBusy)
            }
            statusLine
            actionButtons
        } header: {
            Text("Version")
        } footer: {
            Text("Source: \(updates.sourceDescription). Credential: \(updates.authSource). Only releases built by the release workflow after its tests passed, with matching SHA-256 checksums, are installed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch updates.phase {
        case .checking:
            working("Checking…")
        case .downloading(let v):
            working("Downloading and verifying \(v)…")
        case .installing(let v):
            working("Installing \(v). The app quits and comes back by itself.")
        case .idle, .staged:
            EmptyView()
        }
        if let error = updates.lastError {
            Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if let result = updates.lastResult {
            Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let last = updates.prefs.lastCheck {
            Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened)).")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !updates.enabled {
            Text("Automatic checks are off for this build (not the installed NeedsYou.app). Check now still works.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let offer = available
        if updates.stagedVersion != nil || offer != nil {
            HStack {
                Spacer()
                if let offer {
                    Button("Skip \(offer.description)") { updates.skipAvailable() }
                        .disabled(isBusy)
                }
                Button(updates.stagedVersion != nil ? "Restart to update" : "Download and install now") { updates.installNow() }
                    .disabled(isBusy)
            }
        }
    }

    /// A version that passes the gate (ready, or waiting out the soak) or is staged.
    private var available: SemVer? {
        if let staged = updates.stagedVersion { return staged }
        switch updates.decision {
        case .ready(let c), .wait(let c, _): return c.version
        default: return nil
        }
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .checking, .downloading, .installing: return true
        case .idle, .staged: return false
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle(isOn: $updates.prefs.checkAutomatically) {
                LabelWithDetail("Check for updates automatically",
                                "2 minutes after launch and every 6 hours. The only request goes to api.github.com and carries nothing about your items.")
            }
            Toggle(isOn: $updates.prefs.installAutomatically) {
                LabelWithDetail("Install updates automatically",
                                "When you've been away for 10 minutes, or when you quit. Never while the panel is open or just after a new item.")
            }
            Picker(selection: $updates.prefs.channel) {
                ForEach(UpdateChannel.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Channel", "Drafts are never installed.")
            }
            Picker(selection: soakBinding) {
                ForEach(UpdatePolicy.soakChoices, id: \.self) { seconds in
                    Text(Self.soakTitle(seconds)).tag(seconds)
                }
            } label: {
                LabelWithDetail("Wait after a release", "A release pulled within this time never reaches this Mac.")
            }
        } header: {
            Text("Updates")
        }
    }

    private var soakBinding: Binding<TimeInterval> {
        Binding(get: {
            let s = updates.prefs.soakHours * 3600
            return UpdatePolicy.soakChoices.contains(s) ? s : UpdatePolicy.defaultSoak
        }, set: { updates.prefs.soakHours = $0 / 3600 })
    }

    static func soakTitle(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 0: return "Install at once"
        case 3600: return "1 hour"
        case 86_400: return "24 hours"
        default: return "\(Int(seconds / 3600)) hours"
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
