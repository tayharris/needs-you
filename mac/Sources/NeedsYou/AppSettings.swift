import Foundation
import NeedsYouCore

/// User settings. The hub URL and toggles live in UserDefaults; the token lives in the
/// Keychain (PLAN.md, "Credentials").
///
/// Environment overrides (handy for running the binary directly):
///   NEEDS_YOU_DEMO=1                 demo mode, no hub, no Keychain access
///   NEEDS_YOU_DEMO_FIXTURE=path.json demo seed items (hub list shape) instead of the built-in set
///   NEEDS_YOU_DEMO_INJECT_SECONDS=n  demo: post a new item every n seconds (default 45, 0 = never)
///   NEEDS_YOU_POLL_SECONDS=n         poll interval (default 30; 5 in demo mode)
///   NEEDS_YOU_EXPAND=1               start expanded
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private let env = ProcessInfo.processInfo.environment
    let tokenStore = KeychainTokenStore()

    private enum Key {
        static let hubURL = "hubURL"
        static let demoMode = "demoMode"
        static let urgentBreaksSnooze = "urgentBreaksSnooze"
        static let viewContext = "viewContext"
        static let placements = "panelPlacements"
    }

    @Published var hubURLString: String {
        didSet { defaults.set(hubURLString, forKey: Key.hubURL) }
    }
    @Published var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: Key.demoMode) }
    }
    /// PLAN.md open decision 2: urgent items break through a snooze. Default on.
    @Published var urgentBreaksSnooze: Bool {
        didSet { defaults.set(urgentBreaksSnooze, forKey: Key.urgentBreaksSnooze) }
    }
    /// The context shown when picked by hand in the expanded header.
    @Published var viewContext: ItemContext {
        didSet { defaults.set(viewContext.rawValue, forKey: Key.viewContext) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.urgentBreaksSnooze: true])
        hubURLString = defaults.string(forKey: Key.hubURL) ?? ""
        demoMode = defaults.bool(forKey: Key.demoMode)
        urgentBreaksSnooze = defaults.bool(forKey: Key.urgentBreaksSnooze)
        viewContext = ItemContext(rawValue: defaults.string(forKey: Key.viewContext) ?? "") ?? .work
    }

    // MARK: Derived

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

    /// A usable hub URL: http(s) with a host. Plain http is expected on the tailnet.
    var hubURL: URL? {
        let trimmed = hubURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    func hubConfig() -> HubConfig? {
        guard let url = hubURL, let token = tokenStore.read(), !token.isEmpty else { return nil }
        return HubConfig(baseURL: url, token: token)
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
