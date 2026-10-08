import CoreGraphics
import Foundation

// Size tables for the floating panel. Pure data, so every size can be unit-tested and the
// view code only reads numbers. `.regular` with `.standard` text is the original look;
// PanelStyleTests pins those values so a default install never changes size.

/// How big the pill, the cards' type and the expanded panel are.
public enum PanelSize: String, CaseIterable, Codable, Sendable {
    case compact, regular, large

    public var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }
}

/// The size of card body text (agents' multi-step instructions), separate from the panel
/// size. Stored as its raw value; `.standard` is stored as "default".
public enum TextSize: String, CaseIterable, Codable, Sendable {
    case small
    case standard = "default"
    case large
    case extraLarge

    public var title: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra large"
        }
    }

    /// Body point size at the regular panel size.
    var basePoints: CGFloat {
        switch self {
        case .small: return 11
        case .standard: return 12
        case .large: return 14
        case .extraLarge: return 16
        }
    }
}

/// Every size the panel's views and PanelController use, in points.
public struct PanelMetrics: Equatable, Sendable {
    // Idle pill: "Nothing needs <you>".
    public var idleFont: CGFloat
    public var idleHeight: CGFloat
    public var idleHoverHeight: CGFloat
    public var idleMaxWidth: CGFloat
    /// Added to the text width (dot, gaps, padding).
    public var idleExtraWidth: CGFloat

    // Count pill: "3 · 1".
    public var countFont: CGFloat
    public var countHeight: CGFloat
    public var countMinWidth: CGFloat
    public var countBaseWidth: CGFloat
    public var countDigitWidth: CGFloat

    // New-item preview.
    public var previewWidth: CGFloat
    public var previewHeight: CGFloat

    // Expanded panel.
    public var expandedWidth: CGFloat
    public var headerHeight: CGFloat
    public var footerHeight: CGFloat
    public var maxListHeight: CGFloat
    public var minListHeight: CGFloat

    // Type.
    public var titleFont: CGFloat
    public var metaFont: CGFloat
    public var linkFont: CGFloat
    public var actionFont: CGFloat
    public var headerFont: CGFloat
    public var sectionFont: CGFloat

    // Card layout.
    public var cardPadding: CGFloat
    public var cardSpacing: CGFloat
    public var listPadding: CGFloat

    /// The body size offset for this panel size (added to the text size's base).
    public var bodyOffset: CGFloat

    /// The width of the count pill for `digits` digit-widths of text.
    public func countWidth(digits: Int) -> CGFloat {
        max(countMinWidth, countBaseWidth + CGFloat(max(0, digits)) * countDigitWidth)
    }

    /// The idle pill's width for a line of text `textWidth` points wide.
    public func idleWidth(textWidth: CGFloat) -> CGFloat {
        min(idleMaxWidth, ceil(textWidth) + idleExtraWidth)
    }
}

public enum PanelStyle {
    /// The original look; everything else is scaled from it.
    public static let regular = PanelMetrics(
        idleFont: 11, idleHeight: 18, idleHoverHeight: 22, idleMaxWidth: 340, idleExtraWidth: 32,
        countFont: 12, countHeight: 22, countMinWidth: 44, countBaseWidth: 18, countDigitWidth: 8,
        previewWidth: 320, previewHeight: 52,
        expandedWidth: 360, headerHeight: 44, footerHeight: 26, maxListHeight: 520, minListHeight: 64,
        titleFont: 13, metaFont: 11, linkFont: 11, actionFont: 11, headerFont: 13, sectionFont: 10,
        cardPadding: 10, cardSpacing: 8, listPadding: 10,
        bodyOffset: 0
    )

    public static let compact = PanelMetrics(
        idleFont: 10, idleHeight: 16, idleHoverHeight: 20, idleMaxWidth: 300, idleExtraWidth: 28,
        countFont: 11, countHeight: 20, countMinWidth: 38, countBaseWidth: 16, countDigitWidth: 7,
        previewWidth: 290, previewHeight: 46,
        expandedWidth: 320, headerHeight: 38, footerHeight: 24, maxListHeight: 460, minListHeight: 56,
        titleFont: 12, metaFont: 10, linkFont: 10, actionFont: 10, headerFont: 12, sectionFont: 9,
        cardPadding: 8, cardSpacing: 6, listPadding: 8,
        bodyOffset: -1
    )

    public static let large = PanelMetrics(
        idleFont: 13, idleHeight: 21, idleHoverHeight: 26, idleMaxWidth: 400, idleExtraWidth: 38,
        countFont: 14, countHeight: 26, countMinWidth: 52, countBaseWidth: 22, countDigitWidth: 9.5,
        previewWidth: 380, previewHeight: 60,
        expandedWidth: 430, headerHeight: 50, footerHeight: 30, maxListHeight: 620, minListHeight: 76,
        titleFont: 15, metaFont: 13, linkFont: 13, actionFont: 13, headerFont: 15, sectionFont: 11,
        cardPadding: 12, cardSpacing: 10, listPadding: 12,
        bodyOffset: 2
    )

    public static func metrics(_ size: PanelSize) -> PanelMetrics {
        switch size {
        case .compact: return compact
        case .regular: return regular
        case .large: return large
        }
    }

    /// Card body point size: the text size's base, nudged by the panel size.
    public static func bodyFont(_ text: TextSize, panel: PanelSize) -> CGFloat {
        text.basePoints + metrics(panel).bodyOffset
    }
}

/// The arrival preview's layout. The title (wrapped to two lines at most) and the meta line
/// take the preview's full width, and the link button, when there is one, sits on its own
/// row below them, left-aligned with the text. So the button never squeezes the title or
/// the "needs you · devbox · claude-code" line. The panel's height follows from it: the
/// original one-line preview with no link is `previewHeight`, unchanged.
public enum PreviewLayout {
    public static let maxTitleLines = 2
    /// Left and right padding inside the preview.
    public static let horizontalPadding: CGFloat = 12
    /// The priority dot and the gap after it.
    public static let dotSize: CGFloat = 7
    public static let dotGap: CGFloat = 10
    /// Between the title and the meta line.
    public static let metaGap: CGFloat = 2
    /// Between the meta line and the link button's row.
    public static let linkRowGap: CGFloat = 6
    /// The link button's vertical padding inside its capsule.
    public static let linkChipVertical: CGFloat = 3

    /// How wide the title, meta line and link row can be.
    public static func textWidth(_ m: PanelMetrics) -> CGFloat {
        m.previewWidth - horizontalPadding * 2 - dotSize - dotGap
    }

    /// One line of system text at `points`, rounded up.
    public static func lineHeight(_ points: CGFloat) -> CGFloat {
        ceil(points * 1.2)
    }

    /// Lines the title takes, from its height when wrapped at `textWidth` (measured by the
    /// app with the real font): 1 or 2; a longer title is cut at the end of line 2.
    public static func titleLines(wrappedHeight: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0, wrappedHeight.isFinite, wrappedHeight > 0 else { return 1 }
        let lines = Int((wrappedHeight / lineHeight).rounded())
        return min(maxTitleLines, max(1, lines))
    }

    /// The link button's row: the capsule's height (without the gap above it).
    public static func linkRowHeight(_ m: PanelMetrics) -> CGFloat {
        lineHeight(m.linkFont) + linkChipVertical * 2
    }

    /// The preview's height (the visible shape, without the glow padding).
    public static func height(_ m: PanelMetrics, titleLines: Int, hasLink: Bool) -> CGFloat {
        let extraLines = min(maxTitleLines, max(1, titleLines)) - 1
        var height = m.previewHeight + CGFloat(extraLines) * lineHeight(m.titleFont)
        if hasLink { height += linkRowGap + linkRowHeight(m) }
        return height
    }
}
