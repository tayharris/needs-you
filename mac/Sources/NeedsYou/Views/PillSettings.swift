import NeedsYouCore
import SwiftUI

// Settings → Panel → Collapsed pill: its size, how much it says, how it splits the count,
// and the "N new" badge (UIPrefs pill keys; PillContent in NeedsYouCore). Settings window
// only, never the floating panel.

struct PillSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            PillSettingsPreview(settings: settings)
            Picker(selection: $settings.ui.pillSize) {
                ForEach(PillSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Pill size", "The collapsed pill only, on top of Size above.")
            }
            Picker(selection: $settings.ui.pillDetail) {
                ForEach(PillDetail.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Shows", "The count, the count and the top card's title, or just a dot in the top priority's colour (hover for the count).")
            }
            Picker(selection: $settings.ui.pillSplit) {
                ForEach(PillSplit.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Split", "One count, work and personal side by side, or urgent, normal and low in their colours.")
            }
            Toggle(isOn: $settings.ui.pillShowNew) {
                LabelWithDetail("New since last opened", "A small “2 new” next to the count for what arrived or changed since you last opened the panel.")
            }
        } header: {
            Text("Collapsed pill")
        }
    }
}

/// Sample pills at the chosen options: three work items (urgent, normal, low), one
/// personal, two new. "Minimal dot" shows the pill at rest and on hover.
private struct PillSettingsPreview: View {
    @ObservedObject var settings: AppSettings

    private func sampleInput() -> PillInput {
        let now = Date()
        let items = [
            Item(id: "pill-preview-1", key: "pill-preview-1", priority: .urgent,
                 title: "Approve the prod deploy for ACME-4700", createdAt: now),
            Item(id: "pill-preview-2", key: "pill-preview-2", priority: .normal,
                 title: "Review the schema migration", createdAt: now),
            Item(id: "pill-preview-3", key: "pill-preview-3", priority: .low,
                 title: "Rotate the staging key", createdAt: now),
        ]
        return PillInput(context: .work, items: items, otherCount: 1, newCount: 2, needsLabel: settings.needsLabel)
    }

    var body: some View {
        let metrics = settings.ui.pillMetrics
        let options = settings.ui.pillOptions
        let input = sampleInput()
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 18) {
                sample(PillContent.make(input, options: options, hovering: false), metrics: metrics,
                       caption: options.detail == .dot ? "At rest" : nil)
                if options.detail == .dot {
                    sample(PillContent.make(input, options: options, hovering: true), metrics: metrics, caption: "On hover")
                }
                Spacer(minLength: 0)
            }
            .id(Theme.palette)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        }
        .padding(.vertical, 4)
        .environment(\.colorScheme, Theme.colorScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.2), value: settings.ui)
    }

    @ViewBuilder
    private func sample(_ content: PillContent, metrics m: PillMetrics, caption: String?) -> some View {
        let size = PillLayout.size(content, metrics: m)
        let shape = RoundedRectangle(cornerRadius: content.isDot ? m.height / 2 : m.cornerRadius, style: .continuous)
        let look = settings.ui.alertLook(for: .urgent)
        VStack(spacing: 4) {
            PillContentView(content: content, metrics: m)
                .frame(width: size.width, height: size.height)
                .background(Theme.raised)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.urgent.opacity(look.ringOpacity), lineWidth: look.ringWidth))
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
