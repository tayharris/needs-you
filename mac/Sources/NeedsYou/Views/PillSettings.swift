import AppKit
import NeedsYouCore
import SwiftUI

// settings-section: pill
// Settings → Appearance → Pill: the panel's shape (PanelCorners: the pill, the preview and
// the open panel), the pill's size, how much it says, how it splits the count, and the
// "N new" badge (UIPrefs pill keys; PillContent in NeedsYouCore). Settings window only,
// never the floating panel.

struct PillSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            PillSettingsPreview(settings: settings)
            Picker(selection: $settings.ui.panelShape) {
                ForEach(PanelShape.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Shape", "The corners of the pill, the new-item preview and the open panel together. Capsule gives the pill fully round ends.")
            }
            Picker(selection: $settings.ui.pillSize) {
                ForEach(PillSize.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Pill size", "The pill's height, its text and its usage meters together, waiting or idle. On top of Size in Panel and cards.")
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
                       caption: options.detail == .dot ? "At rest" : "Waiting")
                if options.detail == .dot {
                    sample(PillContent.make(input, options: options, hovering: true), metrics: metrics, caption: "On hover")
                }
                idleSample(metrics)
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
        let shape = PanelOutline(settings.ui, content.isDot ? .dot : .pill)
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

    /// The idle "Nothing needs you" pill at rest (its size and shape follow the same settings).
    private func idleSample(_ m: PillMetrics) -> some View {
        let text = "Nothing \(settings.needsLabel)"
        let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: m.idleFont)]).width
        let shape = PanelOutline(settings.ui, .idle(hovering: false))
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                Text(verbatim: text).font(.system(size: m.idleFont)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: m.idleWidth(textWidth: textWidth), height: m.idleHeight)
            .background(Theme.raised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text("Nothing waiting").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
