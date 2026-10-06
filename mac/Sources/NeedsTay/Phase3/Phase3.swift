import AppKit
import NeedsTayCore
import SwiftUI

// Phase 3 (PLAN.md build order): the springy new-item preview, the work/personal
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
    /// holds ~4 s, then springs back. Urgent pulses twice. (The panel controller animates
    /// the size change with an overshoot curve, or a fade under Reduce Motion.)
    private func announce(_ items: [Item]) {
        guard let top = items.min(by: { $0.priority < $1.priority }) else { return }
        let urgent = items.contains { $0.priority == .urgent }
        model.previewItem = top
        model.requestPulse(times: urgent ? 2 : 1, priority: top.priority)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.model.previewItem?.id == top.id else { return }
            self.model.previewItem = nil
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
        let last = defaults.object(forKey: Key.lastSummary) as? Date
        guard summary.isDue(now: now, lastShown: last) else { return }
        // Wait for a successful poll so the summary isn't empty for the wrong reason.
        // (A snooze left over from last night doesn't block it: expanding shows the panel.)
        guard model.lastCheck != nil else { return }
        defaults.set(now, forKey: Key.lastSummary)
        model.settings.viewContext = .work
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
        guard useStream, !model.isDemo, let config = model.settings.hubConfig() else { return }
        stream.start(config: config) { [weak self] in
            self?.model.pollNow()
        }
    }

    // MARK: Settings

    var settingsSection: AnyView {
        AnyView(Phase3SettingsSection(phase3: self))
    }
}

private struct Phase3SettingsSection: View {
    @ObservedObject var phase3: Phase3Controller

    var body: some View {
        Section("Schedule") {
            Toggle("Switch work / personal on a schedule (weekdays 7:00–18:00 = work)", isOn: $phase3.followSchedule)
            Toggle("Start-of-day summary at 7:30 on weekdays", isOn: $phase3.morningSummaryEnabled)
            Toggle("Live updates from /v1/stream when the hub offers it", isOn: $phase3.useStream)
        }
    }
}
