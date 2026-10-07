#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// The configurable shortcut: parsing, formatting, validation, and what pressing it does.
final class HotKeyComboTests: XCTestCase {
    static var allTests = [
        ("testStandardIsControlOptionSpace", testStandardIsControlOptionSpace),
        ("testFormatAndStorageRoundTrip", testFormatAndStorageRoundTrip),
        ("testParseFriendlySpellings", testParseFriendlySpellings),
        ("testParseRejectsJunk", testParseRejectsJunk),
        ("testModifierRequired", testModifierRequired),
        ("testReservedShortcuts", testReservedShortcuts),
        ("testStoredFallsBack", testStoredFallsBack),
        ("testMenuKeyEquivalent", testMenuKeyEquivalent),
        ("testHotKeyAction", testHotKeyAction),
    ]

    private let c = HotKeyCombo.command, s = HotKeyCombo.shift, o = HotKeyCombo.option, k = HotKeyCombo.control

    func testStandardIsControlOptionSpace() {
        // The Carbon values RegisterEventHotKey expects (Events.h).
        XCTAssertEqual(HotKeyCombo.command, 256)
        XCTAssertEqual(HotKeyCombo.shift, 512)
        XCTAssertEqual(HotKeyCombo.option, 2048)
        XCTAssertEqual(HotKeyCombo.control, 4096)
        XCTAssertEqual(KeyNames.space, 49)
        XCTAssertEqual(HotKeyCombo.standard, HotKeyCombo(keyCode: 49, modifiers: k | o))
        XCTAssertEqual(HotKeyCombo.standard.display, "⌃⌥Space")
        XCTAssertEqual(HotKeyCombo.standard.storageString, "control+option+space")
        XCTAssertTrue(HotKeyValidator.isValid(.standard))
    }

    func testFormatAndStorageRoundTrip() {
        let combo = HotKeyCombo(keyCode: KeyNames.letter("k")!, modifiers: c | s | o | k)
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘K")
        XCTAssertEqual(combo.storageString, "control+option+shift+command+k")
        XCTAssertEqual(HotKeyCombo.parse(combo.storageString), combo)
        XCTAssertEqual(HotKeyCombo.parse(combo.display), combo)

        let f5 = HotKeyCombo(keyCode: 0x60, modifiers: o)
        XCTAssertEqual(f5.display, "⌥F5")
        XCTAssertEqual(HotKeyCombo.parse(f5.storageString), f5)
        let digit = HotKeyCombo(keyCode: KeyNames.digit(7)!, modifiers: c | o)
        XCTAssertEqual(digit.display, "⌥⌘7")
        XCTAssertEqual(HotKeyCombo.parse(digit.storageString), digit)
        // Every named key round-trips.
        for code in UInt32(0)...UInt32(0x7F) where KeyNames.display(code) != nil {
            let combo = HotKeyCombo(keyCode: code, modifiers: k | o)
            XCTAssertEqual(HotKeyCombo.parse(combo.storageString), combo, "key code \(code)")
        }
        // Unknown modifier bits are dropped.
        XCTAssertEqual(HotKeyCombo(keyCode: 49, modifiers: k | o | 1).modifiers, k | o)
    }

    func testParseFriendlySpellings() {
        XCTAssertEqual(HotKeyCombo.parse("ctrl+opt+space"), .standard)
        XCTAssertEqual(HotKeyCombo.parse(" Control + Option + Space "), .standard)
        XCTAssertEqual(HotKeyCombo.parse("⌃⌥Space"), .standard)
        XCTAssertEqual(HotKeyCombo.parse("cmd+shift+k"), HotKeyCombo(keyCode: KeyNames.letter("k")!, modifiers: c | s))
        XCTAssertEqual(HotKeyCombo.parse("alt+esc"), HotKeyCombo(keyCode: KeyNames.escape, modifiers: o))
        XCTAssertEqual(HotKeyCombo.parse("control+code49"), HotKeyCombo(keyCode: 49, modifiers: k))
    }

    func testParseRejectsJunk() {
        XCTAssertNil(HotKeyCombo.parse(""))
        XCTAssertNil(HotKeyCombo.parse("control+option+"))
        XCTAssertNil(HotKeyCombo.parse("hyper+space"))
        XCTAssertNil(HotKeyCombo.parse("control+notakey"))
        XCTAssertNil(HotKeyCombo.parse("control+code999"))
    }

    func testModifierRequired() {
        let space = KeyNames.space
        XCTAssertEqual(HotKeyValidator.problem(with: HotKeyCombo(keyCode: space, modifiers: 0)), .needsModifier)
        XCTAssertEqual(HotKeyValidator.problem(with: HotKeyCombo(keyCode: KeyNames.letter("a")!, modifiers: s)), .needsModifier)
        XCTAssertNil(HotKeyValidator.problem(with: HotKeyCombo(keyCode: KeyNames.letter("a")!, modifiers: k | s)))
        XCTAssertNil(HotKeyValidator.problem(with: HotKeyCombo(keyCode: 0x60, modifiers: o)))
        // Escape alone closes the panel, and keys without a name can't be shown.
        XCTAssertEqual(HotKeyValidator.problem(with: HotKeyCombo(keyCode: KeyNames.escape, modifiers: 0)), .unsupportedKey)
        XCTAssertEqual(HotKeyValidator.problem(with: HotKeyCombo(keyCode: 0x7F, modifiers: k)), .unsupportedKey)
        XCTAssertFalse(HotKeyProblem.needsModifier.message.isEmpty)
    }

    func testReservedShortcuts() {
        func problem(_ key: UInt32, _ mods: UInt32) -> HotKeyProblem? {
            HotKeyValidator.problem(with: HotKeyCombo(keyCode: key, modifiers: mods))
        }
        XCTAssertEqual(problem(KeyNames.space, c), .reserved("Spotlight"))
        XCTAssertEqual(problem(KeyNames.space, k), .reserved("input source switching"))
        XCTAssertEqual(problem(KeyNames.tab, c), .reserved("the app switcher"))
        XCTAssertEqual(problem(KeyNames.letter("q")!, c), .reserved("Quit in every app"))
        XCTAssertEqual(problem(KeyNames.digit(4)!, c | s), .reserved("a screenshot shortcut"))
        XCTAssertEqual(problem(KeyNames.escape, c | o), .reserved("Force Quit"))
        XCTAssertTrue(HotKeyProblem.reserved("Spotlight").message.contains("Spotlight"))
        // Ours, and nearby combinations, are fine.
        XCTAssertNil(problem(KeyNames.space, k | o))
        XCTAssertNil(problem(KeyNames.space, k | o | c))
        XCTAssertNil(problem(KeyNames.letter("q")!, c | o | s))
        for (combo, _) in HotKeyValidator.reserved {
            XCTAssertNotEqual(combo, .standard)
        }
    }

    func testStoredFallsBack() {
        XCTAssertEqual(HotKeyValidator.stored(nil), .standard)
        XCTAssertEqual(HotKeyValidator.stored("garbage"), .standard)
        XCTAssertEqual(HotKeyValidator.stored("command+space"), .standard)   // reserved
        XCTAssertEqual(HotKeyValidator.stored("space"), .standard)           // no modifier
        XCTAssertEqual(HotKeyValidator.stored("control+option+n"),
                       HotKeyCombo(keyCode: KeyNames.letter("n")!, modifiers: k | o))
    }

    func testMenuKeyEquivalent() {
        XCTAssertEqual(HotKeyCombo.standard.menuKeyEquivalent, " ")
        XCTAssertEqual(HotKeyCombo(keyCode: KeyNames.letter("k")!, modifiers: c).menuKeyEquivalent, "k")
        XCTAssertEqual(HotKeyCombo(keyCode: KeyNames.digit(3)!, modifiers: c).menuKeyEquivalent, "3")
        XCTAssertEqual(HotKeyCombo(keyCode: 0x2C, modifiers: c).menuKeyEquivalent, "/")
        XCTAssertNil(HotKeyCombo(keyCode: 0x60, modifiers: c).menuKeyEquivalent)     // F5
        XCTAssertNil(HotKeyCombo(keyCode: 0x7B, modifiers: c).menuKeyEquivalent)     // ←
        XCTAssertNil(HotKeyCombo(keyCode: KeyNames.returnKey, modifiers: c).menuKeyEquivalent)
    }

    func testHotKeyAction() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let linked = Item(id: "a", key: "a", title: "PR", links: [ItemLink(label: "PR", url: "https://example.com/pr")], createdAt: now)
        let jump = Item(id: "j", key: "j", title: "Agent", links: [ItemLink(label: "Terminal", url: "needsyou://orca/terminal?handle=term_1")], createdAt: now)
        let bare = Item(id: "b", key: "b", title: "No link", createdAt: now)
        let blocked = Item(id: "x", key: "x", title: "Bad", links: [ItemLink(label: "x", url: "file:///etc/passwd")], createdAt: now)

        // Off (the default): always show / hide.
        XCTAssertEqual(HotKeyAction.decide(openTopLink: false, top: linked), .toggleVisibility)
        // On: open the top card's first allowed link.
        XCTAssertEqual(HotKeyAction.decide(openTopLink: true, top: linked), .openTopCard(linked))
        // On, but nothing to open: show / hide as usual.
        XCTAssertEqual(HotKeyAction.decide(openTopLink: true, top: nil), .toggleVisibility)
        XCTAssertEqual(HotKeyAction.decide(openTopLink: true, top: bare), .toggleVisibility)
        XCTAssertEqual(HotKeyAction.decide(openTopLink: true, top: blocked), .toggleVisibility)
        if case .open = MenuItemAction.forItem(jump) {
            XCTAssertEqual(HotKeyAction.decide(openTopLink: true, top: jump), .openTopCard(jump))
        }
    }
}
