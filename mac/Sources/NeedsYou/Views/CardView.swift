import NeedsYouCore
import SwiftUI

struct CardView: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let m = model.metrics
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.color(item.priority))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                let badge = CardAge.badge(createdAt: item.createdAt, now: model.now)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(Theme.title(m))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(item.key)
                    if let badge {
                        Spacer(minLength: 0)
                        AgeBadge(text: badge, stale: CardAge.isStale(createdAt: item.createdAt, now: model.now), metrics: m)
                    }
                }

                Text(Format.meta(item, now: model.now, includeAge: badge == nil))
                    .font(Theme.meta(m))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                if let body = item.body, !body.isEmpty {
                    let mode = model.settings.ui.cardBodies
                    let expanded = model.expandedCards.contains(item.id)
                    if CardBodyPolicy.showsBody(mode, expanded: expanded) {
                        Text(LimitedMarkdown.render(body))
                            .font(Theme.body(model.bodyFont))
                            .foregroundStyle(.white.opacity(0.85))
                            .tint(Theme.normal)
                            .lineLimit(CardBodyPolicy.lineLimit(mode, expanded: expanded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if CardBodyPolicy.canExpand(body: body, mode: mode) {
                        Button(CardBodyPolicy.toggleTitle(mode, expanded: expanded)) { model.toggleCardExpanded(item) }
                            .buttonStyle(.plain)
                            .font(Theme.meta(m))
                            .foregroundStyle(Theme.muted)
                    }
                }

                if !item.links.isEmpty {
                    LinkRow(item: item, model: model)
                        .padding(.top, 2)
                }

                CardActions(item: item, model: model)
                    .padding(.top, 2)
            }
        }
        .padding(m.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardBottomsKey.self, value: [proxy.frame(in: .named(CardBottomsKey.space)).maxY])
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Allowed links are buttons that open via NSWorkspace; anything else is plain text.
struct LinkRow: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        let compact = model.settings.ui.compactLinks
        let plan = LinkRowPolicy.plan(item.links, compact: compact, expanded: model.expandedCards.contains(item.id))
        FlowLayout(spacing: compact ? 4 : 6, lineSpacing: compact ? 4 : 6) {
            ForEach(Array(plan.shown.enumerated()), id: \.offset) { _, link in
                if LinkPolicy.isAllowed(link.url) {
                    Button {
                        model.open(link.url, from: item)
                    } label: {
                        HStack(spacing: 3) {
                            Text(LinkRowPolicy.label(link, maxLength: plan.maxLabelLength)).lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: model.metrics.linkFont, weight: .medium))
                        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2 : 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                } else {
                    Text("\(link.label): \(link.url)")
                        .font(.system(size: model.metrics.linkFont))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Not opened: link scheme isn't on the allow-list")
                }
            }
            if plan.overflow > 0 {
                Button("+\(plan.overflow)") { model.toggleCardExpanded(item) }
                    .buttonStyle(.plain)
                    .font(.system(size: model.metrics.linkFont, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 2)
                    .help("Show all links")
            }
        }
    }
}

struct CardActions: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Done", symbol: "checkmark", size: model.metrics.actionFont) { model.resolve(item) }
            ActionButton(title: "Dismiss", symbol: "xmark", size: model.metrics.actionFont) { model.dismiss(item) }
            Menu {
                ForEach(SnoozeOption.cardChoices) { option in
                    Button(option.title) { model.snoozeCard(item, option) }
                }
            } label: {
                Label("Snooze", systemImage: "clock")
                    .font(.system(size: model.metrics.actionFont))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if let host = ItemStore.host(of: item) {
                let count = model.itemsFromSameHost(as: item).count
                Menu {
                    Button("Dismiss All from \(host) (\(count))") { model.dismissAll(fromHostOf: item) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: model.metrics.actionFont, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
    }
}

/// "5 h" / "2 d" next to an old card's title; amber once it's probably stale.
private struct AgeBadge: View {
    let text: String
    let stale: Bool
    let metrics: PanelMetrics

    var body: some View {
        Text(text)
            .font(.system(size: metrics.metaFont, weight: .medium).monospacedDigit())
            .foregroundStyle(stale ? Theme.normal.opacity(0.9) : Theme.muted)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(stale ? 0.10 : 0.06)))
            .fixedSize()
            .help(stale ? "Waiting a long time: it may be stale. Dismiss it, or all from this host (… menu)." : "Waiting since this long ago")
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var size: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: size))
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact row for done / info items in "Recent". Never counted.
struct RecentRow: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.kind == .done ? "checkmark.circle" : "info.circle")
                .font(.system(size: model.metrics.metaFont))
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.body(model.bodyFont))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.meta(item, now: model.now))
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(Theme.faint)
                if !item.links.isEmpty {
                    LinkRow(item: item, model: model)
                }
            }
            Spacer(minLength: 0)
            Button { model.dismiss(item) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.faint)
            .help("Dismiss")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// A simple wrapping row layout for link buttons.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, min(x - spacing, maxWidth))
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
