import Foundation

/// `needsyou://focus?level=urgent&minutes=60`: sets the in-app focus from a Shortcuts
/// automation ("When Focus turns on"), a script or `open -g`.
///
/// Any app or web page can open a `needsyou://` link, so this one is fenced in:
/// - validated like OrcaJump: exactly one `level` from the fixed set (`off`, `agents`,
///   `urgent`, `later`), at most one duration, no other parameter, path, user, port or
///   fragment; anything else does nothing;
/// - the duration is `minutes` (1–9999, digits only, clamped to 720 = 12 h) or
///   `until=tomorrow` (7:00 tomorrow); with neither it lasts 12 h, never "until turned off";
///   `off` takes none;
/// - a focus it sets never holds back urgent items (DeliveryPolicy's link floor);
/// - unless Settings → Alerts → "Allow focus links from other apps" is on, the app asks
///   first (`confirmation`); turning focus off never needs asking.
/// It's not an item link: the hub doesn't take it in items and LinkPolicy doesn't open it
/// from cards; only the system URL handler reaches it.
public struct FocusLink: Equatable, Sendable {
    public static let host = "focus"
    /// The longest focus a link can set by minutes (12 h).
    public static let maxMinutes = 720

    public enum Duration: Equatable, Sendable {
        case minutes(Int)
        case untilTomorrow
    }

    public let level: FocusLevel
    /// Nil only for `off`.
    public let duration: Duration?

    /// Minutes are clamped to 1...`maxMinutes`. `off` has no duration; any other level
    /// without one gets the 12 h maximum.
    public init(level: FocusLevel, duration: Duration? = nil) {
        self.level = level
        if level == .off {
            self.duration = nil
        } else {
            switch duration {
            case .minutes(let m)?: self.duration = .minutes(min(max(m, 1), Self.maxMinutes))
            case .untilTomorrow?: self.duration = .untilTomorrow
            case nil: self.duration = .minutes(Self.maxMinutes)
            }
        }
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
        let allowed: Set<String> = ["level", "minutes", "until"]
        guard query.allSatisfy({ allowed.contains($0.name) }),
              query.filter({ $0.name == "level" }).count == 1,
              query.filter({ $0.name == "minutes" || $0.name == "until" }).count <= 1,
              let rawLevel = query.first(where: { $0.name == "level" })?.value,
              let level = FocusLevel(rawValue: rawLevel.lowercased())
        else { return nil }
        var duration: Duration?
        if let raw = query.first(where: { $0.name == "minutes" })?.value {
            guard !raw.isEmpty, raw.count <= 4, raw.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(raw), value >= 1
            else { return nil }
            duration = .minutes(value)
        }
        if let raw = query.first(where: { $0.name == "until" })?.value {
            guard raw.lowercased() == "tomorrow" else { return nil }
            duration = .untilTomorrow
        }
        if level == .off && duration != nil { return nil }
        return FocusLink(level: level, duration: duration)
    }

    public static func parse(_ url: URL) -> FocusLink? { parse(url.absoluteString) }

    /// The focus this link sets, starting at `now`. Always ends (at most 12 h, or 7:00 tomorrow).
    public func state(now: Date, calendar: Calendar = .current) -> FocusState {
        switch duration {
        case .minutes(let m)?:
            return FocusState(level: level, until: now.addingTimeInterval(Double(m) * 60), source: .link)
        case .untilTomorrow?:
            return FocusState(level: level, until: FocusDuration.tomorrow.until(from: now, calendar: calendar), source: .link)
        case nil:
            return FocusState(level: .off, source: .link)
        }
    }

    /// Turning focus off only makes alerts louder, so it needs no confirmation.
    public var needsConfirmation: Bool { level != .off }

    /// The question asked before an outside link may set the focus.
    public var confirmation: (title: String, message: String) {
        let how: String
        switch duration {
        case .minutes(let m)?:
            how = m % 60 == 0 ? "for \(m / 60) hr" : "for \(m) min"
        case .untilTomorrow?:
            how = "until tomorrow"
        case nil:
            how = ""
        }
        return (
            title: "Turn on Focus “\(level.title)” \(how)?",
            message: "Another app or a web page opened a needs-you focus link. While it's on, other items wait under Later; urgent items still interrupt. Allow links like this without asking in Settings → Alerts."
        )
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = ConnectLink.scheme
        c.host = Self.host
        var items = [URLQueryItem(name: "level", value: level.rawValue)]
        switch duration {
        case .minutes(let m)?: items.append(URLQueryItem(name: "minutes", value: String(m)))
        case .untilTomorrow?: items.append(URLQueryItem(name: "until", value: "tomorrow"))
        case nil: break
        }
        c.queryItems = items
        return c.url!
    }
}
