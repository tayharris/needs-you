import Foundation

// Usage meters (ADR 0011): `usage` status records as bars, one row per provider and
// account, in the open panel and as two hairlines on the pill. Read-only and quiet: they
// never count, animate or notify. Settings → Usage picks what shows (UsagePrefs).

/// Which windows the meters show.
public enum UsageWindowChoice: String, CaseIterable, Sendable {
    case both, session, weekly

    public var title: String {
        switch self {
        case .both: return "Session and weekly"
        case .session: return "Session (5 hours)"
        case .weekly: return "Weekly"
        }
    }
}

/// Settings → Usage, in UserDefaults as plain values. Unknown or out-of-range stored values
/// fall back to the default; `load` never writes and `save` writes only what changed.
public struct UsagePrefs: Equatable, Sendable {
    public enum Key {
        public static let inPanel = "usageInPanel"
        public static let onPill = "usageOnPill"
        public static let providers = "usageProviders"
        public static let windows = "usageWindows"
        public static let hideUnderPct = "usageHideUnderPct"
        public static let warnPct = "usageWarnPct"
    }

    /// The choices offered for "Hide under" and "Warning colour from".
    public static let hideUnderChoices = [0, 25, 50, 75, 90]
    public static let warnChoices = [50, 60, 70, 75, 80, 90, 95]

    /// A usage section in the open panel. Default on.
    public var inPanel = true
    /// Two hairline meters along the pill's bottom edge. Default on.
    public var onPill = true
    /// Providers to show (`claude`, `codex`, ...); empty: every provider that reports.
    public var providers: [String] = []
    public var windows: UsageWindowChoice = .both
    /// Bars under this percentage are hidden; 0 always shows them.
    public var hideUnderPct = 0
    /// Bars at or past this percentage take the warning colour.
    public var warnPct = 80

    public init() {}

    /// Statuses are fetched only when something shows them.
    public var isShown: Bool { inPanel || onPill }

    public func shows(provider: String) -> Bool { providers.isEmpty || providers.contains(provider) }

    public static func load(from store: UserDefaults) -> UsagePrefs {
        var p = UsagePrefs()
        if let v = store.object(forKey: Key.inPanel) as? NSNumber { p.inPanel = v.boolValue }
        if let v = store.object(forKey: Key.onPill) as? NSNumber { p.onPill = v.boolValue }
        if let v = store.stringArray(forKey: Key.providers) { p.providers = v.filter { !$0.isEmpty } }
        if let raw = store.string(forKey: Key.windows), let v = UsageWindowChoice(rawValue: raw) { p.windows = v }
        if let v = store.object(forKey: Key.hideUnderPct) as? NSNumber, hideUnderChoices.contains(v.intValue) {
            p.hideUnderPct = v.intValue
        }
        if let v = store.object(forKey: Key.warnPct) as? NSNumber, warnChoices.contains(v.intValue) { p.warnPct = v.intValue }
        return p
    }

    public func save(to store: UserDefaults, previous: UsagePrefs? = nil) {
        if previous?.inPanel != inPanel { store.set(inPanel, forKey: Key.inPanel) }
        if previous?.onPill != onPill { store.set(onPill, forKey: Key.onPill) }
        if previous?.providers != providers { store.set(providers, forKey: Key.providers) }
        if previous?.windows != windows { store.set(windows.rawValue, forKey: Key.windows) }
        if previous?.hideUnderPct != hideUnderPct { store.set(hideUnderPct, forKey: Key.hideUnderPct) }
        if previous?.warnPct != warnPct { store.set(warnPct, forKey: Key.warnPct) }
    }
}

public enum UsageLevel: Equatable, Sendable {
    case normal, warning, full
}

/// One window's bar.
public struct UsageBar: Equatable, Sendable, Identifiable {
    /// The window name (`5h`, `7d`, ...).
    public var id: String
    /// "Session", "Weekly", or the window's own name.
    public var title: String
    /// 0-100; 0 once the window has reset.
    public var pct: Double
    public var resetsAt: Date?
    /// `resets_at` has passed since the producer wrote it.
    public var isReset: Bool
    public var level: UsageLevel
    /// "resets 14:00", "resets Tue 09:00", "reset", or nil.
    public var resetText: String?

    /// "51%"
    public var pctText: String { "\(Int(pct.rounded(.down)))%" }
}

/// One provider and account.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public var id: String { provider + "/" + account }
    public var provider: String
    public var account: String
    /// "Claude", or "Claude · team-2".
    public var title: String
    public var bars: [UsageBar]
    /// The machine that reported it last.
    public var host: String?
    public var updatedAt: Date
}

public enum UsageMeters {
    /// Session first, then weekly, then any other window by name.
    static func order(_ name: String) -> Int {
        switch name {
        case "5h": return 0
        case "7d": return 1
        default: return 2
        }
    }

    public static func providerTitle(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    public static func windowTitle(_ name: String) -> String {
        switch name {
        case "5h": return "Session"
        case "7d": return "Weekly"
        default: return name
        }
    }

    static func wanted(_ name: String, _ choice: UsageWindowChoice) -> Bool {
        switch choice {
        case .both: return true
        case .session: return name == "5h"
        case .weekly: return name == "7d"
        }
    }

    public static func level(_ pct: Double, warnPct: Int) -> UsageLevel {
        if pct >= 100 { return .full }
        return pct >= Double(warnPct) ? .warning : .normal
    }

    /// The live usage records, one per provider and account: the newest write wins when
    /// several machines report the same account.
    static func latest(_ statuses: [StatusRecord], now: Date) -> [StatusRecord] {
        var best: [String: StatusRecord] = [:]
        for s in statuses where s.type == "usage" && !s.isExpired(at: now) {
            guard let u = s.usage, !u.provider.isEmpty else { continue }
            let id = u.provider + "/" + u.account
            if let have = best[id], have.updatedAt >= s.updatedAt { continue }
            best[id] = s
        }
        return Array(best.values)
    }

    /// Every provider that reports now (for Settings → Usage), sorted.
    public static func providers(_ statuses: [StatusRecord], now: Date) -> [String] {
        Array(Set(latest(statuses, now: now).compactMap { $0.usage?.provider })).sorted()
    }

    /// The rows to draw, sorted by provider and account. A row whose bars are all hidden
    /// (hide-under, the window choice) is left out.
    public static func rows(_ statuses: [StatusRecord], prefs: UsagePrefs, now: Date,
                            timeZone: TimeZone = .current) -> [UsageRow] {
        latest(statuses, now: now).compactMap { s -> UsageRow? in
            guard let u = s.usage, prefs.shows(provider: u.provider) else { return nil }
            let bars = u.windows
                .filter { wanted($0.name, prefs.windows) }
                .sorted { (order($0.name), $0.name) < (order($1.name), $1.name) }
                .map { bar($0, warnPct: prefs.warnPct, now: now, timeZone: timeZone) }
                .filter { prefs.hideUnderPct <= 0 || $0.pct >= Double(prefs.hideUnderPct) }
            guard !bars.isEmpty else { return nil }
            let title = providerTitle(u.provider) + (u.account.isEmpty ? "" : " · " + u.account)
            return UsageRow(provider: u.provider, account: u.account, title: title, bars: bars,
                            host: s.source?.host, updatedAt: s.updatedAt)
        }
        .sorted { ($0.provider, $0.account) < ($1.provider, $1.account) }
    }

    static func bar(_ w: UsageWindow, warnPct: Int, now: Date, timeZone: TimeZone) -> UsageBar {
        let reset = w.resetsAt.map { $0 <= now } ?? false
        let pct = reset ? 0 : w.usedPct
        return UsageBar(id: w.name, title: windowTitle(w.name), pct: pct, resetsAt: w.resetsAt, isReset: reset,
                        level: level(pct, warnPct: warnPct),
                        resetText: reset ? "reset" : w.resetsAt.map { resetText($0, now: now, timeZone: timeZone) })
    }

    /// "resets 14:00" within 20 hours, else "resets Tue 09:00".
    public static func resetText(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = date.timeIntervalSince(now) < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
        return "resets " + f.string(from: date)
    }

    /// The pill's hairlines: per window shown (session, then weekly), the fullest bar of
    /// any row. At most two.
    public static func pillBars(_ rows: [UsageRow]) -> [UsageBar] {
        ["5h", "7d"].compactMap { name in
            rows.flatMap(\.bars).filter { $0.id == name }.max { $0.pct < $1.pct }
        }
    }

    /// The pill's tooltip addition: "Claude session 51% · weekly 41%".
    public static func summary(_ rows: [UsageRow]) -> String {
        rows.map { row in
            row.title + " " + row.bars.map { "\($0.title.lowercased()) \($0.pctText)" }.joined(separator: " · ")
        }.joined(separator: "; ")
    }
}
