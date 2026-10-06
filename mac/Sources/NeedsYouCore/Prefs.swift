import Foundation

// Small, self-limiting preference records. Everything the app persists is a handful of
// UserDefaults keys; these types make sure the per-layout and per-hub ones can't grow
// without bound.

/// Panel placement per screen layout, least-recently-used, capped at `capacity` layouts.
public struct PlacementBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var placement: PanelPlacement
        public var lastUsed: Date
    }

    public static let defaultCapacity = 10
    public private(set) var entries: [String: Entry] = [:]
    public var capacity: Int

    public init(capacity: Int = PlacementBook.defaultCapacity) {
        self.capacity = capacity
    }

    enum CodingKeys: String, CodingKey { case entries, capacity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([String: Entry].self, forKey: .entries)
        capacity = (try? c.decode(Int.self, forKey: .capacity)) ?? Self.defaultCapacity
    }

    /// Decodes the current format, or the old plain `[layout: PanelPlacement]` dictionary.
    public static func decode(_ data: Data?, now: Date = Date()) -> PlacementBook {
        guard let data else { return PlacementBook() }
        if let book = try? JSONDecoder().decode(PlacementBook.self, from: data) {
            var b = book
            b.trim()
            return b
        }
        if let legacy = try? JSONDecoder().decode([String: PanelPlacement].self, from: data) {
            var book = PlacementBook()
            for (key, placement) in legacy.sorted(by: { $0.key < $1.key }) {
                book.entries[key] = Entry(placement: placement, lastUsed: now)
            }
            book.trim()
            return book
        }
        return PlacementBook()
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public func placement(forLayout key: String) -> PanelPlacement? { entries[key]?.placement }

    /// Marks a layout as in use (so it isn't the one evicted). Returns true if anything changed.
    @discardableResult
    public mutating func touch(_ key: String, now: Date = Date()) -> Bool {
        guard entries[key] != nil else { return false }
        entries[key]?.lastUsed = now
        return true
    }

    public mutating func set(_ placement: PanelPlacement, forLayout key: String, now: Date = Date()) {
        entries[key] = Entry(placement: placement, lastUsed: now)
        trim()
    }

    /// Drop the least recently used layouts beyond `capacity`.
    public mutating func trim() {
        let cap = max(capacity, 1)
        guard entries.count > cap else { return }
        let keep = entries.sorted {
            $0.value.lastUsed != $1.value.lastUsed ? $0.value.lastUsed > $1.value.lastUsed : $0.key < $1.key
        }.prefix(cap)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

/// The role of the token stored for each hub (from the redeem response), keyed by
/// `HubName.key`. Only hubs still in the list are kept.
public struct HubRoleBook: Equatable, Sendable {
    public private(set) var roles: [String: HubRole]

    public init(roles: [String: HubRole] = [:]) {
        self.roles = roles
    }

    public init(plist: [String: String]?) {
        var r: [String: HubRole] = [:]
        for (k, v) in plist ?? [:] { if let role = HubRole(rawValue: v) { r[k] = role } }
        roles = r
    }

    public var plist: [String: String] { roles.mapValues(\.rawValue) }

    public func role(for url: URL) -> HubRole? { roles[HubName.key(url)] }

    /// nil forgets the role (a hand-entered token's role is unknown).
    public mutating func set(_ role: HubRole?, for url: URL) {
        roles[HubName.key(url)] = role
    }

    /// Forget roles for hubs that are no longer configured.
    public mutating func prune(keeping urls: [URL]) {
        let keep = Set(urls.map(HubName.key))
        roles = roles.filter { keep.contains($0.key) }
    }
}
