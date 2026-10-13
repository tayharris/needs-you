#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Settings → Integrations → Your tools: what the app learns about the pollers from their
/// cards, and the `needs-you context` lines its Work / Personal pickers hand out.
final class ToolSightingsTests: XCTestCase {
    static var allTests = [
        ("testLinearWorkspaceTeamsAndHost", testLinearWorkspaceTeamsAndHost),
        ("testJiraSiteAndProjects", testJiraSiteAndProjects),
        ("testGitHubOwnersReposAndOptIns", testGitHubOwnersReposAndOptIns),
        ("testExpiryAndOtherSendersAndSetupCards", testExpiryAndOtherSendersAndSetupCards),
        ("testNewestContextWinsAndChangeIsReported", testNewestContextWinsAndChangeIsReported),
        ("testHostileNamesAreNeverKept", testHostileNamesAreNeverKept),
        ("testPruneAndBounds", testPruneAndBounds),
        ("testSaveAndLoad", testSaveAndLoad),
        ("testContextCommandLines", testContextCommandLines),
        ("testConfiguredToolsText", testConfiguredToolsText),
        ("testAddAnotherPrompts", testAddAnotherPrompts),
    ]

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func card(_ agent: String, project: String? = nil, key: String = "k", context: ItemContext = .work,
              host: String? = "devbox", event: String? = nil, links: [ItemLink] = [], at minutes: Double = 0) -> Item {
        Item(id: UUID().uuidString, key: key, context: context, title: "t", links: links,
             source: ItemSource(host: host, agent: agent, project: project, event: event),
             createdAt: t0.addingTimeInterval(minutes * 60))
    }

    func testLinearWorkspaceTeamsAndHost() {
        var s = ToolSightings()
        XCTAssertTrue(s.record([
            card("linear", project: "ACME", key: "work:linear:ACME-1",
                 links: [ItemLink(label: "Issue", url: "https://linear.app/acme/issue/ACME-1/fix-it")]),
            card("linear", project: "OPS", key: "personal:linear:OPS-2", context: .personal, at: 5),
            card("linear", project: "linear", key: "work:linear:devbox:poller-failing"),   // health card: no team
        ], now: t0))
        let linear = s.tool("linear")!
        XCTAssertEqual(linear.accountNames, ["acme"])
        XCTAssertEqual(linear.hostNames, ["devbox"])
        XCTAssertEqual(linear.scopeList.map(\.name), ["OPS", "ACME"])
        XCTAssertEqual(linear.scopes["OPS"]?.context, .personal)
        XCTAssertEqual(linear.scopes["ACME"]?.context, .work)
        XCTAssertEqual(s.all.map(\.id), ["linear"])
        // The same cards again: nothing new to save.
        XCTAssertFalse(s.record([card("linear", project: "ACME", key: "work:linear:ACME-1", at: 10)], now: t0))
    }

    func testJiraSiteAndProjects() {
        var s = ToolSightings()
        s.record([card("jira", project: "ACME", key: "work:jira:acme:ACME-7",
                       links: [ItemLink(label: "Open", url: "https://acme.atlassian.net/browse/ACME-7")]),
                  card("jira", project: "jira", key: "work:jira:acme:devbox:poller-failing")], now: t0)
        let jira = s.tool("jira")!
        XCTAssertEqual(jira.accountNames, ["acme.atlassian.net"])
        XCTAssertEqual(jira.scopeList.map(\.name), ["ACME"])
        // Plain http, or a link that isn't an issue, isn't the site.
        var other = ToolSightings()
        other.record([card("jira", project: "ACME", links: [ItemLink(label: "x", url: "http://jira.acme.example/browse/ACME-1"),
                                                           ItemLink(label: "y", url: "https://example.com/x")])], now: t0)
        XCTAssertEqual(other.tool("jira")?.accountNames, [])
    }

    func testGitHubOwnersReposAndOptIns() {
        var s = ToolSightings()
        s.record([
            card("github", project: "acme/api", key: "work:gh:acme/api#3:review"),
            card("github", project: "Example-User/dotfiles", key: "personal:gh:example-user/dotfiles#1:mention",
                 context: .personal, at: 1),
            card("github", project: "acme/web", key: "work:gh:acme/web#9:status", event: "status",
                 links: [ItemLink(label: "Open", url: "https://github.com/acme/web/issues/9"),
                         ItemLink(label: "Project", url: "https://github.com/orgs/acme/projects/1")], at: 2),
            card("github", project: "github", key: "work:gh:devbox:poller-failing"),
        ], now: t0)
        let gh = s.tool("github")!
        XCTAssertEqual(Set(gh.accountNames), ["acme", "example-user"])
        XCTAssertEqual(gh.owners.map(\.owner), ["acme", "example-user"])
        XCTAssertEqual(gh.owners.first?.repos.map(\.name), ["acme/web", "acme/api"])
        XCTAssertEqual(gh.features, ["projects"])
        s.record([card("github", project: "acme/api", key: "work:gh:acme/api:security:4", event: "security", at: 3)], now: t0)
        XCTAssertEqual(s.tool("github")?.features, ["projects", "dependabot"])
    }

    func testExpiryAndOtherSendersAndSetupCards() {
        var s = ToolSightings()
        s.record([card("expiry", project: "expiry", key: "personal:expiry:tls:example.com", context: .personal),
                  card("claude-code", project: "acme/api"),
                  Item(id: SetupChecklist.idPrefix + SetupTip.integrations.rawValue, key: "x", title: "t",
                       source: ItemSource(agent: "linear", project: "ACME"), createdAt: t0)], now: t0)
        XCTAssertEqual(s.all.map(\.id), ["expiry"])
        XCTAssertEqual(s.tool("expiry")?.context, .personal)
        XCTAssertEqual(s.tool("expiry")?.scopes, [:])
    }

    func testNewestContextWinsAndChangeIsReported() {
        var s = ToolSightings()
        s.record([card("linear", project: "ACME", at: 0)], now: t0)
        // An older card replayed doesn't undo the newer one.
        XCTAssertTrue(s.record([card("linear", project: "ACME", context: .personal, at: 5)], now: t0))
        XCTAssertFalse(s.record([card("linear", project: "ACME", context: .work, at: 1)], now: t0))
        XCTAssertEqual(s.tool("linear")?.scopes["ACME"]?.context, .personal)
        // Much newer: worth saving again.
        XCTAssertTrue(s.record([card("linear", project: "ACME", context: .personal, at: 120)], now: t0))
    }

    func testHostileNamesAreNeverKept() {
        var s = ToolSightings()
        s.record([card("linear", project: "ACME; rm -rf ~", host: "dev box$(x)",
                       links: [ItemLink(label: "Issue", url: "https://linear.app/a b/issue/ACME-1")]),
                  card("github", project: "acme/api`x`"),
                  card("jira", project: "acme")], now: t0)
        XCTAssertEqual(s.tool("linear")?.scopes, [:])
        XCTAssertEqual(s.tool("linear")?.hosts, [:])
        XCTAssertEqual(s.tool("linear")?.accounts, [:])
        XCTAssertEqual(s.tool("github")?.scopes, [:])
        XCTAssertEqual(s.tool("jira")?.scopes, [:])   // Jira keys are upper case
    }

    func testPruneAndBounds() {
        var s = ToolSightings()
        s.record((0..<60).map { card("github", project: "acme/r\($0)", at: Double($0)) }, now: t0)
        XCTAssertEqual(s.tool("github")?.scopes.count, 40)
        XCTAssertNotNil(s.tool("github")?.scopes["acme/r59"])
        XCTAssertNil(s.tool("github")?.scopes["acme/r0"])
        s.record([card("linear", project: "ACME", at: 0)], now: t0)
        XCTAssertTrue(s.prune(now: t0.addingTimeInterval(ToolSightings.maxAge + 3600)))
        XCTAssertTrue(s.isEmpty)
    }

    func testSaveAndLoad() {
        let suite = TestDefaults.suiteName(Self.self)
        let d = TestDefaults.make(suite)
        defer { TestDefaults.clear(suite) }
        var s = ToolSightings()
        // 40 days before t0: long gone by the time this test runs.
        let old = -40.0 * 24 * 60
        s.record([card("jira", project: "ACME", links: [ItemLink(label: "Open", url: "https://acme.atlassian.net/browse/ACME-1")],
                       at: old)], now: t0.addingTimeInterval(old * 60))
        XCTAssertFalse(s.isEmpty)
        s.save(to: d, key: "sightings")
        // Loading prunes against today: a fresh card survives, so use one from now.
        var fresh = ToolSightings()
        fresh.record([Item(id: "1", key: "k", title: "t", source: ItemSource(host: "devbox", agent: "expiry"), createdAt: Date())])
        fresh.save(to: d, key: "fresh")
        XCTAssertEqual(ToolSightings.load(from: d, key: "fresh"), fresh)
        XCTAssertTrue(ToolSightings.load(from: d, key: "sightings").isEmpty)   // older than 30 days
        XCTAssertTrue(ToolSightings.load(from: d, key: "missing").isEmpty)
        d.set(Data("not json".utf8), forKey: "bad")
        XCTAssertTrue(ToolSightings.load(from: d, key: "bad").isEmpty)
        ToolSightings().save(to: d, key: "fresh")
        XCTAssertNil(d.data(forKey: "fresh"))
    }

    func testContextCommandLines() {
        XCTAssertEqual(ToolContextCommand.line(tool: "linear", name: "acme", context: .personal),
                       "~/.local/bin/needs-you context linear ACME personal")
        XCTAssertEqual(ToolContextCommand.line(tool: "jira", name: "OPS", context: .work),
                       "~/.local/bin/needs-you context jira OPS work")
        XCTAssertEqual(ToolContextCommand.line(tool: "github", name: "Example-User", context: .personal),
                       "~/.local/bin/needs-you context github example-user personal")
        XCTAssertEqual(ToolContextCommand.line(tool: "github", name: "acme/side.project", context: .personal),
                       "~/.local/bin/needs-you context github acme/side.project personal")
        XCTAssertEqual(ToolContextCommand.line(tool: "expiry", name: nil, context: .personal),
                       "~/.local/bin/needs-you context expiry '*' personal")
        for (tool, name) in [("linear", "A;B"), ("jira", "acme"), ("github", "a/b c"), ("github", "$(x)"),
                             ("expiry", "x"), ("slack", "ACME")] {
            XCTAssertNil(ToolContextCommand.line(tool: tool, name: name, context: .work), "\(tool) \(name)")
        }
        XCTAssertTrue(ToolContextCommand.instructions(host: "devbox").hasPrefix("Run this on devbox."))
    }

    func testConfiguredToolsText() {
        var s = ToolSightings()
        s.record([
            card("linear", project: "ACME", links: [ItemLink(label: "Issue", url: "https://linear.app/acme/issue/ACME-1")]),
            card("linear", project: "OPS", at: 1),
            card("jira", project: "ACME", links: [ItemLink(label: "Open", url: "https://acme.atlassian.net/browse/ACME-1")]),
            card("github", project: "acme/api"),
            card("github", project: "acme/web", event: "status",
                 links: [ItemLink(label: "Project", url: "https://github.com/orgs/acme/projects/1")]),
            card("expiry", context: .personal, host: "nas"),
        ], now: t0)
        XCTAssertEqual(s.all.map(\.id), ["linear", "jira", "github", "expiry"])
        XCTAssertEqual(ConfiguredTools.detail(s.tool("linear")!), "Workspace acme · teams OPS, ACME · on devbox")
        XCTAssertEqual(ConfiguredTools.detail(s.tool("jira")!), "acme.atlassian.net · project ACME · on devbox")
        XCTAssertEqual(ConfiguredTools.detail(s.tool("github")!), "acme · 2 repos · Projects statuses · on devbox")
        XCTAssertEqual(ConfiguredTools.detail(s.tool("expiry")!), "Personal · on nas")
        let byID = Dictionary(uniqueKeysWithValues: IntegrationCatalog.all.map { ($0.id, $0) })
        XCTAssertTrue(ConfiguredTools.isSending(byID["linear"]!, in: s))
        XCTAssertTrue(ConfiguredTools.isSending(byID["github-projects"]!, in: s))
        XCTAssertFalse(ConfiguredTools.isSending(byID["dependabot"]!, in: s))   // GitHub, but no alert card yet
        XCTAssertFalse(ConfiguredTools.isSending(byID["linear"]!, in: ToolSightings()))
        for id in ToolSightings.order {
            XCTAssertTrue(ConfiguredTools.guideURL(id).hasPrefix("https://"), id)
            XCTAssertFalse(ConfiguredTools.name(id).isEmpty)
        }
    }

    func testAddAnotherPrompts() {
        XCTAssertNil(ConfiguredTools.addAnotherTitle("github"))
        XCTAssertNil(ConfiguredTools.addAnotherPrompt("github", host: "devbox"))
        for id in ["linear", "jira", "expiry"] {
            XCTAssertNotNil(ConfiguredTools.addAnotherTitle(id), id)
            let prompt = ConfiguredTools.addAnotherPrompt(id, host: "devbox")!
            XCTAssertTrue(prompt.contains("on this machine (devbox)"), id)
            XCTAssertTrue(prompt.contains("If a run prints an error"), id)
            XCTAssertFalse(prompt.contains("nyt_"), id)
            if id != "expiry" {
                // The second key or token goes in its own mode-600 file, typed by the person.
                XCTAssertTrue(prompt.contains("mode 600"), id)
                XCTAssertTrue(prompt.contains("Never ask me for the"), id)
                XCTAssertTrue(prompt.contains("--state ~/.local/state/needs-you/\(id)-2.json"), id)
            }
        }
    }
}
