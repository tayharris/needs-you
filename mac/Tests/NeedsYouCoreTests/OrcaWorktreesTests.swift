#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class OrcaWorktreesTests: XCTestCase {
    static var allTests = [
        ("testParsesRowsAndSkipsArchived", testParsesRowsAndSkipsArchived),
        ("testUntrustedTextIsOneCleanLine", testUntrustedTextIsOneCleanLine),
        ("testRejectsAnswersThatArentOK", testRejectsAnswersThatArentOK),
        ("testVisibleOrderAndCap", testVisibleOrderAndCap),
        ("testArgumentsAndHeader", testArgumentsAndHeader),
    ]

    func answer(_ rows: [[String: Any]]) -> Data {
        let obj: [String: Any] = ["id": "local", "ok": true,
                                  "result": ["worktrees": rows, "hostScope": ["hostIds": ["local"]], "truncated": false],
                                  "_meta": ["runtimeId": "local"]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    let base: [String: Any] = [
        "worktreeId": "repo1::/Users/u/src/app", "hostId": "local", "repo": "app", "path": "/Users/u/src/app",
        "branch": "main", "isArchived": false, "displayName": "app", "workspaceStatus": "in-progress",
        "lastActivityAt": 1791450000000, "liveTerminalCount": 1, "unread": false, "status": "active",
        "preview": "$ export TOKEN=abc", "comment": "secret plan", "linkedPR": NSNull(), "agents": [],
        "someNewField": ["nested": [1, 2]],
    ]

    func row(_ changes: [String: Any]) -> [String: Any] { base.merging(changes) { _, new in new } }

    func testParsesRowsAndSkipsArchived() {
        let rows = OrcaWorktrees.parse(answer([
            base, row(["worktreeId": "w2", "displayName": "", "branch": "feature-x", "unread": true,
                       "liveTerminalCount": 2, "workspaceStatus": "in-review"]),
            row(["worktreeId": "w3", "isArchived": true]),
        ]), environment: "Work Sandbox")
        XCTAssertEqual(rows?.count, 2)
        let a = rows![0], b = rows![1]
        XCTAssertEqual(a.name, "app")
        XCTAssertEqual(a.host, "local")
        XCTAssertEqual(a.environment, "Work Sandbox")
        XCTAssertEqual(a.lastActivity, Date(timeIntervalSince1970: 1791450000))
        XCTAssertEqual(a.detail, "in-progress · 1 terminal · Work Sandbox")
        XCTAssertEqual(b.name, "feature-x")  // no display name: the branch
        XCTAssertEqual(b.detail, "in-review · 2 terminals · unread · Work Sandbox")
        XCTAssertNotEqual(a.id, b.id)
        let text = "\(rows!)"
        for never in ["TOKEN", "secret plan", "/Users/u"] { XCTAssertFalse(text.contains(never), never) }
    }

    func testUntrustedTextIsOneCleanLine() {
        let evil = "x\u{1b}]8;;https://evil.example/\u{07}click\u{202e}\nme\u{200b}" + String(repeating: "y", count: 80)
        let rows = OrcaWorktrees.parse(answer([row(["displayName": evil, "hostId": ["no": "dict"],
                                                    "liveTerminalCount": true, "lastActivityAt": "soon"])]),
                                       environment: nil)!
        let r = rows[0]
        for bad in ["\u{1b}", "\u{07}", "\u{202e}", "\u{200b}", "\n"] { XCTAssertFalse(r.name.contains(bad), bad) }
        XCTAssertTrue(r.name.hasSuffix("…"))
        XCTAssertTrue(r.name.count <= 40, r.name)
        XCTAssertEqual(r.host, "")
        XCTAssertEqual(r.liveTerminals, 0)
        XCTAssertNil(r.lastActivity)
        XCTAssertEqual(OrcaWorktrees.clean(42, limit: 10), "")
        XCTAssertEqual(OrcaWorktrees.clean("  a \t b  ", limit: 10), "a b")
    }

    func testRejectsAnswersThatArentOK() {
        XCTAssertNil(OrcaWorktrees.parse(Data("garbage".utf8), environment: nil))
        XCTAssertNil(OrcaWorktrees.parse(Data(#"{"ok": false, "error": {"message": "no runtime"}}"#.utf8), environment: nil))
        XCTAssertNil(OrcaWorktrees.parse(Data(#"{"ok": true, "result": []}"#.utf8), environment: nil))
        XCTAssertEqual(OrcaWorktrees.parse(Data(#"{"ok": true, "result": {"worktrees": ["x", null]}}"#.utf8),
                                           environment: nil), [])
    }

    func testVisibleOrderAndCap() {
        var list: [[String: Any]] = []
        for i in 0..<12 {
            list.append(row(["worktreeId": "w\(i)", "displayName": "w\(i)", "liveTerminalCount": i == 9 ? 1 : 0,
                             "unread": i == 4, "lastActivityAt": 1791450000000 + i * 1000]))
        }
        let shown = OrcaWorktrees.visible(OrcaWorktrees.parse(answer(list), environment: nil)!)
        XCTAssertEqual(shown.count, OrcaWorktrees.maxRows)
        XCTAssertEqual(shown.map { $0.name }.prefix(3), ["w9", "w4", "w11"])
    }

    func testArgumentsAndHeader() {
        XCTAssertEqual(OrcaWorktrees.psArguments(environment: nil), ["worktree", "ps", "--json"])
        XCTAssertEqual(OrcaWorktrees.psArguments(environment: "Work Sandbox"),
                       ["worktree", "ps", "--json", "--environment", "Work Sandbox"])
        let rows = OrcaWorktrees.parse(answer([base, row(["worktreeId": "w2", "liveTerminalCount": 0])]), environment: nil)!
        XCTAssertEqual(OrcaWorktrees.header(rows), "ORCA · 1 active of 2")
        XCTAssertEqual(OrcaWorktrees.header([rows[1]]), "ORCA · 1")
    }
}
