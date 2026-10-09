#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation

/// Throwaway UserDefaults suites for tests, one FIXED name per test class.
///
/// `removePersistentDomain` empties a suite, but cfprefsd still writes an empty
/// `~/Library/Preferences/<suite>.plist` back afterwards, so a fresh random name per test
/// left thousands of files on every Mac that ran the suite. A fixed name leaves at most one
/// small file per class, and it's emptied before each test (so a crashed run can't leak
/// state into the next) and after it. Tests run one at a time (MiniXCTest runs serially and
/// `swift test` runs without `--parallel`), so a class never shares its suite with itself.
enum TestDefaults {
    static let prefix = "needsyou-tests."

    /// The suite name for one test class, e.g. `needsyou-tests.UIPrefsTests`.
    static func suiteName(_ owner: Any.Type) -> String {
        prefix + String(describing: owner)
    }

    /// The suite, emptied.
    static func make(_ suite: String) -> UserDefaults {
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    static func clear(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

/// Guards against the litter coming back: only `TestDefaults` may open a defaults suite in
/// the tests, and no suite name may be made from a UUID.
final class TestDefaultsTests: XCTestCase {
    static var allTests = [
        ("testSuitesComeFromTestDefaults", testSuitesComeFromTestDefaults),
        ("testFixedNameStartsEmpty", testFixedNameStartsEmpty),
    ]

    /// <repo>/mac/Tests/NeedsYouCoreTests. This file sits three directories below the repo
    /// root both in Tests/NeedsYouCoreTests and as its symlink in Sources/NeedsYouSelfTest.
    private var testsDir: URL {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("mac/Tests/NeedsYouCoreTests")
    }

    func testSuitesComeFromTestDefaults() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: testsDir.path)
            .filter { $0.hasSuffix(".swift") && $0 != "TestDefaults.swift" }
        XCTAssertTrue(files.count > 20, "test sources not found at \(testsDir.path)")
        for name in files {
            let text = try String(contentsOf: testsDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("UserDefaults(suiteName:"), "\(name): use TestDefaults, not a suite of its own")
            for line in text.split(separator: "\n") where line.contains("suite") && line.contains("UUID()") {
                XCTFail("\(name): a UUID-named defaults suite leaves a plist behind: \(line)")
            }
        }
    }

    func testFixedNameStartsEmpty() {
        let suite = TestDefaults.suiteName(Self.self)
        XCTAssertEqual(suite, "needsyou-tests.TestDefaultsTests")
        defer { TestDefaults.clear(suite) }
        TestDefaults.make(suite).set("left over", forKey: "k")
        XCTAssertNil(TestDefaults.make(suite).object(forKey: "k"), "make() empties the suite")
    }
}
