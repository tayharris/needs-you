import Foundation

/// Where the running NeedsYou.app lives, and what that means for Open at login and for
/// moving it to Applications. Pure path logic (the app passes Bundle.main's path and the
/// volume's read-only flag), so every case is testable.
///
/// Settings don't depend on the location: they are UserDefaults under the bundle id
/// (`app.needsyou.mac`) and files in ~/Library/Application Support/NeedsYou, so a moved
/// copy finds them all. The login item (`SMAppService.mainApp`) is the one thing tied to
/// the bundle's path; `LoginItemPolicy` re-points it after a move.
public enum AppLocation: Equatable {
    /// /Applications or ~/Applications (or a test destination): Open at login works.
    case applications
    /// Gatekeeper's App Translocation: macOS runs a quarantined app that wasn't moved with
    /// Finder from a random read-only path (/private/var/folders/…/AppTranslocation/…).
    case translocated
    /// A mounted disk image or another read-only volume under /Volumes (the DMG).
    case diskImage(volume: String)
    /// ~/Downloads.
    case downloads
    /// Anywhere else (a build folder, the Desktop, an external disk): the folder's name.
    case elsewhere(folder: String)

    /// Classifies a bundle path. `home` is the user's home folder; `volumeIsReadOnly` is the
    /// bundle's volume's read-only flag; `installDirs` are extra folders that count as
    /// Applications (a test destination, see `AppMovePlan.destinationOverride`).
    public static func classify(bundlePath: String, home: String, volumeIsReadOnly: Bool,
                                installDirs: [String] = []) -> AppLocation {
        let path = normalized(bundlePath)
        let parent = (path as NSString).deletingLastPathComponent
        let homeDir = normalized(home)
        let apps = ["/Applications", homeDir + "/Applications"] + installDirs.map(normalized)
        for dir in apps where parent == dir || parent.hasPrefix(dir + "/") {
            return .applications
        }
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") {
            let volume = path.split(separator: "/").dropFirst().first.map(String.init) ?? "a disk"
            if volumeIsReadOnly { return .diskImage(volume: volume) }
            return .elsewhere(folder: volume)
        }
        let downloads = homeDir + "/Downloads"
        if parent == downloads || parent.hasPrefix(downloads + "/") { return .downloads }
        let folder = (parent as NSString).lastPathComponent
        return .elsewhere(folder: folder.isEmpty ? parent : folder)
    }

    /// /private/var → /var style aliases and trailing slashes don't change the answer.
    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        for (alias, real) in [("/private/var/", "/var/"), ("/private/tmp/", "/tmp/")] where p.hasPrefix(alias) {
            p = real + p.dropFirst(alias.count)
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Open at login and in-place updates only work from here.
    public var isInstalled: Bool { self == .applications }

    /// Eject the disk image after moving (a running app keeps its DMG busy until it quits).
    public var ejectAfterMoving: Bool {
        if case .diskImage = self { return true }
        return false
    }

    /// "Downloads", "the NeedsYou disk image", ... as in "Needs You is running from …".
    public var placeName: String {
        switch self {
        case .applications: return "Applications"
        case .translocated: return "a temporary copy macOS made (App Translocation)"
        case .diskImage(let volume): return "the \(volume) disk image"
        case .downloads: return "Downloads"
        case .elsewhere(let folder): return folder
        }
    }

    /// The line under the disabled Open at login toggle; nil when it works.
    public var loginExplanation: String? {
        guard !isInstalled else { return nil }
        return "Needs You is running from \(placeName). Move it to Applications to open it at login."
    }

    /// The paragraph next to Move to Applications; nil when it's already there.
    public var moveExplanation: String? {
        switch self {
        case .applications:
            return nil
        case .translocated:
            return "macOS is running Needs You from a temporary, read-only copy because it wasn't moved to Applications. Move it there so it can open at login and update itself."
        case .diskImage:
            return "Needs You is running from the disk image. Move it to Applications so it can open at login and update itself, then eject the disk image."
        case .downloads, .elsewhere:
            return "Needs You is running from \(placeName). Move it to Applications so it can open at login and update itself."
        }
    }
}

/// Where Move to Applications copies to, and what it does with the copy. The app does the
/// file work with FileManager (no admin prompt, no AppleScript).
public enum AppMovePlan {
    public static let appName = "NeedsYou.app"

    /// The test destination: NEEDS_YOU_MOVE_DEST, honoured only by a test build (a bundle id
    /// other than the real one, as mac/scripts/move-test.sh makes), never by the real app.
    public static func destinationOverride(environment: [String: String], bundleID: String?) -> String? {
        guard bundleID != AppIdentity.bundleID,
              let dir = environment["NEEDS_YOU_MOVE_DEST"], dir.hasPrefix("/") else { return nil }
        return dir
    }

    /// /Applications when it's writable (an admin user), else ~/Applications, which is
    /// created if missing. An override (tests) wins.
    public static func destinationDirectory(override: String?, systemWritable: Bool, home: String) -> String {
        if let override { return override }
        return systemWritable ? "/Applications" : (home as NSString).appendingPathComponent("Applications")
    }

    /// Quarantine is kept on the copy, with one exception: a translocated app. macOS
    /// translocates a quarantined app every launch until Finder moves it, and a copy made by
    /// the app itself doesn't count as moved, so the copy in Applications would run
    /// translocated again. The bundle is the one already running (it passed Gatekeeper)
    /// and its signature is verified after the copy, as the updater does for its staged app.
    public static func clearsQuarantine(from location: AppLocation) -> Bool {
        location == .translocated
    }

    /// The staging name next to the destination, so the final step is a rename on one volume.
    public static func stagingName(pid: Int32) -> String { ".\(appName).moving.\(pid)" }

    /// What Settings says once the copy is made, before the new copy launches.
    public static func doneMessage(location: AppLocation, destination: String) -> String {
        var s = "Moved to \(destination). Opening it from there…"
        if location.ejectAfterMoving { s += " Eject the disk image afterwards." }
        else if location != .translocated { s += " You can delete the old copy." }
        return s
    }
}

/// SMAppService.mainApp's status, mirrored so the decision is testable without it.
public enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// What to do with the login item at launch.
public enum LoginItemLaunchAction: Equatable {
    /// Leave it.
    case none
    /// It's on but this build never recorded where from (an older build turned it on): record
    /// the current path.
    case record
    /// It was turned on from another copy (the app moved), or macOS lost it: register again
    /// from this copy and record the path.
    case reregister
}

public enum LoginItemPolicy {
    /// The UserDefaults key holding the bundle path the login item was registered from.
    public static let pathKey = "loginItemPath"

    /// `recordedPath` is where Open at login was last turned on (nil if never, or turned
    /// off). Only a copy in Applications ever touches the login item, so launching a stray
    /// copy from Downloads never steals it from the installed one. A login item the person
    /// removed in System Settings (notRegistered) stays removed.
    public static func launchAction(status: LoginItemStatus, location: AppLocation,
                                    currentPath: String, recordedPath: String?) -> LoginItemLaunchAction {
        guard location.isInstalled else { return .none }
        let current = AppLocation.normalized(currentPath)
        switch status {
        case .enabled:
            guard let recordedPath else { return .record }
            return AppLocation.normalized(recordedPath) == current ? .none : .reregister
        case .notFound:
            return recordedPath == nil ? .none : .reregister
        case .notRegistered, .requiresApproval:
            return .none
        }
    }
}

public enum AppMoveError: Error, Equatable, LocalizedError {
    /// A NeedsYou.app is already there; replacing it needs the person's confirmation.
    case exists(String)
    /// The running copy is already the destination.
    case sameAsSource
    /// The copy's signature didn't verify; nothing was replaced.
    case signature(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .exists(let path): return "There's already a Needs You at \(path)."
        case .sameAsSource: return "Needs You is already there."
        case .signature(let detail): return "The copy's signature didn't verify (\(detail)). Nothing was replaced."
        case .failed(let detail): return "Couldn't move Needs You: \(detail)"
        }
    }
}

/// The file work of Move to Applications, with FileManager only.
public enum AppCopier {
    /// Copies `source` to `destinationDir/NeedsYou.app`: first to a staging name in the same
    /// folder (FileManager keeps extended attributes, so quarantine comes along and the
    /// signature's files are copied byte for byte), then `verify` checks the staged copy
    /// (nil = fine, else the problem), then a rename puts it in place. An existing copy is
    /// replaced only with `replace` (the person confirmed); it's moved to the Bin when it
    /// can be, else deleted. Returns the new bundle's URL.
    public static func copy(source: URL, destinationDir: URL, replace: Bool, clearQuarantine: Bool,
                            pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                            fileManager fm: FileManager = .default, useTrash: Bool = true,
                            verify: (URL) -> String? = { _ in nil }) throws -> URL {
        let target = destinationDir.appendingPathComponent(AppMovePlan.appName)
        if AppLocation.normalized(source.resolvingSymlinksInPath().path)
            == AppLocation.normalized(target.resolvingSymlinksInPath().path) {
            throw AppMoveError.sameAsSource
        }
        let exists = fm.fileExists(atPath: target.path)
        if exists && !replace { throw AppMoveError.exists(target.path) }
        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        } catch {
            throw AppMoveError.failed("can't create \(destinationDir.path) (\(error.localizedDescription))")
        }
        let staging = destinationDir.appendingPathComponent(AppMovePlan.stagingName(pid: pid))
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw AppMoveError.failed("copying to \(destinationDir.path) failed (\(error.localizedDescription))")
        }
        if clearQuarantine { removeQuarantine(under: staging, fileManager: fm) }
        if let problem = verify(staging) {
            try? fm.removeItem(at: staging)
            throw AppMoveError.signature(problem)
        }
        var aside: URL?
        if exists {
            let a = destinationDir.appendingPathComponent(".\(AppMovePlan.appName).replaced.\(pid)")
            try? fm.removeItem(at: a)
            do {
                try fm.moveItem(at: target, to: a)
                aside = a
            } catch {
                try? fm.removeItem(at: staging)
                throw AppMoveError.failed("couldn't move the existing copy aside (\(error.localizedDescription))")
            }
        }
        do {
            try fm.moveItem(at: staging, to: target)
        } catch {
            if let aside { try? fm.moveItem(at: aside, to: target) }
            try? fm.removeItem(at: staging)
            throw AppMoveError.failed("couldn't put the copy in place (\(error.localizedDescription))")
        }
        if let aside, !useTrash || (try? fm.trashItem(at: aside, resultingItemURL: nil)) == nil {
            try? fm.removeItem(at: aside)
        }
        return target
    }

    public static let quarantineAttribute = "com.apple.quarantine"

    /// `xattr -dr com.apple.quarantine`, without a process.
    static func removeQuarantine(under root: URL, fileManager fm: FileManager) {
        var paths = [root.path]
        if let walker = fm.enumerator(atPath: root.path) {
            while let rel = walker.nextObject() as? String { paths.append(root.appendingPathComponent(rel).path) }
        }
        for p in paths { _ = removexattr(p, quarantineAttribute, XATTR_NOFOLLOW) }
    }
}
