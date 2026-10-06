import Foundation

/// An in-memory stand-in for the hub so the UI can be exercised without one.
/// Enabled with `NEEDS_YOU_DEMO=1` or the Settings toggle. It behaves like the hub as
/// specified: `fetchOpen(since:)` returns open items updated at/after `since`, and
/// `patch` closes or marks items seen. `injectNext()` simulates a sender posting.
public actor DemoFeed: ItemFeed {
    private var items: [String: Item] = [:]
    private var injected = 0
    private var serial = 0

    public init(items: [Item]? = nil, now: Date = Date()) {
        for item in items ?? DemoFeed.fixture(now: now) { self.items[item.id] = item }
    }

    /// Load a JSON fixture (a bare array or `{ "items": [...] }`, the hub's shape).
    public static func loadFixture(at url: URL) throws -> [Item] {
        try HubJSON.decodeItemList(Data(contentsOf: url))
    }

    public func fetchOpen(since: Date?) async throws -> [Item] {
        items.values
            .filter { $0.status == .open }
            .filter { since == nil || $0.updatedAt >= since! }
    }

    public func patch(id: String, _ patch: ItemPatch) async throws {
        guard var item = items[id] else { throw HubError.http(status: 404) }
        if let status = patch.status { item.status = status }
        if let seenAt = patch.seenAt { item.seenAt = seenAt }
        item.updatedAt = Date()
        items[id] = item
    }

    /// Simulate a sender: mostly new items, sometimes an upsert on an existing key, and
    /// every so often an urgent one (to exercise snooze breakthrough).
    @discardableResult
    public func injectNext(now: Date = Date()) -> Item {
        injected += 1
        let template = DemoFeed.injectTemplates[(injected - 1) % DemoFeed.injectTemplates.count]

        // Every fourth injection re-posts an existing key with a new title (an upsert).
        if injected % 4 == 0, let target = items.values.filter({ $0.status == .open && $0.kind == .needs }).min(by: { $0.createdAt < $1.createdAt }) {
            var updated = target
            updated.title = "\(target.title.components(separatedBy: " (update").first ?? target.title) (update \(injected / 4))"
            updated.updatedAt = now
            items[updated.id] = updated
            return updated
        }

        let item = Item(
            id: nextID(), key: "demo:\(template.key):\(injected)", context: template.context,
            kind: template.kind, priority: template.priority, title: template.title,
            body: template.body, links: template.links,
            source: ItemSource(host: template.host, agent: template.agent, project: nil),
            createdAt: now, expiresAt: template.kind == .needs ? nil : now.addingTimeInterval(86_400)
        )
        items[item.id] = item
        return item
    }

    /// Simulate a sender resolving an item.
    public func resolve(key: String) {
        for (id, item) in items where item.key == key && item.status == .open {
            items[id]?.status = .resolved
            items[id]?.updatedAt = Date()
        }
    }

    private func nextID() -> String {
        serial += 1
        return String(format: "01DEMO%020d", serial + 1_000)
    }

    // MARK: - Fixture

    struct Template {
        var key: String
        var context: ItemContext
        var kind: ItemKind
        var priority: ItemPriority
        var title: String
        var body: String?
        var links: [ItemLink]
        var host: String
        var agent: String
    }

    static let injectTemplates: [Template] = [
        Template(key: "acme:ACME-4612:review", context: .work, kind: .needs, priority: .normal,
                 title: "ACME-4612: approve the returns-label copy change",
                 body: "Two options in the PR thread. **Pick one** so the worker can finish.",
                 links: [ItemLink(label: "PR #2201", url: "https://github.com/acme/acme-backend/pull/2201")],
                 host: "devbox", agent: "orca:ticket-worker"),
        Template(key: "acme:devbox:memory", context: .work, kind: .needs, priority: .urgent,
                 title: "devbox swap at 92%: approve killing idle sessions",
                 body: "Reaper found 7 idle `claude` sessions holding 11 GB.",
                 links: [ItemLink(label: "Orca", url: "orca://worktree/devbox")],
                 host: "devbox", agent: "orca:idle-reaper"),
        Template(key: "personal:blog:cert", context: .personal, kind: .needs, priority: .low,
                 title: "blog TLS cert expires in 6 days",
                 body: "Renewal hook failed once; it'll retry, but check the DNS token.",
                 links: [ItemLink(label: "Logs", url: "https://blog.example.ts.net/logs")],
                 host: "blog", agent: "cron:certbot"),
        Template(key: "acme:redo-fixer:last-run", context: .work, kind: .done, priority: .normal,
                 title: "Redo fixer: 2 tickets back in review", body: nil,
                 links: [], host: "devbox", agent: "orca:redo-fixer"),
    ]

    /// The seed set. Covers every kind, priority and context, an allowed and a disallowed
    /// link, and a body using the full limited-markdown feature set.
    public static func fixture(now: Date = Date()) -> [Item] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            Item(
                id: "01DEMO00000000000000000001", key: "acme:ACME-4170:push-decision", context: .work,
                kind: .needs, priority: .normal,
                title: "ACME-4170: push blocked on the migration fork",
                body: "Choose one: **merge migration** or *one-time hook bypass*.\nQuestion is in Jira comment `74511`.\n- merge keeps history clean\n- bypass is faster",
                links: [
                    ItemLink(label: "Jira", url: "https://acme.atlassian.net/browse/ACME-4170"),
                    ItemLink(label: "PR #2137", url: "https://github.com/acme/acme-backend/pull/2137"),
                    ItemLink(label: "Orca", url: "orca://worktree/acme-backend/ACME-4170"),
                ],
                source: ItemSource(host: "devbox", agent: "orca:redo-fixer", project: "acme-backend"),
                createdAt: ago(130)
            ),
            Item(
                id: "01DEMO00000000000000000002", key: "acme:ACME-4529:ssm-flag", context: .work,
                kind: .needs, priority: .urgent,
                title: "ACME-4529: set the SSM flag before the 3 pm deploy",
                body: "Needs `prod` access the agent doesn't have. See [the runbook](https://acme.atlassian.net/wiki/runbook). Don't trust [this one](http://example.com/plain) or ![img](https://example.com/x.png).",
                links: [
                    ItemLink(label: "Jira", url: "https://acme.atlassian.net/browse/ACME-4529"),
                    ItemLink(label: "Slack thread", url: "slack://channel?team=T0&id=C0"),
                    ItemLink(label: "Not allowed", url: "http://insecure.example.com"),
                    ItemLink(label: "Script", url: "javascript:alert(1)"),
                ],
                source: ItemSource(host: "devbox", agent: "orca:redo-fixer", project: "acme-backend"),
                createdAt: ago(45)
            ),
            Item(
                id: "01DEMO00000000000000000003", key: "acme:cleanup:feature/ACME-4400-old", context: .work,
                kind: .needs, priority: .low,
                title: "Cleanup: feature/ACME-4400-old has 2 unpushed commits",
                body: "Daily cleanup won't delete it. Push, or say it can go.",
                links: [ItemLink(label: "VS Code", url: "vscode://file/home/dev/acme-backend")],
                source: ItemSource(host: "devbox", agent: "orca:daily-cleanup"),
                createdAt: ago(60 * 20)
            ),
            Item(
                id: "01DEMO00000000000000000004", key: "personal:photos:backup", context: .personal,
                kind: .needs, priority: .normal,
                title: "photos nightly backup failed",
                body: "`restic` exit 1 at 03:00. Disk 97% full.",
                links: [ItemLink(label: "Logs", url: "https://photos.example.ts.net/logs")],
                source: ItemSource(host: "photos", agent: "cron:backup"),
                createdAt: ago(300)
            ),
            Item(
                id: "01DEMO00000000000000000005", key: "acme:redo-fixer:run", context: .work,
                kind: .done, priority: .normal,
                title: "Redo fixer: ACME-4377 back in Engineering Review",
                source: ItemSource(host: "devbox", agent: "orca:redo-fixer"),
                createdAt: ago(25), expiresAt: now.addingTimeInterval(86_400)
            ),
            Item(
                id: "01DEMO00000000000000000006", key: "acme:ci:nightly", context: .work,
                kind: .info, priority: .low,
                title: "Nightly e2e: 214 passed, 0 failed",
                source: ItemSource(host: "ci", agent: "github-actions"),
                createdAt: ago(400), expiresAt: now.addingTimeInterval(86_400)
            ),
        ]
    }
}
