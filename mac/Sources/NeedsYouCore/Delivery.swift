import Foundation

// Delivery tiers (docs/roadmap/focus-tiers.md): how loudly a new or changed item arrives.
// Pure rules, so every cell of the tier table is a unit test. Tiers only decide the
// arrival; once an item is on the list it is the same card whatever its tier.

/// How an arrival is delivered, loudest first.
public enum DeliveryTier: String, CaseIterable, Codable, Sendable, Comparable {
    /// The spring-out preview with a glow pulse (urgent twice); breaks through a snooze or
    /// focus where the rules say so.
    case interrupt
    /// No spring-out: the count and ring change, with one soft brighten of the pill.
    case ambient
    /// Not announced and not counted: kept under Later and delivered as one quiet peek when
    /// the focus or snooze ends, or at the start of the day.
    case later

    public var title: String {
        switch self {
        case .interrupt: return "Interrupt"
        case .ambient: return "Ambient"
        case .later: return "Later"
        }
    }

    public var detail: String {
        switch self {
        case .interrupt: return "Springs out with a glow"
        case .ambient: return "Count and one soft glow"
        case .later: return "Held until focus ends"
        }
    }

    var quietness: Int {
        switch self {
        case .interrupt: return 0
        case .ambient: return 1
        case .later: return 2
        }
    }

    /// Ordered loudest to quietest: `interrupt < ambient < later`.
    public static func < (lhs: DeliveryTier, rhs: DeliveryTier) -> Bool { lhs.quietness < rhs.quietness }

    /// The quieter of two tiers.
    public static func quieter(_ a: DeliveryTier, _ b: DeliveryTier) -> DeliveryTier { max(a, b) }
}

// MARK: - Focus

/// The in-app focus (right-click the pill, the menu bar, or `needsyou://focus`).
/// Raw values are what `needsyou://focus?level=` takes.
public enum FocusLevel: String, CaseIterable, Sendable {
    case off
    /// Agent cards (`agent:` keys, the Claude Code hook) and urgent items interrupt;
    /// everything else waits under Later.
    case agentsAndUrgent = "agents"
    /// Only urgent items interrupt.
    case urgentOnly = "urgent"
    /// Everything waits, urgent too. Only an "Always interrupt" bypass rule gets through.
    case everythingLater = "later"

    /// The levels offered in the Focus menus (Off is listed separately).
    public static let choices: [FocusLevel] = [.agentsAndUrgent, .urgentOnly, .everythingLater]

    public var title: String {
        switch self {
        case .off: return "Off"
        case .agentsAndUrgent: return "Agents and urgent only"
        case .urgentOnly: return "Urgent only"
        case .everythingLater: return "Everything later"
        }
    }

    /// The key prefix the agent level lets through (AGENT-GUIDE: `agent:<host>:<session>`).
    public static let agentKeyPrefix = "agent:"
}

/// Who set the focus: the menus, or a `needsyou://focus` link (Shortcuts, scripts).
public enum FocusSource: String, Sendable {
    case menu, link
}

/// The focus level and when it ends (nil: until turned off). Persisted in UserDefaults
/// (`focusLevel`, `focusUntil`, `focusSource`) so a relaunch keeps it.
public struct FocusState: Equatable, Sendable {
    public var level: FocusLevel
    public var until: Date?
    public var source: FocusSource

    public init(level: FocusLevel, until: Date? = nil, source: FocusSource = .menu) {
        self.level = level
        self.until = level == .off ? nil : until
        self.source = source
    }

    public static let off = FocusState(level: .off)

    /// The level in force at `now`: off once `until` has passed.
    public func effectiveLevel(at now: Date) -> FocusLevel {
        guard level != .off else { return .off }
        if let until, until <= now { return .off }
        return level
    }

    public func isActive(at now: Date) -> Bool { effectiveLevel(at: now) != .off }

    /// "Urgent only until 14:30", "Everything later", or nil when off.
    public func summary(at now: Date, time: (Date) -> String) -> String? {
        let level = effectiveLevel(at: now)
        guard level != .off else { return nil }
        if let until { return "\(level.title) until \(time(until))" }
        return level.title
    }

    public enum Key {
        public static let level = "focusLevel"
        public static let until = "focusUntil"
        public static let source = "focusSource"
    }

    /// The stored focus; unknown or expired values load as off.
    public static func load(from store: UserDefaults, now: Date = Date()) -> FocusState {
        guard let raw = store.string(forKey: Key.level), let level = FocusLevel(rawValue: raw), level != .off else { return .off }
        let until = store.object(forKey: Key.until) as? Date
        let source = store.string(forKey: Key.source).flatMap(FocusSource.init(rawValue:)) ?? .menu
        let state = FocusState(level: level, until: until, source: source)
        return state.isActive(at: now) ? state : .off
    }

    public func save(to store: UserDefaults) {
        store.set(level.rawValue, forKey: Key.level)
        if let until { store.set(until, forKey: Key.until) } else { store.removeObject(forKey: Key.until) }
        store.set(source.rawValue, forKey: Key.source)
    }
}

/// How long a focus from the menus lasts.
public enum FocusDuration: String, CaseIterable, Identifiable, Sendable {
    case minutes30, hour1, hours2, tomorrow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minutes30: return "30 min"
        case .hour1: return "1 hr"
        case .hours2: return "2 hr"
        case .tomorrow: return "Until tomorrow"
        }
    }

    /// "Until tomorrow" ends at the start of the default work day, like the snooze.
    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes30: return now.addingTimeInterval(30 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .hours2: return now.addingTimeInterval(2 * 60 * 60)
        case .tomorrow: return SnoozeOption.tomorrow.until(from: now, calendar: calendar)
        }
    }
}

// MARK: - Defaults (Settings → Alerts)

/// The tier each kind of arrival gets with no focus, no snooze and no rule. Urgent always
/// interrupts. Stored as plain strings; unknown values fall back to the default.
public struct DeliveryDefaults: Equatable, Sendable {
    public enum Key {
        public static let normal = "tierNormal"
        public static let low = "tierLow"
        public static let recent = "tierDoneInfo"
        public static let otherContext = "tierOtherContext"
        public static let urgentBreaksFocus = "urgentBreaksFocus"
    }

    /// `needs` normal, in the current context.
    public var normal: DeliveryTier = .interrupt
    /// `needs` low, in the current context.
    public var low: DeliveryTier = .ambient
    /// `done` and `info` items (Recent; never counted).
    public var recent: DeliveryTier = .ambient
    /// Non-urgent items for the other context (the faint second number).
    public var otherContext: DeliveryTier = .later
    /// Urgent items interrupt under the agents and urgent-only focus levels. Off (for a
    /// presentation): they arrive ambient instead.
    public var urgentBreaksFocus = true

    public init() {}

    public static let standard = DeliveryDefaults()

    public static let needsChoices: [DeliveryTier] = DeliveryTier.allCases
    /// Done/info and other-context items never interrupt by default (a bypass rule can).
    public static let quietChoices: [DeliveryTier] = [.ambient, .later]

    public static func load(from store: UserDefaults) -> DeliveryDefaults {
        var d = DeliveryDefaults()
        func tier(_ key: String, _ choices: [DeliveryTier]) -> DeliveryTier? {
            store.string(forKey: key).flatMap(DeliveryTier.init(rawValue:)).flatMap { choices.contains($0) ? $0 : nil }
        }
        if let v = tier(Key.normal, needsChoices) { d.normal = v }
        if let v = tier(Key.low, needsChoices) { d.low = v }
        if let v = tier(Key.recent, quietChoices) { d.recent = v }
        if let v = tier(Key.otherContext, quietChoices) { d.otherContext = v }
        if let v = store.object(forKey: Key.urgentBreaksFocus) as? NSNumber { d.urgentBreaksFocus = v.boolValue }
        return d
    }

    /// Writes the keys whose value differs from `previous` (all of them when nil).
    public func save(to store: UserDefaults, previous: DeliveryDefaults? = nil) {
        if previous?.normal != normal { store.set(normal.rawValue, forKey: Key.normal) }
        if previous?.low != low { store.set(low.rawValue, forKey: Key.low) }
        if previous?.recent != recent { store.set(recent.rawValue, forKey: Key.recent) }
        if previous?.otherContext != otherContext { store.set(otherContext.rawValue, forKey: Key.otherContext) }
        if previous?.urgentBreaksFocus != urgentBreaksFocus { store.set(urgentBreaksFocus, forKey: Key.urgentBreaksFocus) }
    }
}

// MARK: - Policy

/// Everything the tier depends on besides the item.
public struct DeliveryState: Sendable {
    /// The context being shown (schedule or override).
    public var context: ItemContext
    public var visibility: PanelVisibility
    /// The focus level in force (FocusState.effectiveLevel).
    public var focus: FocusLevel
    public var defaults: DeliveryDefaults
    public var rules: RuleBook
    /// Settings → Alerts: an urgent arrival ends a snooze (default on).
    public var urgentBreaksSnooze: Bool
    /// Settings → Alerts: an urgent arrival shows a hidden panel (default off).
    public var urgentShowsHiddenPanel: Bool
    public var now: Date

    public init(context: ItemContext = .work, visibility: PanelVisibility = .shown, focus: FocusLevel = .off,
                defaults: DeliveryDefaults = .standard, rules: RuleBook = RuleBook(),
                urgentBreaksSnooze: Bool = true, urgentShowsHiddenPanel: Bool = false, now: Date = Date()) {
        self.context = context
        self.visibility = visibility
        self.focus = focus
        self.defaults = defaults
        self.rules = rules
        self.urgentBreaksSnooze = urgentBreaksSnooze
        self.urgentShowsHiddenPanel = urgentShowsHiddenPanel
        self.now = now
    }
}

/// Why an item got its tier (for tests, and the Later section's wording).
public enum DeliveryReason: String, Sendable {
    /// The defaults for its priority and kind.
    case standard
    /// A non-urgent item for the other context: the faint second number, never held.
    case otherContext
    case focus
    case snooze
    case hidden
    case rule
    /// NoisySenderGuard held a sender that interrupted too often this hour.
    case noisySender
}

public struct DeliveryDecision: Equatable, Sendable {
    public var tier: DeliveryTier
    public var reason: DeliveryReason
    /// Later items to collect in the Later list (open `needs` items held back by focus, a
    /// snooze, a rule or the defaults; not other-context ones, which are just elsewhere).
    public var holdsForLater: Bool

    public init(tier: DeliveryTier, reason: DeliveryReason, holdsForLater: Bool = false) {
        self.tier = tier
        self.reason = reason
        self.holdsForLater = holdsForLater
    }
}

/// The tier table from docs/roadmap/focus-tiers.md ("Default mapping"). With no focus and
/// no rules, the snoozed and hidden results match the old SnoozeBreakthrough and
/// HiddenArrivalPolicy, which now delegate here.
public enum DeliveryPolicy {
    static func isOpenUrgent(_ item: Item) -> Bool {
        item.kind == .needs && item.priority == .urgent && item.status == .open
    }

    public static func decide(_ item: Item, state: DeliveryState) -> DeliveryDecision {
        let urgent = isOpenUrgent(item)
        let inContext = item.context == state.context
        let d = state.defaults

        // 1. The defaults. Urgent interrupts in either context (AGENT-GUIDE: broken now).
        var tier: DeliveryTier
        var reason = DeliveryReason.standard
        if urgent {
            tier = .interrupt
        } else if !inContext {
            tier = d.otherContext
            reason = .otherContext
        } else if item.kind != .needs {
            tier = d.recent
        } else {
            tier = item.priority == .low ? d.low : d.normal
        }

        func quiet(to other: DeliveryTier, because why: DeliveryReason) {
            guard other > tier else { return }
            tier = other
            if reason != .otherContext { reason = why }
        }

        // 2. Focus only ever makes an arrival quieter.
        switch state.focus {
        case .off:
            break
        case .agentsAndUrgent:
            if urgent {
                quiet(to: d.urgentBreaksFocus ? .interrupt : .ambient, because: .focus)
            } else if item.kind == .needs && item.key.hasPrefix(FocusLevel.agentKeyPrefix) {
                break
            } else {
                quiet(to: .later, because: .focus)
            }
        case .urgentOnly:
            quiet(to: urgent ? (d.urgentBreaksFocus ? .interrupt : .ambient) : .later, because: .focus)
        case .everythingLater:
            quiet(to: .later, because: .focus)
        }

        // 3. Snoozed or hidden panel.
        let hiddenCap: DeliveryTier?
        switch state.visibility {
        case .shown:
            hiddenCap = nil
        case .snoozed(let until):
            hiddenCap = nil
            if until > state.now {
                quiet(to: urgent ? (state.urgentBreaksSnooze ? .interrupt : .ambient) : .later, because: .snooze)
            }
        case .hidden:
            // Hidden is an explicit choice: arrivals still count (the menu bar), and only an
            // urgent item with "show the panel even when hidden" brings it back.
            hiddenCap = urgent && state.urgentShowsHiddenPanel ? .interrupt : .ambient
            quiet(to: hiddenCap ?? .ambient, because: .hidden)
        }

        // 4. Bypass rules, first match wins.
        if let rule = state.rules.firstMatch(item) {
            switch rule.action {
            case .alwaysInterrupt:
                tier = hiddenCap ?? .interrupt
                reason = .rule
            case .neverInterrupt:
                if tier == .interrupt {
                    tier = .ambient
                    reason = .rule
                }
            case .alwaysLater:
                tier = .later
                reason = .rule
            }
        }

        let holds = tier == .later && item.kind == .needs && item.status == .open && reason != .otherContext
        return DeliveryDecision(tier: tier, reason: reason, holdsForLater: holds)
    }

    /// What a batch of arrivals does while the panel is out of sight: any interrupt shows
    /// the panel, an urgent item held to ambient pulses the menu bar icon once.
    public static func hiddenArrival(_ decided: [(item: Item, decision: DeliveryDecision)]) -> HiddenArrival {
        if decided.contains(where: { $0.decision.tier == .interrupt }) { return .showPanel }
        if decided.contains(where: { isOpenUrgent($0.item) && $0.decision.tier == .ambient }) { return .pulseMenuBar }
        return .none
    }

    // MARK: Preview (Settings → Alerts)

    /// The rows of the read-only tier table in Settings.
    public enum PreviewRow: String, CaseIterable, Sendable {
        case urgent, normal, low, agent, doneInfo, otherContext

        public var title: String {
            switch self {
            case .urgent: return "Urgent"
            case .normal: return "Normal"
            case .low: return "Low"
            case .agent: return "Agent waiting (normal)"
            case .doneInfo: return "Done and info"
            case .otherContext: return "Other context"
            }
        }

        func sample(context: ItemContext) -> Item {
            let t = Date(timeIntervalSince1970: 0)
            switch self {
            case .urgent: return Item(id: "p-u", key: "p:u", context: context, priority: .urgent, title: "", createdAt: t)
            case .normal: return Item(id: "p-n", key: "p:n", context: context, priority: .normal, title: "", createdAt: t)
            case .low: return Item(id: "p-l", key: "p:l", context: context, priority: .low, title: "", createdAt: t)
            case .agent: return Item(id: "p-a", key: "agent:host:session", context: context, priority: .normal, title: "", createdAt: t)
            case .doneInfo: return Item(id: "p-d", key: "p:d", context: context, kind: .done, priority: .normal, title: "", createdAt: t)
            case .otherContext: return Item(id: "p-o", key: "p:o", context: context.other, priority: .normal, title: "", createdAt: t)
            }
        }
    }

    /// The columns: each focus level, then snoozed.
    public enum PreviewColumn: Hashable, Sendable {
        case focus(FocusLevel)
        case snoozed

        public static let all: [PreviewColumn] = FocusLevel.allCases.map { .focus($0) } + [.snoozed]

        public var title: String {
            switch self {
            case .focus(.off): return "No focus"
            case .focus(.agentsAndUrgent): return "Agents + urgent"
            case .focus(.urgentOnly): return "Urgent only"
            case .focus(.everythingLater): return "All later"
            case .snoozed: return "Snoozed"
            }
        }
    }

    /// One cell: the tier `row` gets under `column` with these settings (no rules).
    public static func preview(_ row: PreviewRow, _ column: PreviewColumn, defaults: DeliveryDefaults,
                               urgentBreaksSnooze: Bool) -> DeliveryTier {
        let now = Date(timeIntervalSince1970: 0)
        var state = DeliveryState(context: .work, defaults: defaults, urgentBreaksSnooze: urgentBreaksSnooze, now: now)
        switch column {
        case .focus(let level): state.focus = level
        case .snoozed: state.visibility = .snoozed(until: now.addingTimeInterval(600))
        }
        return decide(row.sample(context: .work), state: state).tier
    }
}

// MARK: - The Later digest

/// When held items are delivered.
public enum LaterRelease: String, Sendable {
    case focusEnded, snoozeEnded, startOfDay, byHand
}

/// "3 waited while you were focused": the one quiet peek when Later is delivered.
public struct LaterDigest: Equatable, Sendable {
    public var count: Int
    public var reason: LaterRelease
    public var priority: ItemPriority

    public init(count: Int, reason: LaterRelease, priority: ItemPriority = .normal) {
        self.count = count
        self.reason = reason
        self.priority = priority
    }

    public var text: String {
        let verb = count == 1 ? "1 waited" : "\(count) waited"
        switch reason {
        case .focusEnded: return "\(verb) while you were focused"
        case .snoozeEnded: return "\(verb) while you were snoozed"
        case .startOfDay: return "\(verb) for the start of the day"
        case .byHand: return "\(verb) under Later"
        }
    }
}
