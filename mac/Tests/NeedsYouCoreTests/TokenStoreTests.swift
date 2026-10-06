#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// tokens.json: the file-based replacement for the Keychain. Everything runs in a temp dir.
final class TokenStoreTests: XCTestCase {
    static var allTests = [
        ("testRoundTripAcrossInstances", testRoundTripAcrossInstances),
        ("testPermissionsAreTightened", testPermissionsAreTightened),
        ("testAtomicWriteLeavesNoTempFilesAndKeepsOldFileOnFailure", testAtomicWriteLeavesNoTempFilesAndKeepsOldFileOnFailure),
        ("testCorruptFileReadsEmptyAndIsBackedUp", testCorruptFileReadsEmptyAndIsBackedUp),
        ("testUnknownRoleAndEmptyTokens", testUnknownRoleAndEmptyTokens),
        ("testPruneAndRemove", testPruneAndRemove),
        ("testSupportDirectoryOverride", testSupportDirectoryOverride),
    ]

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("NeedsYou/tokens.json") }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("needsyou-tokens-\(UUID().uuidString)")
    }

    override func tearDown() {
        // Undo the immutable flag from the failure test before removing.
        chflags(dir.appendingPathComponent("NeedsYou").path, 0)
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    func testRoundTripAcrossInstances() throws {
        let hub = URL(string: "http://Hub1.example.ts.net:8765/")!
        let store = FileTokenStore(url: file)
        XCTAssertNil(store.token(for: hub))
        try store.set("  tok-1\n", role: .owner, for: hub)
        try store.set("tok-2", role: nil, for: URL(string: "https://hub2.example.com")!)

        let again = FileTokenStore(url: file)
        // Same hub, spelled differently (HubName.key: lowercased host, no trailing slash).
        XCTAssertEqual(again.token(for: URL(string: "http://hub1.example.ts.net:8765")!), "tok-1")
        XCTAssertEqual(again.role(for: hub), .owner)
        XCTAssertEqual(again.token(for: URL(string: "https://hub2.example.com/")!), "tok-2")
        XCTAssertNil(again.role(for: URL(string: "https://hub2.example.com")!))
        XCTAssertEqual(again.all().count, 2)

        // The format other tools (and a later build) can read.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, FileTokenStore.formatVersion)
        let hubs = try XCTUnwrap(json["hubs"] as? [String: [String: String]])
        XCTAssertEqual(hubs["http://hub1.example.ts.net:8765"]?["token"], "tok-1")
        XCTAssertEqual(hubs["http://hub1.example.ts.net:8765"]?["role"], "owner")
    }

    func testPermissionsAreTightened() throws {
        // A pre-existing, too-open directory and a permissive umask.
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let old = umask(0o022)
        defer { umask(old) }
        try FileTokenStore(url: file).set("t", role: .reader, for: URL(string: "http://h.ts.net:8765")!)
        XCTAssertEqual(mode(parent), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        // Still 600 after a rewrite.
        try FileTokenStore(url: file).set("t2", role: .reader, for: URL(string: "http://h.ts.net:8765")!)
        XCTAssertEqual(mode(file), 0o600)
    }

    func testAtomicWriteLeavesNoTempFilesAndKeepsOldFileOnFailure() throws {
        let store = FileTokenStore(url: file)
        let hub = URL(string: "http://h.ts.net:8765")!
        for i in 0..<5 { try store.set("tok-\(i)", role: nil, for: hub) }
        let parent = file.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["tokens.json"])
        let before = try Data(contentsOf: file)

        // A directory the store can't create files in (user-immutable, so the store's own
        // chmod can't undo it): the write fails, the old file stays.
        XCTAssertEqual(chflags(parent.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(parent.path, 0) }
        var threw = false
        do { try store.set("new", role: nil, for: URL(string: "http://other.ts.net:8765")!) } catch { threw = true }
        XCTAssertTrue(threw)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(FileTokenStore(url: file).token(for: hub), "tok-4")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["tokens.json"])
    }

    func testCorruptFileReadsEmptyAndIsBackedUp() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let garbage = Data("{\"version\":1,\"hubs\":{\"http://h\":".utf8)
        try garbage.write(to: file)

        let store = FileTokenStore(url: file)
        XCTAssertEqual(store.all(), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix("tokens.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        let backup = parent.appendingPathComponent(backups[0])
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
        XCTAssertEqual(mode(backup), 0o600)

        // The app keeps working: the next save writes a fresh file next to the backup.
        try store.set("fresh", role: .owner, for: URL(string: "http://h.ts.net:8765")!)
        XCTAssertEqual(FileTokenStore(url: file).token(for: URL(string: "http://h.ts.net:8765")!), "fresh")

        // A second corrupt file gets its own backup name.
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(FileTokenStore(url: file).all(), [:])
        let after = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix("tokens.json.corrupt-") }
        XCTAssertEqual(after.count, 2)
    }

    func testUnknownRoleAndEmptyTokens() throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let json = """
        {"version": 2, "hubs": {"http://a.ts.net:8765": {"token": "ta", "role": "superuser", "extra": 1},
                                "http://b.ts.net:8765": {"token": ""}}}
        """
        try Data(json.utf8).write(to: file)
        let store = FileTokenStore(url: file)
        XCTAssertEqual(store.token(for: URL(string: "http://a.ts.net:8765")!), "ta")
        XCTAssertNil(store.role(for: URL(string: "http://a.ts.net:8765")!))
        XCTAssertNil(store.token(for: URL(string: "http://b.ts.net:8765")!))
        // An empty token removes the entry.
        try store.set("  ", role: .owner, for: URL(string: "http://a.ts.net:8765")!)
        XCTAssertNil(FileTokenStore(url: file).token(for: URL(string: "http://a.ts.net:8765")!))
    }

    func testPruneAndRemove() throws {
        let store = FileTokenStore(url: file)
        let a = URL(string: "http://a.ts.net:8765")!, b = URL(string: "http://b.ts.net:8765")!, c = URL(string: "https://c.example.com")!
        for u in [a, b, c] { try store.set("t-\(u.host!)", role: .reader, for: u) }
        try store.prune(keeping: [a, c])
        XCTAssertNil(store.token(for: b))
        try store.remove(c)
        try store.setRole(.owner, for: a)
        let again = FileTokenStore(url: file)
        XCTAssertEqual(Array(again.all().keys), ["http://a.ts.net:8765"])
        XCTAssertEqual(again.role(for: a), .owner)
    }

    func testSupportDirectoryOverride() {
        XCTAssertEqual(SupportPaths.directory(environment: ["NEEDS_YOU_SUPPORT_DIR": "/tmp/x"]).path, "/tmp/x")
        XCTAssertTrue(SupportPaths.directory(environment: [:]).path.hasSuffix("Library/Application Support/NeedsYou"))
    }
}
