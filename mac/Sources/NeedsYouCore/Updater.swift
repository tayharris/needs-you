import CryptoKit
import Foundation

// The Mac app's self-update, pure parts (docs/roadmap/rollout-updates.md). The app's
// UpdateController does the I/O; everything that decides lives here and is tested.
//
// The gate: a release is installed only when it is published (not a draft, not a
// prerelease unless that channel is chosen), newer than this build, carries the
// `release-manifest.json` the release job writes after the tests pass, its app zip matches
// both the manifest and SHA256SUMS, the release run concluded `success` (when Actions is
// readable), this Mac meets `min_macos`, the soak time since publishing has passed, and the
// user hasn't skipped (or rolled back from) that version.

// MARK: - Versions

/// X.Y.Z, the format the VERSION file enforces. A leading "v" (tags) is accepted.
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        self.init(nums[0], nums[1], nums[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// "14.0" or "14" or "14.2.1" as an OS version (for `min_macos`).
    public static func osVersion(_ raw: String) -> OperatingSystemVersion? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.map { $0! }
        return OperatingSystemVersion(majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0,
                                      patchVersion: n.count > 2 ? n[2] : 0)
    }

    public static func atLeast(_ have: OperatingSystemVersion, _ need: OperatingSystemVersion) -> Bool {
        (have.majorVersion, have.minorVersion, have.patchVersion)
            >= (need.majorVersion, need.minorVersion, need.patchVersion)
    }
}

// MARK: - Wire shapes (GitHub's release and Actions run JSON, the release manifest)

public struct ReleaseAsset: Decodable, Equatable, Sendable {
    /// GitHub's asset id (downloads go through /releases/assets/<id>). 0 for a local feed.
    public var id: Int
    public var name: String
    public var size: Int
    /// The API URL (`url`), used with `Accept: application/octet-stream`.
    public var apiURL: String?
    public var downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case apiURL = "url"
        case downloadURL = "browser_download_url"
    }

    public init(id: Int = 0, name: String, size: Int = 0, apiURL: String? = nil, downloadURL: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.apiURL = apiURL
        self.downloadURL = downloadURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? 0
        name = try c.decode(String.self, forKey: .name)
        size = (try? c.decodeIfPresent(Int.self, forKey: .size)) ?? 0
        apiURL = try? c.decodeIfPresent(String.self, forKey: .apiURL)
        downloadURL = try? c.decodeIfPresent(String.self, forKey: .downloadURL)
    }
}

public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public var tagName: String
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: Date?
    public var htmlURL: String?
    public var assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }

    public init(tagName: String, draft: Bool = false, prerelease: Bool = false, publishedAt: Date?,
                htmlURL: String? = nil, assets: [ReleaseAsset]) {
        self.tagName = tagName
        self.draft = draft
        self.prerelease = prerelease
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        draft = (try? c.decodeIfPresent(Bool.self, forKey: .draft)) ?? false
        prerelease = (try? c.decodeIfPresent(Bool.self, forKey: .prerelease)) ?? false
        let raw = (try? c.decodeIfPresent(String.self, forKey: .publishedAt)) ?? nil
        publishedAt = raw.flatMap(HubJSON.parseDate)
        htmlURL = try? c.decodeIfPresent(String.self, forKey: .htmlURL)
        assets = (try? c.decodeIfPresent([ReleaseAsset].self, forKey: .assets)) ?? []
    }

    public var version: SemVer? { SemVer(tagName) }

    public func asset(named name: String) -> ReleaseAsset? { assets.first { $0.name == name } }

    public static func decode(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// `GET /releases` (newest first): the newest usable release for a channel. Drafts never.
    public static func pick(_ releases: [ReleaseInfo], channel: UpdateChannel) -> ReleaseInfo? {
        releases
            .filter { !$0.draft && $0.version != nil && (channel == .prerelease || !$0.prerelease) }
            .max { ($0.version!, $0.publishedAt ?? .distantPast) < ($1.version!, $1.publishedAt ?? .distantPast) }
    }
}

public struct ReleaseManifest: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var sha256: String
        public var size: Int
        public init(name: String, sha256: String, size: Int) {
            self.name = name
            self.sha256 = sha256
            self.size = size
        }
    }

    public var version: String
    public var commit: String?
    public var runID: Int?
    public var tests: String?
    public var minMacOS: String?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case version, commit, tests, assets
        case runID = "run_id"
        case minMacOS = "min_macos"
    }

    public init(version: String, commit: String? = nil, runID: Int? = nil, tests: String? = "success",
                minMacOS: String? = "14.0", assets: [Asset]) {
        self.version = version
        self.commit = commit
        self.runID = runID
        self.tests = tests
        self.minMacOS = minMacOS
        self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        commit = try? c.decodeIfPresent(String.self, forKey: .commit)
        runID = (try? c.decodeIfPresent(Int.self, forKey: .runID)) ?? nil
        tests = try? c.decodeIfPresent(String.self, forKey: .tests)
        minMacOS = try? c.decodeIfPresent(String.self, forKey: .minMacOS)
        assets = try c.decode([Asset].self, forKey: .assets)
    }

    public static let fileName = "release-manifest.json"

    public static func decode(_ data: Data) throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }

    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
}

/// `GET /repos/{o}/{r}/actions/runs/{id}`.
public struct WorkflowRun: Decodable, Equatable, Sendable {
    public var id: Int
    public var headSHA: String
    public var status: String?
    public var conclusion: String?

    enum CodingKeys: String, CodingKey {
        case id, status, conclusion
        case headSHA = "head_sha"
    }

    public init(id: Int, headSHA: String, status: String? = "completed", conclusion: String?) {
        self.id = id
        self.headSHA = headSHA
        self.status = status
        self.conclusion = conclusion
    }
}

/// `sha256sum` / `shasum -a 256` output: "<64 hex>  <name>" (a `*` before the name in
/// binary mode). Unparseable lines are ignored.
public enum SHA256Sums {
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let digest = parts[0].lowercased()
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard Checksum.isHexDigest(digest), !name.isEmpty else { continue }
            out[name] = digest
        }
        return out
    }
}

public enum Checksum {
    public static func isHexDigest(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file, so a large zip isn't read into memory at once.
    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Policy and decision

public enum UpdateChannel: String, CaseIterable, Sendable {
    case stable, prerelease

    public var title: String {
        switch self {
        case .stable: return "Releases"
        case .prerelease: return "Releases and pre-releases"
        }
    }
}

public struct UpdatePolicy: Equatable, Sendable {
    public static let defaultSoak: TimeInterval = 2 * 3600
    public static let soakChoices: [TimeInterval] = [0, 3600, 2 * 3600, 6 * 3600, 24 * 3600]

    public var channel: UpdateChannel
    /// Install no earlier than published_at + soak.
    public var soak: TimeInterval
    /// Versions the user chose to skip.
    public var skipped: Set<String>
    /// The version install.sh rolled back from (Updates/rolled-back-version).
    public var rolledBack: String?

    public init(channel: UpdateChannel = .stable, soak: TimeInterval = UpdatePolicy.defaultSoak,
                skipped: Set<String> = [], rolledBack: String? = nil) {
        self.channel = channel
        self.soak = max(0, soak)
        self.skipped = skipped
        self.rolledBack = rolledBack
    }
}

/// The release's files the updater uses.
public struct UpdateCandidate: Equatable, Sendable {
    public var version: SemVer
    public var zip: ReleaseAsset
    public var sha256: String
    public var size: Int
    public var publishedAt: Date?
    public var releaseURL: String?

    public init(version: SemVer, zip: ReleaseAsset, sha256: String, size: Int, publishedAt: Date?, releaseURL: String? = nil) {
        self.version = version
        self.zip = zip
        self.sha256 = sha256
        self.size = size
        self.publishedAt = publishedAt
        self.releaseURL = releaseURL
    }
}

public enum UpdateDecision: Equatable, Sendable {
    /// Nothing newer.
    case upToDate
    /// Newer, but the user skipped it or it was rolled back.
    case skipped(SemVer, String)
    /// Newer, but it fails the gate; the reason is shown in Settings.
    case blocked(SemVer?, String)
    /// Passes the gate except the soak.
    case wait(UpdateCandidate, until: Date)
    case ready(UpdateCandidate)

    public var summary: String {
        switch self {
        case .upToDate: return "Up to date."
        case .skipped(let v, let why): return "\(v) is available (\(why))."
        case .blocked(let v, let why): return "\(v.map { "\($0): " } ?? "")\(why)"
        case .wait(let c, let until):
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "\(c.version) is available; it installs after \(f.string(from: until)) (soak time)."
        case .ready(let c): return "\(c.version) is ready to install."
        }
    }
}

public enum UpdateGate {
    public static func zipName(_ v: SemVer) -> String { "NeedsYou-\(v)-macos.zip" }
    public static let sumsName = "SHA256SUMS"

    /// Before downloading anything else: is the release newer, usable, and not skipped?
    /// Returns nil when the manifest and sums should be fetched next.
    public static func preflight(release: ReleaseInfo, current: SemVer, policy: UpdatePolicy) -> UpdateDecision? {
        guard let v = release.version else { return .blocked(nil, "The release tag \(release.tagName) isn't X.Y.Z.") }
        guard v > current else { return .upToDate }
        if release.draft { return .blocked(v, "It's still a draft.") }
        if release.prerelease, policy.channel != .prerelease { return .upToDate }
        if policy.skipped.contains(v.description) { return .skipped(v, "skipped") }
        if let rb = policy.rolledBack, SemVer(rb) == v { return .skipped(v, "rolled back on this Mac") }
        if release.asset(named: ReleaseManifest.fileName) == nil {
            return .blocked(v, "The release has no \(ReleaseManifest.fileName), so it wasn't built by the release workflow after the tests passed.")
        }
        if release.asset(named: zipName(v)) == nil { return .blocked(v, "The release has no \(zipName(v)).") }
        if release.asset(named: sumsName) == nil { return .blocked(v, "The release has no \(sumsName).") }
        return nil
    }

    /// The whole gate. `run` is the release workflow run named by the manifest, nil when
    /// Actions couldn't be read (anonymous, rate limited): then the manifest's existence and
    /// its `tests` field stand in, since only the release job, after `needs: test`, writes it.
    public static func evaluate(release: ReleaseInfo, manifest: ReleaseManifest, sums: [String: String],
                                run: WorkflowRun?, current: SemVer, os: OperatingSystemVersion,
                                now: Date, policy: UpdatePolicy) -> UpdateDecision {
        if let early = preflight(release: release, current: current, policy: policy) { return early }
        let v = release.version!
        guard SemVer(manifest.version) == v else {
            return .blocked(v, "The manifest says \(manifest.version), the tag says \(release.tagName).")
        }
        if let tests = manifest.tests, tests != "success" {
            return .blocked(v, "The manifest records the tests as \(tests).")
        }
        if let run {
            if manifest.runID != nil, run.id != manifest.runID {
                return .blocked(v, "The release run doesn't match the manifest.")
            }
            if run.conclusion != "success" {
                return .blocked(v, "Its release workflow run concluded \(run.conclusion ?? "nothing yet").")
            }
            if let commit = manifest.commit, !commit.isEmpty, run.headSHA != commit {
                return .blocked(v, "The release run built a different commit than the manifest names.")
            }
        }
        if let raw = manifest.minMacOS {
            guard let need = SemVer.osVersion(raw) else { return .blocked(v, "The manifest's min_macos (\(raw)) isn't a version.") }
            if !SemVer.atLeast(os, need) { return .blocked(v, "It needs macOS \(raw) or later.") }
        }
        let name = zipName(v)
        guard let zip = release.asset(named: name) else { return .blocked(v, "The release has no \(name).") }
        guard let entry = manifest.asset(named: name), Checksum.isHexDigest(entry.sha256) else {
            return .blocked(v, "The manifest doesn't list \(name).")
        }
        guard let sum = sums[name] else { return .blocked(v, "SHA256SUMS doesn't list \(name).") }
        guard sum == entry.sha256 else { return .blocked(v, "SHA256SUMS and the manifest disagree about \(name).") }
        if zip.size > 0, entry.size > 0, zip.size != entry.size {
            return .blocked(v, "The uploaded \(name) isn't the size the manifest records.")
        }
        let candidate = UpdateCandidate(version: v, zip: zip, sha256: entry.sha256, size: entry.size,
                                        publishedAt: release.publishedAt, releaseURL: release.htmlURL)
        let published = release.publishedAt ?? now
        let until = published.addingTimeInterval(policy.soak)
        if now < until { return .wait(candidate, until: until) }
        return .ready(candidate)
    }

    /// The downloaded zip, before it is unpacked.
    public static func verifyDownload(sha256: String, size: Int, candidate: UpdateCandidate) -> String? {
        if candidate.size > 0, size != candidate.size {
            return "The download is \(size) bytes; the manifest says \(candidate.size)."
        }
        if sha256.lowercased() != candidate.sha256 { return "The download's SHA-256 doesn't match the release's." }
        return nil
    }

    /// The unpacked app's Info.plist: same bundle id, the version the tag promised, and
    /// newer than the running app (a downgrade is only ever install.sh --rollback).
    public static func verifyBundle(info: [String: Any], expectedID: String, version: SemVer, newerThan current: SemVer? = nil) -> String? {
        guard let id = info["CFBundleIdentifier"] as? String, id == expectedID else {
            return "The downloaded app's bundle id isn't \(expectedID)."
        }
        guard let raw = info["CFBundleShortVersionString"] as? String, SemVer(raw) == version else {
            return "The downloaded app's version isn't \(version)."
        }
        if let current, !(version > current) { return "\(version) isn't newer than this app (\(current))." }
        return nil
    }
}

// MARK: - Authenticity beyond the checksums

/// The checksums prove the zip is the one the release lists, not who made the release.
/// These add what's possible without a Developer ID: the signing team must stay the same,
/// symlinks can't leave the bundle, and, once the owner pins a key, an Ed25519 signature
/// over release-manifest.json (CryptoKit, in the OS) is required.
public enum UpdateAuthenticity {
    /// TODO(owner): pin the base64 raw Ed25519 public key (32 bytes) here once the release
    /// signing key exists. The private key lives only in the owner's keychain and in the
    /// `RELEASE_MANIFEST_SIGNING_KEY` Actions secret; the exact steps are in
    /// docs/security/release-signing.md. Never commit it. While this is nil, signatures
    /// aren't checked.
    public static let pinnedManifestKey: String? = nil
    public static let signatureSuffix = ".sig"
    public static var signatureName: String { ReleaseManifest.fileName + signatureSuffix }

    /// nil when acceptable. With a key configured, a missing or bad signature is refused.
    /// The signature asset is the base64 of the 64-byte signature over the manifest bytes.
    public static func verifyManifest(_ manifest: Data, signature: Data?, publicKey: String?) -> String? {
        guard let publicKey else { return nil }
        guard let keyData = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return "The app's pinned release key is malformed."
        }
        guard let signature else { return "The release has no \(signatureName), and this app requires signed releases." }
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text), sig.count == 64 else { return "\(signatureName) isn't a signature." }
        return key.isValidSignature(sig, for: manifest) ? nil : "\(signatureName) doesn't verify against the pinned release key."
    }

    /// `codesign -dv` prints "TeamIdentifier=ABCDE12345", or "TeamIdentifier=not set" when
    /// ad-hoc signed.
    public static func teamID(codesignOutput: String) -> String? {
        for line in codesignOutput.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let v = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == "not set" ? nil : v
        }
        return nil
    }

    /// An app signed by a team only accepts updates from that team. An ad-hoc app (today's
    /// builds) has no stable identity to compare (its designated requirement is its own
    /// cdhash), so any validly sealed build passes here and the checksums are the gate.
    public static func checkSigner(runningTeam: String?, stagedTeam: String?) -> String? {
        guard let runningTeam else { return nil }
        return stagedTeam == runningTeam ? nil : "The update is signed by \(stagedTeam ?? "no team (ad-hoc)"), this app by \(runningTeam)."
    }

    /// A symlink inside the bundle (at `directory`, components relative to the bundle root)
    /// pointing at `destination`: true when it resolves outside the bundle.
    public static func linkEscapes(destination: String, directory: [String]) -> Bool {
        if destination.hasPrefix("/") { return true }
        var stack = directory
        for part in destination.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return true }
                stack.removeLast()
            } else {
                stack.append(String(part))
            }
        }
        return false
    }
}

// MARK: - When to install

/// Installing quits and relaunches the app, so it waits for a quiet moment.
public enum InstallWindow {
    public static let idleNeeded: TimeInterval = 10 * 60
    public static let quietAfterArrival: TimeInterval = 2 * 60

    /// Automatic installs only. A click on "Restart to update" installs at once.
    public static func canInstall(panelExpanded: Bool, hovering: Bool, lastArrival: Date?,
                                  idleSeconds: TimeInterval, now: Date) -> Bool {
        if panelExpanded || hovering { return false }
        if let lastArrival, now.timeIntervalSince(lastArrival) < quietAfterArrival { return false }
        return idleSeconds >= idleNeeded
    }
}

/// How often to check: 2 minutes after launch, then every 6 hours.
public enum UpdateSchedule {
    public static let firstCheckDelay: TimeInterval = 120
    public static let interval: TimeInterval = 6 * 3600

    public static func nextCheck(lastCheck: Date?, launchedAt: Date, now: Date) -> Date {
        let first = launchedAt.addingTimeInterval(firstCheckDelay)
        guard let lastCheck else { return max(first, now) }
        return max(first, lastCheck.addingTimeInterval(interval))
    }
}

// MARK: - Where releases come from, and the credential for a private repo

/// GitHub while the repo is private needs a token. The chain: `gh auth token` from a fixed
/// path, then a fine-grained token in `github.token` (mode 600) in the support directory,
/// else anonymous. The token is held in memory, sent only to api.github.com, and never
/// logged or shown (only which source it came from).
public enum UpdateAuth: Equatable, Sendable, CustomStringConvertible {
    case anonymous
    case gh(token: String)
    case tokenFile(token: String)

    public static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    public static let tokenFileName = "github.token"

    public var token: String? {
        switch self {
        case .anonymous: return nil
        case .gh(let t), .tokenFile(let t): return t
        }
    }

    /// What Settings shows. Never the token.
    public var description: String {
        switch self {
        case .anonymous: return "anonymous (public repo)"
        case .gh: return "GitHub CLI (gh auth token)"
        case .tokenFile: return "token file (\(UpdateAuth.tokenFileName))"
        }
    }

    /// A GitHub token is one line of [A-Za-z0-9_] (ghp_…, gho_…, github_pat_…). Anything
    /// else (a prompt, an error, a second line) is not used.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...255).contains(t.count),
              t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" })
        else { return nil }
        return t
    }

    public static func choose(ghToken: String?, fileToken: String?) -> UpdateAuth {
        if let t = sanitize(ghToken) { return .gh(token: t) }
        if let t = sanitize(fileToken) { return .tokenFile(token: t) }
        return .anonymous
    }

    /// A token file is used only when other users can't read it.
    public static func fileModeIsPrivate(_ mode: Int) -> Bool { mode & 0o077 == 0 }
}

public struct UpdateSource: Equatable, Sendable {
    /// Fixed in code: never taken from a setting, a manifest or a release.
    public static let defaultRepository = "tayharris/needs-you"

    /// "owner/repo" on GitHub, or a local feed directory (a build-release.sh output dir, or
    /// one made by mac/scripts/make-test-feed.sh) for testing without a real release.
    public enum Kind: Equatable, Sendable {
        case github(String)
        case localFeed(URL)
    }

    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }

    /// The `updateFeedURL` default or NEEDS_YOU_UPDATE_FEED picks a local test feed: a file://
    /// URL or an absolute path, nothing else (an http(s) value is ignored). A test feed is
    /// shown as such in Settings and never installs automatically.
    public static func resolve(feed: String?) -> UpdateSource {
        if let feed = feed?.trimmingCharacters(in: .whitespaces), !feed.isEmpty {
            if let url = URL(string: feed), url.isFileURL { return UpdateSource(kind: .localFeed(url)) }
            if feed.hasPrefix("/") || feed.hasPrefix("~") {
                return UpdateSource(kind: .localFeed(URL(fileURLWithPath: (feed as NSString).expandingTildeInPath, isDirectory: true)))
            }
        }
        return UpdateSource(kind: .github(defaultRepository))
    }

    public var isTestFeed: Bool {
        if case .localFeed = kind { return true }
        return false
    }

    public static let apiHost = "api.github.com"

    public func latestURL(channel: UpdateChannel) -> URL? {
        guard case .github(let repo) = kind else { return nil }
        return channel == .stable
            ? URL(string: "https://\(Self.apiHost)/repos/\(repo)/releases/latest")
            : URL(string: "https://\(Self.apiHost)/repos/\(repo)/releases?per_page=10")
    }

    public func runURL(id: Int) -> URL? {
        guard case .github(let repo) = kind else { return nil }
        return URL(string: "https://\(Self.apiHost)/repos/\(repo)/actions/runs/\(id)")
    }

    /// The API asset URL for a GitHub release (downloaded with Accept: octet-stream), or the
    /// file in a local feed.
    public func assetURL(_ asset: ReleaseAsset) -> URL? {
        switch kind {
        case .github(let repo):
            // Built from the asset id under this repo only: an `url` naming another repo or
            // host is never followed.
            return asset.id > 0 ? URL(string: "https://\(Self.apiHost)/repos/\(repo)/releases/assets/\(asset.id)") : nil
        case .localFeed(let dir):
            guard !asset.name.contains("/"), !asset.name.hasPrefix(".") else { return nil }
            return dir.appendingPathComponent(asset.name)
        }
    }

    /// Only GitHub's API host ever gets the token; a redirect elsewhere (the asset CDN) must
    /// drop it.
    public static func mayCarryToken(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host?.lowercased() == apiHost
    }

    /// Where a GitHub download may go, redirects included: https to GitHub's API and its
    /// release-asset CDN only. Anything else is refused.
    public static let downloadHosts: Set<String> = [
        "api.github.com", "github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com",
    ]

    public static func mayDownload(from url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return downloadHosts.contains(host) && url.user == nil && url.password == nil
    }

    /// A local feed has no GitHub release JSON: one is made from its manifest (published at
    /// the manifest's `built_at`, or `now`), listing the files the directory has.
    public static func localRelease(manifestData: Data, files: [String: Int], now: Date) -> ReleaseInfo? {
        guard let manifest = try? ReleaseManifest.decode(manifestData),
              let v = SemVer(manifest.version) else { return nil }
        let built = (try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any])?["built_at"] as? String
        let assets = files.keys.sorted().map { ReleaseAsset(name: $0, size: files[$0] ?? 0) }
        return ReleaseInfo(tagName: "v\(v)", publishedAt: built.flatMap(HubJSON.parseDate) ?? now, assets: assets)
    }
}

/// What the updater keeps in ~/Library/Application Support/NeedsYou/Updates.
public enum UpdatePaths {
    public static func directory(support: URL) -> URL { support.appendingPathComponent("Updates", isDirectory: true) }
    public static let rolledBackFile = "rolled-back-version"
    public static let installLog = "install.log"
    public static let attemptFile = "installing-version"
}

// MARK: - Settings → Updates

/// The updater's settings, plain keys in the app's defaults (`defaults read
/// app.needsyou.mac`). Missing or invalid values fall back to the defaults.
public struct UpdatePrefs: Equatable, Sendable {
    public enum Key {
        public static let check = "updateCheckAutomatically"
        public static let install = "updateInstallAutomatically"
        public static let channel = "updateChannel"
        public static let soakHours = "updateSoakHours"
        public static let skipped = "updateSkippedVersions"
        public static let lastCheck = "updateLastCheck"
        /// Testing: a local feed directory (file:// URL or path) instead of GitHub.
        public static let feedURL = "updateFeedURL"
    }

    public var checkAutomatically = true
    public var installAutomatically = true
    public var channel: UpdateChannel = .stable
    public var soakHours: Double = UpdatePolicy.defaultSoak / 3600
    public var skipped: [String] = []
    public var lastCheck: Date?

    public init() {}

    public static func load(from d: UserDefaults) -> UpdatePrefs {
        var p = UpdatePrefs()
        if d.object(forKey: Key.check) != nil { p.checkAutomatically = d.bool(forKey: Key.check) }
        if d.object(forKey: Key.install) != nil { p.installAutomatically = d.bool(forKey: Key.install) }
        if let raw = d.string(forKey: Key.channel), let c = UpdateChannel(rawValue: raw) { p.channel = c }
        if let n = d.object(forKey: Key.soakHours) as? NSNumber, n.doubleValue >= 0, n.doubleValue <= 24 * 30 {
            p.soakHours = n.doubleValue
        }
        p.skipped = (d.stringArray(forKey: Key.skipped) ?? []).filter { SemVer($0) != nil }
        p.lastCheck = d.object(forKey: Key.lastCheck) as? Date
        return p
    }

    public func save(to d: UserDefaults) {
        d.set(checkAutomatically, forKey: Key.check)
        d.set(installAutomatically, forKey: Key.install)
        d.set(channel.rawValue, forKey: Key.channel)
        d.set(soakHours, forKey: Key.soakHours)
        d.set(skipped, forKey: Key.skipped)
        if let lastCheck { d.set(lastCheck, forKey: Key.lastCheck) } else { d.removeObject(forKey: Key.lastCheck) }
    }

    public func policy(rolledBack: String?) -> UpdatePolicy {
        UpdatePolicy(channel: channel, soak: soakHours * 3600, skipped: Set(skipped), rolledBack: rolledBack)
    }

    public mutating func skip(_ v: SemVer) {
        if !skipped.contains(v.description) { skipped.append(v.description) }
        if skipped.count > 20 { skipped.removeFirst(skipped.count - 20) }
    }
}
