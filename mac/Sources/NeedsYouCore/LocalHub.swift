import Darwin
import Foundation

// The hub that runs inside the app (`Resources/hub/needs_you_hub.py` as a child process).
// This file holds the pure parts: address detection, the public URL choice, and the
// command line. Process management lives in the app (LocalHubController).

public enum LocalHub {
    public static let port = 8765
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

    /// Keys for "this is the local hub" checks (the app's own URL, plus localhost).
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "127.0.0.1" || host == "localhost" || host == "::1") && (url.port ?? 80) == port
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
