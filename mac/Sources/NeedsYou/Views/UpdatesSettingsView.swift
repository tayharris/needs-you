import NeedsYouCore
import SwiftUI

/// Settings → Updates: this app's version, the update checks and installs, and which sender
/// machines and server hubs are behind, with Request update for each. Lives in the Settings
/// window only, never in the panel.
// settings-section: updates
struct UpdatesSettingsView: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var connect: ConnectController
    let settings: AppSettings

    var body: some View {
        Group {
            if let notice = updates.notice {
                Section {
                    HStack(alignment: .top) {
                        if notice.failed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.seal").foregroundStyle(.green)
                        }
                        Text(notice.text).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer()
                        Button("OK") { updates.dismissNotice() }
                    }
                }
            }
            if updates.source.isTestFeed {
                Section {
                    Label("Test update source: \(updates.sourceDescription). Updates from it are never installed automatically. Remove the updateFeedURL default (or NEEDS_YOU_UPDATE_FEED) to go back to GitHub.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            versionSection
            settingsSection
            MachinesAndHubsSection(updates: updates, connect: connect, settings: settings)
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
            Text("Source: \(updates.sourceDescription). GitHub sign-in: \(updates.authSource). Only releases built by the release workflow after its tests passed, with matching SHA-256 checksums, are installed.")
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
                LabelWithDetail("Channel", "Releases only, or pre-releases too (newer, less tested). Drafts are never installed.")
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

/// Machines and hubs (ADR 0013): each sender machine (GET /v1/tokens, as on Settings →
/// Machines) and each server hub (the local hub's peers and other owner hubs, GET
/// /v1/hub/update), its version and whether it's behind, Request update per row and Update all
/// for the ones behind. Senders are judged against this app's version (what its hub serves on
/// /dl); hubs against the newest release this app knows (they update from GitHub).
struct MachinesAndHubsSection: View {
    @ObservedObject var updates: UpdateController
    @ObservedObject var connect: ConnectController
    @StateObject private var fleet: HubFleetController
    @State private var now = Date()

    init(updates: UpdateController, connect: ConnectController, settings: AppSettings) {
        self.updates = updates
        self.connect = connect
        _fleet = StateObject(wrappedValue: HubFleetController(settings: settings))
    }

    private var senderTarget: SemVer? { updates.current }
    private var hubTarget: SemVer? { FleetTarget.newest(app: updates.current, seen: updates.decision?.seenVersion) }

    private var accessBusy: Bool {
        if case .working = connect.accessStatus { return true }
        return false
    }

    var body: some View {
        Section {
            if !connect.canInvite {
                Text("Listing machines and hubs needs an owner token. Turn on Run hub on this Mac (Built-in hub), which has one, or join a hub with an owner link (Other hubs).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let summary = FleetSummary(tokens: connect.accessTokens, senderTarget: senderTarget,
                                           hubs: fleet.hubs, hubTarget: hubTarget, now: now)
                HStack {
                    Text(summary.text).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Refresh") { refresh() }
                        .disabled(fleet.loading)
                    Button(summary.updateAllCount > 0 ? "Update all (\(summary.updateAllCount))" : "Update all") {
                        connect.requestUpdates(summary.tokensToAsk)
                        let hubs = summary.hubsToAsk
                        Task { await fleet.requestAll(hubs) }
                    }
                    .disabled(summary.updateAllCount == 0 || accessBusy || !fleet.busy.isEmpty)
                    .help("Asks every machine and hub that's behind to update: machines from this Mac's hub, hubs from GitHub with their own checks.")
                }
                ForEach(senderRows) { token in
                    senderRow(token)
                }
                ForEach(fleet.hubs) { hub in
                    hubRow(hub)
                }
                if let message = fleet.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if case .failure(let text) = connect.accessStatus {
                    Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if case .success(let text) = connect.accessStatus {
                    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Machines and hubs")
        } footer: {
            Text("Sender machines update themselves from this Mac's hub once a day (`needs-you update`); Request update asks one to update the next time it talks to the hub, or to remind whoever uses it if its automatic updates are off. Server hubs update themselves from GitHub every 6 hours; Request update asks one to update now, with every check, skipping only the wait after a release. To update many machines over SSH at once, use scripts/rollout.sh from the repository.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            guard connect.canInvite else { return }
            connect.refreshAccess()
            while !Task.isCancelled {
                now = Date()
                await fleet.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func refresh() {
        connect.refreshAccess()
        Task { await fleet.refresh() }
    }

    /// Sender machines seen in the last 14 days, the ones behind first.
    private var senderRows: [TokenSummary] {
        let status = RolloutStatus(tokens: connect.accessTokens, target: senderTarget, now: now)
        let byID = Dictionary(connect.accessTokens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return status.rows.compactMap { byID[$0.id] }
    }

    private func senderRow(_ token: TokenSummary) -> some View {
        let row = RolloutStatus(tokens: [token], target: senderTarget, now: now).rows.first
        return HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name)
                Text(row?.detail ?? "").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row?.behind == true, token.updateRequestedAt == nil {
                Text("out of date").font(.caption).foregroundStyle(.orange)
            }
            MachineUpdateButton(token: token, connect: connect)
        }
    }

    private func hubRow(_ hub: FleetHub) -> some View {
        let state = HubUpdateState(hub: hub, target: hubTarget)
        return HStack(alignment: .top) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.name)
                Text(hub.detail(now: now)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                hubNote(state)
            }
            Spacer()
            hubControl(hub, state: state)
        }
    }

    @ViewBuilder
    private func hubNote(_ state: HubUpdateState) -> some View {
        switch state {
        case .unknown(let why), .unavailable(let why):
            Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .failed(let why):
            Text("Last update failed: \(why)").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .tooOld:
            Text("Too old to be asked: re-run install-hub.sh on it once.").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func hubControl(_ hub: FleetHub, state: HubUpdateState) -> some View {
        switch state {
        case .current:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case .requested(let at):
            Text(at.map { MachineUpdateState.requestedLabel($0, now: now) } ?? "Update requested")
                .font(.caption).foregroundStyle(.secondary)
        case .working(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .outdated, .failed:
            Button("Request update") { Task { await fleet.request(hub) } }
                .disabled(fleet.busy.contains(hub.id))
                .help("Asks this hub to update now. Its own updater installs the newest checked release on its channel (sums, manifest, build provenance), without the wait after a release, and rolls back if it doesn't come up.")
        case .unavailable, .tooOld:
            Text("out of date").font(.caption).foregroundStyle(.orange)
        case .unknown:
            EmptyView()
        }
    }
}
