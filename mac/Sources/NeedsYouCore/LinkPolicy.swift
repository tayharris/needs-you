import Foundation

/// Which URLs the app is willing to open (PLAN.md, "Cards"). Agents write these links,
/// so anything outside the allow-list is shown as plain text and is never opened.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = [
        "https", "orca", "slack", "vscode", "cursor", "figma", "msteams", "discord", "linear",
    ]

    /// The app's own `needsyou://<host>/<path>?…` actions a card may carry, mirrored by the
    /// hub's `APP_LINK_PATHS` (hard rule 7: change both). Each one has a parser below that
    /// validates every parameter; a path here without a parser opens nothing.
    public static let appActionPaths: [String] = ["orca/terminal", "terminal/focus"]

    /// The URL another app opens, or nil if the string isn't an allowed, well-formed link.
    public static func externalURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              // Reject control characters and spaces outright rather than letting
              // URL(string:) percent-encode its way around them.
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme)
        else { return nil }
        // https needs a host; the app schemes may legitimately be host-less.
        if scheme == "https", (url.host ?? "").isEmpty { return nil }
        return url
    }

    /// The URL to act on, or nil if the string isn't an allowed, well-formed link. The
    /// app's own scheme counts only for the actions in `appActionPaths` that parse
    /// (`AppAction`: the Orca jump, the terminal jump); callers hand those to their
    /// runner, never to NSWorkspace (that would route back to this app).
    public static func openableURL(_ string: String) -> URL? {
        if let action = AppAction.parse(string) { return action.url }
        return externalURL(string)
    }

    public static func isAllowed(_ string: String) -> Bool { openableURL(string) != nil }

    public static func isAllowed(_ url: URL) -> Bool { openableURL(url.absoluteString) != nil }
}
