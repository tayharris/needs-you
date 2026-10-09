import Foundation

// Always-on hubs that replicate with this Mac's hub (ADR 0012).
//
// Hub contract:
//   POST /v1/invites {name, role: "peer", uses: 1, ttl_hours}  (Bearer owner)
//        → 201 {code, join_url, install_command, expires_at}; the server runs install_command
//   GET /v1/peers                                               (Bearer owner)
//        → {peers: [{url, hub_id, name, source, added_at, outbox_pending, last_push_ok,
//                    last_pull_ok, last_error, blocked, ...}]}
//   DELETE /v1/peers/<hub_id>                                   (Bearer owner) → {removed: [...]}
// Peer secrets never reach the app: the hubs keep them in their databases.

/// POST /v1/invites for another hub: one use, short-lived.
public struct PeerInviteRequest: Encodable, Equatable, Sendable {
    public var name: String
    public let role = "peer"
    public let uses = 1
    public var ttlHours: Int

    enum CodingKeys: String, CodingKey {
        case name, role, uses
        case ttlHours = "ttl_hours"
    }

    /// The hub allows 1–24 hours; 1 by default.
    public static let ttlRange = 1...24

    public init(name: String, ttlHours: Int = 1) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ttlHours = min(max(ttlHours, Self.ttlRange.lowerBound), Self.ttlRange.upperBound)
    }
}

/// One peer as `GET /v1/peers` (or `/v1/health`'s `peers`) lists it. Never carries a secret.
public struct PeerSummary: Decodable, Equatable, Identifiable, Sendable {
    public enum Source: String, Sendable {
        /// From the hub's config (hand-set, shared mesh secret).
        case config
        /// From a peer invite (its own secret, removable from Settings).
        case invite
    }

    public var url: String
    public var hubID: String?
    public var name: String?
    public var source: Source?
    public var addedAt: Date?
    public var outboxPending: Int
    public var lastPushOK: Date?
    public var lastPullOK: Date?
    public var lastError: String?
    public var blocked: String?

    public var id: String { url }

    enum CodingKeys: String, CodingKey {
        case url, name, source, blocked
        case hubID = "hub_id"
        case addedAt = "added_at"
        case outboxPending = "outbox_pending"
        case lastPushOK = "last_push_ok"
        case lastPullOK = "last_pull_ok"
        case lastError = "last_error"
    }

    public init(url: String, hubID: String? = nil, name: String? = nil, source: Source? = .invite,
                addedAt: Date? = nil, outboxPending: Int = 0, lastPushOK: Date? = nil, lastPullOK: Date? = nil,
                lastError: String? = nil, blocked: String? = nil) {
        self.url = url
        self.hubID = hubID
        self.name = name
        self.source = source
        self.addedAt = addedAt
        self.outboxPending = outboxPending
        self.lastPushOK = lastPushOK
        self.lastPullOK = lastPullOK
        self.lastError = lastError
        self.blocked = blocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        func string(_ k: CodingKeys) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) }
        hubID = string(.hubID)
        name = string(.name)
        source = string(.source).flatMap(Source.init(rawValue:))
        addedAt = string(.addedAt).flatMap(HubJSON.parseDate)
        outboxPending = ((try? c.decodeIfPresent(Int.self, forKey: .outboxPending)) ?? nil) ?? 0
        lastPushOK = string(.lastPushOK).flatMap(HubJSON.parseDate)
        lastPullOK = string(.lastPullOK).flatMap(HubJSON.parseDate)
        lastError = string(.lastError)
        blocked = string(.blocked)
    }

    /// The hub's name for Settings: its hub id, else the URL's host.
    public var displayName: String {
        if let hubID, !hubID.isEmpty { return hubID }
        return URL(string: url)?.host ?? url
    }

    /// Only links from a peer invite can be removed from the app (config peers live in a file).
    public var removable: Bool { source == .invite && !(hubID ?? "").isEmpty }

    /// The last time replication with it worked, either way.
    public var lastSync: Date? {
        switch (lastPushOK, lastPullOK) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

/// What Settings says about a peer.
public enum PeerState: Equatable, Sendable {
    /// Added, nothing exchanged yet (the server may still be installing).
    case waiting
    /// Replicating: last sync recent, nothing queued.
    case connected(lastSync: Date)
    /// Writes queued for it (it's asleep, off, or unreachable for now).
    case behind(pending: Int, lastSync: Date?)
    /// The last attempt failed and nothing worked for a while.
    case failing(String, lastSync: Date?)
    /// A record one side can't read holds replication (an older hub).
    case blocked(String)

    /// No sync for this long with an error standing is "failing" rather than "behind".
    public static let staleAfter: TimeInterval = 180

    public init(_ peer: PeerSummary, now: Date) {
        if let b = peer.blocked, !b.isEmpty { self = .blocked(b); return }
        let last = peer.lastSync
        if let err = peer.lastError, !err.isEmpty {
            // Failing once nothing has worked for a while: since the last sync, or since it
            // was added (a new server gets a few minutes to come up).
            let since = last ?? peer.addedAt
            if since.map({ now.timeIntervalSince($0) > Self.staleAfter }) ?? true {
                self = .failing(err, lastSync: last)
                return
            }
        }
        if peer.outboxPending > 0 { self = .behind(pending: peer.outboxPending, lastSync: last); return }
        guard let last else { self = .waiting; return }
        self = .connected(lastSync: last)
    }

    /// One line for the row under the hub's name.
    public func label(now: Date) -> String {
        func ago(_ d: Date?) -> String {
            guard let d else { return "never synced" }
            let age = now.timeIntervalSince(d)
            return age < 60 ? "synced just now" : "synced \(CardAge.short(age)) ago"
        }
        switch self {
        case .waiting:
            return "Waiting for the hub to start"
        case .connected(let last):
            return "Connected, " + ago(last)
        case .behind(let n, let last):
            return "Behind by \(n) change\(n == 1 ? "" : "s"), " + ago(last)
        case .failing(let err, let last):
            return "Can't reach it (\(PeerState.shortError(err))), " + ago(last)
        case .blocked:
            return "Held: one hub runs an older version. Update both."
        }
    }

    /// The hub's error text, cut for one line.
    static func shortError(_ s: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    public var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// The command a server runs to join this Mac's hub with a peer invite (the hub's
/// PEER_JOIN_COMMAND): the installer of a release from GitHub, the join link on its stdin.
/// It runs as root, so it's built only from checked parts: a join URL of the hub's shape,
/// single-quoted as the hub's _sh_quote does, and an X.Y.Z version.
public enum PeerJoinCommand {
    /// http(s)://host[:port][/prefix]/join/nyi_<code>, nothing else (no quote, space, `$`).
    static let joinURLPattern = #"^https?://(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~-]+)*/join/nyi_[A-Za-z0-9_-]{16,64}\z"#
    static let versionPattern = #"^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}\z"#

    public static func isJoinURL(_ value: String) -> Bool {
        value.range(of: joinURLPattern, options: .regularExpression) != nil
    }

    /// One shell word, as the hub's _sh_quote: '…', with each ' written as '"'"'.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The command for `joinURL` and release `version`, or nil when either isn't of its shape.
    public static func command(joinURL: String, version: String,
                               repository: String = UpdateSource.defaultRepository) -> String? {
        guard isJoinURL(joinURL), version.range(of: versionPattern, options: .regularExpression) != nil else {
            return nil
        }
        return "(curl -fsSL https://github.com/\(repository)/releases/download/v\(version)/install-hub.sh && echo "
            + shellQuote(joinURL) + ") | sudo bash -s -- --join -"
    }

    /// What Settings shows: the hub's install_command when it is exactly the command built
    /// here for its join URL and the version it names, else the one built with the app's
    /// version; nil when the join URL isn't a join URL (nothing to run).
    public static func resolve(joinURL: String, hubCommand: String?, appVersion: String?) -> String? {
        guard isJoinURL(joinURL) else { return nil }
        if let hubCommand,
           let r = hubCommand.range(of: #"/releases/download/v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}/"#,
                                    options: .regularExpression) {
            let version = String(hubCommand[r].dropFirst("/releases/download/v".count).dropLast())
            if command(joinURL: joinURL, version: version) == hubCommand { return hubCommand }
        }
        return appVersion.flatMap { command(joinURL: joinURL, version: $0) }
    }
}
