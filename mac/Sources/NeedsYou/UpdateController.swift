import AppKit
import CoreGraphics
import Foundation
import NeedsYouCore
import os

/// The Mac app's self-update (docs/roadmap/rollout-updates.md): checks GitHub (or a local
/// test feed) 2 minutes after launch and every 6 hours, applies the gate in
/// `NeedsYouCore/Updater.swift`, downloads and verifies the app zip, stages it, and installs
/// it with the bundled `install.sh` when the user is idle, when the app quits, or on a click
/// in Settings → Updates.
///
/// Focus rule: nothing here opens a window or activates the app. The relaunch after an
/// install is `open -g` (install.sh). The GitHub token, when one is used, stays in memory,
/// goes to api.github.com only, and is never logged or shown.
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(SemVer)
        case staged(SemVer)
        case installing(SemVer)
    }

    @Published var prefs: UpdatePrefs {
        didSet { if prefs != oldValue { prefs.save(to: defaults); if prefs.channel != oldValue.channel || prefs.soakHours != oldValue.soakHours { recheckSoon() } } }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var decision: UpdateDecision?
    /// The last check's outcome or error, for Settings.
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?
    /// Where the GitHub credential came from ("GitHub CLI (gh auth token)"), never the token.
    @Published private(set) var authSource: String = "not checked yet"
    /// After an update or a rollback: what happened, shown once in Settings → Updates.
    @Published private(set) var notice: String?

    let current: SemVer?
    let build: String
    let source: UpdateSource
    /// False for test copies (another bundle id), `swift run` and builds outside a .app:
    /// they never check on their own (a local feed still works, for testing).
    let enabled: Bool

    private let defaults: UserDefaults
    private let model: AppModel
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "update")
    private let launchedAt = Date()
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var staged: StagedApp?
    private var auth: UpdateAuth?
    private let fm = FileManager.default

    private struct StagedApp {
        var version: SemVer
        var app: URL
    }

    init(defaults: UserDefaults, model: AppModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.model = model
        prefs = UpdatePrefs.load(from: defaults)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String).flatMap { SemVer($0) }
        current = version
        build = info["CFBundleVersion"] as? String ?? "?"
        let resolved = UpdateSource.resolve(feed: environment["NEEDS_YOU_UPDATE_FEED"] ?? defaults.string(forKey: UpdatePrefs.Key.feedURL))
        source = resolved
        var isLocalFeed = false
        if case .localFeed = resolved.kind { isLocalFeed = true }
        let realApp = Bundle.main.bundleIdentifier == AppIdentity.bundleID && Bundle.main.bundleURL.pathExtension == "app"
        enabled = version != nil && (realApp || isLocalFeed)
    }

    var updatesDirectory: URL { UpdatePaths.directory(support: SupportPaths.directory()) }

    var sourceDescription: String {
        switch source.kind {
        case .github(let repo): return "GitHub releases of \(repo)"
        case .localFeed(let url): return "local test feed \(url.path)"
        }
    }

    var stagedVersion: SemVer? { staged?.version }

    // MARK: Lifecycle

    func start() {
        readInstallOutcome()
        cleanUpdatesDirectory(keep: nil)
        // One timer for both jobs: due checks (it survives sleep, unlike a 6 h timer) and
        // the idle install.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Quitting with a staged update and automatic installs on: install without relaunching
    /// (the user asked to quit).
    func appWillTerminate() {
        guard enabled, autoInstallAllowed, let staged, phase == .staged(staged.version) else { return }
        _ = launchInstaller(staged, relaunch: false)
    }

    private func tick() {
        guard enabled else { return }
        let now = Date()
        if prefs.checkAutomatically, checkTask == nil, phase == .idle || isWaiting,
           now >= UpdateSchedule.nextCheck(lastCheck: prefs.lastCheck, launchedAt: launchedAt, now: now) {
            check(manual: false)
        }
        if case .wait(_, let until) = decision, now >= until, checkTask == nil { check(manual: false) }
        if autoInstallAllowed, let staged, phase == .staged(staged.version),
           InstallWindow.canInstall(panelExpanded: model.isExpanded, hovering: model.hovering,
                                    lastArrival: model.store.latestUpdatedAt, idleSeconds: Self.idleSeconds(), now: now) {
            log.info("installing \(staged.version.description, privacy: .public) (idle)")
            install()
        }
    }

    /// A test feed never installs by itself: only a click on Restart to update.
    var autoInstallAllowed: Bool { prefs.installAutomatically && !source.isTestFeed }

    private var isWaiting: Bool {
        if case .wait = decision { return true }
        return false
    }

    private func recheckSoon() {
        guard decision != nil, checkTask == nil, staged == nil else { return }
        check(manual: true)
    }

    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType: any keyboard, mouse or tablet input.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: Check

    /// Settings → Check now, or the schedule. Downloads and stages a release that passes
    /// the gate (also during the soak when `installNow` is set: a click overrides the soak).
    func check(manual: Bool, installNow: Bool = false) {
        guard let current else {
            lastError = "This build has no version number."
            return
        }
        if case .installing = phase { return }
        checkTask?.cancel()
        if staged == nil { phase = .checking }
        lastError = nil
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { self.checkTask = nil }
                if self.phase == .checking { self.phase = .idle }
            }
            do {
                let result = try await self.evaluate(current: current)
                guard !Task.isCancelled else { return }
                self.prefs.lastCheck = Date()
                self.decision = result
                self.lastResult = result.summary
                self.log.info("update check: \(result.summary, privacy: .public)")
                switch result {
                case .ready(let c):
                    await self.stage(c, thenInstall: installNow)
                case .wait(let c, _) where installNow:
                    await self.stage(c, thenInstall: true)
                default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                if !manual { self.prefs.lastCheck = Date() }   // don't retry every minute
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.lastError = message
                self.log.notice("update check failed: \(message, privacy: .public)")
            }
        }
    }

    func installNow() {
        if let staged, phase == .staged(staged.version) {
            install()
        } else {
            check(manual: true, installNow: true)
        }
    }

    func skipAvailable() {
        let v: SemVer?
        switch decision {
        case .ready(let c), .wait(let c, _): v = c.version
        default: v = staged?.version
        }
        guard let v else { return }
        prefs.skip(v)
        if staged?.version == v {
            staged = nil
            phase = .idle
            cleanUpdatesDirectory(keep: nil)
        }
        decision = .skipped(v, "skipped")
        lastResult = decision?.summary
    }

    func dismissNotice() { notice = nil }

    private func rolledBackVersion() -> String? {
        let url = updatesDirectory.appendingPathComponent(UpdatePaths.rolledBackFile)
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func evaluate(current: SemVer) async throws -> UpdateDecision {
        let policy = prefs.policy(rolledBack: rolledBackVersion())
        let os = ProcessInfo.processInfo.operatingSystemVersion
        switch source.kind {
        case .localFeed(let dir):
            let manifestData = try readLocal(dir.appendingPathComponent(ReleaseManifest.fileName))
            var files: [String: Int] = [:]
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
                let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue
                files[name] = size ?? 0
            }
            guard let release = UpdateSource.localRelease(manifestData: manifestData, files: files, now: Date()) else {
                throw UpdateError.message("The test feed's \(ReleaseManifest.fileName) isn't a release manifest.")
            }
            authSource = "none (local test feed)"
            if let early = UpdateGate.preflight(release: release, current: current, policy: policy) { return early }
            let sigData = try? Data(contentsOf: dir.appendingPathComponent(UpdateAuthenticity.signatureName))
            if let problem = UpdateAuthenticity.verifyManifest(manifestData, signature: sigData, publicKey: UpdateAuthenticity.pinnedManifestKey) {
                return .blocked(release.version, problem)
            }
            let manifest = try ReleaseManifest.decode(manifestData)
            let sums = SHA256Sums.parse(String(decoding: try readLocal(dir.appendingPathComponent(UpdateGate.sumsName)), as: UTF8.self))
            return UpdateGate.evaluate(release: release, manifest: manifest, sums: sums, run: nil, current: current,
                                       os: os, now: Date(), policy: policy)
        case .github:
            let auth = await resolveAuth()
            authSource = auth.description
            guard let url = source.latestURL(channel: policy.channel) else { throw UpdateError.message("No release URL.") }
            let data = try await get(url, auth: auth, what: "the latest release")
            let release: ReleaseInfo
            if policy.channel == .stable {
                release = try decodeRelease(data)
            } else {
                guard let list = try? JSONDecoder().decode([ReleaseInfo].self, from: data),
                      let pick = ReleaseInfo.pick(list, channel: policy.channel) else { return .upToDate }
                release = pick
            }
            if let early = UpdateGate.preflight(release: release, current: current, policy: policy) { return early }
            let manifestData = try await asset(ReleaseManifest.fileName, of: release, auth: auth)
            if let key = UpdateAuthenticity.pinnedManifestKey {
                let sig = release.asset(named: UpdateAuthenticity.signatureName) == nil ? nil
                    : try await asset(UpdateAuthenticity.signatureName, of: release, auth: auth)
                if let problem = UpdateAuthenticity.verifyManifest(manifestData, signature: sig, publicKey: key) {
                    return .blocked(release.version, problem)
                }
            }
            guard let manifest = try? ReleaseManifest.decode(manifestData) else {
                return .blocked(release.version, "Its \(ReleaseManifest.fileName) can't be read.")
            }
            let sumsData = try await asset(UpdateGate.sumsName, of: release, auth: auth)
            let sums = SHA256Sums.parse(String(decoding: sumsData, as: UTF8.self))
            // The release run's conclusion, when Actions is readable; otherwise the
            // manifest stands in (see UpdateGate.evaluate).
            var run: WorkflowRun?
            if let id = manifest.runID, let runURL = source.runURL(id: id),
               let runData = try? await get(runURL, auth: auth, what: "the release run") {
                run = try? JSONDecoder().decode(WorkflowRun.self, from: runData)
            }
            return UpdateGate.evaluate(release: release, manifest: manifest, sums: sums, run: run, current: current,
                                       os: os, now: Date(), policy: policy)
        }
    }

    private func decodeRelease(_ data: Data) throws -> ReleaseInfo {
        do { return try ReleaseInfo.decode(data) } catch { throw UpdateError.message("GitHub sent a release this app can't read.") }
    }

    private func readLocal(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw UpdateError.message("The test feed has no \(url.lastPathComponent).") }
    }

    private func asset(_ name: String, of release: ReleaseInfo, auth: UpdateAuth) async throws -> Data {
        guard let a = release.asset(named: name), let url = source.assetURL(a) else {
            throw UpdateError.message("The release has no \(name).")
        }
        return try await get(url, auth: auth, what: name, accept: "application/octet-stream")
    }

    // MARK: Credentials

    /// gh at a fixed path, then the token file, then anonymous. Once per launch, or again
    /// after GitHub refused the token.
    private func resolveAuth() async -> UpdateAuth {
        if let auth { return auth }
        let ghToken = await Task.detached(priority: .utility) { () -> String? in
            for path in UpdateAuth.ghPaths where FileManager.default.isExecutableFile(atPath: path) {
                let r = Self.runTool(path, ["auth", "token", "--hostname", "github.com"], timeout: 5,
                                     environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "GH_PROMPT_DISABLED": "1",
                                                   "GH_NO_UPDATE_NOTIFIER": "1"])
                if r.status == 0, let t = UpdateAuth.sanitize(r.output) { return t }
            }
            return nil
        }.value
        var fileToken: String?
        let file = SupportPaths.directory().appendingPathComponent(UpdateAuth.tokenFileName)
        if let attrs = try? fm.attributesOfItem(atPath: file.path), let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue {
            if UpdateAuth.fileModeIsPrivate(mode) {
                fileToken = try? String(contentsOf: file, encoding: .utf8)
            } else {
                lastError = "\(UpdateAuth.tokenFileName) is readable by other users; run chmod 600 on it. It isn't used until then."
            }
        }
        let chosen = UpdateAuth.choose(ghToken: ghToken, fileToken: fileToken)
        auth = chosen
        return chosen
    }

    // MARK: HTTP

    private lazy var session: URLSession = {
        let cfg = HubSession.makeConfiguration(requestTimeout: 30, resourceTimeout: 600)
        return URLSession(configuration: cfg, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    private func request(_ url: URL, auth: UpdateAuth, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("NeedsYou/\(current?.description ?? "?")", forHTTPHeaderField: "User-Agent")
        if let token = auth.token, UpdateSource.mayCarryToken(url) {
            r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func get(_ url: URL, auth: UpdateAuth, what: String, accept: String = "application/vnd.github+json") async throws -> Data {
        guard UpdateSource.mayDownload(from: url) else { throw UpdateError.message("Refused to fetch \(what) from \(url.host ?? "?").") }
        let (data, response) = try await send { try await self.session.data(for: self.request(url, auth: auth, accept: accept)) }
        try checkResponse(response, what: what, auth: auth)
        return data
    }

    private func send<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as URLError {
            throw UpdateError.message("Couldn't reach GitHub (\(e.code == .notConnectedToInternet ? "offline" : e.localizedDescription)).")
        }
    }

    private func checkResponse(_ response: URLResponse, what: String, auth: UpdateAuth) throws {
        guard let http = response as? HTTPURLResponse else { throw UpdateError.message("No HTTP response for \(what).") }
        guard UpdateSource.mayDownload(from: http.url) else {
            throw UpdateError.message("\(what) was redirected to \(http.url?.host ?? "?"), which isn't GitHub; refused.")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 404 where auth == .anonymous:
            throw UpdateError.message("GitHub found no release. While the repo is private the app needs a token: install the GitHub CLI and run `gh auth login`, or put a fine-grained token (Contents: read, Actions: read) in ~/Library/Application Support/NeedsYou/\(UpdateAuth.tokenFileName) with mode 600.")
        case 404:
            throw UpdateError.message("GitHub has no published release yet (or the token can't see this repo).")
        case 401:
            self.auth = nil   // ask gh / the file again next time
            throw UpdateError.message("GitHub refused the token (\(auth.description)). Run `gh auth login` again or replace the token file.")
        case 403, 429:
            throw UpdateError.message("GitHub refused \(what) (HTTP \(http.statusCode), probably the rate limit). The next check retries.")
        default:
            throw UpdateError.message("GitHub answered HTTP \(http.statusCode) for \(what).")
        }
    }

    // MARK: Download, verify, stage

    private func stage(_ c: UpdateCandidate, thenInstall: Bool) async {
        if let staged, staged.version == c.version {
            phase = .staged(c.version)
            if thenInstall { install() }
            return
        }
        phase = .downloading(c.version)
        do {
            let app = try await downloadAndVerify(c)
            staged = StagedApp(version: c.version, app: app)
            phase = .staged(c.version)
            lastResult = "\(c.version) is downloaded and verified. "
                + (autoInstallAllowed ? "It installs when you've been away for 10 minutes, or when you quit." : "Click Restart to update.")
            log.info("staged \(c.version.description, privacy: .public)")
            if thenInstall { install() }
        } catch {
            phase = .idle
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = "Couldn't stage \(c.version): \(message)"
            log.error("staging \(c.version.description, privacy: .public) failed: \(message, privacy: .public)")
            cleanUpdatesDirectory(keep: nil)
        }
    }

    private func downloadAndVerify(_ c: UpdateCandidate) async throws -> URL {
        let dir = updatesDirectory.appendingPathComponent(c.version.description, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cleanUpdatesDirectory(keep: c.version.description)
        let zip = dir.appendingPathComponent("NeedsYou.zip")
        guard let url = source.assetURL(c.zip) else { throw UpdateError.message("No download URL for \(c.zip.name).") }
        if url.isFileURL {
            try fm.copyItem(at: url, to: zip)
        } else {
            guard UpdateSource.mayDownload(from: url) else { throw UpdateError.message("Refused to download from \(url.host ?? "?").") }
            let auth = await resolveAuth()
            let (tmp, response) = try await send { try await self.session.download(for: self.request(url, auth: auth, accept: "application/octet-stream")) }
            try checkResponse(response, what: c.zip.name, auth: auth)
            try fm.moveItem(at: tmp, to: zip)
        }
        let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue ?? -1
        let digest = try await Task.detached(priority: .utility) { try Checksum.sha256(fileAt: zip) }.value
        if let problem = UpdateGate.verifyDownload(sha256: digest, size: size, candidate: c) {
            throw UpdateError.message(problem)
        }
        // A fresh directory only this user can write, so nothing can be swapped in between
        // the checks below and the install.
        let unpacked = dir.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for d in [updatesDirectory, dir, unpacked] {
            let mode = (try? fm.attributesOfItem(atPath: d.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard mode & 0o022 == 0 else { throw UpdateError.message("\(d.path) is writable by other users.") }
        }
        let ditto = await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 120)
        guard ditto.status == 0 else { throw UpdateError.message("Couldn't unzip it (ditto: \(ditto.output.prefix(200))).") }
        let app = unpacked.appendingPathComponent("NeedsYou.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.message("The zip has no NeedsYou.app.")
        }
        if let problem = UpdateGate.verifyBundle(info: info, expectedID: AppIdentity.bundleID, version: c.version, newerThan: current) {
            throw UpdateError.message(problem)
        }
        if let escape = symlinkEscaping(app) {
            throw UpdateError.message("The app has a symlink that points outside it (\(escape)).")
        }
        let sign = await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)
        guard sign.status == 0 else { throw UpdateError.message("The app's signature doesn't verify (\(sign.output.prefix(200))).") }
        let runningInfo = await Self.run("/usr/bin/codesign", ["-dv", Bundle.main.bundleURL.path], timeout: 30)
        let stagedInfo = await Self.run("/usr/bin/codesign", ["-dv", app.path], timeout: 30)
        if let problem = UpdateAuthenticity.checkSigner(runningTeam: UpdateAuthenticity.teamID(codesignOutput: runningInfo.output),
                                                        stagedTeam: UpdateAuthenticity.teamID(codesignOutput: stagedInfo.output)) {
            throw UpdateError.message(problem)
        }
        guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/scripts/install.sh").path) else {
            throw UpdateError.message("The new app has no bundled install.sh.")
        }
        // A URLSession download isn't quarantined, but a copy from a local feed may be. The
        // checksum above is the gate, so the staged copy only loses the flag.
        _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], timeout: 30)
        try? fm.removeItem(at: zip)
        return app
    }

    /// The first symlink in the bundle that resolves outside it, if any.
    private func symlinkEscaping(_ app: URL) -> String? {
        guard let walker = fm.enumerator(atPath: app.path) else { return "unreadable" }
        while let rel = walker.nextObject() as? String {
            let path = app.appendingPathComponent(rel).path
            guard let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { return rel }
            let dir = rel.split(separator: "/").dropLast().map(String.init)
            if UpdateAuthenticity.linkEscapes(destination: dest, directory: dir) { return rel }
        }
        return nil
    }

    /// Keeps at most one staged version (and the rollback record).
    private func cleanUpdatesDirectory(keep: String?) {
        guard let names = try? fm.contentsOfDirectory(atPath: updatesDirectory.path) else { return }
        for name in names where SemVer(name) != nil && name != keep && name != staged?.version.description {
            try? fm.removeItem(at: updatesDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Install

    /// Settings → Restart to update, or the idle/quit paths. install.sh quits this app,
    /// swaps the bundle (keeping NeedsYou.app.previous), relaunches with `open -g`, and puts
    /// the old version back if the new one doesn't stay running.
    func install() {
        guard let staged else { return }
        if launchInstaller(staged, relaunch: true) {
            phase = .installing(staged.version)
            lastResult = "Installing \(staged.version)…"
        }
    }

    @discardableResult
    private func launchInstaller(_ s: StagedApp, relaunch: Bool) -> Bool {
        let bundle = Bundle.main.bundleURL
        let dest = bundle.deletingLastPathComponent()
        guard bundle.lastPathComponent == "NeedsYou.app" else {
            lastError = "The app is installed as \(bundle.lastPathComponent); install.sh only updates NeedsYou.app."
            return false
        }
        guard fm.isWritableFile(atPath: dest.path) else {
            lastError = "\(s.version) is ready, but \(dest.path) isn't writable. Run: \(installCommand(s, dest: dest))"
            return false
        }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts/install.sh"),
              fm.isReadableFile(atPath: bundled.path) else {
            lastError = "This build has no bundled install.sh; update with mac/scripts/install.sh --app \(s.app.path)."
            return false
        }
        // Run a copy: the bundle it lives in is moved during the swap.
        let script = updatesDirectory.appendingPathComponent("install.sh")
        do {
            try? fm.removeItem(at: script)
            try fm.copyItem(at: bundled, to: script)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            try (s.version.description + "\n").write(to: updatesDirectory.appendingPathComponent(UpdatePaths.attemptFile),
                                                      atomically: true, encoding: .utf8)
        } catch {
            lastError = "Couldn't prepare the installer: \(error.localizedDescription)"
            return false
        }
        var args = ["--app", s.app.path, "--dest", dest.path, "--record-rollback", updatesDirectory.path]
        if !relaunch { args.append("--no-launch") }
        // Detached: bash backgrounds install.sh and exits, so it outlives this app (which
        // install.sh quits) and is reparented to launchd.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "\"$0\" \"$@\" >>\"$NY_INSTALL_LOG\" 2>&1 </dev/null & disown", script.path] + args
        var env = ProcessInfo.processInfo.environment
        env["NY_INSTALL_LOG"] = updatesDirectory.appendingPathComponent(UpdatePaths.installLog).path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            lastError = "Couldn't start install.sh: \(error.localizedDescription)"
            return false
        }
        log.info("install.sh started for \(s.version.description, privacy: .public) (relaunch: \(relaunch))")
        return true
    }

    private func installCommand(_ s: StagedApp, dest: URL) -> String {
        "\"\(s.app.path)/Contents/Resources/scripts/install.sh\" --app \"\(s.app.path)\" --dest \"\(dest.path)\""
    }

    /// At launch: did the last install land, or was it rolled back?
    private func readInstallOutcome() {
        let attempt = updatesDirectory.appendingPathComponent(UpdatePaths.attemptFile)
        guard let raw = try? String(contentsOf: attempt, encoding: .utf8) else { return }
        try? fm.removeItem(at: attempt)
        let tried = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, SemVer(tried) == current {
            notice = "Updated to \(current). If macOS asks whether python3 may accept incoming connections, choose Allow, or other machines can't reach this Mac's hub."
            log.info("updated to \(current.description, privacy: .public)")
        } else if rolledBackVersion() == tried {
            notice = "\(tried) didn't stay running, so the previous version was put back. \(tried) is skipped; see \(updatesDirectory.appendingPathComponent(UpdatePaths.installLog).path)."
            log.error("update to \(tried, privacy: .public) was rolled back")
        }
    }

    // MARK: Processes

    struct ToolResult: Sendable {
        var status: Int32
        var output: String
    }

    nonisolated static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> ToolResult {
        await Task.detached(priority: .utility) { runTool(path, args, timeout: timeout, environment: nil) }.value
    }

    /// Runs a tool with an argv list (no shell) and returns its exit status and output.
    /// The output is returned to the caller only, never logged (gh prints the token).
    nonisolated static func runTool(_ path: String, _ args: [String], timeout: TimeInterval,
                                    environment: [String: String]?) -> ToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let environment { p.environment = environment }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ToolResult(status: -1, output: error.localizedDescription) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return ToolResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum UpdateError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// The token goes to api.github.com only: a redirect anywhere else (GitHub sends asset
/// downloads to its CDN with a signed URL) loses the Authorization header.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Off GitHub's hosts: no redirect at all (the 3xx is then refused by the caller).
        guard UpdateSource.mayDownload(from: request.url) else { return completionHandler(nil) }
        var next = request
        if !UpdateSource.mayCarryToken(request.url) { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(next)
    }
}
