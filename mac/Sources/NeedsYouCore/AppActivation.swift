import Foundation

/// `needsyou://app/activate?bundle=<id>` (docs/API.md, "Links"): bring forward the app an
/// agent session runs in when the sender knows the app but no window jump exists for it
/// (kitty, Warp, Zed, a JetBrains IDE; the hook reads `__CFBundleIdentifier`).
///
/// Senders only hold a token, so the link is parsed into a typed value: exactly one
/// `bundle` parameter whose value is, byte for byte, one of `allowedApps`, a fixed list of
/// terminals and editors (never a setting, never anything from the link). Needs You itself
/// is never on it. The runner (`AppActivationRunner` in the app) only activates an app that
/// is already running; it never launches one and never activates this app (hard rule 2). If
/// abused, a sender can bring a listed terminal or editor to the front, and nothing else.
public struct AppActivation: Equatable, Sendable {
    public static let host = "app"
    public static let path = "/activate"

    /// The only apps this action brings forward, bundle id to button name. Mirrored by the
    /// Claude Code hook's `TERMINAL_APPS` and `EDITOR_APPS` (tests/test_link_mirror.py).
    public static let allowedApps: [String: String] = [
        // Terminals
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "com.github.wez.wezterm": "WezTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "dev.warp.Warp-Stable": "Warp",
        "co.zeit.hyper": "Hyper",
        "org.tabby": "Tabby",
        // Editors
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
        "dev.zed.Zed": "Zed",
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.intellij.ce": "IntelliJ IDEA CE",
        "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.pycharm.ce": "PyCharm CE",
        "com.jetbrains.goland": "GoLand",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.jetbrains.CLion": "CLion",
        "com.jetbrains.rider": "Rider",
        "com.jetbrains.rubymine": "RubyMine",
        "com.jetbrains.PhpStorm": "PhpStorm",
        "com.google.android.studio": "Android Studio",
    ]

    public let bundleID: String

    public init?(bundleID: String) {
        guard Self.allowedApps[bundleID] != nil, bundleID != AppIdentity.bundleID else { return nil }
        self.bundleID = bundleID
    }

    /// The button name ("kitty", "Zed").
    public var displayName: String { Self.allowedApps[bundleID] ?? bundleID }

    /// Parses the link, or nil if it isn't exactly `needsyou://app/activate?bundle=<listed id>`.
    /// Nothing is trimmed first: surrounding whitespace or an invisible character refuses it,
    /// as the hub does.
    public static func parse(_ string: String) -> AppActivation? {
        guard !string.isEmpty, string.count <= 300,
              string.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              !string.contains("%"),
              let c = URLComponents(string: string),
              c.scheme?.lowercased() == ConnectLink.scheme,
              c.host?.lowercased() == Self.host,
              c.path.lowercased() == Self.path,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              let items = c.queryItems, items.count == 1,
              items[0].name == "bundle", let value = items[0].value
        else { return nil }
        return AppActivation(bundleID: value)
    }

    public static func parse(_ url: URL) -> AppActivation? { parse(url.absoluteString) }

    /// The canonical link (what the hook writes).
    public var url: URL {
        var c = URLComponents()
        c.scheme = ConnectLink.scheme
        c.host = Self.host
        c.path = Self.path
        c.queryItems = [URLQueryItem(name: "bundle", value: bundleID)]
        return c.url!
    }
}
