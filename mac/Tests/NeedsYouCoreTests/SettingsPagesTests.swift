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
        ("testTaskBasedNames", testTaskBasedNames),
        ("testDeepLinksAndOldNames", testDeepLinksAndOldNames),
        ("testAppearanceHoldsTheLookPages", testAppearanceHoldsTheLookPages),
        ("testPagesByName", testPagesByName),
        ("testConnectChoicesInPlainWords", testConnectChoicesInPlainWords),
        ("testMachineRowText", testMachineRowText),
        ("testThisMacRows", testThisMacRows),
        ("testLinksUseTheUpdaterRepository", testLinksUseTheUpdaterRepository),
    ]

    func testSidebarOrderAndGroups() {
        XCTAssertEqual(SettingsSidebarGroup.allCases.map { $0.pages(canInvite: true) }, [
            [.general],
            [.inbox, .connect, .machines, .otherHubs],
            [.theme, .pill, .cards, .alertStyle, .usageMeters],
            [.panel, .alerts, .integrations, .updates, .advanced],
        ])
        XCTAssertNil(SettingsSidebarGroup.start.title)
        XCTAssertEqual(SettingsSidebarGroup.hubs.title, "Hubs and machines")
        XCTAssertEqual(SettingsSidebarGroup.appearance.title, "Appearance")
        // Every page is in exactly one group.
        let listed = SettingsSidebarGroup.allCases.flatMap { $0.pages(canInvite: true) }
        XCTAssertEqual(Set(listed), Set(SettingsTab.allCases))
        XCTAssertEqual(listed.count, SettingsTab.allCases.count)
    }

    func testAccessOnlyWithAnOwnerToken() {
        XCTAssertEqual(SettingsSidebarGroup.hubs.pages(canInvite: false), [.inbox, .connect, .otherHubs])
        XCTAssertEqual(SettingsTab.machines.resolved(canInvite: false), .connect)
        XCTAssertEqual(SettingsTab.machines.resolved(canInvite: true), .machines)
        // Deep links: Connect a Machine… and connect links always land on a visible page.
        XCTAssertEqual(SettingsTab.connect.resolved(canInvite: false), .connect)
        XCTAssertEqual(SettingsTab.otherHubs.resolved(canInvite: false), .otherHubs)
        XCTAssertEqual(SettingsTab.inbox.resolved(canInvite: false), .inbox)
    }

    func testTaskBasedNames() {
        XCTAssertEqual(SettingsSidebarGroup.hubs.pages(canInvite: true).map(\.title),
                       ["Built-in hub", "Connect a machine", "Machines", "Other hubs (advanced)"])
        // None of the old, confusing names is left in the sidebar.
        let titles = Set(SettingsTab.allCases.map(\.title))
        for old in ["This Mac", "Your inbox", "Join a hub", "Invite a machine", "Access", "Hubs (manual)", "Hubs"] {
            XCTAssertFalse(titles.contains(old), old)
        }
    }

    @available(*, deprecated)
    func testDeepLinksAndOldNames() {
        // Code still using the old names lands on the merged or renamed page.
        XCTAssertEqual(SettingsTab.thisMac, .inbox)
        XCTAssertEqual(SettingsTab.invite, .connect)
        XCTAssertEqual(SettingsTab.access, .machines)
        XCTAssertEqual(SettingsTab.joinHub, .otherHubs)
        XCTAssertEqual(SettingsTab.hubs, .otherHubs)
        // Appearance became a group: the old page lands on its first page, Theme (which
        // holds what the old page did), and Usage moved under it whole.
        XCTAssertEqual(SettingsTab.appearance, .theme)
        XCTAssertEqual(SettingsTab.usage, .usageMeters)
        XCTAssertEqual(SettingsTab.appearance.group, .appearance)
        XCTAssertEqual(SettingsTab.usage.resolved(canInvite: false), .usageMeters)
    }

    /// Look and behaviour don't mix: Appearance's pages are all and only the look pages,
    /// and the behaviour pages keep their names and deep links.
    func testAppearanceHoldsTheLookPages() {
        XCTAssertEqual(SettingsSidebarGroup.appearance.pages(canInvite: false).map(\.title),
                       ["Theme", "Pill", "Panel and cards", "Alert style", "Usage meters"])
        for tab in [SettingsTab.panel, .alerts, .integrations, .updates, .advanced] {
            XCTAssertEqual(tab.group, .app, tab.rawValue)
            XCTAssertEqual(tab.resolved(canInvite: false), tab)
        }
        // No page is called just "Appearance" or "Usage": those are a group and a subpage.
        let titles = Set(SettingsTab.allCases.map(\.title))
        XCTAssertFalse(titles.contains("Appearance"))
        XCTAssertFalse(titles.contains("Usage"))
    }

    func testPagesByName() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab(name: tab.rawValue), tab)
        }
        XCTAssertEqual(SettingsTab(name: "appearance"), .theme)
        XCTAssertEqual(SettingsTab(name: "usage"), .usageMeters)
        XCTAssertEqual(SettingsTab(name: "thisMac"), .inbox)
        XCTAssertEqual(SettingsTab(name: "invite"), .connect)
        XCTAssertEqual(SettingsTab(name: "access"), .machines)
        XCTAssertEqual(SettingsTab(name: "joinHub"), .otherHubs)
        XCTAssertEqual(SettingsTab(name: "hubs"), .otherHubs)
        XCTAssertNil(SettingsTab(name: "nope"))
        XCTAssertNil(SettingsTab(name: ""))
    }

    func testConnectChoicesInPlainWords() {
        XCTAssertEqual(HubRole.sender.connectTitle, "A server or agent that sends alerts")
        XCTAssertEqual(HubRole.reader.connectTitle, "Another Mac that shows the same alerts")
        XCTAssertTrue(HubRole.owner.connectTitle.contains("advanced"))
        for role in HubRole.allCases {
            XCTAssertFalse(role.connectDetail.isEmpty)
            XCTAssertFalse(role.machineLabel.isEmpty)
            // Plain words: the role's own name isn't the label.
            XCTAssertFalse(role.connectTitle.lowercased().contains(role.rawValue), role.rawValue)
        }
    }

    func testMachineRowText() {
        let sender = TokenSummary(id: "1", name: "devbox", role: .sender, openItems: 2, client: ["cli": "0.4.1"])
        XCTAssertEqual(MachineRowText.detail(sender), "Sender · 2 open · CLI 0.4.1")
        let quiet = TokenSummary(id: "2", name: "ci", role: .sender)
        XCTAssertEqual(MachineRowText.detail(quiet), "Sender · version unknown (hasn't posted since updating)")
        let unknown = TokenSummary(id: "3", name: "old", role: .sender, client: ["cli": "unknown"])
        XCTAssertTrue(MachineRowText.detail(unknown).hasSuffix(MachineRowText.versionUnknown))
        // Macs don't run the CLI, so no version line for them.
        let me = TokenSummary(id: "4", name: "mac", role: .owner, current: true)
        XCTAssertEqual(MachineRowText.detail(me), "Mac, owner · this Mac: app")
        let reader = TokenSummary(id: "5", name: "laptop", role: .reader, openItems: 1)
        XCTAssertEqual(MachineRowText.detail(reader), "Mac, reader · 1 open")
    }

    /// "This Mac" comes only from what the app knows for itself (the token it is using),
    /// never from a name: a sender picks its own invite name and host, so a machine named
    /// like this Mac must not be shown as this Mac.
    func testThisMacRows() {
        let app = TokenSummary(id: "1", name: "this-mac", role: .owner, current: true)
        let spoof = TokenSummary(id: "2", name: "devbox", role: .sender)
        let spoof2 = TokenSummary(id: "3", name: "agent-devbox", role: .sender)
        let spoof3 = TokenSummary(id: "4", name: "this-mac", role: .sender)
        let other = TokenSummary(id: "5", name: "build-1", role: .sender)
        XCTAssertTrue(MachineRowText.isThisMac(app))
        for token in [spoof, spoof2, spoof3, other] {
            XCTAssertFalse(MachineRowText.isThisMac(token), token.name)
            XCTAssertFalse(MachineRowText.detail(token).contains("this Mac"), token.name)
        }
        XCTAssertEqual(MachineRowText.detail(app), "Mac, owner · this Mac: app")
        // The app's own row first, the rest as the hub listed them.
        XCTAssertEqual(MachineRowText.ordered([other, spoof, app, spoof2]).map(\.id),
                       ["1", "5", "2", "3"])
    }

    func testLinksUseTheUpdaterRepository() {
        XCTAssertEqual(SettingsLinks.serverHubGuide().absoluteString,
                       "https://github.com/\(UpdateSource.defaultRepository)/blob/main/docs/HUB.md")
        XCTAssertEqual(SettingsLinks.wordsGuide(repository: "o/r").absoluteString,
                       "https://github.com/o/r/blob/main/docs/guides/concepts.md")
        XCTAssertTrue(LinkPolicy.isAllowed(SettingsLinks.serverHubGuide().absoluteString))
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
