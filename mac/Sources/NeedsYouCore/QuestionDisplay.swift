import Foundation

// An item's `question` on a card (docs/API.md, ADR 0009): each question under its header,
// its options as rows (label and a secondary description, no tick boxes). "First lines" and
// "Title only" show a one-line "Asks: …" summary that expands the card; the arrival preview
// shows the question and the first options. Pure, so it's unit-tested; the views only read
// the answers. Items without a question (and older hooks' choices-as-steps) are untouched.

public enum QuestionDisplay {
    /// The most questions and options per question drawn (the hub's limits; extra ones from
    /// a newer hub are left out).
    public static let maxQuestions = 4
    public static let maxOptions = 8
    /// The summary and the preview cut the question to this many characters.
    public static let summaryLength = 80
    /// Option labels the arrival preview names before "+N more".
    public static let previewOptions = 3

    /// The questions the card draws, each with at most `maxOptions` options.
    public static func visible(_ q: ItemQuestion) -> [ItemQuestionItem] {
        q.items.prefix(maxQuestions).map { item in
            var item = item
            item.options = Array(item.options.prefix(maxOptions))
            return item
        }
    }

    /// Every option the card can show, across the questions.
    public static func choiceCount(_ q: ItemQuestion) -> Int {
        visible(q).reduce(0) { $0 + $1.options.count }
    }

    /// The line above a question: "Database · choose one". Without a header: "Choose any"
    /// for a single question, "Question 2 · choose one" among several. A question without
    /// options is answered in the agent: "Database · answer in the agent", or, when the card
    /// can take typed words for it (`answering` and `allowOther`), "Name · type an answer".
    public static func heading(_ item: ItemQuestionItem, index: Int, count: Int, answering: Bool = false) -> String {
        let header = oneLine(item.header)
        let hint = item.options.isEmpty
            ? (answering && item.allowOther ? "type an answer" : "answer in the agent")
            : (item.multiSelect ? "choose any" : "choose one")
        if !header.isEmpty { return "\(header) · \(hint)" }
        if count > 1 { return "Question \(index + 1) · \(hint)" }
        return hint.prefix(1).uppercased() + hint.dropFirst()
    }

    /// Full mode, or an expanded card, draws every question and option; "First lines" and
    /// "Title only" show `summary` (which expands the card).
    public static func showsAll(_ mode: CardBodyMode, expanded: Bool) -> Bool {
        expanded || mode == .full
    }

    /// "Asks: Which database should we use? · 3 choices", "Asks: Which database? and 1 more
    /// · 5 choices", or without choices "Asks: What should the file be called?".
    public static func summary(_ q: ItemQuestion) -> String {
        let items = visible(q)
        guard let first = items.first else { return "Asks a question" }
        var text = "Asks: " + clip(oneLine(first.text), summaryLength)
        if items.count > 1 { text += " and \(items.count - 1) more" }
        let n = choiceCount(q)
        if n > 0 { text += " · " + (n == 1 ? "1 choice" : "\(n) choices") }
        return text
    }

    /// The arrival preview's question line: the first question, one line.
    public static func previewQuestion(_ q: ItemQuestion) -> String? {
        guard let first = visible(q).first else { return nil }
        let more = q.items.count > 1 ? " (+\(min(q.items.count, maxQuestions) - 1) more)" : ""
        return clip(oneLine(first.text), summaryLength) + more
    }

    /// The arrival preview's options line: the first question's first labels,
    /// "Postgres · SQLite · +2 more". nil when it has no options.
    public static func previewChoices(_ q: ItemQuestion) -> String? {
        guard let first = visible(q).first, !first.options.isEmpty else { return nil }
        let labels = first.options.prefix(previewOptions).map { clip(oneLine($0.label), 24) }
        let rest = first.options.count - labels.count
        return (labels + (rest > 0 ? ["+\(rest) more"] : [])).joined(separator: " · ")
    }

    /// Lines the arrival preview adds below the meta line for this item: 0 without a
    /// question, 1 for a question without options, 2 with options.
    public static func previewRows(_ item: Item) -> Int {
        guard let q = item.question, previewQuestion(q) != nil else { return 0 }
        return previewChoices(q) == nil ? 1 : 2
    }

    /// Does the card get a Show more / Show details toggle for its question? Whenever the
    /// question is summarised.
    public static func canExpand(_ item: Item, mode: CardBodyMode) -> Bool {
        item.question != nil && mode != .full
    }

    /// The body the card draws. Hooks that send `question` also list the questions and
    /// their choices in the body, for clients that don't show the field; with the question
    /// drawn as rows, those paragraphs would say everything twice. So a paragraph (text
    /// between blank lines) that quotes one of the questions is left out, as is the hook's
    /// "+N more questions" line. Everything else ("Answer in Claude.", the folder and host
    /// lines) stays. nil when nothing is left.
    public static func body(_ item: Item) -> String? {
        guard let body = item.body else { return nil }
        guard let q = item.question else { return body.isEmpty ? nil : body }
        let needles = q.items.compactMap { item -> String? in
            let line = item.text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return line.count >= 4 ? String(line.prefix(60)) : nil
        }
        let paragraphs = body.components(separatedBy: "\n\n")
        let kept = paragraphs.filter { p in
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            if needles.contains(where: { t.contains($0) }) { return false }
            if isMoreQuestionsLine(t) { return false }
            return true
        }
        let joined = kept.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func isMoreQuestionsLine(_ t: String) -> Bool {
        guard t.hasPrefix("+"), t.hasSuffix(" more questions") else { return false }
        let digits = t.dropFirst().dropLast(" more questions".count)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard n > 1, s.count > n else { return s }
        return String(s.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
