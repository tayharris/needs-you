#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
@testable import NeedsYouCore

/// The collapsed pill's usage meters (Settings → Usage → On the pill): the style pref, and
/// where bars, thin bars and percentages go at every pill size.
final class PillMeterLayoutTests: XCTestCase {
    static var allTests = [
        ("testStylePrefDefaultsPersistsAndFallsBack", testStylePrefDefaultsPersistsAndFallsBack),
        ("testNoMetersChangeNothing", testNoMetersChangeNothing),
        ("testBarsSitBelowTheCount", testBarsSitBelowTheCount),
        ("testBarsAreVisible", testBarsAreVisible),
        ("testBarsScaleWithEveryPillSize", testBarsScaleWithEveryPillSize),
        ("testThinAndPercentKeepTheSize", testThinAndPercentKeepTheSize),
        ("testIdleAlphaFloor", testIdleAlphaFloor),
        ("testAppearancePrefsDefaultsAndMigrate", testAppearancePrefsDefaultsAndMigrate),
        ("testEveryShapeArrangementAndSizeFits", testEveryShapeArrangementAndSizeFits),
        ("testLargeReadsAtAGlance", testLargeReadsAtAGlance),
        ("testRowsWidenANarrowPill", testRowsWidenANarrowPill),
        ("testRings", testRings),
        ("testTrailingCountsTowardTheMinimumWidth", testTrailingCountsTowardTheMinimumWidth),
        ("testExampleBars", testExampleBars),
    ]

    private let medium = PillMetrics.make(PanelStyle.regular, size: .medium)

    func testStylePrefDefaultsPersistsAndFallsBack() {
        let suite = TestDefaults.suiteName(Self.self)
        let store = TestDefaults.make(suite)
        defer { TestDefaults.clear(suite) }
        let fresh = UsagePrefs.load(from: store)
        XCTAssertEqual(fresh.pillStyle, .bars, "bars are the default: thin lines were too easy to miss")
        XCTAssertEqual(PillMeterStyle.allCases, [.bars, .thin, .rings, .percent])
        XCTAssertEqual(PillMeterStyle.allCases.map(\.title), ["Bars", "Thin bars", "Rings", "Percentages"])

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
        let thin = PillMeterLayout.make(.thin, count: 2, height: 22, font: 12)
        XCTAssertEqual(thin.barHeight, 1.5, "the 0.4.0 look, unchanged")
        XCTAssertEqual(PillMeterLayout.make(.thin, count: 2, height: 26, font: 14).barHeight, 2)
        XCTAssertEqual(thin.fillOpacity, 0.85)
        XCTAssertEqual(thin.trackOpacity, 0.28)
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

    func testThinAndPercentKeepTheSize() {
        for style in [PillMeterStyle.thin, .percent] {
            let l = PillMeterLayout.make(style, count: 2, height: medium.height, font: medium.font)
            XCTAssertEqual(l.height, medium.height)
        }
        // Thin bars get their own band too: the count moves up to clear them.
        let medThin = PillMeterLayout.make(.thin, count: 2, height: medium.height, font: medium.font)
        XCTAssertEqual(medThin.band, 5)
        XCTAssertEqual(medThin.contentHeight, 17)
        XCTAssertEqual(PillMeterLayout.make(.percent, count: 2, height: 22, font: 12).contentHeight, 22)
        // The 18 pt idle pill grows a point, so the line's descenders clear the bars.
        let idleThin = PillMeterLayout.make(.thin, count: 2, height: 18, font: 11)
        XCTAssertEqual(idleThin.contentHeight, 14)
        XCTAssertEqual(idleThin.height, 19)
        let thin = PillMeterLayout.make(.thin, count: 2, height: 22, font: 12)
        XCTAssertTrue(thin.showsBars)
        XCTAssertFalse(thin.showsPercent)
        XCTAssertEqual(thin.bottomInset, 1)
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

    // MARK: Shape × arrangement × size

    func testAppearancePrefsDefaultsAndMigrate() {
        let suite = TestDefaults.suiteName(Self.self) + ".appearance"
        let store = TestDefaults.make(suite)
        defer { TestDefaults.clear(suite) }
        let fresh = UsagePrefs.load(from: store)
        XCTAssertEqual(fresh.pillAppearance, PillMeterAppearance(.bars, arrangement: .stacked, size: .large, showsNumbers: false),
                       "large stacked bars out of the box: easy to see")
        XCTAssertEqual(PillMeterArrangement.allCases, [.stacked, .row])
        XCTAssertEqual(PillMeterSize.allCases, [.small, .medium, .large])
        XCTAssertEqual(PillMeterArrangement.stacked.title(for: .rings), "One inside the other")
        XCTAssertEqual(PillMeterArrangement.stacked.title(for: .bars), "Stacked")
        XCTAssertEqual(PillMeterArrangement.row.title(for: .rings), "Side by side")

        // A style saved before sizes existed keeps the size it was drawn at.
        for (raw, style) in [("thin", PillMeterStyle.thin), ("hairline", .thin), ("bars", .bars), ("percent", .percent)] {
            store.set(raw, forKey: UsagePrefs.Key.pillStyle)
            let p = UsagePrefs.load(from: store)
            XCTAssertEqual(p.pillStyle, style, raw)
            XCTAssertEqual(p.pillSize, .medium, raw)
            XCTAssertEqual(p.pillArrangement, .stacked, raw)
            XCTAssertFalse(p.pillNumbers, raw)
        }
        // An old thin-bars pill is drawn exactly as before.
        store.set("thin", forKey: UsagePrefs.Key.pillStyle)
        let old = UsagePrefs.load(from: store)
        for (h, f) in [(CGFloat(22), CGFloat(12)), (18, 11), (26, 14)] {
            XCTAssertEqual(PillMeterLayout.make(old.pillAppearance, count: 2, height: h, font: f),
                           PillMeterLayout.make(.thin, count: 2, height: h, font: f))
        }
        XCTAssertEqual(PillMeterLayout.make(old.pillAppearance, count: 2, height: 22, font: 12).barHeight, 1.5)
        store.removeObject(forKey: UsagePrefs.Key.pillStyle)

        // Round trip, and a new save always writes the size with the style.
        var p = fresh
        p.pillSize = .small
        p.save(to: store, previous: fresh)
        XCTAssertEqual(store.string(forKey: UsagePrefs.Key.pillStyle), "bars")
        XCTAssertEqual(store.string(forKey: UsagePrefs.Key.pillSize), "small")
        XCTAssertNil(store.object(forKey: UsagePrefs.Key.pillArrangement), "save writes only what changed")
        XCTAssertEqual(UsagePrefs.load(from: store).pillSize, .small)
        var q = UsagePrefs.load(from: store)
        q.pillStyle = .rings
        q.pillArrangement = .row
        q.pillNumbers = true
        q.save(to: store, previous: p)
        let back = UsagePrefs.load(from: store)
        XCTAssertEqual(back.pillAppearance, PillMeterAppearance(.rings, arrangement: .row, size: .small, showsNumbers: true))
        XCTAssertEqual(back, q)

        // Unknown values fall back.
        store.set("huge", forKey: UsagePrefs.Key.pillSize)
        store.set("diagonal", forKey: UsagePrefs.Key.pillArrangement)
        XCTAssertEqual(UsagePrefs.load(from: store).pillSize, .medium, "a stored style with no usable size")
        XCTAssertEqual(UsagePrefs.load(from: store).pillArrangement, .stacked)
    }

    private struct Pill {
        var name: String
        var height: CGFloat
        var font: CGFloat
        var width: CGFloat
        var radius: CGFloat
    }

    /// Every pill the app draws: waiting (each panel and pill size, one digit: the narrowest)
    /// and idle (at rest and on hover).
    private var everyPill: [Pill] {
        var pills: [Pill] = []
        for panel in PanelSize.allCases {
            for size in PillSize.allCases {
                let m = PillMetrics.make(PanelStyle.metrics(panel), size: size)
                pills.append(Pill(name: "waiting \(panel) \(size)", height: m.height, font: m.font,
                                  width: m.width(units: 1), radius: m.cornerRadius))
            }
            let pm = PanelStyle.metrics(panel)
            let text: CGFloat = 100   // about "Nothing needs you"
            pills.append(Pill(name: "idle \(panel)", height: pm.idleHeight, font: pm.idleFont,
                              width: pm.idleWidth(textWidth: text), radius: 9))
            pills.append(Pill(name: "idle hover \(panel)", height: pm.idleHoverHeight, font: pm.idleFont,
                              width: pm.idleWidth(textWidth: text), radius: 11))
        }
        return pills
    }

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.001 && i.height > 0.001
    }

    func testEveryShapeArrangementAndSizeFits() {
        for pill in everyPill {
            for style in PillMeterStyle.allCases {
                for arrangement in PillMeterArrangement.allCases {
                    for size in PillMeterSize.allCases {
                        for numbers in [false, true] {
                            for count in [1, 2] {
                                let a = PillMeterAppearance(style, arrangement: arrangement, size: size, showsNumbers: numbers)
                                let l = PillMeterLayout.make(a, count: count, height: pill.height, font: pill.font)
                                check(l, pill, "\(pill.name) \(style) \(arrangement) \(size) numbers \(numbers) ×\(count)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func check(_ l: PillMeterLayout, _ pill: Pill, _ what: String) {
        let line = ceil(pill.font * 1.2)
        // Never shorter, and a few points taller at most: never a second row of text.
        XCTAssertTrue(l.height >= pill.height, what)
        XCTAssertTrue(l.height - pill.height <= pill.font * 0.9, "\(what): grew \(l.height - pill.height)")
        XCTAssertTrue(l.contentHeight >= line, "\(what): the count or idle line keeps its descenders")
        XCTAssertEqual(l.showsPercent, l.style == .percent || l.showsNumbers, what)
        for v in [l.barHeight, l.barGap, l.bottomInset, l.height, l.ringDiameter, l.ringStroke] {
            XCTAssertEqual((v * 2).rounded(), v * 2, "half points: \(what)")
        }
        switch l.style {
        case .bars, .thin:
            XCTAssertTrue(l.showsBars, what)
            XCTAssertFalse(l.showsRings, what)
            XCTAssertEqual(l.contentHeight + l.band, l.height, what)
            XCTAssertTrue(l.barHeight >= 1, what)
            // The app widens the pill to `minWidth` when it needs to.
            let inset = l.barInset(cornerRadius: pill.radius)
            let width = max(pill.width, l.minWidth(cornerRadius: pill.radius))
            let rects = l.barRects(width: width, cornerRadius: pill.radius)
            XCTAssertEqual(rects.count, l.count, what)
            for (i, r) in rects.enumerated() {
                XCTAssertTrue(r.minY >= l.contentHeight - 0.001, "\(what): bar \(i) is below the text band")
                XCTAssertTrue(r.maxY <= l.height - l.bottomInset + 0.001, what)
                XCTAssertTrue(r.minX >= inset - 0.001 && r.maxX <= width - inset + 0.001, "\(what): clear of the rounded ends")
                XCTAssertEqual(r.height, l.barHeight, what)
                XCTAssertTrue(r.width >= l.minMeterWidth - 0.001, "\(what): bar \(i) \(r.width) wide")
                for other in rects[(i + 1)...] { XCTAssertFalse(overlaps(r, other), "\(what): bars overlap") }
            }
            XCTAssertEqual(l.ringsWidth, 0, what)
        case .rings:
            XCTAssertFalse(l.showsBars, what)
            XCTAssertTrue(l.showsRings, what)
            XCTAssertEqual(l.band, 0, what)
            XCTAssertEqual(l.contentHeight, l.height, "\(what): rings sit beside the text, not under it")
            XCTAssertEqual(l.minWidth(cornerRadius: pill.radius), 0, what)
            let rects = l.ringRects
            XCTAssertEqual(rects.count, l.count, what)
            for (i, r) in rects.enumerated() {
                XCTAssertTrue(r.minX >= l.ringLeading - 0.001 && r.maxX <= l.ringsWidth + 0.001, "\(what): ring \(i) in its slot")
                XCTAssertTrue(r.minY >= l.ringMargin - 0.001 && r.maxY <= l.height - l.ringMargin + 0.001, "\(what): ring \(i) in the pill")
                XCTAssertEqual(r.width, r.height, what)
                XCTAssertTrue(r.width >= 2 * l.ringStroke + 2 - 0.001, "\(what): ring \(i) keeps a hole")
            }
            if l.count == 2 {
                if l.arrangement == .row {
                    XCTAssertFalse(overlaps(rects[0], rects[1]), "\(what): rings overlap")
                } else {
                    // The inner ring's stroke is inside the outer one's, with a gap.
                    XCTAssertEqual(rects[0].midX, rects[1].midX, what)
                    XCTAssertEqual(rects[0].midY, rects[1].midY, what)
                    XCTAssertTrue(rects[1].width <= rects[0].width - 2 * (l.ringStroke + l.ringGap) + 0.001, what)
                }
            }
        case .percent:
            XCTAssertFalse(l.showsBars, what)
            XCTAssertFalse(l.showsRings, what)
            XCTAssertEqual(l.height, pill.height, what)
            XCTAssertEqual(l.ringsWidth, 0, what)
        }
    }

    func testLargeReadsAtAGlance() {
        // The default: large stacked bars, the medium pill a little taller than with medium ones.
        let def = PillMeterLayout.make(UsagePrefs().pillAppearance, count: 2, height: 22, font: 12)
        XCTAssertEqual(def.barHeight, 4.5)
        XCTAssertEqual(def.barGap, 2)
        XCTAssertEqual(def.band, 14)
        XCTAssertEqual(def.height, 30)
        XCTAssertEqual(def.contentHeight, 16)
        // Each size is bigger than the one before, for every shape.
        for style in [PillMeterStyle.bars, .thin] {
            let t = PillMeterSize.allCases.map {
                PillMeterLayout.make(PillMeterAppearance(style, size: $0), count: 2, height: 22, font: 12).barHeight
            }
            XCTAssertTrue(t[0] < t[1] && t[1] < t[2], "\(style) \(t)")
        }
        let rings = PillMeterSize.allCases.map {
            PillMeterLayout.make(PillMeterAppearance(.rings, arrangement: .row, size: $0), count: 2, height: 22, font: 12)
        }
        XCTAssertTrue(rings[0].ringDiameter < rings[1].ringDiameter && rings[1].ringDiameter < rings[2].ringDiameter)
        XCTAssertTrue(rings[0].ringStroke < rings[1].ringStroke && rings[1].ringStroke < rings[2].ringStroke)
        XCTAssertEqual(rings[2].ringDiameter, 18)
        XCTAssertEqual(rings[2].ringStroke, 3.5)
        XCTAssertEqual(rings[2].height, 22, "a large ring fits the medium pill as it is")
        // Side by side: thick bars without the height of two.
        let row = PillMeterLayout.make(PillMeterAppearance(.bars, arrangement: .row, size: .large), count: 2, height: 22, font: 12)
        XCTAssertEqual(row.band, 7.5)
        XCTAssertEqual(row.height, 23.5)
        // The percentages: a point smaller, as before, or the pill's own size.
        let base: CGFloat = 10
        let sizes = PillMeterSize.allCases.map {
            PillMeterLayout.make(PillMeterAppearance(.percent, size: $0), count: 2, height: 22, font: 12).numberSize(base)
        }
        XCTAssertEqual(sizes, [9, 10, 12])
    }

    func testRowsWidenANarrowPill() {
        let m = medium
        let narrow = m.width(units: 1)
        XCTAssertEqual(narrow, 44)
        let stacked = PillMeterLayout.make(PillMeterAppearance(.bars), count: 2, height: m.height, font: m.font)
        XCTAssertTrue(stacked.minWidth(cornerRadius: m.cornerRadius) <= narrow, "stacked bars fit the narrowest pill")
        let row = PillMeterLayout.make(PillMeterAppearance(.bars, arrangement: .row), count: 2, height: m.height, font: m.font)
        XCTAssertEqual(row.minWidth(cornerRadius: m.cornerRadius), 56)
        let one = PillMeterLayout.make(PillMeterAppearance(.bars, arrangement: .row), count: 1, height: m.height, font: m.font)
        XCTAssertTrue(one.minWidth(cornerRadius: m.cornerRadius) <= narrow, "one meter in a row is as wide as stacked")
        let rects = row.barRects(width: 56, cornerRadius: m.cornerRadius)
        XCTAssertEqual(rects.map(\.minX), [7, 31])
        XCTAssertEqual(rects.map(\.width), [18, 18])
        XCTAssertEqual(rects.map(\.minY), [16, 16])
        // Stacked: session on top.
        let two = stacked.barRects(width: 44, cornerRadius: m.cornerRadius)
        XCTAssertEqual(two.map(\.minY), [16, 20.5])
        // Percentages arrange nothing, and are numbers whatever "Show percentages" says.
        XCTAssertEqual(PillMeterLayout.make(PillMeterAppearance(.percent, arrangement: .stacked), count: 2, height: 22, font: 12).arrangement, .row)
        XCTAssertTrue(PillMeterLayout.make(PillMeterAppearance(.percent), count: 2, height: 22, font: 12).showsNumbers)
        XCTAssertFalse(PillMeterLayout.make(PillMeterAppearance(.bars), count: 2, height: 22, font: 12).showsPercent)
        XCTAssertTrue(PillMeterLayout.make(PillMeterAppearance(.bars, showsNumbers: true), count: 2, height: 22, font: 12).showsPercent)
        XCTAssertFalse(PillMeterLayout.make(PillMeterAppearance(.bars, showsNumbers: true), count: 0, height: 22, font: 12).showsPercent)
    }

    func testRings() {
        let side = PillMeterLayout.make(PillMeterAppearance(.rings, arrangement: .row, size: .medium), count: 2, height: 22, font: 12)
        XCTAssertEqual(side.ringDiameter, 15)
        XCTAssertEqual(side.ringsWidth, 5 + 15 + 4 + 15)
        XCTAssertEqual(side.ringRects.map(\.minX), [5, 24])
        XCTAssertEqual(side.ringRects.map(\.minY), [3.5, 3.5])
        let inside = PillMeterLayout.make(PillMeterAppearance(.rings, arrangement: .stacked, size: .medium), count: 2, height: 22, font: 12)
        XCTAssertEqual(inside.ringsWidth, 5 + 15)
        XCTAssertEqual(inside.ringRects[1], CGRect(x: 8.5, y: 7, width: 8, height: 8))
        // A small pair one inside the other grows to keep the inner ring's hole.
        let tiny = PillMeterLayout.make(PillMeterAppearance(.rings, arrangement: .stacked, size: .small), count: 2, height: 16, font: 10)
        XCTAssertTrue(tiny.ringRects[1].width >= 2 * tiny.ringStroke + 2)
    }

    func testTrailingCountsTowardTheMinimumWidth() {
        // A one-digit pill is 44 wide, mostly padding; the rings' or percentages' slot uses
        // that room instead of adding to it.
        XCTAssertEqual(medium.width(units: 1, trailing: 40), 18 + 8 + 40)
        XCTAssertEqual(medium.width(units: 1, trailing: 10), 44)
        XCTAssertEqual(medium.width(units: 1, trailing: 0), medium.width(units: 1))
        XCTAssertEqual(medium.width(units: 1, titleWidth: 5000, trailing: 40), medium.maxWidth)
    }

    func testExampleBars() {
        let bars = UsageMeters.exampleBars(session: 85, weekly: 100, warnPct: 80)
        XCTAssertEqual(bars.map(\.id), ["5h", "7d"])
        XCTAssertEqual(bars.map(\.pctText), ["85%", "100%"])
        XCTAssertEqual(bars.map(\.level), [.warning, .full])
        XCTAssertEqual(UsageMeters.exampleBars(session: 31, weekly: 10, warnPct: 80).map(\.level), [.normal, .normal])
    }
}
