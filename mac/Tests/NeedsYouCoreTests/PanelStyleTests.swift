#if NEEDSYOU_SELFTEST
import MiniXCTest
#else
import XCTest
#endif
import CoreGraphics
import Foundation
import NeedsYouCore

/// Panel size and text size tables. Regular + default text must stay the original look.
final class PanelStyleTests: XCTestCase {
    static var allTests = [
        ("testRegularIsTheOriginalLook", testRegularIsTheOriginalLook),
        ("testSizesGrowInOrder", testSizesGrowInOrder),
        ("testBodyFont", testBodyFont),
        ("testPillWidths", testPillWidths),
        ("testRawValuesAreStable", testRawValuesAreStable),
        ("testPreviewWithoutLinkKeepsTheOriginalSize", testPreviewWithoutLinkKeepsTheOriginalSize),
        ("testPreviewLinkGetsItsOwnRow", testPreviewLinkGetsItsOwnRow),
        ("testPreviewTitleWrapsToTwoLines", testPreviewTitleWrapsToTwoLines),
        ("testPreviewTextTakesTheFullWidth", testPreviewTextTakesTheFullWidth),
    ]

    func testRegularIsTheOriginalLook() {
        let m = PanelStyle.metrics(.regular)
        XCTAssertEqual(m.idleFont, 11)
        XCTAssertEqual(m.idleHeight, 18)
        XCTAssertEqual(m.idleHoverHeight, 22)
        XCTAssertEqual(m.idleMaxWidth, 340)
        XCTAssertEqual(m.countFont, 12)
        XCTAssertEqual(m.countHeight, 22)
        XCTAssertEqual(m.previewWidth, 320)
        XCTAssertEqual(m.previewHeight, 52)
        XCTAssertEqual(m.expandedWidth, 360)
        XCTAssertEqual(m.headerHeight, 44)
        XCTAssertEqual(m.footerHeight, 26)
        XCTAssertEqual(m.maxListHeight, 520)
        XCTAssertEqual(m.minListHeight, 64)
        XCTAssertEqual(m.titleFont, 13)
        XCTAssertEqual(m.metaFont, 11)
        XCTAssertEqual(m.linkFont, 11)
        XCTAssertEqual(m.cardPadding, 10)
        XCTAssertEqual(m.cardSpacing, 8)
        XCTAssertEqual(PanelStyle.bodyFont(.standard, panel: .regular), 12)
    }

    func testSizesGrowInOrder() {
        XCTAssertEqual(PanelSize.allCases, [.compact, .regular, .large])
        let sizes = PanelSize.allCases.map { PanelStyle.metrics($0) }
        for (a, b) in zip(sizes, sizes.dropFirst()) {
            XCTAssertTrue(a.expandedWidth < b.expandedWidth)
            XCTAssertTrue(a.titleFont < b.titleFont)
            XCTAssertTrue(a.metaFont < b.metaFont)
            XCTAssertTrue(a.countHeight < b.countHeight)
            XCTAssertTrue(a.idleHeight < b.idleHeight)
            XCTAssertTrue(a.previewWidth < b.previewWidth)
            XCTAssertTrue(a.headerHeight < b.headerHeight)
            XCTAssertTrue(a.maxListHeight < b.maxListHeight)
        }
        // Compact is still readable.
        XCTAssertTrue(PanelStyle.compact.metaFont >= 10)
    }

    func testBodyFont() {
        XCTAssertEqual(TextSize.allCases, [.small, .standard, .large, .extraLarge])
        for panel in PanelSize.allCases {
            let sizes = TextSize.allCases.map { PanelStyle.bodyFont($0, panel: panel) }
            XCTAssertEqual(sizes, sizes.sorted())
            XCTAssertEqual(Set(sizes).count, sizes.count, "each text size differs at \(panel)")
            XCTAssertTrue(sizes.allSatisfy { $0 >= 10 }, "never smaller than 10 pt at \(panel)")
        }
        XCTAssertEqual(PanelStyle.bodyFont(.extraLarge, panel: .regular), 16)
        XCTAssertEqual(PanelStyle.bodyFont(.small, panel: .compact), 10)
        XCTAssertEqual(PanelStyle.bodyFont(.extraLarge, panel: .large), 18)
    }

    func testPillWidths() {
        let m = PanelStyle.regular
        // The original formulas: max(44, 18 + digits * 8) and min(340, ceil(text) + 32).
        XCTAssertEqual(m.countWidth(digits: 1), 44)
        XCTAssertEqual(m.countWidth(digits: 4), 50)
        XCTAssertEqual(m.idleWidth(textWidth: 100.2), 133)
        XCTAssertEqual(m.idleWidth(textWidth: 1000), 340)
    }

    func testRawValuesAreStable() {
        // Stored in UserDefaults; renaming a case would silently reset users' choice.
        XCTAssertEqual(PanelSize.allCases.map(\.rawValue), ["compact", "regular", "large"])
        XCTAssertEqual(TextSize.allCases.map(\.rawValue), ["small", "default", "large", "extraLarge"])
    }

    func testPreviewWithoutLinkKeepsTheOriginalSize() {
        // One title line, no link: the original 52 pt preview at the regular size.
        for size in PanelSize.allCases {
            let m = PanelStyle.metrics(size)
            XCTAssertEqual(PreviewLayout.height(m, titleLines: 1, hasLink: false), m.previewHeight)
        }
        XCTAssertEqual(PreviewLayout.height(PanelStyle.regular, titleLines: 1, hasLink: false), 52)
    }

    func testPreviewLinkGetsItsOwnRow() {
        // The button sits on a row below the title and meta line, so the preview grows by
        // that row (and the gap above it) instead of the button taking a column.
        let m = PanelStyle.regular
        XCTAssertEqual(PreviewLayout.linkRowHeight(m), 20)   // an 11 pt label (14 pt line), 3 pt above and below
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 1, hasLink: true), 52 + 6 + 20)
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 2, hasLink: true), 52 + 16 + 6 + 20)
        for size in PanelSize.allCases {
            let s = PanelStyle.metrics(size)
            XCTAssertTrue(PreviewLayout.height(s, titleLines: 1, hasLink: true) >= s.previewHeight + PreviewLayout.linkRowHeight(s))
        }
    }

    func testPreviewTitleWrapsToTwoLines() {
        let line: CGFloat = 16
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: 15.5, lineHeight: line), 1)
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: 31, lineHeight: line), 2)
        // Longer titles stop at two lines (cut at the end of the second).
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: 80, lineHeight: line), 2)
        // Nothing measured: one line.
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: 0, lineHeight: line), 1)
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: 20, lineHeight: 0), 1)
        XCTAssertEqual(PreviewLayout.titleLines(wrappedHeight: .infinity, lineHeight: line), 1)
        // A second title line adds one title line's height; never more than two.
        let m = PanelStyle.regular
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 2, hasLink: false), 52 + PreviewLayout.lineHeight(m.titleFont))
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 9, hasLink: false), PreviewLayout.height(m, titleLines: 2, hasLink: false))
        XCTAssertEqual(PreviewLayout.height(m, titleLines: 0, hasLink: false), 52)
    }

    func testPreviewTextTakesTheFullWidth() {
        // Everything but the padding and the priority dot: no column kept for the button.
        XCTAssertEqual(PreviewLayout.textWidth(PanelStyle.regular), 320 - 24 - 7 - 10)
        for size in PanelSize.allCases {
            let m = PanelStyle.metrics(size)
            XCTAssertTrue(PreviewLayout.textWidth(m) > m.previewWidth * 0.85)
        }
    }
}
