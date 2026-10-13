#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Notes (docs/API.md "Notes", ADR 0014) as the app reads, draws and ticks them.
final class NotesTests: XCTestCase {
    static var allTests = [
        ("testLines", testLines),
        ("testToggleFlipsOnlyTheShownLine", testToggleFlipsOnlyTheShownLine),
        ("testFindRedoesAClickOnAFreshCopy", testFindRedoesAClickOnAFreshCopy),
        ("testOpenCount", testOpenCount),
        ("testProblem", testProblem),
        ("testRequestsAndOutcomes", testRequestsAndOutcomes),
        ("testDecodingIsBounded", testDecodingIsBounded),
    ]
    static var asyncTests = [
        ("testDemoFeedSavesWithRevCheck", testDemoFeedSavesWithRevCheck),
    ]

    let doc = "## Today\n- [ ] one **bold**\n  - [x] nested\n\n\n- plain\nJust text\n```\n- [ ] in code\n```\n# Done ##\n"

    func testLines() {
        XCTAssertEqual(NotesText.lines(doc), [
            .heading(level: 2, text: "Today"),
            .checkbox(index: 1, checked: false, text: "one **bold**", indent: 0),
            .checkbox(index: 2, checked: true, text: "nested", indent: 1),
            .blank,
            .bullet(text: "plain", indent: 0),
            .text("Just text"),
            .text("- [ ] in code"),
            .heading(level: 1, text: "Done"),
        ])
        XCTAssertEqual(NotesText.lines(""), [])
        XCTAssertEqual(NotesText.lines("#tag"), [.text("#tag")])
    }

    func testToggleFlipsOnlyTheShownLine() {
        let ticked = NotesText.toggle(doc, index: 1, expect: "one **bold**")
        XCTAssertEqual(ticked, doc.replacingOccurrences(of: "- [ ] one", with: "- [x] one"))
        let unticked = NotesText.toggle(doc, index: 2, expect: "nested")
        XCTAssertEqual(unticked, doc.replacingOccurrences(of: "  - [x] nested", with: "  - [ ] nested"))
        XCTAssertNil(NotesText.toggle(doc, index: 1, expect: "something else"), "the notes moved")
        XCTAssertNil(NotesText.toggle(doc, index: 4, expect: "plain"), "not a checkbox")
        XCTAssertNil(NotesText.toggle(doc, index: 99, expect: ""))
    }

    func testFindRedoesAClickOnAFreshCopy() {
        let fresh = "## Inbox\n- [ ] new from an agent\n" + doc
        XCTAssertEqual(NotesText.find(fresh, expect: "one **bold**", checked: false), 3)
        XCTAssertNil(NotesText.find(fresh, expect: "one **bold**", checked: true))
    }

    func testOpenCount() {
        XCTAssertEqual(NotesText.openCount(doc), 1)
        XCTAssertEqual(NotesText.openCount(""), 0)
    }

    func testProblem() {
        XCTAssertNil(NotesText.problem("a\n\tb\r\n"))
        XCTAssertNotNil(NotesText.problem("evil\u{202E}name"))
        XCTAssertNotNil(NotesText.problem("a\u{0007}"))
        XCTAssertNotNil(NotesText.problem(String(repeating: "x", count: NotesText.maxLength + 1)))
    }

    func testRequestsAndOutcomes() throws {
        let base = URL(string: "http://127.0.0.1:8765")!
        let get = HubClient.notesRequest(base: base, token: "t", etag: "\"r1\"")
        XCTAssertEqual(get.url?.absoluteString, "http://127.0.0.1:8765/v1/notes")
        XCTAssertEqual(get.value(forHTTPHeaderField: "If-None-Match"), "\"r1\"")
        let put = HubClient.saveNotesRequest(base: base, token: "t", text: "x", baseRev: "r1")
        XCTAssertEqual(put.httpMethod, "PUT")
        let body = try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["text": "x", "base_rev": "r1"])

        XCTAssertEqual(try HubClient.notesOutcome(status: 304, body: Data(), etag: nil), .unchanged)
        XCTAssertEqual(try HubClient.notesOutcome(status: 404, body: Data(), etag: nil), .unsupported)
        let json = Data(#"{"id": "nt_main", "text": "- [ ] a", "rev": "r2", "updated_at": "2026-10-13T09:00:00.000Z", "new": 1}"#.utf8)
        guard case let .fresh(doc, etag) = try HubClient.notesOutcome(status: 200, body: json, etag: "\"r2\"") else {
            return XCTFail("expected fresh")
        }
        XCTAssertEqual(doc.text, "- [ ] a")
        XCTAssertEqual(doc.rev, "r2")
        XCTAssertEqual(etag, "\"r2\"")
        XCTAssertNotNil(doc.updatedAt)
        do {
            _ = try HubClient.notesOutcome(status: 403, body: Data(), etag: nil)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? HubError, .unauthorized)
        }

        XCTAssertEqual(try HubClient.saveNotesOutcome(status: 409, body: Data()), .conflict)
        let refused = Data(#"{"error": "secret_in_text", "message": "looks like a key", "field": "text"}"#.utf8)
        XCTAssertEqual(try HubClient.saveNotesOutcome(status: 400, body: refused),
                       .refused(code: "secret_in_text", message: "looks like a key"))
        guard case .saved = try HubClient.saveNotesOutcome(status: 200, body: json) else { return XCTFail("expected saved") }
    }

    func testDecodingIsBounded() throws {
        let long = String(repeating: "x", count: 20_000)
        let json = Data(#"{"text": "a‮b\#(long)", "rev": "\#(long)"}"#.utf8)
        let doc = try HubJSON.makeDecoder().decode(NotesDocument.self, from: json)
        XCTAssertTrue(doc.text.count <= NotesText.maxLength)
        XCTAssertFalse(doc.text.contains("\u{202E}"))
        XCTAssertEqual(doc.rev.count, 64)
    }

    func testDemoFeedSavesWithRevCheck() async throws {
        let feed = DemoFeed(items: [], statuses: [])
        guard case let .fresh(doc, etag) = try await feed.fetchNotes(etag: nil) else { return XCTFail("expected fresh") }
        XCTAssertTrue(NotesText.openCount(doc.text) > 0)
        let again = try await feed.fetchNotes(etag: etag)
        XCTAssertEqual(again, .unchanged)
        let stale = try await feed.saveNotes(text: "x", baseRev: "nope")
        XCTAssertEqual(stale, .conflict)
        guard case let .saved(saved) = try await feed.saveNotes(text: "x", baseRev: doc.rev) else {
            return XCTFail("expected saved")
        }
        XCTAssertNotEqual(saved.rev, doc.rev)
    }
}
