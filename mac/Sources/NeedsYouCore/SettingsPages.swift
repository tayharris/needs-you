import Foundation

// The Settings window's pages: a sidebar like System Settings, with short pages instead of
// long tabs. The window itself is in the app (SettingsWindow.swift); the page list, which
// pages show, and where a deep link lands live here so they can be tested.

/// One Settings page. (The name is from when these were tabs; menu items and links open
/// one with `SettingsWindowController.show(tab:)`.)
///
/// The middle group is named after tasks, not parts: Your inbox (the hub inside this app),
/// Connect a machine (make an invite link), Machines (who's connected) and Other hubs
/// (advanced: joining another hub, adding one by hand, always-on server hubs).
public enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    // Inbox and machines
    case inbox, connect, machines, otherHubs
    // The app
    case panel, appearance, alerts, integrations, updates, advanced

    public var title: String {
        switch self {
        case .general: return "General"
        case .inbox: return "Your inbox"
        case .connect: return "Connect a machine"
        case .machines: return "Machines"
        case .otherHubs: return "Other hubs (advanced)"
        case .panel: return "Panel"
        case .appearance: return "Appearance"
        case .alerts: return "Alerts"
        case .integrations: return "Integrations"
        case .updates: return "Updates"
        case .advanced: return "Advanced"
        }
    }

    /// SF Symbol for the sidebar and the page header.
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .inbox: return "tray.full"
        case .connect: return "plus.circle"
        case .machines: return "desktopcomputer"
        case .otherHubs: return "server.rack"
        case .panel: return "rectangle.on.rectangle"
        case .appearance: return "paintpalette"
        case .alerts: return "bell.badge"
        case .integrations: return "puzzlepiece.extension"
        case .updates: return "arrow.down.circle"
        case .advanced: return "gearshape.2"
        }
    }

    /// One or two plain sentences under the page title: what this page is for.
    public var summary: String {
        switch self {
        case .general:
            return "Your name, starting at login, and demo mode."
        case .inbox:
            return "This Mac holds your alerts: it runs the hub your machines and agents send to."
        case .connect:
            return "Make a link that sets up a server, an agent or another Mac to use your inbox."
        case .machines:
            return "Every machine connected to your inbox, and open invite links. Revoke any of them."
        case .otherHubs:
            return "Optional. Join a hub someone else runs, add one by URL, or use always-on server hubs."
        case .panel:
            return "How the floating pill and its cards look, where they show, and the shortcut."
        case .appearance:
            return "The pill's and cards' colours: a theme, light or dark, and an accent colour."
        case .alerts:
            return "How loudly new items arrive, what can interrupt you, and when."
        case .integrations:
            return "What the shortcut and a card's Terminal button do, and live updates."
        case .updates:
            return "This app's version, automatic updates, and which machines are out of date."
        case .advanced:
            return "Reset the look and alerts, and where settings are kept."
        }
    }

    public var group: SettingsSidebarGroup {
        switch self {
        case .general: return .start
        case .inbox, .connect, .machines, .otherHubs: return .hubs
        case .panel, .appearance, .alerts, .integrations, .updates, .advanced: return .app
        }
    }

    /// Machines lists the owner hub's invites and tokens, so it only shows with an owner
    /// token (and not in demo mode). Every other page always shows; Connect a machine
    /// explains how to get an owner token when there isn't one.
    public func isVisible(canInvite: Bool) -> Bool {
        self != .machines || canInvite
    }

    /// The page to show for a request: a hidden page falls back to the nearest one that
    /// explains why (Machines → Connect a machine).
    public func resolved(canInvite: Bool) -> SettingsTab {
        isVisible(canInvite: canInvite) ? self : .connect
    }

    // The old page names, so code written against them still lands on the right page.
    @available(*, deprecated, renamed: "inbox")
    public static let thisMac = SettingsTab.inbox
    @available(*, deprecated, renamed: "connect")
    public static let invite = SettingsTab.connect
    @available(*, deprecated, renamed: "machines")
    public static let access = SettingsTab.machines
    @available(*, deprecated, renamed: "otherHubs")
    public static let joinHub = SettingsTab.otherHubs
    @available(*, deprecated, renamed: "otherHubs")
    public static let hubs = SettingsTab.otherHubs
}

/// The sidebar's groups, in order.
public enum SettingsSidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case start, hubs, app

    public var id: String { rawValue }

    /// Section header in the sidebar; nil for none.
    public var title: String? {
        switch self {
        case .start: return nil
        case .hubs: return "Inbox and machines"
        case .app: return "Needs You"
        }
    }

    /// This group's visible pages, in sidebar order.
    public func pages(canInvite: Bool) -> [SettingsTab] {
        SettingsTab.allCases.filter { $0.group == self && $0.isVisible(canInvite: canInvite) }
    }
}

/// Links the Settings pages show, on GitHub in the repository the updater uses (https, so
/// they pass the link allow-list).
public enum SettingsLinks {
    /// docs/HUB.md: optional always-on server hubs, set up from the command line.
    public static func serverHubGuide(repository: String = UpdateSource.defaultRepository) -> URL {
        URL(string: "https://github.com/\(repository)/blob/main/docs/HUB.md")!
    }

    /// docs/guides/concepts.md: the words (hub, sender, reader, owner, link, server hub).
    public static func wordsGuide(repository: String = UpdateSource.defaultRepository) -> URL {
        URL(string: "https://github.com/\(repository)/blob/main/docs/guides/concepts.md")!
    }
}

// MARK: - Connect a machine: the kinds of machine

extension HubRole {
    /// The choice on Connect a machine, in plain words.
    public var connectTitle: String {
        switch self {
        case .sender: return "A server or agent that sends alerts"
        case .reader: return "Another Mac that shows the same alerts"
        case .owner: return "Another Mac that can also connect machines (advanced)"
        }
    }

    /// One more sentence about the choice.
    public var connectDetail: String {
        switch self {
        case .sender: return "It gets the needs-you command, not this app. It sends alerts but can't see yours."
        case .reader: return "It needs this app. It shows the same alerts, but can't connect machines."
        case .owner: return "Like another Mac, and it can also make links and revoke machines. Only for your own Macs."
        }
    }

    /// The role on Machines.
    public var machineLabel: String {
        switch self {
        case .sender: return "Sends alerts"
        case .reader: return "Mac, shows alerts"
        case .owner: return "Mac, owner"
        }
    }
}

// MARK: - Machines: one row

/// The line under a machine's name on Machines: what it is, its open items and, for a
/// sender, the CLI version it last reported.
public enum MachineRowText {
    /// A sender that hasn't reported a CLI version: it hasn't posted since it was updated
    /// to a CLI that reports one (or hasn't posted at all).
    public static let versionUnknown = "version unknown (hasn't posted since updating)"

    public static func detail(_ token: TokenSummary, hostNames: [String] = []) -> String {
        var parts = [token.role?.machineLabel ?? "Unknown role"]
        if let mine = thisMac(token, hostNames: hostNames) { parts.append(mine.label) }
        if token.openItems > 0 { parts.append("\(token.openItems) open") }
        if token.role == .sender || token.role == nil {
            if let cli = token.client["cli"], SemVer(cli) != nil {
                parts.append("CLI \(cli)")
            } else {
                parts.append(versionUnknown)
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Which part of this Mac a token on Machines belongs to. The Mac shows up more than once
/// when its agents were set up too: the app's own token (`current`, "this-mac"), and a
/// sender token from an invite redeemed here, named after this Mac by the hub
/// (`<invite name>-<host>`, or just the host). Told apart by name only: the wire has no
/// "same machine" field, so a token named after this Mac's host counts as this Mac.
public enum ThisMacPart: Equatable, Sendable {
    /// The Needs You app (the token Settings is using).
    case app
    /// The `needs-you` command and agent hooks on this Mac (a sender token).
    case agents
    /// Some other token named after this Mac (a reader or owner link redeemed here).
    case other

    public var label: String {
        switch self {
        case .app: return "this Mac: app"
        case .agents: return "this Mac: agents"
        case .other: return "this Mac"
        }
    }
}

extension MachineRowText {
    /// This Mac's names as the hub would put them in a token name: the local host name
    /// and the network host name, each reduced like the hub's `sanitize_host` and cut at
    /// the first dot, lowercased. Empty names and "localhost" are dropped.
    public static func hostNames(_ names: [String?]) -> [String] {
        var out: [String] = []
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for raw in names {
            guard let raw else { continue }
            var s = ""
            var lastDash = false
            for ch in raw {
                if allowed.contains(ch) {
                    s.append(ch)
                    lastDash = false
                } else if !lastDash {
                    s.append("-")
                    lastDash = true
                }
            }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
            let first = String(s.split(separator: ".", maxSplits: 1).first ?? "").lowercased()
            if !first.isEmpty && first != "localhost" && !out.contains(first) { out.append(first) }
        }
        return out
    }

    /// Whether a token is this Mac, and which part. The token Settings is using is the
    /// app; one named after this Mac (`devbox`, `agent-devbox`, `agent-devbox-2`) is its
    /// agents when it sends alerts.
    public static func thisMac(_ token: TokenSummary, hostNames: [String]) -> ThisMacPart? {
        if token.current { return .app }
        guard namedAfter(token.name, hostNames: hostNames) else { return nil }
        return token.role == .sender || token.role == nil ? .agents : .other
    }

    /// Machines in the order shown: this Mac first (the app, then the rest of it), then
    /// the other machines as the hub listed them.
    public static func ordered(_ tokens: [TokenSummary], hostNames: [String]) -> [TokenSummary] {
        func rank(_ t: TokenSummary) -> Int {
            switch thisMac(t, hostNames: hostNames) {
            case .app?: return 0
            case .agents?, .other?: return 1
            case nil: return 2
            }
        }
        return tokens.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static func namedAfter(_ name: String, hostNames: [String]) -> Bool {
        var n = name.lowercased()
        // The hub's "-2", "-3"... for a name already taken.
        if let dash = n.lastIndex(of: "-") {
            let tail = n[n.index(after: dash)...]
            let base = String(n[..<dash])
            if !tail.isEmpty, tail.allSatisfy(\.isASCIIDigit), !base.isEmpty { n = base }
        }
        for host in hostNames where !host.isEmpty {
            if n == host { return true }
            for sep in ["-", ".", "_"] where n.hasSuffix(sep + host) { return true }
        }
        return false
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Other hubs: a join link on the clipboard

/// Settings → Other hubs → Join a hub with a link: picking up a join link from the
/// clipboard. The page reads the clipboard only while it is open (the person opened
/// Settings), never in the background.
public enum ConnectLinkClipboard {
    /// Longer clipboard text is never a join link; don't even look at it.
    public static let maxLength = 2048

    public enum Paste: Equatable, Sendable {
        /// A link `ConnectLink.parse` accepts, trimmed.
        case link(String)
        case notALink
        case empty
    }

    /// What the Paste button does with the clipboard. Only a real join link goes into the
    /// field, so a password or token that happens to be on the clipboard is never shown.
    public static func paste(_ clipboard: String?) -> Paste {
        let text = (clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        guard text.count <= maxLength, ConnectLink.parse(text) != nil else { return .notALink }
        return .link(text)
    }

    /// The link to prefill when the page appears, or nil to leave the field alone: only
    /// when the field is empty, the clipboard holds a join link, the link isn't one already
    /// handled (`ignoring`), and it isn't for this Mac's own hub (`ownHubs`: a Mac link you
    /// just made for someone else is not one to join yourself).
    public static func suggestion(clipboard: String?, draft: String,
                                  ownHubs: [URL] = [], ignoring: [ConnectLink] = []) -> String? {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .link(let text) = paste(clipboard),
              let link = ConnectLink.parse(text),
              !ignoring.contains(link)
        else { return nil }
        let own = Set(ownHubs.map(HubName.key))
        if own.contains(HubName.key(link.hub)) { return nil }
        return text
    }
}
