import Foundation

/// What a merge changed, so the UI can decide what to animate.
public struct MergeResult: Equatable, Sendable {
    /// Items the app hadn't seen before.
    public var inserted: [Item] = []
    /// Known items whose title, body or priority changed (these re-animate).
    public var changed: [Item] = []
    /// Known items whose update was invisible (e.g. an hourly re-post). No animation.
    public var touched: [Item] = []
    /// Items that left the open set (resolved/dismissed by someone, expired, or missing
    /// from a full snapshot).
    public var removed: [Item] = []

    public init() {}

    /// The items worth announcing: new or visibly changed.
    public var announce: [Item] { inserted + changed }
    public var isEmpty: Bool { inserted.isEmpty && changed.isEmpty && touched.isEmpty && removed.isEmpty }
}

/// The local mirror of the hub's open items plus purely local state (per-card snoozes,
/// optimistic closes). A value type with no I/O, so the rules are easy to test.
public struct ItemStore: Sendable {
    public private(set) var items: [String: Item] = [:]
    /// Newest `updated_at` seen from the hub; sent back as `since`.
    public private(set) var latestUpdatedAt: Date?
    /// Per-card snoozes (PLAN.md: 15 min / 1 hr / tomorrow), local to this Mac.
    public private(set) var cardSnoozes: [String: Date] = [:]
    /// Items closed locally while the PATCH is in flight, with the `updated_at` they had,
    /// so a poll that races the PATCH doesn't resurrect them.
    private var locallyClosed: [String: Date] = [:]

    public init(items: [Item] = []) {
        for item in items where item.status == .open { self.items[item.id] = item }
        latestUpdatedAt = items.map(\.updatedAt).max()
    }

    // MARK: - Merge

    /// Merge a poll response.
    /// - Parameter isFullSnapshot: the response is every open item (no `since`), so open
    ///   items missing from it were closed on the hub and are dropped.
    @discardableResult
    public mutating func merge(_ polled: [Item], isFullSnapshot: Bool, now: Date = Date()) -> MergeResult {
        var result = MergeResult()
        var seenIDs = Set<String>()

        // Oldest first, so if a response holds two versions of one item the newest wins.
        for incoming in polled.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            seenIDs.insert(incoming.id)
            latestUpdatedAt = max(latestUpdatedAt ?? incoming.updatedAt, incoming.updatedAt)

            if let closedAt = locallyClosed[incoming.id] {
                if incoming.updatedAt <= closedAt { continue }
                // The sender updated it after we closed it: it's live again.
                locallyClosed[incoming.id] = nil
            }

            let existing = items[incoming.id]
            if let existing, existing.updatedAt > incoming.updatedAt { continue } // stale

            if incoming.status != .open || incoming.isExpired(at: now) {
                if let removed = items.removeValue(forKey: incoming.id) {
                    result.removed.append(removed)
                }
                cardSnoozes[incoming.id] = nil
                continue
            }

            // Keys are unique while open: a different id with the same key replaces the old one.
            if existing == nil,
               let twin = items.values.first(where: { $0.key == incoming.key && $0.id != incoming.id }) {
                items[twin.id] = nil
                cardSnoozes[twin.id] = nil
                items[incoming.id] = incoming
                if incoming.hasVisibleChange(from: twin) { result.changed.append(incoming) } else { result.touched.append(incoming) }
                continue
            }

            items[incoming.id] = incoming
            if let existing {
                if incoming.hasVisibleChange(from: existing) {
                    result.changed.append(incoming)
                } else if incoming != existing {
                    result.touched.append(incoming)
                }
            } else {
                result.inserted.append(incoming)
            }
        }

        if isFullSnapshot {
            for (id, item) in items where !seenIDs.contains(id) {
                items[id] = nil
                cardSnoozes[id] = nil
                result.removed.append(item)
            }
            // Anything we closed locally that the hub no longer lists is settled.
            locallyClosed = locallyClosed.filter { seenIDs.contains($0.key) }
        }

        result.removed.append(contentsOf: prune(now: now))
        return result
    }

    /// Drop expired items and finished card snoozes. Returns the items dropped.
    @discardableResult
    public mutating func prune(now: Date = Date()) -> [Item] {
        var dropped: [Item] = []
        for (id, item) in items where item.isExpired(at: now) {
            items[id] = nil
            cardSnoozes[id] = nil
            dropped.append(item)
        }
        cardSnoozes = cardSnoozes.filter { $0.value > now }
        return dropped
    }

    // MARK: - Local actions

    /// Optimistically close an item (Done / Dismiss). Returns it so a failed PATCH can restore it.
    @discardableResult
    public mutating func closeLocally(id: String) -> Item? {
        guard let item = items.removeValue(forKey: id) else { return nil }
        locallyClosed[id] = item.updatedAt
        cardSnoozes[id] = nil
        return item
    }

    /// Undo `closeLocally` after a failed PATCH.
    public mutating func restore(_ item: Item) {
        locallyClosed[item.id] = nil
        if items[item.id] == nil { items[item.id] = item }
    }

    public mutating func snoozeCard(id: String, until: Date) {
        guard items[id] != nil else { return }
        cardSnoozes[id] = until
    }

    public mutating func unsnoozeCard(id: String) { cardSnoozes[id] = nil }

    public mutating func markSeen(id: String, at date: Date) {
        items[id]?.seenAt = date
    }

    // MARK: - Queries

    public func isCardSnoozed(_ id: String, now: Date = Date()) -> Bool {
        if let until = cardSnoozes[id] { return until > now }
        return false
    }

    /// Items currently shown (open, not expired, not card-snoozed).
    public func visibleItems(now: Date = Date()) -> [Item] {
        items.values.filter { $0.status == .open && !$0.isExpired(at: now) && !isCardSnoozed($0.id, now: now) }
    }

    /// Open `needs` items in a context, urgent → normal → low, oldest first within a priority.
    public func needs(in context: ItemContext, now: Date = Date()) -> [Item] {
        visibleItems(now: now)
            .filter { $0.kind == .needs && $0.context == context }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
    }

    /// The badge count: open `needs` items in the current context only (PLAN.md, "Count").
    public func needsCount(in context: ItemContext, now: Date = Date()) -> Int {
        needs(in: context, now: now).count
    }

    /// The "Recent" list: done and info items in a context, newest first. Never counted.
    public func recent(in context: ItemContext, now: Date = Date()) -> [Item] {
        visibleItems(now: now)
            .filter { $0.kind != .needs && $0.context == context }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The colour driver for the ring and glow: the highest open `needs` priority.
    public func highestPriority(in context: ItemContext, now: Date = Date()) -> ItemPriority? {
        needs(in: context, now: now).map(\.priority).min()
    }

    public var snoozedCardCount: Int { cardSnoozes.count }
}
