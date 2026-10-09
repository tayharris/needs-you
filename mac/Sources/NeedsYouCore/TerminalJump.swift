import Foundation

/// The card's terminal link for sessions outside Orca:
/// `needsyou://terminal/focus?app=<app>&<id>` (docs/API.md, "Links").
///
/// | app        | id parameters                                              | how |
/// |------------|------------------------------------------------------------|-----|
/// | `wezterm`  | `pane=<n>`                                                 | `wezterm cli activate-pane` |
/// | `tmux`     | `pane=<n>` (`%<n>`) or `target=<session>:<window>.<pane>`, optional `host=<terminal>` | `tmux select-window` / `select-pane` |
/// | `iterm`    | `session=<UUID>` or `tty=/dev/ttys<n>`                      | AppleScript, opt-in |
/// | `terminal` | `tty=/dev/ttys<n>`                                          | AppleScript, opt-in |
/// | `ghostty`  | none                                                       | bring Ghostty forward |
///
/// Senders only hold a token, so this is parsed into a typed value whose every field
/// passes a strict pattern; anything else (an unknown or repeated parameter, a value
/// outside its pattern) is nil and does nothing. No value can start with `-`, so none can
/// be read as a flag. The runner (`TerminalJumpRunner` in the app) uses only `arguments`
/// with a CLI from `cliPaths` (never PATH, never a shell), or a fixed AppleScript handler
/// with the value as a typed parameter. If abused, a sender can switch which terminal tab
/// is shown, and nothing else.
public struct TerminalJump: Equatable, Sendable {
    public enum App: String, CaseIterable, Sendable {
        case wezterm, tmux, iterm, terminal, ghostty

        /// The macOS app brought forward after the switch.
        public var bundleID: String? {
            switch self {
            case .wezterm: return "com.github.wez.wezterm"
            case .iterm: return "com.googlecode.iterm2"
            case .terminal: return "com.apple.Terminal"
            case .ghostty: return "com.mitchellh.ghostty"
            case .tmux: return nil  // runs inside one of the others (`host`)
            }
        }

        public var displayName: String {
            switch self {
            case .wezterm: return "WezTerm"
            case .tmux: return "tmux"
            case .iterm: return "iTerm2"
            case .terminal: return "Terminal"
            case .ghostty: return "Ghostty"
            }
        }

        /// Selecting a tab needs AppleScript (and macOS's Automation permission).
        public var usesAppleScript: Bool { self == .iterm || self == .terminal }
    }

    /// What to focus inside the app.
    public enum Target: Equatable, Sendable {
        /// WezTerm pane id, or tmux pane id (`%<n>`).
        case pane(Int)
        /// tmux `session:window.pane`.
        case tmuxTarget(session: String, window: Int, pane: Int)
        /// iTerm2 session `unique id`.
        case session(String)
        /// `/dev/ttys<n>` (iTerm2 or Terminal.app).
        case tty(String)
        /// Ghostty: only the app comes forward.
        case app
    }

    public let app: App
    public let target: Target
    /// tmux only: the terminal app tmux runs in (brought forward after the select).
    public let hostApp: App?

    public static let host = "terminal"
    public static let path = "/focus"

    /// Terminals that can host tmux, in the order tried when `host` isn't given.
    public static let hostApps: [App] = [.iterm, .wezterm, .ghostty, .terminal]

    public init?(app: App, target: Target, hostApp: App? = nil) {
        switch (app, target) {
        case (.wezterm, .pane(let n)), (.tmux, .pane(let n)):
            guard (0...999_999).contains(n) else { return nil }
        case (.tmux, .tmuxTarget(let session, let window, let pane)):
            guard Self.isValidTmuxSession(session), (0...9_999).contains(window), (0...9_999).contains(pane)
            else { return nil }
        case (.iterm, .session(let id)):
            guard Self.isValidUUID(id) else { return nil }
        case (.iterm, .tty(let t)), (.terminal, .tty(let t)):
            guard Self.isValidTTY(t) else { return nil }
        case (.ghostty, .app):
            break
        default:
            return nil
        }
        if let hostApp {
            guard app == .tmux, hostApp != .tmux else { return nil }
        }
        self.app = app
        self.target = target
        self.hostApp = hostApp
    }

    // MARK: Parsing

    /// Parses the link, or nil if it isn't exactly a valid terminal link.
    public static func parse(_ string: String) -> TerminalJump? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300,
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let c = URLComponents(string: trimmed),
              c.scheme?.lowercased() == ConnectLink.scheme,
              c.host?.lowercased() == Self.host,
              c.path.lowercased() == Self.path,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil
        else { return nil }
        var params: [String: String] = [:]
        for q in c.queryItems ?? [] {
            guard let v = q.value, !v.isEmpty, params[q.name] == nil, !v.hasPrefix("-") else { return nil }
            params[q.name] = v
        }
        guard let appName = params.removeValue(forKey: "app"), let app = App(rawValue: appName) else { return nil }
        let allowed: Set<String>
        switch app {
        case .wezterm: allowed = ["pane"]
        case .tmux: allowed = ["pane", "target", "host"]
        case .iterm: allowed = ["session", "tty"]
        case .terminal: allowed = ["tty"]
        case .ghostty: allowed = []
        }
        guard Set(params.keys).isSubset(of: allowed) else { return nil }

        var hostApp: App?
        if let h = params.removeValue(forKey: "host") {
            guard let a = App(rawValue: h) else { return nil }
            hostApp = a
        }
        // Exactly one id parameter (none for Ghostty).
        if app == .ghostty {
            guard params.isEmpty else { return nil }
            return TerminalJump(app: .ghostty, target: .app)
        }
        guard params.count == 1, let entry = params.first else { return nil }
        let name = entry.key, value = entry.value
        let target: Target
        switch (app, name) {
        case (.wezterm, "pane"), (.tmux, "pane"):
            guard let n = digits(value, max: 6) else { return nil }
            target = .pane(n)
        case (.tmux, "target"):
            guard let t = parseTmuxTarget(value) else { return nil }
            target = t
        case (.iterm, "session"):
            target = .session(value)
        case (.iterm, "tty"), (.terminal, "tty"):
            target = .tty(value)
        default:
            return nil
        }
        return TerminalJump(app: app, target: target, hostApp: hostApp)
    }

    public static func parse(_ url: URL) -> TerminalJump? { parse(url.absoluteString) }

    /// 1...`max` ASCII digits, as an Int.
    static func digits(_ s: String, max: Int) -> Int? {
        guard (1...max).contains(s.count), s.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(s)
    }

    /// `session:window.pane`, the form the hook shows in the card body.
    static func parseTmuxTarget(_ s: String) -> Target? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let wp = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard wp.count == 2, let w = digits(String(wp[0]), max: 4), let p = digits(String(wp[1]), max: 4)
        else { return nil }
        return .tmuxTarget(session: String(parts[0]), window: w, pane: p)
    }

    /// A tmux session name: ASCII letters, digits, `_` and `-`, at most 64, not starting
    /// with `-`. (tmux itself never allows `:` or `.` in one.)
    public static func isValidTmuxSession(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, (1...64).contains(s.count), first != "-" else { return false }
        return s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
    }

    /// An iTerm2 session `unique id`: a UUID, 8-4-4-4-12 hex digits.
    public static func isValidUUID(_ s: String) -> Bool {
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) } }
    }

    /// A macOS pseudo-terminal: `/dev/ttys` and 1–4 digits.
    public static func isValidTTY(_ s: String) -> Bool {
        guard s.hasPrefix("/dev/ttys") else { return false }
        return digits(String(s.dropFirst(9)), max: 4) != nil
    }

    // MARK: Running

    /// Where the CLIs may live. Never looked up on PATH.
    public static func cliPaths(_ app: App) -> [String] {
        switch app {
        case .wezterm:
            return ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm"]
        case .tmux:
            return ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
        default:
            return []
        }
    }

    /// The tmux target string (`%12` or `session:window.pane`).
    public var tmuxTarget: String? {
        guard app == .tmux else { return nil }
        switch target {
        case .pane(let n): return "%\(n)"
        case .tmuxTarget(let s, let w, let p): return "\(s):\(w).\(p)"
        default: return nil
        }
    }

    /// The CLI runs, in order, each an argv list for the binary from `cliPaths(app)`.
    /// Empty for the AppleScript apps and Ghostty.
    public var invocations: [[String]] {
        switch (app, target) {
        case (.wezterm, .pane(let n)):
            return [["cli", "activate-pane", "--pane-id", String(n)]]
        case (.tmux, _):
            guard let t = tmuxTarget else { return [] }
            return [["select-window", "-t", t], ["select-pane", "-t", t]]
        default:
            return []
        }
    }

    /// The AppleScript handler and its one parameter, for iTerm2 and Terminal.app.
    public var appleScriptCall: (handler: String, parameter: String)? {
        switch (app, target) {
        case (.iterm, .session(let id)): return ("focus_iterm_session", id)
        case (.iterm, .tty(let t)): return ("focus_iterm_tty", t)
        case (.terminal, .tty(let t)): return ("focus_terminal_tty", t)
        default: return nil
        }
    }

    /// The apps to bring forward after the switch, first running one wins. For tmux
    /// without `host`, the terminals that usually host it.
    public var appsToActivate: [App] {
        if app == .tmux { return hostApp.map { [$0] } ?? Self.hostApps }
        return [app]
    }

    /// The same switch for a person to paste into a terminal, when there is a CLI form.
    public var command: String? {
        switch (app, target) {
        case (.wezterm, .pane(let n)):
            return "wezterm cli activate-pane --pane-id \(n)"
        case (.tmux, _):
            guard let t = tmuxTarget else { return nil }
            return "tmux select-window -t \(t) && tmux select-pane -t \(t)"
        default:
            return nil
        }
    }

    /// Short text for the confirmation alert and logs: "WezTerm pane 12".
    public var summary: String {
        switch target {
        case .pane(let n): return app == .tmux ? "tmux pane %\(n)" : "\(app.displayName) pane \(n)"
        case .tmuxTarget(let s, let w, let p): return "tmux \(s):\(w).\(p)"
        case .session(let id): return "\(app.displayName) session \(id.prefix(8))…"
        case .tty(let t): return "\(app.displayName) tab on \(t)"
        case .app: return app.displayName
        }
    }

    /// The canonical link (what the hook writes).
    public var url: URL {
        var c = URLComponents()
        c.scheme = ConnectLink.scheme
        c.host = Self.host
        c.path = Self.path
        var q = [URLQueryItem(name: "app", value: app.rawValue)]
        switch target {
        case .pane(let n): q.append(URLQueryItem(name: "pane", value: String(n)))
        case .tmuxTarget(let s, let w, let p): q.append(URLQueryItem(name: "target", value: "\(s):\(w).\(p)"))
        case .session(let id): q.append(URLQueryItem(name: "session", value: id))
        case .tty(let t): q.append(URLQueryItem(name: "tty", value: t))
        case .app: break
        }
        if let hostApp { q.append(URLQueryItem(name: "host", value: hostApp.rawValue)) }
        c.queryItems = q
        return c.url!
    }

    /// Confirmation for a link opened from outside the app (a web page, `open`): a card
    /// click is trusted, anything else asks first.
    public var confirmation: (title: String, message: String) {
        ("Switch to a terminal?",
         "A link asks Needs You to show \(summary). Only switch if you just clicked a needs-you link you trust.")
    }
}

/// The app's own actions a card link may carry (`LinkPolicy.appActionPaths`).
public enum AppAction: Equatable, Sendable {
    case orca(OrcaJump)
    case terminal(TerminalJump)
    case activate(AppActivation)

    public static func parse(_ string: String) -> AppAction? {
        if let j = OrcaJump.parse(string) { return .orca(j) }
        if let j = TerminalJump.parse(string) { return .terminal(j) }
        if let a = AppActivation.parse(string) { return .activate(a) }
        return nil
    }

    public static func parse(_ url: URL) -> AppAction? { parse(url.absoluteString) }

    public var url: URL {
        switch self {
        case .orca(let j): return j.url
        case .terminal(let j): return j.url
        case .activate(let a): return a.url
        }
    }
}

/// Which way a terminal jump goes, given the Settings opt-in (pure, so it's testable).
public enum TerminalJumpPlan: Equatable, Sendable {
    /// Run the CLI invocations, then bring the app forward.
    case cli
    /// Call the fixed AppleScript handler with the value as its parameter (the script
    /// activates the terminal itself).
    case appleScript(handler: String, parameter: String)
    /// Only bring the app forward (Ghostty, or AppleScript jumps while the opt-in is off).
    case activateOnly

    public static func plan(_ jump: TerminalJump, appleScriptEnabled: Bool) -> TerminalJumpPlan {
        if !jump.invocations.isEmpty { return .cli }
        if let call = jump.appleScriptCall {
            return appleScriptEnabled ? .appleScript(handler: call.handler, parameter: call.parameter) : .activateOnly
        }
        return .activateOnly
    }
}
