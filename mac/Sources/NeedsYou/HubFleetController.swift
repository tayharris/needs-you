import Foundation
import NeedsYouCore

/// Settings → Updates → Machines and hubs, the hubs half (ADR 0013): every server hub this
/// Mac knows (the local hub's peers, and other owner hubs), each asked GET /v1/hub/update at its
/// own URL with an owner token, and Request update (POST /v1/hub/update, no body). Settings
/// window only; nothing here touches the panel or activates the app.
@MainActor
final class HubFleetController: ObservableObject {
    @Published private(set) var hubs: [FleetHub] = []
    @Published private(set) var message: String?
    @Published private(set) var loading = false
    @Published private(set) var busy: Set<String> = []

    private let settings: AppSettings
    private let client: InviteClient
    private var endpoints: [String: FleetHubEndpoint] = [:]

    init(settings: AppSettings, client: InviteClient = InviteClient()) {
        self.settings = settings
        self.client = client
    }

    private var localToken: String? {
        guard settings.runLocalHub, let t = settings.localHubToken, !t.isEmpty else { return nil }
        return t
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        var peers: [PeerSummary] = []
        if let token = localToken {
            peers = (try? await client.listPeers(hub: LocalHub.clientURL, token: token)) ?? []
        }
        let plan = FleetHubEndpoint.plan(peers: peers, ownerHubs: settings.ownerHubConfigs(), localToken: localToken)
        let client = self.client
        let fetched = await withTaskGroup(of: (Int, FleetHub).self) { group -> [FleetHub] in
            for (i, e) in plan.enumerated() {
                group.addTask { (i, await Self.fetch(e, client: client)) }
            }
            var out = [FleetHub?](repeating: nil, count: plan.count)
            for await (i, hub) in group { out[i] = hub }
            return out.compactMap { $0 }
        }
        endpoints = Dictionary(plan.map { (HubName.key($0.url), $0) }, uniquingKeysWith: { a, _ in a })
        hubs = fetched
    }

    private nonisolated static func fetch(_ e: FleetHubEndpoint, client: InviteClient) async -> FleetHub {
        do {
            let status = try await client.hubUpdateStatus(hub: e.url, token: e.token)
            return FleetHub(url: e.url, name: e.name, status: status)
        } catch ConnectError.hubTooOld {
            if let version = try? await client.hubVersion(hub: e.url) {
                return FleetHub(url: e.url, name: e.name, version: version)
            }
            return FleetHub(url: e.url, name: e.name, error: ConnectError.hubTooOld.errorDescription)
        } catch {
            return FleetHub(url: e.url, name: e.name, error: Self.describe(error))
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Request update for one hub; the row shows the answer at once.
    func request(_ hub: FleetHub) async {
        guard let e = endpoints[hub.id], !busy.contains(hub.id) else { return }
        busy.insert(hub.id)
        defer { busy.remove(hub.id) }
        do {
            let status = try await client.requestHubUpdate(hub: e.url, token: e.token)
            replace(FleetHub(url: e.url, name: e.name, status: status))
            message = "Asked \(hub.name) to update. Its updater checks the release as always and starts within a minute."
        } catch {
            message = "\(hub.name): \(Self.describe(error))"
            await reload(e)
        }
    }

    /// Update all: every hub given, one after the other.
    func requestAll(_ hubs: [FleetHub]) async {
        for hub in hubs { await request(hub) }
        if hubs.count > 1 { message = "Asked \(hubs.count) hubs to update." }
    }

    private func reload(_ e: FleetHubEndpoint) async {
        replace(await Self.fetch(e, client: client))
    }

    private func replace(_ hub: FleetHub) {
        if let i = hubs.firstIndex(where: { $0.id == hub.id }) { hubs[i] = hub }
    }
}
