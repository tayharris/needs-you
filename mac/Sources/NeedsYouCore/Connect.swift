import Foundation

// Connecting with an invite link, and minting invites from an owner token.
//
// Hub contract (invites):
//   POST /v1/invites         (Bearer owner) {name, role, uses, ttl_hours}
//                            → 201 {code, join_url, mac_url, expires_at}
//   POST /v1/invites/redeem  (no auth)      {code, host}
//                            → 200 {token, role, name, hub_urls, hub_id} | 404
//   GET /v1/invites, DELETE /v1/invites/<id>, GET /v1/tokens, DELETE /v1/tokens/<id>
//                            (Bearer owner) list and revoke
//   POST|DELETE /v1/tokens/<id>/request-update
//                            (Bearer owner) ask a sender machine to update, or withdraw it

/// A token's role on the hub. `owner` = reader + may create invites.
public enum HubRole: String, Codable, CaseIterable, Sendable {
    case sender, reader, owner

    /// Can this role read the item list (i.e. drive the Mac panel)?
    public var canRead: Bool { self != .sender }
    public var canInvite: Bool { self == .owner }
}

/// A parsed connect link: which hub to redeem with, and the invite code.
public struct ConnectLink: Equatable, Sendable {
    public var hub: URL
    public var code: String

    public init(hub: URL, code: String) {
        self.hub = hub
        self.code = code
    }

    public static let scheme = "needsyou"

    /// Accepts
    ///   needsyou://connect?hub=<urlencoded hub url>&code=<code>
    ///   http(s)://<hub>[/prefix]/join/<code>[/]
    /// and nothing else.
    public static func parse(_ string: String) -> ConnectLink? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case Self.scheme:
            guard components.host?.lowercased() == "connect",
                  components.path.isEmpty || components.path == "/"
            else { return nil }
            let query = components.queryItems ?? []
            guard let hubString = query.first(where: { $0.name == "hub" })?.value,
                  let hub = normalizedHubURL(hubString),
                  let code = query.first(where: { $0.name == "code" })?.value,
                  isValidCode(code)
            else { return nil }
            return ConnectLink(hub: hub, code: code)

        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
            var parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, parts[parts.count - 2] == "join" else { return nil }
            let code = parts.removeLast()
            parts.removeLast() // "join"
            guard isValidCode(code) else { return nil }
            var base = URLComponents()
            base.scheme = scheme
            base.host = host
            base.port = components.port
            base.path = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
            guard let hubURL = base.url else { return nil }
            return ConnectLink(hub: hubURL, code: code)

        default:
            return nil
        }
    }

    /// Invite codes are URL-safe tokens.
    public static func isValidCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return code.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// http(s)://host[:port][/path], no query/fragment, no trailing slash.
    public static func normalizedHubURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty
        else { return nil }
        c.scheme = scheme
        c.query = nil
        c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url
    }
}

extension ConnectLink {
    /// What the app asks before redeeming a link that arrived from outside (a browser, chat
    /// or `open`). Any web page can open a needsyou:// URL; without this a page could connect
    /// the app to a hub it controls and put its own cards in the panel.
    public var confirmation: (title: String, message: String) {
        let name = hub.host ?? hub.absoluteString
        return ("Connect to \(name)?",
                "A link asked Needs You to join the hub at \(hub.absoluteString). Its items will "
                + "show in your panel and it will learn this Mac's name. Connect only if you "
                + "made or asked for this invite.")
    }
}

/// Plain http is fine on the tailnet (Tailscale encrypts) and on this machine; anything
/// else needs https. Mirrors the bundle's ATS exceptions (Resources/Info.plist).
public enum HubTransportPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let raw = url.host?.lowercased(), !raw.isEmpty else { return false }
        let host = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        if host == "localhost" || host.hasSuffix(".ts.net") || host.hasSuffix(".local") { return true }
        if isIPLiteral(host) { return true }   // ATS does not apply to IP addresses
        return !host.contains(".")             // unqualified names (NSAllowsLocalNetworking)
    }

    public static func isIPLiteral(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.contains(":") { return h.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in UInt8(p) != nil }
    }
}

// MARK: - Wire types

public struct RedeemResponse: Decodable, Equatable, Sendable {
    public var token: String
    public var role: HubRole?
    public var name: String?
    public var hubURLs: [String]
    public var hubID: String?

    enum CodingKeys: String, CodingKey {
        case token, role, name
        case hubURLs = "hub_urls"
        case hubID = "hub_id"
    }

    public init(token: String, role: HubRole?, name: String? = nil, hubURLs: [String] = [], hubID: String? = nil) {
        self.token = token
        self.role = role
        self.name = name
        self.hubURLs = hubURLs
        self.hubID = hubID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        // An unknown role (newer hub) decodes as nil rather than failing the redeem.
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { $0.flatMap(HubRole.init(rawValue:)) }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        hubURLs = (try? c.decodeIfPresent([String].self, forKey: .hubURLs)) ?? []
        hubID = try? c.decodeIfPresent(String.self, forKey: .hubID)
    }
}

public struct InviteRequest: Encodable, Equatable, Sendable {
    public var name: String
    public var role: HubRole
    public var uses: Int
    public var ttlHours: Int

    enum CodingKeys: String, CodingKey {
        case name, role, uses
        case ttlHours = "ttl_hours"
    }

    public static let usesRange = 1...20

    public init(name: String, role: HubRole, uses: Int, ttlHours: Int) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.uses = min(max(uses, Self.usesRange.lowerBound), Self.usesRange.upperBound)
        self.ttlHours = max(ttlHours, 1)
    }
}

public struct InviteResponse: Decodable, Equatable, Sendable {
    public var code: String
    public var joinURL: String
    public var macURL: String?
    public var expiresAt: String?
    /// Optional extras some hubs send for sender invites; preferred when present.
    public var hubAgentPrompt: String?
    public var hubInstallCommand: String?

    enum CodingKeys: String, CodingKey {
        case code
        case joinURL = "join_url"
        case macURL = "mac_url"
        case expiresAt = "expires_at"
        case hubAgentPrompt = "agent_prompt"
        case hubInstallCommand = "install_command"
    }

    public init(code: String, joinURL: String, macURL: String?, expiresAt: String?,
                hubAgentPrompt: String? = nil, hubInstallCommand: String? = nil) {
        self.code = code
        self.joinURL = joinURL
        self.macURL = macURL
        self.expiresAt = expiresAt
        self.hubAgentPrompt = hubAgentPrompt
        self.hubInstallCommand = hubInstallCommand
    }

    /// The installer flags for a machine that runs Claude Code: hooks, skill, alerts on
    /// (docs/guides/claude-code-everywhere.md). The join page lists the rest.
    public static let claudeFlags = "--claude-hooks user --skill --alerts"
    /// The flag to add on a machine that runs OpenAI Codex CLI (integrations/codex/).
    public static let codexFlag = "--codex-hooks user"

    /// What to paste into an agent on the new machine. A hub that predates the Claude
    /// flags sends a shorter prompt; this one is used instead.
    public var agentPrompt: String {
        if let hubAgentPrompt, hubAgentPrompt.contains("--claude-hooks") { return hubAgentPrompt }
        return "Set up needs-you alerts on this machine: read \(joinURL) and follow it. "
            + "If this machine runs Claude Code, use \(Self.claudeFlags). "
            + "If it runs OpenAI Codex CLI, add \(Self.codexFlag)."
    }
    /// What to run on the new machine: the full Claude Code setup.
    public var shellOneLiner: String {
        if let hubInstallCommand, hubInstallCommand.contains("--claude-hooks") { return hubInstallCommand }
        var base = joinURL
        while base.hasSuffix("/") { base.removeLast() }
        return "curl -fsSL \(base)/install.sh | bash -s -- --yes \(Self.claudeFlags)"
    }
}

/// An invite as `GET /v1/invites` lists it (not revoked, not expired; `left` may be 0).
public struct InviteSummary: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: HubRole?
    public var uses: Int
    public var left: Int
    public var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, role, uses, left
        case expiresAt = "expires_at"
    }

    public init(id: String, name: String, role: HubRole?, uses: Int, left: Int, expiresAt: String?) {
        self.id = id
        self.name = name
        self.role = role
        self.uses = uses
        self.left = left
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { $0.flatMap(HubRole.init(rawValue:)) }
        uses = (try? c.decodeIfPresent(Int.self, forKey: .uses)) ?? 0
        left = (try? c.decodeIfPresent(Int.self, forKey: .left)) ?? 0
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}

/// An active token as `GET /v1/tokens` lists it. Never carries the secret.
public struct TokenSummary: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: HubRole?
    public var openItems: Int
    /// The token making the request (this Mac's own owner token).
    public var current: Bool
    /// What the machine last reported (X-Needs-You-Client): "cli", "hook", "skill", "orca"
    /// → "X.Y.Z" / "none" / "unknown". Empty from older hubs or before its first report.
    public var client: [String: String]
    /// When this hub last saw a call from it. Nil from older hubs, or never.
    public var lastSeenAt: Date?
    /// When the owner asked this machine to update (Request update), while the request
    /// stands. The hub clears it once the machine reports another CLI version.
    public var updateRequestedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, role, current, client
        case openItems = "open_items"
        case lastSeenAt = "last_seen_at"
        case updateRequestedAt = "update_requested_at"
    }

    public init(id: String, name: String, role: HubRole?, openItems: Int = 0, current: Bool = false,
                client: [String: String] = [:], lastSeenAt: Date? = nil, updateRequestedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.openItems = openItems
        self.current = current
        self.client = client
        self.lastSeenAt = lastSeenAt
        self.updateRequestedAt = updateRequestedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { $0.flatMap(HubRole.init(rawValue:)) }
        openItems = (try? c.decodeIfPresent(Int.self, forKey: .openItems)) ?? 0
        current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
        // Tolerant: a non-string value (a newer hub) drops that entry, not the token.
        let raw = (try? c.decodeIfPresent([String: JSONScalar].self, forKey: .client)) ?? nil
        client = (raw ?? [:]).compactMapValues(\.string)
        let seen = (try? c.decodeIfPresent(String.self, forKey: .lastSeenAt)) ?? nil
        lastSeenAt = seen.flatMap(HubJSON.parseDate)
        let requested = (try? c.decodeIfPresent(String.self, forKey: .updateRequestedAt)) ?? nil
        updateRequestedAt = requested.flatMap(HubJSON.parseDate)
    }
}

/// What the machine list shows for a token's CLI (Settings → Access / Machines): a
/// **Request update** button while it is behind or unknown, the pending request, or that
/// it's current. "Current" means at least `target`, the version this app carries, which is
/// what its hub serves on /dl and so the newest `needs-you update` can install from it.
public enum MachineUpdateState: Equatable, Sendable {
    /// Not a sender (the Mac, a reader), or no target to compare with (a dev build) and a
    /// known version: nothing to show.
    case notApplicable
    case current
    /// Older than the target, or never reported (`reported` nil, or "unknown").
    case outdated(reported: String?)
    case requested(Date)

    public init(token: TokenSummary, target: SemVer?) {
        guard token.role == .sender else { self = .notApplicable; return }
        if let at = token.updateRequestedAt { self = .requested(at); return }
        let reported = token.client["cli"]
        guard let version = reported.flatMap(SemVer.init) else { self = .outdated(reported: reported); return }
        guard let target else { self = .notApplicable; return }
        self = version < target ? .outdated(reported: reported) : .current
    }

    public var canRequest: Bool {
        if case .outdated = self { return true }
        return false
    }

    /// "Update requested 5m ago" / "Update requested just now".
    public static func requestedLabel(_ at: Date, now: Date) -> String {
        let age = now.timeIntervalSince(at)
        return age < 60 ? "Update requested just now" : "Update requested \(CardAge.short(age)) ago"
    }
}

/// A JSON value that may or may not be a string.
struct JSONScalar: Decodable {
    let string: String?
    init(from decoder: Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
}

public enum ConnectError: Error, LocalizedError, Equatable {
    case badLink
    case httpNotAllowed(host: String)
    case expiredOrUsed
    case unreachable(host: String)
    case unauthorized
    case senderOnly
    case http(status: Int, message: String?)
    case invalidResponse
    case tokenStore

    public var errorDescription: String? {
        switch self {
        case .badLink:
            return "That isn't a needs-you connect link. Paste a needsyou://connect?… link or an http(s)://<hub>/join/<code> URL."
        case .httpNotAllowed(let host):
            return "\(host) uses plain http://, which is only allowed for Tailscale (*.ts.net), local names and IP addresses. Use the hub's MagicDNS name or an https:// URL."
        case .expiredOrUsed:
            return "This link has expired or has already been used. Ask for a new one."
        case .unreachable(let host):
            return "Couldn't reach the hub at \(host). Check that it's running and that this Mac is on the same tailnet."
        case .unauthorized:
            return "The hub rejected this Mac's token. Only an owner token can create invites."
        case .senderOnly:
            return "This link is for a sending machine, not a Mac. Ask for a Mac link (role: another Mac / owner)."
        case .http(let status, let message):
            return message.map { "Hub returned HTTP \(status): \($0)" } ?? "Hub returned HTTP \(status)"
        case .invalidResponse:
            return "The hub sent a response this app doesn't understand. Is it up to date?"
        case .tokenStore:
            return "Couldn't save the token to ~/Library/Application Support/NeedsYou/tokens.json."
        }
    }
}

// MARK: - Shared URLSession

/// One ephemeral, cache-less session for every hub request: nothing hits the disk, and
/// hub switches don't leave un-invalidated sessions behind.
public enum HubSession {
    public static func makeConfiguration(requestTimeout: TimeInterval = 15, resourceTimeout: TimeInterval = 30) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = resourceTimeout
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        return cfg
    }

    public static let shared = URLSession(configuration: makeConfiguration())
}

// MARK: - Client

public struct InviteClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = HubSession.shared) {
        self.session = session
    }

    /// POST /v1/invites/redeem. Never sends a token.
    public func redeem(_ link: ConnectLink, host: String) async throws -> RedeemResponse {
        guard HubTransportPolicy.allows(link.hub) else { throw ConnectError.httpNotAllowed(host: link.hub.host ?? link.hub.absoluteString) }
        var request = URLRequest(url: link.hub.appendingPathComponent("v1/invites/redeem"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["code": link.code, "host": String(host.prefix(100))])
        let data = try await send(request, hub: link.hub, notFound: .expiredOrUsed)
        guard let response = try? JSONDecoder().decode(RedeemResponse.self, from: data),
              !response.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ConnectError.invalidResponse }
        return response
    }

    /// POST /v1/invites with an owner token.
    public func createInvite(_ invite: InviteRequest, hub: URL, token: String) async throws -> InviteResponse {
        guard HubTransportPolicy.allows(hub) else { throw ConnectError.httpNotAllowed(host: hub.host ?? hub.absoluteString) }
        let body = try JSONEncoder().encode(invite)
        let request = HubClient.makeRequest(url: hub.appendingPathComponent("v1/invites"), method: "POST", token: token, body: body)
        let data = try await send(request, hub: hub, notFound: .http(status: 404, message: "this hub doesn't support invites yet"))
        guard let response = try? JSONDecoder().decode(InviteResponse.self, from: data) else { throw ConnectError.invalidResponse }
        return response
    }

    /// GET /v1/invites with an owner token.
    public func listInvites(hub: URL, token: String) async throws -> [InviteSummary] {
        struct Body: Decodable { var invites: [InviteSummary] }
        let data = try await ownerRequest("GET", path: "v1/invites", hub: hub, token: token)
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw ConnectError.invalidResponse }
        return body.invites
    }

    /// GET /v1/tokens with an owner token (active tokens only).
    public func listTokens(hub: URL, token: String) async throws -> [TokenSummary] {
        struct Body: Decodable { var tokens: [TokenSummary] }
        let data = try await ownerRequest("GET", path: "v1/tokens", hub: hub, token: token)
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw ConnectError.invalidResponse }
        return body.tokens
    }

    /// DELETE /v1/invites/<id>.
    public func revokeInvite(id: String, hub: URL, token: String) async throws {
        _ = try await ownerRequest("DELETE", path: "v1/invites/" + id, hub: hub, token: token)
    }

    /// DELETE /v1/tokens/<id>.
    public func revokeToken(id: String, hub: URL, token: String) async throws {
        _ = try await ownerRequest("DELETE", path: "v1/tokens/" + id, hub: hub, token: token)
    }

    /// POST /v1/tokens/<id>/request-update: the machine's next calls to this hub carry
    /// `update_requested`. Returns when the hub recorded it.
    @discardableResult
    public func requestUpdate(id: String, hub: URL, token: String) async throws -> Date? {
        try await updateRequest("POST", id: id, hub: hub, token: token)
    }

    /// DELETE /v1/tokens/<id>/request-update (idempotent).
    public func clearUpdateRequest(id: String, hub: URL, token: String) async throws {
        _ = try await updateRequest("DELETE", id: id, hub: hub, token: token)
    }

    private func updateRequest(_ method: String, id: String, hub: URL, token: String) async throws -> Date? {
        struct Body: Decodable {
            var at: String?
            enum CodingKeys: String, CodingKey { case at = "update_requested_at" }
        }
        let data = try await ownerRequest(method, path: "v1/tokens/" + id + "/request-update", hub: hub, token: token,
                                          notFound: .http(status: 404, message: "not on this hub, or the hub is too old to request updates"))
        return (try? JSONDecoder().decode(Body.self, from: data))?.at.flatMap(HubJSON.parseDate)
    }

    private func ownerRequest(_ method: String, path: String, hub: URL, token: String,
                              notFound: ConnectError? = nil) async throws -> Data {
        guard HubTransportPolicy.allows(hub) else { throw ConnectError.httpNotAllowed(host: hub.host ?? hub.absoluteString) }
        let request = HubClient.makeRequest(url: hub.appendingPathComponent(path), method: method, token: token)
        let notFound: ConnectError = notFound ?? (method == "GET"
            ? .http(status: 404, message: "this hub can't list or revoke yet; update it")
            : .http(status: 404, message: "already revoked, or not on this hub"))
        return try await send(request, hub: hub, notFound: notFound)
    }

    private func send(_ request: URLRequest, hub: URL, notFound: ConnectError) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .appTransportSecurityRequiresSecureConnection {
                throw ConnectError.httpNotAllowed(host: hub.host ?? hub.absoluteString)
            }
            throw ConnectError.unreachable(host: hub.host.map { h in hub.port.map { "\(h):\($0)" } ?? h } ?? hub.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw ConnectError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 404, 410: throw notFound
        case 401, 403: throw ConnectError.unauthorized
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw ConnectError.http(status: http.statusCode, message: message)
        }
    }
}

// MARK: - Hub list merge

public enum HubListMerge {
    public struct Result: Equatable, Sendable {
        /// The new ordered hub list (strings, as stored in settings).
        public var hubs: [String]
        /// Every hub the redeemed token should be stored for (given hub + all returned).
        public var tokenHubs: [URL]
        /// Hubs that weren't in the list before.
        public var added: [URL]
        /// Returned URLs that were dropped (malformed, plain http off the tailnet, or this Mac).
        public var skipped: [String]
    }

    /// Existing order is kept; new hubs are appended, the given hub first if it's new, then
    /// the returned `hub_urls` in order. Deduped by `HubName.key`. `exclude` holds keys that
    /// must not be added (the local hub, which is always listed separately).
    public static func merge(existing: [String], given: URL, returned: [String], exclude: Set<String> = []) -> Result {
        var hubs = existing
        let existingKeys = Set(existing.compactMap(ConnectLink.normalizedHubURL).map(HubName.key))
        var known = existingKeys
        // A link to a hub we don't know yet may add hubs, but it can't re-key the ones we
        // already have: a rogue hub could otherwise name them in `hub_urls` and overwrite
        // their working tokens with its own. Reconnecting through a known hub still does.
        let givenIsKnown = existingKeys.contains(HubName.key(given))
        var tokenKeys = Set<String>()
        var tokenHubs: [URL] = []
        var added: [URL] = []
        var skipped: [String] = []

        func consider(_ url: URL, raw: String) {
            let key = HubName.key(url)
            if exclude.contains(key) { return }
            if tokenKeys.insert(key).inserted { tokenHubs.append(url) }
            if known.insert(key).inserted {
                hubs.append(key)
                added.append(url)
            }
        }

        consider(given, raw: given.absoluteString)
        for raw in returned {
            guard let url = ConnectLink.normalizedHubURL(raw), HubTransportPolicy.allows(url) else {
                skipped.append(raw)
                continue
            }
            if exclude.contains(HubName.key(url)) { skipped.append(raw); continue }
            if !givenIsKnown, existingKeys.contains(HubName.key(url)) { skipped.append(raw); continue }
            consider(url, raw: raw)
        }
        return Result(hubs: hubs, tokenHubs: tokenHubs, added: added, skipped: skipped)
    }
}
