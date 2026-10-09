import Foundation

// A card's "Alerts for This Session" and "Alerts for All <agent> Sessions" menus: bypass
// rules made from an agent card in one click (docs/roadmap/focus-tiers.md, "Bypass"). The
// state and edits live here so they're testable; the view only draws them. The first match
// wins, so rules made here go in by specificity (RuleBook.inserting): above Settings' rules, a
// session's above its agent's, an event rule above the same scope's any-event rule.

/// Who a card-made rule is for.
public enum RuleScope: Hashable, Sendable {
    /// One agent session: `.session` on `agent:<host>:<session>`.
    case session(String)
    /// Every session of one agent: `.agentPrefix` on `source.agent` (`claude-code`).
    case agent(String)

    public var match: BypassMatch {
        switch self {
        case .session: return .session
        case .agent: return .agentPrefix
        }
    }

    public var value: String {
        switch self {
        case .session(let key): return key
        case .agent(let name): return name
        }
    }

    public var menuTitle: String {
        switch self {
        case .session: return "Alerts for This Session"
        case .agent(let name): return "Alerts for All \(name) Sessions"
        }
    }

    /// The scopes a card offers: an agent card (`agent:` key) its session, and a card with a
    /// `source.agent` that agent. Neither for anything else.
    public static func scopes(for item: Item) -> [RuleScope] {
        guard let key = sessionKey(item.key) else { return [] }
        var out: [RuleScope] = [.session(key)]
        if let agent = item.source?.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
           BypassRule.isValidValue(agent) {
            out.append(.agent(agent))
        }
        return out
    }

    /// `agent:<host>:<session>` for any card of that session (the context card is
    /// `agent:<host>:<session>:context`); nil for keys that aren't an agent session's.
    public static func sessionKey(_ key: String) -> String? {
        guard key.hasPrefix(FocusLevel.agentKeyPrefix) else { return nil }
        let parts = key.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        let session = parts[0...2].joined(separator: ":")
        return BypassRule.isValidValue(session) ? session : nil
    }
}

public enum AlertRuleMenu {
    /// The actions the card menu offers, in order.
    public static let actions: [BypassAction] = [.urgent, .alwaysInterrupt, .neverInterrupt, .alwaysLater]
    /// The "Only When It…" narrowings, in order.
    public static let events: [AgentEvent] = [.question, .approval, .finished, .failed]

    static func isScope(_ rule: BypassRule, _ scope: RuleScope) -> Bool {
        rule.match == scope.match && rule.value == scope.value
    }

    /// The scope's rule for exactly this event (nil: for any event), if there is one.
    static func existing(_ book: RuleBook, _ scope: RuleScope, event: String?) -> (index: Int, rule: BypassRule)? {
        guard let i = book.rules.firstIndex(where: { isScope($0, scope) && $0.event == event }) else { return nil }
        return (i, book.rules[i])
    }

    /// Whether the rule at `index` never applies because an earlier rule matches every item
    /// it does (`covers`): the same scope for any event or the same event, or a broader rule
    /// such as Settings' "Agents Always Interrupt" (key prefix `agent:`) above a session's.
    static func isShadowed(_ book: RuleBook, at index: Int) -> Bool {
        let rule = book.rules[index]
        return book.rules[..<index].contains { covers($0, rule) }
    }

    /// Whether `a` matches every item `b` matches (so `b` below `a` never applies). Only the
    /// cases that can be told from the rules: a key prefix covers the keys and sessions that
    /// start with it, a session itself and the keys under it, an agent prefix the longer
    /// agent prefixes, a host the same host.
    static func covers(_ a: BypassRule, _ b: BypassRule) -> Bool {
        guard a.event == nil || a.event == b.event else { return false }
        switch (a.match, b.match) {
        case (.keyPrefix, .keyPrefix), (.keyPrefix, .session):
            return b.value.hasPrefix(a.value)
        case (.session, .session):
            return b.value == a.value || b.value.hasPrefix(a.value + ":")
        case (.session, .keyPrefix):
            return b.value.hasPrefix(a.value + ":")
        case (.agentPrefix, .agentPrefix):
            return b.value.lowercased().hasPrefix(a.value.lowercased())
        case (.host, .host):
            return a.value.lowercased() == b.value.lowercased()
        default:
            return false
        }
    }

    /// The action of the scope's rule for exactly this event (nil: for any event), when it
    /// applies: the checkmark. A shadowed rule gets none, and choosing it re-places it.
    public static func current(_ book: RuleBook, _ scope: RuleScope, event: String?) -> BypassAction? {
        guard let found = existing(book, scope, event: event), !isShadowed(book, at: found.index) else { return nil }
        return found.rule.action
    }

    /// Whether the scope has any rule (enables "Remove Rules").
    public static func hasRules(_ book: RuleBook, _ scope: RuleScope) -> Bool {
        book.rules.contains { isScope($0, scope) }
    }

    /// Whether choosing `action` can be saved: it replaces a rule, or there's room for one.
    public static func canChoose(_ book: RuleBook, _ scope: RuleScope, event: String?) -> Bool {
        !book.isFull || existing(book, scope, event: event) != nil
    }

    /// Picking a menu item: the checked action again removes the rule; another replaces the
    /// scope's rule for that event with a new one, placed by specificity (RuleBook.inserting).
    public static func choosing(_ action: BypassAction, in book: RuleBook, _ scope: RuleScope,
                                event: String?) -> RuleBook {
        let was = current(book, scope, event: event)
        let rest = book.removing { isScope($0, scope) && $0.event == event }
        guard was != action, let rule = BypassRule(match: scope.match, value: scope.value, action: action, event: event)
        else { return rest }
        return rest.inserting(rule)
    }

    /// "Remove Rules": every rule of the scope, whatever its event.
    public static func removingAll(in book: RuleBook, _ scope: RuleScope) -> RuleBook {
        book.removing { isScope($0, scope) }
    }

    /// A one-line summary of the scope's rules that apply, in the order they do ("Treat as
    /// urgent when it asks; Always interrupt"), nil when there are none.
    public static func summary(_ book: RuleBook, _ scope: RuleScope) -> String? {
        let mine = book.rules.indices.filter { isScope(book.rules[$0], scope) && !isShadowed(book, at: $0) }
            .map { book.rules[$0] }
        guard !mine.isEmpty else { return nil }
        return mine.map { rule in
            rule.event.map { "\(rule.action.title) \(AgentEvent.title(of: $0).lowercased())" } ?? rule.action.title
        }.joined(separator: "; ")
    }
}
