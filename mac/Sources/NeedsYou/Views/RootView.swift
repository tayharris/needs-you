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
    @State private var ripple: Double = 0
    @State private var ripplePlan = ArrivalPlan.idle(AlertStyle.look(.normal, priority: .normal))

    var body: some View {
        let display = model.display
        content(display)
            // A theme change redraws everything (the views read Theme's colours).
            .id(model.palette)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint(display))
            .background(themeTint(display))
            .background(backdrop(display))
            .clipShape(shape(display))
            .overlay(ring(display))
            .overlay(shape(display).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .background(
                // Soft glow outside the edge; only visible while a pulse runs.
                GlowEdge(shape: shape(display), color: glowColor, glow: glow, look: glowLook)
            )
            .background(
                // Arrival animation → Ripple: a ring spreading into the padding.
                RippleEdge(shape: shape(display), color: glowColor, progress: ripple, plan: ripplePlan)
            )
            .padding(PanelController.glowPadding)
            .environment(\.colorScheme, model.palette.isDark ? .dark : .light)
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
            PreviewPill(item: item, now: model.now, needsLabel: model.needsLabel, metrics: model.metrics,
                        link: PreviewLink.primary(item)) { link in model.openAndResolve(item, link: link) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in model.dragHandler?(.changed) }
                        .onEnded { _ in model.dragHandler?(.ended) }
                )
                .onTapGesture {
                    // An urgent item from the other context opens that side.
                    if item.context != model.context { model.setContext(item.context) }
                    model.expand(byUser: true, focusing: item.id)
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
        case .waiting: return RoundedRectangle(cornerRadius: model.pillCornerRadius, style: .continuous)
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

    /// Settings → Panel → Opacity → Background darkness: a dark layer behind the glass
    /// (not the faint idle pill), so text reads over bright or busy windows.
    @ViewBuilder
    private func backdrop(_ display: PanelDisplay) -> some View {
        switch display {
        case .idle:
            EmptyView()
        default:
            Theme.backdrop.opacity(model.palette.backdropOpacity(model.settings.ui.backdrop))
        }
    }

    /// Settings → Appearance → Theme: the theme's wash over the glass (none by default).
    @ViewBuilder
    private func themeTint(_ display: PanelDisplay) -> some View {
        switch display {
        case .idle:
            EmptyView()
        default:
            if model.palette.tintOpacity > 0 { Theme.tint }
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
        // Settings → Alerts → Arrival animation. Glow and ripple are drawn here, in the
        // panel's padding; bounce, shake and slide move the whole panel content
        // (PanelController.playArrival). Ambient arrivals are one soft glow at most.
        let plan = model.arrivalPlan(request)
        guard !plan.isEmpty else { return }   // Alerts → Off (never for urgent: it has a floor)
        glowColor = Theme.color(request.priority)
        switch plan.animation {
        case .glow:
            glowLook = plan.look
            Task { @MainActor in await ArrivalRunner.run(plan) { glow = $0 } }
        case .ripple:
            ripplePlan = plan
            Task { @MainActor in await ArrivalRunner.run(plan) { ripple = $0 } }
        default:
            break
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
            .onTapGesture { model.pillOpensSettings ? model.openSettings() : model.toggleExpanded() }
    }
}

extension View {
    func pillInteraction(_ model: AppModel) -> some View { modifier(PillInteraction(model: model)) }
}

struct IdlePill: View {
    @ObservedObject var model: AppModel
    /// Observed too, so a change in Settings → Usage redraws the meters straight away (the
    /// panel resizes from the same settings).
    @ObservedObject var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        // At rest a small, faint "Nothing needs <you>" (still easy to drag, right-click or
        // hide); on hover the full status line. Usage meters (Settings → Usage → On the pill)
        // go below or after the line, and the pill rests a little stronger while they show
        // (PillMeterLayout.idleAlpha).
        let layout = model.idleMeterLayout
        PillWithMeters(bars: layout.count > 0 ? model.pillUsageBars : [], layout: layout,
                       cornerRadius: model.hovering ? 11 : 9, numberBase: model.metrics.idleFont - 1,
                       trailing: 8) {
            line(trailing: layout.showsTrailing ? 0 : 8)
        }
        .animation(.easeInOut(duration: 0.15), value: model.hovering)
        .pillInteraction(model)
        .help((model.focusSummary.map { "Focus: \($0) · \(model.statusLine)" } ?? model.statusLine)
              + model.pillUsageHelp)
    }

    private func line(trailing: CGFloat) -> some View {
        HStack(spacing: 6) {
            if model.isFocused {
                // Focus is on (right-click → Focus); the link badge when a link set it.
                Image(systemName: "moon.fill")
                    .font(.system(size: model.metrics.idleFont - 1))
                    .foregroundStyle(Theme.muted)
                if model.focusSetByLink {
                    Image(systemName: "link")
                        .font(.system(size: model.metrics.idleFont - 2, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                }
            } else {
                Circle()
                    .fill(model.lastError == nil && model.isConfigured ? Color.green.opacity(0.8) : Theme.faint)
                    .frame(width: 5, height: 5)
            }
            Text(model.hovering ? model.idleHoverLine : model.idleRestLine)
                .font(.system(size: model.metrics.idleFont))
                .foregroundStyle(Theme.text.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, trailing)
    }
}

/// Phase 3: the springy new-item preview (title and source, and an agent's question with
/// its first choices). With an allowed link, a
/// button opens it and marks the item done; clicking elsewhere opens the panel at the card.
/// The title (two lines at most) and the meta line take the full width; the button sits
/// on its own row below them (PreviewLayout, which also sizes the panel).
struct PreviewPill: View {
    let item: Item
    let now: Date
    let needsLabel: String
    let metrics: PanelMetrics
    var link: ItemLink?
    var onOpen: (ItemLink) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PreviewLayout.dotGap) {
            Circle().fill(Theme.color(item.priority))
                .frame(width: PreviewLayout.dotSize, height: PreviewLayout.dotSize)
                // Level with the middle of the title's first line.
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + metrics.titleFont * 0.33 }
            VStack(alignment: .leading, spacing: PreviewLayout.metaGap) {
                Text(item.title)
                    .font(Theme.title(metrics))
                    .foregroundStyle(Theme.text)
                    .lineLimit(PreviewLayout.maxTitleLines)
                    .fixedSize(horizontal: false, vertical: true)
                (Text(item.kind == .needs ? needsLabel : item.kind.rawValue).foregroundStyle(Theme.color(item.priority).opacity(0.9))
                 + Text(" · " + Format.meta(item, now: now)).foregroundStyle(Theme.muted))
                    .font(Theme.meta(metrics))
                    .lineLimit(1)
                if let question = item.question, let text = QuestionDisplay.previewQuestion(question) {
                    // What it asks and the first choices (QuestionDisplay.previewRows sizes these).
                    Text(text)
                        .font(Theme.meta(metrics))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, PreviewLayout.questionRowGap - PreviewLayout.metaGap)
                    if let choices = QuestionDisplay.previewChoices(question) {
                        Text(choices)
                            .font(Theme.meta(metrics).weight(.medium))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.top, PreviewLayout.questionRowGap - PreviewLayout.metaGap)
                    }
                }
                if let link {
                    linkButton(link)
                        .padding(.top, PreviewLayout.linkRowGap - PreviewLayout.metaGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PreviewLayout.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func linkButton(_ link: ItemLink) -> some View {
        Button { onOpen(link) } label: {
            HStack(spacing: 3) {
                Text(LinkRowPolicy.label(link, maxLength: 14)).lineLimit(1)
                if let destination = LinkRowPolicy.destination(link) {
                    // Where it really goes, as on the cards, so a label can't pass
                    // for another site.
                    Text(destination)
                        .fontWeight(.regular)
                        .foregroundStyle(Theme.linkDestination)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 90)
                }
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: metrics.linkFont, weight: .medium))
            .linkChip(horizontal: 8, vertical: PreviewLayout.linkChipVertical)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open \(link.url) and mark this done")
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
                    .foregroundStyle(Theme.text)
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
