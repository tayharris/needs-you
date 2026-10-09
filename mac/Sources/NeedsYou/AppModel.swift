import AppKit
import Combine
import Foundation
import NeedsYouCore

/// A request for the ring glow to pulse `times` times. `ambient` is the delivery tiers'
/// single soft brighten (AlertStyle.ambientLook).
struct PulseRequest: Equatable {
    let id = UUID()
    let times: Int
    let priority: ItemPriority
    var ambient = false
}

/// What the panel is showing; drives both the SwiftUI content and the window size.
enum PanelDisplay: Equatable {
    case idle
    case waiting
    case preview(Item)
    /// "3 waited while you were focused": Later delivered as one quiet peek.
    case digest(LaterDigest)
    case expanded

    /// The arrival peeks (they spring out on the display you're working on).
    var isPeek: Bool {
        switch self {
        case .preview, .digest: return true
        default: return false
        }
    }
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
    /// The urgent edge glow on the work display (Settings → Alerts, off by default).
    @Published private(set) var edgeGlowRequest: UUID?
    @Published var hovering = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    /// Short name of the hub the last successful poll came from ("hub2").
    @Published private(set) var activeHub: String?
    @Published private(set) var pulse: PulseRequest? {
        didSet {
            // The repeat reminder counts from the last urgent arrival or reminder.
            if let pulse, pulse.priority == .urgent, !pulse.ambient { lastUrgentAlertAt = Date() }
        }
    }
    /// When urgent last played its arrival (UrgentReminder).
    private var lastUrgentAlertAt: Date?
    @Published var showRecent = false
    /// The Orca section in the open panel is open (it starts collapsed).
    @Published var showOrca = false
    /// Orca's worktrees (OrcaWorktrees.visible), refreshed while the panel is open; empty
    /// without Orca or with Settings → Panel → Orca off. Local only: never counted.
    @Published private(set) var orcaRows: [OrcaWorktreeRow] = []
    /// Every row Orca returned (for the header's "of N").
    @Published private(set) var orcaTotal: [OrcaWorktreeRow] = []
    private var orcaFetchedAt: Date?
    /// The hub's status records (GET /v1/status), shown as usage meters (UsageMeters).
    /// Never counted, animated or announced; empty from a hub that predates them.
    @Published private(set) var statuses: [StatusRecord] = []
    private var statusETag: String?
    private var orcaFetching = false
    /// The Later section in the expanded panel is open.
    @Published var showLater = false
    /// The quiet peek that delivers Later, if one is showing.
    @Published private(set) var digest: LaterDigest?
    /// Ticks every 15 s so ages ("2h") and snooze expiry stay current.
    @Published private(set) var now = Date()
    /// Height of the expanded card list as laid out by SwiftUI.
    @Published var expandedContentHeight: CGFloat = 0
    /// Each card's bottom edge in the list (for Settings → Panel → Cards before scrolling).
    @Published var cardBottoms: [CGFloat] = []
    /// The resize grip is on the open panel's bottom edge; false puts it on the top edge
    /// (the panel sits on a bottom corner and grows up). Set by the panel controller.
    @Published var listGripAtBottom = true
    /// Cards whose full body and links are shown (Show more / Show details / +N). Cleared
    /// when the panel collapses.
    @Published private(set) var expandedCards: Set<String> = []
    /// Steps ticked on this Mac (local only, never sent to the hub; kept while the item is).
    @Published private(set) var stepTicks = StepTicks()
    /// Options clicked on an answerable question's card (multi-select or several questions),
    /// before Send. Local; dropped once the answer is sent, the item leaves or a re-post
    /// changes it.
    @Published private(set) var answerSelections: [String: AnswerSelection] = [:]
    /// Where each card's answer stands (sending, sent, failed and why).
    @Published private(set) var answerStates: [String: AnswerState] = [:]
    /// The item each selection and state was made for (AnswerPolicy.stamp).
    private var answerStamps: [String: String] = [:]
    /// The token role for each hub of the current feed (nil: unknown), set when it's built.
    private var feedRoles: [HubRole?] = []
    /// Every hub refused this Mac's typed words (`forbidden`) since the feed was built: the
    /// cards stop offering Other… until the hubs change in Settings.
    @Published private(set) var typedAnswersRefused = false
    /// May the cards offer Other… and Answer…? Not when every hub's token is known not to be
    /// an owner one (AnswerPolicy.mayType), or the hubs refused typed words already.
    var mayTypeAnswers: Bool { !typedAnswersRefused && AnswerPolicy.mayType(roles: feedRoles) }
    /// The footer's update line ("Update available: 0.3.0 → 0.3.1"), set by UpdateController.
    /// Footer text only: not an item, never counted, never animates the pill or notifies.
    @Published var updateFooter: UpdateFooter?
    /// The last copy from a card (a command chip or the "…" menu), shown as "Copied" on the
    /// card for a moment. Cleared after 1.5 s.
    @Published private(set) var copied: CardCopyNotice?
    private var copiedTask: Task<Void, Never>?
    /// The card the open panel scrolls to (ExpandFocus); the list clears it once scrolled.
    @Published var scrollTarget: String?
    /// The card drawn highlighted for a moment after the panel opened at it.
    @Published private(set) var highlightedItem: String?
    private var highlightTask: Task<Void, Never>?
    /// Phase 3: the new-item preview currently shown, if any.
    @Published var previewItem: Item?
    /// Phase 3: set while the start-of-day summary is open; items created after this
    /// date sit below a "since yesterday" divider. Cleared on collapse.
    @Published var summarySince: Date?

    let settings: AppSettings

    /// Set by the panel controller; the SwiftUI drag gesture forwards to it.
    var dragHandler: ((DragPhase) -> Void)?
    /// Set by the panel controller; the expanded panel's resize grip forwards to it.
    var resizeHandler: ((DragPhase) -> Void)?
    /// Set by the app delegate.
    var openSettingsHandler: (() -> Void)?
    /// Set by AppDelegate: opens the answer window for an item's question (index). Only
    /// `openAnswerWindow` calls it, from an explicit click on "Other…" or "Answer…".
    var openAnswerWindowHandler: ((Item, Int) -> Void)?
    /// Set by the app delegate: opens Settings at the invite section (activates the app).
    var openInviteHandler: (() -> Void)?
    /// Set by the app delegate: opens Settings at a page (the menu's Move to Applications…).
    var openSettingsPageHandler: ((SettingsTab) -> Void)?
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
    /// The answering hub's `server_time` from the last poll: the next `since`.
    private var pollCursor: Date?
    /// Its `next` (hubs after 0.1.2): sent with that `since`, so paging always moves on.
    private var pollNext: String?
    private var hasSynced = false
    /// The feed generation a poll is running for, if any.
    private var pollingGeneration: Int?
    /// A poll was asked for while one ran.
    private var pollAgain = false
    private var feedGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var injectTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var feedHubCount = 0
    private var digestTask: Task<Void, Never>?
    /// The panel was opened by the launch (LaunchOpen), not by the person: a click
    /// elsewhere closes it whatever Collapse when clicking elsewhere says, and it closes by
    /// itself (launchOpenTask) once the pointer has been away for a while.
    private(set) var openedAtLaunch = false
    private var launchOpenTask: Task<Void, Never>?
    /// Holds a sender that interrupts more than 6 times an hour to ambient.
    private var noisyGuard = NoisySenderGuard()

    /// Set by LocalHubController when the bundled hub can't run (no Python, port taken).
    @Published var localHubIssue: String?
    /// Set by LocalHubController: the bundled hub started but hasn't answered in time
    /// (`localHubIssue` says so); the panel offers Restart.
    @Published var localHubNotAnswering = false
    /// Set by LocalHubController: the URL other machines use while the hub on this Mac runs.
    @Published var localHubPublicURL: String? {
        didSet { if localHubPublicURL != oldValue { recordSetupProgress() } }
    }

    // MARK: Setup tips (SetupChecklist): local cards, never sent to a hub, never counted.

    /// Set by the app delegate: runs a setup card's button (Settings, the agent prompt).
    var setupActionHandler: ((SetupAction, SetupTip) -> Void)?
    /// Set by the app delegate: asks the owner hub for its token list once, so a hub that
    /// already has senders (but no open items) doesn't get the "connect" tip.
    var setupProbeHandler: (() -> Void)?
    private var setupProbed = false
    /// Something arrived from a hub (or the hub lists another token) since launch.
    @Published private(set) var senderObserved = false
    @Published private(set) var claudeCodeInstalled = false
    @Published private(set) var claudeHooksInstalled = false
    /// A line under a setup card after its button ran ("Agent prompt copied…"). Never holds
    /// the invite link or code.
    @Published var setupNotice: SetupNotice?
    private let localHost: String
    /// The panel's colours: Settings → Appearance's theme and accent for macOS's current
    /// light or dark appearance. Also copied to `Theme.palette`, which the views read.
    @Published private(set) var palette = PanelTheme.standardPalette
    private var appearanceObservers = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        localHost = LocalHubController.localHostName()
        visibility = settings.panelHidden ? .hidden : .shown
        refreshPalette()
        settings.$ui
            .map { [$0.theme.rawValue, $0.accent.storageString] }
            .removeDuplicates()
            .sink { [weak self] _ in
                // $ui publishes before the new value is stored.
                Task { @MainActor in self?.refreshPalette() }
            }
            .store(in: &appearanceObservers)
        NSApplication.shared.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshPalette() } }
            .store(in: &appearanceObservers)
        // A rule's "Treat as urgent"/"Treat as low" recolours and re-sorts the cards at once.
        settings.$bypassRules
            .removeDuplicates()
            .sink { [weak self] rules in Task { @MainActor in self?.applyRules(rules) } }
            .store(in: &appearanceObservers)
    }

    /// Puts the bypass rules' priority (RuleBook.effectivePriority) on every stored item.
    private func applyRules(_ rules: RuleBook) {
        var next = store
        if next.applyRules(rules) { store = next }
    }

    /// The card menu's "Alerts for This Session" edits (AlertRuleMenu). Saved like a change in
    /// Settings → Alerts; the observer above re-applies them to the cards.
    func setBypassRules(_ rules: RuleBook) {
        guard rules != settings.bypassRules else { return }
        settings.bypassRules = rules
    }

    /// Recomputes the palette from the settings and macOS's appearance.
    func refreshPalette() {
        Theme.systemIsDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next = settings.ui.palette(systemIsDark: Theme.systemIsDark)
        Theme.palette = next
        if next != palette { palette = next }
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
    /// Snapshot runs (NEEDS_YOU_SNAPSHOT_DIR, a debug aid) draw demo items the way a real
    /// inbox shows them, for screenshots: no DEMO badge, and "this Mac" as the source.
    let showcase = AppSettings.snapshotDirectory != nil
    /// The DEMO badge in the open panel's footer.
    var showsDemoBadge: Bool { isDemo && !showcase }
    /// False shows the "set up" pill (click opens Settings): no hub at all, or only the
    /// local hub and it can't run (no Python, port taken).
    var isConfigured: Bool {
        guard feed != nil else { return false }
        return !(localHubIssue != nil && feedHubCount == 1 && settings.runLocalHub && !isDemo)
    }

    var display: PanelDisplay {
        if isExpanded { return .expanded }
        if let previewItem { return .preview(previewItem) }
        if let digest { return .digest(digest) }
        return count > 0 || otherCount > 0 || laterCount > 0 ? .waiting : .idle
    }

    // MARK: Setup tips

    /// What the app knows about its own setup, for SetupChecklist.
    var setupState: SetupState {
        var s = SetupState()
        s.enabled = settings.showSetupTips
        s.isDemo = isDemo
        s.hasHub = feedHubCount > 0
        s.hubReachable = lastCheck != nil
        if !settings.runLocalHub || isDemo {
            s.localHub = .off
        } else if localHubNotAnswering {
            s.localHub = .notAnswering
        } else if let url = localHubPublicURL {
            s.localHub = .running(loopbackOnly: SetupChecklist.isLoopbackOnly(publicURL: url))
        } else {
            s.localHub = .notReady
        }
        s.loopbackForced = LocalHub.loopbackOnly
        s.canInvite = settings.hasOwnerHub
        s.senderSeen = senderObserved || settings.setupTipsDone.contains(SetupTip.connectSender.rawValue)
        s.hasOtherMachines = !settings.hubURLs.isEmpty
            || SetupChecklist.hasOtherHosts(Array(store.items.values), localHost: localHost)
        s.claudeCodeInstalled = claudeCodeInstalled
        s.claudeHooksInstalled = claudeHooksInstalled
        s.closed = settings.setupTipsDone.union(settings.setupTipsDismissed)
        s.context = context
        s.now = now
        return s
    }

    /// The setup cards to show, in order. Not in the store, the count or the menu bar.
    var setupCards: [SetupCard] { SetupChecklist.cards(state: setupState) }

    /// The "set up" pill's click: straight to Settings, unless a setup card explains what
    /// to do (then it opens the panel, and the card's button opens Settings).
    var pillOpensSettings: Bool { !isConfigured && setupCards.isEmpty }

    func setupCard(for item: Item) -> SetupCard? {
        guard let tip = SetupChecklist.tip(forItemID: item.id) else { return nil }
        return setupCards.first { $0.tip == tip }
    }

    /// Tips whose condition is met are done for good. Also asks the owner hub once for its
    /// tokens while the "connect" tip is up.
    func recordSetupProgress() {
        let state = setupState
        let done = Set(SetupChecklist.satisfied(state).map { $0.rawValue })
        if !done.isSubset(of: settings.setupTipsDone) {
            settings.setupTipsDone.formUnion(done)
        }
        if !setupProbed, SetupChecklist.pending(state).contains(.connectSender) {
            setupProbed = true
            setupProbeHandler?()
        }
    }

    /// The owner hub's token list (Settings → Machines, or the one-off probe): any token
    /// besides this Mac's own means something has connected.
    func noteAccessTokens(_ tokens: [TokenSummary]) {
        guard !isDemo, !senderObserved, tokens.contains(where: { !$0.current }) else { return }
        senderObserved = true
        recordSetupProgress()
    }

    // MARK: Orca strip

    /// Re-reads Orca's worktrees (this Mac and its paired environments) at most every
    /// OrcaWorktrees.refreshInterval while the panel is open. Runs `orca` off the main
    /// thread; nothing it returns is ever a link or an action.
    func refreshOrca(force: Bool = false) {
        guard settings.showOrcaWorktrees, !isDemo else {
            if !orcaRows.isEmpty { orcaRows = []; orcaTotal = [] }
            return
        }
        guard !orcaFetching else { return }
        if !force, let at = orcaFetchedAt, Date().timeIntervalSince(at) < OrcaWorktrees.refreshInterval { return }
        orcaFetching = true
        orcaFetchedAt = Date()
        OrcaStripRunner.fetch { [weak self] rows in
            guard let self else { return }
            self.orcaFetching = false
            guard self.settings.showOrcaWorktrees else { return }
            let all = rows ?? []
            if all != self.orcaTotal {
                self.orcaTotal = all
                self.orcaRows = OrcaWorktrees.visible(all)
            }
        }
    }

    /// Re-reads ~/.claude (on launch, expand and wake). Small and read-only.
    func refreshSetupFacts() {
        guard settings.showSetupTips, !isDemo else { return }
        let facts = SetupChecklist.claudeCode(home: FileManager.default.homeDirectoryForCurrentUser)
        if facts.installed != claudeCodeInstalled { claudeCodeInstalled = facts.installed }
        if facts.hooks != claudeHooksInstalled { claudeHooksInstalled = facts.hooks }
        recordSetupProgress()
    }

    /// A setup card's button. Opening Settings activates the app, so this only ever runs
    /// from a click on the card.
    func runSetup(_ action: SetupAction, for tip: SetupTip) {
        setupNotice = nil
        setupActionHandler?(action, tip)
    }

    /// Dismiss: the tip doesn't come back (Settings → Panel → Show dismissed tips again).
    func dismissSetupTip(_ tip: SetupTip) {
        settings.setupTipsDismissed.insert(tip.rawValue)
        if setupNotice?.tip == tip { setupNotice = nil }
    }

    // MARK: Delivery tiers (docs/roadmap/focus-tiers.md)

    /// The focus level in force right now.
    var focusLevel: FocusLevel { settings.focus.effectiveLevel(at: Date()) }
    var isFocused: Bool { focusLevel != .off }
    /// The focus in force came from a needsyou://focus link (the pill shows a link badge).
    var focusSetByLink: Bool { isFocused && settings.focus.source == .link }
    /// "Urgent only until 14:30", or nil.
    var focusSummary: String? { settings.focus.summary(at: Date()) { Self.timeFormatter.string(from: $0) } }
    /// Items held under Later in this context (not counted; the faint "+N").
    var laterItems: [Item] { store.laterItems(in: context, now: now) }
    var laterCount: Int { store.laterCount(in: context, now: now) }
    /// Senders the noisy-sender guard is holding to ambient this hour ("devbox · cron").
    var quietedSenders: [String] { noisyGuard.heldSenders(now: now).map(NoisySenderGuard.displayName) }

    func deliveryState(at date: Date) -> DeliveryState {
        DeliveryState(context: context, visibility: visibility, focus: settings.focus.effectiveLevel(at: date),
                      focusSource: settings.focus.source, defaults: settings.delivery, rules: settings.bypassRules,
                      urgentBreaksSnooze: settings.urgentBreaksSnooze,
                      urgentShowsHiddenPanel: settings.urgentShowsHiddenPanel, now: date)
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
        if !isConfigured && localHubNotAnswering { return "Hub on this Mac isn't answering" }
        if !isConfigured { return localHubIssue != nil ? "Hub on this Mac can't start · click for Settings" : "No hub set up · click to set up" }
        let time = lastCheck.map { Self.timeFormatter.string(from: $0) } ?? "–"
        if let lastError { return "\(lastError) · \(time)" }
        let source = showsDemoBadge ? "demo" : (activeHub ?? (isDemo ? LocalHub.displayName : "hub"))
        return "\(source) · \(time)"
    }

    /// Idle at rest: a short line that keeps the pill findable, so it can be dragged or hidden.
    var idleRestLine: String {
        if !isConfigured && localHubNotAnswering { return "Hub not answering" }
        if !isConfigured { return localHubIssue != nil ? "Hub can't start" : "Set up Needs You" }
        if lastError != nil { return "Can't reach hub" }
        let tips = setupCards.count
        if tips > 0 { return "Nothing \(needsLabel) · \(tips) setup tip\(tips == 1 ? "" : "s")" }
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
        refreshSetupFacts()
        if settings.startExpanded { expand() }
    }

    /// (Re)build the feed from settings and restart polling. Called on launch and after
    /// Settings change.
    func restartFeed() {
        pollTask?.cancel()
        injectTask?.cancel()
        feedGeneration += 1
        // The items start over (the new hub's first poll is a full one), but card snoozes,
        // Later holds and local closes carry over: the same items come back from a hub
        // that replicates with the old one.
        store = store.carryingLocalState()
        planner = PollPlanner()
        pollCursor = nil
        pollNext = nil
        hasSynced = false
        lastError = nil
        lastCheck = nil
        activeHub = nil
        demoFeed = nil
        feedHubCount = 0
        feedRoles = []
        typedAnswersRefused = false
        statuses = []
        statusETag = nil

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
            feedRoles = configs.map { settings.role(for: $0.baseURL) }
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

    /// The format tour: senders re-posting these items under their keys (demo mode only).
    func applyDemoRepost(_ items: [Item]) async {
        guard let demoFeed else { return }
        await demoFeed.upsert(items)
        pollNow()
    }

    /// The snapshot tour: the demo's usage records become exactly these.
    func applyDemoStatuses(_ records: [StatusRecord]) async {
        guard let demoFeed else { return }
        await demoFeed.replaceStatuses(with: records)
        pollNow()
    }

    /// The format tour: the demo's open items become exactly these.
    func applyDemoOpenSet(_ items: [Item]) async {
        guard let demoFeed else { return }
        await demoFeed.replaceOpen(with: items)
        pollNow(full: true)
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
        refreshSetupFacts()
        planner.forceFull()
        tick()
        pollNow()
    }

    private func pollOnce() async {
        // One poll at a time per feed. A request that comes in meanwhile (a live-update
        // nudge, Refresh, wake) runs once more right after, so its change isn't left for
        // the next interval; a poll of a replaced feed doesn't hold up the new one.
        guard pollingGeneration != feedGeneration else {
            pollAgain = true
            return
        }
        let generation = feedGeneration
        pollingGeneration = generation
        defer { if pollingGeneration == generation { pollingGeneration = nil } }
        repeat {
            pollAgain = false
            await pollFeed(generation: generation)
        } while pollAgain && generation == feedGeneration
    }

    private func pollFeed(generation: Int) async {
        guard let feed else {
            lastError = nil
            return
        }
        // The hub's own cursor (docs/API.md); feeds without one fall back to the newest updated_at.
        let since = planner.nextSince(latest: pollCursor ?? store.latestUpdatedAt)
        do {
            let page = try await feed.fetchPage(since: since, cursor: since == nil ? nil : pollNext)
            guard generation == feedGeneration else { return }
            var updated = store
            // By id, last-writer-wins on updated_at; a hub switch forces a full snapshot.
            // With the bypass rules' priority on each item, as the store keeps them (applyRules).
            let rules = settings.bypassRules
            let result = updated.merge(page.items.map { rules.applied(to: $0) }, isFullSnapshot: page.isFullSnapshot, now: Date())
            activeHub = page.source
            pollCursor = page.cursor
            pollNext = page.next
            store = updated
            endPreview(ifGone: result.removed)
            if !stepTicks.isEmpty {
                var ticks = stepTicks
                ticks.retain(itemIDs: Set(updated.items.keys))
                if ticks != stepTicks { stepTicks = ticks }
            }
            // Gone, or re-posted with a new question: the old picks and "Sent" don't apply.
            let stale = AnswerPolicy.staleAnswerIDs(stamps: answerStamps, items: updated.items,
                                                    kept: Set(answerSelections.keys).union(answerStates.keys))
            if !stale.isEmpty {
                for id in stale { answerStamps[id] = nil }
                if answerSelections.keys.contains(where: stale.contains) {
                    answerSelections = answerSelections.filter { !stale.contains($0.key) }
                }
                if answerStates.keys.contains(where: stale.contains) {
                    answerStates = answerStates.filter { !stale.contains($0.key) }
                }
            }
            lastCheck = Date()
            lastError = nil
            if hasSynced {
                handleAnnouncements(result.announce)
            }
            hasSynced = true
            if !isDemo, !senderObserved, !updated.items.isEmpty { senderObserved = true }
            recordSetupProgress()
            if isExpanded { markVisibleSeen() }
            refreshStatusesInBackground(generation: generation)
        } catch {
            guard generation == feedGeneration else { return }
            let many = feedHubCount > 1
            lastError = (error as? LocalizedError)?.errorDescription ?? (many ? "No hub reachable" : "Hub unreachable")
            if (error as? URLError) != nil { lastError = many ? "No hub reachable" : "Hub unreachable" }
            activeHub = nil
            planner.forceFull()
        }
    }

    private var statusRefreshing = false

    /// The status fetch runs on its own (one at a time): a hub slow to answer it never holds
    /// up the next items poll.
    private func refreshStatusesInBackground(generation: Int) {
        guard !statusRefreshing else { return }
        statusRefreshing = true
        Task { [weak self] in
            await self?.refreshStatuses(generation: generation)
            self?.statusRefreshing = false
        }
    }

    /// After a good items poll: the same hub's statuses, when Settings → Usage shows them.
    /// A failure keeps the last ones (they carry their own expiry) and never touches items.
    private func refreshStatuses(generation: Int) async {
        guard settings.usage.isShown, let statusFeed = feed as? StatusFeed else {
            if !statuses.isEmpty { statuses = [] }
            statusETag = nil
            return
        }
        guard let fetch = try? await statusFeed.fetchStatuses(etag: statusETag),
              generation == feedGeneration else { return }
        if case let .fresh(records, etag) = fetch {
            statusETag = etag
            if records != statuses { statuses = records }
        }
    }

    private func tick() {
        now = Date()
        if isExpanded { refreshOrca() }
        if case .snoozed(let until) = visibility, until <= now {
            visibility = .shown
            objectWillChange.send()
            releaseLater(.snoozeEnded)
        }
        if settings.focus.level != .off && !settings.focus.isActive(at: now) {
            settings.focus = .off
            releaseLater(.focusEnded)
        }
        if let resolved = contextResolver?(now), resolved != settings.viewContext {
            settings.viewContext = resolved
            // The schedule switching to work is the start of the day: Later is delivered.
            if resolved == .work { releaseLater(.startOfDay) }
        }
        onTick?(now)
        remindAboutUrgent(at: now)
        var pruned = store
        let expired = pruned.prune(now: now)
        if !expired.isEmpty || pruned.snoozedCardCount != store.snoozedCardCount {
            store = pruned
            endPreview(ifGone: expired)
        }
    }

    /// The preview's item left the open set (its sender resolved it, it was closed here, or
    /// it expired): take the preview down rather than keep announcing it.
    private func endPreview(ifGone removed: [Item]) {
        guard let shown = previewItem, removed.contains(where: { $0.id == shown.id }) else { return }
        previewItem = nil
    }

    // MARK: Announcements

    /// Each new or visibly changed item gets a delivery tier (DeliveryPolicy): interrupt is
    /// the spring-out preview and pulse, ambient one soft brighten, later is held under
    /// Later (not counted) until the focus or snooze ends. Never activates the app.
    private func handleAnnouncements(_ items: [Item]) {
        let date = Date()
        let arrivals = items.filter { !store.isCardSnoozed($0.id, now: date) }
        guard !arrivals.isEmpty else { return }

        let state = deliveryState(at: date)
        var updated = store
        var decided: [(item: Item, decision: DeliveryDecision)] = []
        for item in arrivals {
            var decision = DeliveryPolicy.decide(item, state: state)
            if decision.tier == .interrupt && !noisyGuard.admit(item, now: date) {
                decision = DeliveryDecision(tier: .ambient, reason: .noisySender)
            }
            if decision.holdsForLater {
                updated.holdForLater(id: item.id, at: date)
            } else if decision.tier != .later {
                updated.unhold(id: item.id)
            }
            decided.append((item: item, decision: decision))
        }
        store = updated
        let interrupts = decided.filter { $0.decision.tier == .interrupt }.map(\.item)
        let urgentInterrupt = interrupts.contains { $0.kind == .needs && $0.priority == .urgent }
        let glow = urgentInterrupt && settings.edgeGlow == .urgent

        if visibility.isHidden(at: date) && !peeking {
            // Out of sight: the menu bar count updates by itself; an urgent item pulses the
            // icon once, or brings the panel back (the tier table's snoozed/hidden column).
            switch DeliveryPolicy.hiddenArrival(decided) {
            case .none:
                break
            case .pulseMenuBar:
                menuBarPulse = UUID()
            case .showPanel:
                // Open decision 2: break through with a single pulse. The snooze/hide ends.
                let wasSnoozed = visibility != .hidden
                visibility = .shown
                if let top = interrupts.min(by: { $0.priority < $1.priority }), top.context != context {
                    settings.viewContext = top.context
                }
                pulse = PulseRequest(times: 1, priority: interrupts.map(\.priority).min() ?? .urgent)
                menuBarPulse = UUID()
                if glow { edgeGlowRequest = UUID() }
                if wasSnoozed { releaseLater(.snoozeEnded, peek: false) }
            }
            return
        }

        if glow { edgeGlowRequest = UUID() }
        guard !isExpanded else { return }
        if !interrupts.isEmpty {
            digest = nil
            if let announcer {
                announcer(self, interrupts)
            } else {
                let urgent = interrupts.contains { $0.priority == .urgent }
                pulse = PulseRequest(times: urgent ? 2 : 1, priority: interrupts.map(\.priority).min() ?? .normal)
            }
            return
        }
        let ambient = decided.filter { $0.decision.tier == .ambient }.map(\.item)
        if let top = ambient.map(\.priority).min() {
            pulse = PulseRequest(times: 1, priority: top, ambient: true)
        }
    }

    /// Deliver Later: everything held joins the list and the count, with one quiet peek
    /// ("3 waited while you were focused") when the panel is in view. Waits while a focus
    /// or snooze is still on, unless it's by hand (Show now).
    func releaseLater(_ reason: LaterRelease, peek: Bool = true) {
        let date = Date()
        if reason != .byHand {
            if settings.focus.isActive(at: date) { return }
            if case .snoozed(let until) = visibility, until > date { return }
        }
        var updated = store
        let released = updated.releaseLater(now: date)
        guard !released.isEmpty else { return }
        store = updated
        let here = released.filter { $0.context == context }
        guard peek, !here.isEmpty, isPanelVisible, !isExpanded, previewItem == nil else { return }
        let top = here.map(\.priority).min() ?? .normal
        let shown = LaterDigest(count: here.count, reason: reason, priority: top)
        digest = shown
        pulse = PulseRequest(times: 1, priority: top, ambient: true)
        digestTask?.cancel()
        digestTask = holdPeek(while: { [weak self] in self?.digest == shown }) { [weak self] in
            self?.digest = nil
        }
    }

    /// Keeps an arrival peek (the new-item preview or the Later digest) out for Settings →
    /// Alerts → Show new items for. The clock stops while the pointer is over the panel and
    /// resumes when it leaves (PeekCountdown). Ends early, without calling `end`, once
    /// `showing` is false (clicked, replaced or collapsed).
    func holdPeek(while showing: @escaping () -> Bool, end: @escaping () -> Void) -> Task<Void, Never> {
        let seconds = settings.ui.previewSeconds
        return Task { [weak self] in
            var countdown = PeekCountdown(seconds: seconds)
            let step: TimeInterval = 0.25
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, showing() else { return }
                if countdown.advance(by: step, hovering: self.hovering) {
                    end()
                    return
                }
            }
        }
    }

    /// The Later section's Show now.
    func deliverLaterNow() { releaseLater(.byHand, peek: false) }

    // MARK: Focus

    /// Focus menu: a level for a while. Never activates the app.
    func setFocus(_ level: FocusLevel, for duration: FocusDuration) {
        setFocus(FocusState(level: level, until: duration.until(from: Date()), source: .menu))
    }

    /// Set the focus (menus, needsyou://focus). An inactive state ends the focus.
    func setFocus(_ state: FocusState) {
        guard state.isActive(at: Date()) else { endFocus(); return }
        settings.focus = state
        objectWillChange.send()
    }

    /// Focus → Off: what waited is delivered as one quiet peek.
    func endFocus() {
        let wasFocused = isFocused
        settings.focus = .off
        objectWillChange.send()
        if wasFocused { releaseLater(.focusEnded) }
    }

    func requestPulse(times: Int, priority: ItemPriority) {
        pulse = PulseRequest(times: times, priority: priority)
    }

    /// The arrival to play for a pulse (Settings → Alerts → Arrival animation and timing).
    /// Ambient arrivals stay one soft glow whatever the animation.
    func arrivalPlan(_ request: PulseRequest) -> ArrivalPlan {
        let ui = settings.ui
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if request.ambient {
            let look = AlertStyle.ambientLook(ui.alertIntensity(for: request.priority), priority: request.priority)
            return ArrivalMotion.plan(.glow, look: look, speed: ui.arrivalSpeed, reduceMotion: reduceMotion)
        }
        return ui.arrivalPlan(for: request.priority, basePulses: request.times, reduceMotion: reduceMotion)
    }

    /// Settings → Alerts → Preview on the pill: a sample item arrives the way a real one
    /// does (the announcer: the pill springs out to its preview with the arrival animation,
    /// the preview stays out for Show new items for, then the pill goes back). Nothing is
    /// posted or counted. Only changes what's drawn; never shows, orders front or focuses
    /// the panel.
    func previewArrival(_ priority: ItemPriority) {
        guard isPanelVisible else { return }
        if isExpanded { collapse() }
        digest = nil
        let sample = ArrivalPreview.sampleItem(priority)
        if let announcer {
            announcer(self, [sample])
        } else {
            pulse = PulseRequest(times: priority == .urgent ? 2 : 1, priority: priority)
        }
    }

    /// Settings → Alerts → Remind about unseen urgent items: plays urgent's arrival again
    /// every N minutes while an urgent item that came in since the panel was last open waits
    /// (UrgentReminder decides). Called from the 15 s tick.
    private func remindAboutUrgent(at date: Date) {
        let minutes = settings.ui.urgentReminderMinutes
        guard minutes > 0 else { return }
        let since = settings.pillLastOpenedAt
        let unseen = needsItems.filter { item in
            item.priority == .urgent && since.map { store.freshAt(item) > $0 } == true
        }
        guard let top = unseen.first else { return }
        if lastUrgentAlertAt == nil { lastUrgentAlertAt = date }   // e.g. after a relaunch
        let interrupts = DeliveryPolicy.decide(top, state: deliveryState(at: date)).tier == .interrupt
        let input = UrgentReminder.Input(intervalMinutes: minutes, unseenUrgent: unseen.count,
                                         panelShown: !visibility.isHidden(at: date), expanded: isExpanded,
                                         peekShowing: previewItem != nil || digest != nil,
                                         urgentWouldInterrupt: interrupts, lastAlertAt: lastUrgentAlertAt, now: date)
        if UrgentReminder.isDue(input) {
            pulse = PulseRequest(times: 2, priority: .urgent)
        }
    }

    // MARK: Expand / collapse

    /// Clicking the pill. Never makes the panel key or activates the app.
    func toggleExpanded() {
        isExpanded ? collapse() : expand(byUser: true)
    }

    /// `focusing` is the card the click was about (a preview); a plain click on the pill
    /// goes to the newest arrival instead (ExpandFocus).
    func expand(byUser: Bool = false, focusing clicked: String? = nil) {
        // Automatic expansions (NEEDS_YOU_EXPAND, the morning summary) never undo a hide.
        if visibility == .hidden && !byUser && !peeking { return }
        if byUser, let target = ExpandFocus.target(clicked: clicked, items: needsItems,
                                                   lastOpenedAt: settings.pillLastOpenedAt, freshAt: store.freshAt) {
            focus(on: target)
        }
        expandedByUser = byUser
        endLaunchOpen()
        previewItem = nil
        digest = nil
        if visibility.isHidden(at: Date()) && !peeking {
            // The shortcut or the morning summary ends a snooze: what it held is delivered,
            // as when it runs out (no peek; the list is opening).
            let wasSnoozed = visibility != .hidden
            visibility = .shown
            if wasSnoozed { releaseLater(.snoozeEnded, peek: false) }
        }
        isExpanded = true
        if byUser { refreshSetupFacts() }
        refreshOrca()
        markVisibleSeen()
        settings.pillLastOpenedAt = Date()   // the pill's "N new" starts over
    }

    /// The person started the app (LaunchOpen): open the panel once so they see their items
    /// and where the pill is. An automatic expansion like the morning summary, so it never
    /// makes the panel key or activates the app, and a hidden panel stays hidden. It closes
    /// like an arrival peek: after LaunchOpen.seconds with the pointer away, held while the
    /// pointer is over it, 2 s after the pointer leaves; or at a click elsewhere.
    func openAtLaunch() {
        guard !isExpanded, isPanelVisible else { return }
        expand()
        guard isExpanded else { return }
        openedAtLaunch = true
        launchOpenTask = Task { [weak self] in
            var countdown = PeekCountdown(seconds: LaunchOpen.seconds)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.openedAtLaunch, self.isExpanded else { return }
                if countdown.advance(by: 0.25, hovering: self.hovering) {
                    NSLog("NeedsYou: the panel opened at launch closed by itself")
                    self.collapse()
                    return
                }
            }
        }
    }

    private func endLaunchOpen() {
        openedAtLaunch = false
        launchOpenTask?.cancel()
        launchOpenTask = nil
    }

    /// Scroll the open list to a card and highlight it for a moment.
    private func focus(on id: String) {
        scrollTarget = id
        highlightedItem = id
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.highlightedItem = nil
        }
    }

    /// The preview's link button: open the link and count the alert as handled. The panel
    /// stays collapsed; nothing activates this app.
    func openAndResolve(_ item: Item, link: ItemLink) {
        previewItem = nil
        guard open(link.url, from: item) else { return }
        // App actions (the terminal and Orca jumps) already resolve in open(_:from:).
        if AppAction.parse(link.url) == nil { resolve(item) }
    }

    func collapse() {
        if isExpanded { settings.pillLastOpenedAt = Date() }   // what arrived while open was seen
        endLaunchOpen()
        isExpanded = false
        summarySince = nil
        peeking = false
        scrollTarget = nil
        highlightedItem = nil
        if !expandedCards.isEmpty { expandedCards = [] }
    }

    /// The resize grip's double-click: the list goes back to its automatic height.
    func resetListHeight() {
        settings.ui.expandedListHeight = Double(ListResize.automatic)
    }

    func toggleCardExpanded(_ item: Item) {
        if expandedCards.contains(item.id) { expandedCards.remove(item.id) } else { expandedCards.insert(item.id) }
    }

    func toggleStep(_ item: Item, _ index: Int) {
        stepTicks.toggle(item, index)
    }

    // MARK: Answers (ADR 0009 B2)

    /// A click on an option of an answerable question. For one single-choice question the
    /// click is the answer and is sent at once; otherwise it toggles the option and Send
    /// sends. Nothing here activates the app or makes the panel key: these are plain
    /// buttons in the non-activating panel, and the answer is one network request.
    func pickOption(_ item: Item, question: Int, label: String) {
        guard AnswerPolicy.canAnswer(item, now: Date()), let q = item.question,
              q.items.indices.contains(question), answerStates[item.id] != .sending,
              answerStates[item.id] != .sent else { return }
        if AnswerPolicy.sendsOnClick(q) {
            if let request = AnswerPolicy.clickRequest(item, question: question, label: label) {
                sendAnswer(item, request)
            }
            return
        }
        var selection = answerSelections[item.id] ?? AnswerSelection()
        selection.toggle(question, label, multiSelect: q.items[question].multiSelect)
        answerSelections[item.id] = selection
        answerStamps[item.id] = AnswerPolicy.stamp(item)
        if case .failed = answerStates[item.id] { answerStates[item.id] = nil }
    }

    /// Send: the clicked options, once every question has one.
    func sendPickedAnswer(_ item: Item) {
        guard AnswerPolicy.canAnswer(item, now: Date()),
              let request = AnswerPolicy.request(item, answerSelections[item.id] ?? AnswerSelection()) else { return }
        sendAnswer(item, request)
    }

    /// A click on "Other…" ("Answer…" for a question without options): open the answer
    /// window, where the person types their own words. The one card button that activates
    /// the app (CLAUDE.md rule 2): typing needs a key window, and the panel never is one.
    func openAnswerWindow(_ item: Item, question: Int) {
        guard AnswerPolicy.canAnswer(item, now: Date(), mayType: mayTypeAnswers), let q = item.question,
              q.items.indices.contains(question), q.items[question].allowOther,
              answerStates[item.id] != .sending, answerStates[item.id] != .sent else { return }
        openAnswerWindowHandler?(item, question)
    }

    /// The words already typed for a question on this card (to edit them), if any.
    func typedAnswer(_ itemID: String, question: Int) -> String? {
        answerSelections[itemID]?.texts[question]
    }

    /// Would the words for this question make the card's answer whole (the window's button
    /// then says Send), and the labels picked on the card that would go with them.
    func typedAnswerPlan(_ itemID: String, question: Int) -> (complete: Bool, with: [String]) {
        guard let item = store.items[itemID], let q = item.question,
              let r = AnswerPolicy.withText(item, answerSelections[itemID] ?? AnswerSelection(),
                                            question: question, text: "x") else { return (false, []) }
        let with = q.items.indices.flatMap { i in
            q.items[i].options.map(\.label).filter { r.selection.isPicked(i, $0) }
        }
        return (r.complete, with)
    }

    /// Send (or Use) in the answer window: the typed words become that question's answer.
    /// When that makes the card's answer whole it is sent, like a click; otherwise the card
    /// keeps the words and its Send waits for the other questions. Returns why the words
    /// weren't taken, for the window; nil when they were (the window closes).
    func submitTypedAnswer(itemID: String, question: Int, text raw: String, seenVersion: String?) -> String? {
        guard let item = store.items[itemID], AnswerPolicy.canAnswer(item, now: Date(), mayType: mayTypeAnswers),
              answerStates[itemID] != .sending, answerStates[itemID] != .sent else {
            return "This question can't take an answer any more: answer in the terminal."
        }
        guard item.contentUpdatedAtRaw == seenVersion else {
            return "The question changed while you typed: look at the card again."
        }
        switch AnswerPolicy.typedAnswer(raw) {
        case .refused(let why):
            return why
        case .ok(let text):
            guard let r = AnswerPolicy.withText(item, answerSelections[itemID] ?? AnswerSelection(),
                                                question: question, text: text) else {
                return "This question takes only its options."
            }
            answerSelections[itemID] = r.selection
            // Stamped like a click, so a re-post that changes the question clears the words
            // (staleAnswerIDs) instead of sending them as the answer to another question.
            answerStamps[itemID] = AnswerPolicy.stamp(item)
            if case .failed = answerStates[itemID] { answerStates[itemID] = nil }
            if r.complete, let request = AnswerPolicy.request(item, r.selection) { sendAnswer(item, request) }
            return nil
        }
    }

    /// A click on the typed words' row before Send: take them back.
    func clearTypedAnswer(_ item: Item, question: Int) {
        guard var selection = answerSelections[item.id], let q = item.question, q.items.indices.contains(question),
              answerStates[item.id] != .sending, answerStates[item.id] != .sent else { return }
        selection.setText(question, nil, multiSelect: q.items[question].multiSelect)
        answerSelections[item.id] = selection
        answerStamps[item.id] = AnswerPolicy.stamp(item)
    }

    private func sendAnswer(_ item: Item, _ request: AnswerRequest) {
        guard let feed else { return }
        answerStates[item.id] = .sending
        answerStamps[item.id] = AnswerPolicy.stamp(item)
        let id = item.id
        let generation = feedGeneration
        let typed = AnswerPolicy.hasText(request)
        Task {
            let state: AnswerState
            var typedRefused = false
            do {
                switch try await feed.answer(id: id, request) {
                case .taken: state = .sent
                case .refused(let code):
                    typedRefused = typed && code == "forbidden"
                    state = .failed(AnswerPolicy.failureText(code: code, typed: typed))
                }
            } catch {
                state = .failed(AnswerPolicy.failureText(code: nil))
            }
            guard generation == feedGeneration else { return }
            if typedRefused {
                // No hub takes this Mac's typed words: drop them so the card's options can be
                // picked, and stop offering Other… (the card says why).
                typedAnswersRefused = true
                answerSelections[id] = answerSelections[id]?.withoutTexts()
            }
            answerStates[id] = state
            if state == .sent {
                answerSelections[id] = nil
                pollNow()  // the item's answer comes back from the hub
            }
        }
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
        endPreview(ifGone: [removed])
        let generation = feedGeneration
        Task {
            do {
                try await feed.patch(id: item.id, ItemPatch(status: status))
            } catch {
                guard generation == feedGeneration else {
                    // The feed changed meanwhile and carried the close over: let it go.
                    store.forgetClose(id: item.id)
                    return
                }
                store.restore(settings.bypassRules.applied(to: removed))
                lastError = "Couldn't update item"
            }
        }
    }

    /// What "Dismiss All from <host>" closes: everything shown in this context from that host.
    func itemsFromSameHost(as item: Item) -> [Item] {
        guard let host = ItemStore.host(of: item) else { return [] }
        return store.visibleItems(fromHost: host, in: context, now: now)
    }

    /// Dismiss every card and Recent row from the item's host (stale-items.md, option D).
    /// One PATCH per item, like Dismiss.
    func dismissAll(fromHostOf item: Item) {
        for other in itemsFromSameHost(as: item) { dismiss(other) }
    }

    func snoozeCard(_ item: Item, _ option: SnoozeOption) {
        store.snoozeCard(id: item.id, until: option.until(from: Date()))
    }

    // MARK: Copying from a card

    /// Puts `text` on the clipboard and shows "Copied" on the card: on the chip clicked
    /// (`inPlace`), else by the "…" menu. The panel is never key, so a card's text can't be
    /// selected; this is how it's copied. Nothing activates.
    func copy(_ text: String, from item: Item, what: String, inPlace: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = CardCopyNotice(itemID: item.id, text: text, what: what, inPlace: inPlace)
        copiedTask?.cancel()
        copiedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    /// Developer mode's debug report context: versions, the feed, and how the item would be
    /// delivered now. Never a token, peer secret or invite code (the feed is a short name).
    func debugInfo(for item: Item) -> CardCopy.DebugInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "dev build"
        let build = (info["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        let date = Date()
        let feedName = isDemo ? "demo" : (activeHub.map { "\($0) (last successful poll)" } ?? "none yet")
        return CardCopy.DebugInfo(appVersion: version + build,
                                  osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                  feed: feedName,
                                  delivery: DeliveryPolicy.decide(item, state: deliveryState(at: date)),
                                  rule: settings.bypassRules.firstMatch(item),
                                  focus: settings.focus.effectiveLevel(at: date).title,
                                  capturedAt: date)
    }

    // MARK: Panel visibility

    /// Is the floating panel on screen? (Shown, or peeking while hidden.)
    var isPanelVisible: Bool { peeking || !visibility.isHidden(at: Date()) }

    func snoozePanel(_ option: SnoozeOption) {
        isExpanded = false
        previewItem = nil
        digest = nil
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
        digest = nil
        peeking = false
        summarySince = nil
        visibility = .hidden
        return true
    }

    func showPanel() {
        peeking = false
        let wasSnoozed: Bool
        if case .snoozed = visibility { wasSnoozed = true } else { wasSnoozed = false }
        visibility = .shown
        if wasSnoozed { releaseLater(.snoozeEnded) }
    }

    /// The global shortcut and the menu bar's Show Floating Panel: hidden/snoozed → shown,
    /// shown → hidden. Returns false if hiding was refused. A peek (a menu item opened the
    /// hidden panel) counts as hidden, matching the unchecked menu item: it stays shown.
    @discardableResult
    func toggleVisibility() -> Bool {
        if visibility.isHidden(at: Date()) { showPanel(); return true }
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
            if let action = AppAction.parse(url) {
                run(action)
                resolve(item)
            } else {
                NSWorkspace.shared.open(url)
            }
        case .showPanel:
            if item.context != context { setContext(item.context) }
            showExpanded(focusing: item.id)
        }
    }

    /// Expand the panel from the menu bar. While hidden or snoozed it only peeks:
    /// collapsing puts it back out of sight.
    func showExpanded(focusing id: String? = nil) {
        if visibility.isHidden(at: Date()) { peeking = true }
        expand(byUser: true, focusing: id)
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

    /// Opens a link only if it passes the scheme allow-list. The app's own actions (the
    /// Orca and terminal jumps) run their fixed action instead of going to NSWorkspace, and
    /// going to the terminal counts as handling the card: it's marked done. A click in the
    /// panel is trusted; links from outside the app go through AppDelegate, which asks.
    /// The panel stays open afterwards (so the card can be read next to what it opened)
    /// unless Settings → Panel → Collapse when clicking elsewhere is on.
    @discardableResult
    func open(_ string: String, from item: Item? = nil) -> Bool {
        if let action = AppAction.parse(string) {
            run(action)
            if let item { resolve(item) }
            collapseAfterOpening()
            return true
        }
        guard let url = LinkPolicy.externalURL(string) else { return false }
        NSWorkspace.shared.open(url)
        collapseAfterOpening()
        return true
    }

    private func collapseAfterOpening() {
        if settings.ui.collapseOnClickOutside { collapse() }
    }

    @discardableResult
    func open(_ url: URL) -> Bool { open(url.absoluteString) }

    /// Runs one of the app's own actions. Activates the target app, never this one.
    func run(_ action: AppAction) {
        switch action {
        case .orca(let jump): OrcaJumpRunner.run(jump)
        case .terminal(let jump): TerminalJumpRunner.run(jump, appleScript: settings.terminalAppleScript)
        }
    }

    func openSettings() { openSettingsHandler?() }

    func openSettings(page: SettingsTab) {
        if let openSettingsPageHandler { openSettingsPageHandler(page) } else { openSettings() }
    }
}

/// "Copied" on a card: which card, what was copied (a chip matches on `text`), how to say
/// it ("Copied JSON"), and whether the chip clicked shows it itself.
struct CardCopyNotice: Equatable {
    let id = UUID()
    let itemID: String
    let text: String
    let what: String
    let inPlace: Bool
}

/// The line under a setup card after its button ran.
struct SetupNotice: Equatable {
    let tip: SetupTip
    let text: String
    let failed: Bool
}

enum DragPhase {
    case changed
    case ended
}
