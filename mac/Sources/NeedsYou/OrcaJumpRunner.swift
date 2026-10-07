import AppKit
import Foundation
import NeedsYouCore
import os

/// Runs a validated `OrcaJump`: `orca terminal switch …` from a fixed path (argv, no
/// shell, 5 s timeout), then brings Orca forward. That activates Orca, never this app
/// (hard rule 2). If the switch fails, the command goes on the clipboard; Orca still
/// comes forward, so the worst case is "opens the right app".
enum OrcaJumpRunner {
    private static let log = Logger(subsystem: "app.needsyou.mac", category: "orca-jump")

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
        let fm = FileManager.default
        guard let cli = OrcaJump.cliPaths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            log.error("orca CLI not found")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = jump.arguments
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do {
            try p.run()
        } catch {
            log.error("orca terminal switch did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            log.error("orca terminal switch timed out")
            return false
        }
        if p.terminationStatus != 0 {
            log.error("orca terminal switch exited \(p.terminationStatus)")
            return false
        }
        return true
    }

    private static func bringOrcaForward() {
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
