import Foundation

// Settings → Integrations → Your tools: which tool pollers (Linear, Jira, GitHub, expiry) are
// already sending cards, for what (the Linear workspace and teams, the Jira site and
// projects, the GitHub owners and repos), from which machine, and as work or personal.
//
// The pollers run on sender machines, so the app can't read their config or tokens. It
// learns only from the cards they post (source agent, project, links, context, host), as
// items pass through a poll, and keeps a small, bounded summary in UserDefaults so the page
// still knows after a restart or once the cards are gone. Every name it keeps must fit a
// strict pattern (a team key, a repo, a host name): a card is sender input, and these names
// end up in commands the person copies and runs.

/// One team, project or repo a poller posted cards for, and the context they had.
public struct ToolScope: Codable, Equatable, Sendable {
    /// Linear team key (`ACME`), Jira project key (`ACME`) or GitHub `owner/repo`.
    public var name: String
    /// The context of its newest card.
    public var context: ItemContext
    public var lastSeen: Date

    public init(name: String, context: ItemContext, lastSeen: Date) {
        self.name = name
        self.context = context
        self.lastSeen = lastSeen
    }
}

/// What the app has seen of one poller.
public struct ToolSighting: Codable, Equatable, Sendable, Identifiable {
    /// The poller: `linear`, `jira`, `github` or `expiry` (its cards' source agent).
    public var id: String
    /// Machines that posted its cards, with when each last did.
    public var hosts: [String: Date] = [:]
    /// The account: the Linear workspace (from its issue links), the Jira site's host, or a
    /// GitHub owner. With when each was last seen.
    public var accounts: [String: Date] = [:]
    /// Teams, projects or repos, by name.
    public var scopes: [String: ToolScope] = [:]
    /// GitHub's opt-ins seen at work: `projects` (Projects statuses), `dependabot`.
    public var features: Set<String> = []
    /// The context of its newest card (expiry has no scopes, so this is its setting).
    public var context: ItemContext = .work
    public var lastSeen: Date

    public init(id: String, lastSeen: Date) {
        self.id = id
        self.lastSeen = lastSeen
    }

    /// Hosts, accounts and scopes, newest first.
    public var hostNames: [String] { Self.newestFirst(hosts) }
    public var accountNames: [String] { Self.newestFirst(accounts) }
    public var scopeList: [ToolScope] {
        scopes.values.sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : $0.name < $1.name }
    }

    /// GitHub's scopes grouped by owner (the poller's context is per owner, or per repo).
    public var owners: [(owner: String, repos: [ToolScope])] {
        var by: [String: [ToolScope]] = [:]
        for s in scopeList { by[ToolSightings.owner(of: s.name), default: []].append(s) }
        return by.map { ($0.key, $0.value) }.sorted { a, b in
            (a.repos.first?.lastSeen ?? .distantPast) > (b.repos.first?.lastSeen ?? .distantPast)
        }
    }

    static func newestFirst(_ dict: [String: Date]) -> [String] {
        dict.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

public struct ToolSightings: Codable, Equatable, Sendable {
    /// By poller id.
    public private(set) var tools: [String: ToolSighting] = [:]

    /// The pollers, in the order the page lists them.
    public static let order = ["linear", "jira", "github", "expiry"]
    /// Forgotten after this long without a card.
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxScopes = 40
    static let maxAccounts = 8
    static let maxHosts = 8
    /// A newer card than this moves `lastSeen` (and is worth saving); closer ones don't.
    static let refreshEvery: TimeInterval = 3600

    public init() {}

    /// The pollers seen, in page order.
    public var all: [ToolSighting] { Self.order.compactMap { tools[$0] } }

    public func tool(_ id: String) -> ToolSighting? { tools[id] }

    public var isEmpty: Bool { tools.isEmpty }

    // MARK: Names

    /// Patterns for the names kept (the same shapes `needs-you context` takes).
    static let teamPattern = #"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$"#
    static let jiraProjectPattern = #"^[A-Z][A-Z0-9_]{0,30}$"#
    static let repoPattern = #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$"#
    static let ownerPattern = #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#
    static let hostPattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#
    static let siteHostPattern = #"^[A-Za-z0-9]([A-Za-z0-9-]{0,62}\.)+[A-Za-z]{2,63}$"#
    static let linearLinkPattern = #"^https://linear\.app/([A-Za-z0-9][A-Za-z0-9_-]{0,63})/issue/"#

    static func fits(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func owner(of repo: String) -> String {
        String(repo.split(separator: "/", maxSplits: 1).first ?? "").lowercased()
    }

    // MARK: Recording

    /// Takes in a poll's items (open or closed). True when something worth saving changed:
    /// a new host, account, team, project or repo, a context that changed, or a card more
    /// than an hour newer than the last one. Setup cards and tombstones don't count.
    @discardableResult
    public mutating func record(_ items: [Item], now: Date = Date()) -> Bool {
        var changed = false
        for item in items {
            if record(item) { changed = true }
        }
        if prune(now: now) { changed = true }
        return changed
    }

    private mutating func record(_ item: Item) -> Bool {
        guard !item.tombstone, SetupChecklist.tip(forItemID: item.id) == nil,
              let agent = item.source?.agent?.lowercased(), Self.order.contains(agent) else { return false }
        // Whole seconds, so what was saved loads back equal.
        let seen = Date(timeIntervalSince1970: item.updatedAt.timeIntervalSince1970.rounded())
        var tool = tools[agent] ?? ToolSighting(id: agent, lastSeen: seen)
        var changed = tools[agent] == nil

        if let host = item.source?.host, Self.fits(host, Self.hostPattern) {
            changed = Self.bump(&tool.hosts, host.lowercased(), seen) || changed
        }
        let project = item.source?.project ?? ""
        switch agent {
        case "linear":
            for link in item.links {
                if let ws = Self.firstGroup(link.url, Self.linearLinkPattern) {
                    changed = Self.bump(&tool.accounts, ws.lowercased(), seen) || changed
                    break
                }
            }
            if project.lowercased() != "linear", Self.fits(project, Self.teamPattern) {
                changed = Self.bumpScope(&tool, project.uppercased(), item.context, seen) || changed
            }
        case "jira":
            for link in item.links {
                if let url = URL(string: link.url), url.scheme == "https", url.path.contains("/browse/"),
                   let host = url.host?.lowercased(), Self.fits(host, Self.siteHostPattern) {
                    changed = Self.bump(&tool.accounts, host, seen) || changed
                    break
                }
            }
            if Self.fits(project, Self.jiraProjectPattern) {
                changed = Self.bumpScope(&tool, project, item.context, seen) || changed
            }
        case "github":
            if Self.fits(project, Self.repoPattern) {
                let repo = project.lowercased()
                changed = Self.bump(&tool.accounts, Self.owner(of: repo), seen) || changed
                changed = Self.bumpScope(&tool, repo, item.context, seen) || changed
                let feature: String?
                if item.source?.event == "security" || item.key.contains(":security:") {
                    feature = "dependabot"
                } else if item.source?.event == "status", item.links.contains(where: { $0.label == "Project" }) {
                    feature = "projects"
                } else {
                    feature = nil
                }
                if let feature, !tool.features.contains(feature) {
                    tool.features.insert(feature)
                    changed = true
                }
            }
        default:
            break
        }
        if seen >= tool.lastSeen {
            // Only expiry's own context is a setting the page shows; the others' are per scope.
            if tool.context != item.context, agent == "expiry" { changed = true }
            tool.context = item.context
            if seen.timeIntervalSince(tool.lastSeen) > Self.refreshEvery { changed = true }
            tool.lastSeen = seen
        }
        tools[agent] = tool
        return changed
    }

    /// Newest wins. True for a new name or one more than an hour newer.
    private static func bump(_ dict: inout [String: Date], _ name: String, _ seen: Date) -> Bool {
        guard let old = dict[name] else { dict[name] = seen; return true }
        if seen > old { dict[name] = seen }
        return seen.timeIntervalSince(old) > refreshEvery
    }

    private static func bumpScope(_ tool: inout ToolSighting, _ name: String, _ ctx: ItemContext, _ seen: Date) -> Bool {
        guard let old = tool.scopes[name] else {
            tool.scopes[name] = ToolScope(name: name, context: ctx, lastSeen: seen)
            return true
        }
        guard seen >= old.lastSeen else { return false }
        tool.scopes[name] = ToolScope(name: name, context: ctx, lastSeen: seen)
        return old.context != ctx || seen.timeIntervalSince(old.lastSeen) > refreshEvery
    }

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Drops what's older than `maxAge` and keeps the newest few of each. True if it dropped anything.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let before = tools
        for (id, var tool) in tools {
            if tool.lastSeen < cutoff { tools[id] = nil; continue }
            tool.hosts = Self.keepNewest(tool.hosts.filter { $0.value >= cutoff }, Self.maxHosts)
            tool.accounts = Self.keepNewest(tool.accounts.filter { $0.value >= cutoff }, Self.maxAccounts)
            let scopes = tool.scopes.filter { $0.value.lastSeen >= cutoff }
            let kept = Set(scopes.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxScopes).map(\.name))
            tool.scopes = scopes.filter { kept.contains($0.key) }
            tools[id] = tool
        }
        return tools != before
    }

    private static func keepNewest(_ dict: [String: Date], _ n: Int) -> [String: Date] {
        guard dict.count > n else { return dict }
        let kept = Set(ToolSighting.newestFirst(dict).prefix(n))
        return dict.filter { kept.contains($0.key) }
    }

    /// Forgets one poller (Settings → Your tools → Forget, after it was taken down).
    public mutating func forget(_ id: String) { tools[id] = nil }

    // MARK: Storage

    public static func load(from defaults: UserDefaults, key: String) -> ToolSightings {
        guard let data = defaults.data(forKey: key),
              var s = try? JSONDecoder().decode(ToolSightings.self, from: data) else { return ToolSightings() }
        // Bounded and clean however it was written.
        s.tools = s.tools.filter { order.contains($0.key) && $0.key == $0.value.id }
        s.prune(now: Date())
        return s
    }

    public func save(to defaults: UserDefaults, key: String) {
        if tools.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Work or personal: the command for the poller's machine

/// `needs-you context` lines (cli/needs-you): the Mac can't write a sender machine's env
/// file, so a Work / Personal picker hands the person the command to run there.
public enum ToolContextCommand {
    /// `~/.local/bin/needs-you context linear ACME personal`, or nil for a name the CLI
    /// wouldn't take (never quoted into a shell line). `name` nil: the whole poller (`*`).
    public static func line(tool: String, name: String?, context: ItemContext) -> String? {
        let target: String
        switch (tool, name) {
        case ("expiry", nil), ("linear", nil), ("jira", nil), ("github", nil):
            target = "'*'"
        case ("linear", let n?) where ToolSightings.fits(n, ToolSightings.teamPattern):
            target = n.uppercased()
        case ("jira", let n?) where ToolSightings.fits(n, ToolSightings.jiraProjectPattern):
            target = n
        case ("github", let n?) where ToolSightings.fits(n, ToolSightings.ownerPattern)
            || ToolSightings.fits(n, ToolSightings.repoPattern):
            target = n.lowercased()
        default:
            return nil
        }
        return "~/.local/bin/needs-you context \(tool) \(target) \(context.rawValue)"
    }

    /// What to do with the lines, for the page.
    public static func instructions(host: String?) -> String {
        let on = host.map { "on \($0)" } ?? "on the machine that runs the poller"
        return "Run this \(on). Cards posted from then on carry the new context; open ones move over on the poller's next run. "
            + "If it says `invalid choice: 'context'`, run `~/.local/bin/needs-you update` there first."
    }
}

// MARK: - Your tools: pollers already sending cards

/// Settings → Integrations → Your tools: one row per poller seen at work (ToolSightings),
/// with what it watches, a Work / Personal picker per team, project or owner, and Add
/// another where a second one makes sense.
public enum ConfiguredTools {
    public static func name(_ tool: String) -> String {
        switch tool {
        case "linear": return "Linear"
        case "jira": return "Jira"
        case "github": return "GitHub"
        case "expiry": return "Expiry dates"
        default: return tool
        }
    }

    public static func symbol(_ tool: String) -> String {
        switch tool {
        case "github": return "chevron.left.forwardslash.chevron.right"
        default: return IntegrationCatalog.integration(id: tool)?.symbol ?? "puzzlepiece.extension"
        }
    }

    /// The poller's guide (https, so it passes the link allow-list).
    public static func guideURL(_ tool: String) -> String {
        SetupChecklist.guideURL("\(tool).md")
    }

    /// Does a catalog row's poller already send cards? GitHub's opt-ins count once their
    /// own cards were seen, not just any GitHub card.
    public static func isSending(_ integration: Integration, in sightings: ToolSightings) -> Bool {
        switch integration.id {
        case "github-projects": return sightings.tool("github")?.features.contains("projects") ?? false
        case "dependabot": return sightings.tool("github")?.features.contains("dependabot") ?? false
        default: return sightings.tool(integration.id) != nil
        }
    }

    /// The line under the poller's name: what it watches and where it runs.
    public static func detail(_ tool: ToolSighting) -> String {
        var parts: [String] = []
        let scopes = tool.scopeList.map(\.name)
        switch tool.id {
        case "linear":
            if !tool.accountNames.isEmpty { parts.append(list("Workspace", "Workspaces", tool.accountNames)) }
            if !scopes.isEmpty { parts.append(list("team", "teams", scopes)) }
        case "jira":
            if !tool.accountNames.isEmpty { parts.append(tool.accountNames.joined(separator: ", ")) }
            if !scopes.isEmpty { parts.append(list("project", "projects", scopes)) }
        case "github":
            let owners = tool.owners.map(\.owner)
            if !owners.isEmpty {
                parts.append(owners.prefix(4).joined(separator: ", ") + (owners.count > 4 ? " and \(owners.count - 4) more" : ""))
            }
            if !scopes.isEmpty { parts.append(scopes.count == 1 ? "1 repo" : "\(scopes.count) repos") }
            if tool.features.contains("projects") { parts.append("Projects statuses") }
            if tool.features.contains("dependabot") { parts.append("Dependabot alerts") }
        default:
            parts.append(tool.context == .personal ? "Personal" : "Work")
        }
        if !tool.hostNames.isEmpty { parts.append("on " + tool.hostNames.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private static func list(_ one: String, _ many: String, _ names: [String]) -> String {
        let shown = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
        return (names.count == 1 ? one : many) + " " + shown
    }

    /// The Add another button's title, or nil where one poller covers everything (GitHub
    /// watches every repo whose notifications you get).
    public static func addAnotherTitle(_ tool: String) -> String? {
        switch tool {
        case "linear": return "Add another workspace"
        case "jira": return "Add another Jira site"
        case "expiry": return "Watch more"
        default: return nil
        }
    }

    static func secondCron(_ env: String, _ executable: String, _ state: String) -> String {
        "(crontab -l 2>/dev/null; echo '*/5 * * * * \(env) $HOME/.local/bin/\(executable) "
            + "--state $HOME/.local/state/needs-you/\(state).json >/dev/null  # \(executable)-2') | crontab -"
    }

    /// What Add another copies: a prompt for an agent on the poller's machine. Like the
    /// setup prompts, it holds no token and has the person put theirs in place.
    public static func addAnotherPrompt(_ tool: String, host: String?) -> String? {
        let here = host.map { "on this machine (\($0))" } ?? "on this machine"
        let keep = "Settings go in ~/.config/needs-you/env, which also holds this machine's needs-you token: "
            + "never print, read out or rewrite it."
        let end = "If a run prints an error, fix what it names, or tell me if it needs me."
        switch tool {
        case "linear":
            let file = "~/.config/needs-you/linear-key-2"
            let env = "NEEDS_YOU_LINEAR_KEY_FILE=$HOME/.config/needs-you/linear-key-2"
            return [
                "Add a second Linear workspace to needs-you \(here). needs-you-linear already runs here for one "
                    + "workspace; the guide is \(IntegrationCatalog.linear.guideURL).",
                "The second one reads its own key, from \(file), which must be mine and mode 600. Never ask me for "
                    + "the key in chat, never print it, and never put it in ~/.config/needs-you/env, a cron line, a "
                    + "command or any file you write. Ask me to run this in my own terminal and paste the second "
                    + "workspace's Linear personal API key there myself (paste it, press Enter, then Ctrl-D), and wait "
                    + "until I say it's done: `(umask 077 && mkdir -p ~/.config/needs-you && cat > \(file))`. Then "
                    + "check only the file's mode with `ls -l \(file)`: never read the file.",
                keep,
                "Run `\(env) ~/.local/bin/needs-you-linear --state ~/.local/state/needs-you/linear-2.json --dry-run -v` "
                    + "and tell me what it says.",
                "Schedule it next to the first one. On Linux add the cron line: "
                    + "`\(secondCron(env, "needs-you-linear", "linear-2"))`. On macOS copy the needs-you-linear "
                    + "LaunchAgent to io.needs-you.linear-2.plist with its own Label, NEEDS_YOU_LINEAR_KEY_FILE in its "
                    + "EnvironmentVariables and `--state` with linear-2.json in its arguments, and load it.",
                end,
            ].joined(separator: "\n")
        case "jira":
            let file = "~/.config/needs-you/jira-token-2"
            return [
                "Add a second Jira site to needs-you \(here). needs-you-jira already runs here for one site; the "
                    + "guide is \(IntegrationCatalog.jira.guideURL).",
                "Ask me for the second site's URL (https://...) and, for Jira Cloud, the email I sign in with there. "
                    + "They go in the second run's own settings below, not in ~/.config/needs-you/env.",
                "Its token goes in \(file), which must be mine and mode 600. Never ask me for the token in chat, never "
                    + "print it, and never put it in ~/.config/needs-you/env, a cron line, a command or any file you "
                    + "write. Ask me to run this in my own terminal and type the token there myself (it isn't shown; "
                    + "press Enter after it), and wait until I say it's done: `mkdir -p ~/.config/needs-you && (umask 077; "
                    + "printf 'Jira token: '; read -rs t; printf '%s\\n' \"$t\" > \(file)); echo`. Then check only the "
                    + "file's mode with `ls -l \(file)`: never read the file.",
                keep,
                "Run `NEEDS_YOU_JIRA_SITE=<site> NEEDS_YOU_JIRA_EMAIL=<email> "
                    + "NEEDS_YOU_JIRA_TOKEN_FILE=$HOME/.config/needs-you/jira-token-2 ~/.local/bin/needs-you-jira "
                    + "--state ~/.local/state/needs-you/jira-2.json -v` with my answers (leave out NEEDS_YOU_JIRA_EMAIL "
                    + "for Data Center) and tell me what it says. Its first run only records my open issues and posts nothing.",
                "Schedule it next to the first one, every 5 minutes with the same three settings and --state: on Linux "
                    + "a second cron line ending in `# needs-you-jira-2`; on macOS a copy of the needs-you-jira "
                    + "LaunchAgent named io.needs-you.jira-2.plist with its own Label, the settings in its "
                    + "EnvironmentVariables and `--state` with jira-2.json in its arguments.",
                end,
            ].joined(separator: "\n")
        case "expiry":
            return [
                "Add to what needs-you-expiry watches \(here). The guide is \(IntegrationCatalog.expiry.guideURL).",
                "Ask me what else to watch: hosts whose TLS certificate matters, domains I own, and keys or tokens with "
                    + "the date each stops working. Append them to ~/.config/needs-you/expiry.conf, one per line, keeping "
                    + "the lines already there: `tls example.com`, `domain example.com`, "
                    + "`key \"Figma PAT\" 2026-12-31 renew=https://www.figma.com/settings`. Add `context=personal` to a "
                    + "line that's personal. A key line holds only the key's name and date, never the key itself.",
                "Run `~/.local/bin/needs-you-expiry --dry-run -v` and tell me what it says.",
                end,
            ].joined(separator: "\n")
        default:
            return nil
        }
    }
}
