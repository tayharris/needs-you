#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Setup tips: which apply, which are done for good, and what the cards say and link to.
final class SetupChecklistTests: XCTestCase {
    static var allTests = [
        ("testNoHubShowsTurnOnHub", testNoHubShowsTurnOnHub),
        ("testRunningHubWithoutSendersShowsConnect", testRunningHubWithoutSendersShowsConnect),
        ("testConnectWaitsForAPollAndAnInviteToken", testConnectWaitsForAPollAndAnInviteToken),
        ("testLoopbackOnlyWithOtherMachinesShowsTailscale", testLoopbackOnlyWithOtherMachinesShowsTailscale),
        ("testClaudeHooksAfterFirstSender", testClaudeHooksAfterFirstSender),
        ("testDoneAndDismissedTipsStayAway", testDoneAndDismissedTipsStayAway),
        ("testSatisfiedIsRecordedForGood", testSatisfiedIsRecordedForGood),
        ("testDemoAndDisabledShowNothing", testDemoAndDisabledShowNothing),
        ("testCardsLookLikeLocalNeedsItems", testCardsLookLikeLocalNeedsItems),
        ("testCardTextNeverHoldsInviteDetails", testCardTextNeverHoldsInviteDetails),
        ("testGuideLinksAreAllowedHttps", testGuideLinksAreAllowedHttps),
        ("testLoopbackDetection", testLoopbackDetection),
        ("testOtherHosts", testOtherHosts),
        ("testClaudeHookDetection", testClaudeHookDetection),
        ("testHubNotAnsweringOffersARestart", testHubNotAnsweringOffersARestart),
    ]

    func testHubNotAnsweringOffersARestart() {
        let stuck = state { $0.hasHub = true; $0.localHub = .notAnswering }
        XCTAssertEqual(SetupChecklist.pending(stuck), [.restartHub])
        // It's the hub's state, not a tip: setup tips off or an old dismissal don't hide it,
        // and it's never recorded as done.
        XCTAssertEqual(SetupChecklist.pending(state { $0.hasHub = true; $0.localHub = .notAnswering; $0.enabled = false }), [.restartHub])
        XCTAssertEqual(SetupChecklist.pending(state {
            $0.hasHub = true; $0.localHub = .notAnswering; $0.closed = [SetupTip.restartHub.rawValue]
        }), [.restartHub])
        XCTAssertFalse(SetupChecklist.satisfied(freshHub()).contains(.restartHub))
        XCTAssertFalse(SetupChecklist.pending(freshHub()).contains(.restartHub))
        XCTAssertEqual(SetupChecklist.pending(state { $0.localHub = .notAnswering; $0.isDemo = true }), [])
        // It comes first, with a Restart button that runs in place (no focus), and no Dismiss.
        let cards = SetupChecklist.cards(state: state { $0.hasHub = true; $0.hubReachable = true; $0.canInvite = true
            $0.localHub = .notAnswering })
        XCTAssertEqual(cards.first?.tip, .restartHub)
        XCTAssertEqual(cards.first?.buttons.map(\.action), [.restartLocalHub, .openSettings(.thisMac)])
        XCTAssertEqual(cards.first?.dismissible, false)
        XCTAssertEqual(SetupChecklist.card(.connectSender, state: stuck).dismissible, true)
    }

    private func state(_ configure: (inout SetupState) -> Void = { _ in }) -> SetupState {
        var s = SetupState()
        s.now = Date(timeIntervalSince1970: 1_800_000_000)
        configure(&s)
        return s
    }

    /// A Mac running its own hub, polled once, able to invite, nothing posted yet.
    private func freshHub(_ configure: (inout SetupState) -> Void = { _ in }) -> SetupState {
        state { s in
            s.hasHub = true
            s.hubReachable = true
            s.localHub = .running(loopbackOnly: false)
            s.canInvite = true
            configure(&s)
        }
    }

    func testNoHubShowsTurnOnHub() {
        XCTAssertEqual(SetupChecklist.pending(state()), [.turnOnHub])
        // The local hub is on but still starting: no tip about turning it on.
        XCTAssertEqual(SetupChecklist.pending(state { $0.localHub = .notReady }), [])
        XCTAssertFalse(SetupChecklist.pending(freshHub()).contains(.turnOnHub))
    }

    func testRunningHubWithoutSendersShowsConnect() {
        XCTAssertEqual(SetupChecklist.pending(freshHub()), [.connectSender])
        XCTAssertEqual(SetupChecklist.pending(freshHub { $0.senderSeen = true }), [])
    }

    func testConnectWaitsForAPollAndAnInviteToken() {
        XCTAssertEqual(SetupChecklist.pending(freshHub { $0.hubReachable = false }), [])
        XCTAssertEqual(SetupChecklist.pending(freshHub { $0.canInvite = false }), [])
    }

    func testLoopbackOnlyWithOtherMachinesShowsTailscale() {
        let lonely = freshHub { $0.senderSeen = true; $0.localHub = .running(loopbackOnly: true) }
        XCTAssertEqual(SetupChecklist.pending(lonely), [])
        var others = lonely
        others.hasOtherMachines = true
        XCTAssertEqual(SetupChecklist.pending(others), [.reachFromOtherMachines])
        var forced = others
        forced.loopbackForced = true
        XCTAssertEqual(SetupChecklist.pending(forced), [])
        var tailnet = others
        tailnet.localHub = .running(loopbackOnly: false)
        XCTAssertEqual(SetupChecklist.pending(tailnet), [])
    }

    func testClaudeHooksAfterFirstSender() {
        XCTAssertEqual(SetupChecklist.pending(freshHub { $0.claudeCodeInstalled = true }), [.connectSender])
        let connected = freshHub { $0.claudeCodeInstalled = true; $0.senderSeen = true }
        XCTAssertEqual(SetupChecklist.pending(connected), [.claudeHooks])
        var hooked = connected
        hooked.claudeHooksInstalled = true
        XCTAssertEqual(SetupChecklist.pending(hooked), [])
        var noClaude = connected
        noClaude.claudeCodeInstalled = false
        XCTAssertEqual(SetupChecklist.pending(noClaude), [])
        // Without an owner token there's no prompt to copy; the guide link stays.
        var reader = connected
        reader.canInvite = false
        let card = SetupChecklist.card(.claudeHooks, state: reader)
        XCTAssertTrue(card.buttons.isEmpty)
        XCTAssertFalse(card.item.links.isEmpty)
    }

    func testDoneAndDismissedTipsStayAway() {
        XCTAssertEqual(SetupChecklist.pending(state { $0.closed = ["hub"] }), [])
        XCTAssertEqual(SetupChecklist.pending(freshHub { $0.closed = [SetupTip.connectSender.rawValue] }), [])
        // Unknown stored ids are ignored.
        XCTAssertEqual(SetupChecklist.pending(state { $0.closed = ["something-else"] }), [.turnOnHub])
    }

    func testSatisfiedIsRecordedForGood() {
        let s = freshHub { $0.senderSeen = true; $0.claudeHooksInstalled = true }
        XCTAssertEqual(SetupChecklist.satisfied(s), [.turnOnHub, .connectSender, .reachFromOtherMachines, .claudeHooks])
        XCTAssertEqual(SetupChecklist.satisfied(state()), [])
        // Loopback only isn't "reachable from other machines".
        XCTAssertFalse(SetupChecklist.satisfied(freshHub { $0.localHub = .running(loopbackOnly: true) }).contains(.reachFromOtherMachines))
        // Demo data proves nothing about the real setup.
        XCTAssertEqual(SetupChecklist.satisfied(freshHub { $0.isDemo = true; $0.senderSeen = true }), [])
    }

    func testDemoAndDisabledShowNothing() {
        XCTAssertEqual(SetupChecklist.pending(state { $0.isDemo = true }), [])
        XCTAssertEqual(SetupChecklist.pending(state { $0.enabled = false }), [])
        XCTAssertEqual(SetupChecklist.cards(state: state { $0.enabled = false }), [])
    }

    func testCardsLookLikeLocalNeedsItems() {
        let s = state { $0.context = .personal }
        let cards = SetupChecklist.cards(state: s)
        XCTAssertEqual(cards.count, 1)
        let item = cards[0].item
        XCTAssertEqual(item.kind, .needs)
        XCTAssertEqual(item.priority, .normal)
        XCTAssertEqual(item.context, .personal)
        XCTAssertEqual(item.status, .open)
        XCTAssertEqual(item.source?.host, SetupChecklist.sourceName)
        XCTAssertEqual(item.createdAt, s.now)
        XCTAssertEqual(SetupChecklist.tip(forItemID: item.id), .turnOnHub)
        XCTAssertNil(SetupChecklist.tip(forItemID: "01HXYZ"))
        XCTAssertNil(SetupChecklist.tip(forItemID: SetupChecklist.idPrefix + "nope"))
        XCTAssertEqual(cards[0].buttons.map(\.action), [.openSettings(.thisMac)])
        for tip in SetupTip.allCases {
            let priority = SetupChecklist.card(tip, state: s).item.priority
            XCTAssertTrue(priority == .low || priority == .normal, "\(tip) is \(priority)")
        }
        XCTAssertEqual(SetupChecklist.card(.connectSender, state: s).buttons.map(\.action), [.copyAgentPrompt])
    }

    func testCardTextNeverHoldsInviteDetails() {
        let s = freshHub()
        for tip in SetupTip.allCases {
            let item = SetupChecklist.card(tip, state: s).item
            let text = [item.title, item.body ?? ""] + item.links.map(\.url)
            for part in text {
                XCTAssertFalse(part.contains("nyi_"), "\(tip): \(part)")
                XCTAssertFalse(part.contains("/join/"), "\(tip): \(part)")
                XCTAssertFalse(part.contains("needsyou://connect"), "\(tip): \(part)")
            }
        }
    }

    func testGuideLinksAreAllowedHttps() {
        XCTAssertEqual(SetupChecklist.guideURL("tailscale.md", repository: "acme/needs-you"),
                       "https://github.com/acme/needs-you/blob/main/docs/guides/tailscale.md")
        XCTAssertTrue(SetupChecklist.guideURL("quickstart.md").hasPrefix("https://github.com/\(UpdateSource.defaultRepository)/"))
        let s = freshHub()
        for tip in SetupTip.allCases {
            for link in SetupChecklist.card(tip, state: s).item.links {
                XCTAssertTrue(LinkPolicy.isAllowed(link.url), link.url)
                XCTAssertTrue(link.url.hasPrefix("https://"), link.url)
            }
        }
    }

    func testLoopbackDetection() {
        XCTAssertTrue(SetupChecklist.isLoopbackOnly(publicURL: "http://127.0.0.1:8765"))
        XCTAssertTrue(SetupChecklist.isLoopbackOnly(publicURL: "http://localhost:8765"))
        XCTAssertFalse(SetupChecklist.isLoopbackOnly(publicURL: "http://hub-a.example.ts.net:8765"))
        XCTAssertFalse(SetupChecklist.isLoopbackOnly(publicURL: "http://100.64.0.7:8765"))
        XCTAssertFalse(SetupChecklist.isLoopbackOnly(publicURL: "not a url"))
    }

    func testOtherHosts() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ host: String?) -> Item {
            Item(id: UUID().uuidString, key: "k", title: "t", source: ItemSource(host: host), createdAt: date)
        }
        XCTAssertFalse(SetupChecklist.hasOtherHosts([], localHost: "Studio-Mac"))
        XCTAssertFalse(SetupChecklist.hasOtherHosts([item("studio-mac"), item("Studio-Mac.local"), item(nil), item("  ")], localHost: "Studio-Mac"))
        XCTAssertTrue(SetupChecklist.hasOtherHosts([item("studio-mac"), item("devbox")], localHost: "Studio-Mac"))
        // A setup card's "host" is its source label, not a machine.
        let setup = SetupChecklist.card(.turnOnHub, state: state()).item
        XCTAssertFalse(SetupChecklist.hasOtherHosts([setup], localHost: "Studio-Mac"))
    }

    func testClaudeHookDetection() throws {
        XCTAssertFalse(SetupChecklist.referencesNeedsYouHook(settingsJSON: nil))
        XCTAssertFalse(SetupChecklist.referencesNeedsYouHook(settingsJSON: "{\"hooks\": {}}"))
        XCTAssertTrue(SetupChecklist.referencesNeedsYouHook(settingsJSON: "{\"command\": \"\\\"$HOME/.claude/hooks/needs-you-hook.sh\\\" notify\"}"))

        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("setup-tips-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        XCTAssertFalse(SetupChecklist.claudeCode(home: home).installed)
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        var facts = SetupChecklist.claudeCode(home: home)
        XCTAssertTrue(facts.installed)
        XCTAssertFalse(facts.hooks)
        let settings = claude.appendingPathComponent("settings.json")
        try Data("{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"$HOME/.claude/hooks/needs-you-hook.sh stop\"}]}]}}".utf8).write(to: settings)
        facts = SetupChecklist.claudeCode(home: home)
        XCTAssertTrue(facts.installed)
        XCTAssertTrue(facts.hooks)
    }
}
