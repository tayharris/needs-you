import Foundation

// Status records (docs/API.md "Status records", ADR 0011): small keyed records apart from
// items. The app shows `usage` ones as meters (UsageMeters); they never count, animate,
// notify or make a card. Decoding is lenient like items: unknown fields are ignored, a
// newer `type` is kept (and ignored by the UI), a malformed `usage` is nil.

public struct UsageWindow: Decodable, Equatable, Sendable {
    /// `5h` (the session window) or `7d` (the weekly one) from today's producers.
    public var name: String
    /// 0-100.
    public var usedPct: Double
    public var resetsAt: Date?

    public init(name: String, usedPct: Double, resetsAt: Date? = nil) {
        self.name = name
        self.usedPct = usedPct
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case name
        case usedPct = "used_pct"
        case resetsAt = "resets_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let pct = try c.decode(Double.self, forKey: .usedPct)
        usedPct = pct.isFinite ? min(100, max(0, pct)) : 0
        resetsAt = (try? c.decodeIfPresent(Date.self, forKey: .resetsAt)) ?? nil
    }
}

public struct StatusUsage: Decodable, Equatable, Sendable {
    public var provider: String
    /// A local label or hash, never an email (the hub refuses `@`). Empty: the only account.
    public var account: String
    public var windows: [UsageWindow]

    public init(provider: String, account: String = "", windows: [UsageWindow]) {
        self.provider = provider
        self.account = account
        self.windows = windows
    }

    enum CodingKeys: String, CodingKey { case provider, account, windows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        account = (try? c.decodeIfPresent(String.self, forKey: .account)) ?? ""
        // A malformed window is dropped, not the whole record.
        struct Lenient: Decodable {
            let window: UsageWindow?
            init(from decoder: Decoder) throws { window = try? UsageWindow(from: decoder) }
        }
        windows = ((try? c.decodeIfPresent([Lenient].self, forKey: .windows)) ?? nil)?.compactMap(\.window) ?? []
    }
}

public struct StatusRecord: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: String
    /// `usage` or `progress` today; anything else is kept and ignored.
    public var type: String
    public var label: String
    public var detail: String
    public var usage: StatusUsage?
    public var source: ItemSource?
    public var updatedAt: Date
    public var expiresAt: Date?

    public init(id: String, key: String, type: String = "usage", label: String = "", detail: String = "",
                usage: StatusUsage? = nil, source: ItemSource? = nil, updatedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.key = key
        self.type = type
        self.label = label
        self.detail = detail
        self.usage = usage
        self.source = source
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id, key, type, label, detail, usage, source
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? id
        type = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil)?.lowercased() ?? ""
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        usage = (try? c.decodeIfPresent(StatusUsage.self, forKey: .usage)) ?? nil
        source = (try? c.decodeIfPresent(ItemSource.self, forKey: .source)) ?? nil
        updatedAt = ((try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil) ?? .distantPast
        expiresAt = (try? c.decodeIfPresent(Date.self, forKey: .expiresAt)) ?? nil
    }

    public func isExpired(at now: Date) -> Bool {
        if let expiresAt { return expiresAt <= now }
        return false
    }

    /// `GET /v1/status`: `{"statuses": [...]}`. A record that doesn't decode is skipped.
    public static func decodeList(_ data: Data) throws -> [StatusRecord] {
        struct Lenient: Decodable {
            let record: StatusRecord?
            init(from decoder: Decoder) throws { record = try? StatusRecord(from: decoder) }
        }
        struct Wrapped: Decodable { let statuses: [Lenient] }
        return try HubJSON.makeDecoder().decode(Wrapped.self, from: data).statuses.compactMap(\.record)
    }
}

/// One `GET /v1/status` answer.
public enum StatusFetch: Equatable, Sendable {
    /// 304: what the last fetch with this ETag returned still holds.
    case unchanged
    /// The hub's statuses (empty from a hub that predates them) and its ETag.
    case fresh([StatusRecord], etag: String?)
}

/// A feed that can list statuses. HubClient, FailoverFeed and DemoFeed are; other feeds
/// (test doubles) simply have none.
public protocol StatusFeed: Sendable {
    /// `etag` is the one from this feed's last `.fresh` answer, or nil.
    func fetchStatuses(etag: String?) async throws -> StatusFetch
}

extension HubClient: StatusFeed {
    /// GET /v1/status
    public static func statusURL(base: URL) -> URL {
        base.appendingPathComponent("v1/status")
    }

    public static func statusRequest(base: URL, token: String, etag: String?) -> URLRequest {
        var request = makeRequest(url: statusURL(base: base), method: "GET", token: token)
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// The HTTP answer as a fetch (pure, tested): 304 unchanged, 404 a hub without statuses.
    public static func statusOutcome(status: Int, body: Data, etag: String?) throws -> StatusFetch {
        switch status {
        case 304: return .unchanged
        case 404: return .fresh([], etag: nil)
        case 200..<300:
            do {
                return .fresh(try StatusRecord.decodeList(body), etag: etag)
            } catch {
                throw HubError.invalidResponse
            }
        case 401, 403: throw HubError.unauthorized
        case 421: throw HubError.misdirected
        default: throw HubError.http(status: status)
        }
    }

    public func fetchStatuses(etag: String?) async throws -> StatusFetch {
        let request = Self.statusRequest(base: config.baseURL, token: config.token, etag: etag)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        return try Self.statusOutcome(status: http.statusCode, body: data,
                                      etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
