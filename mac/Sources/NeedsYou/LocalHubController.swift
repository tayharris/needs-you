import Darwin
import Foundation
import Network
import NeedsYouCore
import os
import SystemConfiguration

/// Runs the bundled hub (`Contents/Resources/hub/needs_you_hub.py`) as a child process, so
/// a new user needs no servers: agents post to this Mac over Tailscale (or to localhost).
///
/// - Listens on 127.0.0.1 and, when the Mac is on a tailnet, its 100.x address. Never 0.0.0.0.
/// - Restarts with backoff if the hub exits; stops it on quit (`--parent-pid` also makes
///   it exit if the app dies).
/// - Re-checks the tailnet address on network changes and wake, and restarts the hub if it
///   changed.
/// - Its stdout/stderr go to os_log (subsystem app.needsyou.mac, category hub). No log
///   files.
///
/// Focus rule: nothing here touches windows or activates the app.
@MainActor
final class LocalHubController: ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case running(publicURL: String)
        case failed(String)
    }

    @Published private(set) var state: State = .off {
        didSet {
            // Setup tips need to know whether other machines can reach this hub.
            if case .running(let url) = state { model.localHubPublicURL = url } else { model.localHubPublicURL = nil }
        }
    }

    private let settings: AppSettings
    private let model: AppModel
    private let log = Logger(subsystem: "app.needsyou.mac", category: "hub")

    private var process: Process?
    private var plan: LocalHubPlan?
    private var generation = 0
    private var stopping = false
    private var backoff: TimeInterval = 1
    private var restartTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var startedAt = Date.distantPast
    private var lastStderr: [String] = []
    private var pythonChecked: PythonProbe?

    init(settings: AppSettings, model: AppModel) {
        self.settings = settings
        self.model = model
    }

    // MARK: Paths

    /// ~/Library/Application Support/NeedsYou, or NEEDS_YOU_SUPPORT_DIR (tests, trial runs:
    /// keeps hub.db, owner.token and tokens.json out of the real profile).
    static var supportDirectory: URL { SupportPaths.directory() }

    static var dbURL: URL { supportDirectory.appendingPathComponent("hub.db") }
    static var ownerTokenURL: URL { supportDirectory.appendingPathComponent("owner.token") }

    /// The hub script: NEEDS_YOU_HUB_SCRIPT, else the bundle, else the repo (for `swift run`).
    static func hubScript() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["NEEDS_YOU_HUB_SCRIPT"], fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("hub/needs_you_hub.py"), fm.fileExists(atPath: res.path) {
            return res
        }
        // mac/Sources/NeedsYou/LocalHubController.swift → repo/hub/needs_you_hub.py
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hub/needs_you_hub.py")
        return fm.fileExists(atPath: repo.path) ? repo : nil
    }

    static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    // MARK: Token

    /// Load (or mint) the owner token synchronously, so the first feed includes this Mac.
    /// The file (mode 600) is the only copy: the hub reads it, and the Keychain is never used.
    func prepareToken() {
        guard settings.runLocalHub, !settings.isDemo else {
            settings.localHubToken = nil
            return
        }
        do {
            settings.localHubToken = try OwnerToken.loadOrCreate(at: Self.ownerTokenURL)
        } catch {
            settings.localHubToken = nil
            fail("Couldn't create the hub's token file in \(Self.supportDirectory.path): \(error.localizedDescription)")
        }
    }

    // MARK: Lifecycle

    /// Apply the current setting: start, or stop and forget.
    func apply() {
        if settings.runLocalHub && !settings.isDemo {
            prepareToken()
            guard settings.localHubToken != nil else { return }
            startMonitoring()
            launch()
        } else {
            stop()
            stopMonitoring()
            settings.localHubToken = nil
            model.localHubIssue = nil
            state = .off
        }
    }

    /// Stop the child (quit, or the setting turned off).
    func stop() {
        stopping = true
        generation += 1
        restartTask?.cancel(); restartTask = nil
        readyTask?.cancel(); readyTask = nil
        guard let p = process else { return }
        process = nil
        detachPipes(p)
        if p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    /// Wake or network change: re-detect the tailnet address and restart if it moved.
    func networkMayHaveChanged() {
        guard settings.runLocalHub, !settings.isDemo else { return }
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // let interfaces settle
            guard !Task.isCancelled, let self else { return }
            guard let current = self.plan else {
                if self.process == nil, self.restartTask == nil, self.state != .starting { self.launch() }
                return
            }
            let next = await self.makePlan(script: current.script)
            if next.needsRestart(comparedTo: current) {
                self.log.info("network changed (\(current.publicURL, privacy: .public) → \(next.publicURL, privacy: .public)); restarting hub")
                self.stop()
                self.launch()
            }
        }
    }

    private func startMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            let owner = self; Task { @MainActor in owner?.networkMayHaveChanged() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        networkTask?.cancel()
        networkTask = nil
    }

    // MARK: Launch

    private func launch() {
        stopping = false
        guard process == nil else { return }
        guard let script = Self.hubScript() else {
            fail("The bundled hub is missing (Contents/Resources/hub/needs_you_hub.py). Rebuild with scripts/bundle.sh, or connect to a remote hub.")
            return
        }
        state = .starting
        generation += 1
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let probe: PythonProbe
            if let cached = self.pythonChecked, cached == .ok { probe = cached } else {
                probe = await Task.detached(priority: .utility) { Self.probePython() }.value
                self.pythonChecked = probe
            }
            guard gen == self.generation else { return }
            if let message = probe.message {
                self.fail(message)
                return
            }
            if !(await Task.detached { Self.isPortFree(LocalHub.port) }.value) {
                guard gen == self.generation else { return }
                self.fail("Port \(LocalHub.port) is already in use by another program (maybe another needs-you hub). Quit it, or turn off “Run hub on this Mac” and connect to that hub.", retry: true)
                return
            }
            let plan = await self.makePlan(script: script.path)
            guard gen == self.generation else { return }
            self.spawn(plan)
        }
    }

    private func makePlan(script: String) async -> LocalHubPlan {
        let (ip, dns) = await Task.detached(priority: .utility) { () -> (String?, String?) in
            if LocalHub.loopbackOnly { return (nil, nil) }
            let ip = TailnetAddress.current()
            return (ip, ip == nil ? nil : Self.magicDNSName())
        }.value
        return LocalHubPlan(
            script: script,
            dbPath: Self.dbURL.path,
            ownerTokenPath: Self.ownerTokenURL.path,
            hubID: LocalHub.hubID(fromHostName: Self.localHostName()),
            tailnetIP: ip,
            magicDNSName: dns,
            parentPID: getpid()
        )
    }

    private func spawn(_ plan: LocalHubPlan) {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: plan.python)
        p.arguments = plan.arguments
        p.currentDirectoryURL = Self.supportDirectory
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"   // nothing written next to the bundled script
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        lastStderr = []
        let log = self.log
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") { log.info("\(line, privacy: .public)") }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n").map(String.init)
            for line in lines { log.notice("\(line, privacy: .public)") }
            let owner = self
            Task { @MainActor in
                guard let owner else { return }
                owner.lastStderr = Array((owner.lastStderr + lines).suffix(20))
            }
        }
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let owner = self; Task { @MainActor in owner?.exited(status: status, generation: gen) }
        }
        do {
            try p.run()
        } catch {
            detachPipes(p)
            fail("Couldn't start the hub: \(error.localizedDescription)", retry: true)
            return
        }
        process = p
        self.plan = plan
        startedAt = Date()
        log.info("hub started pid \(p.processIdentifier) at \(plan.publicURL, privacy: .public)")
        waitUntilReady(publicURL: plan.publicURL, generation: gen)
    }

    private func detachPipes(_ p: Process) {
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminationHandler = nil
    }

    private func waitUntilReady(publicURL: String, generation gen: Int) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            let url = LocalHub.clientURL.appendingPathComponent("v1/health")
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if let (_, response) = try? await HubSession.shared.data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    guard let self, gen == self.generation else { return }
                    self.state = .running(publicURL: publicURL)
                    self.model.localHubIssue = nil
                    self.model.pollNow(full: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func exited(status: Int32, generation gen: Int) {
        guard gen == generation, !stopping else { return }
        if let p = process { detachPipes(p) }
        process = nil
        readyTask?.cancel()
        let ranFor = Date().timeIntervalSince(startedAt)
        if ranFor > 60 { backoff = 1 }
        let tail = lastStderr.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "exit status \(status)"
        log.error("hub exited (status \(status)) after \(Int(ranFor)) s: \(tail, privacy: .public)")
        if lastStderr.contains(where: { $0.contains("Address already in use") || $0.contains("Errno 48") }) {
            fail("Port \(LocalHub.port) is already in use by another program. Quit it, or turn off “Run hub on this Mac” and connect to that hub.", retry: true)
        } else {
            fail("The hub stopped (\(tail)). Restarting…", retry: true)
        }
    }

    /// Show a problem in Settings / the hover line; optionally retry with backoff.
    private func fail(_ message: String, retry: Bool = false) {
        state = .failed(message)
        model.localHubIssue = message
        log.error("\(message, privacy: .public)")
        guard retry, settings.runLocalHub else { return }
        let delay = backoff
        backoff = min(backoff * 2, 60)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.settings.runLocalHub, self.process == nil else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    // MARK: Probes (run off the main thread)

    /// Is the CLT python usable? Never runs the /usr/bin/python3 stub without a developer
    /// directory (it would pop the "install command line tools" dialog).
    nonisolated static func probePython() -> PythonProbe {
        let exists = FileManager.default.isExecutableFile(atPath: LocalHub.python)
        guard exists else { return .missing }
        let xcodeSelect = run("/usr/bin/xcode-select", ["-p"], timeout: 5)
        guard xcodeSelect.status == 0 else {
            return PythonProbe.classify(pythonExists: true, xcodeSelectStatus: xcodeSelect.status, importStatus: nil)
        }
        let probe = run(LocalHub.python, ["-c", "import sqlite3, http.server"], timeout: 20)
        return PythonProbe.classify(pythonExists: true, xcodeSelectStatus: 0, importStatus: probe.status, stderr: probe.stderr)
    }

    /// `tailscale status --json` → Self.DNSName, trying the app bundle then PATH.
    nonisolated static func magicDNSName() -> String? {
        for path in TailscaleStatus.candidatePaths() where FileManager.default.isExecutableFile(atPath: path) {
            let result = run(path, ["status", "--json"], timeout: 5)
            if result.status == 0, let name = TailscaleStatus.magicDNSName(fromStatusJSON: result.stdout) { return name }
        }
        return nil
    }

    nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        // Like the hub's own server: ignore TIME_WAIT leftovers from our previous run, but
        // still fail on a live listener.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    private struct RunResult: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    nonisolated private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return RunResult(status: -1, stdout: Data(), stderr: error.localizedDescription) }
        // Read before waiting so a chatty child can't block on a full pipe.
        let outData = out.fileHandleForReading.readDataToEndOfFileWithTimeout(timeout, process: p)
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, stdout: outData, stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}

private extension FileHandle {
    /// Read to EOF, killing `process` if it runs past `timeout`.
    func readDataToEndOfFileWithTimeout(_ timeout: TimeInterval, process: Process) -> Data {
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }
        return readDataToEndOfFile()
    }
}
