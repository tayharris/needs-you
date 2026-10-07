import Foundation

// Item steps on a card: a numbered checklist. Ticking a step is local to this Mac (no API
// write); the sender's `done` shows as ticked and can't be unticked here. Pure, so it's
// unit-tested; the views only read the answers.

/// The steps this Mac's user ticked, per item. In memory only; pruned as items leave.
/// A tick is keyed by item id, step index and step text, so a sender editing the list
/// doesn't carry a tick over to a different step.
public struct StepTicks: Equatable, Sendable {
    private var ticked: Set<String> = []

    public init() {}

    static func key(_ item: Item, _ index: Int) -> String? {
        guard item.steps.indices.contains(index) else { return nil }
        return "\(item.id)\u{1F}\(index)\u{1F}\(item.steps[index].text)"
    }

    /// Ticked by the sender (`done`) or by the user here.
    public func isTicked(_ item: Item, _ index: Int) -> Bool {
        guard let key = Self.key(item, index) else { return false }
        return item.steps[index].done || ticked.contains(key)
    }

    /// Steps the sender marked done can't be unticked here.
    public func canToggle(_ item: Item, _ index: Int) -> Bool {
        item.steps.indices.contains(index) && !item.steps[index].done
    }

    public mutating func toggle(_ item: Item, _ index: Int) {
        guard canToggle(item, index), let key = Self.key(item, index) else { return }
        if ticked.contains(key) { ticked.remove(key) } else { ticked.insert(key) }
    }

    public func tickedCount(_ item: Item) -> Int {
        item.steps.indices.filter { isTicked(item, $0) }.count
    }

    /// Every step ticked (so the card offers Done). False for items without steps.
    public func allTicked(_ item: Item) -> Bool {
        !item.steps.isEmpty && tickedCount(item) == item.steps.count
    }

    /// Drops ticks for items no longer in `ids`.
    public mutating func retain(itemIDs ids: Set<String>) {
        let kept = ticked.filter { key in
            guard let id = key.split(separator: "\u{1F}", maxSplits: 1).first else { return false }
            return ids.contains(String(id))
        }
        if kept != ticked { ticked = kept }
    }

    public var isEmpty: Bool { ticked.isEmpty }
}

public enum StepsPolicy {
    /// The most steps drawn (the hub's limit; extra ones from a newer hub are left out).
    public static let maxSteps = 10

    /// The steps the card draws.
    public static func visible(_ item: Item) -> [ItemStep] { Array(item.steps.prefix(maxSteps)) }

    /// Full mode, or an expanded card, draws the checklist; "First lines" and "Title only"
    /// show a one-line summary ("3 steps") that expands the card.
    public static func showsList(_ mode: CardBodyMode, expanded: Bool) -> Bool {
        expanded || mode == .full
    }

    /// "3 steps", "1 step", or "2 of 3 done" once any are ticked.
    public static func summary(total: Int, ticked: Int) -> String {
        if ticked > 0 { return "\(ticked) of \(total) done" }
        return total == 1 ? "1 step" : "\(total) steps"
    }

    /// "1.", "2.", ...
    public static func number(_ index: Int) -> String { "\(index + 1)." }

    /// The step link's button title, shortened like compact link labels (a blank label
    /// shows the host, as on the links row). The view adds `LinkRowPolicy.destination`.
    public static func linkTitle(_ link: ItemLink) -> String {
        LinkRowPolicy.label(link, maxLength: LinkRowPolicy.compactLabelLength)
    }

    /// Does the card get a Show more / Show details toggle? Bodies decide as before; steps
    /// add one whenever they're summarised.
    public static func canExpand(_ item: Item, mode: CardBodyMode) -> Bool {
        CardBodyPolicy.canExpand(body: item.body, mode: mode) || (!item.steps.isEmpty && mode != .full)
    }
}
