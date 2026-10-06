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
        static let hubRoles = "hubRoles"
        static let runLocalHub = "runLocalHub"
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

    /// Run the bundled hub inside the app (the default: no servers needed).
    @Published var runLocalHub: Bool {
        didSet { defaults.set(runLocalHub, forKey: Key.runLocalHub) }
    }
    /// The local hub's owner token, once LocalHubController has loaded or minted it.
    /// Kept in memory; the token file and the Keychain hold the stored copies.
    @Published var localHubToken: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.urgentBreaksSnooze: true, Key.runLocalHub: true])
        runLocalHub = defaults.bool(forKey: Key.runLocalHub)
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

    /// Remote hubs, in failover order (the local hub is never stored in this list).
    var hubURLs: [URL] { hubURLStrings.compactMap(Self.parseHubURL).filter { !LocalHub.isLocal($0) } }
    var hasHubs: Bool { !hubURLs.isEmpty || runLocalHub }

    func tokenStore(for url: URL) -> KeychainTokenStore {
        KeychainTokenStore(service: Self.keychainService, account: HubName.key(url))
    }

    static var localTokenStore: KeychainTokenStore {
        KeychainTokenStore(service: keychainService, account: HubName.key(LocalHub.clientURL))
    }

    /// Hubs that have a token, in failover order. The local hub, when on, is always first.
    func hubConfigs() -> [HubConfig] {
        var configs: [HubConfig] = []
        if runLocalHub, let token = localHubToken, !token.isEmpty {
            configs.append(HubConfig(baseURL: LocalHub.clientURL, token: token))
        }
        configs += hubURLs.compactMap { url in
            guard let token = tokenStore(for: url).read(), !token.isEmpty else { return nil }
            return HubConfig(baseURL: url, token: token)
        }
        return configs
    }

    /// Display name for a hub in the failover feed and status line.
    static func displayName(for url: URL) -> String {
        LocalHub.isLocal(url) ? LocalHub.displayName : HubName.short(url)
    }

    // MARK: Token roles (from the redeem response)

    private var roleBook: HubRoleBook {
        get { HubRoleBook(plist: defaults.dictionary(forKey: Key.hubRoles) as? [String: String]) }
        set { defaults.set(newValue.plist, forKey: Key.hubRoles) }
    }

    /// The role of the token stored for `url`; nil when unknown (entered by hand).
    func role(for url: URL) -> HubRole? {
        if LocalHub.isLocal(url) { return runLocalHub ? .owner : nil }
        return roleBook.role(for: url)
    }

    func setRole(_ role: HubRole?, for url: URL) {
        var book = roleBook
        book.set(role, for: url)
        book.prune(keeping: hubURLs + [url])
        roleBook = book
        objectWillChange.send()
    }

    /// Forget roles of hubs that are no longer in the list.
    func pruneRoles() {
        var book = roleBook
        book.prune(keeping: hubURLs)
        roleBook = book
    }

    /// Is any configured token an owner token? (No Keychain access.)
    var hasOwnerHub: Bool {
        if runLocalHub, localHubToken != nil { return true }
        return hubURLs.contains { role(for: $0) == .owner }
    }

    /// Hubs whose token may create invites, in failover order (local hub first).
    func ownerHubConfigs() -> [HubConfig] {
        hubConfigs().filter { role(for: $0.baseURL) == .owner }
    }

    // MARK: Panel placement per screen layout (LRU, at most 10 layouts)

    func placement(forLayout key: String) -> PanelPlacement? {
        var book = PlacementBook.decode(defaults.data(forKey: Key.placements))
        guard let placement = book.placement(forLayout: key) else { return nil }
        // Bump the LRU stamp at most hourly; layouts don't change often.
        if let last = book.entries[key]?.lastUsed, Date().timeIntervalSince(last) > 3600 {
            book.touch(key)
            if let data = book.encoded() { defaults.set(data, forKey: Key.placements) }
        }
        return placement
    }

    func setPlacement(_ placement: PanelPlacement, forLayout key: String) {
        var book = PlacementBook.decode(defaults.data(forKey: Key.placements))
        book.set(placement, forLayout: key)
        if let data = book.encoded() { defaults.set(data, forKey: Key.placements) }
    }
}
