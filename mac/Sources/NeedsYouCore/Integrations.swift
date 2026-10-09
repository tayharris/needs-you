import Foundation

// Settings → Integrations → Cards from your tools: the pollers that turn another tool into
// cards (Linear, Jira, GitHub Projects statuses, Dependabot alerts, expiry dates). Each runs
// on one always-on sender machine, from cron or a LaunchAgent; the Mac app only explains
// them: what each does, its settings, the commands, and a prompt to paste into an agent on
// that machine. Kept here, in Core, so tests can hold every name and command to the scripts
// and guides they come from (IntegrationCatalogTests, tests/test_integration_catalog.py).
//
// Tokens are never shown or put in a prompt. A prompt tells the agent where the poller
// reads its token (a mode-600 file, or gh's own login) and to have the person paste it in
// there themselves.

/// One setting a poller reads from ~/.config/needs-you/env (or the environment).
public struct IntegrationSetting: Equatable, Sendable {
    /// The variable, as the script reads it: `NEEDS_YOU_LINEAR_TEAMS`.
    public var name: String
    /// What it does and its default, in a few words.
    public var detail: String
    /// An example line for the env file, or nil when it's not something to set by hand.
    public var example: String?

    public init(_ name: String, _ detail: String, example: String? = nil) {
        self.name = name
        self.detail = detail
        self.example = example
    }
}

/// Where a poller's credential lives. Never the credential itself.
public enum IntegrationSecret: Equatable, Sendable {
    /// No account or token.
    case none
    /// A file only the person can read (mode 600), which they fill in themselves.
    /// `noun` is what goes in it ("Linear personal API key"); `store` is the command that
    /// creates it and reads the secret from the keyboard (never an argument); `keys` says
    /// how to finish typing it there.
    case file(path: String, noun: String, store: String, keys: String)
    /// gh's own login, plus a scope added with `gh auth refresh -s <scope>`.
    case ghScope(String)

    /// The file path, for `.file`.
    public var path: String? {
        if case .file(let path, _, _, _) = self { return path }
        return nil
    }

    /// The gh scope, for `.ghScope`.
    public var scope: String? {
        if case .ghScope(let scope) = self { return scope }
        return nil
    }
}

/// One command in an integration's setup, with a Copy button.
public struct IntegrationCommand: Equatable, Sendable {
    public var title: String
    public var command: String

    public init(_ title: String, _ command: String) {
        self.title = title
        self.command = command
    }
}

/// One tool that can send cards, as Settings → Integrations lists it.
public struct Integration: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The name inside a sentence: "Set up needs-you cards for <subject> on this machine."
    public var subject: String
    /// SF Symbol.
    public var symbol: String
    /// One or two plain sentences: what cards it sends and when they clear.
    public var summary: String
    /// What it needs, one sentence (the token's home, or gh's scope).
    public var needs: String
    /// The poller, under integrations/: `linear/needs-you-linear`.
    public var script: String
    /// Its guide, under docs/guides/ (with an anchor when it's a section).
    public var guide: String
    public var secret: IntegrationSecret
    /// The settings worth knowing, as the script names them.
    public var settings: [IntegrationSetting]
    /// Install, store the token, try it, schedule it: each one copyable.
    public var commands: [IntegrationCommand]
    /// The integration-specific middle of the agent prompt: what to ask the person and
    /// what to write where.
    var configure: [String]

    /// The poller's file name: `needs-you-linear`.
    public var executable: String { (script as NSString).lastPathComponent }

    /// The LaunchAgent next to the script: `integrations/linear/io.needs-you.linear.plist`.
    public var launchAgent: String {
        let dir = (script as NSString).deletingLastPathComponent
        return "integrations/\(dir)/io.needs-you.\(dir).plist"
    }

    /// The guide on GitHub (https, so it passes the link allow-list).
    public var guideURL: String {
        let parts = guide.split(separator: "#", maxSplits: 1).map(String.init)
        let base = SetupChecklist.guideURL(parts[0])
        return parts.count == 2 ? base + "#" + parts[1] : base
    }

    /// The commands' text, for checks: install, store, dry run, schedule.
    func command(_ title: String) -> String? { commands.first { $0.title == title }?.command }

    /// What to paste into an agent on the machine that will run the poller. Like the
    /// invite's agent prompt: plain steps the agent follows, ending with a check. It holds
    /// no token: it says where the token goes and has the person put it there.
    public var agentPrompt: String {
        var lines: [String] = []
        lines.append("Set up needs-you cards for \(subject) on this machine. The guide is \(guideURL).")
        lines.append("This machine must already send needs-you alerts: if ~/.local/bin/needs-you is missing "
                     + "or ~/.local/bin/needs-you doctor shows a FAIL, stop and ask me for an invite link "
                     + "(Needs You on my Mac: Settings → Connect a machine).")
        if let install = command(IntegrationCatalog.installTitle) {
            lines.append(IntegrationCatalog.installStep(self, install))
        }
        switch secret {
        case .none:
            break
        case .file(let path, let noun, let store, let keys):
            lines.append("\(executable) reads my \(noun) from \(path), which must be mine and mode 600. "
                         + "Never ask me for the \(noun) in chat, never print it, and never put it in "
                         + "~/.config/needs-you/env, a cron line, a command or any file you write. Ask me to "
                         + "run this in my own terminal and paste the \(noun) there myself (\(keys)), and wait "
                         + "until I say it's done: `\(store)`. Then check only the file's mode with `ls -l \(path)`: "
                         + "never read the file.")
        case .ghScope(let scope):
            lines.append("\(executable) uses this machine's gh login (`gh auth status` must say Logged in) and "
                         + "needs gh's \(scope) scope. Ask me to run `gh auth refresh -s \(scope)` in my own "
                         + "terminal (it signs in in the browser), and wait until I say it's done. Never ask "
                         + "me for a GitHub token and never print one.")
        }
        lines.append("Settings go in ~/.config/needs-you/env, which also holds this machine's needs-you token: "
                     + "only append lines to it (`echo 'NAME=value' >> ~/.config/needs-you/env`), never "
                     + "print, read out or rewrite it.")
        lines += configure
        if let dry = command(IntegrationCatalog.tryTitle) {
            lines.append("Run `\(dry)` and tell me what it says.")
        }
        if let cron = command(IntegrationCatalog.scheduleTitle) {
            lines.append(IntegrationCatalog.scheduleStep(self, cron))
        }
        lines.append("If a run prints an error, fix what it names, or tell me if it needs me.")
        return lines.joined(separator: "\n")
    }
}

public enum IntegrationCatalog {
    static let installTitle = "Install"
    static let storeTitle = "Store the token"
    static let tryTitle = "Try it"
    static let scheduleTitle = "Run it on a schedule"

    /// The pollers in Settings order.
    public static let all: [Integration] = [linear, jira, githubProjects, dependabot, expiry]

    public static func integration(id: String) -> Integration? { all.first { $0.id == id } }

    /// The item source agents the pollers post as (`--agent=...`), for the setup tip.
    public static let sourceAgents: Set<String> = ["linear", "jira", "github", "expiry"]

    static func raw(_ path: String) -> String {
        "curl -fsSL https://raw.githubusercontent.com/\(UpdateSource.defaultRepository)/main/integrations/\(path) "
            + "-o ~/.local/bin/\((path as NSString).lastPathComponent) && chmod 755 ~/.local/bin/\((path as NSString).lastPathComponent)"
    }

    static func ghRaw(_ path: String) -> String {
        "gh api -H 'Accept: application/vnd.github.raw' repos/\(UpdateSource.defaultRepository)/contents/integrations/\(path) "
            + "> ~/.local/bin/\((path as NSString).lastPathComponent) && chmod 755 ~/.local/bin/\((path as NSString).lastPathComponent)"
    }

    static func cron(_ schedule: String, _ executable: String) -> String {
        "(crontab -l 2>/dev/null; echo '\(schedule) $HOME/.local/bin/\(executable) >/dev/null  # \(executable)') | crontab -"
    }

    static func installStep(_ i: Integration, _ install: String) -> String {
        if i.script.hasPrefix("github/") {
            return "If ~/.local/bin/\(i.executable) isn't there yet, install it: `\(install)`. "
                + "It also posts cards for review requests, deploys waiting for approval, failed CI and my "
                + "own pull requests (NEEDS_YOU_GITHUB_REASONS turns some off)."
        }
        return "Install the poller: `\(install)`."
    }

    static func scheduleStep(_ i: Integration, _ cron: String) -> String {
        let already = i.script.hasPrefix("github/") ? " If `crontab -l` already lists \(i.executable), it's scheduled: skip this." : ""
        return "Schedule it. On Linux add the cron line: `\(cron)`. On macOS use the LaunchAgent "
            + "\(i.launchAgent) from the repo instead (replace /Users/me with my home directory)." + already
    }

    // MARK: The integrations

    public static let linear = Integration(
        id: "linear", name: "Linear", subject: "Linear", symbol: "checklist",
        summary: "A card per Linear issue when it's assigned to you, gets a comment or a mention, or changes status. "
            + "It clears when you read the notification in Linear or the issue is done.",
        needs: "A Linear personal API key (read-only is enough), in ~/.config/needs-you/linear-key, mode 600.",
        script: "linear/needs-you-linear", guide: "linear.md",
        secret: .file(path: "~/.config/needs-you/linear-key", noun: "Linear personal API key",
                      store: "(umask 077 && mkdir -p ~/.config/needs-you && cat > ~/.config/needs-you/linear-key)",
                      keys: "paste it, press Enter, then Ctrl-D"),
        settings: [
            IntegrationSetting("NEEDS_YOU_LINEAR_KEY_FILE", "The key file. Default ~/.config/needs-you/linear-key."),
            IntegrationSetting("NEEDS_YOU_LINEAR_TEAMS", "Only these teams, with their context and base priority. Default: every team.",
                               example: "NEEDS_YOU_LINEAR_TEAMS=ACME=work:normal,OPS=work:urgent"),
            IntegrationSetting("NEEDS_YOU_LINEAR_STATUSES", "Priority by status; off = no status-change card. Default *=low.",
                               example: "NEEDS_YOU_LINEAR_STATUSES=Blocked=urgent,In Review=normal,Backlog=off,*=low"),
            IntegrationSetting("NEEDS_YOU_LINEAR_CATEGORIES", "Events to post: assigned, status, comment, mention. Default all.",
                               example: "NEEDS_YOU_LINEAR_CATEGORIES=-mention"),
        ],
        commands: [
            IntegrationCommand(installTitle, raw("linear/needs-you-linear")),
            IntegrationCommand(storeTitle, "(umask 077 && mkdir -p ~/.config/needs-you && cat > ~/.config/needs-you/linear-key)"),
            IntegrationCommand(tryTitle, "~/.local/bin/needs-you-linear --dry-run -v"),
            IntegrationCommand(scheduleTitle, cron("*/5 * * * *", "needs-you-linear")),
        ],
        configure: [
            "Ask me which Linear teams to watch. If I name some, append NEEDS_YOU_LINEAR_TEAMS with them, "
                + "like NEEDS_YOU_LINEAR_TEAMS=ACME=work:normal; otherwise it watches every team.",
        ])

    public static let jira = Integration(
        id: "jira", name: "Jira", subject: "Jira", symbol: "list.bullet.rectangle",
        summary: "A card per Jira issue assigned to you when someone moves it, comments, mentions you or assigns it to you. "
            + "It clears when the issue is done, when you act on it yourself, or after a day.",
        needs: "Your Jira site, and an API token (Cloud, with your email) or a personal access token (Data Center) "
            + "in ~/.config/needs-you/jira-token, mode 600.",
        script: "jira/needs-you-jira", guide: "jira.md",
        secret: .file(path: "~/.config/needs-you/jira-token", noun: "Jira token",
                      store: "mkdir -p ~/.config/needs-you && (umask 077; printf 'Jira token: '; read -rs t; printf '%s\\n' \"$t\" > ~/.config/needs-you/jira-token); echo",
                      keys: "it isn't shown; press Enter after it"),
        settings: [
            IntegrationSetting("NEEDS_YOU_JIRA_SITE", "Your Jira, https only. Unset: the poller does nothing.",
                               example: "NEEDS_YOU_JIRA_SITE=https://acme.atlassian.net"),
            IntegrationSetting("NEEDS_YOU_JIRA_EMAIL", "Your Atlassian account email (Jira Cloud only).",
                               example: "NEEDS_YOU_JIRA_EMAIL=me@acme.example"),
            IntegrationSetting("NEEDS_YOU_JIRA_TOKEN_FILE", "The token file. Default ~/.config/needs-you/jira-token."),
            IntegrationSetting("NEEDS_YOU_JIRA_STATUSES", "Priority by status; off = no status card. Default: every status change, low.",
                               example: "NEEDS_YOU_JIRA_STATUSES=Blocked=urgent,In Review=normal,*=low"),
            IntegrationSetting("NEEDS_YOU_JIRA_PROJECTS", "Only these projects, with their context and base priority. Default: every project.",
                               example: "NEEDS_YOU_JIRA_PROJECTS=ACME=work:normal,OPS=work:urgent"),
            IntegrationSetting("NEEDS_YOU_JIRA_EVENTS", "Events to post: status, comment, assigned, mention. Default all.",
                               example: "NEEDS_YOU_JIRA_EVENTS=-assigned"),
        ],
        commands: [
            IntegrationCommand(installTitle, raw("jira/needs-you-jira")),
            IntegrationCommand(storeTitle, "mkdir -p ~/.config/needs-you && (umask 077; printf 'Jira token: '; read -rs t; printf '%s\\n' \"$t\" > ~/.config/needs-you/jira-token); echo"),
            IntegrationCommand(tryTitle, "~/.local/bin/needs-you-jira -v"),
            IntegrationCommand(scheduleTitle, cron("*/5 * * * *", "needs-you-jira")),
        ],
        configure: [
            "Ask me for my Jira site URL and append it as NEEDS_YOU_JIRA_SITE=https://... . For Jira Cloud "
                + "(a site on atlassian.net) also ask for the email I sign in with and append NEEDS_YOU_JIRA_EMAIL. "
                + "The token is an API token from id.atlassian.com for Cloud, or a personal access token for Data Center.",
            "Its first run only records my open issues and posts nothing.",
        ])

    public static let githubProjects = Integration(
        id: "github-projects", name: "GitHub Projects statuses", subject: "GitHub Projects statuses", symbol: "rectangle.split.3x1",
        summary: "A card when an issue or pull request assigned to you moves to a status you name in a GitHub project, "
            + "such as Blocked. It clears when the status moves on, the issue closes or you're unassigned.",
        needs: "gh logged in on that machine, with the read:project scope. Part of the GitHub poller.",
        script: "github/needs-you-github", guide: "github.md#projects-statuses-and-dependabot-alerts-opt-in",
        secret: .ghScope("read:project"),
        settings: [
            IntegrationSetting("NEEDS_YOU_GITHUB_PROJECT_STATUSES", "The statuses that make a card, with a priority. Default: none (off).",
                               example: "NEEDS_YOU_GITHUB_PROJECT_STATUSES=Blocked=urgent,In Review=normal"),
            IntegrationSetting("NEEDS_YOU_GITHUB_PROJECT_FIELD", "The single-select field to watch. Default Status."),
        ],
        commands: [
            IntegrationCommand(installTitle, ghRaw("github/needs-you-github")),
            IntegrationCommand("Add the scope", "gh auth refresh -s read:project"),
            IntegrationCommand(tryTitle, "~/.local/bin/needs-you-github --dry-run -v"),
            IntegrationCommand(scheduleTitle, cron("*/5 * * * *", "needs-you-github")),
        ],
        configure: [
            "Ask me which project statuses need me and how urgent each is, and append them like "
                + "NEEDS_YOU_GITHUB_PROJECT_STATUSES=Blocked=urgent,In Review=normal. If my projects call the field "
                + "something other than Status, also append NEEDS_YOU_GITHUB_PROJECT_FIELD with its name.",
            "Its first run only notes where everything is and posts no status cards.",
        ])

    public static let dependabot = Integration(
        id: "dependabot", name: "Dependabot alerts", subject: "Dependabot alerts", symbol: "shield.lefthalf.filled",
        summary: "A low card per open critical Dependabot alert when GitHub sends you a security alert notification. "
            + "It clears when the alert is fixed or dismissed, or you read the notification.",
        needs: "gh logged in on that machine, with the security_events scope. Part of the GitHub poller.",
        script: "github/needs-you-github", guide: "github.md#projects-statuses-and-dependabot-alerts-opt-in",
        secret: .ghScope("security_events"),
        settings: [
            IntegrationSetting("NEEDS_YOU_GITHUB_SECURITY", "1 turns these cards on. Default off.",
                               example: "NEEDS_YOU_GITHUB_SECURITY=1"),
            IntegrationSetting("NEEDS_YOU_GITHUB_SECURITY_SEVERITIES", "Which severities. Default critical.",
                               example: "NEEDS_YOU_GITHUB_SECURITY_SEVERITIES=critical,high"),
            IntegrationSetting("NEEDS_YOU_GITHUB_SECURITY_PRIORITY", "The cards' priority. Default low."),
        ],
        commands: [
            IntegrationCommand(installTitle, ghRaw("github/needs-you-github")),
            IntegrationCommand("Add the scope", "gh auth refresh -s security_events"),
            IntegrationCommand(tryTitle, "~/.local/bin/needs-you-github --dry-run -v"),
            IntegrationCommand(scheduleTitle, cron("*/5 * * * *", "needs-you-github")),
        ],
        configure: [
            "Append NEEDS_YOU_GITHUB_SECURITY=1. Ask me whether high alerts should count too; if so, also "
                + "append NEEDS_YOU_GITHUB_SECURITY_SEVERITIES=critical,high.",
        ])

    public static let expiry = Integration(
        id: "expiry", name: "Expiring certificates, domains and keys",
        subject: "expiring certificates, domains and keys", symbol: "calendar.badge.clock",
        summary: "A card 30 days before a TLS certificate, a domain or an API key you list expires, louder as the day nears. "
            + "It clears when you renew.",
        needs: "No account or token: a list of what to watch in ~/.config/needs-you/expiry.conf.",
        script: "expiry/needs-you-expiry", guide: "expiry.md",
        secret: .none,
        settings: [
            IntegrationSetting("NEEDS_YOU_EXPIRY_CONFIG", "The list. Default expiry.conf next to the env file."),
            IntegrationSetting("NEEDS_YOU_EXPIRY_DAYS", "When cards appear and how loud. Default 30=low,7=normal,1=urgent.",
                               example: "NEEDS_YOU_EXPIRY_DAYS=60=low,14=normal,3=urgent"),
            IntegrationSetting("NEEDS_YOU_EXPIRY_CONTEXT", "work or personal. Default work.",
                               example: "NEEDS_YOU_EXPIRY_CONTEXT=personal"),
        ],
        commands: [
            IntegrationCommand(installTitle, ghRaw("expiry/needs-you-expiry")),
            IntegrationCommand(tryTitle, "~/.local/bin/needs-you-expiry --dry-run -v"),
            IntegrationCommand(scheduleTitle, cron("17 9 * * *", "needs-you-expiry")),
        ],
        configure: [
            "Ask me what to watch: hosts whose TLS certificate matters, domains I own, and keys or tokens with the "
                + "date each stops working. Write them to ~/.config/needs-you/expiry.conf, one per line: "
                + "`tls example.com`, `domain example.com`, `key \"Figma PAT\" 2026-12-31 renew=https://www.figma.com/settings`. "
                + "A key line holds only the key's name and date, never the key itself.",
        ])
}
