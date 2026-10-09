import CoreGraphics
import Foundation

// Where the collapsed pill's usage meters go (Settings → Usage → On the pill), as numbers
// the app draws with: CountPill and IdlePill draw them, PanelController sizes the pill and
// sets its opacity from them. Pure, so every shape, arrangement and size is unit-tested.
//
// Two places a meter can go:
//   - a band under the count (bars, thin bars): the count (or the idle line) is
//     centred in `contentHeight` at the top, the band below it, so a bar never covers a
//     digit or a descender. Stacked meters sit one above the other, a row side by side.
//   - after the count (rings, percentages), centred on the pill's height, in a slot whose
//     width is fixed, so the pill never resizes as the numbers change.

/// The meters' geometry for one pill.
public struct PillMeterLayout: Equatable, Sendable {
    public var style: PillMeterStyle
    public var arrangement: PillMeterArrangement
    public var size: PillMeterSize
    /// The percentages after the meters ("Show percentages", or the `.percent` style).
    public var showsNumbers: Bool
    /// Meters drawn (one per window, at most two); 0 draws nothing and changes nothing.
    public var count: Int
    /// The pill's own type size the layout was made for.
    public var font: CGFloat

    // The band (bars, thin bars).
    public var barHeight: CGFloat = 0
    /// Between stacked meters.
    public var barGap: CGFloat = 0
    /// Between side-by-side meters.
    public var rowGap: CGFloat = 0
    /// From the pill's bottom edge to the lowest bar.
    public var bottomInset: CGFloat = 0
    /// The narrowest a band meter may be; a row of them widens the pill to keep it.
    public var minMeterWidth: CGFloat = 0

    // Rings.
    public var ringDiameter: CGFloat = 0
    public var ringStroke: CGFloat = 0
    /// Between side-by-side rings, or between the outer ring's stroke and the inner ring.
    public var ringGap: CGFloat = 0
    /// Before the first ring, after the count.
    public var ringLeading: CGFloat = 0
    /// The least room above and below a ring.
    public var ringMargin: CGFloat = 0

    /// The pill's height with the meters.
    public var height: CGFloat
    /// The band at the top that the count (or the idle line) is centred in. Bars sit below
    /// it, so they never cover the digits or a descender; with rings or percentages it's the
    /// whole pill.
    public var contentHeight: CGFloat

    public var showsBars: Bool { count > 0 && style.isBand }
    public var showsRings: Bool { count > 0 && style == .rings }
    public var showsPercent: Bool { count > 0 && (style == .percent || showsNumbers) }
    /// Something sits after the count (rings or percentages).
    public var showsTrailing: Bool { showsRings || showsPercent }

    /// The track behind the fill (the unfilled part), so 0-100 % reads at a glance. Thin
    /// bars need a stronger one to show at all.
    public var trackOpacity: Double { style == .thin ? 0.28 : 0.22 }
    /// A meter below the warning line: bright enough to read on a dimmed pill.
    public var fillOpacity: Double { 0.85 }

    /// The medium, stacked look of `style` with no percentages (the first style picker's).
    public static func make(_ style: PillMeterStyle, count: Int, height: CGFloat, font: CGFloat) -> PillMeterLayout {
        make(PillMeterAppearance(style), count: count, height: height, font: font)
    }

    /// `height` and `font` are the pill's own (PillMetrics, or the idle pill's), so the
    /// meters scale with Settings → Panel → Size and Pill size. Sizes are rounded to half
    /// points.
    public static func make(_ a: PillMeterAppearance, count: Int, height: CGFloat, font: CGFloat) -> PillMeterLayout {
        let n = max(0, min(2, count))
        var l = PillMeterLayout(style: a.style, arrangement: a.style.canArrange ? a.arrangement : .row, size: a.size,
                                showsNumbers: a.style == .percent || (a.showsNumbers && a.style.canShowNumbers),
                                count: n, font: font, height: height, contentHeight: height)
        guard n > 0 else { return l }
        let u = font / 12
        func r(_ v: CGFloat, min floor: CGFloat) -> CGFloat { max(floor, (v * u * 2).rounded() / 2) }
        func pick(_ small: CGFloat, _ medium: CGFloat, _ large: CGFloat) -> CGFloat {
            switch a.size {
            case .small: return small
            case .medium: return medium
            case .large: return large
            }
        }
        let line = ceil(font * 1.2)
        switch a.style {
        case .percent:
            return l
        case .rings:
            l.ringStroke = pick(r(2, min: 1.5), r(2.5, min: 2), r(3.5, min: 2.5))
            l.ringGap = l.arrangement == .stacked ? r(1, min: 1) : r(4, min: 3)
            l.ringLeading = r(5, min: 4)
            l.ringMargin = 2
            var d = pick(r(12, min: 10), r(15, min: 12), r(18, min: 14))
            if l.arrangement == .stacked && n == 2 {
                // The inner ring keeps a hole at least 2 pt across.
                d = max(d, 4 * l.ringStroke + 2 * l.ringGap + 2)
            }
            l.ringDiameter = d
            // A large ring may make the pill a little taller; never shorter.
            l.height = max(height, d + 2 * l.ringMargin)
            l.contentHeight = l.height
            return l
        case .thin:
            // 1.5 pt lines, 2 pt on a pill 24 pt or taller, 1 pt above the bottom edge (0.4.0,
            // medium). The count moves up to clear them; the waiting pill keeps its size, the
            // shorter idle pill grows so "Nothing needs you" keeps its descenders.
            let tall = height >= 24
            l.barHeight = pick(1, tall ? 2 : 1.5, tall ? 3 : 2.5)
            l.barGap = 1
            l.bottomInset = 1
            l.rowGap = r(6, min: 4)
            l.minMeterWidth = r(18, min: 14)
            l.contentHeight = max(height - l.band, line)
            l.height = l.contentHeight + l.band
            return l
        case .bars:
            l.barHeight = pick(r(2, min: 1.5), r(3, min: 2), r(4.5, min: 3))
            l.barGap = pick(r(1.5, min: 1), r(1.5, min: 1), r(2, min: 1.5))
            l.bottomInset = r(3, min: 2)
            l.rowGap = r(6, min: 4)
            l.minMeterWidth = r(18, min: 14)
            // The count keeps a band a line tall; a thin band fits in the pill as it is,
            // a thicker one makes it a few points taller (medium, stacked: 22 → 26.5).
            let content = max(height - r(6, min: 4), line)
            l.height = max(height, content + l.band)
            l.contentHeight = l.height - l.band
            return l
        }
    }

    /// The bars and the room below them.
    public var band: CGFloat {
        guard showsBars else { return 0 }
        let rows = CGFloat(arrangement == .stacked ? count : 1)
        return bottomInset + rows * barHeight + (rows - 1) * barGap
    }

    /// Meters across: two side by side in a row, else one.
    var across: Int { arrangement == .row ? count : 1 }

    /// From the pill's side to a band meter: bars run between the rounded ends.
    public func barInset(cornerRadius: CGFloat) -> CGFloat {
        style == .thin ? max(8, cornerRadius) : max(6, (cornerRadius * 0.6).rounded())
    }

    /// The narrowest pill that still gives each band meter `minMeterWidth`; 0 when nothing
    /// needs it. The app takes the larger of this and the pill's own width.
    public func minWidth(cornerRadius: CGFloat) -> CGFloat {
        guard showsBars else { return 0 }
        let n = CGFloat(across)
        return ceil(2 * barInset(cornerRadius: cornerRadius) + n * minMeterWidth + (n - 1) * rowGap)
    }

    /// Each band meter's rectangle in a pill `width` wide (origin top left), session first:
    /// stacked top to bottom, or a row left to right. All of them are below `contentHeight`.
    public func barRects(width: CGFloat, cornerRadius: CGFloat) -> [CGRect] {
        guard showsBars else { return [] }
        let inset = barInset(cornerRadius: cornerRadius)
        let usable = max(0, width - 2 * inset)
        let bottom = height - bottomInset
        if arrangement == .row {
            let n = CGFloat(count)
            let w = max(0, (usable - (n - 1) * rowGap) / n)
            return (0..<count).map { i in
                CGRect(x: inset + CGFloat(i) * (w + rowGap), y: bottom - barHeight, width: w, height: barHeight)
            }
        }
        return (0..<count).map { i in
            let below = CGFloat(count - 1 - i)
            return CGRect(x: inset, y: bottom - barHeight - below * (barHeight + barGap), width: usable, height: barHeight)
        }
    }

    /// The rings' slot after the count: as wide as they need, before any percentages.
    public var ringsWidth: CGFloat {
        guard showsRings else { return 0 }
        let n = CGFloat(arrangement == .row ? count : 1)
        return ringLeading + n * ringDiameter + (n - 1) * ringGap
    }

    /// Each ring's bounding square in the rings' slot (`ringsWidth` × `height`, origin top
    /// left), session first. Side by side, or one inside the other (session outside). The
    /// stroke is drawn inside the square.
    public var ringRects: [CGRect] {
        guard showsRings else { return [] }
        let y = (height - ringDiameter) / 2
        if arrangement == .row {
            return (0..<count).map { i in
                CGRect(x: ringLeading + CGFloat(i) * (ringDiameter + ringGap), y: y, width: ringDiameter, height: ringDiameter)
            }
        }
        let outer = CGRect(x: ringLeading, y: y, width: ringDiameter, height: ringDiameter)
        guard count == 2 else { return [outer] }
        return [outer, outer.insetBy(dx: ringStroke + ringGap, dy: ringStroke + ringGap)]
    }

    /// The percentages' type: from the pill's small size (`base`), a point smaller for
    /// small, and the pill's own size for large.
    public func numberSize(_ base: CGFloat) -> CGFloat {
        switch size {
        case .small: return max(8, base - 1)
        case .medium: return base
        case .large: return max(base, font)
        }
    }

    /// The idle "Nothing needs you" pill rests at a faint 0.35 opacity. While it shows
    /// meters it rests at this at least, so the numbers can be read; with none it's as faint
    /// as before. The waiting pill keeps Settings → Panel → Opacity as chosen.
    public static let idleMinimumAlpha: Double = 0.6

    public static func idleAlpha(_ base: Double, showsMeters: Bool) -> Double {
        showsMeters ? max(base, idleMinimumAlpha) : base
    }
}
