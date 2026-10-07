import Foundation

/// Snooze durations from PLAN.md ("Snoozed / hidden" and per-card snooze).
public enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
    case minutes15, minutes30, hour1, hours3, tomorrow

    public var id: String { rawValue }

    /// Choices for the whole panel.
    public static let panelChoices: [SnoozeOption] = [.minutes15, .minutes30, .hour1, .hours3, .tomorrow]
    /// Choices for a single card.
    public static let cardChoices: [SnoozeOption] = [.minutes15, .hour1, .tomorrow]

    /// "Until tomorrow" ends at this local hour the next day (start of the default work day).
    public static let tomorrowHour = 7

    public var title: String {
        switch self {
        case .minutes15: return "15 min"
        case .minutes30: return "30 min"
        case .hour1: return "1 hr"
        case .hours3: return "3 hr"
        case .tomorrow: return "Until tomorrow"
        }
    }

    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes15: return now.addingTimeInterval(15 * 60)
        case .minutes30: return now.addingTimeInterval(30 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .hours3: return now.addingTimeInterval(3 * 60 * 60)
        case .tomorrow:
            let startOfToday = calendar.startOfDay(for: now)
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
            return calendar.date(bySettingHour: Self.tomorrowHour, minute: 0, second: 0, of: startOfTomorrow) ?? startOfTomorrow
        }
    }
}

/// Whole-panel visibility. `hidden` is the indefinite hide from the global hotkey.
public enum PanelVisibility: Equatable, Sendable {
    case shown
    case snoozed(until: Date)
    case hidden

    public func isHidden(at now: Date) -> Bool {
        switch self {
        case .shown: return false
        case .hidden: return true
        case .snoozed(let until): return until > now
        }
    }
}

/// Decides whether a new arrival should break through a panel snooze/hide
/// (PLAN.md open decision 2; a setting that defaults to on).
public enum SnoozeBreakthrough {
    /// Any new or re-escalated urgent `needs` item breaks through, in either context:
    /// AGENT-GUIDE defines urgent as "broken now / someone blocked today".
    public static func shouldBreakThrough(
        visibility: PanelVisibility, announced: [Item],
        urgentBreaksThrough: Bool, now: Date
    ) -> Bool {
        // The tier table with no focus and no rules (DeliveryPolicy).
        HiddenArrivalPolicy.decide(visibility: visibility, announced: announced, urgentBreaksSnooze: urgentBreaksThrough,
                                   urgentShowsHiddenPanel: urgentBreaksThrough, now: now) == .showPanel
    }
}
