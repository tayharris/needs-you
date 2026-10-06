import Foundation

// Connecting with an invite link, and minting invites from an owner token.
//
// Hub contract (invites):
//   POST /v1/invites         (Bearer owner) {name, role, uses, ttl_hours}
//                            → 201 {code, join_url, mac_url, expires_at}
//   POST /v1/invites/redeem  (no auth)      {code, host}
//                            → 200 {token, role, name, hub_urls, hub_id} | 404

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

    /// What to paste into an agent on the new machine.
    public var agentPrompt: String {
        hubAgentPrompt ?? "Set up needs-you alerts on this machine: read \(joinURL) and follow it."
    }
    /// What to run on the new machine.
    public var shellOneLiner: String {
        if let hubInstallCommand { return hubInstallCommand }
        var base = joinURL
        while base.hasSuffix("/") { base.removeLast() }
        return "curl -fsSL \(base)/install.sh | bash -s -- --yes"
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
        var known = Set(existing.compactMap(ConnectLink.normalizedHubURL).map(HubName.key))
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
            consider(url, raw: raw)
        }
        return Result(hubs: hubs, tokenHubs: tokenHubs, added: added, skipped: skipped)
    }
}
