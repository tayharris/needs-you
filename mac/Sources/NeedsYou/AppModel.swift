import AppKit
import Foundation
import NeedsYouCore

/// A request for the ring glow to pulse `times` times.
struct PulseRequest: Equatable {
    let id = UUID()
    let times: Int
    let priority: ItemPriority
}

/// What the panel is showing; drives both the SwiftUI content and the window size.
enum PanelDisplay: Equatable {
    case idle
    case waiting
    case preview(Item)
    case expanded
}

/// App state: the item store, the poll loop, and the panel's UI state.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state

    @Published private(set) var store = ItemStore()
    @Published private(set) var isExpanded = false
    @Published private(set) var visibility: PanelVisibility = .shown
    @Published var hovering = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pulse: PulseRequest?
    @Published var showRecent = false
    /// Ticks every 15 s so ages ("2h") and snooze expiry stay current.
    @Published private(set) var now = Date()
    /// Height of the expanded card list as laid out by SwiftUI.
    @Published var expandedContentHeight: CGFloat = 0
    /// Phase 3: the new-item preview currently shown, if any.
    @Published var previewItem: Item?
    /// Phase 3: set while the start-of-day summary is open; items created after this
    /// date sit below a "since yesterday" divider. Cleared on collapse.
    @Published var summarySince: Date?

    let settings: AppSettings

    /// Set by the panel controller; the SwiftUI drag gesture forwards to it.
    var dragHandler: ((DragPhase) -> Void)?
    /// Set by the app delegate.
    var openSettingsHandler: (() -> Void)?

    // Phase 3 hooks. Phase 2 leaves them nil: new items get a plain pulse, the context
    // only changes by hand, and nothing reacts to feed restarts.
    var announcer: ((AppModel, [Item]) -> Void)?
    /// Returns the scheduled context, or nil to leave the current one.
    var contextResolver: ((Date) -> ItemContext?)?
    var onContextPicked: ((ItemContext) -> Void)?
    var onFeedRestart: (() -> Void)?
    var onTick: ((Date) -> Void)?

    private var feed: ItemFeed?
    private var demoFeed: DemoFeed?
    private var planner = PollPlanner()
    private var hasSynced = false
    private var isPolling = false
    private var feedGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?
    private var tickTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Derived

    /// The context the count and cards are for.
    var context: ItemContext { settings.viewContext }

    var count: Int { store.needsCount(in: context, now: now) }
    var otherCount: Int { store.needsCount(in: context.other, now: now) }
    var highestPriority: ItemPriority? { store.highestPriority(in: context, now: now) }
    var needsItems: [Item] { store.needs(in: context, now: now) }
    var recentItems: [Item] { store.recent(in: context, now: now) }
    var isDemo: Bool { settings.isDemo }
    var isConfigured: Bool { feed != nil }

    var display: PanelDisplay {
        if isExpanded { return .expanded }
        if let previewItem { return .preview(previewItem) }
        return count > 0 || otherCount > 0 ? .waiting : .idle
    }

    var statusLine: String {
        if !isConfigured { return "Hub not set up · open Settings" }
        let time = lastCheck.map { Self.timeFormatter.string(from: $0) } ?? "–"
        if let lastError { return "\(lastError) · \(time)" }
        return "Checked \(time)"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    // MARK: Lifecycle

    func start() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        restartFeed()
        if settings.startExpanded { expand() }
    }

    /// (Re)build the feed from settings and restart polling. Called on launch and after
    /// Settings change.
    func restartFeed() {
        pollTask?.cancel()
        injectTask?.cancel()
        feedGeneration += 1
        store = ItemStore()
        planner = PollPlanner()
        hasSynced = false
        lastError = nil
        lastCheck = nil
        demoFeed = nil

        if settings.isDemo {
            var seed: [Item]?
            if let url = settings.demoFixtureURL {
                do { seed = try DemoFeed.loadFixture(at: url) } catch { lastError = "Fixture unreadable" }
            }
            let demo = DemoFeed(items: seed)
            demoFeed = demo
            feed = demo
            startInjector(demo)
        } else if let config = settings.hubConfig() {
            feed = HubClient(config: config)
        } else {
            feed = nil
        }

        let generation = feedGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.feedGeneration == generation else { return }
                await self.pollOnce()
                let seconds = self.settings.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
        onFeedRestart?()
    }

    private func startInjector(_ demo: DemoFeed) {
        let interval = settings.demoInjectInterval
        guard interval > 0 else { return }
        injectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await demo.injectNext()
                await self?.pollOnce()
            }
        }
    }

    /// Poll now (wake from sleep, the refresh button).
    func pollNow(full: Bool = false) {
        if full { planner.forceFull() }
        Task { await pollOnce() }
    }

    func handleWake() {
        planner.forceFull()
        tick()
        pollNow()
    }

    private func pollOnce() async {
        guard !isPolling else { return }
        guard let feed else {
            lastError = nil
            return
        }
        isPolling = true
        defer { isPolling = false }
        let generation = feedGeneration
        let since = planner.nextSince(latest: store.latestUpdatedAt)
        do {
            let items = try await feed.fetchOpen(since: since)
            guard generation == feedGeneration else { return }
            var updated = store
            let result = updated.merge(items, isFullSnapshot: since == nil, now: Date())
            store = updated
            lastCheck = Date()
            lastError = nil
            if hasSynced {
                handleAnnouncements(result.announce)
            }
            hasSynced = true
            if isExpanded { markVisibleSeen() }
        } catch {
            guard generation == feedGeneration else { return }
            lastError = (error as? LocalizedError)?.errorDescription ?? "Hub unreachable"
            if (error as? URLError) != nil { lastError = "Hub unreachable" }
            planner.forceFull()
        }
    }

    private func tick() {
        now = Date()
        if case .snoozed(let until) = visibility, until <= now {
            visibility = .shown
        }
        if let resolved = contextResolver?(now), resolved != settings.viewContext {
            settings.viewContext = resolved
        }
        onTick?(now)
        var pruned = store
        if !pruned.prune(now: now).isEmpty || pruned.snoozedCardCount != store.snoozedCardCount {
            store = pruned
        }
    }

    // MARK: Announcements

    private func handleAnnouncements(_ items: [Item]) {
        let needs = items.filter { $0.kind == .needs && !store.isCardSnoozed($0.id, now: Date()) }
        guard !needs.isEmpty else { return }

        if visibility.isHidden(at: Date()) {
            if SnoozeBreakthrough.shouldBreakThrough(
                visibility: visibility, announced: needs,
                urgentBreaksThrough: settings.urgentBreaksSnooze, now: Date()
            ) {
                // Open decision 2: break through with a single pulse. The snooze ends.
                visibility = .shown
                if let urgent = needs.first(where: { $0.priority == .urgent }), urgent.context != context {
                    settings.viewContext = urgent.context
                }
                pulse = PulseRequest(times: 1, priority: .urgent)
            }
            return
        }

        let inContext = needs.filter { $0.context == context }
        guard !inContext.isEmpty, !isExpanded else { return }
        if let announcer {
            announcer(self, inContext)
        } else {
            let urgent = inContext.contains { $0.priority == .urgent }
            pulse = PulseRequest(times: urgent ? 2 : 1, priority: inContext.map(\.priority).min() ?? .normal)
        }
    }

    func requestPulse(times: Int, priority: ItemPriority) {
        pulse = PulseRequest(times: times, priority: priority)
    }

    // MARK: Expand / collapse

    func toggleExpanded() {
        isExpanded ? collapse() : expand()
    }

    func expand() {
        previewItem = nil
        if visibility.isHidden(at: Date()) { visibility = .shown }
        isExpanded = true
        markVisibleSeen()
    }

    func collapse() {
        isExpanded = false
        summarySince = nil
    }

    func setContext(_ context: ItemContext) {
        settings.viewContext = context
        onContextPicked?(context)
        objectWillChange.send()
    }

    private func markVisibleSeen() {
        guard let feed else { return }
        let date = Date()
        for item in needsItems where item.seenAt == nil {
            store.markSeen(id: item.id, at: date)
            let id = item.id
            Task { try? await feed.patch(id: id, ItemPatch(seenAt: date)) }
        }
    }

    // MARK: Item actions

    func resolve(_ item: Item) { close(item, status: .resolved) }
    func dismiss(_ item: Item) { close(item, status: .dismissed) }

    private func close(_ item: Item, status: ItemStatus) {
        guard let feed, let removed = store.closeLocally(id: item.id) else { return }
        let generation = feedGeneration
        Task {
            do {
                try await feed.patch(id: item.id, ItemPatch(status: status))
            } catch {
                guard generation == feedGeneration else { return }
                store.restore(removed)
                lastError = "Couldn't update item"
            }
        }
    }

    func snoozeCard(_ item: Item, _ option: SnoozeOption) {
        store.snoozeCard(id: item.id, until: option.until(from: Date()))
    }

    // MARK: Panel visibility

    func snoozePanel(_ option: SnoozeOption) {
        isExpanded = false
        previewItem = nil
        visibility = .snoozed(until: option.until(from: Date()))
    }

    /// Hidden until the hotkey (or Settings) brings it back.
    func hidePanel() {
        isExpanded = false
        previewItem = nil
        visibility = .hidden
    }

    func showPanel() {
        visibility = .shown
    }

    /// The global shortcut: hidden/snoozed → shown, shown → hidden.
    func toggleVisibility() {
        if visibility.isHidden(at: Date()) { showPanel() } else { hidePanel() }
    }

    var snoozeDescription: String? {
        switch visibility {
        case .shown: return nil
        case .hidden: return "Hidden"
        case .snoozed(let until): return "Snoozed until \(Self.timeFormatter.string(from: until))"
        }
    }

    // MARK: Links

    /// Opens a link only if it passes the scheme allow-list.
    @discardableResult
    func open(_ string: String) -> Bool {
        guard let url = LinkPolicy.openableURL(string) else { return false }
        NSWorkspace.shared.open(url)
        collapse()
        return true
    }

    @discardableResult
    func open(_ url: URL) -> Bool { open(url.absoluteString) }

    func openSettings() { openSettingsHandler?() }
}

enum DragPhase {
    case changed
    case ended
}
