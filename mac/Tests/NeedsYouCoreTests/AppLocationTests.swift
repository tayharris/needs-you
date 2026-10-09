#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Where the app runs from, Move to Applications' file work (in a temp dir, never
/// /Applications), and when the login item is re-pointed after a move.
final class AppLocationTests: XCTestCase {
    static var allTests = [
        ("testApplicationsFolders", testApplicationsFolders),
        ("testTranslocatedDiskImageDownloadsElsewhere", testTranslocatedDiskImageDownloadsElsewhere),
        ("testExplanations", testExplanations),
        ("testDestination", testDestination),
        ("testOverrideOnlyForTestBuilds", testOverrideOnlyForTestBuilds),
        ("testRelaunchEnvironmentFilter", testRelaunchEnvironmentFilter),
        ("testQuarantineKeptExceptWhenTranslocated",testQuarantineKeptExceptWhenTranslocated),
        ("testLoginItemLaunchAction", testLoginItemLaunchAction),
        ("testCopyKeepsQuarantineAndContents", testCopyKeepsQuarantineAndContents),
        ("testCopyClearsQuarantineWhenAsked", testCopyClearsQuarantineWhenAsked),
        ("testExistingCopyNeedsConfirmation", testExistingCopyNeedsConfirmation),
        ("testFailedVerifyReplacesNothing", testFailedVerifyReplacesNothing),
        ("testSameAsSourceRefused", testSameAsSourceRefused),
        ("testCopyMustBeTheRunningApp", testCopyMustBeTheRunningApp),
    ]

    private let home = "/Users/sam"
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("needsyou-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func at(_ path: String, readOnly: Bool = false, installDirs: [String] = []) -> AppLocation {
        AppLocation.classify(bundlePath: path, home: home, volumeIsReadOnly: readOnly, installDirs: installDirs)
    }

    func testApplicationsFolders() {
        XCTAssertEqual(at("/Applications/NeedsYou.app"), .applications)
        XCTAssertEqual(at("/Applications/NeedsYou.app/"), .applications)
        XCTAssertEqual(at("/Applications/Utilities/NeedsYou.app"), .applications)
        XCTAssertEqual(at("/Users/sam/Applications/NeedsYou.app"), .applications)
        XCTAssertEqual(at("/private/tmp/t/Apps/NeedsYou.app", installDirs: ["/tmp/t/Apps"]), .applications)
        XCTAssertTrue(at("/Applications/NeedsYou.app").isInstalled)
        // Not fooled by look-alike folders.
        XCTAssertNotEqual(at("/ApplicationsOld/NeedsYou.app"), .applications)
        XCTAssertNotEqual(at("/Users/sam/Downloads/Applications/NeedsYou.app"), .applications)
    }

    func testTranslocatedDiskImageDownloadsElsewhere() {
        XCTAssertEqual(at("/private/var/folders/xy/abc123/T/AppTranslocation/0F3A-11/d/NeedsYou.app", readOnly: true), .translocated)
        XCTAssertEqual(at("/Volumes/NeedsYou/NeedsYou.app", readOnly: true), .diskImage(volume: "NeedsYou"))
        XCTAssertEqual(at("/Volumes/NeedsYou 1/NeedsYou.app", readOnly: true), .diskImage(volume: "NeedsYou 1"))
        // A writable external disk isn't a disk image: nothing to eject.
        XCTAssertEqual(at("/Volumes/Backup/Apps/NeedsYou.app", readOnly: false), .elsewhere(folder: "Backup"))
        XCTAssertEqual(at("/Users/sam/Downloads/NeedsYou.app"), .downloads)
        XCTAssertEqual(at("/Users/sam/Downloads/NeedsYou-0.2.1-macos/NeedsYou.app"), .downloads)
        XCTAssertEqual(at("/Users/sam/src/needs-you/mac/dist/NeedsYou.app"), .elsewhere(folder: "dist"))
        XCTAssertEqual(at("/Users/sam/Desktop/NeedsYou.app"), .elsewhere(folder: "Desktop"))
        for loc in [at("/Users/sam/Downloads/NeedsYou.app"), at("/Volumes/NeedsYou/NeedsYou.app", readOnly: true)] {
            XCTAssertFalse(loc.isInstalled)
        }
    }

    func testExplanations() {
        XCTAssertNil(AppLocation.applications.loginExplanation)
        XCTAssertNil(AppLocation.applications.moveExplanation)
        XCTAssertEqual(AppLocation.downloads.loginExplanation,
                       "Needs You is running from Downloads. Move it to Applications to open it at login.")
        XCTAssertEqual(AppLocation.diskImage(volume: "NeedsYou").loginExplanation,
                       "Needs You is running from the NeedsYou disk image. Move it to Applications to open it at login.")
        XCTAssertTrue(AppLocation.diskImage(volume: "NeedsYou").ejectAfterMoving)
        XCTAssertTrue(AppLocation.diskImage(volume: "NeedsYou").moveExplanation!.contains("eject the disk image"))
        XCTAssertFalse(AppLocation.downloads.ejectAfterMoving)
        XCTAssertTrue(AppLocation.translocated.moveExplanation!.contains("temporary"))
        XCTAssertTrue(AppMovePlan.doneMessage(location: .diskImage(volume: "NeedsYou"), destination: "/Applications").contains("Eject"))
        XCTAssertTrue(AppMovePlan.doneMessage(location: .downloads, destination: "/Applications").contains("delete the old copy"))
    }

    func testDestination() {
        XCTAssertEqual(AppMovePlan.destinationDirectory(override: nil, systemWritable: true, home: home), "/Applications")
        XCTAssertEqual(AppMovePlan.destinationDirectory(override: nil, systemWritable: false, home: home), "/Users/sam/Applications")
        XCTAssertEqual(AppMovePlan.destinationDirectory(override: "/tmp/t/Apps", systemWritable: true, home: home), "/tmp/t/Apps")
    }

    func testOverrideOnlyForTestBuilds() {
        let env = ["NEEDS_YOU_MOVE_DEST": "/tmp/t/Apps"]
        XCTAssertNil(AppMovePlan.destinationOverride(environment: env, bundleID: AppIdentity.bundleID))
        XCTAssertEqual(AppMovePlan.destinationOverride(environment: env, bundleID: "app.needsyou.mac.movetest"), "/tmp/t/Apps")
        XCTAssertNil(AppMovePlan.destinationOverride(environment: ["NEEDS_YOU_MOVE_DEST": "relative"], bundleID: "x"))
        XCTAssertNil(AppMovePlan.destinationOverride(environment: [:], bundleID: "x"))
    }

    func testRelaunchEnvironmentFilter() {
        let env = [
            "NEEDS_YOU_SUPPORT_DIR": "/tmp/s", "NEEDS_YOU_HUB_PORT": "25000", "NEEDS_YOU_MOVE_DEST": "/tmp/a",
            "NEEDS_YOU_MOVE_NOW": "1", "NEEDS_YOU_TOKEN": "t", "NEEDS_YOU_PEER_SECRET": "s",
            "NEEDS_YOU_INVITE_CODE": "c", "NEEDS_YOU_API_KEY": "k", "NEEDS_YOU_owner_token": "t2",
            "HOME": "/Users/sam", "GITHUB_TOKEN": "g",
        ]
        // The real app forwards nothing.
        XCTAssertTrue(AppMovePlan.relaunchEnvironment(env, testOverride: false).isEmpty)
        let forwarded = AppMovePlan.relaunchEnvironment(env, testOverride: true)
        XCTAssertEqual(forwarded.map { $0.0 }, ["NEEDS_YOU_HUB_PORT", "NEEDS_YOU_MOVE_DEST", "NEEDS_YOU_SUPPORT_DIR"])
        XCTAssertEqual(forwarded.map { $0.1 }, ["25000", "/tmp/a", "/tmp/s"])
    }

    func testQuarantineKeptExceptWhenTranslocated() {
        XCTAssertTrue(AppMovePlan.clearsQuarantine(from: .translocated))
        for loc: AppLocation in [.downloads, .diskImage(volume: "NeedsYou"), .elsewhere(folder: "dist")] {
            XCTAssertFalse(AppMovePlan.clearsQuarantine(from: loc))
        }
    }

    func testLoginItemLaunchAction() {
        let apps = "/Applications/NeedsYou.app"
        func act(_ s: LoginItemStatus, _ recorded: String?, at loc: AppLocation = .applications) -> LoginItemLaunchAction {
            LoginItemPolicy.launchAction(status: s, location: loc, currentPath: apps, recordedPath: recorded)
        }
        // Turned on from Downloads by an older build, now running from Applications.
        XCTAssertEqual(act(.enabled, "/Users/sam/Downloads/NeedsYou.app"), .reregister)
        XCTAssertEqual(act(.notFound, "/Users/sam/Downloads/NeedsYou.app"), .reregister)
        XCTAssertEqual(act(.enabled, apps), .none)
        XCTAssertEqual(act(.enabled, apps + "/"), .none)
        // On, but never recorded (turned on by a build before this one): adopt it.
        XCTAssertEqual(act(.enabled, nil), .record)
        XCTAssertEqual(act(.notFound, nil), .none)
        // Removed in System Settings, or waiting for approval: left alone.
        XCTAssertEqual(act(.notRegistered, "/Users/sam/Downloads/NeedsYou.app"), .none)
        XCTAssertEqual(act(.requiresApproval, "/Users/sam/Downloads/NeedsYou.app"), .none)
        // A stray copy outside Applications never touches it.
        for loc: AppLocation in [.downloads, .translocated, .diskImage(volume: "NeedsYou"), .elsewhere(folder: "dist")] {
            XCTAssertEqual(act(.enabled, "/Some/Other/NeedsYou.app", at: loc), .none)
            XCTAssertEqual(act(.notFound, apps, at: loc), .none)
        }
    }

    // MARK: Copy

    private func makeApp(in folder: String, marker: String) throws -> URL {
        let app = dir.appendingPathComponent(folder).appendingPathComponent("NeedsYou.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try marker.write(to: macos.appendingPathComponent("NeedsYou"), atomically: true, encoding: .utf8)
        try "plist".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    private let quarantine = "0083;6700a1b2;Safari;"

    private func setQuarantine(_ url: URL) {
        let value = Array(quarantine.utf8)
        _ = setxattr(url.path, AppCopier.quarantineAttribute, value, value.count, 0, XATTR_NOFOLLOW)
    }

    private func readQuarantine(_ url: URL) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = getxattr(url.path, AppCopier.quarantineAttribute, &buf, buf.count, 0, XATTR_NOFOLLOW)
        return n < 0 ? nil : String(decoding: buf.prefix(n), as: UTF8.self)
    }

    private func contents(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/NeedsYou"), encoding: .utf8)
    }

    func testCopyKeepsQuarantineAndContents() throws {
        let src = try makeApp(in: "Downloads", marker: "v2")
        setQuarantine(src)
        setQuarantine(src.appendingPathComponent("Contents/MacOS/NeedsYou"))
        let dest = dir.appendingPathComponent("Applications")   // created on demand, like ~/Applications
        var verified: URL?
        let out = try AppCopier.copy(source: src, destinationDir: dest, replace: false, clearQuarantine: false, pid: 42) {
            verified = $0
            return nil
        }
        XCTAssertEqual(out.path, dest.appendingPathComponent("NeedsYou.app").path)
        XCTAssertEqual(verified?.lastPathComponent, ".NeedsYou.app.moving.42")
        XCTAssertEqual(contents(out), "v2")
        XCTAssertEqual(readQuarantine(out), quarantine)
        XCTAssertEqual(readQuarantine(out.appendingPathComponent("Contents/MacOS/NeedsYou")), quarantine)
        // The original is left where it was; no staging leftovers.
        XCTAssertEqual(contents(src), "v2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["NeedsYou.app"])
    }

    func testCopyClearsQuarantineWhenAsked() throws {
        let src = try makeApp(in: "Translocated", marker: "v2")
        setQuarantine(src)
        setQuarantine(src.appendingPathComponent("Contents/MacOS/NeedsYou"))
        let out = try AppCopier.copy(source: src, destinationDir: dir.appendingPathComponent("Applications"),
                                     replace: false, clearQuarantine: true)
        XCTAssertNil(readQuarantine(out))
        XCTAssertNil(readQuarantine(out.appendingPathComponent("Contents/MacOS/NeedsYou")))
        XCTAssertEqual(readQuarantine(src), quarantine, "the source keeps its flag")
    }

    func testExistingCopyNeedsConfirmation() throws {
        let src = try makeApp(in: "Downloads", marker: "new")
        let old = try makeApp(in: "Applications", marker: "old")
        let dest = old.deletingLastPathComponent()
        do {
            _ = try AppCopier.copy(source: src, destinationDir: dest, replace: false, clearQuarantine: false)
            XCTFail("replaced without confirmation")
        } catch let e as AppMoveError {
            XCTAssertEqual(e, .exists(old.path))
        }
        XCTAssertEqual(contents(old), "old")
        let out = try AppCopier.copy(source: src, destinationDir: dest, replace: true, clearQuarantine: false, useTrash: false)
        XCTAssertEqual(contents(out), "new")
        // The old copy was deleted (the app moves it to the Bin); nothing hidden is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["NeedsYou.app"])
    }

    func testFailedVerifyReplacesNothing() throws {
        let src = try makeApp(in: "Downloads", marker: "new")
        let old = try makeApp(in: "Applications", marker: "old")
        let dest = old.deletingLastPathComponent()
        do {
            _ = try AppCopier.copy(source: src, destinationDir: dest, replace: true, clearQuarantine: false) { _ in "invalid signature" }
            XCTFail("a copy that fails verification was put in place")
        } catch let e as AppMoveError {
            XCTAssertEqual(e, .signature("invalid signature"))
        }
        XCTAssertEqual(contents(old), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["NeedsYou.app"])
    }

    func testSameAsSourceRefused() throws {
        let app = try makeApp(in: "Applications", marker: "v1")
        do {
            _ = try AppCopier.copy(source: app, destinationDir: app.deletingLastPathComponent(), replace: true, clearQuarantine: false)
            XCTFail("copied onto itself")
        } catch let e as AppMoveError {
            XCTAssertEqual(e, .sameAsSource)
        }
        XCTAssertEqual(contents(app), "v1")
    }

    /// Security finding 4: `codesign --verify` alone passes any validly signed bundle, so the
    /// check also requires the running app's cdhash; without one, nothing is checked or moved.
    func testCopyMustBeTheRunningApp() {
        let hash = Data((0..<20).map { UInt8($0 * 13 % 256) })
        XCTAssertEqual(AppSignature.requirement(cdhash: hash), "cdhash H\"000d1a2734414e5b6875828f9ca9b6c3d0ddeaf7\"")
        XCTAssertEqual(AppSignature.verifyArguments(path: "/Applications/.NeedsYou.app.moving.1", cdhash: hash),
                       ["--verify", "--deep", "--strict", "-R", "=cdhash H\"000d1a2734414e5b6875828f9ca9b6c3d0ddeaf7\"",
                        "/Applications/.NeedsYou.app.moving.1"])
        XCTAssertNil(AppSignature.verifyArguments(path: "/x", cdhash: nil))
        XCTAssertNil(AppSignature.verifyArguments(path: "/x", cdhash: Data()))
        XCTAssertNil(AppSignature.verifyArguments(path: "/x", cdhash: Data(repeating: 1, count: 32)))
    }
}
