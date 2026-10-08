import Darwin
import Foundation

// The hub that runs inside the app (`Resources/hub/needs_you_hub.py` as a child process).
// This file holds the pure parts: address detection, the public URL choice, and the
// command line. Process management lives in the app (LocalHubController).

public enum LocalHub {
    public static let defaultPort = 8765
    /// 8765, or NEEDS_YOU_HUB_PORT (test instances, so they never collide with the real app's hub).
    public static let port: Int = port(environment: ProcessInfo.processInfo.environment)
    /// NEEDS_YOU_HUB_LOOPBACK_ONLY=1: listen on 127.0.0.1 only and skip tailnet detection
    /// (test instances: no network exposure, no Local Network prompt).
    public static let loopbackOnly: Bool = ProcessInfo.processInfo.environment["NEEDS_YOU_HUB_LOOPBACK_ONLY"] == "1"

    public static func port(environment: [String: String]) -> Int {
        if let s = environment["NEEDS_YOU_HUB_PORT"], let p = Int(s), (1024...65535).contains(p) { return p }
        return defaultPort
    }
    /// What the app itself talks to.
    public static let clientURL = URL(string: "http://127.0.0.1:\(port)")!
    /// Shown in place of the hub's host name.
    public static let displayName = "this Mac"
    public static let python = "/usr/bin/python3"

    /// The hub id: the Mac's local host name, lowercased, safe characters only.
    public static func hubID(fromHostName name: String) -> String {
        var s = name.lowercased()
        if s.hasSuffix(".local") { s.removeLast(6) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "mac" : String(cleaned.prefix(63))
    }

    /// The hub process runs but hasn't answered its health check (LocalHubReadiness).
    /// `lastOutput` is its last line of output, if any, shortened.
    public static func notAnsweringMessage(seconds: Int, lastOutput: String?, port: Int = LocalHub.port) -> String {
        var text = "The hub on this Mac started but hasn't answered on 127.0.0.1:\(port) for \(seconds) s"
        if let line = lastOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            text += " (last output: \(line.count > 160 ? String(line.prefix(160)) + "…" : line))"
        }
        return text + ". Restart it; if it happens again, quit and reopen Needs You."
    }

    /// Keys for "this is the local hub" checks (the app's own URL, plus localhost).
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "127.0.0.1" || host == "localhost" || host == "::1") && (url.port ?? 80) == port
    }
}

// MARK: - Start-up health check

/// Waiting for a freshly started hub to answer `/v1/health`: every half second until
/// `timeout`, then once "timed out" (the app says what's wrong and offers a restart), then
/// every 5 s in case it comes up after all.
public struct LocalHubReadiness: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case ready
        /// Check again after this many seconds.
        case wait(TimeInterval)
        /// The deadline just passed (reported once). Check again after `slowCheckInterval`.
        case timedOut
    }

    /// 30 s, or NEEDS_YOU_HUB_READY_TIMEOUT (1–600 s; test copies).
    public static let defaultTimeout: TimeInterval = timeout(environment: ProcessInfo.processInfo.environment)

    public static func timeout(environment: [String: String]) -> TimeInterval {
        if let s = environment["NEEDS_YOU_HUB_READY_TIMEOUT"], let t = Int(s), (1...600).contains(t) { return TimeInterval(t) }
        return 30
    }
    public static let checkInterval: TimeInterval = 0.5
    public static let slowCheckInterval: TimeInterval = 5
    /// Each health request's own timeout, so a hub that accepts but never answers can't
    /// hold one check past the deadline.
    public static let requestTimeout: TimeInterval = 2

    public let startedAt: Date
    public let timeout: TimeInterval
    public private(set) var timedOut = false

    public init(startedAt: Date, timeout: TimeInterval = LocalHubReadiness.defaultTimeout) {
        self.startedAt = startedAt
        self.timeout = timeout
    }

    public mutating func next(answered: Bool, now: Date) -> Step {
        if answered { return .ready }
        if timedOut { return .wait(Self.slowCheckInterval) }
        if now.timeIntervalSince(startedAt) >= timeout {
            timedOut = true
            return .timedOut
        }
        return .wait(Self.checkInterval)
    }
}

// MARK: - Tailnet address

public enum TailnetAddress {
    /// True for IPv4 addresses in Tailscale's CGNAT range 100.64.0.0/10.
    public static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, address.split(separator: ".", omittingEmptySubsequences: false).count == 4 else { return false }
        return parts[0] == 100 && (parts[1] & 0b1100_0000) == 0b0100_0000
    }

    /// The first tailnet address in interface order.
    public static func pick(from addresses: [String]) -> String? {
        addresses.first(where: isTailnetIPv4)
    }

    /// This Mac's IPv4 addresses on interfaces that are up (getifaddrs).
    public static func interfaceIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }

    public static func current() -> String? { pick(from: interfaceIPv4Addresses()) }
}

// MARK: - Tailscale

public enum TailscaleStatus {
    /// Where to look for the CLI: the App Store / standalone app first, then common
    /// install locations and PATH (GUI apps get a minimal PATH).
    public static func candidatePaths(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var paths = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ]
        for dir in (path ?? "").split(separator: ":") where !dir.isEmpty {
            let p = "\(dir)/tailscale"
            if !paths.contains(p) { paths.append(p) }
        }
        return paths
    }

    /// Is the Tailscale CLI (or app) on this Mac? Only file checks; nothing is run.
    public static func isInstalled(path: String? = ProcessInfo.processInfo.environment["PATH"],
                                   isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        candidatePaths(path: path).contains(where: isExecutable)
    }

    /// `Self.DNSName` from `tailscale status --json`, without the trailing dot.
    public static func magicDNSName(fromStatusJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = obj["Self"] as? [String: Any],
              var name = me["DNSName"] as? String
        else { return nil }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name.lowercased()
    }
}

// MARK: - Public URL and command line

public struct LocalHubPlan: Equatable, Sendable {
    public var script: String
    public var python: String = LocalHub.python
    public var port: Int = LocalHub.port
    public var dbPath: String
    public var ownerTokenPath: String
    public var hubID: String
    public var tailnetIP: String?
    public var magicDNSName: String?
    public var parentPID: Int32

    public init(script: String, dbPath: String, ownerTokenPath: String, hubID: String,
                tailnetIP: String?, magicDNSName: String?, parentPID: Int32) {
        self.script = script
        self.dbPath = dbPath
        self.ownerTokenPath = ownerTokenPath
        self.hubID = hubID
        self.tailnetIP = tailnetIP
        self.magicDNSName = magicDNSName
        self.parentPID = parentPID
    }

    /// The URL other machines are told to use: MagicDNS name, else the tailnet IP, else
    /// loopback (local-only developers).
    public static func publicURL(magicDNSName: String?, tailnetIP: String?, port: Int = LocalHub.port) -> String {
        if let name = magicDNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), !name.isEmpty {
            return "http://\(name):\(port)"
        }
        if let ip = tailnetIP, TailnetAddress.isTailnetIPv4(ip) { return "http://\(ip):\(port)" }
        return "http://127.0.0.1:\(port)"
    }

    public var publicURL: String { Self.publicURL(magicDNSName: magicDNSName, tailnetIP: tailnetIP, port: port) }

    /// Addresses to listen on: always loopback, plus the tailnet address when there is one.
    /// Never 0.0.0.0.
    public var bindAddresses: [String] {
        var binds = ["127.0.0.1"]
        if let ip = tailnetIP, TailnetAddress.isTailnetIPv4(ip) { binds.append(ip) }
        return binds
    }

    /// Arguments after the python executable.
    public var arguments: [String] {
        var args = ["-u", script]
        for b in bindAddresses { args += ["--bind", b] }
        args += [
            "--port", String(port),
            "--db", dbPath,
            "--hub-id", hubID,
            "--public-url", publicURL,
            "--owner-token-file", ownerTokenPath,
            "--parent-pid", String(parentPID),
        ]
        return args
    }

    /// Restart when the network identity changes (new tailnet IP or MagicDNS name).
    public func needsRestart(comparedTo other: LocalHubPlan) -> Bool {
        bindAddresses != other.bindAddresses || publicURL != other.publicURL
    }
}

// MARK: - Who can reach it

/// Settings → Built-in hub: the two addresses of the hub on this Mac, and whether other
/// machines can reach it.
public struct LocalHubReach: Equatable, Sendable {
    public enum Tailscale: Equatable, Sendable {
        /// On a tailnet: the hub also listens on the Tailscale address.
        case connected
        /// Tailscale is installed but this Mac has no tailnet address (signed out or off).
        case notConnected
        case notInstalled
        /// NEEDS_YOU_HUB_LOOPBACK_ONLY=1 (test copies).
        case loopbackOnly
    }

    /// For agents and scripts on this Mac.
    public var localURL: String
    /// For other machines, over Tailscale: the MagicDNS name, else the 100.x address.
    /// nil when the hub listens on 127.0.0.1 only.
    public var tailnetURL: String?
    public var tailscale: Tailscale

    public init(magicDNSName: String?, tailnetIP: String?, tailscaleInstalled: Bool,
                loopbackOnly: Bool = LocalHub.loopbackOnly, port: Int = LocalHub.port) {
        localURL = "http://127.0.0.1:\(port)"
        if loopbackOnly {
            tailnetURL = nil
            tailscale = .loopbackOnly
        } else if let ip = tailnetIP, TailnetAddress.isTailnetIPv4(ip) {
            // Only with a tailnet address: that's what the hub binds (LocalHubPlan.bindAddresses).
            tailnetURL = LocalHubPlan.publicURL(magicDNSName: magicDNSName, tailnetIP: ip, port: port)
            tailscale = .connected
        } else {
            tailnetURL = nil
            tailscale = tailscaleInstalled ? .notConnected : .notInstalled
        }
    }

    public init(plan: LocalHubPlan, tailscaleInstalled: Bool, loopbackOnly: Bool = LocalHub.loopbackOnly) {
        self.init(magicDNSName: plan.magicDNSName, tailnetIP: plan.tailnetIP, tailscaleInstalled: tailscaleInstalled,
                  loopbackOnly: loopbackOnly, port: plan.port)
    }

    /// Can servers and other Macs reach this hub?
    public var reachableFromOtherMachines: Bool { tailnetURL != nil }

    /// One or two plain sentences for Settings.
    public var note: String {
        switch tailscale {
        case .connected:
            return "Servers, agents and other Macs on your tailnet send alerts to this address. Invite links use it too."
        case .notConnected:
            return "Tailscale is installed, but this Mac isn't connected, so other machines can't reach this hub yet. Open Tailscale and sign in. The address shows here by itself."
        case .notInstalled:
            return "Tailscale wasn't found, so only agents on this Mac can reach this hub. To get alerts from servers or other Macs, install Tailscale on this Mac and on them."
        case .loopbackOnly:
            return "NEEDS_YOU_HUB_LOOPBACK_ONLY=1 is set, so the hub only listens on this Mac."
        }
    }

    /// The Tailscale setup guide in the repository (docs/guides/tailscale.md).
    public static let tailscaleGuideURL = URL(string: "https://github.com/\(UpdateSource.defaultRepository)/blob/main/docs/guides/tailscale.md")!
}

// MARK: - Python availability

public enum PythonProbe: Equatable, Sendable {
    case ok
    /// No developer directory: /usr/bin/python3 is only the stub that offers to install
    /// the Command Line Tools. Never run it (that would pop an installer dialog).
    case missingDeveloperTools
    case missing
    case broken(String)

    public static let installHint = "Install Apple's command line tools (`xcode-select --install`) or connect to a remote hub."

    public var message: String? {
        switch self {
        case .ok: return nil
        case .missingDeveloperTools, .missing: return "Python 3 isn't available on this Mac. " + Self.installHint
        case .broken(let detail): return "Python 3 can't run the hub (\(detail)). " + Self.installHint
        }
    }

    /// Classify the two probe steps: `xcode-select -p` exit status, then
    /// `python3 -c 'import sqlite3'` exit status (nil when not run) and its stderr.
    public static func classify(pythonExists: Bool, xcodeSelectStatus: Int32, importStatus: Int32?, stderr: String = "") -> PythonProbe {
        guard pythonExists else { return .missing }
        guard xcodeSelectStatus == 0 else { return .missingDeveloperTools }
        guard let importStatus else { return .missingDeveloperTools }
        if importStatus == 0 { return .ok }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(importStatus)"
        return .broken(line)
    }
}

// MARK: - Owner token

public enum OwnerToken {
    /// 32 random bytes, base64url without padding.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)   // CSPRNG on Darwin
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Read the token file, or create it (mode 600) with `fallback` or a fresh token.
    public static func loadOrCreate(at url: URL, fallback: String? = nil) throws -> String {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return s
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let token = (fallback?.isEmpty == false ? fallback! : generate())
        guard fm.createFile(atPath: url.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}
