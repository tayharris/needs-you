#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class OrcaJumpTests: XCTestCase {
    static var allTests = [
        ("testParsesHandleAndEnvironment", testParsesHandleAndEnvironment),
        ("testRejectsBadHandles", testRejectsBadHandles),
        ("testRejectsBadEnvironments", testRejectsBadEnvironments),
        ("testRejectsOtherShapes", testRejectsOtherShapes),
        ("testArgumentsCommandAndRoundTrip", testArgumentsCommandAndRoundTrip),
        ("testLinkPolicyAllowsOnlyTheJump", testLinkPolicyAllowsOnlyTheJump),
        ("testMenuItemOpensTheJump", testMenuItemOpensTheJump),
        ("testReadsOrcaOutput", testReadsOrcaOutput),
    ]

    let handle = "term_4f261ae3-041a-47c6-872a-cf02e1e40804"

    func testParsesHandleAndEnvironment() {
        let j = OrcaJump.parse("needsyou://orca/terminal?handle=\(handle)")
        XCTAssertEqual(j?.handle, handle)
        XCTAssertNil(j?.environment)
        let e = OrcaJump.parse("NEEDSYOU://ORCA/terminal?handle=\(handle)&environment=Work%20Sandbox")
        XCTAssertEqual(e?.environment, "Work Sandbox")
        XCTAssertNil(OrcaJump.parse("needsyou://orca/terminal?handle=\(handle)&environment=")?.environment)
        XCTAssertNotNil(OrcaJump.parse("needsyou://orca/terminal?handle=\(handle)&environment="))
    }

    func testRejectsBadHandles() {
        for h in ["", "term_", "term_abc", "term_ABCDEF12", "term_abcdef12;rm", "term_abcdef12%20x",
                  "xterm_abcdef12", "--terminal", "term_" + String(repeating: "a", count: 65),
                  "term_abcdef1g"] {
            XCTAssertNil(OrcaJump.parse("needsyou://orca/terminal?handle=\(h)"), h)
            XCTAssertNil(OrcaJump(handle: h.removingPercentEncoding ?? h), h)
        }
        XCTAssertNotNil(OrcaJump(handle: "term_abcdef12"))
    }

    func testRejectsBadEnvironments() {
        for e in ["-x", "--json", " lead", "a;b", "a$b", "a`b", "a'b", "a\"b", "a/b", "a\nb",
                  "é", String(repeating: "a", count: 65)] {
            XCTAssertNil(OrcaJump(handle: handle, environment: e), e)
            let q = e.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            XCTAssertNil(OrcaJump.parse("needsyou://orca/terminal?handle=\(handle)&environment=\(q)"), e)
        }
        for e in ["local", "Work Sandbox", "build-1", "dev_box.2"] {
            XCTAssertNotNil(OrcaJump(handle: handle, environment: e), e)
        }
    }

    func testRejectsOtherShapes() {
        for s in [
            "needsyou://connect?hub=x&code=y",
            "needsyou://orca/terminal",
            "needsyou://orca/terminal/?handle=\(handle)",
            "needsyou://orca/worktree?handle=\(handle)",
            "needsyou://evil/terminal?handle=\(handle)",
            "needsyou://orca:9/terminal?handle=\(handle)",
            "needsyou://u@orca/terminal?handle=\(handle)",
            "needsyou://orca/terminal?handle=\(handle)#x",
            "needsyou://orca/terminal?handle=\(handle)&handle=term_abcdef12",
            "needsyou://orca/terminal?handle=\(handle)&environment=a&environment=b",
            "needsyou://orca/terminal?handle=\(handle)&cmd=rm",
            "orca://orca/terminal?handle=\(handle)",
            "https://orca/terminal?handle=\(handle)",
            "needsyou://orca/terminal?handle=\(handle) x",
        ] {
            XCTAssertNil(OrcaJump.parse(s), s)
        }
    }

    func testArgumentsCommandAndRoundTrip() {
        let j = OrcaJump(handle: handle, environment: "Work Sandbox")!
        XCTAssertEqual(j.arguments, ["terminal", "switch", "--terminal", handle, "--json", "--environment", "Work Sandbox"])
        XCTAssertEqual(j.command, "orca terminal switch --terminal \(handle) --environment 'Work Sandbox'")
        XCTAssertEqual(OrcaJump.parse(j.url), j)
        let local = OrcaJump(handle: handle)!
        XCTAssertEqual(local.arguments, ["terminal", "switch", "--terminal", handle, "--json"])
        XCTAssertEqual(local.via("Work Sandbox"), j)
        XCTAssertNil(local.via("--json"))
        XCTAssertEqual(local.url.absoluteString, "needsyou://orca/terminal?handle=\(handle)")
    }

    func testLinkPolicyAllowsOnlyTheJump() {
        XCTAssertTrue(LinkPolicy.isAllowed("needsyou://orca/terminal?handle=\(handle)"))
        XCTAssertNil(LinkPolicy.externalURL("needsyou://orca/terminal?handle=\(handle)"))
        XCTAssertFalse(LinkPolicy.isAllowed("needsyou://orca/terminal?handle=bad"))
        XCTAssertFalse(LinkPolicy.isAllowed("needsyou://connect?hub=https%3A%2F%2Fh&code=abc"))
    }

    func testMenuItemOpensTheJump() {
        let link = ItemLink(label: "Terminal", url: "needsyou://orca/terminal?handle=\(handle)")
        let item = Item(id: "a", key: "agent:h:x", priority: .normal, title: "Claude needs permission",
                        links: [link], createdAt: Date())
        guard case .open(let url) = MenuItemAction.forItem(item) else { return XCTFail("not open") }
        XCTAssertEqual(OrcaJump.parse(url)?.handle, handle)
    }

    func testReadsOrcaOutput() {
        let ok = #"{"id":"x","ok":true,"result":{"focus":{"navigated":true}}}"#
        let stale = #"{"id":"x","ok":false,"error":{"code":"terminal_handle_stale"}}"#
        XCTAssertTrue(OrcaJump.switchSucceeded(Data(ok.utf8)))
        XCTAssertFalse(OrcaJump.switchSucceeded(Data(stale.utf8)))
        XCTAssertFalse(OrcaJump.switchSucceeded(Data("not json".utf8)))
        let list = #"{"ok":true,"result":{"environments":[{"name":"Work Sandbox"},{"name":"-x"},{"name":"build-1"},{"id":"no-name"}]}}"#
        XCTAssertEqual(OrcaJump.environmentNames(Data(list.utf8)), ["Work Sandbox", "build-1"])
        XCTAssertEqual(OrcaJump.environmentNames(Data("{}".utf8)), [])
    }
}
