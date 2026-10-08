import AppKit
import NeedsYouCore
import SwiftUI

/// Settings → Built-in hub → Always-on hub (ADR 0012): make a peer invite for a server, show
/// the command to run there, and each peer's replication state. Settings window only; the
/// panel shows nothing of it. Peer secrets never reach the app (the hubs keep them).
@MainActor
final class AlwaysOnHubController: ObservableObject {
    @Published private(set) var peers: [PeerSummary] = []
    @Published private(set) var command: String?
    @Published private(set) var commandExpires: Date?
    @Published private(set) var message: String?
    @Published private(set) var working = false

    private let settings: AppSettings
    private let client: InviteClient
    /// This Mac's hub id, for the command that removes it on the server.
    private let hubID: String?

    init(settings: AppSettings, hubID: String?, client: InviteClient = InviteClient()) {
        self.settings = settings
        self.hubID = hubID
        self.client = client
    }

    private var token: String? {
        guard let t = settings.localHubToken, !t.isEmpty else { return nil }
        return t
    }

    func refresh() async {
        guard let token else { return }
        do {
            peers = try await client.listPeers(hub: LocalHub.clientURL, token: token)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func makeInvite() async {
        guard let token else { return }
        working = true
        defer { working = false }
        do {
            let invite = try await client.createPeerInvite(PeerInviteRequest(name: "always-on"),
                                                           hub: LocalHub.clientURL, token: token)
            command = invite.hubInstallCommand ?? "curl -fsSL \(invite.joinURL.components(separatedBy: "/join/").first ?? "")/dl/install-hub.sh | sudo bash -s -- --join '\(invite.joinURL)'"
            commandExpires = invite.expiresAt.flatMap(HubJSON.parseDate)
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func remove(_ peer: PeerSummary) async {
        guard let token, let id = peer.hubID else { return }
        do {
            try await client.removePeer(hubID: id, hub: LocalHub.clientURL, token: token)
            message = "Removed \(peer.displayName). On that server, also run: needs-you-admin peer remove \(hubID ?? "<this Mac's hub id>")"
            await refresh()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AlwaysOnHubSection: View {
    @StateObject private var controller: AlwaysOnHubController
    let reach: LocalHubReach
    let hubID: String?
    @State private var pendingRemove: PeerSummary?
    @State private var now = Date()

    init(settings: AppSettings, reach: LocalHubReach, hubID: String?) {
        _controller = StateObject(wrappedValue: AlwaysOnHubController(settings: settings, hubID: hubID))
        self.reach = reach
        self.hubID = hubID
    }

    /// A server addresses this Mac by its MagicDNS name, which survives a new tailnet IP.
    private var namedByIP: Bool {
        guard let url = reach.tailnetURL.flatMap(URL.init(string:)), let host = url.host else { return false }
        return TailnetAddress.isTailnetIPv4(host)
    }

    var body: some View {
        Section {
            Text("A server that's always on keeps your alerts while this Mac sleeps. It replicates every item with the hub on this Mac, both ways, and links you make here list it too, so senders use it when this Mac is away.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(controller.peers) { peer in
                peerRow(peer)
            }
            if reach.reachableFromOtherMachines {
                if let command = controller.command {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On the server (Linux with systemd and Tailscale), run this. It installs the hub from this Mac and pairs it:")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top) {
                            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            SettingsCopyButton(title: "Copy", text: command)
                        }
                        Text(expiryNote)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    if namedByIP {
                        Text("Turn on MagicDNS in Tailscale first: without it the server finds this Mac by an address that can change.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(controller.command == nil ? "Add an always-on hub…" : "Make a new link") {
                        Task { await controller.makeInvite() }
                    }
                    .disabled(controller.working)
                }
            } else {
                Text("Connect this Mac to Tailscale first: the server reaches this hub over your tailnet.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Always-on hub")
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                await controller.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .confirmationDialog(pendingRemove.map { "Stop replicating with \($0.displayName)?" } ?? "",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let peer = pendingRemove { Task { await controller.remove(peer) } }
                pendingRemove = nil
            }
        } message: {
            Text("Its link and secret are deleted here. Items it already has stay on it. Remove this Mac on the server too: needs-you-admin peer remove \(hubID ?? "<this Mac's hub id>")")
        }
    }

    private var expiryNote: String {
        let base = "The link works once"
        guard let expires = controller.commandExpires else { return base + "." }
        let minutes = max(0, Int(expires.timeIntervalSince(now) / 60))
        return base + ", for \(minutes) more minute\(minutes == 1 ? "" : "s"). It never shows the pair's secret."
    }

    private func peerRow(_ peer: PeerSummary) -> some View {
        let state = PeerState(peer, now: now)
        return HStack(alignment: .top) {
            Image(systemName: state.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state.isHealthy ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.displayName)
                Text(peer.url).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(state.label(now: now)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if peer.removable {
                Button("Remove…") { pendingRemove = peer }
            }
        }
    }
}
