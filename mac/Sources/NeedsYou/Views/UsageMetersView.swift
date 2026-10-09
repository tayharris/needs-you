import NeedsYouCore
import SwiftUI

// Usage meters (UsageMeters in NeedsYouCore, Settings → Usage): a section at the top of the
// open panel and two hairlines along the pill's bottom edge. Plain read-only drawing: no
// buttons, links or anything focusable, and nothing here counts, animates or announces.

extension AppModel {
    /// The panel's rows, with Settings → Usage applied.
    var usageRows: [UsageRow] {
        UsageMeters.rows(statuses, prefs: settings.usage, now: now)
    }

    /// The pill's hairlines; empty when Settings → Usage turns them off.
    var pillUsageBars: [UsageBar] {
        settings.usage.onPill ? UsageMeters.pillBars(usageRows) : []
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
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(Theme.muted)
            UsageTrack(pct: bar.pct, color: bar.level.color, height: 4)
            Text(verbatim: bar.pctText)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(bar.level == .normal ? Theme.text.opacity(0.8) : bar.level.color)
            Text(verbatim: bar.resetText ?? "")
                .frame(width: 92, alignment: .leading)
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: max(pct > 0 ? height : 0, proxy.size.width * min(1, max(0, pct / 100))))
            }
        }
        .frame(height: height)
    }
}

/// The pill's meters: one hairline per window (session above weekly), inset from the
/// rounded ends. Drawn over the pill, so its size and count never change.
struct PillUsageMeter: View {
    let bars: [UsageBar]
    let metrics: PillMetrics

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(bars) { bar in
                UsageTrack(pct: bar.pct, color: bar.level == .normal ? Theme.text.opacity(0.45) : bar.level.color,
                           height: 1.5)
            }
        }
        .padding(.horizontal, max(6, metrics.cornerRadius * 0.8))
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }
}
