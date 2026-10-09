#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import Foundation
import NeedsYouCore

/// Settings → Appearance → Theme → Accent colour and Background, and macOS's Increase
/// Contrast: the defaults are today's look, stored values fall back safely, no accent can
/// ever stand in for (or pass for) urgent's red, and Solid and Increase Contrast keep text
/// and meters readable in every theme, light and dark.
final class PanelColourTests: XCTestCase {
    static var allTests = [
        ("testDefaultsAreToday", testDefaultsAreToday),
        ("testStoredValuesFallBack", testStoredValuesFallBack),
        ("testBackgroundRoundTrip", testBackgroundRoundTrip),
        ("testUrgentIsNeverOverridden", testUrgentIsNeverOverridden),
        ("testRedAccentsAreRefused", testRedAccentsAreRefused),
        ("testPresetsAreSafeEverywhere", testPresetsAreSafeEverywhere),
        ("testSolidIsReadable", testSolidIsReadable),
        ("testSolidIsAlwaysOpaque", testSolidIsAlwaysOpaque),
        ("testIncreaseContrast", testIncreaseContrast),
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

    /// Every palette a user can end up with: each theme, dark and light macOS, with and
    /// without Increase Contrast.
    private var allPalettes: [(String, PanelPalette)] {
        PanelTheme.allCases.flatMap { theme in
            [true, false].flatMap { dark in
                [false, true].map { increase in
                    ("\(theme.rawValue)/\(dark ? "dark" : "light")\(increase ? "/increase" : "")",
                     theme.palette(systemIsDark: dark, accent: .theme, increaseContrast: increase))
                }
            }
        }
    }

    /// Accents a person could pick: the presets, reds and near-reds, greys, and a sweep of
    /// hues at three strengths.
    private var accentsToTry: [ThemeRGB] {
        var colours = ThemeAccent.Preset.allCases.map(\.color)
        colours += [0xFF0000, 0xEF4444, 0xF87171, 0xB91C1C, 0xFB7185, 0xEC4899, 0xF97316, 0xFF7A7A, 0xA50E0E, 0xE11D48]
            .map { ThemeRGB(hex: $0) }
        colours += [.white, .black, ThemeRGB(0.5, 0.5, 0.5)]
        for step in 0..<24 {
            let h = Double(step) * 15
            for (s, v) in [(1.0, 1.0), (0.6, 0.8), (0.9, 0.5)] {
                colours.append(Self.hsv(h, s, v))
            }
        }
        return colours
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> ThemeRGB {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return ThemeRGB(r + m, g + m, b + m)
    }

    func testDefaultsAreToday() {
        let ui = UIPrefs.defaults
        XCTAssertEqual(ui.accent, .theme)
        XCTAssertEqual(ui.background, .glass)
        XCTAssertEqual(PanelBackground.glass.rawValue, "glass")
        // The palette is the original one, without Increase Contrast.
        let p = ui.palette(systemIsDark: true)
        XCTAssertEqual(p, PanelTheme.standardPalette)
        XCTAssertFalse(p.increasedContrast)
        XCTAssertEqual(p.borderWidth, 0.5)
        XCTAssertEqual(p.quietMeterOpacity, 0.55)
        XCTAssertEqual(p.accentMinimumContrast, ThemeAccent.minimumContrast)
        // Glass keeps the Opacity settings exactly: 85 % pill at rest, 100 % otherwise.
        XCTAssertEqual(ui.pillAlpha(hovering: false), 0.85)
        XCTAssertEqual(ui.pillAlpha(hovering: true), 1)
        XCTAssertEqual(ui.panelAlpha(hovering: false), 1)
        for rest in PanelOpacity.choices {
            for hovering in [false, true] {
                var g = UIPrefs()
                g.pillOpacity = rest
                g.panelOpacity = rest
                XCTAssertEqual(g.pillAlpha(hovering: hovering),
                               PanelOpacity.alpha(rest: rest, hover: g.pillHoverOpacity, hovering: hovering))
                XCTAssertEqual(g.panelAlpha(hovering: hovering),
                               PanelOpacity.alpha(rest: rest, hover: g.panelHoverOpacity, hovering: hovering))
            }
        }
        // Nothing stored: nothing changes.
        XCTAssertEqual(UIPrefs.load(from: store), UIPrefs.defaults)
    }

    func testStoredValuesFallBack() {
        store.set("frosted", forKey: UIPrefs.Key.background)
        XCTAssertEqual(UIPrefs.load(from: store).background, .glass)
        store.set(3, forKey: UIPrefs.Key.background)
        XCTAssertEqual(UIPrefs.load(from: store).background, .glass)
        // Pink and Orange were offered up to 0.5 and came too close to urgent: the theme's own now.
        for old in ["pink", "orange", "red", "rainbow", "#12", "FF0000"] {
            XCTAssertEqual(ThemeAccent(stored: old), .theme, old)
        }
        // Every swatch still stored under the name it always had.
        for preset in ThemeAccent.Preset.allCases {
            XCTAssertEqual(ThemeAccent(stored: preset.rawValue), .preset(preset))
        }
        XCTAssertEqual(ThemeAccent.Preset.allCases.map(\.rawValue), ["blue", "purple", "green", "teal", "graphite"])
    }

    func testBackgroundRoundTrip() {
        var p = UIPrefs()
        p.background = .solid
        p.save(to: store, previous: UIPrefs())
        XCTAssertEqual(Set((store.persistentDomain(forName: suite) ?? [:]).keys), [UIPrefs.Key.background])
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.background), "solid")
        XCTAssertEqual(UIPrefs.load(from: store), p)
    }

    /// The model's promise: whatever accent is picked, urgent keeps its colour, and the
    /// accent drawn never looks like it.
    func testUrgentIsNeverOverridden() {
        for (name, base) in allPalettes {
            for colour in accentsToTry + [base.urgent] {
                let p = base.withAccent(colour)
                XCTAssertEqual(p.urgent, base.urgent, "\(name): \(colour.hexString)")
                XCTAssertEqual(p.normal, base.normal, "\(name): \(colour.hexString)")
                XCTAssertEqual(p.low, base.low, "\(name): \(colour.hexString)")
                XCTAssertEqual(p.color(.urgent), base.urgent)
                XCTAssertNotEqual(p.accent, p.urgent, "\(name): \(colour.hexString)")
                XCTAssertFalse(ThemeAccent.looksUrgent(p.accent, urgent: p.urgent), "\(name): \(colour.hexString) → \(p.accent.hexString)")
                XCTAssertTrue(p.accent.contrast(with: p.surface) >= p.accentMinimumContrast, "\(name): \(colour.hexString) → \(p.accent.hexString)")
                // Only the accent may differ.
                var same = p
                same.accent = base.accent
                XCTAssertEqual(same, base, name)
            }
        }
        // And through the settings, for a stored custom red.
        var ui = UIPrefs()
        ui.accent = .custom(ThemeRGB(hex: 0xFF0000))
        for dark in [true, false] {
            for increase in [false, true] {
                let p = ui.palette(systemIsDark: dark, increaseContrast: increase)
                XCTAssertEqual(p.accent, PanelTheme.standard.palette(systemIsDark: dark, accent: .theme, increaseContrast: increase).accent)
            }
        }
    }

    func testRedAccentsAreRefused() {
        let p = PanelTheme.standardPalette
        for hex: UInt32 in [0xFF0000, 0xEF4444, 0xEC4899, 0xF97316, 0xE11D48] {
            XCTAssertTrue(p.refusesAccent(ThemeRGB(hex: hex)), String(hex, radix: 16))
            XCTAssertEqual(p.withAccent(ThemeRGB(hex: hex)), p, "the theme's own accent stays")
        }
        // Greys are never refused (they can't pass for red), nor is the theme's own amber.
        XCTAssertFalse(p.refusesAccent(ThemeRGB(0.5, 0.5, 0.5)))
        XCTAssertFalse(p.refusesAccent(ThemeRGB(hex: 0x8E8E93)))
        XCTAssertFalse(ThemeAccent.looksUrgent(p.accent, urgent: p.urgent))
        XCTAssertFalse(p.refusesAccent(ThemeRGB(hex: 0x3B82F6)))
    }

    /// Every swatch applies in every theme (never refused), reads, and is far from red; so
    /// does every theme's own accent.
    func testPresetsAreSafeEverywhere() {
        for (name, base) in allPalettes {
            XCTAssertFalse(ThemeAccent.looksUrgent(base.accent, urgent: base.urgent), "\(name): theme's own accent")
            for preset in ThemeAccent.Preset.allCases {
                XCTAssertFalse(base.refusesAccent(preset.color), "\(name): \(preset.rawValue)")
                let a = base.withAccent(preset.color).accent
                XCTAssertTrue(a.contrast(with: base.surface) >= base.accentMinimumContrast, "\(name): \(preset.rawValue)")
                XCTAssertTrue(a.distance(to: base.urgent) >= 0.3, "\(name): \(preset.rawValue) vs urgent")
            }
        }
        // Different enough from each other to tell apart in the row.
        let colours = ThemeAccent.Preset.allCases.map(\.color)
        for (i, a) in colours.enumerated() {
            for b in colours[(i + 1)...] { XCTAssertTrue(a.distance(to: b) >= 0.25, "\(a.hexString) vs \(b.hexString)") }
        }
    }

    /// Solid draws the theme's surface, opaque, so these contrasts are exact (on glass they
    /// depend on what's behind).
    func testSolidIsReadable() {
        for (name, base) in allPalettes {
            for accent in [nil] + ThemeAccent.Preset.allCases.map(\.color) {
                let p = accent.map { base.withAccent($0) } ?? base
                let s = p.surface
                XCTAssertTrue(p.text.contrast(with: s) >= 7, "\(name): text")
                XCTAssertTrue(p.mutedOnSurface.contrast(with: s) >= 4.5, "\(name): muted")
                XCTAssertTrue(p.faintOnSurface.contrast(with: s) >= 3, "\(name): faint")
                XCTAssertTrue(p.urgent.contrast(with: s) >= 4.5, "\(name): urgent")
                XCTAssertTrue(p.normal.contrast(with: s) >= 3, "\(name): normal")
                XCTAssertTrue(p.low.contrast(with: s) >= 3, "\(name): low")
                XCTAssertTrue(p.accent.contrast(with: s) >= p.accentMinimumContrast, "\(name): accent")
                // Usage meters: quiet in the text colour, then normal (warning) and urgent (full).
                XCTAssertTrue(p.text.over(s, alpha: p.quietMeterOpacity).contrast(with: s) >= 3, "\(name): quiet meter")
                XCTAssertTrue(p.normal.contrast(with: s) >= 3, "\(name): warning meter")
            }
        }
    }

    func testSolidIsAlwaysOpaque() {
        var ui = UIPrefs()
        ui.background = .solid
        for rest in PanelOpacity.choices {
            ui.pillOpacity = rest
            ui.pillHoverOpacity = rest
            ui.panelOpacity = rest
            ui.panelHoverOpacity = rest
            for hovering in [false, true] {
                XCTAssertEqual(ui.pillAlpha(hovering: hovering), 1)
                XCTAssertEqual(ui.panelAlpha(hovering: hovering), 1)
            }
        }
        XCTAssertEqual(PanelBackground.glass.alpha(0.4), 0.4)
        XCTAssertEqual(PanelBackground.solid.alpha(0.4), 1)
    }

    func testIncreaseContrast() {
        for theme in PanelTheme.allCases {
            for dark in [true, false] {
                let base = theme.palette(systemIsDark: dark)
                let p = theme.palette(systemIsDark: dark, accent: .theme, increaseContrast: true)
                let name = "\(theme.rawValue)/\(dark ? "dark" : "light")"
                XCTAssertTrue(p.increasedContrast)
                XCTAssertEqual(p.borderWidth, 1)
                XCTAssertEqual(p.quietMeterOpacity, 0.8)
                // Colours and the surface stay the theme's; only strength goes up.
                XCTAssertEqual(p.urgent, base.urgent, name)
                XCTAssertEqual(p.normal, base.normal, name)
                XCTAssertEqual(p.low, base.low, name)
                XCTAssertEqual(p.text, base.text, name)
                XCTAssertEqual(p.surface, base.surface, name)
                XCTAssertTrue(p.mutedOpacity >= base.mutedOpacity && p.faintOpacity >= base.faintOpacity, name)
                XCTAssertTrue(p.hairlineOpacity >= 0.4 && p.hairlineOpacity >= base.hairlineOpacity, name)
                XCTAssertTrue(p.mutedOnSurface.contrast(with: p.surface) >= 7, "\(name): muted")
                XCTAssertTrue(p.faintOnSurface.contrast(with: p.surface) >= 4.5, "\(name): faint")
                XCTAssertTrue(p.accent.contrast(with: p.surface) >= ThemeAccent.increasedMinimumContrast, "\(name): accent")
                // The glass gets a backdrop of at least 60 %, whatever Background darkness says.
                XCTAssertTrue(p.backdropOpacity(0) >= 0.6, name)
                XCTAssertEqual(p.backdropOpacity(0.75), 0.75)
                // Off, nothing changes.
                XCTAssertEqual(theme.palette(systemIsDark: dark, accent: .theme, increaseContrast: false), base)
            }
        }
    }
}
