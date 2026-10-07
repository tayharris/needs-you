#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func item(_ id: String, _ priority: ItemPriority = .normal, context: ItemContext = .work, kind: ItemKind = .needs,
                  key: String? = nil, host: String? = nil, agent: String? = nil) -> Item {
    Item(id: id, key: key ?? "work:test:\(id)", context: context, kind: kind, priority: priority, title: id,
         source: (host == nil && agent == nil) ? nil : ItemSource(host: host, agent: agent), createdAt: now)
}

private func tier(_ item: Item, focus: FocusLevel = .off, visibility: PanelVisibility = .shown,
                  defaults: DeliveryDefaults = .standard, rules: [BypassRule] = [],
                  breaksSnooze: Bool = true, showsHidden: Bool = false) -> DeliveryTier {
    decide(item, focus: focus, visibility: visibility, defaults: defaults, rules: rules,
           breaksSnooze: breaksSnooze, showsHidden: showsHidden).tier
}

private func decide(_ item: Item, focus: FocusLevel = .off, visibility: PanelVisibility = .shown,
                    defaults: DeliveryDefaults = .standard, rules: [BypassRule] = [],
                    breaksSnooze: Bool = true, showsHidden: Bool = false) -> DeliveryDecision {
    DeliveryPolicy.decide(item, state: DeliveryState(
        context: .work, visibility: visibility, focus: focus, defaults: defaults, rules: RuleBook(rules),
        urgentBreaksSnooze: breaksSnooze, urgentShowsHiddenPanel: showsHidden, now: now))
}

private let snoozed = PanelVisibility.snoozed(until: now.addingTimeInterval(600))

/// One test per cell of the tier table in docs/roadmap/focus-tiers.md ("Default mapping"),
/// with the app's focus levels: Off, Agents and urgent only, Urgent only, Everything later.
final class DeliveryPolicyTests: XCTestCase {
    static var allTests = [
        ("testUrgentInContext", testUrgentInContext),
        ("testNormalInContext", testNormalInContext),
        ("testLowInContext", testLowInContext),
        ("testOtherContext", testOtherContext),
        ("testUrgentOtherContext", testUrgentOtherContext),
        ("testDoneAndInfo", testDoneAndInfo),
        ("testAgentItems", testAgentItems),
        ("testUrgentBreaksFocusOff", testUrgentBreaksFocusOff),
        ("testSnoozedAndHidden", testSnoozedAndHidden),
        ("testExpiredSnoozeIsShown", testExpiredSnoozeIsShown),
        ("testRulesWin", testRulesWin),
        ("testRuleCantUnhideThePanel", testRuleCantUnhideThePanel),
        ("testHoldsForLater", testHoldsForLater),
        ("testDefaultsFromSettings", testDefaultsFromSettings),
        ("testHiddenArrivalFromDecisions", testHiddenArrivalFromDecisions),
        ("testOldSnoozeBehaviourIsPreserved", testOldSnoozeBehaviourIsPreserved),
        ("testPreviewTable", testPreviewTable),
        ("testDefaultsLoadAndSave", testDefaultsLoadAndSave),
        ("testLaterDigestText", testLaterDigestText),
    ]

    func testUrgentInContext() {
        let u = item("u", .urgent)
        XCTAssertEqual(tier(u), .interrupt)
        XCTAssertEqual(tier(u, focus: .agentsAndUrgent), .interrupt)
        XCTAssertEqual(tier(u, focus: .urgentOnly), .interrupt)
        // Everything later means everything; only an Always interrupt rule gets through.
        XCTAssertEqual(tier(u, focus: .everythingLater), .later)
        XCTAssertEqual(tier(u, visibility: snoozed), .interrupt)
        XCTAssertEqual(tier(u, visibility: snoozed, breaksSnooze: false), .ambient)
    }

    func testNormalInContext() {
        let n = item("n", .normal)
        XCTAssertEqual(tier(n), .interrupt)
        XCTAssertEqual(tier(n, focus: .agentsAndUrgent), .later)
        XCTAssertEqual(tier(n, focus: .urgentOnly), .later)
        XCTAssertEqual(tier(n, focus: .everythingLater), .later)
        XCTAssertEqual(tier(n, visibility: snoozed), .later)
    }

    func testLowInContext() {
        let l = item("l", .low)
        XCTAssertEqual(tier(l), .ambient)
        XCTAssertEqual(tier(l, focus: .agentsAndUrgent), .later)
        XCTAssertEqual(tier(l, focus: .urgentOnly), .later)
        XCTAssertEqual(tier(l, focus: .everythingLater), .later)
        XCTAssertEqual(tier(l, visibility: snoozed), .later)
    }

    func testOtherContext() {
        let o = item("o", .normal, context: .personal)
        XCTAssertEqual(decide(o), DeliveryDecision(tier: .later, reason: .otherContext, holdsForLater: false))
        for level in FocusLevel.allCases {
            XCTAssertEqual(tier(o, focus: level), .later)
            XCTAssertFalse(decide(o, focus: level).holdsForLater, "other-context items are never held")
        }
        XCTAssertEqual(tier(o, visibility: snoozed), .later)
    }

    func testUrgentOtherContext() {
        // Urgent breaks through in either context.
        let u = item("u", .urgent, context: .personal)
        XCTAssertEqual(tier(u), .interrupt)
        XCTAssertEqual(tier(u, focus: .agentsAndUrgent), .interrupt)
        XCTAssertEqual(tier(u, focus: .urgentOnly), .interrupt)
        XCTAssertEqual(tier(u, visibility: snoozed), .interrupt)
    }

    func testDoneAndInfo() {
        for kind in [ItemKind.done, .info] {
            let d = item("d", .normal, kind: kind)
            XCTAssertEqual(tier(d), .ambient)
            XCTAssertEqual(tier(d, focus: .agentsAndUrgent), .later)
            XCTAssertEqual(tier(d, focus: .urgentOnly), .later)
            XCTAssertEqual(tier(d, visibility: snoozed), .later)
            XCTAssertFalse(decide(d, focus: .urgentOnly).holdsForLater, "Recent rows aren't collected under Later")
            // An "urgent" done item is not urgent: only needs items break through.
            XCTAssertEqual(tier(item("du", .urgent, kind: kind), focus: .urgentOnly), .later)
        }
    }

    func testAgentItems() {
        let agent = item("a", .normal, key: "agent:devbox:abc123")
        XCTAssertEqual(tier(agent), .interrupt)
        XCTAssertEqual(tier(agent, focus: .agentsAndUrgent), .interrupt)
        XCTAssertEqual(tier(agent, focus: .urgentOnly), .later)
        XCTAssertEqual(tier(agent, focus: .everythingLater), .later)
        // Focus only makes things quieter: a low agent item stays ambient.
        XCTAssertEqual(tier(item("al", .low, key: "agent:devbox:x"), focus: .agentsAndUrgent), .ambient)
        // An agent done item isn't a gate.
        XCTAssertEqual(tier(item("ad", .normal, kind: .done, key: "agent:devbox:x"), focus: .agentsAndUrgent), .later)
    }

    func testUrgentBreaksFocusOff() {
        var d = DeliveryDefaults()
        d.urgentBreaksFocus = false
        let u = item("u", .urgent)
        XCTAssertEqual(tier(u, defaults: d), .interrupt, "no focus: unchanged")
        XCTAssertEqual(tier(u, focus: .agentsAndUrgent, defaults: d), .ambient)
        XCTAssertEqual(tier(u, focus: .urgentOnly, defaults: d), .ambient)
        XCTAssertEqual(tier(u, visibility: snoozed, defaults: d), .interrupt, "the snooze has its own setting")
    }

    func testSnoozedAndHidden() {
        let u = item("u", .urgent), n = item("n"), l = item("l", .low)
        // Hidden: still counted (ambient), and only urgent with the setting brings it back.
        XCTAssertEqual(tier(u, visibility: .hidden), .ambient)
        XCTAssertEqual(tier(u, visibility: .hidden, showsHidden: true), .interrupt)
        XCTAssertEqual(tier(n, visibility: .hidden), .ambient)
        XCTAssertEqual(tier(n, visibility: .hidden, showsHidden: true), .ambient)
        XCTAssertEqual(tier(l, visibility: .hidden), .ambient)
        // Hidden plus focus: the quieter wins.
        XCTAssertEqual(tier(n, focus: .urgentOnly, visibility: .hidden), .later)
        // Snoozed plus focus.
        XCTAssertEqual(tier(u, focus: .everythingLater, visibility: snoozed), .later)
        XCTAssertEqual(decide(n, visibility: snoozed).reason, .snooze)
        XCTAssertEqual(decide(n, focus: .urgentOnly).reason, .focus)
    }

    func testExpiredSnoozeIsShown() {
        XCTAssertEqual(tier(item("n"), visibility: .snoozed(until: now)), .interrupt)
    }

    func testRulesWin() {
        let agentRule = BypassRule(match: .keyPrefix, value: "work:gh:deploy:", action: .alwaysInterrupt)!
        let deploy = item("d", .low, key: "work:gh:deploy:acme/app:42")
        XCTAssertEqual(tier(deploy), .ambient)
        XCTAssertEqual(tier(deploy, rules: [agentRule]), .interrupt)
        XCTAssertEqual(tier(deploy, focus: .everythingLater, rules: [agentRule]), .interrupt)
        XCTAssertEqual(tier(deploy, visibility: snoozed, rules: [agentRule]), .interrupt)
        XCTAssertEqual(decide(deploy, focus: .urgentOnly, rules: [agentRule]).reason, .rule)

        let quiet = BypassRule(match: .host, value: "CI-runner", action: .neverInterrupt)!
        XCTAssertEqual(tier(item("c", .urgent, host: "ci-runner"), rules: [quiet]), .ambient)
        XCTAssertEqual(tier(item("c2", .low, host: "ci-runner"), rules: [quiet]), .ambient)
        XCTAssertEqual(tier(item("c3", .normal, host: "ci-runner"), focus: .urgentOnly, rules: [quiet]), .later,
                       "never interrupt doesn't make anything louder")

        let later = BypassRule(match: .agentPrefix, value: "orca:", action: .alwaysLater)!
        XCTAssertEqual(tier(item("o", .urgent, agent: "Orca:nightly"), rules: [later]), .later)
        XCTAssertTrue(decide(item("o", .urgent, agent: "orca:nightly"), rules: [later]).holdsForLater)

        // First match wins.
        let both = [BypassRule(match: .host, value: "devbox", action: .alwaysLater)!,
                    BypassRule(match: .host, value: "devbox", action: .alwaysInterrupt)!]
        XCTAssertEqual(tier(item("x", host: "devbox"), rules: both), .later)
        // No match: the table.
        XCTAssertEqual(tier(item("y", host: "laptop"), rules: both), .interrupt)
    }

    func testRuleCantUnhideThePanel() {
        let rule = BypassRule(match: .keyPrefix, value: "agent:", action: .alwaysInterrupt)!
        let agent = item("a", .normal, key: "agent:devbox:s")
        XCTAssertEqual(tier(agent, visibility: .hidden, rules: [rule]), .ambient)
        XCTAssertEqual(tier(item("u", .urgent, key: "agent:devbox:s"), visibility: .hidden, rules: [rule], showsHidden: true), .interrupt)
    }

    func testHoldsForLater() {
        XCTAssertTrue(decide(item("n"), focus: .urgentOnly).holdsForLater)
        XCTAssertTrue(decide(item("n"), visibility: snoozed).holdsForLater)
        XCTAssertFalse(decide(item("n")).holdsForLater)
        XCTAssertFalse(decide(item("l", .low)).holdsForLater, "ambient isn't held")
        var closed = item("c")
        closed.status = .resolved
        XCTAssertFalse(decide(closed, focus: .urgentOnly).holdsForLater)
    }

    func testDefaultsFromSettings() {
        var d = DeliveryDefaults()
        d.normal = .ambient
        d.low = .later
        d.recent = .later
        d.otherContext = .ambient
        XCTAssertEqual(tier(item("n"), defaults: d), .ambient)
        XCTAssertEqual(tier(item("l", .low), defaults: d), .later)
        XCTAssertTrue(decide(item("l", .low), defaults: d).holdsForLater, "a low-is-later default collects a digest")
        XCTAssertEqual(tier(item("d", kind: .done), defaults: d), .later)
        XCTAssertEqual(tier(item("o", context: .personal), defaults: d), .ambient)
        XCTAssertEqual(tier(item("u", .urgent), defaults: d), .interrupt, "urgent isn't configurable")
    }

    func testHiddenArrivalFromDecisions() {
        let u = item("u", .urgent), n = item("n")
        func arrival(_ items: [Item], visibility: PanelVisibility, showsHidden: Bool = false, focus: FocusLevel = .off) -> HiddenArrival {
            DeliveryPolicy.hiddenArrival(items.map { (item: $0, decision: decide($0, focus: focus, visibility: visibility, showsHidden: showsHidden)) })
        }
        XCTAssertEqual(arrival([n, u], visibility: snoozed), .showPanel)
        XCTAssertEqual(arrival([u], visibility: .hidden), .pulseMenuBar)
        XCTAssertEqual(arrival([u], visibility: .hidden, showsHidden: true), .showPanel)
        XCTAssertEqual(arrival([n], visibility: .hidden), .none)
        XCTAssertEqual(arrival([u], visibility: snoozed, focus: .everythingLater), .none)
    }

    /// The old SnoozeBreakthrough and HiddenArrivalPolicy results, now through the policy.
    func testOldSnoozeBehaviourIsPreserved() {
        let u = item("u", .urgent), n = item("n"), uPersonal = item("up", .urgent, context: .personal)
        var done = u; done.status = .resolved
        var info = u; info.kind = .info
        XCTAssertTrue(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [n, u], urgentBreaksThrough: true, now: now))
        XCTAssertTrue(SnoozeBreakthrough.shouldBreakThrough(visibility: .hidden, announced: [u], urgentBreaksThrough: true, now: now))
        XCTAssertTrue(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [uPersonal], urgentBreaksThrough: true, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [u], urgentBreaksThrough: false, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: snoozed, announced: [n, done, info], urgentBreaksThrough: true, now: now))
        XCTAssertFalse(SnoozeBreakthrough.shouldBreakThrough(visibility: .shown, announced: [u], urgentBreaksThrough: true, now: now))

        func hidden(_ v: PanelVisibility, _ items: [Item], breaks: Bool = true, shows: Bool = false) -> HiddenArrival {
            HiddenArrivalPolicy.decide(visibility: v, announced: items, urgentBreaksSnooze: breaks, urgentShowsHiddenPanel: shows, now: now)
        }
        XCTAssertEqual(hidden(.shown, [u]), .none)
        XCTAssertEqual(hidden(.hidden, [u]), .pulseMenuBar)
        XCTAssertEqual(hidden(.hidden, [uPersonal]), .pulseMenuBar)
        XCTAssertEqual(hidden(.hidden, [u], shows: true), .showPanel)
        XCTAssertEqual(hidden(.hidden, [n], shows: true), .none)
        XCTAssertEqual(hidden(snoozed, [n, u]), .showPanel)
        XCTAssertEqual(hidden(snoozed, [uPersonal]), .showPanel)
        XCTAssertEqual(hidden(snoozed, [u], breaks: false), .pulseMenuBar)
        XCTAssertEqual(hidden(snoozed, [n]), .none)
        XCTAssertEqual(hidden(.snoozed(until: now), [u]), .none)
        XCTAssertEqual(hidden(.hidden, [done, info]), .none)
    }

    func testPreviewTable() {
        let d = DeliveryDefaults()
        XCTAssertEqual(DeliveryPolicy.PreviewColumn.all.count, 5)
        XCTAssertEqual(DeliveryPolicy.preview(.urgent, .focus(.off), defaults: d, urgentBreaksSnooze: true), .interrupt)
        XCTAssertEqual(DeliveryPolicy.preview(.urgent, .snoozed, defaults: d, urgentBreaksSnooze: false), .ambient)
        XCTAssertEqual(DeliveryPolicy.preview(.normal, .focus(.urgentOnly), defaults: d, urgentBreaksSnooze: true), .later)
        XCTAssertEqual(DeliveryPolicy.preview(.agent, .focus(.agentsAndUrgent), defaults: d, urgentBreaksSnooze: true), .interrupt)
        XCTAssertEqual(DeliveryPolicy.preview(.low, .focus(.off), defaults: d, urgentBreaksSnooze: true), .ambient)
        XCTAssertEqual(DeliveryPolicy.preview(.otherContext, .focus(.off), defaults: d, urgentBreaksSnooze: true), .later)
        XCTAssertEqual(DeliveryPolicy.preview(.doneInfo, .focus(.off), defaults: d, urgentBreaksSnooze: true), .ambient)
    }

    func testDefaultsLoadAndSave() {
        let suite = "needsyou.delivery.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DeliveryDefaults.load(from: store), DeliveryDefaults.standard)
        // Unknown or not-allowed values fall back.
        store.set("loud", forKey: DeliveryDefaults.Key.normal)
        store.set("interrupt", forKey: DeliveryDefaults.Key.recent)
        XCTAssertEqual(DeliveryDefaults.load(from: store), DeliveryDefaults.standard)
        var d = DeliveryDefaults()
        d.low = .later
        d.urgentBreaksFocus = false
        d.save(to: store, previous: .standard)
        XCTAssertEqual(store.string(forKey: DeliveryDefaults.Key.low), "later")
        XCTAssertEqual(store.string(forKey: DeliveryDefaults.Key.normal), "loud", "unchanged keys aren't written")
        XCTAssertEqual(DeliveryDefaults.load(from: store), d)
    }

    func testLaterDigestText() {
        XCTAssertEqual(LaterDigest(count: 3, reason: .focusEnded).text, "3 waited while you were focused")
        XCTAssertEqual(LaterDigest(count: 1, reason: .snoozeEnded).text, "1 waited while you were snoozed")
        XCTAssertEqual(LaterDigest(count: 2, reason: .startOfDay).text, "2 waited for the start of the day")
    }
}

final class FocusStateTests: XCTestCase {
    static var allTests = [
        ("testEffectiveLevel", testEffectiveLevel),
        ("testDurations", testDurations),
        ("testPersistence", testPersistence),
        ("testSummary", testSummary),
    ]

    func testEffectiveLevel() {
        XCTAssertEqual(FocusState.off.effectiveLevel(at: now), .off)
        let timed = FocusState(level: .urgentOnly, until: now.addingTimeInterval(60))
        XCTAssertEqual(timed.effectiveLevel(at: now), .urgentOnly)
        XCTAssertTrue(timed.isActive(at: now))
        XCTAssertEqual(timed.effectiveLevel(at: now.addingTimeInterval(60)), .off)
        XCTAssertEqual(FocusState(level: .everythingLater).effectiveLevel(at: .distantFuture), .everythingLater, "no end: until turned off")
        XCTAssertNil(FocusState(level: .off, until: now).until)
    }

    func testDurations() {
        XCTAssertEqual(FocusDuration.minutes30.until(from: now), now.addingTimeInterval(1800))
        XCTAssertEqual(FocusDuration.hour1.until(from: now), now.addingTimeInterval(3600))
        XCTAssertEqual(FocusDuration.hours2.until(from: now), now.addingTimeInterval(7200))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let tomorrow = FocusDuration.tomorrow.until(from: now, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: tomorrow), SnoozeOption.tomorrowHour)
        XCTAssertTrue(tomorrow > now)
        XCTAssertEqual(FocusDuration.allCases.map(\.title), ["30 min", "1 hr", "2 hr", "Until tomorrow"])
    }

    func testPersistence() {
        let suite = "needsyou.focus.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FocusState.load(from: store, now: now), .off)
        let state = FocusState(level: .agentsAndUrgent, until: now.addingTimeInterval(600), source: .link)
        state.save(to: store)
        XCTAssertEqual(FocusState.load(from: store, now: now), state)
        // Expired on load: off.
        XCTAssertEqual(FocusState.load(from: store, now: now.addingTimeInterval(601)), .off)
        // Until turned off survives.
        FocusState(level: .urgentOnly).save(to: store)
        XCTAssertNil(store.object(forKey: FocusState.Key.until))
        XCTAssertEqual(FocusState.load(from: store, now: now).level, .urgentOnly)
        store.set("deep-work", forKey: FocusState.Key.level)
        XCTAssertEqual(FocusState.load(from: store, now: now), .off)
    }

    func testSummary() {
        let time: (Date) -> String = { _ in "14:30" }
        XCTAssertNil(FocusState.off.summary(at: now, time: time))
        XCTAssertEqual(FocusState(level: .urgentOnly, until: now.addingTimeInterval(60)).summary(at: now, time: time), "Urgent only until 14:30")
        XCTAssertEqual(FocusState(level: .agentsAndUrgent).summary(at: now, time: time), "Agents and urgent only")
    }
}

final class BypassRuleTests: XCTestCase {
    static var allTests = [
        ("testMatching", testMatching),
        ("testValidation", testValidation),
        ("testCap", testCap),
        ("testDecodingJunk", testDecodingJunk),
        ("testRoundTrip", testRoundTrip),
    ]

    func testMatching() {
        let key = BypassRule(match: .keyPrefix, value: "agent:", action: .alwaysInterrupt)!
        XCTAssertTrue(key.matches(item("a", key: "agent:devbox:1")))
        XCTAssertFalse(key.matches(item("b", key: "work:agent:1")))
        XCTAssertFalse(key.matches(item("c", key: "Agent:devbox:1")), "keys are case-sensitive")

        let agent = BypassRule(match: .agentPrefix, value: "orca:", action: .alwaysLater)!
        XCTAssertTrue(agent.matches(item("d", agent: "ORCA:fixer")))
        XCTAssertFalse(agent.matches(item("e", agent: "claude-code")))
        XCTAssertFalse(agent.matches(item("f")), "no source, no match")

        let host = BypassRule(match: .host, value: " devbox ", action: .neverInterrupt)!
        XCTAssertEqual(host.value, "devbox")
        XCTAssertTrue(host.matches(item("g", host: "DevBox")))
        XCTAssertFalse(host.matches(item("h", host: "devbox2")), "host is exact, not a prefix")
    }

    func testValidation() {
        XCTAssertNil(BypassRule(match: .host, value: "   ", action: .alwaysLater))
        XCTAssertNil(BypassRule(match: .host, value: "dev\nbox", action: .alwaysLater))
        XCTAssertNil(BypassRule(match: .keyPrefix, value: String(repeating: "k", count: BypassRule.maxValueLength + 1), action: .alwaysLater))
        XCTAssertNotNil(BypassRule(match: .keyPrefix, value: String(repeating: "k", count: BypassRule.maxValueLength), action: .alwaysLater))
    }

    func testCap() {
        let many = (0..<80).map { BypassRule(match: .host, value: "h\($0)", action: .alwaysLater)! }
        let book = RuleBook(many)
        XCTAssertEqual(book.rules.count, RuleBook.maxRules)
        XCTAssertTrue(book.isFull)
        XCTAssertEqual(book.rules.last?.value, "h49", "the first 50 are kept, in order")
        XCTAssertEqual(RuleBook.decode(book.encoded()).rules.count, RuleBook.maxRules)
    }

    func testDecodingJunk() {
        XCTAssertTrue(RuleBook.decode(nil).isEmpty)
        XCTAssertTrue(RuleBook.decode(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(RuleBook.decode(Data("{\"rules\": 1}".utf8)).isEmpty)
        let json = """
        [
          {"match": "keyPrefix", "value": "agent:", "action": "alwaysInterrupt"},
          {"match": "title", "value": "x", "action": "alwaysLater"},
          {"match": "host", "value": "", "action": "alwaysLater"},
          {"match": "host", "value": "devbox", "action": "explode"},
          42,
          {"match": "host", "value": "devbox", "action": "neverInterrupt", "note": "unknown fields are ignored"}
        ]
        """
        let book = RuleBook.decode(Data(json.utf8))
        XCTAssertEqual(book.rules.count, 2)
        XCTAssertEqual(book.rules.first?.match, .keyPrefix)
        XCTAssertEqual(book.rules.last?.action, .neverInterrupt)
    }

    func testRoundTrip() {
        let book = RuleBook([
            BypassRule(match: .keyPrefix, value: "work:gh:deploy:", action: .alwaysInterrupt)!,
            BypassRule(match: .agentPrefix, value: "claude-code", action: .neverInterrupt)!,
        ])
        XCTAssertEqual(RuleBook.decode(book.encoded()), book)
        XCTAssertEqual(book.firstMatch(item("x", key: "work:gh:deploy:a/b:1"))?.action, .alwaysInterrupt)
        XCTAssertNil(book.firstMatch(item("y")))
    }
}

final class NoisySenderGuardTests: XCTestCase {
    static var allTests = [
        ("testHoldsAfterThresholdForTheHour", testHoldsAfterThresholdForTheHour),
        ("testSendersAreSeparate", testSendersAreSeparate),
        ("testBounded", testBounded),
        ("testDisplayName", testDisplayName),
    ]

    func testHoldsAfterThresholdForTheHour() {
        var g = NoisySenderGuard()
        let loop = item("x", host: "devbox", agent: "cron:sync")
        for i in 0..<6 {
            XCTAssertTrue(g.admit(loop, now: now.addingTimeInterval(Double(i) * 60)), "interrupt \(i + 1) of 6 is allowed")
        }
        XCTAssertFalse(g.admit(loop, now: now.addingTimeInterval(400)))
        XCTAssertEqual(g.heldSenders(now: now.addingTimeInterval(400)), ["devbox|cron:sync"])
        // Still held just before the first one is an hour old.
        XCTAssertFalse(g.admit(loop, now: now.addingTimeInterval(3599)))
        // Then the window slides.
        XCTAssertTrue(g.admit(loop, now: now.addingTimeInterval(3600)))
        XCTAssertTrue(g.heldSenders(now: now.addingTimeInterval(7300)).isEmpty)
    }

    func testSendersAreSeparate() {
        var g = NoisySenderGuard(threshold: 2)
        let a = item("a", host: "devbox", agent: "one"), b = item("b", host: "devbox", agent: "two")
        XCTAssertTrue(g.admit(a, now: now))
        XCTAssertTrue(g.admit(a, now: now))
        XCTAssertFalse(g.admit(a, now: now))
        XCTAssertTrue(g.admit(b, now: now))
    }

    func testBounded() {
        var g = NoisySenderGuard()
        for i in 0..<(NoisySenderGuard.maxSenders + 50) {
            _ = g.admit(item("s\(i)", host: "h\(i)"), now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(g.trackedSenderCount, NoisySenderGuard.maxSenders)
        _ = g.admit(item("late", host: "late"), now: now.addingTimeInterval(7200))
        XCTAssertEqual(g.trackedSenderCount, 1, "an hour later the old ones are gone")
    }

    func testDisplayName() {
        XCTAssertEqual(NoisySenderGuard.displayName("devbox|cron:sync"), "devbox · cron:sync")
        XCTAssertEqual(NoisySenderGuard.displayName("devbox|"), "devbox")
        XCTAssertEqual(NoisySenderGuard.displayName("|"), "an unnamed sender")
    }
}
