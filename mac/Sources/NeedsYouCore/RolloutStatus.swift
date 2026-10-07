import Foundation

/// "2 of 5 machines out of date" (docs/roadmap/rollout-updates.md): sender tokens seen in the
/// last 14 days, against the version this app (and so its hub's /dl) carries. Each machine
/// reports its versions in X-Needs-You-Client; GET /v1/tokens lists them.
public struct RolloutStatus: Equatable, Sendable {
    public static let recentWindow: TimeInterval = 14 * 86_400

    public struct Row: Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var detail: String
        /// A reported version is older than the target.
        public var behind: Bool
        /// Seen in the window but hasn't reported versions (a CLI before 0.1.2).
        public var unreported: Bool
    }

    public var rows: [Row]
    public var recent: Int
    public var behind: Int
    public var unreported: Int

    public init(tokens: [TokenSummary], target: SemVer?, now: Date) {
        var rows: [Row] = []
        for t in tokens where t.role == .sender {
            guard let seen = t.lastSeenAt, now.timeIntervalSince(seen) <= Self.recentWindow else { continue }
            let versions = ["cli", "hook", "skill", "orca"].compactMap { k in t.client[k].map { (k, $0) } }
            let behind = target.map { target in versions.contains { SemVer($0.1).map { $0 < target } ?? false } } ?? false
            let age = now.timeIntervalSince(seen)
            let seenText = age < 60 ? "seen now" : "seen \(CardAge.short(age)) ago"
            let head = versions.isEmpty
                ? ["no versions reported (old CLI)"]
                : versions.map { "\($0.0 == "cli" ? "CLI" : $0.0) \($0.1)" }
            rows.append(Row(id: t.id, name: t.name, detail: (head + [seenText]).joined(separator: " · "),
                            behind: behind, unreported: versions.isEmpty))
        }
        self.rows = rows.sorted { ($0.behind ? 0 : 1, $0.name) < ($1.behind ? 0 : 1, $1.name) }
        recent = rows.count
        behind = rows.filter(\.behind).count
        unreported = rows.filter(\.unreported).count
    }

    public var summary: String {
        if recent == 0 { return "No sender machines seen in the last 14 days." }
        let machines = recent == 1 ? "machine" : "machines"
        var s = behind == 0 ? "All \(recent) \(machines) up to date." : "\(behind) of \(recent) \(machines) out of date."
        if unreported > 0 { s += " \(unreported) not reporting versions yet." }
        return s
    }

    /// Merges the token lists of several hubs (versions are per hub): per token id, the
    /// entry seen most recently wins.
    public static func merge(_ lists: [[TokenSummary]]) -> [TokenSummary] {
        var byID: [String: TokenSummary] = [:]
        var order: [String] = []
        for list in lists {
            for t in list {
                if let old = byID[t.id] {
                    if (t.lastSeenAt ?? .distantPast) > (old.lastSeenAt ?? .distantPast) { byID[t.id] = t }
                } else {
                    byID[t.id] = t
                    order.append(t.id)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }
}
