import NeedsYouCore
import SwiftUI

/// Fills the whole panel. The visible shape sits inside the glow padding; the material
/// behind it is the panel's NSVisualEffectView, so this view only draws content, the
/// priority ring, the hairline and the glow.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var glow: Double = 0
    @State private var glowColor: Color = Theme.normal
    @State private var glowLook = AlertStyle.look(.normal, priority: .normal)

    var body: some View {
        let display = model.display
        content(display)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint(display))
            .clipShape(shape(display))
            .overlay(ring(display))
            .overlay(shape(display).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .background(
                // Soft glow outside the edge; only visible while a pulse runs.
                GlowEdge(shape: shape(display), color: glowColor, glow: glow, look: glowLook)
            )
            .padding(PanelController.glowPadding)
            .environment(\.colorScheme, .dark)
            .environment(\.openURL, OpenURLAction { url in
                model.open(url) ? .handled : .discarded
            })
            .onChange(of: model.pulse) { _, request in
                if let request { runPulse(request) }
            }
    }

    @ViewBuilder
    private func content(_ display: PanelDisplay) -> some View {
        switch display {
        case .idle:
            IdlePill(model: model)
        case .waiting:
            CountPill(model: model)
        case .preview(let item):
            PreviewPill(item: item, now: model.now, needsLabel: model.needsLabel, metrics: model.metrics)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in model.dragHandler?(.changed) }
                        .onEnded { _ in model.dragHandler?(.ended) }
                )
                .onTapGesture {
                    // An urgent item from the other context opens that side.
                    if item.context != model.context { model.setContext(item.context) }
                    model.expand(byUser: true)
                }
        case .digest(let digest):
            DigestPill(digest: digest, metrics: model.metrics)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in model.dragHandler?(.changed) }
                        .onEnded { _ in model.dragHandler?(.ended) }
                )
                .onTapGesture { model.expand(byUser: true) }
        case .expanded:
            ExpandedView(model: model)
        }
    }

    private func shape(_ display: PanelDisplay) -> RoundedRectangle {
        switch display {
        case .idle: return RoundedRectangle(cornerRadius: model.hovering ? 11 : 9, style: .continuous)
        case .waiting: return RoundedRectangle(cornerRadius: 11, style: .continuous)
        case .preview, .digest, .expanded: return RoundedRectangle(cornerRadius: 14, style: .continuous)
        }
    }

    @ViewBuilder
    private func ring(_ display: PanelDisplay) -> some View {
        switch display {
        case .waiting, .preview, .digest:
            // Thin ring in the colour of the highest open priority; Settings → Alerts sets how strong.
            let priority = model.highestPriority ?? previewPriority(display)
            let look = model.alertLook(priority ?? .low)
            shape(display).strokeBorder(Theme.color(priority).opacity(model.count > 0 ? look.ringOpacity : AlertStyle.otherContextRingOpacity),
                                        lineWidth: look.ringWidth)
        default:
            EmptyView()
        }
    }

    /// Bright alerts tint the count pill and preview in the priority colour.
    @ViewBuilder
    private func tint(_ display: PanelDisplay) -> some View {
        switch display {
        case .waiting, .preview, .digest:
            let priority = model.highestPriority ?? previewPriority(display)
            let look = model.alertLook(priority ?? .low)
            if model.count > 0 || previewPriority(display) != nil, look.fillOpacity > 0 {
                Theme.color(priority).opacity(look.fillOpacity)
            }
        default:
            EmptyView()
        }
    }

    private func previewPriority(_ display: PanelDisplay) -> ItemPriority? {
        switch display {
        case .preview(let item): return item.priority
        case .digest(let digest): return digest.priority
        default: return nil
        }
    }

    private func runPulse(_ request: PulseRequest) {
        // Ambient arrivals (delivery tiers) get one soft brighten at most.
        var look = request.ambient
            ? AlertStyle.ambientLook(model.settings.ui.alertIntensity(for: request.priority), priority: request.priority)
            : model.alertLook(request.priority, basePulses: request.times)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { look = look.reducedMotion() }
        guard look.pulses > 0 else { return }   // Alerts → Off (never for urgent: it has a floor)
        glowColor = Theme.color(request.priority)
        glowLook = look
        Task { @MainActor in
            await PulseRunner.run(look) { glow = $0 }
        }
    }
}

// MARK: - Collapsed states

/// Shared tap-to-expand and drag-to-move behaviour for the collapsed shapes.
private struct PillInteraction: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in model.dragHandler?(.changed) }
                    .onEnded { _ in model.dragHandler?(.ended) }
            )
            .onTapGesture { model.isConfigured ? model.toggleExpanded() : model.openSettings() }
    }
}

extension View {
    func pillInteraction(_ model: AppModel) -> some View { modifier(PillInteraction(model: model)) }
}

struct IdlePill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // At rest a small, faint "Nothing needs <you>" (still easy to drag, right-click or
        // hide); on hover the full status line.
        HStack(spacing: 6) {
            if model.isFocused {
                // Focus is on (right-click → Focus); the link badge when a link set it.
                Image(systemName: "moon.fill")
                    .font(.system(size: model.metrics.idleFont - 1))
                    .foregroundStyle(Theme.muted)
                if model.focusSetByLink {
                    Image(systemName: "link")
                        .font(.system(size: model.metrics.idleFont - 2, weight: .semibold))
                        .foregroundStyle(Theme.normal.opacity(0.9))
                }
            } else {
                Circle()
                    .fill(model.lastError == nil && model.isConfigured ? Color.green.opacity(0.8) : Theme.faint)
                    .frame(width: 5, height: 5)
            }
            Text(model.hovering ? model.idleHoverLine : model.idleRestLine)
                .font(.system(size: model.metrics.idleFont))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.15), value: model.hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pillInteraction(model)
        .help(model.focusSummary.map { "Focus: \($0) · \(model.statusLine)" } ?? model.statusLine)
    }
}

struct CountPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            if model.isFocused {
                Image(systemName: "moon.fill")
                    .font(.system(size: model.metrics.countFont - 3))
                    .foregroundStyle(Theme.muted)
                if model.focusSetByLink {
                    // Set by a needsyou://focus link, not by hand.
                    Image(systemName: "link")
                        .font(.system(size: model.metrics.countFont - 4, weight: .semibold))
                        .foregroundStyle(Theme.normal.opacity(0.9))
                }
            }
            Text("\(model.count)")
                .foregroundStyle(.white.opacity(model.count > 0 ? 0.95 : 0.5))
            if model.otherCount > 0 {
                // Out-of-context items show as a faint second number ("3 · 1").
                Text("· \(model.otherCount)")
                    .foregroundStyle(Theme.faint)
            }
            if model.laterCount > 0 {
                // Held under Later (not counted): "2 +3".
                Text("+\(model.laterCount)")
                    .foregroundStyle(Theme.faint.opacity(0.8))
            }
        }
        .font(.system(size: model.metrics.countFont, weight: .semibold, design: .rounded).monospacedDigit())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pillInteraction(model)
        .help("\(model.needsLabel): \(model.count) \(model.context.rawValue) item\(model.count == 1 ? "" : "s")"
              + (model.laterCount > 0 ? ", \(model.laterCount) under Later" : "")
              + (model.focusSummary.map { " · Focus: \($0)" } ?? "") + " · \(model.statusLine)")
    }
}

/// Phase 3: the springy new-item preview (title and source).
struct PreviewPill: View {
    let item: Item
    let now: Date
    let needsLabel: String
    let metrics: PanelMetrics

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.color(item.priority)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.title(metrics))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                (Text(item.kind == .needs ? needsLabel : item.kind.rawValue).foregroundStyle(Theme.color(item.priority).opacity(0.9))
                 + Text(" · " + Format.meta(item, now: now)).foregroundStyle(Theme.muted))
                    .font(Theme.meta(metrics))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "3 waited while you were focused": the quiet peek that delivers Later.
struct DigestPill: View {
    let digest: LaterDigest
    let metrics: PanelMetrics

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: metrics.titleFont - 1, weight: .medium))
                .foregroundStyle(Theme.color(digest.priority).opacity(0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text(digest.text)
                    .font(Theme.title(metrics))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Click to see them")
                    .font(Theme.meta(metrics))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
