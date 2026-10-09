import Foundation

/// Where items come from: the real hub, or the demo fixture.
public protocol ItemFeed: Sendable {
    /// Open items; with `since`, only those updated at or after it (docs/API.md, `GET /v1/items`).
    func fetchOpen(since: Date?) async throws -> [Item]
    /// PATCH /v1/items/{id}.
    func patch(id: String, _ patch: ItemPatch) async throws
    /// What the app polls: items (after a `since` poll, closed ones too), whether they form
    /// a full snapshot, which hub served them, and its cursor. The default wraps `fetchOpen`.
    func fetchPage(since: Date?) async throws -> FeedPage
    /// The same, also sending the hub's opaque `next` cursor from the last page (only with a
    /// `since`; docs/API.md "The polling loop"). The default ignores `cursor`.
    func fetchPage(since: Date?, cursor: String?) async throws -> FeedPage
    /// POST /v1/items/{id}/answer: the person's click on a question's options. Throws on
    /// transport errors and a refused token; the hub's refusals come back as `.refused`.
    func answer(id: String, _ answer: AnswerRequest) async throws -> AnswerOutcome
}

/// What the hub said to an answer (docs/API.md).
public enum AnswerOutcome: Equatable, Sendable {
    case taken
    /// 400, 404, 409 or 429, with the hub's `error` code (`already_answered`,
    /// `question_changed`, `question_expired`, `not_open`, `not_answerable`, ...); also a 403
    /// `forbidden` (the token is good, its role may not answer this way: typed `text` from a
    /// token that isn't an owner).
    case refused(code: String)
}

/// One poll response.
public struct FeedPage: Equatable, Sendable {
    /// Open items; after a `since` poll also items closed since then (docs/API.md), which
    /// `ItemStore.merge` drops from the open set.
    public var items: [Item]
    /// True when the response is every open item (no `since`), so absences mean "closed".
    public var isFullSnapshot: Bool
    /// Short name of the hub that answered (nil for the demo feed).
    public var source: String?
    /// The hub's `server_time`: the `since` for the next poll of the same hub. Nil from feeds
    /// without one (the demo feed, older hubs); the newest `updated_at` stands in then.
    public var cursor: Date?
    /// The hub had more than it returned (`more`).
    public var more: Bool
    /// The hub's opaque `next` cursor, sent back with the next `since` poll of the same hub.
    /// Nil from hubs before it (0.1.2 and older) and feeds without one.
    public var next: String?

    public init(items: [Item], isFullSnapshot: Bool, source: String? = nil, cursor: Date? = nil, more: Bool = false,
                next: String? = nil) {
        self.items = items
        self.isFullSnapshot = isFullSnapshot
        self.source = source
        self.cursor = cursor
        self.more = more
        self.next = next
    }
}

extension ItemFeed {
    public func fetchPage(since: Date?) async throws -> FeedPage {
        FeedPage(items: try await fetchOpen(since: since), isFullSnapshot: since == nil)
    }

    public func fetchPage(since: Date?, cursor: String?) async throws -> FeedPage {
        try await fetchPage(since: since)
    }

    /// Feeds that can't answer (test doubles) refuse.
    public func answer(id: String, _ answer: AnswerRequest) async throws -> AnswerOutcome {
        .refused(code: "not_answerable")
    }
}

/// The Mac's PATCH body: `status` (dismissed/resolved) and/or `seen_at`.
public struct ItemPatch: Encodable, Equatable, Sendable {
    public var status: ItemStatus?
    public var seenAt: Date?

    public init(status: ItemStatus? = nil, seenAt: Date? = nil) {
        self.status = status
        self.seenAt = seenAt
    }

    enum CodingKeys: String, CodingKey {
        case status
        case seenAt = "seen_at"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(seenAt, forKey: .seenAt)
    }
}

public struct HubConfig: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public enum HubError: Error, LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case http(status: Int)
    case invalidResponse
    /// 421: the hub doesn't answer to this URL's host name (its DNS-rebinding check).
    case misdirected

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Hub URL or token not set"
        case .unauthorized: return "Hub rejected the token (401/403)"
        case .misdirected: return "Hub doesn't answer to this host name (421): use its tailnet name or IP, or add the name to the hub's allowed_hosts"
        case .http(let status): return "Hub returned HTTP \(status)"
        case .invalidResponse: return "Hub sent an unreadable response"
        }
    }
}

/// Client for the hub's v1 API, as specified in docs/API.md.
public final class HubClient: ItemFeed, @unchecked Sendable {
    public let config: HubConfig
    let session: URLSession  // (internal: StatusRecords.swift fetches statuses with it)

    /// `session` defaults to `HubSession.shared` (ephemeral, no URLCache, no cookies), so
    /// rebuilding clients on a hub switch never leaves sessions behind.
    public init(config: HubConfig, session: URLSession = HubSession.shared) {
        self.config = config
        self.session = session
    }

    // MARK: Request building (pure, tested)

    /// GET /v1/items?status=open[&since=<ts>[&cursor=<next>]]. The cursor goes only with a
    /// `since`: a hub that predates it ignores it and uses `since`, and so does a newer hub
    /// whose database was replaced since it issued the cursor.
    public static func listURL(base: URL, since: Date?, cursor: String? = nil, limit: Int? = nil) -> URL {
        var query = [URLQueryItem(name: "status", value: "open")]
        if let since {
            query.append(URLQueryItem(name: "since", value: HubJSON.formatDate(since)))
            if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        }
        return listURL(base: base, query: query, limit: limit)
    }

    /// GET /v1/items?cursor=<next>&limit=<n>: the rest of a full poll the hub cut short.
    /// No `since`: falling back to it can't continue a full poll, so a cursor the hub can't
    /// read any more is a 400 and the next poll starts over (docs/API.md).
    public static func continueURL(base: URL, cursor: String, limit: Int) -> URL {
        listURL(base: base, query: [URLQueryItem(name: "cursor", value: cursor)], limit: limit)
    }

    private static func listURL(base: URL, query: [URLQueryItem], limit: Int?) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v1/items"), resolvingAgainstBaseURL: false)!
        var query = query
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        components.queryItems = query
        // "+" is legal in a query but many servers read it as a space; encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// PATCH /v1/items/{id}
    public static func itemURL(base: URL, id: String) -> URL {
        base.appendingPathComponent("v1/items").appendingPathComponent(id)
    }

    public static func makeRequest(url: URL, method: String, token: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: ItemFeed

    public func fetchOpen(since: Date?) async throws -> [Item] {
        try await fetchPage(since: since).items.filter { $0.status == .open }
    }

    /// Most pages fetched in one poll while the hub says `more`.
    public static let maxPagesPerPoll = 10
    /// `limit` for a full poll: the most a hub serves (docs/API.md), so even a hub that can't
    /// continue a full poll (0.1.3 and older) gives the whole set up to this size.
    public static let fullPollLimit = 2000

    /// docs/API.md "The polling loop": with `since`, closed items come back too (that's how
    /// a sender's resolve or dismiss reaches the Mac), `next` and `server_time` are the next
    /// cursor, and `more` means poll again at once.
    public func fetchPage(since: Date?) async throws -> FeedPage {
        try await fetchPage(since: since, cursor: nil)
    }

    /// `cursor` is the `next` of this hub's previous page; it goes with `since` only. A hub
    /// that sends `next` pages by it (always moving on, `limit` at most); an older one by
    /// `server_time`.
    public func fetchPage(since: Date?, cursor: String?) async throws -> FeedPage {
        guard let since else { return try await fetchFullPoll() }
        var page = try await fetchOnePage(since: since, cursor: cursor)
        var pages = 1
        while page.more, let serverTime = page.cursor, pages < Self.maxPagesPerPoll {
            let next = try await fetchOnePage(since: serverTime, cursor: page.next)
            page = FeedPage(items: page.items + next.items, isFullSnapshot: false,
                            cursor: next.cursor ?? serverTime, more: next.more, next: next.next)
            pages += 1
        }
        return page
    }

    /// Every open item. A hub with more than `fullPollLimit` cuts the response short (`more`)
    /// and its `next` continues it as changes; those pages are followed here. Only a single
    /// complete page is authoritative: hubs up to 0.1.3 send a `next` that skips the rest, so
    /// a paged one is merged without dropping what's missing (the cursor polls after it
    /// still bring every close).
    private func fetchFullPoll() async throws -> FeedPage {
        var page = try await fetchOnePage(url: Self.listURL(base: config.baseURL, since: nil, limit: Self.fullPollLimit),
                                          since: nil)
        var pages = 1
        while page.more, let next = page.next, pages < Self.maxPagesPerPoll {
            let rest = try await fetchOnePage(url: Self.continueURL(base: config.baseURL, cursor: next, limit: Self.fullPollLimit),
                                              since: page.cursor ?? Date())
            page = FeedPage(items: page.items + rest.items, isFullSnapshot: false,
                            cursor: rest.cursor ?? page.cursor, more: rest.more, next: rest.next ?? next)
            pages += 1
        }
        return page
    }

    private func fetchOnePage(since: Date?, cursor: String?) async throws -> FeedPage {
        try await fetchOnePage(url: Self.listURL(base: config.baseURL, since: since, cursor: cursor), since: since)
    }

    /// `since` only picks how the page is read: nil is a full poll's first page.
    private func fetchOnePage(url: URL, since: Date?) async throws -> FeedPage {
        let request = Self.makeRequest(url: url, method: "GET", token: config.token)
        let data = try await send(request)
        do {
            return try Self.page(from: data, since: since)
        } catch {
            throw HubError.invalidResponse
        }
    }

    /// One `GET /v1/items` response as a page (pure, tested). A full snapshot keeps only open
    /// items and is authoritative unless the hub cut it short (`more`); an incremental one
    /// keeps every status.
    public static func page(from data: Data, since: Date?) throws -> FeedPage {
        let list = try HubJSON.decodeListResponse(data)
        let full = since == nil
        return FeedPage(items: full ? list.items.filter { $0.status == .open } : list.items,
                        isFullSnapshot: full && !list.more, cursor: list.serverTime, more: list.more,
                        next: list.next)
    }

    public func patch(id: String, _ patch: ItemPatch) async throws {
        let body = try HubJSON.makeEncoder().encode(patch)
        let request = Self.makeRequest(url: Self.itemURL(base: config.baseURL, id: id), method: "PATCH", token: config.token, body: body)
        _ = try await send(request)
    }

    public func answer(id: String, _ answer: AnswerRequest) async throws -> AnswerOutcome {
        let body = try HubJSON.makeEncoder().encode(answer)
        let url = Self.itemURL(base: config.baseURL, id: id).appendingPathComponent("answer")
        let request = Self.makeRequest(url: url, method: "POST", token: config.token, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        return try Self.answerOutcome(status: http.statusCode, body: data)
    }

    /// The answer's HTTP status and body as an outcome (pure, so it's tested).
    public static func answerOutcome(status: Int, body: Data) throws -> AnswerOutcome {
        switch status {
        case 200..<300: return .taken
        case 403 where errorCode(body) == "forbidden":
            // A good token whose role may not answer this way (typed words from a reader):
            // the hub's refusal, not a token error, so the card can say what to do instead.
            return .refused(code: "forbidden")
        case 401, 403: throw HubError.unauthorized
        case 421: throw HubError.misdirected
        case 400, 404, 409, 429:
            return .refused(code: errorCode(body) ?? "http_\(status)")
        default: throw HubError.http(status: status)
        }
    }

    private static func errorCode(_ body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    public func health() async throws {
        let request = Self.makeRequest(url: config.baseURL.appendingPathComponent("v1/health"), method: "GET", token: config.token)
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw HubError.unauthorized
        case 421: throw HubError.misdirected
        default: throw HubError.http(status: http.statusCode)
        }
    }
}
