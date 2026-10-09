import AppKit
import NeedsYouCore
import OSLog
import Security
import ServiceManagement
import SwiftUI

/// Where this copy runs from, Move to Applications, and the login item that depends on it.
///
/// Focus rule: nothing here runs on its own in a real app. The move starts only from the
/// Move to Applications button in Settings (an explicit click, so the Settings window may
/// be active); there's no launch-time alert. The login item check at launch is silent.
@MainActor
final class AppMover: ObservableObject {
    static let shared = AppMover()

    enum Phase: Equatable {
        case idle
        /// A NeedsYou.app is already at the destination: Settings asks inline before replacing it.
        case confirmReplace(String)
        case moving
        case moved(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    let location: AppLocation
    let bundleURL: URL
    /// /Applications, ~/Applications, or the test destination.
    let destinationDir: URL
    private let testOverride: Bool
    private let environment: [String: String]
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "move")

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        bundleURL = bundle.bundleURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let override = AppMovePlan.destinationOverride(environment: environment, bundleID: bundle.bundleIdentifier)
        testOverride = override != nil
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        location = AppLocation.classify(bundlePath: bundleURL.path, home: home, volumeIsReadOnly: readOnly,
                                        installDirs: override.map { [$0] } ?? [])
        destinationDir = URL(fileURLWithPath: AppMovePlan.destinationDirectory(
            override: override, systemWritable: FileManager.default.isWritableFile(atPath: "/Applications"), home: home))
    }

    /// Only a real app bundle offers the move (not `swift run`).
    var canMove: Bool { bundleURL.pathExtension == "app" && !location.isInstalled }

    /// "/Applications", or "~/Applications" spelled out for the person.
    var destinationName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = destinationDir.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    func cancelReplace() { phase = .idle }

    /// Settings → Move to Applications (and, after the inline confirm, Replace).
    func move(replace: Bool = false) {
        guard canMove, phase != .moving else { return }
        let target = destinationDir.appendingPathComponent(AppMovePlan.appName)
        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleURL?.standardizedFileURL.path == target.standardizedFileURL.path
        }) {
            phase = .failed("The copy in \(destinationName) is running (pid \(other.processIdentifier)). Quit it first, or quit this one and use that.")
            return
        }
        // The copy must be exactly this running app (AppSignature), not just validly signed.
        guard let cdhash = Self.runningCDHash() else {
            phase = .failed("Can't read this copy's code signature, so the moved copy couldn't be checked. Drag Needs You to \(destinationName) in Finder instead.")
            return
        }
        phase = .moving
        let source = bundleURL, dir = destinationDir, clear = AppMovePlan.clearsQuarantine(from: location)
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, Error>
            do {
                result = .success(try AppCopier.copy(source: source, destinationDir: dir, replace: replace, clearQuarantine: clear) { staged in
                    guard let args = AppSignature.verifyArguments(path: staged.path, cdhash: cdhash) else {
                        return "no code directory hash to compare"
                    }
                    let r = UpdateController.runTool("/usr/bin/codesign", args, timeout: 60, environment: nil)
                    return r.status == 0 ? nil : String(r.output.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                })
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finish(result) }
        }
    }

    /// The running code's directory hash, as the kernel has it: read from the signature, then
    /// checked against the running process (SecCodeCheckValidity on the dynamic code compares
    /// the kernel's cdhash with the bundle on disk), so a bundle replaced on disk since launch
    /// gives nil. Nil for unsigned code.
    nonisolated static func runningCDHash() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let cdhash = dict[kSecCodeInfoUnique as String] as? Data,
              let text = AppSignature.requirement(cdhash: cdhash) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else { return nil }
        return cdhash
    }

    private func finish(_ result: Result<URL, Error>) {
        switch result {
        case .failure(AppMoveError.exists(let path)):
            phase = .confirmReplace(path)
        case .failure(let error):
            log.error("move failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        case .success(let app):
            log.info("copied to \(app.path, privacy: .public); relaunching from there")
            phase = .moved(AppMovePlan.doneMessage(location: location, destination: destinationName))
            relaunch(app)
        }
    }

    /// Opens the new copy once this one has quit (so it isn't handed back to this running
    /// instance, and the hub's port is free), in the background like install.sh does, then
    /// quits. The real app forwards no environment; a test copy forwards its non-secret
    /// NEEDS_YOU_* settings (AppMovePlan.relaunchEnvironment: they're visible in `ps`).
    private func relaunch(_ app: URL) {
        var args = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; shift; exec /usr/bin/open -g \"$@\"",
                    "needs-you-move", String(ProcessInfo.processInfo.processIdentifier)]
        for (k, v) in AppMovePlan.relaunchEnvironment(environment, testOverride: testOverride) {
            args += ["--env", "\(k)=\(v)"]
        }
        args.append(app.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            phase = .failed("Copied to \(destinationName), but couldn't reopen it (\(error.localizedDescription)). Quit and open it from there.")
            return
        }
        // Long enough to read the line in Settings. Terminating stops the local hub cleanly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }

    /// mac/scripts/move-test.sh: a test build (never the real bundle id, see
    /// AppMovePlan.destinationOverride) with NEEDS_YOU_MOVE_NOW=1 moves itself at launch,
    /// as if the button had been clicked.
    func runTestMoveIfAsked() {
        guard testOverride, environment["NEEDS_YOU_MOVE_NOW"] == "1", canMove else { return }
        log.info("NEEDS_YOU_MOVE_NOW: moving to \(self.destinationDir.path, privacy: .public)")
        move(replace: environment["NEEDS_YOU_MOVE_REPLACE"] == "1")
    }
}

/// Open at login (SMAppService.mainApp). macOS ties the login item to the bundle's path, so
/// the path it was turned on from is kept (`loginItemPath`) and re-pointed after a move.
@MainActor
enum LoginItem {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "login-item")

    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// The Settings toggle. Returns the line to show under it, if any.
    static func set(_ on: Bool, defaults: UserDefaults, bundleURL: URL = Bundle.main.bundleURL) -> String? {
        var message: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change the login item: \(error.localizedDescription)."
        }
        if on && status != .notRegistered {
            defaults.set(bundleURL.path, forKey: LoginItemPolicy.pathKey)
        } else if !on {
            defaults.removeObject(forKey: LoginItemPolicy.pathKey)
        }
        if status == .requiresApproval {
            message = "Approve Needs You in System Settings → General → Login Items."
        }
        return message
    }

    /// At launch, silently: after a move, register again from this copy (see LoginItemPolicy).
    static func reconcileAtLaunch(location: AppLocation, defaults: UserDefaults, bundleURL: URL = Bundle.main.bundleURL) {
        let recorded = defaults.string(forKey: LoginItemPolicy.pathKey)
        switch LoginItemPolicy.launchAction(status: status, location: location, currentPath: bundleURL.path, recordedPath: recorded) {
        case .none:
            return
        case .record:
            defaults.set(bundleURL.path, forKey: LoginItemPolicy.pathKey)
        case .reregister:
            try? SMAppService.mainApp.unregister()
            do {
                try SMAppService.mainApp.register()
                defaults.set(bundleURL.path, forKey: LoginItemPolicy.pathKey)
                log.info("login item re-registered from \(bundleURL.path, privacy: .public)")
            } catch {
                log.error("couldn't re-register the login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Settings → General, at the top while the app isn't in Applications.
struct MoveToApplicationsSection: View {
    @ObservedObject var mover: AppMover

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let text = mover.location.moveExplanation {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                Text("Your settings, hubs and tokens stay as they are: they're kept under the app's id, not its folder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch mover.phase {
                case .idle, .failed:
                    Button("Move to Applications") { mover.move() }
                    Text("Copies it to \(mover.destinationName), opens it from there and quits this copy.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .confirmReplace(let path):
                    Text("There's already a Needs You at \(path). Replace it with this one? The old one goes to the Bin.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Replace") { mover.move(replace: true) }
                        Button("Cancel") { mover.cancelReplace() }
                    }
                case .moving:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Moving…")
                    }
                case .moved(let message):
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let message) = mover.phase {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Move to Applications")
        }
    }
}
