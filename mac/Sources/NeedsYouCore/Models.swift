import Foundation

// The item shape from docs/API.md "The item". Decoding is lenient about values the
// app doesn't know yet (a newer hub adding a kind or priority must not break polling).

public enum ItemContext: String, Codable, CaseIterable, Sendable {
    case work, personal

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemContext(rawValue: raw.lowercased()) ?? .work
    }

    public var other: ItemContext { self == .work ? .personal : .work }
}

public enum ItemKind: String, Codable, Sendable {
    case needs, done, info

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown kinds are treated as info so they never raise the count.
        self = ItemKind(rawValue: raw.lowercased()) ?? .info
    }
}

public enum ItemPriority: String, Codable, CaseIterable, Sendable, Comparable {
    case urgent, normal, low

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemPriority(rawValue: raw.lowercased()) ?? .normal
    }

    /// urgent sorts first.
    public var rank: Int {
        switch self {
        case .urgent: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    public static func < (lhs: ItemPriority, rhs: ItemPriority) -> Bool { lhs.rank < rhs.rank }
}

public enum ItemStatus: String, Codable, Sendable {
    case open, resolved, dismissed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Anything that isn't recognisably open is treated as closed.
        self = ItemStatus(rawValue: raw.lowercased()) ?? .resolved
    }
}

public struct ItemLink: Codable, Hashable, Sendable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// One thing the person has to do, in order (`steps` in docs/API.md). `text` is limited
/// markdown; `link` is a button (shown as plain text if its scheme isn't allowed); `done`
/// is the sender's view. Decoding is lenient: a missing `done` is false, a malformed link
/// is dropped, unknown fields are ignored.
public struct ItemStep: Codable, Hashable, Sendable {
    public var text: String
    public var link: ItemLink?
    public var done: Bool

    enum CodingKeys: String, CodingKey { case text, link, done }

    public init(text: String, link: ItemLink? = nil, done: Bool = false) {
        self.text = text
        self.link = link
        self.done = done
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        link = try? c.decodeIfPresent(ItemLink.self, forKey: .link)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

/// What an agent asked the person and the choices it offered (`question` in docs/API.md,
/// ADR 0009). With `answerable`, the sender waits for the person's click on an option
/// (POST /v1/items/{id}/answer); otherwise the person answers in the agent. Decoding is
/// lenient: missing optional fields get their defaults, options without a label and
/// questions without text are skipped, unknown fields are ignored.
public struct ItemQuestion: Codable, Hashable, Sendable {
    public var id: String?
    public var items: [ItemQuestionItem]
    /// The sender waits for an answer from the card.
    public var answerable: Bool
    /// The sender stops waiting then; no answer is taken after it.
    public var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, items, answerable
        case expiresAt = "expires_at"
    }

    public init(id: String? = nil, items: [ItemQuestionItem], answerable: Bool = false, expiresAt: Date? = nil) {
        self.id = id
        self.items = items
        self.answerable = answerable
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        items = ((try? c.decodeIfPresent([ItemQuestionItem].self, forKey: .items)) ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        answerable = (try? c.decodeIfPresent(Bool.self, forKey: .answerable)) ?? false
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }
}

/// One question's answer: the labels the person clicked, as the hub stores them.
public struct ItemAnswer: Codable, Hashable, Sendable {
    public var selected: [String]

    public init(selected: [String]) { self.selected = selected }
}

/// The body of POST /v1/items/{id}/answer (docs/API.md).
public struct AnswerRequest: Encodable, Equatable, Sendable {
    public var questionID: String?
    /// The item's `content_updated_at` exactly as the hub sent it, so the hub can tell the
    /// question didn't change under the person.
    public var contentUpdatedAt: String
    public var answers: [ItemAnswer]

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case contentUpdatedAt = "content_updated_at"
        case answers
    }

    public init(questionID: String?, contentUpdatedAt: String, answers: [ItemAnswer]) {
        self.questionID = questionID
        self.contentUpdatedAt = contentUpdatedAt
        self.answers = answers
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(questionID, forKey: .questionID)  // null when the question has no id
        try c.encode(contentUpdatedAt, forKey: .contentUpdatedAt)
        try c.encode(answers, forKey: .answers)
    }
}

public struct ItemQuestionItem: Codable, Hashable, Sendable {
    public var header: String
    public var text: String
    public var options: [ItemQuestionOption]
    public var multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case header, text, options
        case multiSelect = "multi_select"
    }

    public init(header: String = "", text: String, options: [ItemQuestionOption] = [], multiSelect: Bool = false) {
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        header = (try? c.decodeIfPresent(String.self, forKey: .header)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        options = ((try? c.decodeIfPresent([ItemQuestionOption].self, forKey: .options)) ?? [])
            .filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
    }
}

/// One choice. `detail` is the wire's `description` (a CodingKey can't be named that).
public struct ItemQuestionOption: Codable, Hashable, Sendable {
    public var label: String
    public var detail: String

    enum CodingKeys: String, CodingKey {
        case label
        case detail = "description"
    }

    public init(label: String, detail: String = "") {
        self.label = label
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
    }
}

public struct ItemSource: Codable, Hashable, Sendable {
    public var host: String?
    public var agent: String?
    public var project: String?

    public init(host: String? = nil, agent: String? = nil, project: String? = nil) {
        self.host = host
        self.agent = agent
        self.project = project
    }

    /// `devbox · orca:redo-fixer`, skipping empty parts.
    public var displayParts: [String] {
        [host, agent].compactMap { $0 }.filter { !$0.isEmpty }
    }
}

public struct Item: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var key: String
    public var context: ItemContext
    public var kind: ItemKind
    public var priority: ItemPriority
    public var title: String
    public var body: String?
    public var links: [ItemLink]
    /// The checklist; empty for items without one (and from hubs that predate steps).
    public var steps: [ItemStep]
    /// What an agent asked, if anything; nil from hubs that predate it.
    public var question: ItemQuestion?
    /// The person's answer to `question` (one entry per question), when it was given and by
    /// which token; nil until answered (and from hubs that predate answers).
    public var answer: [ItemAnswer]?
    public var answeredAt: Date?
    public var answeredBy: String?
    /// `content_updated_at` exactly as the hub sent it (an answer echoes it back).
    public var contentUpdatedAtRaw: String?
    public var source: ItemSource?
    public var status: ItemStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var seenAt: Date?
    public var expiresAt: Date?
    /// When the title, body, priority or steps last changed (docs/API.md); nil from hubs
    /// that don't send it. Read for the pill's "new since last opened" count.
    public var contentUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, key, context, kind, priority, title, body, links, steps, question, answer, source, status
        case answeredAt = "answered_at"
        case answeredBy = "answered_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seenAt = "seen_at"
        case expiresAt = "expires_at"
        case contentUpdatedAt = "content_updated_at"
    }

    public init(
        id: String, key: String, context: ItemContext = .work, kind: ItemKind = .needs,
        priority: ItemPriority = .normal, title: String, body: String? = nil,
        links: [ItemLink] = [], steps: [ItemStep] = [], question: ItemQuestion? = nil,
        source: ItemSource? = nil, status: ItemStatus = .open,
        createdAt: Date, updatedAt: Date? = nil, seenAt: Date? = nil, expiresAt: Date? = nil,
        contentUpdatedAt: Date? = nil, answer: [ItemAnswer]? = nil, answeredAt: Date? = nil,
        answeredBy: String? = nil, contentUpdatedAtRaw: String? = nil
    ) {
        self.id = id
        self.key = key
        self.context = context
        self.kind = kind
        self.priority = priority
        self.title = title
        self.body = body
        self.links = links
        self.steps = steps
        self.question = question
        self.source = source
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.seenAt = seenAt
        self.expiresAt = expiresAt
        self.contentUpdatedAt = contentUpdatedAt
        self.answer = answer
        self.answeredAt = answeredAt
        self.answeredBy = answeredBy
        self.contentUpdatedAtRaw = contentUpdatedAtRaw
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? id
        context = try c.decodeIfPresent(ItemContext.self, forKey: .context) ?? .work
        kind = try c.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .needs
        priority = try c.decodeIfPresent(ItemPriority.self, forKey: .priority) ?? .normal
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        body = try c.decodeIfPresent(String.self, forKey: .body)
        links = try c.decodeIfPresent([ItemLink].self, forKey: .links) ?? []
        // Lenient: a malformed steps value never costs the item; steps without text are skipped.
        steps = ((try? c.decodeIfPresent([ItemStep].self, forKey: .steps)) ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Lenient like steps: a malformed question never costs the item; one with no
        // readable question is nil.
        let q: ItemQuestion? = (try? c.decodeIfPresent(ItemQuestion.self, forKey: .question)) ?? nil
        if let q, !q.items.isEmpty { question = q } else { question = nil }
        source = try c.decodeIfPresent(ItemSource.self, forKey: .source)
        status = try c.decodeIfPresent(ItemStatus.self, forKey: .status) ?? .open
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        seenAt = try c.decodeIfPresent(Date.self, forKey: .seenAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        // Lenient: a hub that predates it (or sends junk) just leaves it nil.
        contentUpdatedAt = try? c.decodeIfPresent(Date.self, forKey: .contentUpdatedAt)
        contentUpdatedAtRaw = (try? c.decodeIfPresent(String.self, forKey: .contentUpdatedAt)) ?? nil
        // Lenient: an answer only counts with its question, and a malformed one is ignored.
        let a: [ItemAnswer]? = (try? c.decodeIfPresent([ItemAnswer].self, forKey: .answer)) ?? nil
        answer = (question != nil && a?.isEmpty == false) ? a : nil
        answeredAt = answer == nil ? nil : ((try? c.decodeIfPresent(Date.self, forKey: .answeredAt)) ?? nil)
        answeredBy = answer == nil ? nil : ((try? c.decodeIfPresent(String.self, forKey: .answeredBy)) ?? nil)
    }

    /// Re-animation rule (docs/API.md `content_updated_at`): title, body, priority, steps or
    /// question.
    public func hasVisibleChange(from old: Item) -> Bool {
        title != old.title || body != old.body || priority != old.priority || steps != old.steps
            || question != old.question
    }

    public func isExpired(at now: Date) -> Bool {
        if let expiresAt { return expiresAt <= now }
        return false
    }
}

// MARK: - JSON

public enum HubJSON {
    /// ISO 8601 with or without fractional seconds, plus a numeric epoch fallback.
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date: \(s)")
        }
        return d
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func parseDate(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        guard s.count >= 19 else { return nil }
        // Split "YYYY-MM-DDTHH:MM:SS" + optional ".ffffff" + optional zone.
        let head = String(s.prefix(19))
        var rest = Substring(s.dropFirst(19))
        var fraction = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            let digits = rest.prefix(while: { $0.isNumber })
            fraction = String(digits.prefix(3))
            rest = rest.dropFirst(digits.count)
        }
        // Python's isoformat() without a zone: assume UTC.
        let zone = rest.isEmpty ? "Z" : String(rest)
        s = head + (fraction.isEmpty ? "" : "." + fraction) + zone

        let f = ISO8601DateFormatter()
        f.formatOptions = fraction.isEmpty
            ? [.withInternetDateTime]
            : [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Tolerant of the hub's list response shape: accept either a bare array
    /// or an object wrapping it as `items`.
    public static func decodeItemList(_ data: Data) throws -> [Item] {
        let decoder = makeDecoder()
        if let items = try? decoder.decode([Item].self, from: data) { return items }
        struct Wrapped: Decodable { let items: [Item] }
        return try decoder.decode(Wrapped.self, from: data).items
    }

    /// `GET /v1/items`: the items plus `server_time` (the next `since`), `more` and `next`
    /// (the opaque cursor). A bare array, or a hub without those fields, gives no cursor and
    /// `more` false.
    public static func decodeListResponse(_ data: Data) throws -> (items: [Item], serverTime: Date?, more: Bool, next: String?) {
        let decoder = makeDecoder()
        if let items = try? decoder.decode([Item].self, from: data) { return (items, nil, false, nil) }
        struct Wrapped: Decodable {
            let items: [Item]
            let serverTime: String?
            let more: Bool?
            let next: String?
            enum CodingKeys: String, CodingKey {
                case items, more, next
                case serverTime = "server_time"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                items = try c.decode([Item].self, forKey: .items)
                serverTime = try? c.decodeIfPresent(String.self, forKey: .serverTime)
                more = try? c.decodeIfPresent(Bool.self, forKey: .more)
                next = try? c.decodeIfPresent(String.self, forKey: .next)
            }
        }
        let wrapped = try decoder.decode(Wrapped.self, from: data)
        let next = wrapped.next.flatMap { $0.isEmpty || $0.count > 512 ? nil : $0 }
        return (wrapped.items, wrapped.serverTime.flatMap(parseDate), wrapped.more ?? false, next)
    }
}
