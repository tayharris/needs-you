import Foundation

// The Settings window's pages: a sidebar like System Settings, with short pages instead of
// long tabs. The window itself is in the app (SettingsWindow.swift); the page list, which
// pages show, and where a deep link lands live here so they can be tested.

/// One Settings page. (The name is from when these were tabs; menu items and links open
/// one with `SettingsWindowController.show(tab:)`.)
///
/// The middle group uses the product's three part names (docs/guides/concepts.md): Built-in
/// hub (the hub inside this app), Connect a machine (an invite link for a sender or another
/// Mac), Machines (who's connected) and Other hubs (advanced: server hubs, another hub,
/// adding one by hand).
public enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    // Hubs and machines
    case inbox, connect, machines, otherHubs
    // The app
    case panel, appearance, alerts, usage, integrations, updates, advanced

    public var title: String {
        switch self {
        case .general: return "General"
        case .inbox: return "Built-in hub"
        case .connect: return "Connect a machine"
        case .machines: return "Machines"
        case .otherHubs: return "Other hubs (advanced)"
        case .panel: return "Panel"
        case .appearance: return "Appearance"
        case .alerts: return "Alerts"
        case .usage: return "Usage"
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
        case .usage: return "gauge.medium"
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
            return "The hub inside this app stores the alerts your senders post. On by default; you can use a server hub instead."
        case .connect:
            return "Make a link that sets up a sender (a server or agent machine) or another Mac that shows your alerts."
        case .machines:
            return "Every sender and Mac connected to your hub, and open invite links. Revoke any of them."
        case .otherHubs:
            return "Optional. Join a hub someone else runs, or add one by URL. Always-on server hubs are added in Built-in hub."
        case .panel:
            return "How the floating pill and its cards look, where they show, and the shortcut."
        case .appearance:
            return "The pill's and cards' colours: a theme, light or dark, and an accent colour."
        case .alerts:
            return "How loudly new items arrive, what can interrupt you, and when."
        case .usage:
            return "Meters for your agents' session and weekly limits, as their hooks report them. Never counted or announced."
        case .integrations:
            return "What the shortcut and a card's Terminal button do, and live updates."
        case .updates:
            return "This app's version, automatic updates, and which machines are out of date."
        case .advanced:
            return "Reset the look and alerts, developer mode, and where settings and data are kept."
        }
    }

    public var group: SettingsSidebarGroup {
        switch self {
        case .general: return .start
        case .inbox, .connect, .machines, .otherHubs: return .hubs
        case .panel, .appearance, .alerts, .usage, .integrations, .updates, .advanced: return .app
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
        case .hubs: return "Hubs and machines"
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
        case .sender: return "A sender: it gets the needs-you command, not this app. It sends alerts but can't see yours."
        case .reader: return "It needs this app. It shows the same alerts, but can't connect machines."
        case .owner: return "Like another Mac, and it can also make links and revoke machines. Only for your own Macs."
        }
    }

    /// The role on Machines.
    public var machineLabel: String {
        switch self {
        case .sender: return "Sender"
        case .reader: return "Mac, reader"
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

    public static func detail(_ token: TokenSummary) -> String {
        var parts = [token.role?.machineLabel ?? "Unknown role"]
        if isThisMac(token) { parts.append(thisMacLabel) }
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

extension MachineRowText {
    /// The label on the app's own row.
    public static let thisMacLabel = "this Mac: app"

    /// Whether a token is this Mac: only the token this app is using (`current`, which the
    /// hub sets for the token making the request). Never decided by name: a sender picks
    /// its own invite name and host, so a machine named like this Mac (or "this-mac") is
    /// shown as just its name. Telling which sender runs on this Mac would need the hub to
    /// say so (a wire change).
    public static func isThisMac(_ token: TokenSummary) -> Bool { token.current }

    /// Machines in the order shown: the app's own row first, then the rest as the hub
    /// listed them.
    public static func ordered(_ tokens: [TokenSummary]) -> [TokenSummary] {
        tokens.filter(isThisMac) + tokens.filter { !isThisMac($0) }
    }
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
