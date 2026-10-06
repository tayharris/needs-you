#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Forward-only prefs migrations (`prefsVersion`). Each test uses its own throwaway suite.
final class PrefsMigrationTests: XCTestCase {
    static var allTests = [
        ("testFreshPrefsGetCurrentVersion", testFreshPrefsGetCurrentVersion),
        ("testLegacyPlacementsMigrateAndUnknownKeysSurvive", testLegacyPlacementsMigrateAndUnknownKeysSurvive),
        ("testKeychainMoveFlagsRemoteHubs", testKeychainMoveFlagsRemoteHubs),
        ("testMigrationsRunOnceAndInOrder", testMigrationsRunOnceAndInOrder),
        ("testNewerPrefsAreLeftAlone", testNewerPrefsAreLeftAlone),
    ]

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "needsyou-prefs-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        // removePersistentDomain can leave an empty plist behind; remove it so tests leave no trace.
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(suite).plist")
    }

    func testFreshPrefsGetCurrentVersion() {
        XCTAssertEqual(PrefsMigrator.migrate(defaults), [1, 2, 3])
        XCTAssertEqual(defaults.integer(forKey: PrefsMigrator.versionKey), PrefsMigrator.currentVersion)
        XCTAssertEqual(PrefsMigrator.migrate(defaults), [])
        // No hubs configured: nothing to re-connect.
        XCTAssertFalse(defaults.bool(forKey: PrefsMigrator.reconnectKey))
    }

    func testLegacyPlacementsMigrateAndUnknownKeysSurvive() throws {
        let legacy = ["a|b": PanelPlacement(corner: .bottomLeft, screenID: "s1")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "panelPlacements")
        defaults.set(["http://hub.ts.net:8765"], forKey: "hubURLs")
        defaults.set(["http://hub.ts.net:8765": "owner"], forKey: "hubRoles")
        defaults.set("from-the-future", forKey: "someKeyANewerBuildAdded")

        PrefsMigrator.migrate(defaults)

        let book = PlacementBook.decode(defaults.data(forKey: "panelPlacements"))
        XCTAssertEqual(book.placement(forLayout: "a|b"), PanelPlacement(corner: .bottomLeft, screenID: "s1"))
        // Stored in the new format now.
        XCTAssertNotNil(try? JSONDecoder().decode(PlacementBook.self, from: try XCTUnwrap(defaults.data(forKey: "panelPlacements"))))
        XCTAssertEqual(defaults.stringArray(forKey: "hubURLs"), ["http://hub.ts.net:8765"])
        // Nothing is deleted: an older build still finds its keys after a rollback.
        XCTAssertEqual(defaults.dictionary(forKey: "hubRoles") as? [String: String], ["http://hub.ts.net:8765": "owner"])
        XCTAssertEqual(defaults.string(forKey: "someKeyANewerBuildAdded"), "from-the-future")
    }

    func testKeychainMoveFlagsRemoteHubs() {
        defaults.set(2, forKey: PrefsMigrator.versionKey)
        defaults.set(["http://hub.ts.net:8765"], forKey: "hubURLs")
        XCTAssertEqual(PrefsMigrator.migrate(defaults), [3])
        XCTAssertTrue(defaults.bool(forKey: PrefsMigrator.reconnectKey))
    }

    func testMigrationsRunOnceAndInOrder() {
        var log: [Int] = []
        let migrations = [
            PrefsMigrator.Migration(version: 3) { _ in log.append(3) },
            PrefsMigrator.Migration(version: 1) { _ in log.append(1) },
            PrefsMigrator.Migration(version: 2) { _ in log.append(2) },
        ]
        defaults.set(1, forKey: PrefsMigrator.versionKey)
        XCTAssertEqual(PrefsMigrator.migrate(defaults, migrations: migrations), [2, 3])
        XCTAssertEqual(log, [2, 3])
        XCTAssertEqual(PrefsMigrator.migrate(defaults, migrations: migrations), [])
        XCTAssertEqual(defaults.integer(forKey: PrefsMigrator.versionKey), 3)
    }

    func testNewerPrefsAreLeftAlone() {
        defaults.set(99, forKey: PrefsMigrator.versionKey)
        defaults.set("x", forKey: "panelPlacements")
        XCTAssertEqual(PrefsMigrator.migrate(defaults), [])
        XCTAssertEqual(defaults.integer(forKey: PrefsMigrator.versionKey), 99)
        XCTAssertEqual(defaults.string(forKey: "panelPlacements"), "x")
    }
}
