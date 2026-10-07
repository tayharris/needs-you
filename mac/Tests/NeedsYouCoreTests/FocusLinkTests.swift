#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class FocusLinkTests: XCTestCase {
    static var allTests = [
        ("testParsesEveryLevel", testParsesEveryLevel),
        ("testMinutes", testMinutes),
        ("testRejectsOtherShapes", testRejectsOtherShapes),
        ("testStateAndRoundTrip", testStateAndRoundTrip),
        ("testCardsCantOpenIt", testCardsCantOpenIt),
    ]

    func testParsesEveryLevel() {
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=off")?.level, .off)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents")?.level, .agentsAndUrgent)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=urgent")?.level, .urgentOnly)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=later")?.level, .everythingLater)
        XCTAssertEqual(FocusLink.parse("NEEDSYOU://FOCUS/?level=Urgent")?.level, .urgentOnly)
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent")?.minutes, "no minutes: until turned off")
    }

    func testMinutes() {
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=urgent&minutes=60")?.minutes, 60)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?minutes=1&level=later")?.minutes, 1)
        XCTAssertEqual(FocusLink.parse("needsyou://focus?level=agents&minutes=720")?.minutes, 720)
        for bad in ["0", "721", "-5", "+5", "1.5", "60m", "", "0060", "９"] {
            XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&minutes=\(bad)"), bad)
        }
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=off&minutes=30"), "off takes no duration")
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=urgent&minutes=30&minutes=60"))
    }

    func testRejectsOtherShapes() {
        for bad in [
            "needsyou://focus",
            "needsyou://focus?",
            "needsyou://focus?level=",
            "needsyou://focus?level=quiet",
            "needsyou://focus?level=urgent&level=later",
            "needsyou://focus?level=urgent&context=work",
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
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let link = FocusLink.parse("needsyou://focus?level=urgent&minutes=90")!
        let state = link.state(now: now)
        XCTAssertEqual(state.level, .urgentOnly)
        XCTAssertEqual(state.until, now.addingTimeInterval(90 * 60))
        XCTAssertEqual(state.source, .link)
        XCTAssertNil(FocusLink.parse("needsyou://focus?level=later")!.state(now: now).until)
        XCTAssertEqual(FocusLink.parse(link.url), link)
        XCTAssertEqual(link.url.absoluteString, "needsyou://focus?level=urgent&minutes=90")
        XCTAssertNil(FocusLink(level: .urgentOnly, minutes: 0))
        XCTAssertFalse(FocusLink.parse("needsyou://focus?level=off")!.state(now: now).isActive(at: now))
    }

    func testCardsCantOpenIt() {
        // Not an item link: LinkPolicy never opens it from a card, so a sender can't change the focus.
        XCTAssertFalse(LinkPolicy.isAllowed("needsyou://focus?level=off"))
        XCTAssertNil(MenuItemAction.forItem(Item(id: "x", key: "x", title: "t",
                                                 links: [ItemLink(label: "Focus", url: "needsyou://focus?level=off")],
                                                 createdAt: Date())).openURL)
    }
}

private extension MenuItemAction {
    var openURL: URL? {
        if case .open(let url) = self { return url }
        return nil
    }
}
