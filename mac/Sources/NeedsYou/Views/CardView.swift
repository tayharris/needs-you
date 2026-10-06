import NeedsYouCore
import SwiftUI

struct CardView: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.color(item.priority))
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(Theme.title)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.key)

                Text(Format.meta(item, now: model.now))
                    .font(Theme.meta)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                if let body = item.body, !body.isEmpty {
                    Text(LimitedMarkdown.render(body))
                        .font(Theme.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .tint(Theme.normal)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !item.links.isEmpty {
                    LinkRow(links: item.links, model: model)
                        .padding(.top, 2)
                }

                CardActions(item: item, model: model)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Allowed links are buttons that open via NSWorkspace; anything else is plain text.
struct LinkRow: View {
    let links: [ItemLink]
    @ObservedObject var model: AppModel

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(links.prefix(6).enumerated()), id: \.offset) { _, link in
                if LinkPolicy.isAllowed(link.url) {
                    Button {
                        model.open(link.url)
                    } label: {
                        HStack(spacing: 3) {
                            Text(link.label.isEmpty ? link.url : link.label).lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(link.url)
                } else {
                    Text("\(link.label): \(link.url)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("Not opened: link scheme isn't on the allow-list")
                }
            }
        }
    }
}

struct CardActions: View {
    let item: Item
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ActionButton(title: "Done", symbol: "checkmark") { model.resolve(item) }
            ActionButton(title: "Dismiss", symbol: "xmark") { model.dismiss(item) }
            Menu {
                ForEach(SnoozeOption.cardChoices) { option in
                    Button(option.title) { model.snoozeCard(item, option) }
                }
            } label: {
                Label("Snooze", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.meta(item, now: model.now))
                    .font(Theme.meta)
                    .foregroundStyle(Theme.faint)
                if !item.links.isEmpty {
                    LinkRow(links: item.links, model: model)
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
