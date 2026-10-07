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
    /// True when the user clicked to expand (vs. the morning summary or NEEDS_YOU_EXPAND).
    private(set) var expandedByUser = false
    /// Shown, snoozed, or hidden. `.hidden` persists across launches (settings.panelHidden).
    @Published private(set) var visibility: PanelVisibility = .shown {
        didSet {
            let hidden = visibility == .hidden
            if settings.panelHidden != hidden { settings.panelHidden = hidden }
        }
    }
    /// The panel is shown for a moment while hidden (an item without a link was clicked in
    /// the menu bar menu). Collapsing ends the peek; the panel stays hidden.
    @Published private(set) var peeking = false
    /// One brief pulse of the menu bar icon (an urgent arrival while the panel is hidden).
    @Published private(set) var menuBarPulse: UUID?
    @Published var hovering = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    /// Short name of the hub the last successful poll came from ("hub2").
    @Published private(set) var activeHub: String?
    @Published private(set) var pulse: PulseRequest?
    @Published var showRecent = false
    /// Ticks every 15 s so ages ("2h") and snooze expiry stay current.
    @Published private(set) var now = Date()
    /// Height of the expanded card list as laid out by SwiftUI.
    @Published var expandedContentHeight: CGFloat = 0
    /// Each card's bottom edge in the list (for Settings → Panel → Cards before scrolling).
    @Published var cardBottoms: [CGFloat] = []
    /// Cards whose full body and links are shown (Show more / Show details / +N). Cleared
    /// when the panel collapses.
    @Published private(set) var expandedCards: Set<String> = []
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
    /// Set by the app delegate: opens Settings at the invite section (activates the app).
    var openInviteHandler: (() -> Void)?
    /// Set by the panel controller: forget the saved position for this screen layout.
    var resetPositionHandler: (() -> Void)?

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
    private var feedHubCount = 0

    /// Set by LocalHubController when the bundled hub can't run (no Python, port taken).
    @Published var localHubIssue: String?

    init(settings: AppSettings) {
        self.settings = settings
        visibility = settings.panelHidden ? .hidden : .shown
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
    /// False shows the "set up" pill (click opens Settings): no hub at all, or only the
    /// local hub and it can't run (no Python, port taken).
    var isConfigured: Bool {
        guard feed != nil else { return false }
        return !(localHubIssue != nil && feedHubCount == 1 && settings.runLocalHub && !isDemo)
    }

    var display: PanelDisplay {
        if isExpanded { return .expanded }
        if let previewItem { return .preview(previewItem) }
        return count > 0 || otherCount > 0 ? .waiting : .idle
    }

    /// "needs Sam" / "needs you".
    var needsLabel: String { settings.needsLabel }

    /// Sizes for the chosen panel size (Settings → Panel).
    var metrics: PanelMetrics { settings.ui.metrics }
    /// Card body text size in points (Settings → Panel → Text size).
    var bodyFont: CGFloat { settings.ui.bodyFont }

    /// Glow, ring and tint for a priority (Settings → Alerts; urgent has a floor).
    func alertLook(_ priority: ItemPriority, basePulses: Int = 1) -> AlertLook {
        settings.ui.alertLook(for: priority, basePulses: basePulses)
    }

    /// Footer / tooltip status: "hub2 · 10:42", "Demo · 10:42", or the error.
    var statusLine: String {
        if !isConfigured { return localHubIssue != nil ? "Hub on this Mac can't start · click for Settings" : "No hub set up · click to set up" }
        let time = lastCheck.map { Self.timeFormatter.string(from: $0) } ?? "–"
        if let lastError { return "\(lastError) · \(time)" }
        let source = isDemo ? "demo" : (activeHub ?? "hub")
        return "\(source) · \(time)"
    }

    /// Idle at rest: a short line that keeps the pill findable, so it can be dragged or hidden.
    var idleRestLine: String {
        if !isConfigured { return localHubIssue != nil ? "Hub can't start" : "Set up Needs You" }
        if lastError != nil { return "Can't reach hub" }
        return "Nothing \(needsLabel)"
    }

    /// Idle hover: "all clear · needs Sam · hub2 · 10:42".
    var idleHoverLine: String {
        if !isConfigured { return localHubIssue != nil ? statusLine : "\(needsLabel) · click to set up" }
        if lastError != nil { return statusLine }
        return "all clear · \(needsLabel) · \(statusLine)"
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
        activeHub = nil
        demoFeed = nil
        feedHubCount = 0

        if settings.isDemo {
            var seed: [Item]?
            if let url = settings.demoFixtureURL {
                do { seed = try DemoFeed.loadFixture(at: url) } catch { lastError = "Fixture unreadable" }
            }
            let demo = DemoFeed(items: seed)
            demoFeed = demo
            feed = demo
            startInjector(demo)
        } else if case let configs = settings.hubConfigs(), !configs.isEmpty {
            // One or more hubs, polled in order with failover (FailoverFeed). The local
            // hub, when on, is first.
            feedHubCount = configs.count
            feed = FailoverFeed(hubs: configs.map {
                FailoverFeed.Hub(name: AppSettings.displayName(for: $0.baseURL), feed: HubClient(config: $0))
            })
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
            let page = try await feed.fetchPage(since: since)
            guard generation == feedGeneration else { return }
            var updated = store
            // By id, last-writer-wins on updated_at; a hub switch forces a full snapshot.
            let result = updated.merge(page.items, isFullSnapshot: page.isFullSnapshot, now: Date())
            activeHub = page.source
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
            let many = feedHubCount > 1
            lastError = (error as? LocalizedError)?.errorDescription ?? (many ? "No hub reachable" : "Hub unreachable")
            if (error as? URLError) != nil { lastError = many ? "No hub reachable" : "Hub unreachable" }
            activeHub = nil
            planner.forceFull()
        }
    }

    private func tick() {
        now = Date()
        if case .snoozed(let until) = visibility, until <= now {
            visibility = .shown
            objectWillChange.send()
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

        if visibility.isHidden(at: Date()) && !peeking {
            // Out of sight: the menu bar count updates by itself; an urgent item pulses the
            // icon once, or brings the panel back (see HiddenArrivalPolicy).
            switch HiddenArrivalPolicy.decide(
                visibility: visibility, announced: needs, urgentBreaksSnooze: settings.urgentBreaksSnooze,
                urgentShowsHiddenPanel: settings.urgentShowsHiddenPanel, now: Date()
            ) {
            case .none:
                break
            case .pulseMenuBar:
                menuBarPulse = UUID()
            case .showPanel:
                // Open decision 2: break through with a single pulse. The snooze/hide ends.
                visibility = .shown
                if let urgent = needs.first(where: { $0.priority == .urgent }), urgent.context != context {
                    settings.viewContext = urgent.context
                }
                pulse = PulseRequest(times: 1, priority: .urgent)
                menuBarPulse = UUID()
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

    /// Clicking the pill. Never makes the panel key or activates the app.
    func toggleExpanded() {
        isExpanded ? collapse() : expand(byUser: true)
    }

    func expand(byUser: Bool = false) {
        // Automatic expansions (NEEDS_YOU_EXPAND, the morning summary) never undo a hide.
        if visibility == .hidden && !byUser && !peeking { return }
        expandedByUser = byUser
        previewItem = nil
        if visibility.isHidden(at: Date()) && !peeking { visibility = .shown }
        isExpanded = true
        markVisibleSeen()
    }

    func collapse() {
        isExpanded = false
        summarySince = nil
        peeking = false
        if !expandedCards.isEmpty { expandedCards = [] }
    }

    func toggleCardExpanded(_ item: Item) {
        if expandedCards.contains(item.id) { expandedCards.remove(item.id) } else { expandedCards.insert(item.id) }
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

    /// Is the floating panel on screen? (Shown, or peeking while hidden.)
    var isPanelVisible: Bool { peeking || !visibility.isHidden(at: Date()) }

    func snoozePanel(_ option: SnoozeOption) {
        isExpanded = false
        previewItem = nil
        peeking = false
        visibility = .snoozed(until: option.until(from: Date()))
    }

    /// Can the panel be hidden right now? Not while the menu bar icon is off: the two
    /// can't both be hidden (VisibilityRules).
    var canHidePanel: Bool { VisibilityRules.canHidePanel(showMenuBarIcon: settings.showMenuBarIcon) }

    /// Hidden (and remembered across launches) until the menu bar menu, ⌃⌥Space or Settings
    /// brings it back. Refused, returning false, while the menu bar icon is off.
    @discardableResult
    func hidePanel() -> Bool {
        guard canHidePanel else { return false }
        isExpanded = false
        previewItem = nil
        peeking = false
        summarySince = nil
        visibility = .hidden
        return true
    }

    func showPanel() {
        peeking = false
        visibility = .shown
    }

    /// The global shortcut and the menu bar's Show Floating Panel: hidden/snoozed → shown,
    /// shown → hidden. Returns false if hiding was refused.
    @discardableResult
    func toggleVisibility() -> Bool {
        if visibility.isHidden(at: Date()) && !peeking { showPanel(); return true }
        return hidePanel()
    }

    /// Turn the menu bar icon on or off. Turning it off is refused (returns false) while
    /// the panel is hidden: the icon is the way back.
    @discardableResult
    func setShowMenuBarIcon(_ on: Bool) -> Bool {
        if !on && !VisibilityRules.canHideMenuBarIcon(panelHidden: visibility == .hidden) { return false }
        settings.showMenuBarIcon = on
        return true
    }

    /// A menu bar item was clicked: open its first allowed link, or show the panel
    /// expanded (peeking if it's hidden). Never activates the app.
    func activate(_ item: Item) {
        switch MenuItemAction.forItem(item) {
        case .open(let url):
            if let jump = OrcaJump.parse(url) {
                OrcaJumpRunner.run(jump)
                resolve(item)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .showPanel:
            if item.context != context { setContext(item.context) }
            showExpanded()
        }
    }

    /// Expand the panel from the menu bar. While hidden or snoozed it only peeks:
    /// collapsing puts it back out of sight.
    func showExpanded() {
        if visibility.isHidden(at: Date()) { peeking = true }
        expand(byUser: true)
    }

    func resetPosition() { resetPositionHandler?() }
    func openInvite() { (openInviteHandler ?? openSettingsHandler)?() }

    var snoozeDescription: String? {
        switch visibility {
        case .shown: return nil
        case .hidden: return "Hidden"
        case .snoozed(let until): return "Snoozed until \(Self.timeFormatter.string(from: until))"
        }
    }

    // MARK: Links

    /// Opens a link only if it passes the scheme allow-list. The Orca terminal link runs
    /// its one fixed action instead of going to NSWorkspace, and going to the terminal
    /// counts as handling the card: it's marked done.
    @discardableResult
    func open(_ string: String, from item: Item? = nil) -> Bool {
        if let jump = OrcaJump.parse(string) {
            OrcaJumpRunner.run(jump)
            if let item { resolve(item) }
            collapse()
            return true
        }
        guard let url = LinkPolicy.externalURL(string) else { return false }
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
