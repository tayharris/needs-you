#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

final class TerminalJumpTests: XCTestCase {
    static var allTests = [
        ("testParsesEachApp", testParsesEachApp),
        ("testRejectsBadValues", testRejectsBadValues),
        ("testRejectsInjection", testRejectsInjection),
        ("testRejectsOtherShapes", testRejectsOtherShapes),
        ("testInvocationsAreFixed", testInvocationsAreFixed),
        ("testAppleScriptCallsAndPlan", testAppleScriptCallsAndPlan),
        ("testActivationAndCommand", testActivationAndCommand),
        ("testRoundTrip", testRoundTrip),
        ("testLinkPolicyAndMenuBar", testLinkPolicyAndMenuBar),
        ("testActionTableMatchesParsers", testActionTableMatchesParsers),
        ("testScriptIsFixedAndHasEachHandler", testScriptIsFixedAndHasEachHandler),
        ("testAutomationPermissionStatus", testAutomationPermissionStatus),
    ]

    let uuid = "4F261AE3-041A-47C6-872A-CF02E1E40804"
    let base = "needsyou://terminal/focus?"

    func jump(_ q: String) -> TerminalJump? { TerminalJump.parse(base + q) }

    func testParsesEachApp() {
        XCTAssertEqual(jump("app=wezterm&pane=12")?.target, .pane(12))
        XCTAssertEqual(jump("app=wezterm&pane=12")?.app, .wezterm)
        XCTAssertEqual(jump("app=tmux&pane=7")?.target, .pane(7))
        XCTAssertEqual(jump("app=tmux&target=work:2.1")?.target, .tmuxTarget(session: "work", window: 2, pane: 1))
        XCTAssertEqual(jump("app=tmux&target=my_proj-2:10.0&host=iterm")?.hostApp, .iterm)
        XCTAssertEqual(jump("host=wezterm&app=tmux&pane=3")?.hostApp, .wezterm)
        XCTAssertNil(jump("app=tmux&pane=3")?.hostApp)
        XCTAssertEqual(jump("app=iterm&session=\(uuid)")?.target, .session(uuid))
        XCTAssertEqual(jump("app=iterm&session=\(uuid.lowercased())")?.target, .session(uuid.lowercased()))
        XCTAssertEqual(jump("app=iterm&tty=/dev/ttys004")?.target, .tty("/dev/ttys004"))
        XCTAssertEqual(jump("app=terminal&tty=/dev/ttys012")?.target, .tty("/dev/ttys012"))
        XCTAssertEqual(jump("app=terminal&tty=%2Fdev%2Fttys012")?.target, .tty("/dev/ttys012"))
        XCTAssertEqual(jump("app=ghostty")?.target, .app)
        XCTAssertNotNil(TerminalJump.parse("NEEDSYOU://Terminal/Focus?app=wezterm&pane=1"))
    }

    func testRejectsBadValues() {
        for q in [
            "app=wezterm", "app=wezterm&pane=", "app=wezterm&pane=x", "app=wezterm&pane=1234567",
            "app=wezterm&pane=-1", "app=wezterm&pane=1.5", "app=wezterm&pane=%EF%BC%91",
            "app=tmux", "app=tmux&pane=%2512", "app=tmux&target=work", "app=tmux&target=work:2",
            "app=tmux&target=:2.1", "app=tmux&target=-t:2.1", "app=tmux&target=a.b:2.1",
            "app=tmux&target=a:b.c", "app=tmux&target=a:1.2.3", "app=tmux&target=a:1:2.3",
            "app=tmux&target=w%20x:1.2", "app=tmux&target=" + String(repeating: "a", count: 65) + ":1.2",
            "app=tmux&target=a:12345.1", "app=tmux&pane=1&host=tmux", "app=tmux&pane=1&host=xterm",
            "app=tmux&pane=1&target=a:1.2",
            "app=iterm", "app=iterm&session=abc", "app=iterm&session=\(uuid)0",
            "app=iterm&session=4F261AE3041A47C6872ACF02E1E40804", "app=iterm&session=w0t1p0:\(uuid)",
            "app=iterm&session=ZZZZZZZZ-041A-47C6-872A-CF02E1E40804",
            "app=iterm&session=\(uuid)&tty=/dev/ttys001",
            "app=terminal", "app=terminal&tty=/dev/tty1", "app=terminal&tty=/dev/ttys",
            "app=terminal&tty=/dev/ttys12345", "app=terminal&tty=/dev/ttys001/../x",
            "app=terminal&tty=ttys001", "app=terminal&session=\(uuid)",
            "app=ghostty&pane=1", "app=wezterm&pane=1&host=iterm", "app=iterm&tty=/dev/ttys001&host=iterm",
            "app=xterm&pane=1", "app=WezTerm&pane=1", "app=", "pane=1",
        ] {
            XCTAssertNil(jump(q), q)
        }
        XCTAssertNil(TerminalJump(app: .wezterm, target: .pane(1_000_000)))
        XCTAssertNil(TerminalJump(app: .wezterm, target: .tty("/dev/ttys001")))
        XCTAssertNil(TerminalJump(app: .terminal, target: .session(uuid)))
        XCTAssertNil(TerminalJump(app: .iterm, target: .tty("/dev/ttys1;x")))
        XCTAssertNil(TerminalJump(app: .tmux, target: .tmuxTarget(session: "-x", window: 1, pane: 1)))
        XCTAssertNil(TerminalJump(app: .wezterm, target: .pane(1), hostApp: .iterm))
        XCTAssertNotNil(TerminalJump(app: .tmux, target: .pane(1), hostApp: .terminal))
    }

    func testRejectsInjection() {
        for q in [
            "app=wezterm&pane=1;open%20-a%20Calculator", "app=wezterm&pane=1%0A2", "app=wezterm&pane=1%00",
            "app=wezterm&pane=--help", "app=tmux&target=--kill-server", "app=tmux&target=a:1.2;kill-server",
            "app=tmux&target=a:1.2%20%5C;kill-server", "app=tmux&target=$(id):1.2", "app=tmux&target=a%60id%60:1.2",
            "app=iterm&session=\(uuid)%22%20%26%20do%20shell%20script%20%22id",
            "app=terminal&tty=/dev/ttys001%22%20then%20do%20shell%20script%20%22id",
            "app=terminal&tty=/dev/ttys001'", "app=wezterm&pane=1&cmd=rm", "app=wezterm&pane=1&pane=2",
            "app=wezterm&app=tmux&pane=1", "app=tmux&pane=1&host=iterm&host=wezterm",
        ] {
            XCTAssertNil(jump(q), q)
        }
    }

    func testRejectsOtherShapes() {
        for s in [
            "needsyou://terminal/focus",
            "needsyou://terminal/focus?",
            "needsyou://terminal/focus/?app=wezterm&pane=1",
            "needsyou://terminal/run?app=wezterm&pane=1",
            "needsyou://terminal?app=wezterm&pane=1",
            "needsyou://evil/focus?app=wezterm&pane=1",
            "needsyou://u@terminal/focus?app=wezterm&pane=1",
            "needsyou://terminal:9/focus?app=wezterm&pane=1",
            "needsyou://terminal/focus?app=wezterm&pane=1#x",
            "needsyou://terminal/focus?app=wezterm&pane=1 x",
            "needsyou://terminal/focus?app=wezterm&pane=\u{FF11}",
            "https://terminal/focus?app=wezterm&pane=1",
            "wezterm://terminal/focus?app=wezterm&pane=1",
            "needsyou://orca/terminal?app=wezterm&pane=1",
        ] {
            XCTAssertNil(TerminalJump.parse(s), s)
        }
    }

    func testInvocationsAreFixed() {
        XCTAssertEqual(jump("app=wezterm&pane=12")?.invocations, [["cli", "activate-pane", "--pane-id", "12"]])
        XCTAssertEqual(jump("app=tmux&pane=7")?.invocations, [["select-window", "-t", "%7"], ["select-pane", "-t", "%7"]])
        XCTAssertEqual(jump("app=tmux&target=work:2.1")?.invocations,
                       [["select-window", "-t", "work:2.1"], ["select-pane", "-t", "work:2.1"]])
        XCTAssertEqual(jump("app=iterm&session=\(uuid)")?.invocations, [])
        XCTAssertEqual(jump("app=ghostty")?.invocations, [])
        for app in TerminalJump.App.allCases {
            for path in TerminalJump.cliPaths(app) {
                XCTAssertTrue(path.hasPrefix("/"), path)   // absolute: never PATH
            }
        }
        XCTAssertEqual(TerminalJump.cliPaths(.iterm), [])
        XCTAssertTrue(TerminalJump.cliPaths(.tmux).contains("/opt/homebrew/bin/tmux"))
        XCTAssertTrue(TerminalJump.cliPaths(.wezterm).contains("/Applications/WezTerm.app/Contents/MacOS/wezterm"))
    }

    func testAppleScriptCallsAndPlan() {
        let it = jump("app=iterm&session=\(uuid)")!
        XCTAssertEqual(it.appleScriptCall?.handler, "focus_iterm_session")
        XCTAssertEqual(it.appleScriptCall?.parameter, uuid)
        XCTAssertEqual(jump("app=iterm&tty=/dev/ttys004")?.appleScriptCall?.handler, "focus_iterm_tty")
        let t = jump("app=terminal&tty=/dev/ttys012")!
        XCTAssertEqual(t.appleScriptCall?.handler, "focus_terminal_tty")
        XCTAssertEqual(t.appleScriptCall?.parameter, "/dev/ttys012")
        XCTAssertNil(jump("app=wezterm&pane=1")?.appleScriptCall)

        XCTAssertEqual(TerminalJumpPlan.plan(it, appleScriptEnabled: true), .appleScript(handler: "focus_iterm_session", parameter: uuid))
        XCTAssertEqual(TerminalJumpPlan.plan(it, appleScriptEnabled: false), .activateOnly)
        XCTAssertEqual(TerminalJumpPlan.plan(t, appleScriptEnabled: false), .activateOnly)
        XCTAssertEqual(TerminalJumpPlan.plan(jump("app=wezterm&pane=1")!, appleScriptEnabled: false), .cli)
        XCTAssertEqual(TerminalJumpPlan.plan(jump("app=tmux&pane=1")!, appleScriptEnabled: true), .cli)
        XCTAssertEqual(TerminalJumpPlan.plan(jump("app=ghostty")!, appleScriptEnabled: true), .activateOnly)
        XCTAssertTrue(TerminalJump.App.iterm.usesAppleScript)
        XCTAssertTrue(TerminalJump.App.terminal.usesAppleScript)
        XCTAssertFalse(TerminalJump.App.wezterm.usesAppleScript)
    }

    func testActivationAndCommand() {
        XCTAssertEqual(jump("app=wezterm&pane=1")?.appsToActivate, [.wezterm])
        XCTAssertEqual(jump("app=tmux&pane=1&host=terminal")?.appsToActivate, [.terminal])
        XCTAssertEqual(jump("app=tmux&pane=1")?.appsToActivate, TerminalJump.hostApps)
        XCTAssertFalse(TerminalJump.hostApps.contains(.tmux))
        XCTAssertEqual(TerminalJump.App.wezterm.bundleID, "com.github.wez.wezterm")
        XCTAssertEqual(TerminalJump.App.iterm.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(TerminalJump.App.terminal.bundleID, "com.apple.Terminal")
        XCTAssertNil(TerminalJump.App.tmux.bundleID)
        XCTAssertEqual(jump("app=wezterm&pane=12")?.command, "wezterm cli activate-pane --pane-id 12")
        XCTAssertEqual(jump("app=tmux&pane=7")?.command, "tmux select-window -t %7 && tmux select-pane -t %7")
        XCTAssertNil(jump("app=iterm&session=\(uuid)")?.command)
        XCTAssertEqual(jump("app=tmux&target=work:2.1")?.summary, "tmux work:2.1")
        XCTAssertEqual(jump("app=terminal&tty=/dev/ttys012")?.summary, "Terminal tab on /dev/ttys012")
        XCTAssertTrue(jump("app=wezterm&pane=12")!.confirmation.message.contains("WezTerm pane 12"))
    }

    func testRoundTrip() {
        for q in ["app=wezterm&pane=12", "app=tmux&pane=7&host=iterm", "app=tmux&target=work:2.1",
                  "app=iterm&session=\(uuid)", "app=iterm&tty=/dev/ttys004", "app=terminal&tty=/dev/ttys012",
                  "app=ghostty"] {
            let j = jump(q)
            XCTAssertNotNil(j, q)
            XCTAssertEqual(j.flatMap { TerminalJump.parse($0.url) }, j, q)
            XCTAssertEqual(j?.url.absoluteString, base + q, q)
        }
    }

    func testLinkPolicyAndMenuBar() {
        let s = base + "app=wezterm&pane=12"
        XCTAssertTrue(LinkPolicy.isAllowed(s))
        XCTAssertNil(LinkPolicy.externalURL(s))   // never handed to NSWorkspace
        XCTAssertFalse(LinkPolicy.isAllowed(base + "app=wezterm&pane=x"))
        XCTAssertEqual(AppAction.parse(s), .terminal(jump("app=wezterm&pane=12")!))
        XCTAssertEqual(AppAction.parse("needsyou://orca/terminal?handle=term_abcdef12"),
                       .orca(OrcaJump(handle: "term_abcdef12")!))
        XCTAssertNil(AppAction.parse("needsyou://focus?level=off"))
        XCTAssertNil(AppAction.parse("needsyou://connect?hub=x&code=y"))
        XCTAssertNil(LinkRowPolicy.destination(ItemLink(label: "Terminal", url: s)))

        let item = Item(id: "a", key: "agent:h:x", priority: .normal, title: "Claude needs permission",
                        links: [ItemLink(label: "Terminal", url: s)], createdAt: Date())
        guard case .open(let url) = MenuItemAction.forItem(item) else { return XCTFail("not open") }
        XCTAssertEqual(TerminalJump.parse(url)?.target, .pane(12))
    }

    func testActionTableMatchesParsers() {
        // Every path in the table (mirrored by the hub, tests/test_link_mirror.py) has a parser.
        XCTAssertEqual(LinkPolicy.appActionPaths, ["orca/terminal", "terminal/focus", "app/activate"])
        XCTAssertEqual("\(OrcaJump.host)\(OrcaJump.path)", LinkPolicy.appActionPaths[0])
        XCTAssertEqual("\(TerminalJump.host)\(TerminalJump.path)", LinkPolicy.appActionPaths[1])
        XCTAssertEqual("\(AppActivation.host)\(AppActivation.path)", LinkPolicy.appActionPaths[2])
    }

    func testScriptIsFixedAndHasEachHandler() {
        for q in ["app=iterm&session=\(uuid)", "app=iterm&tty=/dev/ttys004", "app=terminal&tty=/dev/ttys012"] {
            let call = jump(q)!.appleScriptCall!
            let found = TerminalJumpScript.source(forHandler: call.handler)
            XCTAssertNotNil(found, q)
            XCTAssertTrue(found!.source.contains("on \(call.handler)("), q)
            XCTAssertEqual(found!.app, jump(q)!.app, q)
        }
        XCTAssertNil(TerminalJumpScript.source(forHandler: "run"))
        for src in [TerminalJumpScript.iTermSource, TerminalJumpScript.terminalSource] {
            XCTAssertFalse(src.contains("do shell script"))
            XCTAssertFalse(src.contains("run script"))
            XCTAssertFalse(src.contains("\\("))       // no Swift interpolation left in it
            XCTAssertTrue(src.contains("with timeout of 5 seconds"))
        }
    }

    func testAutomationPermissionStatus() {
        XCTAssertEqual(AutomationPermission(status: 0), .allowed)
        XCTAssertEqual(AutomationPermission(status: -1743), .denied)
        XCTAssertEqual(AutomationPermission(status: -1744), .notAskedYet)
        XCTAssertEqual(AutomationPermission(status: -600), .appNotRunning)
        XCTAssertEqual(AutomationPermission(status: -50), .other(-50))
        XCTAssertTrue(AutomationPermission.denied.describe(.iterm).hasPrefix("iTerm2: not allowed"))
    }
}
