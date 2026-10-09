#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Forward-only prefs migrations (`prefsVersion`). Each test starts from an empty suite (`TestDefaults`).
final class PrefsMigrationTests: XCTestCase {
    static var allTests = [
        ("testFreshPrefsGetCurrentVersion", testFreshPrefsGetCurrentVersion),
        ("testLegacyPlacementsMigrateAndUnknownKeysSurvive", testLegacyPlacementsMigrateAndUnknownKeysSurvive),
        ("testKeychainMoveFlagsRemoteHubs", testKeychainMoveFlagsRemoteHubs),
        ("testMigrationsRunOnceAndInOrder", testMigrationsRunOnceAndInOrder),
        ("testNewerPrefsAreLeftAlone", testNewerPrefsAreLeftAlone),
        ("testLookSettingsNeedNoMigration", testLookSettingsNeedNoMigration),
    ]

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = TestDefaults.suiteName(Self.self)
        defaults = TestDefaults.make(suite)
    }

    override func tearDown() {
        TestDefaults.clear(suite)
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

    /// The look, alert and shortcut settings are new keys with defaults equal to the
    /// original look, so prefs from a version 3 build need no migration: nothing runs,
    /// nothing is written, and the app looks and behaves as before.
    func testLookSettingsNeedNoMigration() {
        defaults.set(3, forKey: PrefsMigrator.versionKey)
        defaults.set(["http://hub.ts.net:8765"], forKey: "hubURLs")
        defaults.set(true, forKey: "snapToCorners")
        let before = Set((defaults.persistentDomain(forName: suite) ?? [:]).keys)

        XCTAssertEqual(PrefsMigrator.currentVersion, 3)
        XCTAssertEqual(PrefsMigrator.migrate(defaults), [])
        XCTAssertEqual(UIPrefs.load(from: defaults), UIPrefs.defaults)
        XCTAssertEqual(UIPrefs.load(from: defaults).metrics, PanelStyle.regular)
        XCTAssertEqual(HotKeyValidator.stored(defaults.string(forKey: "hotKey")), .standard)
        XCTAssertFalse(defaults.bool(forKey: "hotKeyOpensTopLink"))
        XCTAssertEqual(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys), before)
    }
}
