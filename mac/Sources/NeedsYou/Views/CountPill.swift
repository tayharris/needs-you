import AppKit
import NeedsYouCore
import SwiftUI

// The collapsed "waiting" pill. What it says comes from PillContent (NeedsYouCore,
// Settings → Panel → Collapsed pill); this file only draws it and measures the title.
// Nothing here is focusable: the panel never takes focus.

extension AppModel {
    /// Sizes for the collapsed pill (panel size × pill size).
    var pillMetrics: PillMetrics { settings.ui.pillMetrics }

    /// Counted items that arrived, changed or became `needs` since the panel was last open.
    var newCount: Int { store.newNeedsCount(in: context, since: settings.pillLastOpenedAt, now: now) }

    /// What the collapsed pill shows right now.
    var pillContent: PillContent {
        let input = PillInput(context: context, items: needsItems, otherCount: otherCount, laterCount: laterCount,
                              newCount: newCount, focused: isFocused, focusSetByLink: focusSetByLink,
                              needsLabel: needsLabel)
        return PillContent.make(input, options: settings.ui.pillOptions, hovering: hovering)
    }

    /// "Minimal dot" at rest is a circle; otherwise the pill's own radius.
    var pillCornerRadius: CGFloat {
        settings.ui.pillDetail == .dot && !hovering ? pillMetrics.height / 2 : pillMetrics.cornerRadius
    }

    /// The visible shape's size for `.waiting` (PanelController adds the glow padding), with
    /// room for the usage meters (PillMeterLayout: their band, the rings' or percentages'
    /// slots, a row's minimum width).
    var waitingPillSize: CGSize {
        let content = pillContent
        let meters = waitingMeterLayout(content)
        let trailing = PillMeterMetrics.trailingWidth(meters, base: pillMetrics.smallFont)
        let size = PillLayout.size(content, metrics: pillMetrics, trailing: trailing)
        return CGSize(width: max(size.width, meters.minWidth(cornerRadius: pillCornerRadius)), height: meters.height)
    }
}

enum PillLayout {
    static func titleFont(_ m: PillMetrics) -> NSFont { NSFont.systemFont(ofSize: m.titleFont, weight: .medium) }

    /// The pill's size: a circle for the dot, else the counts' digit units plus the title
    /// measured with the same font the view draws it in, plus `trailing` after them.
    static func size(_ content: PillContent, metrics m: PillMetrics, trailing: CGFloat = 0) -> CGSize {
        if content.isDot { return CGSize(width: m.dotWidth, height: m.height) }
        let titleWidth = content.title.map { ($0 as NSString).size(withAttributes: [.font: titleFont(m)]).width }
        return CGSize(width: m.width(units: content.units, titleWidth: titleWidth, trailing: trailing), height: m.height)
    }
}

struct CountPill: View {
    @ObservedObject var model: AppModel
    /// Observed too, so a change in Settings redraws the pill straight away.
    @ObservedObject var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        let content = model.pillContent
        let layout = model.waitingMeterLayout(content)
        // Usage meters (Settings → Appearance → Usage meters): below or beside the count, never over it.
        PillWithMeters(bars: layout.count > 0 ? model.pillUsageBars : [], layout: layout,
                       cornerRadius: model.pillCornerRadius, numberBase: model.pillMetrics.smallFont) {
            PillContentView(content: content, metrics: model.pillMetrics,
                            focused: model.isFocused, focusSetByLink: model.focusSetByLink)
        }
            .animation(.easeInOut(duration: 0.15), value: model.hovering)
            .pillInteraction(model)
            .help(content.help + (model.focusSummary.map { " · Focus: \($0)" } ?? "") + model.pillUsageHelp + " · \(model.statusLine)")
    }
}

/// Draws a PillContent: the focus moon, the counts, the "N new" badge and the title, or
/// just the dot. Shared by the panel and the Settings preview.
struct PillContentView: View {
    let content: PillContent
    let metrics: PillMetrics
    var focused = false
    var focusSetByLink = false

    var body: some View {
        if content.isDot {
            Circle()
                .fill(content.dotPriority.map { Theme.color($0) } ?? Theme.faint)
                .frame(width: metrics.dotSize, height: metrics.dotSize)
        } else {
            HStack(spacing: 3) {
                if focused {
                    Image(systemName: "moon.fill")
                        .font(.system(size: metrics.font - 3))
                        .foregroundStyle(Theme.muted)
                    if focusSetByLink {
                        // Set by a needsyou://focus link, not by hand.
                        Image(systemName: "link")
                            .font(.system(size: metrics.font - 4, weight: .semibold))
                            .foregroundStyle(Theme.accent.opacity(0.9))
                    }
                }
                ForEach(Array(content.segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment).fixedSize()
                }
                if let title = content.title {
                    Text(verbatim: title)
                        .font(.system(size: metrics.titleFont, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, max(0, metrics.titleGap - 3))
                }
            }
            .font(.system(size: metrics.font, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: PillSegment) -> some View {
        switch segment.style {
        case .count(let dim):
            Text(verbatim: segment.text).foregroundStyle(Theme.text.opacity(dim ? 0.5 : 0.95))
        case .other:
            // Out-of-context items: a faint second number ("3 · 1").
            Text(verbatim: segment.text).foregroundStyle(Theme.faint)
        case .later:
            // Held under Later (not counted): "2 +3".
            Text(verbatim: segment.text).foregroundStyle(Theme.faint.opacity(0.8))
        case .context(_, let current):
            HStack(spacing: 2) {
                Text(verbatim: segment.label ?? "")
                    .font(.system(size: metrics.smallFont, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text.opacity(current ? 0.6 : 0.3))
                Text(verbatim: segment.text)
                    .foregroundStyle(Theme.text.opacity(current ? 0.95 : 0.4))
            }
        case .divider:
            Text(verbatim: segment.text).foregroundStyle(Theme.faint.opacity(0.6))
        case .priority(let priority):
            Text(verbatim: segment.text).foregroundStyle(Theme.color(priority))
        case .new:
            Text(verbatim: segment.text)
                .font(.system(size: metrics.smallFont, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.text.opacity(0.9))
                .padding(.horizontal, 4)
                .background(Capsule().fill(Theme.text.opacity(0.16)))
        }
    }
}
