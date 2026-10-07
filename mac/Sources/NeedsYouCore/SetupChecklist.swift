import Foundation

// Setup tips: local cards the app derives from its own state when something isn't set up
// yet (no hub, nothing has posted, the hub can't be reached from other machines, no Claude
// Code hooks). They look like sender cards (kind needs, a "Needs You setup" source) but are
// never posted to a hub, never replicated, never counted, and never pulse. Each tip is done
// for good once its condition is met, or once the user dismisses it. Pure, so it's
// unit-tested; AppModel gathers the facts and the views draw the cards.

/// One setup tip. The raw value is what's stored in UserDefaults once it's done or dismissed.
public enum SetupTip: String, CaseIterable, Sendable {
    /// No hub at all: the hub on this Mac is off and none is configured.
    case turnOnHub = "hub"
    /// A hub runs, but nothing has ever posted to it.
    case connectSender = "sender"
    /// The hub on this Mac listens on loopback only while there are other machines.
    case reachFromOtherMachines = "tailscale"
    /// Claude Code is set up for this user, but without the needs-you hooks.
    case claudeHooks = "claude-hooks"
}

/// A Settings page a tip opens. The app maps it to its own tab (one switch), so renaming
/// tabs doesn't touch Core.
public enum SetupSettingsPage: Equatable, Sendable {
    /// The hub on this Mac (Run hub on this Mac, the URL other machines use).
    case thisMac
}

/// What a tip's button does. Guides are ordinary https links on the card, not actions.
public enum SetupAction: Equatable, Sendable {
    /// Opens Settings at a page. Only ever from a click on the card (it activates the app).
    case openSettings(SetupSettingsPage)
    /// Makes a sender invite through the normal invite flow and copies its agent prompt.
    /// The invite code goes to the pasteboard only, never into card text or logs.
    case copyAgentPrompt
}

public struct SetupButton: Equatable, Sendable {
    public var title: String
    /// SF Symbol name.
    public var symbol: String
    public var action: SetupAction

    public init(title: String, symbol: String, action: SetupAction) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

/// A tip as the panel draws it: an ordinary item plus its buttons.
public struct SetupCard: Equatable, Sendable {
    public var tip: SetupTip
    public var item: Item
    public var buttons: [SetupButton]
}

/// The hub on this Mac, as far as setup tips care.
public enum SetupLocalHub: Equatable, Sendable {
    case off
    /// Starting, restarting or failed: no tip is decided from it yet.
    case notReady
    /// Running; `loopbackOnly` when other machines can't reach it (no tailnet address).
    case running(loopbackOnly: Bool)
}

/// What the app knows, cheaply, about its own setup.
public struct SetupState: Equatable, Sendable {
    /// Settings → Panel → Show setup tips.
    public var enabled: Bool = true
    public var isDemo: Bool = false
    /// Any hub is configured (the local hub with its token, or a remote hub with a token).
    public var hasHub: Bool = false
    /// At least one poll has succeeded since the feed was (re)built.
    public var hubReachable: Bool = false
    public var localHub: SetupLocalHub = .off
    /// NEEDS_YOU_HUB_LOOPBACK_ONLY: loopback on purpose (test copies), so no Tailscale tip.
    public var loopbackForced: Bool = false
    /// Some configured token may create invites (the agent prompt needs one).
    public var canInvite: Bool = false
    /// Anything has ever arrived from a hub, or the hub lists a token besides this Mac's.
    public var senderSeen: Bool = false
    /// Remote hubs are configured, or items came from a host other than this Mac.
    public var hasOtherMachines: Bool = false
    /// ~/.claude exists.
    public var claudeCodeInstalled: Bool = false
    /// ~/.claude/settings.json mentions the needs-you hook.
    public var claudeHooksInstalled: Bool = false
    /// Tips done (condition met) or dismissed, by raw value.
    public var closed: Set<String> = []
    /// The cards' context (they show in whichever one is on screen) and time.
    public var context: ItemContext = .work
    public var now: Date = Date()

    public init() {}
}

public enum SetupChecklist {
    /// The meta line on every setup card.
    public static let sourceName = "Needs You setup"
    /// Item ids and keys start with this, so a setup card can't be mistaken for a hub item.
    public static let idPrefix = "needsyou-setup:"

    /// The invite the agent-prompt button makes: one sender, for a day. Token names on the
    /// hub become "agent-<hostname>", like any invite named "agent".
    public static let inviteName = "agent"
    public static let inviteUses = 1
    public static let inviteHours = 24

    // MARK: Conditions

    /// Tips whose condition is met right now: recorded as done for good, so they never come
    /// back (turning the hub off later on purpose doesn't nag).
    public static func satisfied(_ s: SetupState) -> Set<SetupTip> {
        var done: Set<SetupTip> = []
        if s.isDemo { return done }
        if s.hasHub { done.insert(.turnOnHub) }
        if s.senderSeen { done.insert(.connectSender) }
        if s.localHub == .running(loopbackOnly: false) { done.insert(.reachFromOtherMachines) }
        if s.claudeHooksInstalled { done.insert(.claudeHooks) }
        return done
    }

    /// Tips that apply now and aren't done or dismissed, in order.
    public static func pending(_ s: SetupState) -> [SetupTip] {
        guard s.enabled, !s.isDemo else { return [] }
        let done = satisfied(s)
        return SetupTip.allCases.filter { tip in
            !done.contains(tip) && !s.closed.contains(tip.rawValue) && applies(tip, s)
        }
    }

    static func applies(_ tip: SetupTip, _ s: SetupState) -> Bool {
        switch tip {
        case .turnOnHub:
            return !s.hasHub && s.localHub == .off
        case .connectSender:
            // Only once a poll has come back (an empty store before that means nothing),
            // and only where the button can work.
            return s.hasHub && s.hubReachable && s.canInvite && !s.senderSeen
        case .reachFromOtherMachines:
            return s.localHub == .running(loopbackOnly: true) && !s.loopbackForced && s.hasOtherMachines
        case .claudeHooks:
            // After the first sender: the first agent prompt installs the hooks anyway.
            return s.claudeCodeInstalled && !s.claudeHooksInstalled && s.senderSeen && s.hubReachable
        }
    }

    // MARK: Cards

    public static func cards(state s: SetupState) -> [SetupCard] {
        pending(s).map { card($0, state: s) }
    }

    public static func card(_ tip: SetupTip, state s: SetupState) -> SetupCard {
        let title: String
        let body: String
        var priority: ItemPriority = .low
        var links: [ItemLink] = []
        var buttons: [SetupButton] = []
        switch tip {
        case .turnOnHub:
            priority = .normal
            title = "Turn on the hub on this Mac"
            body = "Agents and servers post to a hub, and this app can run one for you. "
                + "Turn on **Run hub on this Mac** in Settings, or connect to a hub you already have."
            buttons = [SetupButton(title: "Open Settings", symbol: "gearshape", action: .openSettings(.thisMac))]
            links = [ItemLink(label: "Quickstart", url: guideURL("quickstart.md"))]
        case .connectSender:
            priority = .normal
            title = "Connect your first agent or machine"
            body = "Nothing has posted here yet. Copy the agent prompt and paste it into Claude Code, "
                + "on this Mac or on a server: it installs the `needs-you` CLI and sends a test card. "
                + "The prompt holds a one-use invite that expires in \(inviteHours) hours."
            buttons = [SetupButton(title: "Copy agent prompt", symbol: "doc.on.doc", action: .copyAgentPrompt)]
            links = [ItemLink(label: "Add a sender", url: guideURL("add-a-sender.md")),
                     ItemLink(label: "Claude Code", url: guideURL("claude-code.md"))]
        case .reachFromOtherMachines:
            title = "Reach this Mac from your other machines"
            body = "The hub on this Mac only listens on 127.0.0.1, so servers and other machines can't post to it. "
                + "Install Tailscale here and on them: the hub picks up the tailnet address by itself."
            buttons = [SetupButton(title: "Open Settings", symbol: "gearshape", action: .openSettings(.thisMac))]
            links = [ItemLink(label: "Tailscale guide", url: guideURL("tailscale.md"))]
        case .claudeHooks:
            title = "Install the Claude Code hooks on this Mac"
            body = "Claude Code is set up here, but without the needs-you hooks, so a waiting session can't "
                + "send you a card. Paste the agent prompt into Claude Code, or run "
                + "`integrations/claude-code/install-hooks.sh`."
            if s.canInvite {
                buttons = [SetupButton(title: "Copy agent prompt", symbol: "doc.on.doc", action: .copyAgentPrompt)]
            }
            links = [ItemLink(label: "Claude Code guide", url: guideURL("claude-code.md"))]
        }
        let id = idPrefix + tip.rawValue
        let item = Item(id: id, key: id, context: s.context, kind: .needs, priority: priority,
                        title: title, body: body, links: links,
                        source: ItemSource(host: sourceName), createdAt: s.now)
        return SetupCard(tip: tip, item: item, buttons: buttons)
    }

    /// The tip behind a setup card's item id, or nil for any other item.
    public static func tip(forItemID id: String) -> SetupTip? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return SetupTip(rawValue: String(id.dropFirst(idPrefix.count)))
    }

    /// A guide on GitHub, in the same repository the updater uses: https only, so it passes
    /// the link allow-list like any card link.
    public static func guideURL(_ file: String, repository: String = UpdateSource.defaultRepository) -> String {
        "https://github.com/\(repository)/blob/main/docs/guides/\(file)"
    }

    // MARK: Facts

    /// Is a hub URL loopback only ("http://127.0.0.1:8765")? Unparseable counts as not.
    public static func isLoopbackOnly(publicURL: String) -> Bool {
        guard let host = URL(string: publicURL)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Did any item come from a machine other than this one? Hosts compare by their first
    /// label, case-insensitively ("Studio-Mac.local" is "studio-mac"); items without a host
    /// and setup cards don't count.
    public static func hasOtherHosts(_ items: [Item], localHost: String) -> Bool {
        let me = shortHost(localHost)
        return items.contains { item in
            guard tip(forItemID: item.id) == nil, let host = ItemStore.host(of: item) else { return false }
            let short = shortHost(host)
            return !short.isEmpty && short != me
        }
    }

    static func shortHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// Does a Claude Code settings.json reference the needs-you hook? The same check as
    /// `needs-you doctor`: the hook script's name anywhere in the file.
    public static func referencesNeedsYouHook(settingsJSON: String?) -> Bool {
        settingsJSON?.contains("needs-you-hook.sh") ?? false
    }

    /// Claude Code facts for `home`: is ~/.claude there, and do its user settings use the
    /// hook. Reads at most 1 MB of settings.json; never writes.
    public static func claudeCode(home: URL, fileManager: FileManager = .default) -> (installed: Bool, hooks: Bool) {
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return (false, false) }
        let settings = dir.appendingPathComponent("settings.json")
        guard let handle = try? FileHandle(forReadingFrom: settings) else { return (true, false) }
        defer { try? handle.close() }
        let data: Data? = try? handle.read(upToCount: 1_048_576)
        let text = data.flatMap { String(data: $0, encoding: .utf8) }
        return (true, referencesNeedsYouHook(settingsJSON: text))
    }
}
