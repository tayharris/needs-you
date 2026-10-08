import AppKit
import Darwin
import NeedsYouCore

/// The facts LaunchOpen.kind decides from, read from the system at launch.
@MainActor
enum LaunchContext {
    /// The launch's open-application ('oapp') Apple event carries keyAELaunchedAsLogInItem
    /// when macOS starts the app as a login item. Only meaningful in
    /// applicationWillFinishLaunching, while that event is the current one. Not every login
    /// launch sets it (apps reopened with the session, some SMAppService launches), so
    /// LaunchOpen also counts a launch early in the login session as a login launch.
    static func appleEventSaysLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Seconds since this user's console session began (utmpx's "console" entry, written
    /// by loginwindow at login). nil when there is none (ssh-only sessions, odd setups).
    nonisolated static func secondsSinceConsoleLogin(now: Date = Date()) -> TimeInterval? {
        let user = NSUserName()
        var started: TimeInterval?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            var e = entry.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: &e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: &e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let t = TimeInterval(e.ut_tv.tv_sec) + TimeInterval(e.ut_tv.tv_usec) / 1_000_000
            started = max(started ?? t, t)   // the latest console login
        }
        return started.map { now.timeIntervalSince1970 - $0 }
    }

    /// How old the file at `url` is (its modification date), or nil when it doesn't exist.
    nonisolated static func age(ofFileAt url: URL, now: Date = Date()) -> TimeInterval? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return now.timeIntervalSince(modified)
    }
}
