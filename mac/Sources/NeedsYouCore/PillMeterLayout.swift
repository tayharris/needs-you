import CoreGraphics
import Foundation

// Where the collapsed pill's usage meters go (Settings → Usage → On the pill), as numbers
// the app draws with: CountPill and IdlePill draw them, PanelController sizes the pill and
// sets its opacity from them. Pure, so every style and size is unit-tested.

/// The meters' geometry for one pill.
public struct PillMeterLayout: Equatable, Sendable {
    public var style: PillMeterStyle
    /// Meters drawn (one per window, at most two); 0 draws nothing and changes nothing.
    public var count: Int
    public var barHeight: CGFloat
    public var barGap: CGFloat
    /// From the pill's bottom edge to the lowest bar.
    public var bottomInset: CGFloat
    /// The pill's height with the meters.
    public var height: CGFloat
    /// The band at the top that the count (or the idle line) is centred in. Bars sit below
    /// it, so they never cover the digits or a descender; with percentages it's the whole pill.
    public var contentHeight: CGFloat

    public var showsBars: Bool { count > 0 && style != .percent }
    public var showsPercent: Bool { count > 0 && style == .percent }

    /// The track behind the fill (the unfilled part), so 0-100 % reads at a glance. Thin
    /// bars need a stronger one to show at all.
    public var trackOpacity: Double { style == .bars ? 0.22 : 0.28 }
    /// A bar below the warning line: bright enough to read on a dimmed pill.
    public var fillOpacity: Double { 0.85 }

    /// `height` and `font` are the pill's own (PillMetrics, or the idle pill's), so the bars
    /// scale with Settings → Panel → Size and Pill size. Sizes are rounded to half points.
    public static func make(_ style: PillMeterStyle, count: Int, height: CGFloat, font: CGFloat) -> PillMeterLayout {
        let n = max(0, min(2, count))
        var l = PillMeterLayout(style: style, count: n, barHeight: 0, barGap: 0, bottomInset: 0,
                                height: height, contentHeight: height)
        guard n > 0 else { return l }
        switch style {
        case .percent:
            return l
        case .thin:
            // 1.5 pt lines, 2 pt on a pill 24 pt or taller, 1 pt above the bottom edge (0.4.0).
            // The count moves up a little to clear them; the waiting pill keeps its size, the
            // shorter idle pill grows a point so "Nothing needs you" keeps its descenders.
            l.barHeight = height >= 24 ? 2 : 1.5
            l.barGap = 1
            l.bottomInset = 1
            l.contentHeight = max(height - l.band, ceil(font * 1.2))
            l.height = l.contentHeight + l.band
            return l
        case .bars:
            let u = font / 12
            func r(_ v: CGFloat, min floor: CGFloat) -> CGFloat { max(floor, (v * u * 2).rounded() / 2) }
            l.barHeight = r(3, min: 2)
            l.barGap = r(1.5, min: 1)
            l.bottomInset = r(3, min: 2)
            // The count keeps a band a line tall; one bar fits in the pill as it is, a second
            // makes it a few points taller (medium: 22 → 26.5).
            let content = max(height - r(6, min: 4), ceil(font * 1.2))
            l.height = max(height, content + l.band)
            l.contentHeight = l.height - l.band
            return l
        }
    }

    /// The bars and the room below them.
    public var band: CGFloat {
        guard showsBars else { return 0 }
        return bottomInset + CGFloat(count) * barHeight + CGFloat(count - 1) * barGap
    }

    /// The idle "Nothing needs you" pill rests at a faint 0.35 opacity. While it shows
    /// meters it rests at this at least, so the numbers can be read; with none it's as faint
    /// as before. The waiting pill keeps Settings → Panel → Opacity as chosen.
    public static let idleMinimumAlpha: Double = 0.6

    public static func idleAlpha(_ base: Double, showsMeters: Bool) -> Double {
        showsMeters ? max(base, idleMinimumAlpha) : base
    }
}
