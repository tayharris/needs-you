import Foundation

// Bypass rules (Settings → Alerts, and a card's "Alerts for This Session" menu) and the
// noisy-sender guard (docs/roadmap/focus-tiers.md, "Bypass"). Priority and `source.event` are
// the sender's say; these rules are the person's.

/// What a rule matches on.
public enum BypassMatch: String, Codable, CaseIterable, Sendable {
    /// The item key starts with the value (`agent:` = every Claude Code session).
    case keyPrefix
    /// One agent session: the item key is the value (`agent:<host>:<session>`), or starts with
    /// it and a colon (the session's context card, `…:context`).
    case session
    /// `source.agent` starts with the value, ignoring case (`orca:`, `claude-code`).
    case agentPrefix
    /// `source.host` is the value, ignoring case (`devbox`).
    case host

    public var title: String {
        switch self {
        case .keyPrefix: return "Key starts with"
        case .session: return "Session key is"
        case .agentPrefix: return "Agent starts with"
        case .host: return "Host is"
        }
    }
}

/// What a matching rule does: to the tier, or to the priority the app treats the item as.
public enum BypassAction: String, Codable, CaseIterable, Sendable {
    /// Shown, sorted, counted and delivered as urgent (RuleBook.effectivePriority): red, and
    /// it interrupts as urgent does (Settings → Alerts → Delivery still applies).
    case urgent
    /// Interrupt whatever the focus or snooze (a hidden panel stays hidden).
    case alwaysInterrupt
    /// Ambient at most.
    case neverInterrupt
    /// Always held under Later.
    case alwaysLater
    /// Shown, sorted and delivered as low.
    case low

    public var title: String {
        switch self {
        case .urgent: return "Treat as urgent"
        case .alwaysInterrupt: return "Always interrupt"
        case .neverInterrupt: return "Never interrupt"
        case .alwaysLater: return "Always later"
        case .low: return "Treat as low"
        }
    }

    /// Title case, for menus.
    public var menuTitle: String {
        switch self {
        case .urgent: return "Treat as Urgent"
        case .alwaysInterrupt: return "Always Interrupt"
        case .neverInterrupt: return "Never Interrupt"
        case .alwaysLater: return "Always Later"
        case .low: return "Treat as Low"
        }
    }

    /// The priority the item is treated as, for the two actions that set one.
    public var priority: ItemPriority? {
        switch self {
        case .urgent: return .urgent
        case .low: return .low
        case .alwaysInterrupt, .neverInterrupt, .alwaysLater: return nil
        }
    }
}

/// The `source.event` values docs/API.md gives a meaning (others are allowed and matched as
/// written).
public enum AgentEvent: String, CaseIterable, Sendable {
    case question, approval, finished, failed, context

    /// "Only When It Asks", for the card menu.
    public var menuTitle: String {
        switch self {
        case .question: return "Only When It Asks"
        case .approval: return "Only When It Needs Approval"
        case .finished: return "Only When It Finishes"
        case .failed: return "Only When It Fails"
        case .context: return "Only When Its Context Is Nearly Full"
        }
    }

    /// For the Settings rule editor.
    public var title: String {
        switch self {
        case .question: return "When it asks"
        case .approval: return "When it needs approval"
        case .finished: return "When it finishes"
        case .failed: return "When it fails"
        case .context: return "When context is nearly full"
        }
    }

    /// A `source.event` value: `^[a-z][a-z0-9_-]{0,31}$` (docs/API.md).
    public static func isValid(_ raw: String) -> Bool {
        let v = raw.unicodeScalars.map(\.value)
        func lower(_ c: UInt32) -> Bool { c >= 0x61 && c <= 0x7A }
        guard let first = v.first, v.count <= 32, lower(first) else { return false }
        return v.allSatisfy { lower($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D }
    }

    /// The editor's title for any event value: the known ones by name, others as written.
    public static func title(of raw: String?) -> String {
        guard let raw else { return "Any event" }
        return AgentEvent(rawValue: raw)?.title ?? "When the event is \(raw)"
    }
}

public struct BypassRule: Codable, Hashable, Sendable {
    public static let maxValueLength = 200

    public var match: BypassMatch
    public var value: String
    public var action: BypassAction
    /// Only items whose `source.event` is this (`question`, `failed`, …); nil: any item.
    public var event: String?

    /// Nil when the value is empty (after trimming), too long or has control characters, or
    /// the event isn't a `source.event` slug. An empty event means any.
    public init?(match: BypassMatch, value: String, action: BypassAction, event: String? = nil) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidValue(v) else { return nil }
        let e = event?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let e, !e.isEmpty, !AgentEvent.isValid(e) { return nil }
        self.match = match
        self.value = v
        self.action = action
        self.event = (e?.isEmpty ?? true) ? nil : e
    }

    public static func isValidValue(_ v: String) -> Bool {
        !v.isEmpty && v.count <= maxValueLength
            && !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }

    enum CodingKeys: String, CodingKey { case match, value, action, event }

    /// A rule this build can't apply exactly (an unknown match or action, a bad event) throws,
    /// and RuleBook.decode skips it. A rule without `event` (every rule before it) is for any.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let match = try c.decode(BypassMatch.self, forKey: .match)
        let value = try c.decode(String.self, forKey: .value)
        let action = try c.decode(BypassAction.self, forKey: .action)
        let event = try c.decodeIfPresent(String.self, forKey: .event)
        guard let rule = BypassRule(match: match, value: value, action: action, event: event) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Invalid rule value")
        }
        self = rule
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(match, forKey: .match)
        try c.encode(value, forKey: .value)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(event, forKey: .event)
    }

    public func matches(_ item: Item) -> Bool {
        if let event, item.source?.event != event { return false }
        switch match {
        case .keyPrefix:
            return item.key.hasPrefix(value)
        case .session:
            return item.key == value || item.key.hasPrefix(value + ":")
        case .agentPrefix:
            guard let agent = item.source?.agent else { return false }
            return agent.lowercased().hasPrefix(value.lowercased())
        case .host:
            guard let host = item.source?.host else { return false }
            return host.lowercased() == value.lowercased()
        }
    }
}

/// The ordered rule list: at most `maxRules`, first match wins. Stored as JSON in
/// UserDefaults (`bypassRules`); decoding skips entries it doesn't understand (a newer
/// build's match or action) instead of losing the whole list.
public struct RuleBook: Equatable, Sendable {
    public static let maxRules = 50
    public static let defaultsKey = "bypassRules"

    public private(set) var rules: [BypassRule]

    public init(_ rules: [BypassRule] = []) {
        self.rules = Array(rules.prefix(Self.maxRules))
    }

    public var isEmpty: Bool { rules.isEmpty }
    public var isFull: Bool { rules.count >= Self.maxRules }

    public func firstMatch(_ item: Item) -> BypassRule? {
        rules.first { $0.matches(item) }
    }

    /// The priority the app treats `item` as: its first matching rule's "Treat as urgent" or
    /// "Treat as low", else the sender's. Every view, sort, count and tier decision reads
    /// this (through `applied(to:)` on the items in the store, and DeliveryPolicy directly).
    public func effectivePriority(_ item: Item) -> ItemPriority {
        let sender = item.senderPriority ?? item.priority
        return firstMatch(item)?.action.priority ?? sender
    }

    /// `item` with `priority` set to its effective priority and the sender's kept in
    /// `senderPriority`. Idempotent: apply it again with other rules and it starts from the
    /// sender's.
    public func applied(to item: Item) -> Item {
        var out = item
        out.senderPriority = item.senderPriority ?? item.priority
        out.priority = effectivePriority(item)
        return out
    }

    /// A copy with `rule` first (a rule made from a card wins over the rest); unchanged when
    /// the book is full.
    public func inserting(_ rule: BypassRule) -> RuleBook {
        isFull ? self : RuleBook([rule] + rules)
    }

    /// A copy without the rules `drop` picks.
    public func removing(where drop: (BypassRule) -> Bool) -> RuleBook {
        RuleBook(rules.filter { !drop($0) })
    }

    private struct Lossy: Decodable {
        let rule: BypassRule?
        init(from decoder: Decoder) throws { rule = try? BypassRule(from: decoder) }
    }

    public static func decode(_ data: Data?) -> RuleBook {
        guard let data, let list = try? JSONDecoder().decode([Lossy].self, from: data) else { return RuleBook() }
        return RuleBook(list.compactMap(\.rule))
    }

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(rules)
    }
}

/// A sender (`source.host` + `source.agent`) whose items would interrupt more than
/// `threshold` times in a sliding hour is held to ambient until the oldest of those falls
/// out of the window. Keeps a looping automation from defeating the tiers; the hub's
/// open-item limit stays the hard cap. In memory only, bounded to `maxSenders`.
public struct NoisySenderGuard: Sendable {
    public static let defaultThreshold = 6
    public static let defaultWindow: TimeInterval = 3600
    public static let maxSenders = 200

    public let threshold: Int
    public let window: TimeInterval
    private var stamps: [String: [Date]] = [:]

    public init(threshold: Int = NoisySenderGuard.defaultThreshold, window: TimeInterval = NoisySenderGuard.defaultWindow) {
        self.threshold = max(1, threshold)
        self.window = window
    }

    /// `devbox|orca:redo-fixer`; items without a source share one bucket.
    public static func senderID(_ item: Item) -> String {
        "\(item.source?.host ?? "")|\(item.source?.agent ?? "")"
    }

    /// `devbox · orca:redo-fixer`, or "an unnamed sender".
    public static func displayName(_ senderID: String) -> String {
        let parts = senderID.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        return parts.isEmpty ? "an unnamed sender" : parts.joined(separator: " · ")
    }

    /// Asks to interrupt for `item`. Records it and returns true while the sender is under
    /// the threshold; false (nothing recorded) when it's held.
    public mutating func admit(_ item: Item, now: Date) -> Bool {
        prune(now: now)
        let id = Self.senderID(item)
        var list = stamps[id] ?? []
        guard list.count < threshold else { return false }
        list.append(now)
        stamps[id] = list
        if stamps.count > Self.maxSenders {
            // Forget the senders that interrupted longest ago.
            let keep = stamps.sorted { ($0.value.last ?? .distantPast) > ($1.value.last ?? .distantPast) }.prefix(Self.maxSenders)
            stamps = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return true
    }

    /// Senders held right now, by sender id, sorted.
    public func heldSenders(now: Date) -> [String] {
        stamps.filter { $0.value.filter { now.timeIntervalSince($0) < window }.count >= threshold }.keys.sorted()
    }

    public var trackedSenderCount: Int { stamps.count }

    private mutating func prune(now: Date) {
        for (id, list) in stamps {
            let recent = list.filter { now.timeIntervalSince($0) < window }
            stamps[id] = recent.isEmpty ? nil : recent
        }
    }
}
