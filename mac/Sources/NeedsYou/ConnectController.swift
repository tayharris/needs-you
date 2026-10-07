import AppKit
import Foundation
import NeedsYouCore
import os

/// Connecting with an invite link (needsyou://connect?… or http(s)://<hub>/join/<code>)
/// and inviting other machines with an owner token.
@MainActor
final class ConnectController: ObservableObject {
    enum Status: Equatable {
        case working(String)
        case success(String)
        case failure(String)
    }

    @Published private(set) var status: Status? {
        didSet { if let status { log.info("connect: \(String(describing: status), privacy: .public)") } }
    }
    private let log = Logger(subsystem: "app.needsyou.mac", category: "connect")
    /// The link most recently connected with (pasted or opened). Settings → Join a hub
    /// doesn't offer it again from the clipboard. In memory only, never logged.
    @Published private(set) var lastLink: ConnectLink?
    @Published private(set) var invite: InviteResponse?
    @Published private(set) var inviteRole: HubRole = .sender
    @Published private(set) var inviteStatus: Status?
    /// Settings → Access: what the owner hub lists, and the last list/revoke result.
    @Published private(set) var accessInvites: [InviteSummary] = []
    @Published private(set) var accessTokens: [TokenSummary] = []
    @Published private(set) var accessStatus: Status?

    private let settings: AppSettings
    private let model: AppModel
    private let client: InviteClient
    private var connectTask: Task<Void, Never>?
    private var inviteTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?

    init(settings: AppSettings, model: AppModel, client: InviteClient = InviteClient()) {
        self.settings = settings
        self.model = model
        self.client = client
    }

    // MARK: Connect

    /// From a pasted string (Settings) or an opened URL.
    func connect(_ string: String) {
        guard let link = ConnectLink.parse(string) else {
            status = .failure(ConnectError.badLink.errorDescription ?? "Not a connect link")
            return
        }
        connect(link)
    }

    func connect(_ link: ConnectLink) {
        connectTask?.cancel()
        lastLink = link
        let hostLabel = AppSettings.displayName(for: link.hub)
        status = .working("Connecting to \(hostLabel)…")
        let host = LocalHubController.localHostName()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.client.redeem(link, host: host)
                guard !Task.isCancelled else { return }
                try self.apply(response, from: link)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status = .failure(message)
            }
        }
    }

    /// Merge the hubs, store the token (and role) for each, and restart polling.
    private func apply(_ response: RedeemResponse, from link: ConnectLink) throws {
        if let role = response.role, !role.canRead { throw ConnectError.senderOnly }
        let localKey = HubName.key(LocalHub.clientURL)
        let merge = HubListMerge.merge(existing: settings.hubURLs.map(\.absoluteString), given: link.hub,
                                       returned: response.hubURLs, exclude: [localKey])
        var failed: [String] = []
        for hub in merge.tokenHubs where !settings.saveToken(response.token, role: response.role, for: hub) {
            failed.append(HubName.short(hub))
        }
        if failed.count == merge.tokenHubs.count, !merge.tokenHubs.isEmpty { throw ConnectError.tokenStore }
        settings.hubURLStrings = merge.hubs
        settings.pruneTokens()
        if settings.hubsMissingTokens.isEmpty { settings.tokensNeedReconnect = false }
        if settings.demoMode, !settings.demoForcedByEnvironment { settings.demoMode = false }
        model.restartFeed()

        let hubs = merge.tokenHubs.map { HubName.short($0) }.joined(separator: ", ")
        var text = "Connected\(response.name.map { " as “\($0)”" } ?? "") to \(hubs.isEmpty ? AppSettings.displayName(for: link.hub) : hubs)"
        if let role = response.role { text += " (\(role.rawValue))" }
        text += "."
        if !merge.skipped.isEmpty { text += " Skipped \(merge.skipped.count) hub URL(s) that need https." }
        if !failed.isEmpty { text += " Couldn't save the token for \(failed.joined(separator: ", "))." }
        status = .success(text)
    }

    func clearStatus() { status = nil }

    // MARK: Invites

    var canInvite: Bool { settings.hasOwnerHub }

    func createInvite(name: String, role: HubRole, uses: Int, ttlHours: Int) {
        let owners = settings.ownerHubConfigs()
        guard !owners.isEmpty else {
            inviteStatus = .failure("No owner token: connect with an owner link or run the hub on this Mac.")
            return
        }
        let request = InviteRequest(name: name, role: role, uses: uses, ttlHours: ttlHours)
        guard !request.name.isEmpty else {
            inviteStatus = .failure("Give the machine a name, e.g. “build-box”.")
            return
        }
        inviteTask?.cancel()
        invite = nil
        inviteRole = role
        inviteStatus = .working("Creating invite…")
        inviteTask = Task { [weak self] in
            var lastError: Error = ConnectError.invalidResponse
            for hub in owners {
                do {
                    let response = try await self?.client.createInvite(request, hub: hub.baseURL, token: hub.token)
                    guard let self, !Task.isCancelled, let response else { return }
                    self.invite = response
                    self.inviteStatus = response.expiresAt.map { .success("Invite ready. Expires \(Self.formatExpiry($0)).") } ?? .success("Invite ready.")
                    return
                } catch {
                    lastError = error
                    // Only fail over when the hub couldn't be reached.
                    if case ConnectError.unreachable = error { continue }
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.inviteStatus = .failure((lastError as? LocalizedError)?.errorDescription ?? lastError.localizedDescription)
        }
    }

    // MARK: Access (list and revoke invites and tokens)

    func refreshAccess() {
        runAccess(working: "Loading…", success: nil) { _, _, _ in }
    }

    func revoke(_ invite: InviteSummary) {
        runAccess(working: "Revoking invite \(invite.name)…", success: "Revoked invite \(invite.name). Machines it already set up keep their tokens.") { client, hub, token in
            try await client.revokeInvite(id: invite.id, hub: hub, token: token)
        }
    }

    func revoke(_ token: TokenSummary) {
        runAccess(working: "Revoking \(token.name)…", success: "Revoked \(token.name). That machine can no longer post.") { client, hub, owner in
            try await client.revokeToken(id: token.id, hub: hub, token: owner)
        }
    }

    /// Runs `action` against the first reachable owner hub, then reloads both lists from it.
    private func runAccess(working: String, success: String?,
                           _ action: @escaping @Sendable (InviteClient, URL, String) async throws -> Void) {
        let owners = settings.ownerHubConfigs()
        guard !owners.isEmpty else {
            accessStatus = .failure("No owner token: run the hub on this Mac or connect with an owner link.")
            return
        }
        accessTask?.cancel()
        accessStatus = .working(working)
        let client = self.client
        accessTask = Task { [weak self] in
            var lastError: Error = ConnectError.invalidResponse
            for hub in owners {
                do {
                    try await action(client, hub.baseURL, hub.token)
                    let invites = try await client.listInvites(hub: hub.baseURL, token: hub.token)
                    let tokens = try await client.listTokens(hub: hub.baseURL, token: hub.token)
                    guard let self, !Task.isCancelled else { return }
                    self.accessInvites = invites
                    self.accessTokens = tokens.sorted { ($0.current ? 0 : 1, $0.name) < ($1.current ? 0 : 1, $1.name) }
                    self.accessStatus = success.map { .success($0) }
                    return
                } catch {
                    lastError = error
                    if case ConnectError.unreachable = error { continue }
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.accessStatus = .failure((lastError as? LocalizedError)?.errorDescription ?? lastError.localizedDescription)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func formatExpiry(_ raw: String) -> String {
        guard let date = HubJSON.parseDate(raw) else { return raw }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
