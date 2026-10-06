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

    /// Forget a layout's placement (Reset Position): the panel goes back to the default.
    @discardableResult
    public mutating func remove(forLayout key: String) -> Bool {
        entries.removeValue(forKey: key) != nil
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

/// Forward-only migrations of the app's UserDefaults, run once at launch.
///
/// - `prefsVersion` records the newest schema these prefs have been migrated to.
/// - Each migration runs at most once, in order, and only moves data forward. Unknown keys
///   are never deleted, so rolling back to an older build (or a newer build's extra keys)
///   loses nothing.
/// - Prefs written by a newer build (`prefsVersion` above ours) are left exactly as they
///   are, and the version is never lowered.
public enum PrefsMigrator {
    public static let versionKey = "prefsVersion"
    /// Set by migration 3 when remote hubs were configured: their tokens were in the
    /// Keychain, which this build never reads, so they need re-connecting once.
    public static let reconnectKey = "tokensNeedReconnect"

    public struct Migration {
        public let version: Int
        public let run: (UserDefaults) -> Void

        public init(version: Int, run: @escaping (UserDefaults) -> Void) {
            self.version = version
            self.run = run
        }
    }

    /// This build's migrations. Append new ones; never edit, reorder or delete old ones,
    /// and never remove a key in one (an older build may read it again after a rollback).
    public static let all: [Migration] = [
        // 1: the baseline (phase 2 prefs); nothing to change.
        Migration(version: 1) { _ in },
        // 2: panel placements move from a plain [layout: placement] dictionary to the LRU
        //    PlacementBook (at most 10 layouts).
        Migration(version: 2) { defaults in
            let key = "panelPlacements"
            guard let data = defaults.data(forKey: key) else { return }
            if (try? JSONDecoder().decode(PlacementBook.self, from: data)) != nil { return }
            if let encoded = PlacementBook.decode(data).encoded() { defaults.set(encoded, forKey: key) }
        },
        // 3: hub tokens moved from the Keychain to tokens.json. The Keychain is deliberately
        //    not read (on a Mac whose login keychain password is out of sync that prompts
        //    forever), so remote hubs are re-connected once with a link. `hubRoles` is left
        //    in place for older builds; roles now live in tokens.json.
        Migration(version: 3) { defaults in
            if !(defaults.stringArray(forKey: "hubURLs") ?? []).isEmpty {
                defaults.set(true, forKey: reconnectKey)
            }
        },
    ]

    public static var currentVersion: Int { all.map(\.version).max() ?? 0 }

    /// Runs pending migrations. Returns the versions that ran.
    @discardableResult
    public static func migrate(_ defaults: UserDefaults, migrations: [Migration] = all) -> [Int] {
        let stored = defaults.integer(forKey: versionKey)   // 0 when missing (new, or pre-versioning)
        let target = migrations.map(\.version).max() ?? 0
        guard stored < target else { return [] }
        var ran: [Int] = []
        for m in migrations.sorted(by: { $0.version < $1.version }) where m.version > stored {
            m.run(defaults)
            defaults.set(m.version, forKey: versionKey)   // record progress step by step
            ran.append(m.version)
        }
        return ran
    }
}
