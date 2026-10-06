import Foundation
import NeedsYouCore

/// User settings. Hub URLs, the display name and toggles live in UserDefaults; each hub's
/// token lives in the Keychain, keyed by the hub URL (PLAN.md, "Credentials").
///
/// Environment overrides (handy for running the binary directly):
///   NEEDS_YOU_DEMO=1                 demo mode, no hub, no Keychain access
///   NEEDS_YOU_DEMO_FIXTURE=path.json demo seed items (hub list shape) instead of the built-in set
///   NEEDS_YOU_DEMO_INJECT_SECONDS=n  demo: post a new item every n seconds (default 45, 0 = never)
///   NEEDS_YOU_POLL_SECONDS=n         poll interval (default 30; 5 in demo mode)
///   NEEDS_YOU_EXPAND=1               start expanded (never takes focus)
///   NEEDS_YOU_SNAPSHOT_DIR=dir       debug: write PNGs of each panel state
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private let env = ProcessInfo.processInfo.environment
    static let keychainService = "app.needsyou.mac"

    private enum Key {
        static let hubURLs = "hubURLs"
        static let userName = "userName"
        static let demoMode = "demoMode"
        static let urgentBreaksSnooze = "urgentBreaksSnooze"
        static let viewContext = "viewContext"
        static let placements = "panelPlacements"
    }

    /// Hub URLs in failover order (first reachable wins).
    @Published var hubURLStrings: [String] {
        didSet { defaults.set(hubURLStrings, forKey: Key.hubURLs) }
    }
    /// Shown as "needs <name>"; blank means "needs you".
    @Published var userName: String {
        didSet { defaults.set(userName, forKey: Key.userName) }
    }
    @Published var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Key.demoMode) }
    }
    /// PLAN.md open decision 2: urgent items break through a snooze. Default on.
    @Published var urgentBreaksSnooze: Bool {
        didSet { defaults.set(urgentBreaksSnooze, forKey: Key.urgentBreaksSnooze) }
    }
    /// The context currently shown (picked by hand, or by the phase 3 schedule).
    @Published var viewContext: ItemContext {
        didSet { defaults.set(viewContext.rawValue, forKey: Key.viewContext) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.urgentBreaksSnooze: true])
        hubURLStrings = defaults.stringArray(forKey: Key.hubURLs) ?? []
        userName = defaults.string(forKey: Key.userName) ?? ""
        demoMode = defaults.bool(forKey: Key.demoMode)
        urgentBreaksSnooze = defaults.bool(forKey: Key.urgentBreaksSnooze)
        viewContext = ItemContext(rawValue: defaults.string(forKey: Key.viewContext) ?? "") ?? .work
    }

    // MARK: Derived

    /// "needs Sam", or "needs you" when no name is set.
    var needsLabel: String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "needs \(name.isEmpty ? "you" : name)"
    }

    var demoForcedByEnvironment: Bool { env["NEEDS_YOU_DEMO"].map { $0 == "1" || $0.lowercased() == "true" } ?? false }
    var isDemo: Bool { demoForcedByEnvironment || demoMode }
    var startExpanded: Bool { env["NEEDS_YOU_EXPAND"] == "1" }

    var pollInterval: TimeInterval {
        if let s = env["NEEDS_YOU_POLL_SECONDS"], let v = Double(s), v >= 1 { return v }
        return isDemo ? 5 : 30
    }

    var demoInjectInterval: TimeInterval {
        if let s = env["NEEDS_YOU_DEMO_INJECT_SECONDS"], let v = Double(s), v >= 0 { return v }
        return 45
    }

    var demoFixtureURL: URL? {
        env["NEEDS_YOU_DEMO_FIXTURE"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// A usable hub URL: http(s) with a host. Plain http is expected on a tailnet.
    static func parseHubURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    var hubURLs: [URL] { hubURLStrings.compactMap(Self.parseHubURL) }
    var hasHubs: Bool { !hubURLs.isEmpty }

    func tokenStore(for url: URL) -> KeychainTokenStore {
        KeychainTokenStore(service: Self.keychainService, account: HubName.key(url))
    }

    /// Hubs that have a token, in failover order.
    func hubConfigs() -> [HubConfig] {
        hubURLs.compactMap { url in
            guard let token = tokenStore(for: url).read(), !token.isEmpty else { return nil }
            return HubConfig(baseURL: url, token: token)
        }
    }

    // MARK: Panel placement per screen layout

    func placement(forLayout key: String) -> PanelPlacement? {
        placements()[key]
    }

    func setPlacement(_ placement: PanelPlacement, forLayout key: String) {
        var all = placements()
        all[key] = placement
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Key.placements) }
    }

    private func placements() -> [String: PanelPlacement] {
        guard let data = defaults.data(forKey: Key.placements),
              let all = try? JSONDecoder().decode([String: PanelPlacement].self, from: data)
        else { return [:] }
        return all
    }
}
