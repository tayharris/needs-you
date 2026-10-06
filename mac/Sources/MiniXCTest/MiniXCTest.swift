import Foundation

// A minimal XCTest stand-in. The Command Line Tools for Swift 5.10 don't ship XCTest, so
// `swift test` can't run without Xcode. The test files in Tests/NeedsTayCoreTests import
// this module instead when built into `needstay-selftest` (NEEDSTAY_SELFTEST is defined),
// and real XCTest otherwise. Only the API those tests use is provided.

public struct TestFailure: CustomStringConvertible {
    public let message: String
    public let file: StaticString
    public let line: UInt
    public var description: String { "\(file):\(line): \(message)" }
}

public enum MiniXCTestState {
    nonisolated(unsafe) public static var failures: [TestFailure] = []
}

public struct XCTSkip: Error {
    public let message: String
    public init(_ message: String = "") { self.message = message }
}

public struct XCTUnwrapError: Error {}

open class XCTestCase {
    public required init() {}
    open func setUp() {}
    open func tearDown() {}
}

private func record(_ message: String, _ file: StaticString, _ line: UInt) {
    MiniXCTestState.failures.append(TestFailure(message: message, file: file, line: line))
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    record("XCTFail: \(message)", file, line)
}

public func XCTAssert(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try expression(), message(), file: file, line: line)
}

public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try !expression() { record("XCTAssertTrue failed. \(message())", file, line) }
    } catch {
        record("XCTAssertTrue threw \(error). \(message())", file, line)
    }
}

public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() { record("XCTAssertFalse failed. \(message())", file, line) }
    } catch {
        record("XCTAssertFalse threw \(error). \(message())", file, line)
    }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x != y { record("XCTAssertEqual failed: (\(x)) is not equal to (\(y)). \(message())", file, line) }
    } catch {
        record("XCTAssertEqual threw \(error). \(message())", file, line)
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        let (x, y) = (try a(), try b())
        if x == y { record("XCTAssertNotEqual failed: (\(x)) is equal to (\(y)). \(message())", file, line) }
    } catch {
        record("XCTAssertNotEqual threw \(error). \(message())", file, line)
    }
}

public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if let value = try expression() { record("XCTAssertNil failed: \"\(value)\". \(message())", file, line) }
    } catch {
        record("XCTAssertNil threw \(error). \(message())", file, line)
    }
}

public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do {
        if try expression() == nil { record("XCTAssertNotNil failed. \(message())", file, line) }
    } catch {
        record("XCTAssertNotNil threw \(error). \(message())", file, line)
    }
}

public func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        record("XCTUnwrap failed: expected non-nil value. \(message())", file, line)
        throw XCTUnwrapError()
    }
    return value
}

// MARK: - Runner

public struct TestEntry {
    public let name: String
    public let run: () async throws -> Void
    public init(name: String, run: @escaping () async throws -> Void) {
        self.name = name
        self.run = run
    }
}

/// Builds entries for one XCTestCase subclass from its Linux-style `allTests` list.
public func testEntries<T: XCTestCase>(_ type: T.Type, _ tests: [(String, (T) -> () throws -> Void)], async asyncTests: [(String, (T) -> () async throws -> Void)] = []) -> [TestEntry] {
    let className = String(describing: type)
    let sync = tests.map { name, method in
        TestEntry(name: "\(className).\(name)") {
            let instance = T()
            instance.setUp()
            defer { instance.tearDown() }
            try method(instance)()
        }
    }
    let asyncs = asyncTests.map { name, method in
        TestEntry(name: "\(className).\(name)") {
            let instance = T()
            instance.setUp()
            defer { instance.tearDown() }
            try await method(instance)()
        }
    }
    return sync + asyncs
}

/// Overload for classes whose `allTests` are all non-throwing (Swift infers a
/// non-throwing element type there, which doesn't convert inside an array).
public func testEntries<T: XCTestCase>(_ type: T.Type, _ tests: [(String, (T) -> () -> Void)]) -> [TestEntry] {
    let throwing: [(String, (T) -> () throws -> Void)] = tests.map { name, method in
        (name, { (instance: T) -> () throws -> Void in { method(instance)() } })
    }
    return testEntries(type, throwing, async: [])
}

/// Runs entries, prints an XCTest-like summary, and returns the process exit code.
public func runTests(_ entries: [TestEntry]) async -> Int32 {
    var failed = 0
    let start = Date()
    for entry in entries {
        let before = MiniXCTestState.failures.count
        var skipped = false
        do {
            try await entry.run()
        } catch let skip as XCTSkip {
            skipped = true
            print("Test \(entry.name) skipped: \(skip.message)")
        } catch is XCTUnwrapError {
            // already recorded
        } catch {
            MiniXCTestState.failures.append(TestFailure(message: "threw \(error)", file: #filePath, line: #line))
        }
        let newFailures = MiniXCTestState.failures[before...]
        if newFailures.isEmpty {
            if !skipped { print("Test \(entry.name) passed") }
        } else {
            failed += 1
            for f in newFailures { print("  \(f)") }
            print("Test \(entry.name) FAILED")
        }
    }
    let elapsed = String(format: "%.3f", Date().timeIntervalSince(start))
    print("Executed \(entries.count) tests, with \(failed) failure\(failed == 1 ? "" : "s") in \(elapsed) seconds")
    return failed == 0 ? 0 : 1
}
