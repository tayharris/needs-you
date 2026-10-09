import AppKit
import NeedsYouCore
import SwiftUI

// Usage meters (UsageMeters in NeedsYouCore, Settings → Usage): a section at the top of the
// open panel, and on the collapsed pill (waiting and idle) bars, thin bars, rings or
// percentages, in the chosen arrangement and size (PillMeterAppearance, PillMeterLayout). Plain read-only drawing: no buttons, links or anything
// focusable, and nothing here counts, animates or announces.

extension AppModel {
    /// The panel's rows, with Settings → Usage applied.
    var usageRows: [UsageRow] {
        UsageMeters.rows(statuses, prefs: settings.usage, now: now)
    }

    /// The pill's meters; empty when Settings → Usage turns them off.
    var pillUsageBars: [UsageBar] {
        settings.usage.onPill ? UsageMeters.pillBars(usageRows) : []
    }

    /// The pill's tooltip addition: " · Usage: Claude session 31% · weekly 10%".
    var pillUsageHelp: String {
        let rows = settings.usage.onPill ? usageRows : []
        return rows.isEmpty ? "" : " · Usage: " + UsageMeters.summary(rows)
    }

    /// Where the waiting pill's meters go. None with "Minimal dot", at rest or on hover, so
    /// the dot never changes height when the pointer comes near.
    func waitingMeterLayout(_ content: PillContent) -> PillMeterLayout {
        let m = pillMetrics
        let none = content.isDot || settings.ui.pillDetail == .dot
        return PillMeterLayout.make(settings.usage.pillAppearance, count: none ? 0 : pillUsageBars.count,
                                    height: m.height, font: m.font)
    }

    /// Where the idle pill's meters go (it's taller on hover).
    var idleMeterLayout: PillMeterLayout {
        let m = metrics
        return PillMeterLayout.make(settings.usage.pillAppearance, count: pillUsageBars.count,
                                    height: hovering ? m.idleHoverHeight : m.idleHeight, font: m.idleFont)
    }
}

enum PillMeterMetrics {
    /// The percentages' type, digits monospaced.
    static func percentFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    /// One percentage's slot, as wide as "100%", so the pill never resizes as they change.
    static func percentSlot(_ size: CGFloat) -> CGFloat {
        ceil(("100%" as NSString).size(withAttributes: [.font: percentFont(size)]).width)
    }

    static let percentSpacing: CGFloat = 4
    static let percentLeading: CGFloat = 5

    /// What the percentages add to the pill's width: a slot per meter, fixed. `base` is the
    /// pill's small type size (PillMeterLayout.numberSize).
    static func percentWidth(_ layout: PillMeterLayout, base: CGFloat) -> CGFloat {
        guard layout.showsPercent else { return 0 }
        let n = CGFloat(layout.count)
        return percentLeading + n * percentSlot(layout.numberSize(base)) + (n - 1) * percentSpacing
    }

    /// Everything after the count: the rings, then the percentages.
    static func trailingWidth(_ layout: PillMeterLayout, base: CGFloat) -> CGFloat {
        layout.ringsWidth + percentWidth(layout, base: base)
    }
}

extension UsageLevel {
    /// Quiet until the warning line: the text colour, then the theme's normal (amber) and
    /// urgent (red) colours.
    var color: Color {
        switch self {
        case .normal: return Theme.text.opacity(0.55)
        case .warning: return Theme.normal
        case .full: return Theme.urgent
        }
    }
}

/// The open panel's USAGE section: per provider and account, a title and one bar per window.
struct UsageSection: View {
    let rows: [UsageRow]
    let metrics: PanelMetrics
    let bodyFont: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("USAGE")
                .font(.system(size: metrics.sectionFont, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .padding(.leading, 2)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.title)
                            .font(.system(size: bodyFont - 1, weight: .medium))
                            .foregroundStyle(Theme.text.opacity(0.8))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let host = row.host, !host.isEmpty {
                            Text(verbatim: host)
                                .font(Theme.meta(metrics))
                                .foregroundStyle(Theme.faint)
                                .lineLimit(1)
                        }
                    }
                    ForEach(row.bars) { bar in
                        UsageBarRow(bar: bar, metrics: metrics)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageBarRow: View {
    let bar: UsageBar
    let metrics: PanelMetrics

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: bar.title)
                .lineLimit(1)
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(Theme.muted)
            UsageTrack(pct: bar.pct, color: bar.level.color, height: 4)
            Text(verbatim: bar.pctText)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(bar.level == .normal ? Theme.text.opacity(0.8) : bar.level.color)
            Text(verbatim: bar.resetText ?? "")
                .frame(width: 108, alignment: .leading)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .font(Theme.meta(metrics))
    }
}

/// A rounded track filled to `pct`.
struct UsageTrack: View {
    let pct: Double
    let color: Color
    var height: CGFloat = 4
    var trackOpacity: Double = 0.12

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(trackOpacity))
                Capsule().fill(color)
                    .frame(width: max(pct > 0 ? height : 0, proxy.size.width * min(1, max(0, pct / 100))))
            }
        }
        .frame(height: height)
    }
}

/// A pill meter's colour: quiet until the warning line (the text colour, strong enough to
/// read on a dimmed pill), then amber and red; the track is the text colour, faint.
private func pillMeterColor(_ bar: UsageBar, _ layout: PillMeterLayout) -> Color {
    bar.level == .normal ? Theme.text.opacity(layout.fillOpacity) : bar.level.color
}

/// Bars and thin bars (PillMeterLayout.barRects): one per window, session first,
/// stacked or side by side, in their own band under the count and between the rounded
/// ends. Drawn over the whole pill, so the rectangles are the layout's own.
struct PillUsageBand: View {
    let bars: [UsageBar]
    let layout: PillMeterLayout
    let cornerRadius: CGFloat

    var body: some View {
        Canvas { context, size in
            let track = Theme.text.opacity(layout.trackOpacity)
            func fill(_ r: CGRect, _ color: Color) {
                let radius = min(r.height, r.width) / 2
                context.fill(Path(roundedRect: r, cornerRadius: radius), with: .color(color))
            }
            for (bar, rect) in zip(bars, layout.barRects(width: size.width, cornerRadius: cornerRadius)) {
                fill(rect, track)
                let f = min(1, max(0, bar.pct / 100))
                if f > 0 {
                    // At least a dot, so 1 % shows.
                    let w = min(rect.width, max(rect.height, rect.width * f))
                    fill(CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), pillMeterColor(bar, layout))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Rings after the count (PillMeterLayout.ringRects): filled clockwise from the top on a
/// faint full-circle track; side by side, or session outside and weekly inside.
struct PillUsageRings: View {
    let bars: [UsageBar]
    let layout: PillMeterLayout

    var body: some View {
        Canvas { context, _ in
            let s = layout.ringStroke
            for (bar, rect) in zip(bars, layout.ringRects) {
                let r = rect.insetBy(dx: s / 2, dy: s / 2)
                context.stroke(Path(ellipseIn: r), with: .color(Theme.text.opacity(layout.trackOpacity)), lineWidth: s)
                let f = min(1, max(0, bar.pct / 100))
                guard f > 0 else { continue }
                var arc = Path()
                arc.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                           startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
                context.stroke(arc, with: .color(pillMeterColor(bar, layout)),
                               style: StrokeStyle(lineWidth: s, lineCap: f >= 1 ? .butt : .round))
            }
        }
        .frame(width: layout.ringsWidth, height: layout.height)
        .allowsHitTesting(false)
    }
}

/// The percentages after the count (or the rings): "31% 10%", each in a fixed slot.
struct PillUsagePercent: View {
    let bars: [UsageBar]
    let size: CGFloat

    var body: some View {
        // Side by side at their own widths, centred in a slot wide enough for "100% 100%":
        // the pill keeps its width as the numbers change.
        let n = CGFloat(bars.count)
        HStack(spacing: PillMeterMetrics.percentSpacing) {
            ForEach(bars) { bar in
                Text(verbatim: bar.pctText)
                    .font(Font(PillMeterMetrics.percentFont(size)))
                    .foregroundStyle(bar.level == .normal ? Theme.text.opacity(0.75) : bar.level.color)
                    .lineLimit(1)
            }
        }
        .frame(width: n * PillMeterMetrics.percentSlot(size) + max(0, n - 1) * PillMeterMetrics.percentSpacing)
        .padding(.leading, PillMeterMetrics.percentLeading)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// A collapsed pill's content with its meters (PillMeterLayout): the count (or idle line)
/// centred in its band at the top, bars below it, or rings and percentages after it.
struct PillWithMeters<Content: View>: View {
    let bars: [UsageBar]
    let layout: PillMeterLayout
    let cornerRadius: CGFloat
    /// The pill's small type size; the percentages are drawn at `layout.numberSize(numberBase)`.
    let numberBase: CGFloat
    /// Room after the rings or percentages, for a pill whose content brings its own padding.
    var trailing: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                content()
                if layout.showsRings {
                    PillUsageRings(bars: bars, layout: layout)
                }
                if layout.showsPercent {
                    PillUsagePercent(bars: bars, size: layout.numberSize(numberBase))
                }
                if layout.showsTrailing && trailing > 0 {
                    Color.clear.frame(width: trailing, height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: layout.contentHeight)
            if layout.showsBars {
                PillUsageBand(bars: bars, layout: layout, cornerRadius: cornerRadius)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
