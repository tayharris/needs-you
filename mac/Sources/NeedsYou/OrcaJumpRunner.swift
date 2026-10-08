import AppKit
import Foundation
import NeedsYouCore
import os

/// Runs a validated `OrcaJump`: `orca terminal switch … --json` from a fixed path (argv,
/// no shell, 5 s timeout), then brings Orca forward (that activates Orca, never this app;
/// hard rule 2). Switch first: Orca navigates in the background, and a reopen event sent
/// before it (NSWorkspace.openApplication on a running app) pops Orca's dashboard window
/// and stalls the switch. A running Orca is activated without a reopen. A card without an
/// environment that the local Orca calls stale is retried through each paired
/// environment. If nothing works, the command goes on the clipboard; the worst case is
/// "opens the right app".
enum OrcaJumpRunner {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "orca-jump")

    static func run(_ jump: OrcaJump) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = switchTerminal(jump)
            DispatchQueue.main.async {
                if !ok {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jump.command, forType: .string)
                }
                bringOrcaForward()
            }
        }
    }

    private static func switchTerminal(_ jump: OrcaJump) -> Bool {
        guard let cli = OrcaJump.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log.error("orca CLI not found")
            return false
        }
        if attempt(cli, jump) { return true }
        guard jump.environment == nil, let list = runOrca(cli, OrcaJump.environmentListArguments) else { return false }
        for name in OrcaJump.environmentNames(list) {
            if let viaEnv = jump.via(name), attempt(cli, viaEnv) { return true }
        }
        return false
    }

    private static func attempt(_ cli: String, _ jump: OrcaJump) -> Bool {
        let env = jump.environment ?? "local"
        guard let out = runOrca(cli, jump.arguments) else { return false }
        let ok = OrcaJump.switchSucceeded(out)
        if ok {
            log.info("switched to \(jump.handle, privacy: .public) via \(env, privacy: .public)")
        } else {
            log.error("switch to \(jump.handle, privacy: .public) via \(env, privacy: .public) failed: \(String(decoding: out.prefix(300), as: UTF8.self), privacy: .public)")
        }
        return ok
    }

    /// The first `orca` CLI found at one of the fixed paths (never PATH).
    static var cliPath: String? {
        OrcaJump.cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// stdout of `orca <arguments>`, or nil if it didn't start or timed out. A non-zero
    /// exit still returns stdout: Orca reports errors as JSON. Call off the main thread.
    static func runOrca(_ cli: String, _ arguments: [String], timeout: TimeInterval = 5) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = arguments
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            log.error("orca did not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Read while it runs so a full pipe can't stall it; the output is small.
        var data = Data()
        let reader = DispatchQueue(label: "orca-jump-read")
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            log.error("orca \(arguments.first ?? "", privacy: .public) timed out")
            return nil
        }
        return reader.sync { data }
    }

    private static func bringOrcaForward() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: OrcaJump.bundleID).first {
            running.activate(options: [])
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OrcaJump.bundleID) else {
            log.error("Orca.app not found")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            if let error { log.error("opening Orca failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
