import AppKit
import NeedsYouCore
import SwiftUI

// How the collapsed pill draws its usage meters (UsagePrefs.pillAppearance, PillMeterLayout):
// a style, a size, and where they apply the layout and the percentages, with a live preview
// of the pill. Self-contained rows, so a Settings page can host them in any Section.
// Settings window only: nothing here is in the panel.

struct UsageMeterAppearanceSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let style = settings.usage.pillStyle
        Group {
            Picker(selection: $settings.usage.pillStyle) {
                ForEach(PillMeterStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Style", Self.detail(style))
            }
            Picker(selection: $settings.usage.pillSize) {
                ForEach(PillMeterSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Size", "How thick the bars are, how big the rings, how large the percentages.")
            }
            .pickerStyle(.segmented)
            if style.canArrange {
                Picker(selection: $settings.usage.pillArrangement) {
                    ForEach(PillMeterArrangement.allCases, id: \.self) { Text($0.title(for: style)).tag($0) }
                } label: {
                    LabelWithDetail("Layout", style == .rings
                        ? "The session and weekly rings next to each other, or the session ring around the weekly one."
                        : "Session above weekly, or the two side by side on one line (the pill is a little wider and less tall).")
                }
                .pickerStyle(.segmented)
            }
            if style.canShowNumbers {
                Toggle(isOn: $settings.usage.pillNumbers) {
                    LabelWithDetail("Show percentages", "The numbers after the count too, like \u{201C}31% 10%\u{201D}. The pill gets wider.")
                }
            }
            UsageMeterPillPreview(settings: settings)
        }
        .disabled(!settings.usage.onPill)
    }

    static func detail(_ style: PillMeterStyle) -> String {
        switch style {
        case .bars: return "Bars under the count, on a faint track. The pill grows a few points taller for them."
        case .thin: return "Thin lines along the bottom edge. The waiting pill keeps its size; the idle pill grows a point or two so its text clears them."
        case .rings: return "A ring per window after the count, filled clockwise from the top. The pill gets wider."
        case .percent: return "Session and weekly percentages after the count, like \u{201C}31% 10%\u{201D}. The pill gets wider."
        }
    }
}

/// The collapsed pill at the chosen style and size: waiting at a few session / weekly
/// percentages (quiet, past the warning line, full), and idle.
struct UsageMeterPillPreview: View {
    @ObservedObject var settings: AppSettings

    /// Session and weekly percentages to show.
    static let examples: [(Double, Double)] = [(8, 3), (31, 10), (85, 62), (100, 97)]

    var body: some View {
        let warn = settings.usage.warnPct
        let now = Date()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ForEach(Array(Self.examples.enumerated()), id: \.offset) { _, pair in
                    waiting(UsageMeters.exampleBars(session: pair.0, weekly: pair.1, warnPct: warn, now: now))
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 10) {
                idle(UsageMeters.exampleBars(session: 31, weekly: 10, warnPct: warn, now: now))
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .environment(\.colorScheme, Theme.colorScheme)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the pill's usage meters")
    }

    /// The waiting pill with three items.
    private func waiting(_ bars: [UsageBar]) -> some View {
        let m = settings.ui.pillMetrics
        let items = (1...3).map { i in
            Item(id: "meter-preview-\(i)", key: "meter-preview-\(i)", title: "Example \(i)", createdAt: Date())
        }
        let content = PillContent.make(PillInput(context: .work, items: items, needsLabel: settings.needsLabel),
                                       options: PillOptions(size: settings.ui.pillSize), hovering: false)
        let layout = PillMeterLayout.make(settings.usage.pillAppearance, count: bars.count, height: m.height, font: m.font)
        let trailing = PillMeterMetrics.trailingWidth(layout, base: m.smallFont)
        let width = max(PillLayout.size(content, metrics: m, trailing: trailing).width,
                        layout.minWidth(cornerRadius: m.cornerRadius))
        return sample(width: width, height: layout.height, radius: m.cornerRadius) {
            PillWithMeters(bars: bars, layout: layout, cornerRadius: m.cornerRadius, numberBase: m.smallFont) {
                PillContentView(content: content, metrics: m)
            }
        }
    }

    /// The idle pill, as faint as it rests on the desktop.
    private func idle(_ bars: [UsageBar]) -> some View {
        let panel = settings.ui.metrics
        let layout = PillMeterLayout.make(settings.usage.pillAppearance, count: bars.count,
                                          height: panel.idleHeight, font: panel.idleFont)
        let text = "Nothing \(settings.needsLabel)"
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: panel.idleFont)]).width
        let width = max(panel.idleWidth(textWidth: textWidth + PillMeterMetrics.trailingWidth(layout, base: panel.idleFont - 1)),
                        layout.minWidth(cornerRadius: 9))
        return sample(width: width, height: layout.height, radius: 9) {
            PillWithMeters(bars: bars, layout: layout, cornerRadius: 9, numberBase: panel.idleFont - 1, trailing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                    Text(verbatim: text).font(.system(size: panel.idleFont)).foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.trailing, layout.showsTrailing ? 0 : 8)
            }
        }
        .opacity(PillMeterLayout.idleAlpha(0.35, showsMeters: layout.count > 0))
    }

    private func sample<V: View>(width: CGFloat, height: CGFloat, radius: CGFloat,
                                 @ViewBuilder _ content: () -> V) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content()
            .frame(width: width, height: height)
            .background(Theme.raised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
