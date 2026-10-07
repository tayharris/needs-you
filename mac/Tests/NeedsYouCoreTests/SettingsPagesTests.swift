#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class SettingsPagesTests: XCTestCase {
    static var allTests = [
        ("testSidebarOrderAndGroups", testSidebarOrderAndGroups),
        ("testAccessOnlyWithAnOwnerToken", testAccessOnlyWithAnOwnerToken),
        ("testEveryPageHasTitleSymbolAndSummary", testEveryPageHasTitleSymbolAndSummary),
    ]

    func testSidebarOrderAndGroups() {
        XCTAssertEqual(SettingsSidebarGroup.allCases.map { $0.pages(canInvite: true) }, [
            [.general],
            [.thisMac, .joinHub, .invite, .access, .hubs],
            [.panel, .alerts, .integrations, .updates, .advanced],
        ])
        XCTAssertNil(SettingsSidebarGroup.start.title)
        XCTAssertEqual(SettingsSidebarGroup.hubs.title, "Hubs")
        // Every page is in exactly one group.
        let listed = SettingsSidebarGroup.allCases.flatMap { $0.pages(canInvite: true) }
        XCTAssertEqual(Set(listed), Set(SettingsTab.allCases))
        XCTAssertEqual(listed.count, SettingsTab.allCases.count)
    }

    func testAccessOnlyWithAnOwnerToken() {
        XCTAssertEqual(SettingsSidebarGroup.hubs.pages(canInvite: false), [.thisMac, .joinHub, .invite, .hubs])
        XCTAssertEqual(SettingsTab.access.resolved(canInvite: false), .invite)
        XCTAssertEqual(SettingsTab.access.resolved(canInvite: true), .access)
        // Deep links: Invite a Machine… and connect links always land on a visible page.
        XCTAssertEqual(SettingsTab.invite.resolved(canInvite: false), .invite)
        XCTAssertEqual(SettingsTab.joinHub.resolved(canInvite: false), .joinHub)
    }

    func testEveryPageHasTitleSymbolAndSummary() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.symbol.isEmpty)
            XCTAssertFalse(tab.summary.isEmpty)
            XCTAssertTrue(tab.summary.count <= 120, "\(tab) summary is long: \(tab.summary.count)")
        }
        XCTAssertEqual(Set(SettingsTab.allCases.map(\.title)).count, SettingsTab.allCases.count)
    }
}

final class ConnectLinkClipboardTests: XCTestCase {
    static var allTests = [
        ("testPasteOnlyTakesJoinLinks", testPasteOnlyTakesJoinLinks),
        ("testSuggestionNeedsAnEmptyFieldAndAJoinLink", testSuggestionNeedsAnEmptyFieldAndAJoinLink),
        ("testSuggestionSkipsOwnHubAndHandledLinks", testSuggestionSkipsOwnHubAndHandledLinks),
    ]

    let mac = "needsyou://connect?hub=http%3A%2F%2Fhub-a.example.ts.net%3A8765&code=Ab-12_x"
    let join = "http://hub-a.example.ts.net:8765/join/K7q9"

    func testPasteOnlyTakesJoinLinks() {
        XCTAssertEqual(ConnectLinkClipboard.paste(" \(mac)\n"), .link(mac))
        XCTAssertEqual(ConnectLinkClipboard.paste(join), .link(join))
        XCTAssertEqual(ConnectLinkClipboard.paste(nil), .empty)
        XCTAssertEqual(ConnectLinkClipboard.paste("  \n"), .empty)
        // A token or a password on the clipboard never goes into the field.
        XCTAssertEqual(ConnectLinkClipboard.paste("correct horse battery staple"), .notALink)
        XCTAssertEqual(ConnectLinkClipboard.paste("https://hub-a.example.ts.net:8765"), .notALink)
        XCTAssertEqual(ConnectLinkClipboard.paste(join + String(repeating: "a", count: ConnectLinkClipboard.maxLength)), .notALink)
    }

    func testSuggestionNeedsAnEmptyFieldAndAJoinLink() {
        XCTAssertEqual(ConnectLinkClipboard.suggestion(clipboard: mac, draft: ""), mac)
        XCTAssertEqual(ConnectLinkClipboard.suggestion(clipboard: join, draft: "  "), join)
        XCTAssertNil(ConnectLinkClipboard.suggestion(clipboard: mac, draft: "needsyou://connect?…"))
        XCTAssertNil(ConnectLinkClipboard.suggestion(clipboard: "hello", draft: ""))
        XCTAssertNil(ConnectLinkClipboard.suggestion(clipboard: nil, draft: ""))
    }

    func testSuggestionSkipsOwnHubAndHandledLinks() throws {
        // A Mac link made on this Mac (its hub is this Mac's tailnet URL) isn't offered here.
        let own = try XCTUnwrap(URL(string: "http://HUB-A.example.ts.net:8765/"))
        XCTAssertNil(ConnectLinkClipboard.suggestion(clipboard: mac, draft: "", ownHubs: [own]))
        let other = try XCTUnwrap(URL(string: "http://hub-b.example.ts.net:8765"))
        XCTAssertEqual(ConnectLinkClipboard.suggestion(clipboard: mac, draft: "", ownHubs: [other]), mac)
        // The link just connected (or being connected) isn't offered again.
        let handled = try XCTUnwrap(ConnectLink.parse(join))
        XCTAssertNil(ConnectLinkClipboard.suggestion(clipboard: join, draft: "", ignoring: [handled]))
        XCTAssertEqual(ConnectLinkClipboard.suggestion(clipboard: mac, draft: "", ignoring: [handled]), mac)
    }
}
