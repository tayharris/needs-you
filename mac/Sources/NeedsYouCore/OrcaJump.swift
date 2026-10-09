import Foundation

/// The card's "Orca" link: `needsyou://orca/terminal?handle=term_<uuid>[&environment=<name>]`.
///
/// Senders only hold a token, so the app never runs anything from item data. This is the
/// one fixed action: `orca terminal switch` with a validated handle and environment, as an
/// argv list (no shell). Anything that doesn't parse does nothing. If abused, a sender can
/// switch which Orca tab is shown, and nothing else (docs/roadmap/future.md).
public struct OrcaJump: Equatable, Sendable {
    public let handle: String
    public let environment: String?

    public static let host = "orca"
    public static let path = "/terminal"
    /// Orca's bundle id: the app brought forward after the switch, or when it fails.
    public static let bundleID = "com.stablyai.orca"
    /// Where the `orca` CLI may live. Never looked up on PATH.
    public static let cliPaths = [
        "/usr/local/bin/orca",
        "/opt/homebrew/bin/orca",
        "/Applications/Orca.app/Contents/Resources/bin/orca",
    ]

    public init?(handle: String, environment: String? = nil) {
        guard Self.isValidHandle(handle) else { return nil }
        if let environment, !Self.isValidEnvironment(environment) { return nil }
        self.handle = handle
        self.environment = environment
    }

    /// Parses the link, or nil if it isn't exactly a valid terminal link.
    public static func parse(_ string: String) -> OrcaJump? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let c = URLComponents(string: trimmed),
              c.scheme?.lowercased() == ConnectLink.scheme,
              c.host?.lowercased() == host,
              c.path == path,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil
        else { return nil }
        let query = c.queryItems ?? []
        // Exactly one handle, at most one environment, nothing else.
        guard query.allSatisfy({ $0.name == "handle" || $0.name == "environment" }),
              query.filter({ $0.name == "handle" }).count == 1,
              query.filter({ $0.name == "environment" }).count <= 1,
              let handle = query.first(where: { $0.name == "handle" })?.value
        else { return nil }
        let env = query.first(where: { $0.name == "environment" })?.value
        return OrcaJump(handle: handle, environment: (env?.isEmpty ?? true) ? nil : env)
    }

    public static func parse(_ url: URL) -> OrcaJump? { parse(url.absoluteString) }

    /// `term_` plus a lowercase uuid-ish run of hex and dashes.
    public static func isValidHandle(_ s: String) -> Bool {
        guard s.hasPrefix("term_") else { return false }
        let rest = s.dropFirst(5)
        return (8...64).contains(rest.count)
            && rest.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" }
    }

    /// An Orca environment name as `orca environment list` shows it: letters, digits,
    /// spaces, `.`, `_` and `-`, starting with a letter or digit (so never a flag).
    public static func isValidEnvironment(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= 64,
              CharacterSet.alphanumerics.contains(first), first.isASCII
        else { return false }
        return s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    /// The arguments for the `orca` CLI.
    public var arguments: [String] {
        ["terminal", "switch", "--terminal", handle, "--json"] + (environment.map { ["--environment", $0] } ?? [])
    }

    /// The same jump through a paired environment (for a card that didn't name one).
    public func via(_ environment: String) -> OrcaJump? { OrcaJump(handle: handle, environment: environment) }

    public static let environmentListArguments = ["environment", "list", "--json"]

    /// True if `orca terminal switch --json` printed `"ok": true`. A stale handle
    /// (wrong or missing environment) prints `"ok": false`.
    public static func switchSucceeded(_ output: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { return false }
        return obj["ok"] as? Bool == true
    }

    /// The valid environment names from `orca environment list --json`, at most 8.
    public static func environmentNames(_ output: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let envs = result["environments"] as? [[String: Any]]
        else { return [] }
        return Array(envs.compactMap { $0["name"] as? String }.filter(isValidEnvironment).prefix(8))
    }

    /// The same command for a person to paste into a terminal.
    public var command: String {
        var s = "orca terminal switch --terminal \(handle)"
        if let environment { s += environment.contains(" ") ? " --environment '\(environment)'" : " --environment \(environment)" }
        return s
    }

    /// The link the hook and the Orca prompt block write.
    public var url: URL {
        var c = URLComponents()
        c.scheme = ConnectLink.scheme
        c.host = Self.host
        c.path = Self.path
        c.queryItems = [URLQueryItem(name: "handle", value: handle)]
            + (environment.map { [URLQueryItem(name: "environment", value: $0)] } ?? [])
        return c.url!
    }
}
