import Foundation

/// Card ages, for spotting stale cards (docs/roadmap/stale-items.md, option D). Every card's
/// meta line has a short age ("5m", "2h"); cards older than `oldAfter` show it as a badge
/// next to the title instead ("5 h", "2 d", "3 w"), emphasised once they're stale.
public enum CardAge {
    /// A card this old gets the badge.
    public static let oldAfter: TimeInterval = 4 * 3600
    /// A card this old is probably stale: the badge is emphasised.
    public static let staleAfter: TimeInterval = 2 * 86_400

    /// "now", "5m", "2h", "3d" for the meta line.
    public static func short(_ interval: TimeInterval) -> String {
        let s = max(0, interval)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        default: return "\(Int(s / 86_400))d"
        }
    }

    /// The badge for an old card ("5 h", "2 d", "3 w"), or nil while it's younger than `oldAfter`.
    public static func badge(createdAt: Date, now: Date) -> String? {
        let s = now.timeIntervalSince(createdAt)
        guard s >= oldAfter else { return nil }
        switch s {
        case ..<86_400: return "\(Int(s / 3600)) h"
        case ..<(14 * 86_400): return "\(Int(s / 86_400)) d"
        default: return "\(Int(s / (7 * 86_400))) w"
        }
    }

    public static func isStale(createdAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= staleAfter
    }
}

extension ItemStore {
    /// The host a card came from ("devbox"), trimmed; nil when it doesn't say.
    public static func host(of item: Item) -> String? {
        guard let host = item.source?.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { return nil }
        return host
    }

    /// Everything shown in `context` (needs cards and Recent rows) from `host`, compared
    /// case-insensitively: what "Dismiss all from this host" closes. Snoozed cards aren't
    /// on screen, so they're left alone.
    public func visibleItems(fromHost host: String, in context: ItemContext, now: Date = Date()) -> [Item] {
        let wanted = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return [] }
        return visibleItems(now: now)
            .filter { $0.context == context && Self.host(of: $0)?.lowercased() == wanted }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }
}
