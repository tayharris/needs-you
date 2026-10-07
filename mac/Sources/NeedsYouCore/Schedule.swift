import Foundation

// Phase 3: the work/personal schedule and the start-of-day summary (mac/README.md,
// "Design").

/// Default: weekdays 7:00–18:00 = work, everything else = personal.
public struct WorkSchedule: Equatable, Sendable {
    public var startHour: Int
    public var endHour: Int
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday).
    public var workdays: Set<Int>

    public init(startHour: Int = 7, endHour: Int = 18, workdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.startHour = startHour
        self.endHour = endHour
        self.workdays = workdays
    }

    public func context(at date: Date, calendar: Calendar = .current) -> ItemContext {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        guard let weekday = c.weekday, let hour = c.hour, workdays.contains(weekday) else { return .personal }
        return hour >= startHour && hour < endHour ? .work : .personal
    }

    /// The next time the scheduled context flips (a manual override lasts until then).
    public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        let current = context(at: date, calendar: calendar)
        // Walk forward hour by hour (at most 8 days); boundaries are on the hour.
        var probe = calendar.dateInterval(of: .hour, for: date)?.end ?? date.addingTimeInterval(3600)
        for _ in 0..<(24 * 8) {
            if context(at: probe, calendar: calendar) != current { return probe }
            probe = calendar.date(byAdding: .hour, value: 1, to: probe) ?? probe.addingTimeInterval(3600)
        }
        return probe
    }
}

/// A context picked by hand in the header; it holds until the schedule next flips.
public struct ContextOverride: Equatable, Sendable {
    public var context: ItemContext
    public var until: Date

    public init(context: ItemContext, until: Date) {
        self.context = context
        self.until = until
    }

    public static func resolve(schedule: WorkSchedule, override: ContextOverride?, at date: Date, calendar: Calendar = .current) -> ItemContext {
        if let override, override.until > date { return override.context }
        return schedule.context(at: date, calendar: calendar)
    }
}

/// When to open the expanded view for the start-of-day summary: weekdays at 7:30 local,
/// once; if the Mac was asleep at 7:30, on the first check after it.
public struct MorningSummary: Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    public var workdays: Set<Int>

    public init(hour: Int = 7, minute: Int = 30, workdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.hour = hour
        self.minute = minute
        self.workdays = workdays
    }

    /// Today's trigger time, or nil on a non-workday.
    public func trigger(on date: Date, calendar: Calendar = .current) -> Date? {
        guard let weekday = calendar.dateComponents([.weekday], from: date).weekday, workdays.contains(weekday) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    public func isDue(now: Date, lastShown: Date?, calendar: Calendar = .current) -> Bool {
        guard let trigger = trigger(on: now, calendar: calendar), now >= trigger else { return false }
        // Once per day: not if it already ran at/after today's trigger.
        if let lastShown, lastShown >= trigger { return false }
        return true
    }

    /// Items created after this are "since yesterday": the previous summary, else the
    /// start of yesterday.
    public func sinceYesterdayBoundary(now: Date, lastShown: Date?, calendar: Calendar = .current) -> Date {
        if let lastShown, lastShown < now { return lastShown }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }
}
