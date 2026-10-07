import AppKit
import NeedsYouCore
import SwiftUI

// Phase 3 (the build order in docs/adr/0007-founding-design.md): the springy new-item preview, the work/personal
// schedule, the 7:30 start-of-day summary, and the optional SSE stream.
//
// Everything lives in this folder and plugs into AppModel's hooks. To build phase 2
// alone, delete this folder and the `Phase3Controller` lines in AppDelegate.

@MainActor
final class Phase3Controller: ObservableObject {
    private let model: AppModel
    private let defaults: UserDefaults
    private let stream = EventStream()
    private var previewTask: Task<Void, Never>?
    private var override: ContextOverride?

    let schedule = WorkSchedule()
    let summary = MorningSummary()

    private enum Key {
        static let followSchedule = "followSchedule"
        static let morningSummary = "morningSummary"
        static let useStream = "useStream"
        static let lastSummary = "lastMorningSummary"
    }

    @Published var followSchedule: Bool {
        didSet {
            defaults.set(followSchedule, forKey: Key.followSchedule)
            override = nil
            applySchedule()
        }
    }
    @Published var morningSummaryEnabled: Bool {
        didSet { defaults.set(morningSummaryEnabled, forKey: Key.morningSummary) }
    }
    @Published var useStream: Bool {
        didSet {
            defaults.set(useStream, forKey: Key.useStream)
            restartStream()
        }
    }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        defaults.register(defaults: [Key.followSchedule: true, Key.morningSummary: true, Key.useStream: true])
        followSchedule = defaults.bool(forKey: Key.followSchedule)
        morningSummaryEnabled = defaults.bool(forKey: Key.morningSummary)
        useStream = defaults.bool(forKey: Key.useStream)

        model.announcer = { [weak self] _, items in self?.announce(items) }
        model.contextResolver = { [weak self] now in self?.scheduledContext(at: now) }
        model.onContextPicked = { [weak self] picked in self?.contextPicked(picked) }
        model.onFeedRestart = { [weak self] in self?.restartStream() }
        model.onTick = { [weak self] now in self?.checkMorningSummary(now: now) }
        applySchedule()
    }

    // MARK: New-item preview

    /// The pill springs out to a 320 pt preview of the top new item with a glow pulse,
    /// stays out for Settings → Alerts → Show new items for (14 s by default; pointing at it
    /// holds it), then springs back. Urgent pulses twice. (The panel controller animates
    /// the size change with an overshoot curve, or a fade under Reduce Motion.)
    private func announce(_ items: [Item]) {
        // The most urgent; on a tie, one from the context being shown.
        let shown = model.context
        guard let top = items.min(by: { a, b in
            a.priority != b.priority ? a.priority < b.priority : (a.context == shown && b.context != shown)
        }) else { return }
        let urgent = items.contains { $0.priority == .urgent }
        model.previewItem = top
        model.requestPulse(times: urgent ? 2 : 1, priority: top.priority)
        previewTask?.cancel()
        let id = top.id
        previewTask = model.holdPeek(while: { [weak self] in self?.model.previewItem?.id == id }) { [weak self] in
            self?.model.previewItem = nil
        }
    }

    // MARK: Work / personal schedule

    private func scheduledContext(at date: Date) -> ItemContext? {
        guard followSchedule else { return nil }
        return ContextOverride.resolve(schedule: schedule, override: override, at: date)
    }

    /// Picking a side by hand holds until the schedule next flips.
    private func contextPicked(_ picked: ItemContext) {
        guard followSchedule else { return }
        let now = Date()
        override = picked == schedule.context(at: now) ? nil : ContextOverride(context: picked, until: schedule.nextBoundary(after: now))
    }

    private func applySchedule() {
        if let ctx = scheduledContext(at: Date()), ctx != model.settings.viewContext {
            model.settings.viewContext = ctx
        }
    }

    // MARK: Start-of-day summary

    private func checkMorningSummary(now: Date) {
        guard morningSummaryEnabled else { return }
        // A hidden panel stays hidden; the summary shows once it's back (same morning).
        guard model.visibility != .hidden else { return }
        let last = defaults.object(forKey: Key.lastSummary) as? Date
        guard summary.isDue(now: now, lastShown: last) else { return }
        // Wait for a successful poll so the summary isn't empty for the wrong reason.
        // (A snooze left over from last night doesn't block it: expanding shows the panel.)
        guard model.lastCheck != nil else { return }
        defaults.set(now, forKey: Key.lastSummary)
        model.settings.viewContext = .work
        // The start of the day delivers Later (unless a focus is still on).
        model.releaseLater(.startOfDay, peek: false)
        model.expand()
        model.summarySince = summary.sinceYesterdayBoundary(now: now, lastShown: last)
    }

    /// For the debug tour and testing: open the summary now.
    func showSummaryNow() {
        let last = defaults.object(forKey: Key.lastSummary) as? Date
        model.settings.viewContext = .work
        model.expand()
        model.summarySince = summary.sinceYesterdayBoundary(now: Date(), lastShown: last)
    }

    // MARK: SSE

    private func restartStream() {
        stream.stop()
        guard useStream, !model.isDemo, let config = model.settings.hubConfigs().first else { return }
        stream.start(config: config) { [weak self] in
            self?.model.pollNow()
        }
    }

    // MARK: Settings

    var settingsSection: AnyView {
        AnyView(Phase3ScheduleSection(phase3: self))
    }

    /// Settings → Alerts: the work/personal schedule and the morning summary.
    var scheduleSection: AnyView { settingsSection }

    /// Settings → Integrations: live updates over SSE.
    var streamSection: AnyView { AnyView(Phase3StreamSection(phase3: self)) }
}

private struct Phase3ScheduleSection: View {
    @ObservedObject var phase3: Phase3Controller

    var body: some View {
        Section("Schedule") {
            Toggle(isOn: $phase3.followSchedule) {
                LabelWithDetail("Switch work / personal on a schedule", "Weekdays 7:00–18:00 show work; evenings and weekends personal. Picking a side holds until the next switch.")
            }
            Toggle(isOn: $phase3.morningSummaryEnabled) {
                LabelWithDetail("Start-of-day summary", "At 7:30 on weekdays the panel opens with everything still waiting, oldest first.")
            }
        }
    }
}

private struct Phase3StreamSection: View {
    @ObservedObject var phase3: Phase3Controller

    var body: some View {
        Section("Live updates") {
            Toggle(isOn: $phase3.useStream) {
                LabelWithDetail("Live updates from the hub", "Uses /v1/stream when the hub offers it, so new items show at once instead of at the next poll.")
            }
        }
    }
}
