import AppKit
import NeedsYouCore
import SwiftUI

// Usage meters (UsageMeters in NeedsYouCore, Settings → Usage): a section at the top of the
// open panel, and on the collapsed pill (waiting and idle) bars, thin bars or percentages
// (PillMeterStyle, PillMeterLayout). Plain read-only drawing: no buttons, links or anything
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

    /// Where the waiting pill's meters go; none on the "Minimal dot".
    func waitingMeterLayout(_ content: PillContent) -> PillMeterLayout {
        let m = pillMetrics
        return PillMeterLayout.make(settings.usage.pillStyle, count: content.isDot ? 0 : pillUsageBars.count,
                                    height: m.height, font: m.font)
    }

    /// Where the idle pill's meters go (it's taller on hover).
    var idleMeterLayout: PillMeterLayout {
        let m = metrics
        return PillMeterLayout.make(settings.usage.pillStyle, count: pillUsageBars.count,
                                    height: hovering ? m.idleHoverHeight : m.idleHeight, font: m.idleFont)
    }
}

enum PillMeterMetrics {
    /// The percentages' type: the pill's small size, digits monospaced.
    static func percentFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    /// One percentage's slot, as wide as "100%", so the pill never resizes as they change.
    static func percentSlot(_ size: CGFloat) -> CGFloat {
        ceil(("100%" as NSString).size(withAttributes: [.font: percentFont(size)]).width)
    }

    static let percentSpacing: CGFloat = 4
    static let percentLeading: CGFloat = 5

    /// What `.percent` adds to the pill's width: a slot per meter, fixed.
    static func percentWidth(_ layout: PillMeterLayout, size: CGFloat) -> CGFloat {
        guard layout.showsPercent else { return 0 }
        let n = CGFloat(layout.count)
        return percentLeading + n * percentSlot(size) + (n - 1) * percentSpacing
    }

    /// Bars run between the rounded ends.
    static func barInset(cornerRadius: CGFloat) -> CGFloat { max(6, (cornerRadius * 0.6).rounded()) }
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

/// The pill's meters as bars or thin bars (PillMeterLayout): one per window, session above
/// weekly, between the rounded ends. Bars sit in their own band under the count; thin bars
/// are drawn over the pill's bottom edge.
struct PillUsageMeter: View {
    let bars: [UsageBar]
    let layout: PillMeterLayout
    let cornerRadius: CGFloat

    var body: some View {
        VStack(spacing: layout.barGap) {
            ForEach(bars) { bar in
                UsageTrack(pct: bar.pct,
                           color: bar.level == .normal ? Theme.text.opacity(layout.fillOpacity) : bar.level.color,
                           height: layout.barHeight, trackOpacity: layout.trackOpacity)
            }
        }
        .padding(.horizontal, layout.style == .bars ? PillMeterMetrics.barInset(cornerRadius: cornerRadius)
                                                   : max(8, cornerRadius))
        .padding(.bottom, layout.bottomInset)
        .allowsHitTesting(false)
    }
}

/// `.percent`: "31% 10%" in small type after the count, each in a fixed slot.
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

/// A collapsed pill's content with its meters: the count (or idle line) centred in its band,
/// bars below it, thin bars over the bottom edge, or percentages after it.
struct PillWithMeters<Content: View>: View {
    let bars: [UsageBar]
    let layout: PillMeterLayout
    let cornerRadius: CGFloat
    let percentSize: CGFloat
    /// Room after the percentages, for a pill whose content brings its own padding.
    var percentTrailing: CGFloat = 0
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content()
                if layout.showsPercent {
                    PillUsagePercent(bars: bars, size: percentSize).padding(.trailing, percentTrailing)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: layout.contentHeight)
            if layout.style == .bars && layout.showsBars {
                Spacer(minLength: 0)
                PillUsageMeter(bars: bars, layout: layout, cornerRadius: cornerRadius)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if layout.style == .thin && layout.showsBars {
                PillUsageMeter(bars: bars, layout: layout, cornerRadius: cornerRadius)
            }
        }
    }
}
