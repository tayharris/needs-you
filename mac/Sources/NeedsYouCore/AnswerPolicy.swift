import Foundation

// Answering an agent's question from its card (ADR 0009 B2, docs/API.md). The options of an
// answerable question are buttons: for one single-choice question a click sends at once;
// otherwise clicks toggle (one per single-choice question, any for multi-select) and Send
// sends. Only labels the agent offered, only from a click: never a default, never on a
// timeout. Pure, so it's unit-tested; the card and AppModel only read the answers.

/// The options the person has clicked on one card, per question (index → labels).
public struct AnswerSelection: Equatable, Sendable {
    public private(set) var picked: [Int: [String]] = [:]

    public init() {}

    public func isPicked(_ question: Int, _ label: String) -> Bool {
        picked[question]?.contains(label) ?? false
    }

    /// Single choice: the clicked label replaces the question's pick (a second click on it
    /// clears it). Multi-select: the label toggles.
    public mutating func toggle(_ question: Int, _ label: String, multiSelect: Bool) {
        var labels = picked[question] ?? []
        if let i = labels.firstIndex(of: label) {
            labels.remove(at: i)
        } else if multiSelect {
            labels.append(label)
        } else {
            labels = [label]
        }
        picked[question] = labels.isEmpty ? nil : labels
    }

    /// Every question has at least one pick, all among its options.
    public func isComplete(for q: ItemQuestion) -> Bool {
        answers(for: q) != nil
    }

    /// The answer to send, in the options' order; nil until every question has a pick.
    public func answers(for q: ItemQuestion) -> [ItemAnswer]? {
        var out: [ItemAnswer] = []
        for (i, item) in q.items.enumerated() {
            let mine = picked[i] ?? []
            let chosen = item.options.map(\.label).filter { mine.contains($0) }
            guard !chosen.isEmpty, item.multiSelect || chosen.count == 1 else { return nil }
            out.append(ItemAnswer(selected: chosen))
        }
        return out.isEmpty ? nil : out
    }
}

/// Where an answer from this card stands.
public enum AnswerState: Equatable, Sendable {
    case sending
    case sent
    /// Not taken; the text says why and what to do.
    case failed(String)
}

public enum AnswerPolicy {
    /// Can the card answer this item's question? Open, answerable, every question with
    /// options whose labels differ (an answer is labels only, so two options with one label
    /// can't be told apart; hubs refuse that, an older one may still serve it), not answered
    /// yet, and not past its `expires_at`.
    public static func canAnswer(_ item: Item, now: Date) -> Bool {
        guard item.status == .open, item.answer == nil, let q = item.question, q.answerable,
              !q.items.isEmpty, q.items.allSatisfy({ !$0.options.isEmpty }),
              q.items.allSatisfy({ Set($0.options.map(\.label)).count == $0.options.count }),
              item.contentUpdatedAtRaw != nil else { return false }
        if let exp = q.expiresAt, exp <= now { return false }
        return true
    }

    /// One single-choice question: a click on an option is the answer (no Send button).
    public static func sendsOnClick(_ q: ItemQuestion) -> Bool {
        q.items.count == 1 && !q.items[0].multiSelect
    }

    /// The request for these picks, or nil when they don't make a whole answer.
    public static func request(_ item: Item, _ selection: AnswerSelection) -> AnswerRequest? {
        guard let q = item.question, let raw = item.contentUpdatedAtRaw,
              let answers = selection.answers(for: q) else { return nil }
        return AnswerRequest(questionID: q.id, contentUpdatedAt: raw, answers: answers)
    }

    /// The answer a single-choice click sends.
    public static func clickRequest(_ item: Item, question: Int, label: String) -> AnswerRequest? {
        var s = AnswerSelection()
        s.toggle(question, label, multiSelect: false)
        return request(item, s)
    }

    /// "Answered: Postgres · Tracing, Metrics (devbox-mac)" for an answered item.
    public static func answeredText(_ item: Item) -> String? {
        guard let answer = item.answer, !answer.isEmpty else { return nil }
        let picks = answer.map { $0.selected.joined(separator: ", ") }.joined(separator: " · ")
        let by = (item.answeredBy ?? "").trimmingCharacters(in: .whitespaces)
        return "Answered: " + picks + (by.isEmpty ? "" : " (\(by))")
    }

    /// The card's line for a failed answer, from the hub's error code (nil: a network error).
    public static func failureText(code: String?) -> String {
        switch code {
        case nil: return "Not sent: no hub answered. Try again, or answer in the terminal."
        case "already_answered"?: return "Already answered (another click got there first)."
        case "question_changed"?: return "The question changed: look again before answering."
        case "question_expired"?: return "The agent stopped waiting: answer in the terminal."
        case "not_open"?: return "This card is closed."
        case "not_answerable"?: return "This question can only be answered in the terminal."
        case "rate_limited"?: return "Too many answers just now: wait a moment."
        default: return "Not taken (\(code ?? "error")): answer in the terminal."
        }
    }

    /// What picks and an answer state were made for: the item's content as the person saw
    /// it. A re-post that changes the question moves `content_updated_at` (and the hub then
    /// refuses an answer to the old one, `question_changed`), so this changes with it.
    public static func stamp(_ item: Item) -> String {
        "\(item.id)\u{1F}\(item.contentUpdatedAtRaw ?? "")"
    }

    /// The items whose picks or answer state (`stamps`, by item id) no longer apply: the item
    /// is gone, or a re-post changed it. Without this a "Sent to the agent" from an earlier
    /// question would keep a new one locked, and old picks could show on new options.
    public static func staleAnswerIDs(stamps: [String: String], items: [String: Item]) -> Set<String> {
        Set(stamps.filter { id, stamp in items[id].map { Self.stamp($0) != stamp } ?? true }.keys)
    }

    /// The link that brings forward the agent's terminal (or Orca terminal), for "Answer in
    /// the terminal". nil when the card has none.
    public static func terminalLink(_ item: Item) -> ItemLink? {
        item.links.first { AppAction.parse($0.url) != nil }
    }
}
