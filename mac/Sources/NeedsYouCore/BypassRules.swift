import Foundation

// Bypass rules (Settings → Alerts) and the noisy-sender guard
// (docs/roadmap/focus-tiers.md, "Bypass"). Senders get no new field: priority is their
// lever, and these rules are the person's.

/// What a rule matches on.
public enum BypassMatch: String, Codable, CaseIterable, Sendable {
    /// The item key starts with the value (`agent:` = every Claude Code session).
    case keyPrefix
    /// `source.agent` starts with the value, ignoring case (`orca:`, `claude-code`).
    case agentPrefix
    /// `source.host` is the value, ignoring case (`devbox`).
    case host

    public var title: String {
        switch self {
        case .keyPrefix: return "Key starts with"
        case .agentPrefix: return "Agent starts with"
        case .host: return "Host is"
        }
    }
}

/// What a matching rule does to the tier.
public enum BypassAction: String, Codable, CaseIterable, Sendable {
    /// Interrupt whatever the focus or snooze (a hidden panel stays hidden).
    case alwaysInterrupt
    /// Ambient at most.
    case neverInterrupt
    /// Always held under Later.
    case alwaysLater

    public var title: String {
        switch self {
        case .alwaysInterrupt: return "Always interrupt"
        case .neverInterrupt: return "Never interrupt"
        case .alwaysLater: return "Always later"
        }
    }
}

public struct BypassRule: Codable, Hashable, Sendable {
    public static let maxValueLength = 200

    public var match: BypassMatch
    public var value: String
    public var action: BypassAction

    /// Nil when the value is empty (after trimming), too long or has control characters.
    public init?(match: BypassMatch, value: String, action: BypassAction) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidValue(v) else { return nil }
        self.match = match
        self.value = v
        self.action = action
    }

    public static func isValidValue(_ v: String) -> Bool {
        !v.isEmpty && v.count <= maxValueLength
            && !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }

    enum CodingKeys: String, CodingKey { case match, value, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let match = try c.decode(BypassMatch.self, forKey: .match)
        let value = try c.decode(String.self, forKey: .value)
        let action = try c.decode(BypassAction.self, forKey: .action)
        guard let rule = BypassRule(match: match, value: value, action: action) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Invalid rule value")
        }
        self = rule
    }

    public func matches(_ item: Item) -> Bool {
        switch match {
        case .keyPrefix:
            return item.key.hasPrefix(value)
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
