import NeedsYouCore
import SwiftUI

/// The 360 pt panel: header, cards grouped urgent → normal → low, then a collapsed
/// "Recent" section with done and info items.
struct ExpandedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader(model: model)
                .frame(height: model.metrics.headerHeight - 0.5) // + hairline = headerHeight, matches PanelController
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ScrollView(.vertical) {
                CardList(model: model)
                    .padding(model.metrics.listPadding)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .coordinateSpace(name: CardBottomsKey.space)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            .onPreferenceChange(ContentHeightKey.self) { height in
                if abs(model.expandedContentHeight - height) > 0.5 { model.expandedContentHeight = height }
            }
            .onPreferenceChange(CardBottomsKey.self) { bottoms in
                let rounded = bottoms.map { $0.rounded() }.sorted()
                if rounded != model.cardBottoms { model.cardBottoms = rounded }
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            footer.frame(height: model.metrics.footerHeight - 0.5)
        }
        // Drag to set the list height; on the edge away from the anchored corner.
        .overlay(alignment: model.listGripAtBottom ? .bottom : .top) {
            ResizeGrip(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isDemo {
                Text("DEMO")
                    .font(.system(size: model.metrics.sectionFont - 1, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.normal.opacity(0.25)))
                    .foregroundStyle(Theme.normal)
            }
            Text(model.statusLine)
                .font(Theme.meta(model.metrics))
                .foregroundStyle(model.lastError == nil ? Theme.faint : Theme.urgent.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Text(model.settings.hotKey.display)
                .font(Theme.mono(model.metrics))
                .foregroundStyle(Theme.faint)
                .help("Global shortcut: show / hide the panel (Settings → Panel → Keyboard)")
        }
        .padding(.horizontal, 12)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Every card's bottom edge in the list, for ListHeightPolicy.
struct CardBottomsKey: PreferenceKey {
    static let space = "cardList"
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value.append(contentsOf: nextValue()) }
}

struct ExpandedHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Text(model.needsLabel)
                .font(.system(size: model.metrics.headerFont, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            ContextSwitch(model: model)
                .fixedSize()
            Spacer(minLength: 4)
            Menu {
                ForEach(SnoozeOption.panelChoices) { option in
                    Button(option.title) { model.snoozePanel(option) }
                }
                Divider()
                Button("Hide Floating Panel") { model.hidePanel() }
                    .disabled(!model.canHidePanel)
                Button("Reset Position") { model.resetPosition() }
            } label: {
                Image(systemName: "moon.zzz")
                    .font(.system(size: model.metrics.headerFont - 1, weight: .medium))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Snooze the panel")

            HeaderButton(symbol: "arrow.clockwise", help: "Refresh now", size: model.metrics.headerFont - 1) { model.pollNow(full: true) }
            HeaderButton(symbol: "gearshape", help: "Settings", size: model.metrics.headerFont - 1) { model.openSettings() }
            HeaderButton(symbol: "chevron.up", help: "Collapse (Esc)", size: model.metrics.headerFont - 1) { model.collapse() }
            if model.canHidePanel {
                // Hide the whole panel; the menu bar icon (or the shortcut) brings it back.
                HeaderButton(symbol: "xmark", help: "Hide floating panel (menu bar icon or \(model.settings.hotKey.display) shows it)", size: model.metrics.headerFont - 1) { model.hidePanel() }
            }
        }
        .padding(.horizontal, 10)
        .foregroundStyle(.white.opacity(0.8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in model.dragHandler?(.changed) }
                .onEnded { _ in model.dragHandler?(.ended) }
        )
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Work / Personal toggle with counts. The other side stays visible, never fully hidden.
struct ContextSwitch: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ItemContext.allCases, id: \.self) { ctx in
                let selected = ctx == model.context
                let n = model.store.needsCount(in: ctx, now: model.now)
                Button {
                    model.setContext(ctx)
                } label: {
                    HStack(spacing: 4) {
                        Text(ctx.rawValue.capitalized)
                        if n > 0 {
                            Text("\(n)").monospacedDigit()
                                .foregroundStyle(selected ? Theme.color(model.store.highestPriority(in: ctx, now: model.now)) : Theme.faint)
                        }
                    }
                    .font(.system(size: model.metrics.headerFont - 1, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.12) : .clear))
                    .foregroundStyle(selected ? .white : Theme.muted)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CardList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let needs = model.needsItems
        let recent = model.recentItems
        let later = model.laterItems
        VStack(alignment: .leading, spacing: model.metrics.cardSpacing) {
            ForEach(model.quietedSenders, id: \.self) { sender in
                // NoisySenderGuard: a looping sender can't keep interrupting.
                Label("Quieted \(sender): over \(NoisySenderGuard.defaultThreshold) alerts this hour", systemImage: "speaker.slash")
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            if needs.isEmpty {
                EmptyState(model: model)
            }
            if let since = model.summarySince {
                // Phase 3 start-of-day summary: oldest first, split at "since yesterday".
                let ordered = needs.sorted { $0.createdAt < $1.createdAt }
                let older = ordered.filter { $0.createdAt <= since }
                let newer = ordered.filter { $0.createdAt > since }
                SectionLabel(text: "GOOD MORNING · \(needs.count) OPEN", color: Theme.muted, size: model.metrics.sectionFont)
                ForEach(older) { item in CardView(item: item, model: model) }
                if !newer.isEmpty {
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Text("SINCE YESTERDAY").font(.system(size: model.metrics.sectionFont, weight: .semibold)).foregroundStyle(Theme.faint).fixedSize()
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    .padding(.vertical, 2)
                    ForEach(newer) { item in CardView(item: item, model: model) }
                }
            } else {
                PriorityGroups(needs: needs, model: model)
            }
            if !later.isEmpty {
                // Held by a focus, a snooze or a rule; delivered when it ends.
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { model.showLater.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.showLater ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                            Text("LATER · \(later.count)")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.focusSummary.map { "Focus: \($0). These arrive when it ends." } ?? "These arrive when the snooze ends or at the start of the day.")
                    Button("Show now") { model.deliverLaterNow() }
                        .buttonStyle(.plain)
                        .help("Move them into the list and the count")
                }
                .font(.system(size: model.metrics.sectionFont, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .padding(.top, 4)
                if model.showLater {
                    ForEach(later) { item in CardView(item: item, model: model) }
                }
            }
            if !recent.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showRecent.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.showRecent ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("RECENT · \(recent.count)")
                        Spacer()
                    }
                    .font(.system(size: model.metrics.sectionFont, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                if model.showRecent {
                    ForEach(recent) { item in
                        RecentRow(item: item, model: model)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cards grouped urgent → normal → low.
private struct PriorityGroups: View {
    let needs: [Item]
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(ItemPriority.allCases, id: \.self) { priority in
            let group = needs.filter { $0.priority == priority }
            if !group.isEmpty {
                SectionLabel(text: priority.rawValue.uppercased(), color: Theme.color(priority), size: model.metrics.sectionFont)
                ForEach(group) { item in
                    CardView(item: item, model: model)
                }
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color.opacity(0.85))
            .padding(.leading, 2)
    }
}

private struct EmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(.green.opacity(0.7))
            Text("All clear in \(model.context.rawValue)")
                .font(Theme.body(model.bodyFont))
                .foregroundStyle(.white.opacity(0.8))
            if model.otherCount > 0 {
                Button("\(model.otherCount) waiting in \(model.context.other.rawValue)") {
                    model.setContext(model.context.other)
                }
                .buttonStyle(.plain)
                .font(Theme.meta(model.metrics))
                .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
