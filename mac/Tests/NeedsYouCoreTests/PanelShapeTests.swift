#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// Settings → Appearance → Pill → Shape and Pill size, and Panel and cards → Density: the
/// prefs (defaults are the original look, unknown values fall back), the corner radius of
/// every state in every shape, the pill sizes and the card density.
final class PanelShapeTests: XCTestCase {
    static var allTests = [
        ("testDefaultsAreTheOriginalLook", testDefaultsAreTheOriginalLook),
        ("testRoundTrip", testRoundTrip),
        ("testUnknownValuesFallBack", testUnknownValuesFallBack),
        ("testRawValuesAreStable", testRawValuesAreStable),
        ("testRoundedIsTheOriginalCorners", testRoundedIsTheOriginalCorners),
        ("testSquareCorners", testSquareCorners),
        ("testCapsuleCorners", testCapsuleCorners),
        ("testRadiusNeverExceedsHalfTheHeightOutsideRounded", testRadiusNeverExceedsHalfTheHeightOutsideRounded),
        ("testCornerRadiusUsesThePrefs", testCornerRadiusUsesThePrefs),
        ("testMediumPillIsThePanelSize", testMediumPillIsThePanelSize),
        ("testPillSizesScaleTogether", testPillSizesScaleTogether),
        ("testPillSizeScalesTheMeters", testPillSizeScalesTheMeters),
        ("testComfortableIsTheOriginalSpacing", testComfortableIsTheOriginalSpacing),
        ("testCompactIsTighterButKeepsTheType", testCompactIsTighterButKeepsTheType),
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

    // MARK: Prefs

    func testDefaultsAreTheOriginalLook() {
        let p = UIPrefs.load(from: store)
        XCTAssertEqual(p.panelShape, .rounded)
        XCTAssertEqual(p.cardDensity, .comfortable)
        XCTAssertEqual(p.pillSize, .medium)
        XCTAssertEqual(UIPrefs.defaults.panelShape, .rounded)
        XCTAssertEqual(UIPrefs.defaults.cardDensity, .comfortable)
        // The default metrics are exactly the regular panel size's.
        XCTAssertEqual(p.metrics, PanelStyle.regular)
        XCTAssertTrue((store.persistentDomain(forName: suite) ?? [:]).isEmpty, "load never writes")
    }

    func testRoundTrip() {
        var p = UIPrefs()
        p.panelShape = .capsule
        p.cardDensity = .compact
        p.pillSize = .large
        p.save(to: store, previous: UIPrefs())
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.panelShape), "capsule")
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.cardDensity), "compact")
        XCTAssertEqual(store.string(forKey: UIPrefs.Key.pillSize), "large")
        let loaded = UIPrefs.load(from: store)
        XCTAssertEqual(loaded.panelShape, .capsule)
        XCTAssertEqual(loaded.cardDensity, .compact)
        XCTAssertEqual(loaded.pillSize, .large)
        XCTAssertEqual(loaded, p)

        // Only what changed is written.
        TestDefaults.clear(suite)
        var q = UIPrefs()
        q.panelShape = .square
        q.save(to: store, previous: UIPrefs())
        XCTAssertEqual(Set((store.persistentDomain(forName: suite) ?? [:]).keys), [UIPrefs.Key.panelShape])
    }

    func testUnknownValuesFallBack() {
        store.set("blob", forKey: UIPrefs.Key.panelShape)
        store.set("cosy", forKey: UIPrefs.Key.cardDensity)
        store.set("huge", forKey: UIPrefs.Key.pillSize)
        let p = UIPrefs.load(from: store)
        XCTAssertEqual(p.panelShape, .rounded)
        XCTAssertEqual(p.cardDensity, .comfortable)
        XCTAssertEqual(p.pillSize, .medium)
        // A number where a name belongs.
        store.set(3, forKey: UIPrefs.Key.panelShape)
        store.set(true, forKey: UIPrefs.Key.cardDensity)
        XCTAssertEqual(UIPrefs.load(from: store).panelShape, .rounded)
        XCTAssertEqual(UIPrefs.load(from: store).cardDensity, .comfortable)
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(PanelShape.allCases.map(\.rawValue), ["rounded", "square", "capsule"])
        XCTAssertEqual(CardDensity.allCases.map(\.rawValue), ["comfortable", "compact"])
        XCTAssertEqual(PillSize.allCases.map(\.rawValue), ["small", "medium", "large"])
        XCTAssertEqual(UIPrefs.Key.panelShape, "panelShape")
        XCTAssertEqual(UIPrefs.Key.cardDensity, "cardDensity")
        XCTAssertEqual(PanelShape.allCases.map(\.title), ["Rounded", "Square", "Capsule"])
        XCTAssertEqual(CardDensity.allCases.map(\.title), ["Comfortable", "Compact"])
    }

    // MARK: Corners

    private let pill = PillMetrics.make(PanelStyle.regular, size: .medium)

    private func r(_ shape: PanelShape, _ surface: PanelSurface, _ height: CGFloat) -> CGFloat {
        PanelCorners.radius(shape, surface, height: height, pill: pill)
    }

    func testRoundedIsTheOriginalCorners() {
        // The numbers RootView and PanelController used before Shape existed.
        XCTAssertEqual(r(.rounded, .idle(hovering: false), 18), 9)
        XCTAssertEqual(r(.rounded, .idle(hovering: true), 22), 11)
        XCTAssertEqual(r(.rounded, .pill, 22), 11)
        XCTAssertEqual(r(.rounded, .pill, 26.5), 11, "a taller pill (bars) keeps 11")
        XCTAssertEqual(r(.rounded, .dot, 22), 11, "the minimal dot is a circle")
        XCTAssertEqual(r(.rounded, .peek, 52), 14)
        XCTAssertEqual(r(.rounded, .peek, 90), 14)
        XCTAssertEqual(r(.rounded, .panel, 600), 14)
        // Not clamped: the compact panel size's 16-pt idle pill kept 9 (the drawing clamps it).
        XCTAssertEqual(r(.rounded, .idle(hovering: false), 16), 9)
    }

    func testSquareCorners() {
        for surface in [PanelSurface.idle(hovering: false), .idle(hovering: true), .pill, .dot, .peek, .panel] {
            XCTAssertEqual(r(.square, surface, 40), PanelCorners.squareRadius, "\(surface)")
        }
        XCTAssertEqual(PanelCorners.squareRadius, 3)
        XCTAssertEqual(r(.square, .pill, 4), 2, "never more than half a tiny height")
    }

    func testCapsuleCorners() {
        // Fully round ends on the pills, at whatever height they are.
        XCTAssertEqual(r(.capsule, .idle(hovering: false), 18), 9)
        XCTAssertEqual(r(.capsule, .idle(hovering: true), 22), 11)
        XCTAssertEqual(r(.capsule, .pill, 22), 11)
        XCTAssertEqual(r(.capsule, .pill, 26.5), 13.25, "a taller pill keeps round ends")
        XCTAssertEqual(r(.capsule, .dot, 22), 11)
        // The one-line preview is a capsule; a taller one keeps the cap so text isn't clipped.
        XCTAssertEqual(r(.capsule, .peek, 52), 26)
        XCTAssertEqual(r(.capsule, .peek, 60), 30)
        XCTAssertEqual(r(.capsule, .peek, 110), PanelCorners.capsulePeekMaxRadius)
        // The open panel: its roundest corners, more than Rounded's.
        XCTAssertEqual(r(.capsule, .panel, 600), PanelCorners.capsulePanelRadius)
        XCTAssertTrue(PanelCorners.capsulePanelRadius > PanelCorners.roundedPanelRadius)
        XCTAssertTrue(r(.capsule, .peek, 90) > r(.rounded, .peek, 90))
    }

    func testRadiusNeverExceedsHalfTheHeightOutsideRounded() {
        let surfaces: [PanelSurface] = [.idle(hovering: false), .idle(hovering: true), .pill, .dot, .peek, .panel]
        for shape in [PanelShape.square, .capsule] {
            for surface in surfaces {
                for height in stride(from: CGFloat(0), through: 700, by: 3.5) {
                    let radius = r(shape, surface, height)
                    XCTAssertTrue(radius <= height / 2, "\(shape) \(surface) \(height)")
                    XCTAssertTrue(radius >= 0)
                }
            }
        }
    }

    func testCornerRadiusUsesThePrefs() {
        var p = UIPrefs()
        XCTAssertEqual(p.cornerRadius(.pill, height: 22), 11)
        p.pillSize = .large
        // Rounded follows the pill size's own radius.
        XCTAssertEqual(p.cornerRadius(.pill, height: p.pillMetrics.height), p.pillMetrics.cornerRadius)
        XCTAssertEqual(p.cornerRadius(.idle(hovering: true), height: p.pillMetrics.idleHoverHeight),
                       p.pillMetrics.idleHoverCornerRadius)
        p.panelShape = .capsule
        XCTAssertEqual(p.cornerRadius(.pill, height: 40), 20)
        p.panelShape = .square
        XCTAssertEqual(p.cornerRadius(.panel, height: 400), 3)
    }

    // MARK: Pill size

    func testMediumPillIsThePanelSize() {
        for size in PanelSize.allCases {
            let m = PanelStyle.metrics(size)
            let p = PillMetrics.make(m, size: .medium)
            XCTAssertEqual(p.font, m.countFont)
            XCTAssertEqual(p.height, m.countHeight)
            XCTAssertEqual(p.cornerRadius, PillMetrics.baseCornerRadius)
            XCTAssertEqual(p.idleFont, m.idleFont)
            XCTAssertEqual(p.idleHeight, m.idleHeight)
            XCTAssertEqual(p.idleHoverHeight, m.idleHoverHeight)
            XCTAssertEqual(p.idleMaxWidth, m.idleMaxWidth)
            XCTAssertEqual(p.idleExtraWidth, m.idleExtraWidth)
            XCTAssertEqual(p.idleCornerRadius, 9)
            XCTAssertEqual(p.idleHoverCornerRadius, 11)
            for text in [CGFloat(0), 40.3, 120, 900] {
                XCTAssertEqual(p.idleWidth(textWidth: text), m.idleWidth(textWidth: text))
            }
            XCTAssertEqual(p.idlePillHeight(hovering: false), m.idleHeight)
            XCTAssertEqual(p.idlePillHeight(hovering: true), m.idleHoverHeight)
        }
    }

    func testPillSizesScaleTogether() {
        for panel in PanelSize.allCases {
            let m = PanelStyle.metrics(panel)
            let small = PillMetrics.make(m, size: .small)
            let medium = PillMetrics.make(m, size: .medium)
            let large = PillMetrics.make(m, size: .large)
            // The waiting pill and the idle pill grow together: height, type and width.
            for (a, b) in [(small, medium), (medium, large)] {
                XCTAssertTrue(a.height < b.height, "\(panel)")
                XCTAssertTrue(a.font < b.font, "\(panel)")
                XCTAssertTrue(a.idleHeight < b.idleHeight, "\(panel)")
                XCTAssertTrue(a.idleHoverHeight < b.idleHoverHeight, "\(panel)")
                XCTAssertTrue(a.idleFont < b.idleFont, "\(panel)")
                XCTAssertTrue(a.idleWidth(textWidth: 100) < b.idleWidth(textWidth: 100), "\(panel)")
                XCTAssertTrue(a.cornerRadius <= b.cornerRadius, "\(panel)")
                XCTAssertTrue(a.idleCornerRadius <= b.idleCornerRadius, "\(panel)")
            }
            // Rounded corners never pass round ends, and hover is still taller.
            for p in [small, large] {
                XCTAssertTrue(p.cornerRadius <= p.height / 2)
                XCTAssertTrue(p.idleCornerRadius <= p.idleHeight / 2)
                XCTAssertTrue(p.idleHoverCornerRadius <= p.idleHoverHeight / 2)
                XCTAssertTrue(p.idleHoverHeight > p.idleHeight)
            }
        }
        // The regular panel's numbers, to the half point.
        let large = PillMetrics.make(PanelStyle.regular, size: .large)
        XCTAssertEqual(large.idleFont, 15)
        XCTAssertEqual(large.idleHeight, 24.5)
        XCTAssertEqual(large.idleHoverHeight, 29.5)
        let small = PillMetrics.make(PanelStyle.regular, size: .small)
        XCTAssertEqual(small.idleFont, 9.5)
        XCTAssertEqual(small.idleHeight, 15.5)
    }

    func testPillSizeScalesTheMeters() {
        // The meters take the pill's height and type, so the size scales them on both pills.
        for style in [PillMeterStyle.bars, .rings] {
            var previous: PillMeterLayout?
            for size in PillSize.allCases {
                let p = PillMetrics.make(PanelStyle.regular, size: size)
                let idle = PillMeterLayout.make(PillMeterAppearance(style), count: 2, height: p.idleHeight, font: p.idleFont)
                let waiting = PillMeterLayout.make(PillMeterAppearance(style), count: 2, height: p.height, font: p.font)
                if let previous {
                    XCTAssertTrue(waiting.height >= previous.height, "\(style) \(size)")
                    if style == .rings { XCTAssertTrue(waiting.ringDiameter > previous.ringDiameter, "\(size)") }
                    if style == .bars { XCTAssertTrue(waiting.barHeight >= previous.barHeight, "\(size)") }
                }
                XCTAssertTrue(idle.height >= p.idleHeight)
                previous = waiting
            }
        }
    }

    // MARK: Density

    func testComfortableIsTheOriginalSpacing() {
        for size in PanelSize.allCases {
            XCTAssertEqual(PanelStyle.metrics(size).with(density: .comfortable), PanelStyle.metrics(size))
        }
        let m = PanelStyle.regular
        XCTAssertEqual(m.cardPadding, 10)
        XCTAssertEqual(m.cardSpacing, 8)
        XCTAssertEqual(m.listPadding, 10)
        XCTAssertEqual(m.cardLineSpacing, 5)
        XCTAssertEqual(m.cardRowSpacing, 4)
        XCTAssertEqual(m.cardBarGap, 9)
    }

    func testCompactIsTighterButKeepsTheType() {
        for size in PanelSize.allCases {
            let m = PanelStyle.metrics(size)
            let c = m.with(density: .compact)
            XCTAssertTrue(c.cardPadding < m.cardPadding, "\(size)")
            XCTAssertTrue(c.cardSpacing < m.cardSpacing, "\(size)")
            XCTAssertTrue(c.listPadding < m.listPadding, "\(size)")
            XCTAssertTrue(c.cardLineSpacing < m.cardLineSpacing, "\(size)")
            XCTAssertTrue(c.cardRowSpacing < m.cardRowSpacing, "\(size)")
            XCTAssertTrue(c.cardBarGap < m.cardBarGap, "\(size)")
            XCTAssertTrue(c.cardPadding > 0)
            XCTAssertTrue(c.cardSpacing > 0)
            // Type, the panel's width and the pills are Size's, not Density's.
            XCTAssertEqual(c.titleFont, m.titleFont)
            XCTAssertEqual(c.metaFont, m.metaFont)
            XCTAssertEqual(c.bodyOffset, m.bodyOffset)
            XCTAssertEqual(c.expandedWidth, m.expandedWidth)
            XCTAssertEqual(c.countHeight, m.countHeight)
            XCTAssertEqual(c.idleHeight, m.idleHeight)
            XCTAssertEqual(c.previewHeight, m.previewHeight)
        }
        let c = PanelStyle.regular.with(density: .compact)
        XCTAssertEqual(c.cardPadding, 7)
        XCTAssertEqual(c.cardSpacing, 4)
        XCTAssertEqual(c.listPadding, 7)
        var p = UIPrefs()
        p.cardDensity = .compact
        XCTAssertEqual(p.metrics, c)
        XCTAssertEqual(p.pillMetrics, UIPrefs().pillMetrics, "density leaves the pill alone")
    }
}
