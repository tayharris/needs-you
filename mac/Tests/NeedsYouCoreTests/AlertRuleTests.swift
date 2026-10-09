#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func agentItem(_ id: String, _ priority: ItemPriority = .normal, key: String = "agent:devbox:s1",
                       agent: String? = "claude-code", event: String? = nil, kind: ItemKind = .needs) -> Item {
    Item(id: id, key: key, kind: kind, priority: priority, title: id,
         source: ItemSource(host: "devbox", agent: agent, event: event), createdAt: t0)
}

private func rule(_ match: BypassMatch, _ value: String, _ action: BypassAction, event: String? = nil) -> BypassRule {
    BypassRule(match: match, value: value, action: action, event: event)!
}

/// `source.event`, the session match, the event qualifier, and "Treat as urgent"/"Treat as
/// low" (RuleBook.effectivePriority) all the way to the delivery tier and the store.
final class SessionRuleTests: XCTestCase {
    static var allTests = [
        ("testSourceEventDecoding", testSourceEventDecoding),
        ("testOldRulesDecodeUnchanged", testOldRulesDecodeUnchanged),
        ("testNewRulesRoundTripAndBadOnesAreSkipped", testNewRulesRoundTripAndBadOnesAreSkipped),
        ("testSessionMatch", testSessionMatch),
        ("testEventQualifier", testEventQualifier),
        ("testEffectivePriority", testEffectivePriority),
        ("testAppliedIsIdempotent", testAppliedIsIdempotent),
        ("testTreatAsUrgentDelivers", testTreatAsUrgentDelivers),
        ("testTreatAsLowDelivers", testTreatAsLowDelivers),
        ("testStoreAppliesRules", testStoreAppliesRules),
    ]

    func testSourceEventDecoding() throws {
        let json = """
        [{"id": "a", "key": "agent:devbox:s1", "title": "t", "created_at": "2026-10-09T10:00:00Z",
          "source": {"host": "devbox", "agent": "claude-code", "event": "question", "mood": "x"}},
         {"id": "b", "title": "t", "created_at": "2026-10-09T10:00:00Z", "source": {"host": "devbox", "event": 3}},
         {"id": "c", "title": "t", "created_at": "2026-10-09T10:00:00Z", "source": {"event": "Not a slug"}},
         {"id": "d", "title": "t", "created_at": "2026-10-09T10:00:00Z", "source": {"agent": ["x"], "event": "compacted"}},
         {"id": "e", "title": "t", "created_at": "2026-10-09T10:00:00Z"}]
        """
        let items = try HubJSON.decodeItemList(Data(json.utf8))
        XCTAssertEqual(items.count, 5, "a bad source field never costs the item")
        XCTAssertEqual(items[0].source?.event, "question")
        XCTAssertEqual(items[0].source?.agent, "claude-code")
        XCTAssertNil(items[1].source?.event)
        XCTAssertEqual(items[1].source?.host, "devbox")
        XCTAssertNil(items[2].source?.event)
        XCTAssertEqual(items[3].source?.event, "compacted", "events outside the documented ones are kept as sent")
        XCTAssertNil(items[3].source?.agent)
        XCTAssertNil(items[4].source)
    }

    func testOldRulesDecodeUnchanged() {
        // What 0.3.1 stored: no event, the three old actions and matches.
        let json = """
        [{"action":"alwaysInterrupt","match":"keyPrefix","value":"agent:"},
         {"action":"neverInterrupt","match":"agentPrefix","value":"orca:"},
         {"action":"alwaysLater","match":"host","value":"devbox"}]
        """
        let book = RuleBook.decode(Data(json.utf8))
        XCTAssertEqual(book.rules.count, 3)
        XCTAssertTrue(book.rules.allSatisfy { $0.event == nil })
        XCTAssertEqual(book.rules.map(\.action), [.alwaysInterrupt, .neverInterrupt, .alwaysLater])
        // and they encode back the same way: no "event" key for a rule without one
        let text = String(data: book.encoded()!, encoding: .utf8)!
        XCTAssertFalse(text.contains("event"), text)
        XCTAssertEqual(text, json.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: ""))
    }

    func testNewRulesRoundTripAndBadOnesAreSkipped() {
        let book = RuleBook([
            rule(.session, "agent:devbox:s1", .urgent, event: "finished"),
            rule(.keyPrefix, "agent:", .urgent, event: "question"),
            rule(.agentPrefix, "codex", .low),
        ])
        XCTAssertEqual(RuleBook.decode(book.encoded()), book)
        let json = """
        [{"match": "session", "value": "agent:devbox:s1", "action": "urgent", "event": "failed"},
         {"match": "session", "value": "agent:devbox:s2", "action": "urgent", "event": "Not A Slug"},
         {"match": "session", "value": "agent:devbox:s3", "action": "shout"},
         {"match": "window", "value": "x", "action": "urgent"},
         {"match": "keyPrefix", "value": "agent:", "action": "low", "event": ""}]
        """
        let decoded = RuleBook.decode(Data(json.utf8))
        XCTAssertEqual(decoded.rules.count, 2)
        XCTAssertEqual(decoded.rules[0].event, "failed")
        XCTAssertNil(decoded.rules[1].event, "an empty event is any event")
        XCTAssertNil(BypassRule(match: .host, value: "devbox", action: .urgent, event: "two words"))
        XCTAssertEqual(BypassRule(match: .host, value: "devbox", action: .urgent, event: " Question ")?.event, "question")
    }

    func testSessionMatch() {
        let r = rule(.session, "agent:devbox:s1", .urgent)
        XCTAssertTrue(r.matches(agentItem("a")))
        XCTAssertTrue(r.matches(agentItem("b", key: "agent:devbox:s1:context")), "the session's context card")
        XCTAssertFalse(r.matches(agentItem("c", key: "agent:devbox:s10")), "not a prefix of another session")
        XCTAssertFalse(r.matches(agentItem("d", key: "agent:devbox:s2")))
        XCTAssertFalse(r.matches(agentItem("e", key: "agent:devbox")))
    }

    func testEventQualifier() {
        let r = rule(.agentPrefix, "claude-code", .urgent, event: "question")
        XCTAssertTrue(r.matches(agentItem("a", event: "question")))
        XCTAssertFalse(r.matches(agentItem("b", event: "finished")))
        XCTAssertFalse(r.matches(agentItem("c")), "no event: a rule for one event doesn't match")
        XCTAssertFalse(r.matches(agentItem("d", agent: "codex", event: "question")))
        XCTAssertTrue(rule(.agentPrefix, "claude-code", .urgent).matches(agentItem("e", event: "finished")), "nil: any")
    }

    func testEffectivePriority() {
        let book = RuleBook([
            rule(.session, "agent:devbox:s1", .urgent, event: "finished"),
            rule(.session, "agent:devbox:s1", .neverInterrupt),
            rule(.keyPrefix, "agent:", .urgent, event: "failed"),
            rule(.agentPrefix, "codex", .low),
        ])
        XCTAssertEqual(book.effectivePriority(agentItem("a", event: "finished")), .urgent)
        XCTAssertEqual(book.effectivePriority(agentItem("b", event: "question")), .normal,
                       "first match is neverInterrupt: the sender's priority")
        XCTAssertEqual(book.effectivePriority(agentItem("c", key: "agent:devbox:s9", event: "failed")), .urgent)
        XCTAssertEqual(book.effectivePriority(agentItem("d", .urgent, key: "agent:devbox:s9", agent: "codex")), .low)
        XCTAssertEqual(book.effectivePriority(agentItem("e", .low, key: "work:x:y", agent: nil)), .low, "no rule")
        XCTAssertEqual(RuleBook().effectivePriority(agentItem("f", .urgent)), .urgent)
    }

    func testAppliedIsIdempotent() {
        let urgent = RuleBook([rule(.session, "agent:devbox:s1", .urgent)])
        let a = urgent.applied(to: agentItem("a", .low))
        XCTAssertEqual(a.priority, .urgent)
        XCTAssertEqual(a.senderPriority, .low)
        XCTAssertEqual(urgent.applied(to: a), a)
        // the rule removed: back to the sender's
        let back = RuleBook().applied(to: a)
        XCTAssertEqual(back.priority, .low)
        XCTAssertEqual(back.senderPriority, .low)
        // never encoded: what goes back to a hub is the wire item only
        let data = try! HubJSON.makeEncoder().encode(a)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("senderPriority"))
    }

    private func decide(_ item: Item, _ rules: [BypassRule], focus: FocusLevel = .off,
                        visibility: PanelVisibility = .shown) -> DeliveryDecision {
        DeliveryPolicy.decide(item, state: DeliveryState(context: .work, visibility: visibility, focus: focus,
                                                         rules: RuleBook(rules), now: t0))
    }

    func testTreatAsUrgentDelivers() {
        let rules = [rule(.session, "agent:devbox:s1", .urgent, event: "finished")]
        let finished = agentItem("a", event: "finished")
        // Under Urgent only, a normal card waits; treated as urgent, it interrupts.
        XCTAssertEqual(decide(finished, [], focus: .urgentOnly).tier, .later)
        XCTAssertEqual(decide(finished, rules, focus: .urgentOnly).tier, .interrupt)
        // Snoozed: urgent breaks through (the default)
        let snoozed = PanelVisibility.snoozed(until: t0.addingTimeInterval(600))
        XCTAssertEqual(decide(finished, rules, visibility: snoozed).tier, .interrupt)
        // Everything later still holds it, as it holds a sender's urgent
        XCTAssertEqual(decide(finished, rules, focus: .everythingLater).tier, .later)
        // another session, or another event: untouched
        XCTAssertEqual(decide(agentItem("b", key: "agent:devbox:s2", event: "finished"), rules, focus: .urgentOnly).tier, .later)
        XCTAssertEqual(decide(agentItem("c", event: "question"), rules, focus: .urgentOnly).tier, .later)
        // an item already applied gives the same answer
        XCTAssertEqual(decide(RuleBook(rules).applied(to: finished), rules, focus: .urgentOnly).tier, .interrupt)
    }

    func testTreatAsLowDelivers() {
        var defaults = DeliveryDefaults()
        defaults.low = .later
        let rules = [rule(.agentPrefix, "claude-code", .low)]
        let state = DeliveryState(context: .work, defaults: defaults, rules: RuleBook(rules), now: t0)
        XCTAssertEqual(DeliveryPolicy.decide(agentItem("a", .urgent), state: state).tier, .later)
        XCTAssertEqual(DeliveryPolicy.decide(agentItem("b", .urgent, agent: "codex"), state: state).tier, .interrupt)
    }

    func testStoreAppliesRules() {
        var store = ItemStore()
        let rules = RuleBook([rule(.session, "agent:devbox:s1", .urgent)])
        _ = store.merge([agentItem("a"), agentItem("b", key: "agent:devbox:s2")].map { rules.applied(to: $0) },
                        isFullSnapshot: true, now: t0)
        XCTAssertEqual(store.highestPriority(in: .work, now: t0), .urgent)
        XCTAssertEqual(store.needs(in: .work, now: t0).first?.id, "a", "sorted as urgent")
        // The same poll again: nothing changed
        let again = store.merge([agentItem("a"), agentItem("b", key: "agent:devbox:s2")].map { rules.applied(to: $0) },
                                isFullSnapshot: true, now: t0)
        XCTAssertTrue(again.changed.isEmpty)
        // The rule removed: back to normal at once
        XCTAssertTrue(store.applyRules(RuleBook()))
        XCTAssertEqual(store.highestPriority(in: .work, now: t0), .normal)
        XCTAssertFalse(store.applyRules(RuleBook()), "nothing left to change")
    }
}

/// The card's "Alerts for This Session" / "Alerts for All <agent> Sessions" menus.
final class AlertRuleMenuTests: XCTestCase {
    static var allTests = [
        ("testScopes", testScopes),
        ("testChooseTogglesAndGoesToTheTop", testChooseTogglesAndGoesToTheTop),
        ("testEventsAreSeparateRules", testEventsAreSeparateRules),
        ("testRemoveAllAndSummary", testRemoveAllAndSummary),
        ("testFullBook", testFullBook),
        ("testEventRuleOutranksAnAnyEventRuleChosenLater", testEventRuleOutranksAnAnyEventRuleChosenLater),
        ("testSessionOutranksAgent", testSessionOutranksAgent),
        ("testMostRecentFirstAmongEquals", testMostRecentFirstAmongEquals),
        ("testShadowedRuleIsNotShownAsActive", testShadowedRuleIsNotShownAsActive),
    ]

    /// "Only When It Asks → Treat as Urgent", then "Always Interrupt" for the same session:
    /// the question rule still applies to questions (first match wins, so it stays above).
    func testEventRuleOutranksAnAnyEventRuleChosenLater() {
        let scope = RuleScope.session("agent:devbox:s1")
        let asks = rule(.session, "agent:devbox:s1", .urgent, event: "question")
        let any = rule(.session, "agent:devbox:s1", .alwaysInterrupt)
        for order in [[("question" as String?), nil], [nil, "question"]] {
            var book = RuleBook()
            for event in order {
                book = AlertRuleMenu.choosing(event == nil ? .alwaysInterrupt : .urgent, in: book, scope, event: event)
            }
            XCTAssertEqual(book.rules, [asks, any], "chosen \(order)")
            let question = agentItem("q", event: "question")
            XCTAssertEqual(book.effectivePriority(question), .urgent)
            XCTAssertEqual(book.firstMatch(question)?.action, .urgent)
            XCTAssertEqual(book.firstMatch(agentItem("f", event: "finished"))?.action, .alwaysInterrupt)
            XCTAssertEqual(book.effectivePriority(agentItem("f", event: "finished")), .normal)
            XCTAssertEqual(AlertRuleMenu.current(book, scope, event: "question"), .urgent)
            XCTAssertEqual(AlertRuleMenu.current(book, scope, event: nil), .alwaysInterrupt)
            XCTAssertEqual(AlertRuleMenu.summary(book, scope), "Treat as urgent when it asks; Always interrupt")
        }
    }

    /// A session's rules sit above its agent's, whichever came first; within the agent scope,
    /// an event rule above the any-event one.
    func testSessionOutranksAgent() {
        let session = RuleScope.session("agent:devbox:s1")
        let agent = RuleScope.agent("claude-code")
        var book = AlertRuleMenu.choosing(.urgent, in: RuleBook(), agent, event: nil)
        book = AlertRuleMenu.choosing(.alwaysInterrupt, in: book, agent, event: "question")
        book = AlertRuleMenu.choosing(.neverInterrupt, in: book, session, event: nil)
        book = AlertRuleMenu.choosing(.alwaysLater, in: book, session, event: "finished")
        XCTAssertEqual(book.rules, [
            rule(.session, "agent:devbox:s1", .alwaysLater, event: "finished"),
            rule(.session, "agent:devbox:s1", .neverInterrupt),
            rule(.agentPrefix, "claude-code", .alwaysInterrupt, event: "question"),
            rule(.agentPrefix, "claude-code", .urgent),
        ])
        XCTAssertEqual(book.firstMatch(agentItem("a"))?.action, .neverInterrupt, "this session")
        XCTAssertEqual(book.effectivePriority(agentItem("a")), .normal)
        XCTAssertEqual(book.firstMatch(agentItem("b", key: "agent:devbox:s2", event: "question"))?.action, .alwaysInterrupt)
        XCTAssertEqual(book.effectivePriority(agentItem("c", key: "agent:devbox:s2")), .urgent, "another session")
        // An agent rule chosen last still goes below the session's.
        book = AlertRuleMenu.choosing(.low, in: book, agent, event: nil)
        XCTAssertEqual(book.rules[2], rule(.agentPrefix, "claude-code", .alwaysInterrupt, event: "question"))
        XCTAssertEqual(book.rules[3], rule(.agentPrefix, "claude-code", .low))
    }

    /// Equal rank: the latest first. Rules the menu doesn't make (Settings' key prefixes,
    /// hosts) stay below card-made ones.
    func testMostRecentFirstAmongEquals() {
        let manual = rule(.keyPrefix, "agent:", .alwaysLater)
        var book = RuleBook([manual])
        book = AlertRuleMenu.choosing(.urgent, in: book, .session("agent:devbox:s1"), event: nil)
        book = AlertRuleMenu.choosing(.low, in: book, .session("agent:devbox:s2"), event: nil)
        XCTAssertEqual(book.rules, [rule(.session, "agent:devbox:s2", .low), rule(.session, "agent:devbox:s1", .urgent), manual])
        book = AlertRuleMenu.choosing(.urgent, in: book, .agent("codex"), event: nil)
        XCTAssertEqual(book.rules.last, manual)
        XCTAssertEqual(book.rules[2], rule(.agentPrefix, "codex", .urgent))
    }

    /// A book ordered by hand in Settings can put an any-event rule above the same scope's
    /// event rule: that one never applies, so the menu doesn't check it or list it, and
    /// choosing it again puts it where it applies.
    func testShadowedRuleIsNotShownAsActive() {
        let scope = RuleScope.session("agent:devbox:s1")
        let any = rule(.session, "agent:devbox:s1", .alwaysInterrupt)
        let asks = rule(.session, "agent:devbox:s1", .urgent, event: "question")
        var book = RuleBook([any, asks])
        XCTAssertEqual(book.effectivePriority(agentItem("q", event: "question")), .normal, "shadowed")
        XCTAssertNil(AlertRuleMenu.current(book, scope, event: "question"))
        XCTAssertEqual(AlertRuleMenu.summary(book, scope), "Always interrupt")
        XCTAssertTrue(AlertRuleMenu.hasRules(book, scope))
        book = AlertRuleMenu.choosing(.urgent, in: book, scope, event: "question")
        XCTAssertEqual(book.rules, [asks, any], "re-placed, not removed")
        XCTAssertEqual(book.effectivePriority(agentItem("q", event: "question")), .urgent)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: "question"), .urgent)
    }

    func testScopes() {
        XCTAssertEqual(RuleScope.scopes(for: agentItem("a")), [.session("agent:devbox:s1"), .agent("claude-code")])
        XCTAssertEqual(RuleScope.scopes(for: agentItem("b", key: "agent:devbox:s1:context")),
                       [.session("agent:devbox:s1"), .agent("claude-code")], "the context card is the session's")
        XCTAssertEqual(RuleScope.scopes(for: agentItem("c", agent: nil)), [.session("agent:devbox:s1")])
        XCTAssertEqual(RuleScope.scopes(for: agentItem("d", agent: "  ")), [.session("agent:devbox:s1")])
        XCTAssertEqual(RuleScope.scopes(for: agentItem("e", key: "work:ACME-1:deploy")), [], "not an agent card")
        XCTAssertEqual(RuleScope.scopes(for: agentItem("f", key: "agent:devbox")), [])
        XCTAssertEqual(RuleScope.agent("codex").menuTitle, "Alerts for All codex Sessions")
        XCTAssertEqual(RuleScope.session("agent:devbox:s1").menuTitle, "Alerts for This Session")
    }

    func testChooseTogglesAndGoesToTheTop() {
        let scope = RuleScope.session("agent:devbox:s1")
        let existing = rule(.keyPrefix, "agent:", .alwaysLater)
        var book = RuleBook([existing])
        XCTAssertNil(AlertRuleMenu.current(book, scope, event: nil))
        book = AlertRuleMenu.choosing(.urgent, in: book, scope, event: nil)
        XCTAssertEqual(book.rules.first, rule(.session, "agent:devbox:s1", .urgent), "first: it wins over the rest")
        XCTAssertEqual(book.rules.last, existing)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: nil), .urgent)
        XCTAssertEqual(book.effectivePriority(agentItem("a")), .urgent)
        // another action replaces it
        book = AlertRuleMenu.choosing(.neverInterrupt, in: book, scope, event: nil)
        XCTAssertEqual(book.rules.count, 2)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: nil), .neverInterrupt)
        // the checked one again removes it
        book = AlertRuleMenu.choosing(.neverInterrupt, in: book, scope, event: nil)
        XCTAssertEqual(book.rules, [existing])
    }

    func testEventsAreSeparateRules() {
        let scope = RuleScope.agent("claude-code")
        var book = AlertRuleMenu.choosing(.urgent, in: RuleBook(), scope, event: "question")
        book = AlertRuleMenu.choosing(.alwaysLater, in: book, scope, event: "finished")
        XCTAssertEqual(book.rules.count, 2)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: "question"), .urgent)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: "finished"), .alwaysLater)
        XCTAssertNil(AlertRuleMenu.current(book, scope, event: nil))
        XCTAssertNil(AlertRuleMenu.current(book, .session("agent:devbox:s1"), event: "question"), "scopes are separate")
        XCTAssertEqual(book.effectivePriority(agentItem("a", event: "question")), .urgent)
        XCTAssertEqual(book.effectivePriority(agentItem("b", event: "failed")), .normal)
    }

    func testRemoveAllAndSummary() {
        let scope = RuleScope.session("agent:devbox:s1")
        let other = rule(.session, "agent:devbox:s2", .urgent)
        var book = RuleBook([other])
        XCTAssertFalse(AlertRuleMenu.hasRules(book, scope))
        XCTAssertNil(AlertRuleMenu.summary(book, scope))
        book = AlertRuleMenu.choosing(.urgent, in: book, scope, event: "question")
        book = AlertRuleMenu.choosing(.alwaysInterrupt, in: book, scope, event: nil)
        XCTAssertTrue(AlertRuleMenu.hasRules(book, scope))
        XCTAssertEqual(AlertRuleMenu.summary(book, scope), "Treat as urgent when it asks; Always interrupt",
                       "in the order they apply")
        book = AlertRuleMenu.removingAll(in: book, scope)
        XCTAssertEqual(book.rules, [other])
    }

    func testFullBook() {
        let scope = RuleScope.session("agent:devbox:s1")
        let many = (0..<(RuleBook.maxRules - 1)).map { rule(.host, "h\($0)", .alwaysLater) }
        var book = AlertRuleMenu.choosing(.urgent, in: RuleBook(many), scope, event: nil)
        XCTAssertTrue(book.isFull)
        XCTAssertTrue(AlertRuleMenu.canChoose(book, scope, event: nil), "replacing its own rule is fine")
        XCTAssertFalse(AlertRuleMenu.canChoose(book, scope, event: "question"))
        let unchanged = AlertRuleMenu.choosing(.urgent, in: book, scope, event: "question")
        XCTAssertEqual(unchanged.rules.count, RuleBook.maxRules)
        XCTAssertNil(AlertRuleMenu.current(unchanged, scope, event: "question"), "nothing dropped to make room")
        book = AlertRuleMenu.choosing(.alwaysLater, in: book, scope, event: nil)
        XCTAssertEqual(AlertRuleMenu.current(book, scope, event: nil), .alwaysLater)
        XCTAssertEqual(book.rules.last?.value, "h\(RuleBook.maxRules - 2)", "the others kept, in order")
    }
}
