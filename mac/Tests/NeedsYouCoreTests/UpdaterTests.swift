#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// The self-update gate (docs/roadmap/rollout-updates.md): versions, GitHub and manifest
/// decoding, SHA256SUMS, the decision, the install window and the token chain.
final class UpdaterTests: XCTestCase {
    static var allTests = [
        ("testSemVer", testSemVer),
        ("testOSVersion", testOSVersion),
        ("testDecodesGitHubRelease", testDecodesGitHubRelease),
        ("testPickRelease", testPickRelease),
        ("testDecodesManifest", testDecodesManifest),
        ("testSHA256Sums", testSHA256Sums),
        ("testChecksum", testChecksum),
        ("testReady", testReady),
        ("testUpToDateAndOlder", testUpToDateAndOlder),
        ("testDraftAndPrerelease", testDraftAndPrerelease),
        ("testSkippedAndRolledBack", testSkippedAndRolledBack),
        ("testNeedsManifestZipAndSums", testNeedsManifestZipAndSums),
        ("testChecksumMismatches", testChecksumMismatches),
        ("testRunMustBeGreen", testRunMustBeGreen),
        ("testManifestTestsAndVersion", testManifestTestsAndVersion),
        ("testMinMacOS", testMinMacOS),
        ("testSoak", testSoak),
        ("testVerifyDownloadAndBundle", testVerifyDownloadAndBundle),
        ("testInstallWindow", testInstallWindow),
        ("testSchedule", testSchedule),
        ("testAuthChain", testAuthChain),
        ("testSource", testSource),
        ("testLocalFeedRelease", testLocalFeedRelease),
        ("testPrefs", testPrefs),
    ]

    func testPrefs() throws {
        let suite = "ny-updateprefs-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let fresh = UpdatePrefs.load(from: d)
        XCTAssertEqual(fresh, UpdatePrefs())
        XCTAssertTrue(fresh.checkAutomatically)
        XCTAssertTrue(fresh.installAutomatically)
        XCTAssertEqual(fresh.channel, .stable)
        XCTAssertEqual(fresh.soakHours, 2)
        XCTAssertEqual(fresh.policy(rolledBack: nil).soak, UpdatePolicy.defaultSoak)

        var p = fresh
        p.checkAutomatically = false
        p.channel = .prerelease
        p.soakHours = 0
        p.skip(SemVer(0, 2, 0))
        p.skip(SemVer(0, 2, 0))
        p.lastCheck = now
        p.save(to: d)
        let back = UpdatePrefs.load(from: d)
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.skipped, ["0.2.0"])
        XCTAssertEqual(back.policy(rolledBack: "0.1.9"), UpdatePolicy(channel: .prerelease, soak: 0, skipped: ["0.2.0"], rolledBack: "0.1.9"))

        // Garbage falls back to the defaults.
        d.set("nightly", forKey: UpdatePrefs.Key.channel)
        d.set(-3, forKey: UpdatePrefs.Key.soakHours)
        d.set(["0.3.0", "not-a-version"], forKey: UpdatePrefs.Key.skipped)
        let bad = UpdatePrefs.load(from: d)
        XCTAssertEqual(bad.channel, .stable)
        XCTAssertEqual(bad.soakHours, 2)
        XCTAssertEqual(bad.skipped, ["0.3.0"])
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = SemVer(0, 1, 1)
    private let mac14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
    private let zipSum = String(repeating: "ab", count: 32)
    private let commit = String(repeating: "c", count: 40)

    private func release(_ tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         publishedAgo: TimeInterval = 3 * 3600, files: [String]? = nil) -> ReleaseInfo {
        let names = files ?? ["NeedsYou-0.2.0-macos.zip", "NeedsYou-0.2.0.dmg", "release-manifest.json", "SHA256SUMS"]
        return ReleaseInfo(tagName: tag, draft: draft, prerelease: prerelease, publishedAt: now.addingTimeInterval(-publishedAgo),
                           htmlURL: "https://github.com/o/r/releases/tag/\(tag)",
                           assets: names.enumerated().map { ReleaseAsset(id: $0.offset + 1, name: $0.element, size: $0.element.hasSuffix(".zip") ? 1000 : 10) })
    }

    private func manifest(version: String = "0.2.0", tests: String? = "success", minMacOS: String? = "14.0",
                          sha: String? = nil, size: Int = 1000) -> ReleaseManifest {
        ReleaseManifest(version: version, commit: commit, runID: 42, tests: tests, minMacOS: minMacOS,
                        assets: [.init(name: "NeedsYou-0.2.0-macos.zip", sha256: sha ?? zipSum, size: size)])
    }

    private var sums: [String: String] { ["NeedsYou-0.2.0-macos.zip": zipSum] }
    private var greenRun: WorkflowRun { WorkflowRun(id: 42, headSHA: commit, conclusion: "success") }

    private func decide(_ r: ReleaseInfo? = nil, m: ReleaseManifest? = nil, sums s: [String: String]? = nil,
                        run: WorkflowRun?? = nil, os: OperatingSystemVersion? = nil,
                        policy: UpdatePolicy = UpdatePolicy()) -> UpdateDecision {
        UpdateGate.evaluate(release: r ?? release(), manifest: m ?? manifest(), sums: s ?? sums,
                            run: run ?? greenRun, current: current, os: os ?? mac14, now: now, policy: policy)
    }

    private func isBlocked(_ d: UpdateDecision, _ contains: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .blocked(_, let why) = d {
            XCTAssertTrue(why.contains(contains), "\(why) doesn't mention \(contains)", file: file, line: line)
        } else {
            XCTFail("expected blocked, got \(d)", file: file, line: line)
        }
    }

    func testSemVer() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer(1, 2, 3))
        XCTAssertEqual(SemVer("v0.10.0"), SemVer(0, 10, 0))
        XCTAssertEqual(SemVer(" 2.0.0\n"), SemVer(2, 0, 0))
        XCTAssertNil(SemVer("1.2"))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer("1.2.x"))
        XCTAssertNil(SemVer("1.2.3-beta"))
        XCTAssertNil(SemVer("1..3"))
        XCTAssertNil(SemVer(""))
        XCTAssertTrue(SemVer(0, 10, 0) > SemVer(0, 9, 9))   // numeric, not string, compare
        XCTAssertTrue(SemVer(1, 0, 0) > SemVer(0, 99, 99))
        XCTAssertTrue(SemVer(0, 1, 2) > SemVer(0, 1, 1))
        XCTAssertFalse(SemVer(0, 1, 1) > SemVer(0, 1, 1))
        XCTAssertEqual(SemVer(1, 2, 3).description, "1.2.3")
    }

    func testOSVersion() {
        let v = SemVer.osVersion("14.0")
        XCTAssertEqual(v?.majorVersion, 14)
        XCTAssertEqual(SemVer.osVersion("15")?.majorVersion, 15)
        XCTAssertNil(SemVer.osVersion("fourteen"))
        XCTAssertTrue(SemVer.atLeast(mac14, SemVer.osVersion("14.0")!))
        XCTAssertTrue(SemVer.atLeast(mac14, SemVer.osVersion("14.5")!))
        XCTAssertFalse(SemVer.atLeast(mac14, SemVer.osVersion("14.6")!))
        XCTAssertFalse(SemVer.atLeast(mac14, SemVer.osVersion("15.0")!))
    }

    func testDecodesGitHubRelease() throws {
        // Trimmed from GET /repos/{o}/{r}/releases/latest; unknown fields are ignored.
        let json = """
        {"url":"https://api.github.com/repos/o/r/releases/1","tag_name":"v0.2.0","name":"needs-you 0.2.0",
         "draft":false,"prerelease":false,"created_at":"2026-10-07T01:00:00Z","published_at":"2026-10-07T02:00:00Z",
         "html_url":"https://github.com/o/r/releases/tag/v0.2.0","author":{"login":"x"},
         "assets":[{"url":"https://api.github.com/repos/o/r/releases/assets/7","id":7,"name":"NeedsYou-0.2.0-macos.zip",
                    "size":1234,"content_type":"application/zip","browser_download_url":"https://github.com/o/r/releases/download/v0.2.0/NeedsYou-0.2.0-macos.zip"},
                   {"id":8,"name":"SHA256SUMS","size":300}]}
        """
        let r = try ReleaseInfo.decode(Data(json.utf8))
        XCTAssertEqual(r.tagName, "v0.2.0")
        XCTAssertEqual(r.version, SemVer(0, 2, 0))
        XCTAssertFalse(r.draft)
        XCTAssertEqual(r.publishedAt, HubJSON.parseDate("2026-10-07T02:00:00Z"))
        XCTAssertEqual(r.assets.count, 2)
        XCTAssertEqual(r.asset(named: "NeedsYou-0.2.0-macos.zip")?.id, 7)
        XCTAssertEqual(r.asset(named: "NeedsYou-0.2.0-macos.zip")?.apiURL, "https://api.github.com/repos/o/r/releases/assets/7")
        XCTAssertNil(r.asset(named: "SHA256SUMS")?.apiURL)
        // A draft has no published_at.
        let draft = try ReleaseInfo.decode(Data(#"{"tag_name":"v0.3.0","draft":true,"published_at":null}"#.utf8))
        XCTAssertTrue(draft.draft)
        XCTAssertNil(draft.publishedAt)
        XCTAssertEqual(draft.assets, [])
    }

    func testPickRelease() {
        let list = [release("v0.3.0", prerelease: true), release("v0.4.0", draft: true), release("v0.2.0"), release("nightly")]
        XCTAssertEqual(ReleaseInfo.pick(list, channel: .stable)?.tagName, "v0.2.0")
        XCTAssertEqual(ReleaseInfo.pick(list, channel: .prerelease)?.tagName, "v0.3.0")
        XCTAssertNil(ReleaseInfo.pick([release("v0.4.0", draft: true)], channel: .prerelease))
    }

    func testDecodesManifest() throws {
        // As scripts/build-release.sh writes it.
        let json = """
        {"assets":[{"name":"NeedsYou-0.2.0-macos.zip","sha256":"\(zipSum)","size":1000},
                   {"name":"needs-you-cli-0.2.0","sha256":"\(zipSum)","size":5}],
         "built_at":"2026-10-07T02:00:00Z","commit":"\(commit)","min_macos":"14.0","repository":"o/r",
         "run_attempt":1,"run_id":42,"schema":1,"tag":"v0.2.0","tests":"success","version":"0.2.0","future":{"x":1}}
        """
        let m = try ReleaseManifest.decode(Data(json.utf8))
        XCTAssertEqual(m.version, "0.2.0")
        XCTAssertEqual(m.runID, 42)
        XCTAssertEqual(m.tests, "success")
        XCTAssertEqual(m.minMacOS, "14.0")
        XCTAssertEqual(m.asset(named: "NeedsYou-0.2.0-macos.zip")?.size, 1000)
        // Built outside CI: run_id null.
        let local = try ReleaseManifest.decode(Data(#"{"version":"0.2.0","run_id":null,"tests":"local","assets":[]}"#.utf8))
        XCTAssertNil(local.runID)
        // No asset list: not a manifest.
        XCTAssertNil(try? ReleaseManifest.decode(Data(#"{"version":"0.2.0"}"#.utf8)))
    }

    func testSHA256Sums() {
        let a = String(repeating: "0", count: 64)
        let b = String(repeating: "f", count: 64)
        let text = "\(a)  NeedsYou-0.2.0-macos.zip\n\(b) *needs-you-cli-0.2.0\nnot a line\n\(a.uppercased())  upper\nxyz  short\n"
        let sums = SHA256Sums.parse(text)
        XCTAssertEqual(sums["NeedsYou-0.2.0-macos.zip"], a)
        XCTAssertEqual(sums["needs-you-cli-0.2.0"], b)
        XCTAssertEqual(sums["upper"], a)
        XCTAssertNil(sums["short"])
        XCTAssertEqual(sums.count, 3)
    }

    func testChecksum() throws {
        XCTAssertEqual(Checksum.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ny-sum-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Checksum.sha256(fileAt: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(Checksum.isHexDigest(zipSum))
        XCTAssertFalse(Checksum.isHexDigest(zipSum.uppercased()))
        XCTAssertFalse(Checksum.isHexDigest("abc"))
    }

    func testReady() {
        guard case .ready(let c) = decide() else { return XCTFail("expected ready, got \(decide())") }
        XCTAssertEqual(c.version, SemVer(0, 2, 0))
        XCTAssertEqual(c.zip.name, "NeedsYou-0.2.0-macos.zip")
        XCTAssertEqual(c.sha256, zipSum)
        XCTAssertEqual(c.size, 1000)
        // Actions not readable: the manifest stands in.
        if case .ready = decide(run: .some(nil)) {} else { XCTFail("no run should still be ready") }
    }

    func testUpToDateAndOlder() {
        XCTAssertEqual(decide(release("v0.1.1"), m: manifest(version: "0.1.1")), .upToDate)
        XCTAssertEqual(decide(release("v0.1.0")), .upToDate)
        XCTAssertEqual(UpdateGate.preflight(release: release("v0.0.9"), current: current, policy: UpdatePolicy()), .upToDate)
        isBlocked(decide(release("latest")), "isn't X.Y.Z")
    }

    func testDraftAndPrerelease() {
        isBlocked(decide(release(draft: true)), "draft")
        XCTAssertEqual(decide(release(prerelease: true)), .upToDate)
        if case .ready = decide(release(prerelease: true), policy: UpdatePolicy(channel: .prerelease)) {} else {
            XCTFail("the prerelease channel takes prereleases")
        }
        // Drafts never, whatever the channel.
        isBlocked(decide(release(draft: true), policy: UpdatePolicy(channel: .prerelease)), "draft")
    }

    func testSkippedAndRolledBack() {
        XCTAssertEqual(decide(policy: UpdatePolicy(skipped: ["0.2.0"])), .skipped(SemVer(0, 2, 0), "skipped"))
        XCTAssertEqual(decide(policy: UpdatePolicy(rolledBack: "0.2.0")), .skipped(SemVer(0, 2, 0), "rolled back on this Mac"))
        // Skipping 0.2.0 doesn't skip 0.2.1.
        if case .ready = decide(policy: UpdatePolicy(skipped: ["0.1.9"], rolledBack: "0.1.5")) {} else { XCTFail() }
    }

    func testNeedsManifestZipAndSums() {
        isBlocked(decide(release(files: ["NeedsYou-0.2.0-macos.zip", "SHA256SUMS"])), "release-manifest.json")
        isBlocked(decide(release(files: ["release-manifest.json", "SHA256SUMS"])), "NeedsYou-0.2.0-macos.zip")
        isBlocked(decide(release(files: ["release-manifest.json", "NeedsYou-0.2.0-macos.zip"])), "SHA256SUMS")
        XCTAssertNil(UpdateGate.preflight(release: release(), current: current, policy: UpdatePolicy()))
    }

    func testChecksumMismatches() {
        isBlocked(decide(sums: [:]), "SHA256SUMS doesn't list")
        isBlocked(decide(sums: ["NeedsYou-0.2.0-macos.zip": String(repeating: "00", count: 32)]), "disagree")
        isBlocked(decide(m: manifest(sha: "nothex")), "doesn't list")
        isBlocked(decide(m: manifest(size: 999)), "size")
        let other = ReleaseManifest(version: "0.2.0", runID: 42, assets: [.init(name: "other.zip", sha256: zipSum, size: 1)])
        isBlocked(decide(m: other), "doesn't list NeedsYou-0.2.0-macos.zip")
    }

    func testRunMustBeGreen() {
        isBlocked(decide(run: WorkflowRun(id: 42, headSHA: commit, conclusion: "failure")), "concluded failure")
        isBlocked(decide(run: WorkflowRun(id: 42, headSHA: commit, status: "in_progress", conclusion: nil)), "concluded nothing yet")
        isBlocked(decide(run: WorkflowRun(id: 42, headSHA: String(repeating: "d", count: 40), conclusion: "success")), "different commit")
        isBlocked(decide(run: WorkflowRun(id: 7, headSHA: commit, conclusion: "success")), "doesn't match")
    }

    func testManifestTestsAndVersion() {
        isBlocked(decide(m: manifest(tests: "failure")), "tests as failure")
        isBlocked(decide(m: manifest(tests: "local")), "tests as local")
        isBlocked(decide(m: manifest(version: "0.2.1")), "manifest says 0.2.1")
        if case .ready = decide(m: manifest(tests: nil)) {} else { XCTFail("an older manifest without tests is fine") }
    }

    func testMinMacOS() {
        isBlocked(decide(m: manifest(minMacOS: "15.0")), "macOS 15.0")
        isBlocked(decide(m: manifest(minMacOS: "soon")), "isn't a version")
        if case .ready = decide(m: manifest(minMacOS: nil)) {} else { XCTFail() }
    }

    func testSoak() {
        let fresh = release(publishedAgo: 30 * 60)
        guard case .wait(let c, let until) = decide(fresh) else { return XCTFail("expected wait") }
        XCTAssertEqual(c.version, SemVer(0, 2, 0))
        XCTAssertEqual(until, now.addingTimeInterval(-30 * 60 + UpdatePolicy.defaultSoak))
        if case .ready = decide(fresh, policy: UpdatePolicy(soak: 0)) {} else { XCTFail("soak 0 installs at once") }
        if case .wait = decide(release(publishedAgo: 20 * 3600), policy: UpdatePolicy(soak: 24 * 3600)) {} else { XCTFail() }
        XCTAssertEqual(UpdatePolicy(soak: -5).soak, 0)
        XCTAssertTrue(UpdatePolicy.soakChoices.contains(UpdatePolicy.defaultSoak))
    }

    func testVerifyDownloadAndBundle() {
        guard case .ready(let c) = decide() else { return XCTFail() }
        XCTAssertNil(UpdateGate.verifyDownload(sha256: zipSum, size: 1000, candidate: c))
        XCTAssertNil(UpdateGate.verifyDownload(sha256: zipSum.uppercased(), size: 1000, candidate: c))
        XCTAssertNotNil(UpdateGate.verifyDownload(sha256: zipSum, size: 999, candidate: c))
        XCTAssertNotNil(UpdateGate.verifyDownload(sha256: String(repeating: "0", count: 64), size: 1000, candidate: c))

        let id = "app.needsyou.mac"
        XCTAssertNil(UpdateGate.verifyBundle(info: ["CFBundleIdentifier": id, "CFBundleShortVersionString": "0.2.0"], expectedID: id, version: c.version))
        XCTAssertNotNil(UpdateGate.verifyBundle(info: ["CFBundleIdentifier": "com.evil", "CFBundleShortVersionString": "0.2.0"], expectedID: id, version: c.version))
        XCTAssertNotNil(UpdateGate.verifyBundle(info: ["CFBundleIdentifier": id, "CFBundleShortVersionString": "0.1.9"], expectedID: id, version: c.version))
        XCTAssertNotNil(UpdateGate.verifyBundle(info: [:], expectedID: id, version: c.version))
    }

    func testInstallWindow() {
        let idle = InstallWindow.idleNeeded
        XCTAssertTrue(InstallWindow.canInstall(panelExpanded: false, hovering: false, lastArrival: nil, idleSeconds: idle, now: now))
        XCTAssertFalse(InstallWindow.canInstall(panelExpanded: true, hovering: false, lastArrival: nil, idleSeconds: idle, now: now))
        XCTAssertFalse(InstallWindow.canInstall(panelExpanded: false, hovering: true, lastArrival: nil, idleSeconds: idle, now: now))
        XCTAssertFalse(InstallWindow.canInstall(panelExpanded: false, hovering: false, lastArrival: now.addingTimeInterval(-60), idleSeconds: idle, now: now))
        XCTAssertTrue(InstallWindow.canInstall(panelExpanded: false, hovering: false, lastArrival: now.addingTimeInterval(-180), idleSeconds: idle, now: now))
        XCTAssertFalse(InstallWindow.canInstall(panelExpanded: false, hovering: false, lastArrival: nil, idleSeconds: idle - 1, now: now))
    }

    func testSchedule() {
        let launched = now
        XCTAssertEqual(UpdateSchedule.nextCheck(lastCheck: nil, launchedAt: launched, now: now), now.addingTimeInterval(120))
        XCTAssertEqual(UpdateSchedule.nextCheck(lastCheck: nil, launchedAt: launched.addingTimeInterval(-3600), now: now), now)
        XCTAssertEqual(UpdateSchedule.nextCheck(lastCheck: now.addingTimeInterval(-3600), launchedAt: launched.addingTimeInterval(-7200), now: now),
                       now.addingTimeInterval(5 * 3600))
    }

    func testAuthChain() {
        let gh = "gho_" + String(repeating: "a", count: 36)
        let pat = "github_pat_" + String(repeating: "B1", count: 20)
        XCTAssertEqual(UpdateAuth.choose(ghToken: gh + "\n", fileToken: pat), .gh(token: gh))
        XCTAssertEqual(UpdateAuth.choose(ghToken: nil, fileToken: pat), .tokenFile(token: pat))
        XCTAssertEqual(UpdateAuth.choose(ghToken: "", fileToken: " \(pat)\n"), .tokenFile(token: pat))
        XCTAssertEqual(UpdateAuth.choose(ghToken: nil, fileToken: nil), .anonymous)
        // gh's error text, two lines, or shell junk are never used as a token.
        XCTAssertNil(UpdateAuth.sanitize("no oauth token found for github.com"))
        XCTAssertNil(UpdateAuth.sanitize(gh + "\n" + gh))
        XCTAssertNil(UpdateAuth.sanitize("short"))
        XCTAssertNil(UpdateAuth.sanitize(gh + ";rm"))
        // Settings shows the source, never the secret.
        XCTAssertFalse(UpdateAuth.gh(token: gh).description.contains(gh))
        XCTAssertFalse(UpdateAuth.tokenFile(token: pat).description.contains(pat))
        XCTAssertFalse(String(describing: UpdateAuth.gh(token: gh)).contains(gh))
        XCTAssertEqual(UpdateAuth.ghPaths, ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
        XCTAssertTrue(UpdateAuth.fileModeIsPrivate(0o600))
        XCTAssertTrue(UpdateAuth.fileModeIsPrivate(0o400))
        XCTAssertFalse(UpdateAuth.fileModeIsPrivate(0o644))
    }

    func testSource() {
        XCTAssertEqual(UpdateSource.resolve(feed: nil, repository: nil).kind, .github(UpdateSource.defaultRepository))
        XCTAssertEqual(UpdateSource.resolve(feed: "", repository: "me/fork").kind, .github("me/fork"))
        XCTAssertEqual(UpdateSource.resolve(feed: nil, repository: "../etc").kind, .github(UpdateSource.defaultRepository))
        XCTAssertEqual(UpdateSource.resolve(feed: nil, repository: "a/b/c").kind, .github(UpdateSource.defaultRepository))
        XCTAssertEqual(UpdateSource.resolve(feed: "file:///tmp/feed/", repository: nil).kind, .localFeed(URL(string: "file:///tmp/feed/")!))
        if case .localFeed(let u) = UpdateSource.resolve(feed: "/tmp/feed", repository: nil).kind {
            XCTAssertEqual(u.path, "/tmp/feed")
        } else { XCTFail() }
        // An https feed isn't a thing: GitHub it is.
        XCTAssertEqual(UpdateSource.resolve(feed: "https://evil.example.com/", repository: nil).kind, .github(UpdateSource.defaultRepository))

        let gh = UpdateSource(kind: .github("o/r"))
        XCTAssertEqual(gh.latestURL(channel: .stable)?.absoluteString, "https://api.github.com/repos/o/r/releases/latest")
        XCTAssertEqual(gh.latestURL(channel: .prerelease)?.absoluteString, "https://api.github.com/repos/o/r/releases?per_page=10")
        XCTAssertEqual(gh.runURL(id: 42)?.absoluteString, "https://api.github.com/repos/o/r/actions/runs/42")
        XCTAssertEqual(gh.assetURL(ReleaseAsset(id: 7, name: "x.zip"))?.absoluteString, "https://api.github.com/repos/o/r/releases/assets/7")
        // An asset URL on another host is never used (it would get the token).
        XCTAssertEqual(gh.assetURL(ReleaseAsset(id: 7, name: "x.zip", apiURL: "https://evil.example.com/a"))?.absoluteString,
                       "https://api.github.com/repos/o/r/releases/assets/7")
        XCTAssertTrue(UpdateSource.mayCarryToken(URL(string: "https://api.github.com/repos/o/r")))
        XCTAssertFalse(UpdateSource.mayCarryToken(URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertFalse(UpdateSource.mayCarryToken(URL(string: "http://api.github.com/x")))
        XCTAssertFalse(UpdateSource.mayCarryToken(nil))

        let local = UpdateSource(kind: .localFeed(URL(fileURLWithPath: "/tmp/feed", isDirectory: true)))
        XCTAssertNil(local.latestURL(channel: .stable))
        XCTAssertEqual(local.assetURL(ReleaseAsset(name: "SHA256SUMS"))?.path, "/tmp/feed/SHA256SUMS")
        XCTAssertNil(local.assetURL(ReleaseAsset(name: "../secret")))
    }

    func testLocalFeedRelease() {
        let data = Data(#"{"version":"0.2.0","built_at":"2026-10-07T02:00:00Z","tests":"local","assets":[]}"#.utf8)
        let r = UpdateSource.localRelease(manifestData: data, files: ["SHA256SUMS": 10, "NeedsYou-0.2.0-macos.zip": 1000, "release-manifest.json": 5], now: now)
        XCTAssertEqual(r?.tagName, "v0.2.0")
        XCTAssertEqual(r?.publishedAt, HubJSON.parseDate("2026-10-07T02:00:00Z"))
        XCTAssertEqual(r?.asset(named: "NeedsYou-0.2.0-macos.zip")?.size, 1000)
        XCTAssertNil(UpdateSource.localRelease(manifestData: Data("{}".utf8), files: [:], now: now))
    }
}
