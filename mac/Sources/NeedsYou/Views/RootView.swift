import NeedsYouCore
import SwiftUI

/// Fills the whole panel. The visible shape sits inside the glow padding; the material
/// behind it is the panel's NSVisualEffectView, so this view only draws content, the
/// priority ring, the hairline and the glow.
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var glow: Double = 0
    @State private var glowColor: Color = Theme.normal

    var body: some View {
        let display = model.display
        content(display)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(shape(display))
            .overlay(ring(display))
            .overlay(shape(display).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .background(
                // Soft glow outside the edge; only visible while a pulse runs.
                shape(display)
                    .stroke(glowColor.opacity(glow * 0.9), lineWidth: 2)
                    .shadow(color: glowColor.opacity(glow), radius: 7)
                    .shadow(color: glowColor.opacity(glow * 0.6), radius: 3)
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
            PreviewPill(item: item, now: model.now)
                .contentShape(Rectangle())
                .onTapGesture { model.expand() }
        case .expanded:
            ExpandedView(model: model)
        }
    }

    private func shape(_ display: PanelDisplay) -> RoundedRectangle {
        switch display {
        case .idle: return RoundedRectangle(cornerRadius: model.hovering ? 11 : 5, style: .continuous)
        case .waiting: return RoundedRectangle(cornerRadius: 11, style: .continuous)
        case .preview, .expanded: return RoundedRectangle(cornerRadius: 14, style: .continuous)
        }
    }

    @ViewBuilder
    private func ring(_ display: PanelDisplay) -> some View {
        switch display {
        case .waiting, .preview:
            // Thin ring in the colour of the highest open priority.
            shape(display).strokeBorder(Theme.color(model.highestPriority ?? previewPriority(display)).opacity(model.count > 0 ? 0.9 : 0.25), lineWidth: 1.25)
        default:
            EmptyView()
        }
    }

    private func previewPriority(_ display: PanelDisplay) -> ItemPriority? {
        if case .preview(let item) = display { return item.priority }
        return nil
    }

    private func runPulse(_ request: PulseRequest) {
        glowColor = Theme.color(request.priority)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task { @MainActor in
            for _ in 0..<max(1, request.times) {
                withAnimation(.easeOut(duration: reduceMotion ? 0.4 : 0.35)) { glow = 1 }
                try? await Task.sleep(nanoseconds: 450_000_000)
                withAnimation(.easeIn(duration: reduceMotion ? 0.6 : 0.5)) { glow = 0 }
                try? await Task.sleep(nanoseconds: 550_000_000)
            }
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
            .onTapGesture { model.toggleExpanded() }
    }
}

extension View {
    func pillInteraction(_ model: AppModel) -> some View { modifier(PillInteraction(model: model)) }
}

struct IdlePill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            if model.hovering {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.lastError == nil && model.isConfigured ? Color.green.opacity(0.8) : Theme.faint)
                        .frame(width: 5, height: 5)
                    Text(model.isConfigured && model.lastError == nil ? "All clear · \(model.statusLine.lowercased())" : model.statusLine)
                        .font(Theme.meta)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pillInteraction(model)
        .help(model.statusLine)
    }
}

struct CountPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Text("\(model.count)")
                .foregroundStyle(.white.opacity(model.count > 0 ? 0.95 : 0.5))
            if model.otherCount > 0 {
                // Out-of-context items show as a faint second number ("3 · 1").
                Text("· \(model.otherCount)")
                    .foregroundStyle(Theme.faint)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pillInteraction(model)
        .help("\(model.count) \(model.context.rawValue) item\(model.count == 1 ? "" : "s") need you · \(model.statusLine)")
    }
}

/// Phase 3: the springy new-item preview (title and source).
struct PreviewPill: View {
    let item: Item
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.color(item.priority)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Format.meta(item, now: now))
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
