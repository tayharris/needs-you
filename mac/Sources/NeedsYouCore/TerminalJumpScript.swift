import Foundation

/// The fixed AppleScript behind the iTerm2 and Terminal.app jumps (opt-in, Settings →
/// Integrations). The source never changes at run time: the app compiles it once and calls
/// a handler through an Apple Event whose one parameter is the validated session UUID or
/// tty, passed as a typed string (`NSAppleEventDescriptor`), never spliced into source.
/// So no item text can become script. Each handler only selects an existing session and
/// brings its app forward, giving up after 5 s.
///
/// One script per app: compiling `tell application id …` needs that app's dictionary, so the
/// app compiles a script only when its terminal is installed.
public enum TerminalJumpScript {
    public static let iTermSource = """
    on focus_iterm_session(sid)
    \twith timeout of 5 seconds
    \t\ttell application id "com.googlecode.iterm2"
    \t\t\trepeat with w in windows
    \t\t\t\trepeat with t in tabs of w
    \t\t\t\t\trepeat with s in sessions of t
    \t\t\t\t\t\tif (unique id of s) is sid then
    \t\t\t\t\t\t\ttell w to select
    \t\t\t\t\t\t\ttell t to select
    \t\t\t\t\t\t\ttell s to select
    \t\t\t\t\t\t\tactivate
    \t\t\t\t\t\t\treturn true
    \t\t\t\t\t\tend if
    \t\t\t\t\tend repeat
    \t\t\t\tend repeat
    \t\t\tend repeat
    \t\tend tell
    \tend timeout
    \treturn false
    end focus_iterm_session

    on focus_iterm_tty(ttyPath)
    \twith timeout of 5 seconds
    \t\ttell application id "com.googlecode.iterm2"
    \t\t\trepeat with w in windows
    \t\t\t\trepeat with t in tabs of w
    \t\t\t\t\trepeat with s in sessions of t
    \t\t\t\t\t\tif (tty of s) is ttyPath then
    \t\t\t\t\t\t\ttell w to select
    \t\t\t\t\t\t\ttell t to select
    \t\t\t\t\t\t\ttell s to select
    \t\t\t\t\t\t\tactivate
    \t\t\t\t\t\t\treturn true
    \t\t\t\t\t\tend if
    \t\t\t\t\tend repeat
    \t\t\t\tend repeat
    \t\t\tend repeat
    \t\tend tell
    \tend timeout
    \treturn false
    end focus_iterm_tty
    """

    public static let terminalSource = """
    on focus_terminal_tty(ttyPath)
    \twith timeout of 5 seconds
    \t\ttell application id "com.apple.Terminal"
    \t\t\trepeat with w in windows
    \t\t\t\trepeat with t in tabs of w
    \t\t\t\t\tif (tty of t) is ttyPath then
    \t\t\t\t\t\tset selected of t to true
    \t\t\t\t\t\tset index of w to 1
    \t\t\t\t\t\tactivate
    \t\t\t\t\t\treturn true
    \t\t\t\t\tend if
    \t\t\t\tend repeat
    \t\t\tend repeat
    \t\tend tell
    \tend timeout
    \treturn false
    end focus_terminal_tty
    """

    /// The script for a handler `TerminalJump.appleScriptCall` names, and the app it drives.
    public static func source(forHandler handler: String) -> (source: String, app: TerminalJump.App)? {
        switch handler {
        case "focus_iterm_session", "focus_iterm_tty": return (iTermSource, .iterm)
        case "focus_terminal_tty": return (terminalSource, .terminal)
        default: return nil
        }
    }
}

/// What the Automation (TCC) check for a terminal said, from the OSStatus of
/// `AEDeterminePermissionToAutomateTarget`.
public enum AutomationPermission: Equatable, Sendable {
    case allowed, denied, notAskedYet, appNotRunning, other(Int32)

    public init(status: Int32) {
        switch status {
        case 0: self = .allowed
        case -1743: self = .denied             // errAEEventNotPermitted
        case -1744: self = .notAskedYet        // errAEEventWouldRequireUserConsent
        case -600: self = .appNotRunning       // procNotFound
        default: self = .other(status)
        }
    }

    public func describe(_ app: TerminalJump.App) -> String {
        switch self {
        case .allowed: return "\(app.displayName): allowed"
        case .denied: return "\(app.displayName): not allowed. Turn it on in System Settings → Privacy & Security → Automation → Needs You"
        case .notAskedYet: return "\(app.displayName): not asked yet"
        case .appNotRunning: return "\(app.displayName): not running. Open it and click Check again"
        case .other(let s): return "\(app.displayName): couldn't check (\(s))"
        }
    }
}
