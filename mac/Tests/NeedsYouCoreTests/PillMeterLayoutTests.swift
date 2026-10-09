#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
@testable import NeedsYouCore

/// The collapsed pill's usage meters (Settings → Usage → On the pill): the style pref, and
/// where bars, hairlines and percentages go at every pill size.
final class PillMeterLayoutTests: XCTestCase {
    static var allTests = [
        ("testStylePrefDefaultsPersistsAndFallsBack", testStylePrefDefaultsPersistsAndFallsBack),
        ("testNoMetersChangeNothing", testNoMetersChangeNothing),
        ("testBarsSitBelowTheCount", testBarsSitBelowTheCount),
        ("testBarsAreVisible", testBarsAreVisible),
        ("testBarsScaleWithEveryPillSize", testBarsScaleWithEveryPillSize),
        ("testHairlineAndPercentKeepTheSize", testHairlineAndPercentKeepTheSize),
        ("testIdleAlphaFloor", testIdleAlphaFloor),
    ]

    private let medium = PillMetrics.make(PanelStyle.regular, size: .medium)

    func testStylePrefDefaultsPersistsAndFallsBack() {
        let suite = TestDefaults.suiteName(Self.self)
        let store = TestDefaults.make(suite)
        defer { TestDefaults.clear(suite) }
        let fresh = UsagePrefs.load(from: store)
        XCTAssertEqual(fresh.pillStyle, .bars, "bars are the default: the hairlines were too faint to see")
        XCTAssertEqual(PillMeterStyle.allCases, [.bars, .hairline, .percent])
        XCTAssertEqual(PillMeterStyle.allCases.map(\.title), ["Bars", "Hairlines", "Percentages"])

        for style in PillMeterStyle.allCases {
            var p = fresh
            p.pillStyle = style
            p.save(to: store, previous: fresh)
            XCTAssertEqual(UsagePrefs.load(from: store).pillStyle, style)
            XCTAssertEqual(store.string(forKey: UsagePrefs.Key.pillStyle), style == .bars ? nil : style.rawValue,
                           "save writes only what changed")
            store.removeObject(forKey: UsagePrefs.Key.pillStyle)
        }
        // An unknown stored value (a newer build's style, a typo) falls back to bars.
        store.set("sparkline", forKey: UsagePrefs.Key.pillStyle)
        XCTAssertEqual(UsagePrefs.load(from: store).pillStyle, .bars)
        store.set(3, forKey: UsagePrefs.Key.pillStyle)
        XCTAssertEqual(UsagePrefs.load(from: store).pillStyle, .bars)
    }

    func testNoMetersChangeNothing() {
        for style in PillMeterStyle.allCases {
            let l = PillMeterLayout.make(style, count: 0, height: medium.height, font: medium.font)
            XCTAssertEqual(l.height, medium.height)
            XCTAssertEqual(l.contentHeight, medium.height)
            XCTAssertFalse(l.showsBars)
            XCTAssertFalse(l.showsPercent)
            XCTAssertEqual(l.band, 0)
        }
        // More than two windows still draws two.
        XCTAssertEqual(PillMeterLayout.make(.bars, count: 5, height: 22, font: 12).count, 2)
    }

    func testBarsSitBelowTheCount() {
        // Medium: one bar fits in the 22 pt pill; a second makes it 26.5.
        let one = PillMeterLayout.make(.bars, count: 1, height: medium.height, font: medium.font)
        XCTAssertEqual(one.height, 22)
        XCTAssertEqual(one.contentHeight, 16)
        let two = PillMeterLayout.make(.bars, count: 2, height: medium.height, font: medium.font)
        XCTAssertEqual(two.barHeight, 3)
        XCTAssertEqual(two.barGap, 1.5)
        XCTAssertEqual(two.bottomInset, 3)
        XCTAssertEqual(two.band, 10.5)
        XCTAssertEqual(two.height, 26.5)
        // The count's band and the bars never overlap, and the band holds a line of digits.
        for l in [one, two] {
            XCTAssertEqual(l.contentHeight + l.band, l.height)
            XCTAssertTrue(l.contentHeight >= ceil(medium.font * 1.2))
        }
    }

    func testBarsAreVisible() {
        let l = PillMeterLayout.make(.bars, count: 2, height: 22, font: 12)
        XCTAssertTrue(l.barHeight >= 3)
        XCTAssertTrue(l.fillOpacity >= 0.8)
        XCTAssertTrue(l.trackOpacity > 0.12, "a track behind the fill, so 31 % reads as a third")
        XCTAssertTrue(l.trackOpacity < l.fillOpacity)
        let hairline = PillMeterLayout.make(.hairline, count: 2, height: 22, font: 12)
        XCTAssertEqual(hairline.barHeight, 1)
        XCTAssertEqual(hairline.fillOpacity, 0.45, "the 0.3.2 look, unchanged")
    }

    func testBarsScaleWithEveryPillSize() {
        for panel in PanelSize.allCases {
            for size in PillSize.allCases {
                let m = PillMetrics.make(PanelStyle.metrics(panel), size: size)
                let l = PillMeterLayout.make(.bars, count: 2, height: m.height, font: m.font)
                XCTAssertTrue(l.barHeight >= 2, "\(panel) \(size)")
                XCTAssertTrue(l.contentHeight >= ceil(m.font * 1.2), "\(panel) \(size)")
                XCTAssertEqual(l.contentHeight + l.band, l.height, "\(panel) \(size)")
                // A few points taller at most: never a second row of text.
                XCTAssertTrue(l.height - m.height <= m.font * 0.6, "\(panel) \(size)")
                for v in [l.barHeight, l.barGap, l.bottomInset, l.height] {
                    XCTAssertEqual((v * 2).rounded(), v * 2, "half points: \(panel) \(size)")
                }
            }
            // The idle pill at rest and on hover.
            let pm = PanelStyle.metrics(panel)
            for h in [pm.idleHeight, pm.idleHoverHeight] {
                let l = PillMeterLayout.make(.bars, count: 2, height: h, font: pm.idleFont)
                XCTAssertTrue(l.contentHeight >= ceil(pm.idleFont * 1.2), "idle \(panel)")
                XCTAssertEqual(l.contentHeight + l.band, l.height, "idle \(panel)")
            }
        }
    }

    func testHairlineAndPercentKeepTheSize() {
        for style in [PillMeterStyle.hairline, .percent] {
            let l = PillMeterLayout.make(style, count: 2, height: medium.height, font: medium.font)
            XCTAssertEqual(l.height, medium.height)
            XCTAssertEqual(l.contentHeight, medium.height)
        }
        let hairline = PillMeterLayout.make(.hairline, count: 2, height: 22, font: 12)
        XCTAssertTrue(hairline.showsBars)
        XCTAssertFalse(hairline.showsPercent)
        XCTAssertEqual(hairline.bottomInset, 2)
        let percent = PillMeterLayout.make(.percent, count: 2, height: 22, font: 12)
        XCTAssertFalse(percent.showsBars)
        XCTAssertTrue(percent.showsPercent)
        XCTAssertEqual(percent.band, 0)
    }

    func testIdleAlphaFloor() {
        XCTAssertEqual(PillMeterLayout.idleAlpha(0.35, showsMeters: false), 0.35, "no meters: as faint as before")
        XCTAssertEqual(PillMeterLayout.idleAlpha(0.35, showsMeters: true), PillMeterLayout.idleMinimumAlpha)
        XCTAssertEqual(PillMeterLayout.idleAlpha(0.7, showsMeters: true), 0.7, "hover stays stronger")
        XCTAssertTrue(PillMeterLayout.idleMinimumAlpha >= 0.5)
        XCTAssertTrue(PillMeterLayout.idleMinimumAlpha < 0.7)
    }
}
