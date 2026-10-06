#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class LocalHubTests: XCTestCase {
    static var allTests = [
        ("testTailnetAddressDetection", testTailnetAddressDetection),
        ("testPublicURLFallbackOrder", testPublicURLFallbackOrder),
        ("testCommandLine", testCommandLine),
        ("testCommandLineWithoutTailnet", testCommandLineWithoutTailnet),
        ("testRestartOnlyWhenNetworkIdentityChanges", testRestartOnlyWhenNetworkIdentityChanges),
        ("testHubIDAndLocalURL", testHubIDAndLocalURL),
        ("testTailscaleStatusParsing", testTailscaleStatusParsing),
        ("testPythonProbeClassification", testPythonProbeClassification),
        ("testOwnerTokenFile", testOwnerTokenFile),
    ]

    func testTailnetAddressDetection() {
        XCTAssertTrue(TailnetAddress.isTailnetIPv4("100.64.0.1"))
        XCTAssertTrue(TailnetAddress.isTailnetIPv4("100.127.255.254"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("100.63.255.255"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("100.128.0.1"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("10.0.0.5"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("100.64.0"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("100.64.0.1.2"))
        XCTAssertFalse(TailnetAddress.isTailnetIPv4("fd7a:115c:a1e0::1"))
        XCTAssertEqual(TailnetAddress.pick(from: ["127.0.0.1", "192.168.1.20", "100.101.102.103", "100.70.0.1"]), "100.101.102.103")
        XCTAssertNil(TailnetAddress.pick(from: ["127.0.0.1", "192.168.1.20"]))
        XCTAssertNil(TailnetAddress.pick(from: []))
        // The live probe returns something sane (loopback at least) without crashing.
        XCTAssertTrue(TailnetAddress.interfaceIPv4Addresses().contains("127.0.0.1"))
    }

    func testPublicURLFallbackOrder() {
        XCTAssertEqual(LocalHubPlan.publicURL(magicDNSName: "mac.tail1.ts.net.", tailnetIP: "100.64.0.9"), "http://mac.tail1.ts.net:8765")
        XCTAssertEqual(LocalHubPlan.publicURL(magicDNSName: nil, tailnetIP: "100.64.0.9"), "http://100.64.0.9:8765")
        XCTAssertEqual(LocalHubPlan.publicURL(magicDNSName: "", tailnetIP: "100.64.0.9"), "http://100.64.0.9:8765")
        XCTAssertEqual(LocalHubPlan.publicURL(magicDNSName: nil, tailnetIP: "192.168.1.2"), "http://127.0.0.1:8765")
        XCTAssertEqual(LocalHubPlan.publicURL(magicDNSName: nil, tailnetIP: nil), "http://127.0.0.1:8765")
    }

    private func plan(ip: String? = "100.64.0.9", dns: String? = "mac.tail1.ts.net") -> LocalHubPlan {
        LocalHubPlan(script: "/App/Contents/Resources/hub/needs_you_hub.py",
                     dbPath: "/Users/u/Library/Application Support/NeedsYou/hub.db",
                     ownerTokenPath: "/Users/u/Library/Application Support/NeedsYou/owner.token",
                     hubID: "devbox", tailnetIP: ip, magicDNSName: dns, parentPID: 4242)
    }

    func testCommandLine() {
        let p = plan()
        XCTAssertEqual(p.python, "/usr/bin/python3")
        XCTAssertEqual(p.arguments, [
            "-u", "/App/Contents/Resources/hub/needs_you_hub.py",
            "--bind", "127.0.0.1", "--bind", "100.64.0.9",
            "--port", "8765",
            "--db", "/Users/u/Library/Application Support/NeedsYou/hub.db",
            "--hub-id", "devbox",
            "--public-url", "http://mac.tail1.ts.net:8765",
            "--owner-token-file", "/Users/u/Library/Application Support/NeedsYou/owner.token",
            "--parent-pid", "4242",
        ])
        XCTAssertFalse(p.arguments.contains("0.0.0.0"))
    }

    func testCommandLineWithoutTailnet() {
        let p = plan(ip: nil, dns: nil)
        XCTAssertEqual(p.bindAddresses, ["127.0.0.1"])
        XCTAssertEqual(p.publicURL, "http://127.0.0.1:8765")
        // A non-tailnet address is never bound.
        XCTAssertEqual(plan(ip: "192.168.1.5", dns: nil).bindAddresses, ["127.0.0.1"])
    }

    func testRestartOnlyWhenNetworkIdentityChanges() {
        XCTAssertFalse(plan().needsRestart(comparedTo: plan()))
        XCTAssertTrue(plan(ip: "100.64.0.10").needsRestart(comparedTo: plan()))
        XCTAssertTrue(plan(dns: nil).needsRestart(comparedTo: plan()))
        XCTAssertTrue(plan(ip: nil, dns: nil).needsRestart(comparedTo: plan()))
    }

    func testHubIDAndLocalURL() {
        XCTAssertEqual(LocalHub.hubID(fromHostName: "Sams-MacBook-Pro.local"), "sams-macbook-pro")
        XCTAssertEqual(LocalHub.hubID(fromHostName: "Sam's Mac"), "sam-s-mac")
        XCTAssertEqual(LocalHub.hubID(fromHostName: ""), "mac")
        XCTAssertTrue(LocalHub.isLocal(URL(string: "http://127.0.0.1:8765")!))
        XCTAssertTrue(LocalHub.isLocal(URL(string: "http://localhost:8765/")!))
        XCTAssertFalse(LocalHub.isLocal(URL(string: "http://127.0.0.1:9")!))
        XCTAssertFalse(LocalHub.isLocal(URL(string: "http://hub.ts.net:8765")!))
    }

    func testTailscaleStatusParsing() {
        let json = #"{"Version":"1.76","Self":{"DNSName":"Devbox.example.ts.net.","TailscaleIPs":["100.64.0.9"]}}"#
        XCTAssertEqual(TailscaleStatus.magicDNSName(fromStatusJSON: Data(json.utf8)), "devbox.example.ts.net")
        XCTAssertNil(TailscaleStatus.magicDNSName(fromStatusJSON: Data(#"{"Self":{"DNSName":""}}"#.utf8)))
        XCTAssertNil(TailscaleStatus.magicDNSName(fromStatusJSON: Data("not json".utf8)))
        let paths = TailscaleStatus.candidatePaths(path: "/usr/bin:/opt/homebrew/bin:/custom/bin")
        XCTAssertEqual(paths.first, "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertTrue(paths.contains("/custom/bin/tailscale"))
        XCTAssertEqual(paths.filter { $0 == "/opt/homebrew/bin/tailscale" }.count, 1)
    }

    func testPythonProbeClassification() {
        XCTAssertEqual(PythonProbe.classify(pythonExists: false, xcodeSelectStatus: 0, importStatus: 0), .missing)
        XCTAssertEqual(PythonProbe.classify(pythonExists: true, xcodeSelectStatus: 2, importStatus: nil), .missingDeveloperTools)
        XCTAssertEqual(PythonProbe.classify(pythonExists: true, xcodeSelectStatus: 0, importStatus: 0), .ok)
        XCTAssertEqual(PythonProbe.classify(pythonExists: true, xcodeSelectStatus: 0, importStatus: 1, stderr: "Traceback\nImportError: no sqlite3"),
                       .broken("ImportError: no sqlite3"))
        XCTAssertNil(PythonProbe.ok.message)
        XCTAssertTrue(PythonProbe.missingDeveloperTools.message?.contains("xcode-select --install") ?? false)
    }

    func testOwnerTokenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("needsyou-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("owner.token")
        let first = try OwnerToken.loadOrCreate(at: file)
        XCTAssertTrue(first.count >= 40)
        XCTAssertFalse(first.contains("+") || first.contains("/") || first.contains("="))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        // Stable across runs; a Keychain fallback is only used when the file is missing.
        XCTAssertEqual(try OwnerToken.loadOrCreate(at: file, fallback: "other"), first)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try OwnerToken.loadOrCreate(at: file, fallback: "from-keychain"), "from-keychain")
        XCTAssertNotEqual(OwnerToken.generate(), OwnerToken.generate())
    }
}

final class PruningTests: XCTestCase {
    static var allTests = [
        ("testPlacementBookKeepsTenMostRecentLayouts", testPlacementBookKeepsTenMostRecentLayouts),
        ("testPlacementBookReadsLegacyFormat", testPlacementBookReadsLegacyFormat),
        ("testRoleStorageAndPruning", testRoleStorageAndPruning),
        ("testCardSnoozesArePruned", testCardSnoozesArePruned),
        ("testLocalCloseTombstonesExpireAfter24h", testLocalCloseTombstonesExpireAfter24h),
        ("testLocalCloseTombstonesAreCapped", testLocalCloseTombstonesAreCapped),
    ]

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testPlacementBookKeepsTenMostRecentLayouts() throws {
        var book = PlacementBook()
        for i in 0..<15 {
            book.set(PanelPlacement(corner: .topLeft, screenID: "s\(i)"), forLayout: "layout\(i)", now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(book.entries.count, 10)
        XCTAssertNil(book.placement(forLayout: "layout4"))
        XCTAssertNotNil(book.placement(forLayout: "layout5"))
        // Using an old layout protects it from the next eviction.
        book.touch("layout5", now: t0.addingTimeInterval(100))
        book.set(PanelPlacement(corner: .bottomRight, screenID: "x"), forLayout: "layout99", now: t0.addingTimeInterval(101))
        XCTAssertNotNil(book.placement(forLayout: "layout5"))
        XCTAssertNil(book.placement(forLayout: "layout6"))
        XCTAssertEqual(book.entries.count, 10)
        // Round trip through UserDefaults-sized data.
        let decoded = PlacementBook.decode(book.encoded())
        XCTAssertEqual(decoded, book)
        XCTAssertTrue(try XCTUnwrap(book.encoded()).count < 4096)
    }

    func testPlacementBookReadsLegacyFormat() throws {
        var legacy: [String: PanelPlacement] = [:]
        for i in 0..<12 { legacy["l\(i)"] = PanelPlacement(corner: .topRight, screenID: "s\(i)") }
        let data = try JSONEncoder().encode(legacy)
        let book = PlacementBook.decode(data, now: t0)
        XCTAssertEqual(book.entries.count, 10)
        XCTAssertEqual(PlacementBook.decode(nil).entries.count, 0)
        XCTAssertEqual(PlacementBook.decode(Data("junk".utf8)).entries.count, 0)
    }

    func testRoleStorageAndPruning() throws {
        let suite = "needsyou-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = URL(string: "http://Hub1.t.ts.net:8765/")!, b = URL(string: "http://hub2.t.ts.net:8765")!
        var book = HubRoleBook()
        book.set(.owner, for: a)
        book.set(.reader, for: b)
        defaults.set(book.plist, forKey: "hubRoles")

        let loaded = HubRoleBook(plist: defaults.dictionary(forKey: "hubRoles") as? [String: String])
        XCTAssertEqual(loaded.role(for: URL(string: "http://hub1.t.ts.net:8765")!), .owner)
        XCTAssertEqual(loaded.role(for: b), .reader)

        var pruned = loaded
        pruned.prune(keeping: [b])
        XCTAssertNil(pruned.role(for: a))
        XCTAssertEqual(pruned.roles.count, 1)
        pruned.set(nil, for: b)
        XCTAssertTrue(pruned.roles.isEmpty)
        // Unknown role strings are ignored on load.
        XCTAssertTrue(HubRoleBook(plist: ["http://x": "admin"]).roles.isEmpty)
    }

    private func item(_ id: String, updated: Double = 0) -> Item {
        Item(id: id, key: "k:\(id)", title: "t", createdAt: t0, updatedAt: t0.addingTimeInterval(updated))
    }

    func testCardSnoozesArePruned() {
        var store = ItemStore(items: [item("a"), item("b")])
        store.snoozeCard(id: "a", until: t0.addingTimeInterval(60))
        store.snoozeCard(id: "b", until: t0.addingTimeInterval(3600))
        store.snoozeCard(id: "ghost", until: t0.addingTimeInterval(3600))   // unknown id: ignored
        XCTAssertEqual(store.snoozedCardCount, 2)
        store.prune(now: t0.addingTimeInterval(120))
        XCTAssertEqual(store.snoozedCardCount, 1)
        // The item closes on the hub: its snooze goes with it.
        store.merge([item("a")], isFullSnapshot: true, now: t0.addingTimeInterval(130))
        XCTAssertEqual(store.snoozedCardCount, 0)
    }

    func testLocalCloseTombstonesExpireAfter24h() {
        var store = ItemStore(items: [item("a")])
        store.closeLocally(id: "a", now: t0)
        XCTAssertEqual(store.closedTombstoneCount, 1)
        store.prune(now: t0.addingTimeInterval(23 * 3600))
        XCTAssertEqual(store.closedTombstoneCount, 1)
        store.prune(now: t0.addingTimeInterval(ItemStore.closedRetention + 1))
        XCTAssertEqual(store.closedTombstoneCount, 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testLocalCloseTombstonesAreCapped() {
        let n = ItemStore.maxClosedTombstones + 20
        var store = ItemStore(items: (0..<n).map { item("i\($0)") })
        for i in 0..<n { store.closeLocally(id: "i\(i)", now: t0.addingTimeInterval(Double(i))) }
        store.prune(now: t0.addingTimeInterval(Double(n)))
        XCTAssertEqual(store.closedTombstoneCount, ItemStore.maxClosedTombstones)
    }
}
