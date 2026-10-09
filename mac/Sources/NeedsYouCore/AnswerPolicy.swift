import Foundation

// Answering an agent's question from its card (ADR 0009 B2, docs/API.md). The options of an
// answerable question are buttons: for one single-choice question a click sends at once;
// otherwise clicks toggle (one per single-choice question, any for multi-select) and Send
// sends. A question with `allowOther` also gets "Other…" ("Answer…" without options): a
// click opens the answer window, the one place besides Settings where the app takes focus,
// and the words typed there are that question's answer (in place of a single choice's
// label, next to a multi-select's picks). Only labels the agent offered or words the person
// typed, only after a click: never a default, never on a timeout. Pure, so it's
// unit-tested; the card, the answer window and AppModel only read the answers.

/// The options the person has clicked on one card, and the words typed for it, per question
/// (index → labels, index → text).
public struct AnswerSelection: Equatable, Sendable {
    public private(set) var picked: [Int: [String]] = [:]
    public private(set) var texts: [Int: String] = [:]

    public init() {}

    public func isPicked(_ question: Int, _ label: String) -> Bool {
        picked[question]?.contains(label) ?? false
    }

    /// Single choice: the clicked label replaces the question's pick or typed words (a
    /// second click on it clears it). Multi-select: the label toggles.
    public mutating func toggle(_ question: Int, _ label: String, multiSelect: Bool) {
        var labels = picked[question] ?? []
        if let i = labels.firstIndex(of: label) {
            labels.remove(at: i)
        } else if multiSelect {
            labels.append(label)
        } else {
            labels = [label]
            texts[question] = nil
        }
        picked[question] = labels.isEmpty ? nil : labels
    }

    /// The words typed for a question (nil clears them). Single choice: they replace the
    /// question's pick; multi-select: they go with the picks.
    public mutating func setText(_ question: Int, _ text: String?, multiSelect: Bool) {
        texts[question] = (text?.isEmpty ?? true) ? nil : text
        if texts[question] != nil && !multiSelect { picked[question] = nil }
    }

    /// Every question has at least one pick, all among its options.
    public func isComplete(for q: ItemQuestion) -> Bool {
        answers(for: q) != nil
    }

    /// The answer to send, in the options' order, each question's typed words (where it
    /// allows them) after its labels; nil until every question has a pick or words.
    public func answers(for q: ItemQuestion) -> [ItemAnswer]? {
        var out: [ItemAnswer] = []
        for (i, item) in q.items.enumerated() {
            let mine = picked[i] ?? []
            let chosen = item.options.map(\.label).filter { mine.contains($0) }
            let text = item.allowOther ? texts[i] : nil
            let given = chosen.count + (text == nil ? 0 : 1)
            guard given > 0, item.multiSelect || given == 1 else { return nil }
            out.append(ItemAnswer(selected: chosen, text: text))
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
    /// options or `allowOther`, options whose labels differ (an answer carries labels, so two
    /// options with one label can't be told apart; hubs refuse that, an older one may still
    /// serve it), not answered yet, and not past its `expires_at`.
    public static func canAnswer(_ item: Item, now: Date) -> Bool {
        guard item.status == .open, item.answer == nil, let q = item.question, q.answerable,
              !q.items.isEmpty, q.items.allSatisfy({ !$0.options.isEmpty || $0.allowOther }),
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

    /// The answer window's limit, the hub's: 1,000 characters (Unicode scalars, as the hub
    /// counts them).
    public static let maxTextLength = 1000

    /// The words typed in the answer window, checked as the hub will: line breaks and tabs
    /// (from a paste) become spaces, the ends are trimmed, and then it must be 1–1,000
    /// characters without control or bidi characters. Never rewritten otherwise: what the
    /// person typed is what the agent gets.
    public enum TypedAnswer: Equatable, Sendable {
        case ok(String)
        /// Not sendable; the text says why, for the window.
        case refused(String)
    }

    public static func typedAnswer(_ raw: String) -> TypedAnswer {
        let breaks: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars { scalars.append(breaks.contains(u.value) ? " " : u) }
        let text = String(scalars).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .refused("Type an answer first.") }
        let n = text.unicodeScalars.count
        if n > maxTextLength { return .refused("Too long: \(n) characters, at most \(maxTextLength).") }
        let bad = text.unicodeScalars.contains { u in
            u.value < 0x20 || (0x7F...0x9F).contains(u.value) || (0x202A...0x202E).contains(u.value)
                || (0x2066...0x2069).contains(u.value)
        }
        if bad { return .refused("It holds invisible control characters: retype it.") }
        return .ok(text)
    }

    /// The button that opens the answer window for a question: "Other…" next to options,
    /// "Answer…" for a question without them. nil when it takes no typed words.
    public static func otherTitle(_ q: ItemQuestionItem) -> String? {
        guard q.allowOther else { return nil }
        return q.options.isEmpty ? "Answer\u{2026}" : "Other\u{2026}"
    }

    /// The selection with `text` as question `index`'s words, and whether it is then a whole
    /// answer (the window's button says Send, and sends it) or still waits for other
    /// questions on the card (the button says Use, and the card's Send sends it later).
    public static func withText(_ item: Item, _ selection: AnswerSelection, question index: Int,
                                text: String) -> (selection: AnswerSelection, complete: Bool)? {
        guard let q = item.question, q.items.indices.contains(index), q.items[index].allowOther else { return nil }
        var s = selection
        s.setText(index, text, multiSelect: q.items[index].multiSelect)
        return (s, s.isComplete(for: q))
    }

    /// "Answered: Postgres · Tracing, Metrics (devbox-mac)" for an answered item; typed words
    /// in quotes: "Answered: “MySQL” · Tracing, “Logs”".
    public static func answeredText(_ item: Item) -> String? {
        guard let answer = item.answer, !answer.isEmpty else { return nil }
        let picks = answer.map { a in
            (a.selected + (a.text.map { ["\u{201C}\($0)\u{201D}"] } ?? [])).joined(separator: ", ")
        }.joined(separator: " · ")
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
        case "secret_in_text"?: return "Not sent: your words hold a needs-you token or invite code. Never send those."
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
    /// `kept`: the ids with picks, typed words or an answer state; one without a stamp counts
    /// as stale too (nothing says which version of the question it was made for).
    public static func staleAnswerIDs(stamps: [String: String], items: [String: Item],
                                      kept: Set<String> = []) -> Set<String> {
        Set(stamps.filter { id, stamp in items[id].map { Self.stamp($0) != stamp } ?? true }.keys)
            .union(kept.subtracting(stamps.keys))
    }

    /// The link that brings forward the agent's terminal (or Orca terminal), for "Answer in
    /// the terminal". nil when the card has none.
    public static func terminalLink(_ item: Item) -> ItemLink? {
        item.links.first { AppAction.parse($0.url) != nil }
    }
}
