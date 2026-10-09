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
                .id(Theme.palette)
                .frame(width: m.expandedWidth - 2 * m.listPadding)
                .padding(m.listPadding)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                .opacity(settings.ui.panelOpacity)
                .environment(\.colorScheme, Theme.colorScheme)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.2), value: settings.ui)
        }
        .padding(.vertical, 4)
    }
}

/// Settings → Appearance → Alert style: an item arriving on the pill, as it really does (ArrivalPreview). The
/// pill shows what was waiting, springs out to the new item's preview while the arrival
/// animation plays at the chosen plays and speed, then springs back with the new count.
/// Plays when an alert or arrival setting changes; Urgent and Normal play it again. Over
/// the same sample desktop as Appearance, top-right like the pill's home corner.
struct AlertPreview: View {
    @ObservedObject var settings: AppSettings
    @State private var priority: ItemPriority = .urgent
    @State private var stage: ArrivalPreview.Stage = .before
    @State private var glow: Double = 0
    @State private var ripple: Double = 0
    @State private var motion: Double = 0
    /// The arrival playing, if any.
    @State private var active: ArrivalPlan?
    @State private var run = 0
    @State private var holdSeconds: Double = 0

    var body: some View {
        let m = settings.ui.metrics
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview: a new item arriving on the pill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Urgent") { play(.urgent) }
                Button("Normal") { play(.normal) }
            }
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: stageHeight(m))
                .overlay(alignment: .topTrailing) {
                    pill(m)
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                }
                .background(DesktopBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .environment(\.colorScheme, Theme.colorScheme)
            .accessibilityHidden(true)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .onAppear { play(priority) }
        .onChange(of: settings.ui.alertIntensity(for: .urgent)) { _, _ in play(.urgent) }
        .onChange(of: settings.ui.alertIntensity(for: .normal)) { _, _ in play(.normal) }
        .onChange(of: settings.ui.arrivalAnimation(for: .urgent)) { _, _ in play(.urgent) }
        .onChange(of: settings.ui.arrivalAnimation(for: .normal)) { _, _ in play(.normal) }
        .onChange(of: settings.ui.arrivalSpeed) { _, _ in play(priority) }
        .onChange(of: settings.ui.arrivalRepeats) { _, _ in play(priority) }
        .onChange(of: settings.ui.panelSize) { _, _ in play(priority) }
    }

    private var caption: String {
        let real = settings.ui.previewSeconds
        let shown = holdSeconds > 0 ? String(format: "%.1f s", holdSeconds) : "a moment"
        let realText = real > 0 ? "\(real) s" : "until you click or point at it"
        return "Shown for \(shown) here; on your screen the new item stays out \(realText) (Show new items for, below). Nothing is posted."
    }

    private var waiting: [Item] { ArrivalPreview.waitingBefore() }
    private var arrived: Item { ArrivalPreview.sampleItem(priority) }
    private var after: [Item] { [arrived] + waiting }

    /// The preview's size: one title line, no link (PreviewLayout, as PanelController sizes it).
    private func previewSize(_ m: PanelMetrics) -> CGSize {
        CGSize(width: m.previewWidth, height: PreviewLayout.height(m, titleLines: 1, hasLink: false))
    }

    private func stageHeight(_ m: PanelMetrics) -> CGFloat {
        max(130, previewSize(m).height + 2 * AlertStyle.maxGlowRadius + 50)
    }

    private func size(_ m: PanelMetrics) -> CGSize {
        switch stage {
        case .arrived: return previewSize(m)
        case .before: return PillLayout.size(SamplePill.content(waiting, newCount: 0, settings: settings), metrics: settings.ui.pillMetrics)
        case .after: return PillLayout.size(SamplePill.content(after, newCount: 1, settings: settings), metrics: settings.ui.pillMetrics)
        }
    }

    @ViewBuilder
    private func content(_ m: PanelMetrics) -> some View {
        switch stage {
        case .before:
            PillContentView(content: SamplePill.content(waiting, newCount: 0, settings: settings), metrics: settings.ui.pillMetrics)
        case .arrived:
            PreviewPill(item: arrived, now: Date(), needsLabel: settings.needsLabel, metrics: m)
        case .after:
            PillContentView(content: SamplePill.content(after, newCount: 1, settings: settings), metrics: settings.ui.pillMetrics)
        }
    }

    /// The panel's shape, layered like RootView: content, Bright's tint, the glass, the
    /// ring in the top priority's colour, the hairline, then the glow and ripple outside.
    private func pill(_ m: PanelMetrics) -> some View {
        let pm = settings.ui.pillMetrics
        let s = size(m)
        let dot = stage != .arrived && SamplePill.content(stage == .before ? waiting : after,
                                                          newCount: 0, settings: settings).isDot
        let shape = RoundedRectangle(cornerRadius: stage == .arrived ? 14 : (dot ? pm.height / 2 : pm.cornerRadius),
                                     style: .continuous)
        let top = (stage == .before ? waiting : after).map(\.priority).min() ?? .low
        let look = settings.ui.alertLook(for: top)
        let color = Theme.color(priority)
        return content(m)
            .frame(width: s.width, height: s.height)
            .background(look.fillOpacity > 0 ? Theme.color(top).opacity(look.fillOpacity) : Color.clear)
            .background(PanelGlass(palette: Theme.palette, backdrop: settings.ui.backdrop))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.color(top).opacity(look.ringOpacity), lineWidth: look.ringWidth))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .opacity(stage == .arrived ? settings.ui.panelOpacity : settings.ui.pillOpacity)
            .background(GlowEdge(shape: shape, color: color, glow: glow, look: active?.look ?? look))
            .background(RippleEdge(shape: shape, color: color, progress: ripple, plan: active ?? .idle(look)))
            .modifier(ArrivalMotionEffect(plan: active?.animation.movesPanel == true ? active : nil, value: motion))
            .padding(AlertStyle.maxGlowRadius)
            .id(Theme.palette)
    }

    /// Before → arrived (the spring and the animation) → after.
    private func play(_ chosen: ItemPriority) {
        run += 1
        let id = run
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let plan = settings.ui.arrivalPlan(for: chosen, basePulses: chosen == .urgent ? 2 : 1, reduceMotion: reduceMotion)
        let script = ArrivalPreview.script(plan, previewSeconds: settings.ui.previewSeconds)
        // The shape change: PanelController's overshoot, or a fade under Reduce Motion.
        let spring: Animation = reduceMotion
            ? .easeInOut(duration: 0.2)
            : .timingCurve(0.34, 1.36, 0.64, 1, duration: ArrivalPreview.springSeconds)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            priority = chosen
            stage = .before
            glow = 0
            ripple = 0
            motion = 0
            active = nil
            holdSeconds = script.hold
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(script.lead * 1_000_000_000))
            guard id == run else { return }
            withTransaction(reset) { active = plan.isEmpty ? nil : plan }
            withAnimation(spring) { stage = .arrived }
            if !plan.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(script.motionDelay * 1_000_000_000))
                    guard id == run else { return }
                    switch plan.animation {
                    case .glow: await ArrivalRunner.run(plan) { if id == run { glow = $0 } }
                    case .ripple: await ArrivalRunner.run(plan) { if id == run { ripple = $0 } }
                    default: await ArrivalRunner.run(plan) { if id == run { motion = $0 } }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(script.hold * 1_000_000_000))
            guard id == run else { return }
            withAnimation(spring) { stage = .after }
            try? await Task.sleep(nanoseconds: UInt64(ArrivalPreview.springSeconds * 1_000_000_000))
            guard id == run else { return }
            withTransaction(reset) {
                active = nil
                glow = 0
                ripple = 0
                motion = 0
            }
        }
    }
}
