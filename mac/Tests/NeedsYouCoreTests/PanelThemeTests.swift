#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Themes: the default is the original look, every theme keeps text and urgent legible and
/// urgent distinct in both appearances (WCAG contrast, numerically), and the stored choice
/// and accent fall back safely.
final class PanelThemeTests: XCTestCase {
    static var allTests = [
        ("testDefaultIsTheOriginalLook", testDefaultIsTheOriginalLook),
        ("testContrastMath", testContrastMath),
        ("testEveryThemeIsLegible", testEveryThemeIsLegible),
        ("testUrgentStaysDistinct", testUrgentStaysDistinct),
        ("testHighContrastIsHigher", testHighContrastIsHigher),
        ("testFollowingTheSystem", testFollowingTheSystem),
        ("testAccentOverride", testAccentOverride),
        ("testAccentStorage", testAccentStorage),
        ("testPrefsRoundTripAndFallback", testPrefsRoundTripAndFallback),
    ]

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = TestDefaults.suiteName(Self.self)
        store = TestDefaults.make(suite)
    }

    override func tearDown() {
        TestDefaults.clear(suite)
    }

    /// Every palette a user can end up with: each theme in dark and light macOS.
    private var allPalettes: [(String, PanelPalette)] {
        PanelTheme.allCases.flatMap { theme in
            [true, false].map { dark in ("\(theme.rawValue)/\(dark ? "dark" : "light")", theme.palette(systemIsDark: dark)) }
        }
    }

    func testDefaultIsTheOriginalLook() {
        XCTAssertEqual(UIPrefs.defaults.theme, .standard)
        XCTAssertEqual(UIPrefs.defaults.accent, .theme)
        XCTAssertEqual(PanelTheme.standard.rawValue, "default")
        let p = UIPrefs.defaults.palette(systemIsDark: false)
        XCTAssertEqual(p, PanelTheme.standardPalette, "the default ignores macOS's appearance, as before")
        // red 400, amber 300, slate 400; white text at 55% and 35%; hairline 8%, card 5%.
        XCTAssertEqual(p.urgent.hexString, "#F87171")
        XCTAssertEqual(p.normal.hexString, "#FCD34D")
        XCTAssertEqual(p.low.hexString, "#94A3B8")
        XCTAssertEqual(p.accent, p.normal, "accented bits were amber")
        XCTAssertEqual(p.text, .white)
        XCTAssertEqual(p.mutedOpacity, 0.55)
        XCTAssertEqual(p.faintOpacity, 0.35)
        XCTAssertEqual(p.hairlineOpacity, 0.08)
        XCTAssertEqual(p.cardFillOpacity, 0.05)
        XCTAssertEqual(p.backdrop, .black)
        XCTAssertEqual(p.backdropOpacity(0.3), 0.3)
        XCTAssertEqual(p.tintOpacity, 0)
        XCTAssertTrue(p.isDark)
    }

    func testContrastMath() {
        XCTAssertTrue(abs(ThemeRGB.white.contrast(with: .black) - 21) < 0.01)
        XCTAssertTrue(abs(ThemeRGB.white.contrast(with: .white) - 1) < 0.0001)
        XCTAssertEqual(ThemeRGB(hex: 0xFF0000).hue, 0)
        XCTAssertEqual(ThemeRGB(hex: 0x00FF00).hue, 120)
        XCTAssertEqual(ThemeRGB.white.over(.black, alpha: 0.5), ThemeRGB(0.5, 0.5, 0.5))
        XCTAssertEqual(ThemeRGB(hexString: "#3b82f6")?.hexString, "#3B82F6")
        XCTAssertNil(ThemeRGB(hexString: "#12345"))
        XCTAssertNil(ThemeRGB(hexString: "zzzzzz"))
    }

    func testEveryThemeIsLegible() {
        XCTAssertEqual(PanelTheme.allCases.count, 8)
        for (name, p) in allPalettes {
            XCTAssertTrue(p.text.contrast(with: p.surface) >= 7, "\(name): text")
            XCTAssertTrue(p.mutedOnSurface.contrast(with: p.surface) >= 4.5, "\(name): muted text")
            XCTAssertTrue(p.faintOnSurface.contrast(with: p.surface) >= 3, "\(name): faint text")
            XCTAssertTrue(p.urgent.contrast(with: p.surface) >= 4.5, "\(name): urgent")
            XCTAssertTrue(p.normal.contrast(with: p.surface) >= 3, "\(name): normal")
            XCTAssertTrue(p.low.contrast(with: p.surface) >= 3, "\(name): low")
            XCTAssertTrue(p.accent.contrast(with: p.surface) >= ThemeAccent.minimumContrast, "\(name): accent")
            // Light text on dark glass, dark on light.
            XCTAssertEqual(p.isDark, p.text.luminance > p.surface.luminance, name)
            XCTAssertEqual(p.isDark, p.backdrop == .black, name)
            XCTAssertTrue((0...1).contains(p.tintOpacity) && (0...1).contains(p.backdropFloor), name)
        }
    }

    func testUrgentStaysDistinct() {
        for (name, p) in allPalettes {
            // Red, whatever the theme.
            XCTAssertTrue(p.urgent.hue <= 15 || p.urgent.hue >= 330, "\(name): urgent is red (\(p.urgent.hue))")
            XCTAssertTrue(p.urgent.distance(to: p.normal) >= 0.25, "\(name): urgent vs normal")
            XCTAssertTrue(p.urgent.distance(to: p.low) >= 0.25, "\(name): urgent vs low")
            XCTAssertTrue(p.normal.distance(to: p.low) >= 0.2, "\(name): normal vs low")
        }
    }

    func testHighContrastIsHigher() {
        for dark in [true, false] {
            let p = PanelTheme.highContrast.palette(systemIsDark: dark)
            XCTAssertTrue(p.text.contrast(with: p.surface) >= 15)
            XCTAssertTrue(p.mutedOnSurface.contrast(with: p.surface) >= 7)
            XCTAssertTrue(p.urgent.contrast(with: p.surface) >= 7)
            XCTAssertTrue(p.backdropOpacity(0) >= 0.6, "a dark (or light) layer behind the glass whatever the setting")
            XCTAssertEqual(p.backdropOpacity(0.75), 0.75)
        }
    }

    func testFollowingTheSystem() {
        XCTAssertEqual(PanelTheme.system.palette(systemIsDark: true), PanelTheme.standardPalette)
        XCTAssertEqual(PanelTheme.system.palette(systemIsDark: false), PanelTheme.paper.palette())
        XCTAssertFalse(PanelTheme.paper.palette(systemIsDark: true).isDark)
        XCTAssertTrue(PanelTheme.midnight.palette(systemIsDark: false).isDark)
        XCTAssertEqual(PanelTheme.allCases.filter(\.followsSystem), [.system, .highContrast])
        for theme in PanelTheme.allCases where !theme.followsSystem {
            XCTAssertEqual(theme.palette(systemIsDark: true), theme.palette(systemIsDark: false), theme.rawValue)
        }
    }

    func testAccentOverride() {
        let base = PanelTheme.paper.palette()
        let blue = PanelTheme.paper.palette(accent: .preset(.blue))
        XCTAssertEqual(blue.accent, ThemeAccent.Preset.blue.color)
        // Only the accent changes: priorities never do.
        var same = blue
        same.accent = base.accent
        XCTAssertEqual(same, base)
        // An accent that wouldn't read is nudged until it does, on every theme.
        for (name, p) in allPalettes {
            for color in [ThemeRGB.black, .white, ThemeRGB(hex: 0xFFFF00), p.surface] + ThemeAccent.Preset.allCases.map(\.color) {
                let a = p.withAccent(color).accent
                XCTAssertTrue(a.contrast(with: p.surface) >= ThemeAccent.minimumContrast, "\(name): \(color.hexString) → \(a.hexString)")
            }
        }
        XCTAssertEqual(PanelTheme.standard.palette(accent: .theme), PanelTheme.standardPalette)
    }

    func testAccentStorage() {
        XCTAssertEqual(ThemeAccent(stored: nil), .theme)
        XCTAssertEqual(ThemeAccent(stored: ""), .theme)
        XCTAssertEqual(ThemeAccent(stored: "pink"), .preset(.pink))
        XCTAssertEqual(ThemeAccent(stored: "#10B981"), .custom(ThemeRGB(hex: 0x10B981)))
        XCTAssertEqual(ThemeAccent(stored: "10B981"), .theme, "a bare hex isn't a stored custom colour")
        XCTAssertEqual(ThemeAccent(stored: "chartreuse"), .theme)
        XCTAssertEqual(ThemeAccent(stored: "#GG0000"), .theme)
        for accent in [ThemeAccent.theme, .preset(.teal), .custom(ThemeRGB(hex: 0x123456))] {
            XCTAssertEqual(ThemeAccent(stored: accent.storageString), accent)
        }
    }

    func testPrefsRoundTripAndFallback() {
        XCTAssertEqual(UIPrefs.load(from: store).theme, .standard)
        var p = UIPrefs()
        p.theme = .midnight
        p.accent = .custom(ThemeRGB(hex: 0x22C55E))
        p.save(to: store, previous: UIPrefs())
        XCTAssertEqual(Set((store.persistentDomain(forName: suite) ?? [:]).keys), [UIPrefs.Key.theme, UIPrefs.Key.accent])
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.theme), "midnight")
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.accent), "#22C55E")
        XCTAssertEqual(UIPrefs.load(from: store), p)
        store.set("neon", forKey: UIPrefs.Key.theme)
        store.set("rainbow", forKey: UIPrefs.Key.accent)
        let loaded = UIPrefs.load(from: store)
        XCTAssertEqual(loaded.theme, .standard)
        XCTAssertEqual(loaded.accent, .theme)
    }
}
