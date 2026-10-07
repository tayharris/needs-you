import Foundation

/// Which URLs the app is willing to open (mac/README.md, "Design"). Agents write these links,
/// so anything outside the allow-list is shown as plain text and is never opened.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = [
        "https", "slack", "vscode", "cursor", "figma", "msteams", "discord", "linear",
    ]

    /// The editor schemes, which reach every installed extension's URI handler, so they
    /// open only the shapes in `editorLinkPattern` (security audit #14).
    public static let editorSchemes: Set<String> = ["vscode", "cursor"]

    /// The only `vscode://` / `cursor://` links that open, mirrored byte for byte by the
    /// hub's `EDITOR_LINK_PATTERN` (hard rule 7; tests/test_link_mirror.py compares them).
    /// The scheme is case-insensitive, the rest is exact:
    /// - `<s>://file/<abs path>[:line[:col]]`: a file or folder; no query, no fragment.
    /// - `<s>://vscode-remote/ssh-remote+<host>[/<abs path>]`: a Remote-SSH window.
    /// - `<s>://vscode-remote/tunnel+<name>[/<abs path>]`: a Remote Tunnel (only the user's own).
    /// - `<s>://anthropic.claude-code/open?session=<id>`: the Claude Code extension's tab.
    /// Paths take no escape that decoding turns into structure or something to decode again
    /// (`%2F %3F %23 %2E %25 %5C`), no escaped control character, no `.`/`..` segment.
    /// Host names start with a letter or digit and take no `%` (no ssh option injection);
    /// an all-hex name starting `7b` (a hex-encoded JSON host spec) is refused.
    public static let editorLinkPattern: String =
        #"(?i:vscode|cursor)://(?![^?#]*/\.\.?(?:[/:]|$))(?:"# +
        #"file/(?!/)(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%(?![01][0-9A-Fa-f]|7[Ff]|2[35EeFf]|3[Ff]|5[Cc])[0-9A-Fa-f]{2})*"# +
        #"|vscode-remote/(?:ssh-remote\+(?:[A-Za-z0-9][A-Za-z0-9._-]{0,63}@)?(?!7[Bb][0-9A-Fa-f]*(?:/|$))"# +
        #"|tunnel\+)[A-Za-z0-9][A-Za-z0-9._-]{0,252}"# +
        #"(?:/(?!/)(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%(?![01][0-9A-Fa-f]|7[Ff]|2[35EeFf]|3[Ff]|5[Cc])[0-9A-Fa-f]{2})*)?"# +
        #"|anthropic\.claude-code/open\?session=[A-Za-z0-9-]{8,64})"#

    /// Every link must match this on the raw string before anything parses it, so Foundation's
    /// URL and the hub's urlsplit never read one string two ways. Mirrored byte for byte by the
    /// hub's `LINK_RAW_PATTERN` (tests/test_link_mirror.py). A strict RFC 3986 subset: plain
    /// ASCII, `<scheme>://`, no userinfo `@` in the authority, at most one `#`, `%` only as
    /// `%XX`, no whitespace, backslash, quotes, `[]<>^`, backtick, `{|}` or controls.
    public static let rawLinkPattern: String =
        #"(?i:[a-z][a-z0-9+.-]*)://(?:[A-Za-z0-9._~!$&'()*+,;=:-]|%[0-9A-Fa-f]{2})*"# +
        #"(?:[/?](?:[A-Za-z0-9._~!$&'()*+,;=:@/?-]|%[0-9A-Fa-f]{2})*)?"# +
        #"(?:#(?:[A-Za-z0-9._~!$&'()*+,;=:@/?-]|%[0-9A-Fa-f]{2})*)?"#

    /// An https link needs a host (mirrors the hub's `HTTPS_HOST_PATTERN`; a prefix match).
    public static let httpsHostPattern: String = #"(?i:https)://[^/?#:]"#

    private static func wholeMatch(_ string: String, _ pattern: String) -> Bool {
        string.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
    }

    /// Whether the whole string is one of the allowed editor link shapes.
    public static func isAllowedEditorLink(_ string: String) -> Bool {
        wholeMatch(string, editorLinkPattern)
    }

    /// Whether the whole string fits the raw link grammar (the first check for every link).
    public static func isWellFormedRaw(_ string: String) -> Bool {
        wholeMatch(string, rawLinkPattern)
    }

    /// The app's own `needsyou://<host>/<path>?…` actions a card may carry, mirrored by the
    /// hub's `APP_LINK_PATHS` (hard rule 7: change both). Each one has a parser below that
    /// validates every parameter; a path here without a parser opens nothing.
    public static let appActionPaths: [String] = ["orca/terminal", "terminal/focus"]

    /// The URL another app opens, or nil if the string isn't an allowed, well-formed link.
    public static func externalURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // The raw grammar first (ASCII only, so no spaces, controls or format characters for
        // URL(string:) to percent-encode its way around); the scheme comes from the raw string.
        guard isWellFormedRaw(trimmed) else { return nil }
        let scheme = String(trimmed.prefix(while: { $0 != ":" })).lowercased()
        guard allowedSchemes.contains(scheme) else { return nil }
        // https needs a host; the app schemes may legitimately be host-less.
        if scheme == "https", trimmed.range(of: "^" + httpsHostPattern, options: .regularExpression) == nil { return nil }
        if editorSchemes.contains(scheme), !isAllowedEditorLink(trimmed) { return nil }
        return URL(string: trimmed)
    }

    /// The URL to act on, or nil if the string isn't an allowed, well-formed link. The
    /// app's own scheme counts only for the actions in `appActionPaths` that parse
    /// (`AppAction`: the Orca jump, the terminal jump); callers hand those to their
    /// runner, never to NSWorkspace (that would route back to this app).
    public static func openableURL(_ string: String) -> URL? {
        guard isWellFormedRaw(string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if let action = AppAction.parse(string) { return action.url }
        return externalURL(string)
    }

    public static func isAllowed(_ string: String) -> Bool { openableURL(string) != nil }

    public static func isAllowed(_ url: URL) -> Bool { openableURL(url.absoluteString) != nil }
}
