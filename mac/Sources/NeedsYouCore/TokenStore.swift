import Darwin
import Foundation

/// Where the app keeps its files: `~/Library/Application Support/NeedsYou`, or
/// `NEEDS_YOU_SUPPORT_DIR` (tests and trial runs keep everything out of the real profile).
public enum SupportPaths {
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["NEEDS_YOU_SUPPORT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NeedsYou", isDirectory: true)
    }

    public static var tokensURL: URL { directory().appendingPathComponent(FileTokenStore.fileName) }
}

/// One stored credential: the token for a hub, and its role when known (from an invite
/// redeem; a hand-entered token's role is unknown).
public struct StoredToken: Codable, Equatable, Sendable {
    public var token: String
    public var role: HubRole?

    public init(token: String, role: HubRole? = nil) {
        self.token = token
        self.role = role
    }

    enum CodingKeys: String, CodingKey { case token, role }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        // An unknown role (from a newer build) reads as "unknown", not as a corrupt file.
        if let raw = try? c.decodeIfPresent(String.self, forKey: .role) { role = HubRole(rawValue: raw) } else { role = nil }
    }
}

/// Hub tokens in `tokens.json` (no Keychain: on a managed Mac whose login keychain password
/// is out of sync, every Keychain access prompts, and ad-hoc builds re-prompt after each
/// update).
///
/// - The directory is mode 700 and the file mode 600 (tightened on every write).
/// - Writes are atomic: a mode-600 temp file in the same directory, fsync, then rename(2).
/// - Keyed by `HubName.key(url)`. The local hub's owner token is not in here; it stays in
///   `owner.token`, which the hub itself reads.
/// - A file that doesn't parse is moved aside to `tokens.json.corrupt-<time>` (mode 600)
///   and reads as empty, so the app keeps working and nothing is silently lost.
/// - Unknown top-level and per-hub fields from a newer build are not preserved on write;
///   `version` lets a newer build migrate forward.
public final class FileTokenStore: @unchecked Sendable {
    public static let fileName = "tokens.json"
    public static let formatVersion = 1

    public let url: URL
    private let lock = NSLock()
    private var cache: [String: StoredToken]?

    public init(url: URL) {
        self.url = url
    }

    /// The store in the app's support directory.
    public static func standard() -> FileTokenStore { FileTokenStore(url: SupportPaths.tokensURL) }

    private struct FileFormat: Codable {
        var version: Int
        var hubs: [String: StoredToken]
    }

    public enum StoreError: Error, LocalizedError {
        case write(String)
        public var errorDescription: String? {
            switch self { case .write(let detail): return "Couldn't write tokens.json: \(detail)" }
        }
    }

    // MARK: Reading

    /// Everything stored, keyed by hub key. Cached after the first read (this process is
    /// the only writer); `reload()` drops the cache.
    public func all() -> [String: StoredToken] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public func reload() {
        lock.lock(); cache = nil; lock.unlock()
    }

    public func entry(for hub: URL) -> StoredToken? { all()[HubName.key(hub)] }
    public func token(for hub: URL) -> String? { entry(for: hub).map(\.token).flatMap { $0.isEmpty ? nil : $0 } }
    public func role(for hub: URL) -> HubRole? { entry(for: hub)?.role }

    private func loadLocked() -> [String: StoredToken] {
        if let cache { return cache }
        let loaded = Self.read(url)
        cache = loaded
        return loaded
    }

    /// Parse the file. Missing → empty. Unparseable → moved aside and empty.
    static func read(_ url: URL) -> [String: StoredToken] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return [:] }
        if let file = try? JSONDecoder().decode(FileFormat.self, from: data) {
            return file.hubs.filter { !$0.value.token.isEmpty }
        }
        backUpCorrupt(url)
        return [:]
    }

    /// Rename a bad file to `tokens.json.corrupt-YYYYMMDD-HHMMSS[-n]`, mode 600.
    @discardableResult
    static func backUpCorrupt(_ url: URL, now: Date = Date()) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.lastPathComponent + ".corrupt-" + f.string(from: now)
        let dir = url.deletingLastPathComponent()
        var backup = dir.appendingPathComponent(stem)
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = dir.appendingPathComponent("\(stem)-\(n)")
        }
        guard rename(url.path, backup.path) == 0 else { return nil }
        chmod(backup.path, 0o600)
        return backup
    }

    // MARK: Writing

    /// Store (or replace) the token and role for a hub. An empty token removes it.
    public func set(_ token: String, role: HubRole?, for hub: URL) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutate { all in
            if trimmed.isEmpty { all[HubName.key(hub)] = nil } else { all[HubName.key(hub)] = StoredToken(token: trimmed, role: role) }
        }
    }

    /// Change only the role of an existing entry.
    public func setRole(_ role: HubRole?, for hub: URL) throws {
        try mutate { all in all[HubName.key(hub)]?.role = role }
    }

    public func remove(_ hub: URL) throws {
        try mutate { all in all[HubName.key(hub)] = nil }
    }

    /// Forget hubs that are no longer configured.
    public func prune(keeping hubs: [URL]) throws {
        let keep = Set(hubs.map(HubName.key))
        try mutate { all in all = all.filter { keep.contains($0.key) } }
    }

    private func mutate(_ change: (inout [String: StoredToken]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        let before = all
        change(&all)
        guard all != before else { return }
        try Self.writeAtomically(FileFormat(version: Self.formatVersion, hubs: all), to: url)
        cache = all
    }

    /// Create the directory (700), write a 600 temp file, fsync, rename over the target.
    private static func writeAtomically(_ file: FileFormat, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(file) } catch { throw StoreError.write("encode: \(error.localizedDescription)") }
        try writeAtomically(data + Data("\n".utf8), to: url)
    }

    /// Atomic, private write of raw bytes (also used by tests).
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.write("create \(dir.path): \(error.localizedDescription)")
        }
        chmod(dir.path, 0o700)

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.write("open temp file: \(String(cString: strerror(errno)))") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n <= 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        fchmod(fd, 0o600)   // umask can't widen it, but be explicit
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced else { throw StoreError.write("write temp file: \(String(cString: strerror(errno)))") }
        guard rename(tmp.path, url.path) == 0 else { throw StoreError.write("rename: \(String(cString: strerror(errno)))") }
        ok = true
    }
}
