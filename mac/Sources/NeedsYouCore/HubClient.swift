import Foundation

/// Where items come from: the real hub, or the demo fixture.
public protocol ItemFeed: Sendable {
    /// Open items; with `since`, only those updated at or after it (PLAN.md, "API (v1)").
    func fetchOpen(since: Date?) async throws -> [Item]
    /// PATCH /v1/items/{id}.
    func patch(id: String, _ patch: ItemPatch) async throws
    /// What the app polls: items plus whether they form a full snapshot and which hub
    /// served them. The default wraps `fetchOpen`.
    func fetchPage(since: Date?) async throws -> FeedPage
}

/// One poll response.
public struct FeedPage: Equatable, Sendable {
    public var items: [Item]
    /// True when the response is every open item (no `since`), so absences mean "closed".
    public var isFullSnapshot: Bool
    /// Short name of the hub that answered (nil for the demo feed).
    public var source: String?

    public init(items: [Item], isFullSnapshot: Bool, source: String? = nil) {
        self.items = items
        self.isFullSnapshot = isFullSnapshot
        self.source = source
    }
}

extension ItemFeed {
    public func fetchPage(since: Date?) async throws -> FeedPage {
        FeedPage(items: try await fetchOpen(since: since), isFullSnapshot: since == nil)
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

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Hub URL or token not set"
        case .unauthorized: return "Hub rejected the token (401/403)"
        case .http(let status): return "Hub returned HTTP \(status)"
        case .invalidResponse: return "Hub sent an unreadable response"
        }
    }
}

/// Client for the hub's v1 API, as specified in docs/PLAN.md.
public final class HubClient: ItemFeed, @unchecked Sendable {
    public let config: HubConfig
    private let session: URLSession

    public init(config: HubConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: Request building (pure, tested)

    /// GET /v1/items?status=open[&since=<ts>]
    public static func listURL(base: URL, since: Date?) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("v1/items"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "status", value: "open")]
        if let since { query.append(URLQueryItem(name: "since", value: HubJSON.formatDate(since))) }
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
        let request = Self.makeRequest(url: Self.listURL(base: config.baseURL, since: since), method: "GET", token: config.token)
        let data = try await send(request)
        do {
            // Belt and braces: the hub should only return open items, but never show others.
            return try HubJSON.decodeItemList(data).filter { $0.status == .open }
        } catch {
            throw HubError.invalidResponse
        }
    }

    public func patch(id: String, _ patch: ItemPatch) async throws {
        let body = try HubJSON.makeEncoder().encode(patch)
        let request = Self.makeRequest(url: Self.itemURL(base: config.baseURL, id: id), method: "PATCH", token: config.token, body: body)
        _ = try await send(request)
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
        default: throw HubError.http(status: http.statusCode)
        }
    }
}
