import Foundation

// The item shape from docs/PLAN.md "Data model". Decoding is lenient about values the
// app doesn't know yet (a newer hub adding a kind or priority must not break polling).

public enum ItemContext: String, Codable, CaseIterable, Sendable {
    case work, personal

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemContext(rawValue: raw.lowercased()) ?? .work
    }

    public var other: ItemContext { self == .work ? .personal : .work }
}

public enum ItemKind: String, Codable, Sendable {
    case needs, done, info

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown kinds are treated as info so they never raise the count.
        self = ItemKind(rawValue: raw.lowercased()) ?? .info
    }
}

public enum ItemPriority: String, Codable, CaseIterable, Sendable, Comparable {
    case urgent, normal, low

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemPriority(rawValue: raw.lowercased()) ?? .normal
    }

    /// urgent sorts first.
    public var rank: Int {
        switch self {
        case .urgent: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    public static func < (lhs: ItemPriority, rhs: ItemPriority) -> Bool { lhs.rank < rhs.rank }
}

public enum ItemStatus: String, Codable, Sendable {
    case open, resolved, dismissed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Anything that isn't recognisably open is treated as closed.
        self = ItemStatus(rawValue: raw.lowercased()) ?? .resolved
    }
}

public struct ItemLink: Codable, Hashable, Sendable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// One thing the person has to do, in order (`steps` in docs/API.md). `text` is limited
/// markdown; `link` is a button (shown as plain text if its scheme isn't allowed); `done`
/// is the sender's view. Decoding is lenient: a missing `done` is false, a malformed link
/// is dropped, unknown fields are ignored.
public struct ItemStep: Codable, Hashable, Sendable {
    public var text: String
    public var link: ItemLink?
    public var done: Bool

    enum CodingKeys: String, CodingKey { case text, link, done }

    public init(text: String, link: ItemLink? = nil, done: Bool = false) {
        self.text = text
        self.link = link
        self.done = done
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        link = try? c.decodeIfPresent(ItemLink.self, forKey: .link)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

public struct ItemSource: Codable, Hashable, Sendable {
    public var host: String?
    public var agent: String?
    public var project: String?

    public init(host: String? = nil, agent: String? = nil, project: String? = nil) {
        self.host = host
        self.agent = agent
        self.project = project
    }

    /// `devbox · orca:redo-fixer`, skipping empty parts.
    public var displayParts: [String] {
        [host, agent].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

public struct Item: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var key: String
    public var context: ItemContext
    public var kind: ItemKind
    public var priority: ItemPriority
    public var title: String
    public var body: String?
    public var links: [ItemLink]
    /// The checklist; empty for items without one (and from hubs that predate steps).
    public var steps: [ItemStep]
    public var source: ItemSource?
    public var status: ItemStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var seenAt: Date?
    public var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, key, context, kind, priority, title, body, links, steps, source, status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seenAt = "seen_at"
        case expiresAt = "expires_at"
    }

    public init(
        id: String, key: String, context: ItemContext = .work, kind: ItemKind = .needs,
        priority: ItemPriority = .normal, title: String, body: String? = nil,
        links: [ItemLink] = [], steps: [ItemStep] = [], source: ItemSource? = nil, status: ItemStatus = .open,
        createdAt: Date, updatedAt: Date? = nil, seenAt: Date? = nil, expiresAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.context = context
        self.kind = kind
        self.priority = priority
        self.title = title
        self.body = body
        self.links = links
        self.steps = steps
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.seenAt = seenAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? id
        context = try c.decodeIfPresent(ItemContext.self, forKey: .context) ?? .work
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .needs
        priority = try c.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .normal
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        body = try c.decodeIfPresent(String.self, forKey: .body)
        links = try c.decodeIfPresent([ItemLink].self, forKey: .links) ?? []
        // Lenient: a malformed steps value never costs the item; steps without text are skipped.
        steps = ((try? c.decodeIfPresent([ItemStep].self, forKey: .steps)) ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        source = try c.decodeIfPresent(ItemSource.self, forKey: .source)
        status = try c.decodeIfPresent(ItemStatus.self, forKey: .status) ?? .open
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        seenAt = try c.decodeIfPresent(Date.self, forKey: .seenAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    /// Re-animation rule (docs/API.md `content_updated_at`): title, body, priority or steps.
    public func hasVisibleChange(from old: Item) -> Bool {
        title != old.title || body != old.body || priority != old.priority || steps != old.steps
    }

    public func isExpired(at now: Date) -> Bool {
        if let expiresAt { return expiresAt <= now }
        return false
    }
}

// MARK: - JSON

public enum HubJSON {
    /// ISO 8601 with or without fractional seconds, plus a numeric epoch fallback.
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
        }
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func parseDate(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        guard s.count >= 19 else { return nil }
        // Split "YYYY-MM-DDTHH:MM:SS" + optional ".ffffff" + optional zone.
        let head = String(s.prefix(19))
        var rest = Substring(s.dropFirst(19))
        var fraction = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            let digits = rest.prefix(while: { $0.isNumber })
            fraction = String(digits.prefix(3))
            rest = rest.dropFirst(digits.count)
        }
        // Python's isoformat() without a zone: assume UTC.
        let zone = rest.isEmpty ? "Z" : String(rest)
        s = head + (fraction.isEmpty ? "" : "." + fraction) + zone

        let f = ISO8601DateFormatter()
        f.formatOptions = fraction.isEmpty
            ? [.withInternetDateTime]
            : [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// The hub's list response isn't pinned down in PLAN.md: accept either a bare array
    /// or an object wrapping it as `items`.
    public static func decodeItemList(_ data: Data) throws -> [Item] {
        let decoder = makeDecoder()
        if let items = try? decoder.decode([Item].self, from: data) { return items }
        struct Wrapped: Decodable { let items: [Item] }
        return try decoder.decode(Wrapped.self, from: data).items
    }
}
