#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// needsyou://app/activate?bundle=<id>: only ids on the fixed list, exactly one parameter,
/// never Needs You itself.
final class AppActivationTests: XCTestCase {
    static var allTests = [
        ("testParsesListedApps", testParsesListedApps),
        ("testRefusesEverythingElse", testRefusesEverythingElse),
        ("testNeverThisApp", testNeverThisApp),
        ("testRoundTripAndPolicy", testRoundTripAndPolicy),
        ("testButtonIsNamedForTheApp", testButtonIsNamedForTheApp),
    ]

    let base = "needsyou://app/activate?bundle="

    func testParsesListedApps() {
        for id in ["net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92",
                   "com.jetbrains.pycharm", "com.apple.Terminal"] {
            XCTAssertEqual(AppActivation.parse(base + id)?.bundleID, id, id)
        }
        XCTAssertEqual(AppActivation.parse("NEEDSYOU://APP/ACTIVATE?bundle=dev.zed.Zed")?.bundleID, "dev.zed.Zed")
        XCTAssertEqual(AppActivation.parse(base + "dev.zed.Zed")?.displayName, "Zed")
    }

    func testRefusesEverythingElse() {
        for s in [
            base + "com.example.app",            // not on the list
            base + "COM.APPLE.TERMINAL",         // exact match only
            base + "com.apple.terminal",
            base + "",
            base + "com.apple.Terminal&x=1",
            base + "com.apple.Terminal&bundle=dev.zed.Zed",
            base + "com%2Eapple.Terminal",
            base + "com.apple.Terminal%00",
            base + "com.apple.Terminal#x",
            base + "-com.apple.Terminal",
            base + "com.apple.Terminal x",
            base + "com.apple.Terminal ",       // nothing is trimmed (the hub refuses these too)
            " " + base + "com.apple.Terminal",
            base + "com.apple.Terminal\u{200B}",
            "needsyou://app/activate?id=com.apple.Terminal",
            "needsyou://app/activate",
            "needsyou://app/open?bundle=com.apple.Terminal",
            "needsyou://app?bundle=com.apple.Terminal",
            "needsyou://u@app/activate?bundle=com.apple.Terminal",
            "needsyou://app:1/activate?bundle=com.apple.Terminal",
            "https://app/activate?bundle=com.apple.Terminal",
            "needsyou://terminal/focus?app=ghostty",
        ] {
            XCTAssertNil(AppActivation.parse(s), s)
        }
    }

    func testNeverThisApp() {
        XCTAssertNil(AppActivation(bundleID: AppIdentity.bundleID))
        XCTAssertNil(AppActivation.parse(base + AppIdentity.bundleID))
        XCTAssertNil(AppActivation.allowedApps[AppIdentity.bundleID])
        XCTAssertNil(AppActivation(bundleID: "com.example.app"))
    }

    func testRoundTripAndPolicy() {
        let s = base + "net.kovidgoyal.kitty"
        let a = AppActivation.parse(s)!
        XCTAssertEqual(a.url.absoluteString, s)
        XCTAssertEqual(AppActivation.parse(a.url), a)
        XCTAssertTrue(LinkPolicy.isAllowed(s))
        XCTAssertNil(LinkPolicy.externalURL(s))   // never handed to NSWorkspace
        XCTAssertEqual(AppAction.parse(s), .activate(a))
        XCTAssertFalse(LinkPolicy.isAllowed(base + "com.example.app"))
        for (id, _) in AppActivation.allowedApps {
            XCTAssertEqual(AppActivation.parse(base + id)?.bundleID, id, id)
        }
    }

    func testButtonIsNamedForTheApp() {
        XCTAssertEqual(LinkRowPolicy.label(ItemLink(label: "Terminal", url: base + "dev.zed.Zed"), maxLength: nil), "Zed")
        XCTAssertEqual(LinkRowPolicy.actionName(base + "net.kovidgoyal.kitty"), "kitty")
        XCTAssertNil(LinkRowPolicy.actionName(base + "com.example.app"))
        XCTAssertNil(LinkRowPolicy.destination(ItemLink(label: "kitty", url: base + "net.kovidgoyal.kitty")))
        // "Answer in the terminal" goes to the same button
        let item = Item(id: "a", key: "agent:h:x", priority: .normal, title: "Claude is waiting",
                        links: [ItemLink(label: "kitty", url: base + "net.kovidgoyal.kitty")], createdAt: Date())
        XCTAssertEqual(AnswerPolicy.terminalLink(item)?.url, base + "net.kovidgoyal.kitty")
    }
}
