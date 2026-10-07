#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)

final class FocusLinkTests: XCTestCase {
    static var allTests = [
        ("testParsesEveryLevel", testParsesEveryLevel),
        ("testDurationsAreClamped", testDurationsAreClamped),
        ("testUntilTomorrow", testUntilTomorrow),
        ("testRejectsOtherShapes", testRejectsOtherShapes),
        ("testStateAndRoundTrip", testStateAndRoundTrip),
        ("testConfirmation", testConfirmation),
        ("testLinkFocusNeverHoldsBackUrgent", testLinkFocusNeverHoldsBackUrgent),
        ("testCardsCantOpenIt", testCardsCantOpenIt),
    ]

    func testParsesEveryLevel() {
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=off")?.level, .off)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents")?.level, .agentsAndUrgent)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=urgent")?.level, .urgentOnly)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=later")?.level, .everythingLater)
        XCTAssertEqual(FocusLink.parse("NEEDSYOU://FOCUS/?level=Urgent")?.level, .urgentOnly)
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=off")?.duration)
    }

    func testDurationsAreClamped() {
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=urgent&minutes=60")?.duration, .minutes(60))
        XCTAssertEqual(FocusLink.parse("needsyou://focus?minutes=1&level=later")?.duration, .minutes(1))
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents&minutes=720")?.duration, .minutes(720))
        // Longer asks are cut to 12 h, and no duration is 12 h, never "until turned off".
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents&minutes=721")?.duration, .minutes(720))
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents&minutes=9999")?.duration, .minutes(720))
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=later")?.duration, .minutes(FocusLink.maxMinutes))
        XCTAssertEqual(FocusLink(level: .urgentOnly, duration: .minutes(100_000)).duration, .minutes(720))
        XCTAssertEqual(FocusLink(level: .urgentOnly, duration: .minutes(-3)).duration, .minutes(1))
        for bad in ["0", "10000", "-5", "+5", "1.5", "60m", "", "１"] {
            XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&minutes=\(bad)"), bad)
        }
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=off&minutes=30"), "off takes no duration")
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&minutes=30&minutes=60"))
    }

    func testUntilTomorrow() {
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=urgent&until=tomorrow")?.duration, .untilTomorrow)
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&until=friday"))
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&until=tomorrow&minutes=30"))
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=off&until=tomorrow"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let until = FocusLink(level: .everythingLater, duration: .untilTomorrow).state(now: now, calendar: cal).until
        XCTAssertEqual(until, FocusDuration.tomorrow.until(from: now, calendar: cal))
    }

    func testRejectsOtherShapes() {
        for bad in [
            "needsyou://focus",
            "needsyou://focus?",
            "needsyou://focus?level=",
            "needsyou://focus?level=quiet",
            "needsyou://focus?level=urgent&level=later",
            "needsyou://focus?level=urgent&context=work",
            "needsyou://focus?level=urgent&source=me",
            "needsyou://focus/now?level=urgent",
            "needsyou://user@focus?level=urgent",
            "needsyou://focus:80?level=urgent",
            "needsyou://focus?level=urgent#x",
            "needsyou://orca?level=urgent",
            "https://focus?level=urgent",
            "needsyou://focus?level=urg ent",
            "needsyou://focus?level=urg%0Aent",
            "needsyou://focus?level=urgent&minutes=6%200",
            " ",
        ] {
            XCTAssertNil(FocusLink.parse(bad), bad)
        }
    }

    func testStateAndRoundTrip() {
        let link = FocusLink.parse("needsyou://focus?level=urgent&minutes=90")!
        let state = link.state(now: now)
        XCTAssertEqual(state.level, .urgentOnly)
        XCTAssertEqual(state.until, now.addingTimeInterval(90 * 60))
        XCTAssertEqual(state.source, .link)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=later")!.state(now: now).until, now.addingTimeInterval(12 * 3600),
                       "a link focus always ends")
        XCTAssertEqual(FocusLink.parse(link.url), link)
        XCTAssertEqual(link.url.absoluteString, "needsyou://focus?level=urgent&minutes=90")
        let tomorrow = FocusLink(level: .agentsAndUrgent, duration: .untilTomorrow)
        XCTAssertEqual(FocusLink.parse(tomorrow.url), tomorrow)
        XCTAssertFalse(FocusLink.parse("needsyou://focus?level=off")!.state(now: now).isActive(at: now))
    }

    func testConfirmation() {
        XCTAssertFalse(FocusLink(level: .off).needsConfirmation, "turning focus off only makes alerts louder")
        let link = FocusLink(level: .urgentOnly, duration: .minutes(120))
        XCTAssertTrue(link.needsConfirmation)
        XCTAssertEqual(link.confirmation.title, "Turn on Focus “Urgent only” for 2 hr?")
        XCTAssertEqual(FocusLink(level: .everythingLater, duration: .minutes(45)).confirmation.title, "Turn on Focus “Everything later” for 45 min?")
        XCTAssertTrue(link.confirmation.message.contains("urgent items still interrupt"))
    }

    /// The fixed floor: whatever a link asks for, urgent still interrupts, even with
    /// "Urgent items break through Focus" turned off.
    func testLinkFocusNeverHoldsBackUrgent() {
        let urgent = Item(id: "u", key: "work:x:u", priority: .urgent, title: "u", createdAt: now)
        let normal = Item(id: "n", key: "work:x:n", priority: .normal, title: "n", createdAt: now)
        var defaults = DeliveryDefaults()
        defaults.urgentBreaksFocus = false
        for level in FocusLevel.choices {
            let fromLink = DeliveryState(focus: level, focusSource: .link, defaults: defaults, now: now)
            XCTAssertEqual(DeliveryPolicy.decide(urgent, state: fromLink).tier, .interrupt, level.rawValue)
            XCTAssertEqual(DeliveryPolicy.decide(normal, state: fromLink).tier, .later, level.rawValue)
        }
        // Set by hand, the person's choices still apply.
        let byHand = DeliveryState(focus: .everythingLater, focusSource: .menu, defaults: defaults, now: now)
        XCTAssertEqual(DeliveryPolicy.decide(urgent, state: byHand).tier, .later)
        let byHandUrgentOnly = DeliveryState(focus: .urgentOnly, focusSource: .menu, defaults: defaults, now: now)
        XCTAssertEqual(DeliveryPolicy.decide(urgent, state: byHandUrgentOnly).tier, .ambient)
    }

    func testCardsCantOpenIt() {
        // Not an item link: LinkPolicy never opens it from a card, so a sender can't change the focus.
        XCTAssertFalse(LinkPolicy.isAllowed("needsyou://focus?level=off"))
        XCTAssertNil(MenuItemAction.forItem(Item(id: "x", key: "x", title: "t",
                                                 links: [ItemLink(label: "Focus", url: "needsyou://focus?level=later")],
                                                 createdAt: Date())).openURL)
    }
}

private extension MenuItemAction {
    var openURL: URL? {
        if case .open(let url) = self { return url }
        return nil
    }
}
