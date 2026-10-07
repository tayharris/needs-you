import Foundation

// The Settings window's pages: a sidebar like System Settings, with short pages instead of
// long tabs. The window itself is in the app (SettingsWindow.swift); the page list, which
// pages show, and where a deep link lands live here so they can be tested.

/// One Settings page. (The name is from when these were tabs; menu items and links open
/// one with `SettingsWindowController.show(tab:)`.)
public enum SettingsTab: String, CaseIterable, Hashable, Sendable {
    case general
    // Hubs
    case thisMac, joinHub, invite, access, hubs
    // The app
    case panel, alerts, integrations, updates, advanced

    public var title: String {
        switch self {
        case .general: return "General"
        case .thisMac: return "This Mac"
        case .joinHub: return "Join a hub"
        case .invite: return "Invite a machine"
        case .access: return "Access"
        case .hubs: return "Hubs (manual)"
        case .panel: return "Panel"
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
        case .thisMac: return "desktopcomputer"
        case .joinHub: return "link"
        case .invite: return "person.badge.plus"
        case .access: return "key"
        case .hubs: return "server.rack"
        case .panel: return "rectangle.on.rectangle"
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
        case .thisMac:
            return "The hub that runs inside this app. Your agents and servers send alerts to it."
        case .joinHub:
            return "Use a link from another Mac or a server hub to see its alerts here."
        case .invite:
            return "Make a link that sets up a server, an agent or another Mac to use your hub."
        case .access:
            return "Open invite links and the machines that can use your hub. Revoke any of them."
        case .hubs:
            return "Add a hub by its URL and a token, if you were given those instead of a link."
        case .panel:
            return "How the floating pill and its cards look, where they show, and the shortcut."
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
        case .thisMac, .joinHub, .invite, .access, .hubs: return .hubs
        case .panel, .alerts, .integrations, .updates, .advanced: return .app
        }
    }

    /// Access lists the owner hub's invites and tokens, so it only shows with an owner
    /// token (and not in demo mode). Every other page always shows; Invite a machine
    /// explains how to get an owner token when there isn't one.
    public func isVisible(canInvite: Bool) -> Bool {
        self != .access || canInvite
    }

    /// The page to show for a request: a hidden page falls back to the nearest one that
    /// explains why (Access → Invite a machine).
    public func resolved(canInvite: Bool) -> SettingsTab {
        isVisible(canInvite: canInvite) ? self : .invite
    }
}

/// The sidebar's groups, in order.
public enum SettingsSidebarGroup: String, CaseIterable, Identifiable, Sendable {
    case start, hubs, app

    public var id: String { rawValue }

    /// Section header in the sidebar; nil for none.
    public var title: String? {
        switch self {
        case .start: return nil
        case .hubs: return "Hubs"
        case .app: return "Needs You"
        }
    }

    /// This group's visible pages, in sidebar order.
    public func pages(canInvite: Bool) -> [SettingsTab] {
        SettingsTab.allCases.filter { $0.group == self && $0.isVisible(canInvite: canInvite) }
    }
}

// MARK: - Join a hub: the clipboard

/// Settings → Join a hub: picking up a join link from the clipboard. The page reads the
/// clipboard only while it is open (the person opened Settings), never in the background.
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
