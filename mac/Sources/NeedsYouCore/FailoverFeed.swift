import Foundation

/// Redundant hubs. Hubs replicate to each other server-side and item ids are stable
/// across them, so the app reads from one at a time:
///
/// - Poll the first reachable hub in the configured order. A hub that fails (error or
///   timeout) is skipped for `cooldown`, so a dead primary doesn't cost a timeout on
///   every poll; once the cooldown passes it's tried first again.
/// - When the answering hub differs from the last one, `since` is dropped and a full
///   snapshot is fetched: another hub's `updated_at` history may not line up.
/// - PATCH goes to the hub currently in use, falling back to the others in order if it
///   fails (ids are stable, and the hubs converge).
/// - Merging is by `id` with last-writer-wins on `updated_at` (ItemStore.merge).
public actor FailoverFeed: ItemFeed {
    public struct Hub: Sendable {
        public var name: String
        public var feed: ItemFeed

        public init(name: String, feed: ItemFeed) {
            self.name = name
            self.feed = feed
        }
    }

    public let hubs: [Hub]
    public let cooldown: TimeInterval
    private let clock: @Sendable () -> Date
    private var current: Int?
    private var failedUntil: [Int: Date] = [:]

    public init(hubs: [Hub], cooldown: TimeInterval = 120, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.hubs = hubs
        self.cooldown = cooldown
        self.clock = clock
    }

    /// Name of the hub that answered last.
    public var currentHubName: String? { current.map { hubs[$0].name } }

    /// Healthy hubs first (in configured order), then cooling-down ones as a last resort.
    private func order() -> [Int] {
        let now = clock()
        let healthy = hubs.indices.filter { (failedUntil[$0] ?? .distantPast) <= now }
        let cooling = hubs.indices.filter { !healthy.contains($0) }
        return healthy + cooling
    }

    public func fetchPage(since: Date?) async throws -> FeedPage {
        guard !hubs.isEmpty else { throw HubError.notConfigured }
        var lastError: Error = HubError.notConfigured
        for index in order() {
            let effectiveSince = index == current ? since : nil
            do {
                // The hub's own page: closed items from a `since` poll, its cursor, `more`.
                var page = try await hubs[index].feed.fetchPage(since: effectiveSince)
                current = index
                failedUntil[index] = nil
                page.source = hubs[index].name
                return page
            } catch {
                lastError = error
                failedUntil[index] = clock().addingTimeInterval(cooldown)
            }
        }
        throw lastError
    }

    public func fetchOpen(since: Date?) async throws -> [Item] {
        try await fetchPage(since: since).items
    }

    public func patch(id: String, _ patch: ItemPatch) async throws {
        guard !hubs.isEmpty else { throw HubError.notConfigured }
        let first = current ?? order().first ?? 0
        let attempts = [first] + order().filter { $0 != first }
        var lastError: Error = HubError.notConfigured
        for index in attempts {
            do {
                try await hubs[index].feed.patch(id: id, patch)
                return
            } catch {
                lastError = error
                // An HTTP answer (e.g. 404) means the hub is up; only fail over on transport
                // errors and 421 (this URL's host name is wrong for that hub, another may work).
                if let e = error as? HubError, e != .invalidResponse, e != .misdirected { throw error }
            }
        }
        throw lastError
    }
}

public enum HubName {
    /// A short label for a hub URL: the first DNS label ("hub2" for
    /// http://hub2.tail1234.ts.net:8765), or the whole host for IPs.
    public static func short(_ url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    /// The tokens.json key / identity for a hub: scheme://host[:port][/path], lowercased
    /// host, no trailing slash.
    public static func key(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.host = c.host?.lowercased()
        c.scheme = c.scheme?.lowercased()
        c.query = nil
        c.fragment = nil
        var s = c.string ?? url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
