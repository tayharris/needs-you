import Foundation

/// Which URLs the app is willing to open (PLAN.md, "Cards"). Agents write these links,
/// so anything outside the allow-list is shown as plain text and is never opened.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = [
        "https", "orca", "slack", "vscode", "cursor", "figma", "msteams", "discord",
    ]

    /// The URL to open, or nil if the string isn't an allowed, well-formed link.
    public static func openableURL(_ string: String) -> URL? {
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

    public static func isAllowed(_ string: String) -> Bool { openableURL(string) != nil }

    public static func isAllowed(_ url: URL) -> Bool { openableURL(url.absoluteString) != nil }
}
