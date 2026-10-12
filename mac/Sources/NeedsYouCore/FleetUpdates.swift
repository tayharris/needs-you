import Foundation

// Settings → Updates → Machines and hubs (ADR 0013): every sender machine and every server hub
// with its version, whether it's behind, and a Request update for each (Update all for the
// ones behind). Senders come from GET /v1/tokens (RolloutStatus, MachineUpdateState); hubs
// from the local hub's GET /v1/peers plus the other owner hubs, each asked GET /v1/hub/update
// at its own URL.

/// The versions machines and hubs are judged against.
public enum FleetTarget {
    /// The newest version this app knows of: its own, or a newer release its update check saw
    /// (offered, waiting out the soak, skipped or blocked). Hubs update from GitHub, so that
    /// release is what a requested hub update installs.
    public static func newest(app: SemVer?, seen: SemVer?) -> SemVer? {
        switch (app, seen) {
        case let (a?, s?): return max(a, s)
        case let (a?, nil): return a
        case let (nil, s?): return s
        default: return nil
        }
    }
}

extension UpdateDecision {
    /// The release version the last update check saw, whatever it decided about it.
    public var seenVersion: SemVer? {
        switch self {
        case .upToDate: return nil
        case .skipped(let v, _): return v
        case .blocked(let v, _): return v
        case .wait(let c, _), .ready(let c): return c.version
        }
    }
}

/// A hub to show, and the owner token to ask it with.
public struct FleetHubEndpoint: Equatable, Sendable {
    public var url: URL
    public var name: String
    public var token: String

    public init(url: URL, name: String, token: String) {
        self.url = url
        self.name = name
        self.token = token
    }

    /// The local hub's peers (asked with this Mac's owner token: tokens replicate to peers) and
    /// the other owner hubs the app is connected to (their own tokens win), once each, never
    /// the Mac's own hub (it updates with the app).
    public static func plan(peers: [PeerSummary], ownerHubs: [HubConfig], localToken: String?) -> [FleetHubEndpoint] {
        let localKey = HubName.key(LocalHub.clientURL)
        var out: [FleetHubEndpoint] = []
        var index: [String: Int] = [:]
        func add(_ url: URL, name: String, token: String, override: Bool) {
            let key = HubName.key(url)
            guard key != localKey, !LocalHub.isLocal(url) else { return }
            if let i = index[key] {
                if override { out[i].token = token }
                return
            }
            index[key] = out.count
            out.append(FleetHubEndpoint(url: url, name: name, token: token))
        }
        if let localToken, !localToken.isEmpty {
            for peer in peers {
                guard let url = URL(string: peer.url), url.scheme != nil, url.host != nil else { continue }
                add(url, name: peer.displayName, token: localToken, override: false)
            }
        }
        for hub in ownerHubs {
            add(hub.baseURL, name: HubName.short(hub.baseURL), token: hub.token, override: true)
        }
        return out
    }
}

/// What the app last learned about one hub.
public struct FleetHub: Equatable, Identifiable, Sendable {
    public var url: URL
    public var name: String
    /// From GET /v1/hub/update, or /v1/health for a hub without it. Nil when unreachable.
    public var version: String?
    /// Nil when the hub predates /v1/hub/update, or couldn't be reached.
    public var status: HubUpdateStatus?
    /// Why it couldn't be asked (unreachable, rejected the token, ...).
    public var error: String?

    public var id: String { HubName.key(url) }

    public init(url: URL, name: String, version: String? = nil, status: HubUpdateStatus? = nil, error: String? = nil) {
        self.url = url
        self.name = name
        self.version = version ?? status?.version
        self.status = status
        self.error = error
    }

    public func behind(_ target: SemVer?) -> Bool {
        guard let target, let v = version.flatMap(SemVer.init) else { return false }
        return v < target
    }
}

/// The trailing control on a hub's row.
public enum HubUpdateState: Equatable, Sendable {
    /// Couldn't ask it (the error text).
    case unknown(String)
    /// It has no /v1/hub/update: shown with its version only.
    case tooOld
    case current
    /// Behind, and it can be asked.
    case outdated
    /// Behind, but it can't update itself on request (the hub's reason).
    case unavailable(String)
    case requested(Date?)
    /// Its updater is running ("Checking…", "Updating to 0.5.2…").
    case working(String)
    /// The last run failed (the updater's line); it can be asked again.
    case failed(String)

    public init(hub: FleetHub, target: SemVer?) {
        guard let status = hub.status else {
            if hub.version != nil, hub.error == nil { self = .tooOld; return }
            self = .unknown(hub.error ?? "Not reached yet. Refresh to try again.")
            return
        }
        switch status.state {
        case .requested: self = .requested(status.requestedAt); return
        case .checking: self = .working("Checking for a newer release…"); return
        case .updating: self = .working("Updating\(status.target.map { " to \($0)" } ?? "")…"); return
        default: break
        }
        guard hub.behind(target) else { self = .current; return }
        if !status.available { self = .unavailable(status.reason ?? "It can't update itself on request."); return }
        if status.state == .failed { self = .failed(status.message ?? "The last update failed."); return }
        self = .outdated
    }

    public var canRequest: Bool {
        switch self {
        case .outdated, .failed: return true
        default: return false
        }
    }
}

extension FleetHub {
    /// The line under the hub's name: version, channel, and what its updater last did.
    public func detail(now: Date) -> String {
        var parts: [String] = []
        parts.append(version.map { "Hub \($0)" } ?? "Version unknown")
        if let channel = status?.channel, channel != "stable" { parts.append("\(channel) channel") }
        if let status {
            func ago(_ d: Date?) -> String {
                guard let d else { return "" }
                let age = now.timeIntervalSince(d)
                return age < 60 ? " just now" : " \(CardAge.short(age)) ago"
            }
            switch status.state {
            case .updated:
                let from = status.fromVersion.map { " from \($0)" } ?? ""
                parts.append("updated\(from)\(ago(status.finishedAt))")
            case .upToDate:
                parts.append("checked\(ago(status.finishedAt))")
            case .off:
                parts.append("automatic updates off")
            default:
                break
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// The section's summary and what Update all would ask.
public struct FleetSummary: Equatable, Sendable {
    public var machines: Int
    public var machinesBehind: Int
    public var hubs: Int
    public var hubsBehind: Int
    /// Sender tokens Update all asks: seen in the last 14 days, a CLI older than the sender
    /// target (or never reported), no request pending.
    public var tokensToAsk: [TokenSummary]
    /// Hubs Update all asks: behind the hub target and askable.
    public var hubsToAsk: [FleetHub]

    public init(tokens: [TokenSummary], senderTarget: SemVer?, hubs: [FleetHub], hubTarget: SemVer?, now: Date) {
        let rollout = RolloutStatus(tokens: tokens, target: senderTarget, now: now)
        let recent = Set(rollout.rows.map(\.id))
        machines = rollout.recent
        machinesBehind = rollout.behind
        tokensToAsk = tokens.filter { recent.contains($0.id) && MachineUpdateState(token: $0, target: senderTarget).canRequest }
        self.hubs = hubs.count
        hubsBehind = hubs.filter { $0.behind(hubTarget) }.count
        hubsToAsk = hubs.filter { $0.behind(hubTarget) && HubUpdateState(hub: $0, target: hubTarget).canRequest }
    }

    public var updateAllCount: Int { tokensToAsk.count + hubsToAsk.count }

    public var text: String {
        func part(_ behind: Int, _ total: Int, _ one: String, _ many: String) -> String {
            let noun = total == 1 ? one : many
            if behind > 0 { return "\(behind) of \(total) \(noun) out of date" }
            return total == 1 ? "1 \(noun) up to date" : "all \(total) \(noun) up to date"
        }
        var parts: [String] = []
        if machines > 0 { parts.append(part(machinesBehind, machines, "machine", "machines")) }
        if hubs > 0 { parts.append(part(hubsBehind, hubs, "hub", "hubs")) }
        guard !parts.isEmpty else { return "No sender machines seen in the last 14 days, and no server hubs." }
        let s = parts.joined(separator: "; ")
        return s.prefix(1).uppercased() + s.dropFirst() + "."
    }
}
