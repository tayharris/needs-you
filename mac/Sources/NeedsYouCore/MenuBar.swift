import Foundation

// Pure rules behind the menu bar icon and the floating panel's visibility, so they can be
// unit-tested without AppKit.

/// The menu bar icon and the floating panel can't both be hidden: there would be no way
/// back except a hotkey the user may not remember. Requests that would hide both are
/// refused, and the icon is the one that stays.
public enum VisibilityRules {
    /// Can the panel be hidden (indefinitely) given the icon setting?
    public static func canHidePanel(showMenuBarIcon: Bool) -> Bool { showMenuBarIcon }

    /// Can the menu bar icon be turned off while the panel is (or isn't) hidden?
    public static func canHideMenuBarIcon(panelHidden: Bool) -> Bool { !panelHidden }

    /// Repair stored settings that hide both (e.g. edited by hand): keep the icon.
    public static func normalized(showMenuBarIcon: Bool, panelHidden: Bool) -> (showMenuBarIcon: Bool, panelHidden: Bool) {
        if !showMenuBarIcon && panelHidden { return (true, true) }
        return (showMenuBarIcon, panelHidden)
    }
}

/// What a new `needs` arrival does while the panel is out of sight.
public enum HiddenArrival: Equatable, Sendable {
    /// Nothing beyond the menu bar count updating.
    case none
    /// One brief pulse of the menu bar icon.
    case pulseMenuBar
    /// Bring the panel back (and pulse it).
    case showPanel
}

public enum HiddenArrivalPolicy {
    /// - Snoozed: an urgent arrival ends the snooze when `urgentBreaksSnooze` (the existing
    ///   setting); otherwise it pulses the menu bar icon.
    /// - Hidden: an urgent arrival pulses the menu bar icon, or shows the panel when
    ///   `urgentShowsHiddenPanel` is on (default off).
    /// - Non-urgent arrivals only update the count.
    /// This is the tier table with no focus and no rules (DeliveryPolicy); kept for its tests.
    public static func decide(visibility: PanelVisibility, announced: [Item], urgentBreaksSnooze: Bool,
                              urgentShowsHiddenPanel: Bool, now: Date) -> HiddenArrival {
        guard visibility.isHidden(at: now) else { return .none }
        let state = DeliveryState(visibility: visibility, urgentBreaksSnooze: urgentBreaksSnooze,
                                  urgentShowsHiddenPanel: urgentShowsHiddenPanel, now: now)
        // Out of sight the context doesn't matter: urgent breaks through in either one.
        let decided = announced.map { item -> (item: Item, decision: DeliveryDecision) in
            var s = state
            s.context = item.context
            return (item: item, decision: DeliveryPolicy.decide(item, state: s))
        }
        return DeliveryPolicy.hiddenArrival(decided)
    }
}

/// Text for the menu bar button and its menu.
public enum MenuBarFormat {
    /// How many items the menu lists.
    public static let maxMenuItems = 5
    public static let maxTitleLength = 60

    /// The number next to the icon, or nil for icon only.
    public static func countTitle(count: Int, showCount: Bool) -> String? {
        guard showCount, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// "This Mac", "hub2": the hub name with its first letter capitalised.
    public static func hubLabel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// The first, disabled line of the menu.
    /// "All clear · This Mac", "3 need you · hub2", "1 needs Sam · This Mac",
    /// "Hub unreachable · 2 waiting", "Not set up".
    public static func statusLine(count: Int, userName: String = "", hub: String?, configured: Bool,
                                  error: String? = nil, demo: Bool = false) -> String {
        guard configured else { return "Not set up · open Settings" }
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = name.isEmpty ? "you" : name
        let source = demo ? "Demo" : hubLabel(hub ?? "hub")
        if let error {
            return count > 0 ? "\(error) · \(count) waiting" : error
        }
        if count == 0 { return "All clear · \(source)" }
        return "\(count) \(count == 1 ? "needs" : "need") \(who) · \(source)"
    }

    /// The top items for the menu, already in panel order (urgent first, then oldest).
    public static func topItems(_ needs: [Item], limit: Int = maxMenuItems) -> [Item] {
        Array(needs.prefix(max(0, limit)))
    }

    /// A menu row title, shortened to `maxLength` characters with an ellipsis.
    public static func itemTitle(_ item: Item, maxLength: Int = maxTitleLength) -> String {
        let title = item.title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard title.count > maxLength, maxLength > 1 else { return title }
        return String(title.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Show Floating Panel" is checked when the panel is in view (not hidden or snoozed).
    public static func panelMenuChecked(visibility: PanelVisibility, now: Date) -> Bool {
        !visibility.isHidden(at: now)
    }
}

/// What clicking an item in the menu does: open its first link that passes the scheme
/// allow-list, else show the panel expanded.
public enum MenuItemAction: Equatable, Sendable {
    case open(URL)
    case showPanel

    public static func forItem(_ item: Item) -> MenuItemAction {
        for link in item.links {
            if let url = LinkPolicy.openableURL(link.url) { return .open(url) }
        }
        return .showPanel
    }
}

/// The arrival preview's one-click button: the item's first link that passes the allow-list
/// (the same one the menu bar opens). Clicking it opens the link and marks the item done,
/// so a "VS Code needs you" alert is handled without opening the panel. Nil: no button,
/// and clicking the preview opens the panel at that card.
public enum PreviewLink {
    public static func primary(_ item: Item) -> ItemLink? {
        item.links.first { LinkPolicy.openableURL($0.url) != nil }
    }
}

/// Which card the panel scrolls to and highlights when it opens: the clicked preview's
/// item, else (a click on the pill) the newest card that arrived since the panel was last
/// open, so a new alert is never left below the fold. Nil leaves the list at the top.
public enum ExpandFocus {
    public static func target(clicked: String?, items: [Item], lastOpenedAt: Date?) -> String? {
        if let clicked { return items.contains { $0.id == clicked } ? clicked : nil }
        guard let lastOpenedAt else { return nil }
        return items.filter { $0.createdAt > lastOpenedAt }.max { $0.createdAt < $1.createdAt }?.id
    }
}
