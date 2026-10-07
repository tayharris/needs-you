import Foundation

/// `needsyou://focus?level=urgent&minutes=60`: sets the in-app focus from a Shortcuts
/// automation ("When Focus turns on"), a script or `open -g`. Validated like OrcaJump:
/// exactly one `level` from the fixed set (`off`, `agents`, `urgent`, `later`), at most one
/// `minutes` (1–720, digits only; not with `off`), nothing else. Without `minutes` the
/// focus holds until turned off. It's not an item link: the hub doesn't take it in items
/// and LinkPolicy doesn't open it from cards; only the system URL handler reaches it.
public struct FocusLink: Equatable, Sendable {
    public static let host = "focus"
    public static let maxMinutes = 720

    public let level: FocusLevel
    public let minutes: Int?

    public init?(level: FocusLevel, minutes: Int? = nil) {
        if let minutes {
            guard level != .off, (1...Self.maxMinutes).contains(minutes) else { return nil }
        }
        self.level = level
        self.minutes = minutes
    }

    public static func parse(_ string: String) -> FocusLink? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let c = URLComponents(string: trimmed),
              c.scheme?.lowercased() == ConnectLink.scheme,
              c.host?.lowercased() == host,
              c.path.isEmpty || c.path == "/",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil
        else { return nil }
        let query = c.queryItems ?? []
        guard query.allSatisfy({ $0.name == "level" || $0.name == "minutes" }),
              query.filter({ $0.name == "level" }).count == 1,
              query.filter({ $0.name == "minutes" }).count <= 1,
              let rawLevel = query.first(where: { $0.name == "level" })?.value,
              let level = FocusLevel(rawValue: rawLevel.lowercased())
        else { return nil }
        var minutes: Int?
        if let raw = query.first(where: { $0.name == "minutes" })?.value {
            guard !raw.isEmpty, raw.count <= 3, raw.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(raw)
            else { return nil }
            minutes = value
        }
        return FocusLink(level: level, minutes: minutes)
    }

    public static func parse(_ url: URL) -> FocusLink? { parse(url.absoluteString) }

    /// The focus this link sets, starting at `now`.
    public func state(now: Date) -> FocusState {
        FocusState(level: level, until: minutes.map { now.addingTimeInterval(Double($0) * 60) }, source: .link)
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = ConnectLink.scheme
        c.host = Self.host
        c.queryItems = [URLQueryItem(name: "level", value: level.rawValue)]
            + (minutes.map { [URLQueryItem(name: "minutes", value: String($0))] } ?? [])
        return c.url!
    }
}
