import AppKit
import Carbon
import Foundation
import NeedsYouCore
import os

/// Runs a validated `TerminalJump` (needsyou://terminal/focus). Like `OrcaJumpRunner`:
///
/// - WezTerm and tmux: the CLI from a fixed absolute path (`TerminalJump.cliPaths`), with
///   the argv lists from `TerminalJump.invocations`, no shell, 5 s timeout each. Then the
///   terminal app comes forward (WezTerm, or the terminal tmux runs in).
/// - iTerm2 and Terminal.app: only with Settings → Integrations → "Jump to iTerm2 and
///   Terminal tabs" on. A fixed, compiled AppleScript handler (`TerminalJumpScript`) is
///   called with the validated value as a typed Apple Event parameter. The Automation
///   prompt is only ever asked from that Settings toggle; here the permission is checked
///   without asking, and without it (or with the setting off) the app just comes forward.
/// - Ghostty: it comes forward.
///
/// This activates the terminal, never Needs You (hard rule 2). If a CLI switch fails, its
/// command goes on the clipboard. Worst case: the wrong tab or just the right app.
enum TerminalJumpRunner {
    private static let log = Logger(subsystem: "app.needsyou.mac", category: "terminal-jump")

    static func run(_ jump: TerminalJump, appleScript enabled: Bool) {
        let plan = TerminalJumpPlan.plan(jump, appleScriptEnabled: enabled)
        log.info("jump to \(jump.summary, privacy: .public)")
        switch plan {
        case .cli:
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = runCLI(jump)
                DispatchQueue.main.async {
                    if !ok, let command = jump.command {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    bringForward(jump.appsToActivate)
                }
            }
        case .appleScript(let handler, let parameter):
            guard let found = TerminalJumpScript.source(forHandler: handler), let bundleID = found.app.bundleID else {
                bringForward(jump.appsToActivate)
                return
            }
            let source = found.source, app = found.app
            DispatchQueue.global(qos: .userInitiated).async {
                // Never ask here: the prompt belongs to the Settings toggle.
                let permission = automationPermission(bundleID, ask: false)
                DispatchQueue.main.async {
                    guard permission == .allowed else {
                        log.error("\(permission.describe(app), privacy: .public); bringing it forward only")
                        bringForward(jump.appsToActivate)
                        return
                    }
                    if !callScript(source, app: app, handler: handler, parameter: parameter) {
                        bringForward(jump.appsToActivate)
                    }
                }
            }
        case .activateOnly:
            bringForward(jump.appsToActivate)
        }
    }

    // MARK: CLI

    private static func runCLI(_ jump: TerminalJump) -> Bool {
        guard let cli = TerminalJump.cliPaths(jump.app).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log.error("\(jump.app.rawValue, privacy: .public) CLI not found")
            return false
        }
        for args in jump.invocations {
            guard runProcess(cli, args) else { return false }
        }
        return true
    }

    /// True if `cli <arguments>` exited 0 within 5 s.
    private static func runProcess(_ cli: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            log.error("\(cli, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        var errData = Data()
        let reader = DispatchQueue(label: "terminal-jump-read")
        reader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            log.error("\(arguments.first ?? "", privacy: .public) timed out")
            return false
        }
        let stderr = reader.sync { errData }
        if p.terminationStatus != 0 {
            log.error("\(arguments.joined(separator: " "), privacy: .public) exited \(p.terminationStatus): \(String(decoding: stderr.prefix(300), as: UTF8.self), privacy: .public)")
            return false
        }
        return true
    }

    // MARK: AppleScript

    /// Compiled scripts by app, compiled on first use (main thread only).
    private static var compiled: [String: NSAppleScript] = [:]

    private static func callScript(_ source: String, app: TerminalJump.App, handler: String, parameter: String) -> Bool {
        guard let bundleID = app.bundleID, NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            log.error("\(app.displayName, privacy: .public) isn't installed")
            return false
        }
        let script: NSAppleScript
        if let cached = compiled[app.rawValue] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return false }
            var error: NSDictionary?
            guard s.compileAndReturnError(&error) else {
                log.error("compiling the \(app.displayName, privacy: .public) script failed: \(String(describing: error), privacy: .public)")
                return false
            }
            compiled[app.rawValue] = s
            script = s
        }
        // A subroutine call: 'ascr'/'psbr' with the handler name ('snam') and the
        // parameters as the direct object ('----'), one typed string.
        let event = NSAppleEventDescriptor(eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
                                           targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                           returnID: AEReturnID(-1), transactionID: AETransactionID(0))
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: fourCC("snam"))
        let params = NSAppleEventDescriptor.list()
        params.insert(NSAppleEventDescriptor(string: parameter), at: 1)
        event.setParam(params, forKeyword: fourCC("----"))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            log.error("\(handler, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if !result.booleanValue {
            log.error("\(handler, privacy: .public): no such tab (closed, or a stale id)")
            return false
        }
        return true
    }

    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// The Automation permission for controlling `bundleID`. `ask: true` may show the
    /// system prompt and blocks until it's answered, so call it off the main thread, and
    /// only from the Settings toggle. The target must be running.
    static func automationPermission(_ bundleID: String, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), ask)
        return AutomationPermission(status: Int32(status))
    }

    /// Settings → Integrations: ask for (or re-check) Automation for iTerm2 and Terminal,
    /// and report one line per app on the main thread.
    static func requestAutomation(_ done: @escaping @MainActor (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for app in [TerminalJump.App.iterm, .terminal] {
                guard let id = app.bundleID else { continue }
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil {
                    lines.append("\(app.displayName): not installed")
                    continue
                }
                lines.append(automationPermission(id, ask: true).describe(app))
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }

    // MARK: Bringing the terminal forward

    /// Activates the first running app of `apps` (that terminal, never this app). A
    /// WezTerm or Ghostty that isn't running is opened; for tmux without a known host,
    /// only a running terminal is activated.
    private static func bringForward(_ apps: [TerminalJump.App]) {
        for app in apps {
            guard let id = app.bundleID else { continue }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                running.activate(options: [])
                return
            }
        }
        guard apps.count == 1, let id = apps[0].bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            log.error("no terminal to bring forward")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { log.error("opening \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
