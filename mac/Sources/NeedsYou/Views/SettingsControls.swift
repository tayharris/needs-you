import NeedsYouCore
import SwiftUI

// Small pieces of the Settings window. Everything here lives in the Settings window only,
// never in the floating panel (which must never take focus).

/// A setting's name with a one-line explanation under it.
struct LabelWithDetail: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A sample card drawn with the panel's own CardView at the chosen size, text size, card
/// text and links settings. It can't be clicked.
struct PanelPreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    static func sample(now: Date) -> Item {
        Item(
            id: "settings-preview", key: "settings-preview", priority: .normal,
            title: "Approve the prod deploy for ACME-4700",
            body: "1. Check the **canary** dashboard\n2. Approve in the deploy channel\n3. Reply `go` in the agent's terminal\n4. Watch the error rate for 10 minutes",
            links: [
                ItemLink(label: "Pull request", url: "https://example.com/pr/4700"),
                ItemLink(label: "Canary dashboard", url: "https://example.com/dash"),
                ItemLink(label: "Deploy channel", url: "https://example.com/chat"),
                ItemLink(label: "Runbook", url: "https://example.com/runbook"),
            ],
            source: ItemSource(host: "devbox", agent: "claude"),
            createdAt: now.addingTimeInterval(-26 * 3600)
        )
    }

    var body: some View {
        let m = settings.ui.metrics
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            CardView(item: Self.sample(now: model.now), model: model)
                .frame(width: m.expandedWidth - 2 * m.listPadding)
                .padding(m.listPadding)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
                .opacity(settings.ui.panelOpacity)
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.2), value: settings.ui)
        }
        .padding(.vertical, 4)
    }
}

/// The count pill for an urgent and a normal item at the chosen alert styles. Changing a
/// style plays it; clicking a pill plays it again.
struct AlertPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview: click a pill to play its alert").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                AlertSamplePill(settings: settings, priority: .urgent, count: 2, basePulses: 2)
                AlertSamplePill(settings: settings, priority: .normal, count: 3, basePulses: 1)
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
        }
        .padding(.vertical, 4)
    }
}

private struct AlertSamplePill: View {
    @ObservedObject var settings: AppSettings
    let priority: ItemPriority
    let count: Int
    let basePulses: Int
    @State private var glow: Double = 0
    @State private var playing = false

    var body: some View {
        let m = settings.ui.metrics
        let look = settings.ui.alertLook(for: priority, basePulses: basePulses)
        let color = Theme.color(priority)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: m.countFont, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: m.countWidth(digits: 1), height: m.countHeight)
                .background(color.opacity(look.fillOpacity))
                .background(Color(white: 0.18))
                .clipShape(shape)
                .overlay(shape.strokeBorder(color.opacity(look.ringOpacity), lineWidth: look.ringWidth))
                .background(GlowEdge(shape: shape, color: color, glow: glow, look: look))
                .padding(AlertStyle.maxGlowRadius)
                .contentShape(Rectangle())
                .onTapGesture { play() }
            Text(priority == .urgent ? "Urgent" : "Normal")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: settings.ui.alertIntensity(for: priority)) { _, _ in play() }
        .onChange(of: settings.ui.panelSize) { _, _ in play() }
    }

    private func play() {
        guard !playing else { return }
        var look = settings.ui.alertLook(for: priority, basePulses: basePulses)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { look = look.reducedMotion() }
        guard look.pulses > 0 else { return }
        playing = true
        Task { @MainActor in
            await PulseRunner.run(look) { glow = $0 }
            playing = false
        }
    }
}
