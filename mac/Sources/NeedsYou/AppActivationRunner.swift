import AppKit
import Foundation
import NeedsYouCore
import os

/// Runs a validated `AppActivation` (needsyou://app/activate) from a card click: brings the
/// listed app forward if it's running. Never launches an app, never runs anything, and never
/// activates Needs You (hard rule 2; `AppActivation` can't hold this app's id, and this
/// checks the running bundle id again). Worst case: a listed terminal or editor comes forward.
enum AppActivationRunner {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "app-activate")

    static func run(_ activation: AppActivation) {
        let id = activation.bundleID
        guard id != AppIdentity.bundleID, id != Bundle.main.bundleIdentifier else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            log.info("\(activation.displayName, privacy: .public) isn't running; nothing to bring forward")
            return
        }
        log.info("bring \(activation.displayName, privacy: .public) forward")
        app.activate(options: [])
    }
}
