import Foundation

// When the open panel may close by itself, and which view (cards or notes) it opens on.
// Pure, so it's unit-tested; AppModel and PanelController only read the answers.
//
// The notes (ADR 0014) are something you read next to your work, so while the panel shows
// them only the person closes it: the chevron, Escape, the shortcut, a double-click on the
// header or a menu's Collapse. A click in another app, opening a link, the launch open's
// timer and arrivals leave it open and on the notes.

/// Why the open panel would close.
public enum CollapseTrigger: Equatable, Sendable {
    /// The person closed it: the chevron, Escape, the shortcut, the header's double-click,
    /// a menu's Collapse.
    case explicit
    /// A click in another app (Settings → Panel → Collapse when clicking elsewhere).
    case clickElsewhere
    /// A link or app action opened from a card (the same setting).
    case openedLink
    /// The panel the launch opened ran out its time with the pointer away (LaunchOpen).
    case launchTimer
}

public enum PanelCollapse {
    /// Should the open panel close for `trigger`? `collapseOnClickOutside` is the setting;
    /// `openedAtLaunch` means the launch opened it, not the person (a click elsewhere always
    /// closes that one, unless it shows the notes).
    public static func collapses(_ trigger: CollapseTrigger, notesMode: Bool,
                                 collapseOnClickOutside: Bool, openedAtLaunch: Bool) -> Bool {
        if trigger == .explicit { return true }
        if notesMode { return false }
        switch trigger {
        case .explicit, .launchTimer: return true
        case .clickElsewhere: return collapseOnClickOutside || openedAtLaunch
        case .openedLink: return collapseOnClickOutside
        }
    }

    /// Does the panel show the notes after an expand? `current` is what it shows now,
    /// `remembered` the view the person last chose with the Notes button (kept across
    /// launches). Opening at a card shows the cards. Already open: nothing else leaves the
    /// notes, so an automatic open (the morning summary) never does. Opening: automatically
    /// (the launch, the morning summary) the cards, which is what those are for; by the
    /// person (the pill, the shortcut, the menu) the view they last chose.
    public static func showsNotes(current: Bool, remembered: Bool, alreadyExpanded: Bool,
                                  byUser: Bool, focusingCard: Bool) -> Bool {
        if focusingCard { return false }
        if alreadyExpanded { return current }
        return byUser && remembered
    }
}
