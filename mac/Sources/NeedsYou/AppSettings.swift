import Foundation
import NeedsYouCore

/// User settings. Hub URLs, the display name and toggles live in UserDefaults; each remote
/// hub's token (and its role) lives in `tokens.json` in the support directory, keyed by the
/// hub URL. Nothing here touches the Keychain.
///
/// Environment overrides (handy for running the binary directly):
///   NEEDS_YOU_DEMO=1                 demo mode, no hub
///   NEEDS_YOU_DEMO_FIXTURE=path.json demo seed items (hub list shape) instead of the built-in set
///   NEEDS_YOU_DEMO_INJECT_SECONDS=n  demo: post a new item every n seconds (default 45, 0 = never)
///   NEEDS_YOU_POLL_SECONDS=n         poll interval (default 30; 5 in demo mode)
///   NEEDS_YOU_EXPAND=1               start expanded (never takes focus)
///   NEEDS_YOU_SNAPSHOT_DIR=dir       debug: write PNGs of each panel state
///   NEEDS_YOU_SUPPORT_DIR=dir        hub.db, owner.token and tokens.json here
///   NEEDS_YOU_DEFAULTS_SUITE=name    use this UserDefaults suite instead of the app's domain
@MainActor
final class AppSettings: ObservableObject {
    let defaults: UserDefaults
    private let env = ProcessInfo.processInfo.environment
    let tokens: FileTokenStore

    private enum Key {
        static let hubURLs = "hubURLs"
        static let userName = "userName"
        static let demoMode = "demoMode"
        static let urgentBreaksSnooze = "urgentBreaksSnooze"
        static let viewContext = "viewContext"
        static let placements = "panelPlacements"
        static let runLocalHub = "runLocalHub"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showMenuBarCount = "showMenuBarCount"
        static let urgentShowsHiddenPanel = "urgentShowsHiddenPanel"
        static let panelHidden = "panelHidden"
        static let snapToCorners = "snapToCorners"
    }

    /// Look and feel: panel size, text size, alerts, and so on (UIPrefs; defaults are the
    /// original look). Each change writes only the keys that changed.
    @Published var ui: UIPrefs {
        didSet { if ui != oldValue { ui.save(to: defaults, previous: oldValue) } }
    }

    /// The app's defaults, or the NEEDS_YOU_DEFAULTS_SUITE suite (test instances).
    nonisolated static func makeDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        if let suite = environment["NEEDS_YOU_DEFAULTS_SUITE"], !suite.isEmpty, let d = UserDefaults(suiteName: suite) {
            return d
        }
        return .standard
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
    /// Kept in memory; `owner.token` (mode 600) is the only stored copy.
    @Published var localHubToken: String?

    // Menu bar and panel visibility. Use AppModel to change these: it enforces
    // VisibilityRules (the icon and the panel can't both be hidden).

    /// Show the menu bar icon. Default on.
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    /// Show the open count next to the menu bar icon. Default on.
    @Published var showMenuBarCount: Bool {
        didSet { defaults.set(showMenuBarCount, forKey: Key.showMenuBarCount) }
    }
    /// An urgent arrival brings back a hidden panel (instead of pulsing the icon). Default off.
    @Published var urgentShowsHiddenPanel: Bool {
        didSet { defaults.set(urgentShowsHiddenPanel, forKey: Key.urgentShowsHiddenPanel) }
    }
    /// The floating panel is hidden (not snoozed); persists across launches.
    @Published var panelHidden: Bool {
        didSet { defaults.set(panelHidden, forKey: Key.panelHidden) }
    }
    /// Dropping the pill snaps it to the nearest corner. Default off: it stays exactly where
    /// it's dropped (clamped to the screen).
    @Published var snapToCorners: Bool {
        didSet { defaults.set(snapToCorners, forKey: Key.snapToCorners) }
    }
    /// Remote hubs were configured when tokens moved out of the Keychain (PrefsMigrator 3).
    @Published var tokensNeedReconnect: Bool {
        didSet { defaults.set(tokensNeedReconnect, forKey: PrefsMigrator.reconnectKey) }
    }

    init(defaults: UserDefaults = AppSettings.makeDefaults(), tokens: FileTokenStore = .standard()) {
        self.defaults = defaults
        self.tokens = tokens
        // Forward-only; never deletes keys (see PrefsMigrator).
        PrefsMigrator.migrate(defaults)
        defaults.register(defaults: [
            Key.urgentBreaksSnooze: true,
            Key.runLocalHub: true,
            Key.showMenuBarIcon: true,
            Key.showMenuBarCount: true,
            Key.urgentShowsHiddenPanel: false,
            Key.panelHidden: false,
            Key.snapToCorners: false,
        ])
        runLocalHub = defaults.bool(forKey: Key.runLocalHub)
        hubURLStrings = defaults.stringArray(forKey: Key.hubURLs) ?? []
        userName = defaults.string(forKey: Key.userName) ?? ""
        demoMode = defaults.bool(forKey: Key.demoMode)
        urgentBreaksSnooze = defaults.bool(forKey: Key.urgentBreaksSnooze)
        viewContext = ItemContext(rawValue: defaults.string(forKey: Key.viewContext) ?? "") ?? .work
        let visibility = VisibilityRules.normalized(showMenuBarIcon: defaults.bool(forKey: Key.showMenuBarIcon),
                                                    panelHidden: defaults.bool(forKey: Key.panelHidden))
        showMenuBarIcon = visibility.showMenuBarIcon
        panelHidden = visibility.panelHidden
        showMenuBarCount = defaults.bool(forKey: Key.showMenuBarCount)
        urgentShowsHiddenPanel = defaults.bool(forKey: Key.urgentShowsHiddenPanel)
        tokensNeedReconnect = defaults.bool(forKey: PrefsMigrator.reconnectKey)
        snapToCorners = defaults.bool(forKey: Key.snapToCorners)
        ui = UIPrefs.load(from: defaults)
        // Stored prefs that hide both the icon and the panel: keep the icon.
        if visibility.showMenuBarIcon != defaults.bool(forKey: Key.showMenuBarIcon) {
            defaults.set(true, forKey: Key.showMenuBarIcon)
        }
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

    // MARK: Tokens (tokens.json)

    func token(for url: URL) -> String? { tokens.token(for: url) }

    /// Save a token (and its role, when known). Returns false if the file couldn't be written.
    @discardableResult
    func saveToken(_ token: String, role: HubRole?, for url: URL) -> Bool {
        do {
            try tokens.set(token, role: role, for: url)
            objectWillChange.send()
            return true
        } catch {
            NSLog("NeedsYou: \(error.localizedDescription)")
            return false
        }
    }

    func removeToken(for url: URL) {
        try? tokens.remove(url)
        objectWillChange.send()
    }

    /// Forget tokens of hubs that are no longer in the list.
    func pruneTokens() {
        try? tokens.prune(keeping: hubURLs)
    }

    /// Remote hubs in the list without a stored token (e.g. after the move off the Keychain).
    var hubsMissingTokens: [URL] { hubURLs.filter { token(for: $0) == nil } }

    /// Hubs that have a token, in failover order. The local hub, when on, is always first.
    func hubConfigs() -> [HubConfig] {
        var configs: [HubConfig] = []
        if runLocalHub, let token = localHubToken, !token.isEmpty {
            configs.append(HubConfig(baseURL: LocalHub.clientURL, token: token))
        }
        configs += hubURLs.compactMap { url in
            guard let token = token(for: url) else { return nil }
            return HubConfig(baseURL: url, token: token)
        }
        return configs
    }

    /// Display name for a hub in the failover feed and status line.
    static func displayName(for url: URL) -> String {
        LocalHub.isLocal(url) ? LocalHub.displayName : HubName.short(url)
    }

    // MARK: Token roles (from the redeem response, stored next to the token)

    /// The role of the token stored for `url`; nil when unknown (entered by hand).
    func role(for url: URL) -> HubRole? {
        if LocalHub.isLocal(url) { return runLocalHub ? .owner : nil }
        return tokens.role(for: url)
    }

    /// Is any configured token an owner token?
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

    func removePlacement(forLayout key: String) {
        var book = PlacementBook.decode(defaults.data(forKey: Key.placements))
        guard book.remove(forLayout: key) else { return }
        if let data = book.encoded() { defaults.set(data, forKey: Key.placements) }
    }
}
