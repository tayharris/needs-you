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
            ScrollViewReader { reader in
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
                // Opened from a preview or with new arrivals: bring that card into view.
                .onAppear { scrollToTarget(reader) }
                .onChange(of: model.scrollTarget) { _, _ in scrollToTarget(reader) }
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            footer.frame(height: model.metrics.footerHeight - 0.5)
        }
        // Drag to set the list height; on the edge away from the anchored corner.
        .overlay(alignment: model.listGripAtBottom ? .bottom : .top) {
            ResizeGrip(model: model)
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let id = model.scrollTarget else { return }
        // After this layout pass, so the card exists and the panel has its height.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            model.scrollTarget = nil
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if model.showsDemoBadge {
                Text("DEMO")
                    .font(.system(size: model.metrics.sectionFont - 1, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent.opacity(0.25)))
                    .foregroundStyle(Theme.accent)
            }
            Text(model.statusLine)
                .font(Theme.meta(model.metrics))
                .foregroundStyle(model.lastError == nil ? Theme.faint : Theme.urgent.opacity(0.8))
                .lineLimit(1)
            Spacer()
            Text(model.settings.hotKey.display)
                .font(Theme.mono(model.metrics))
                .foregroundStyle(Theme.faint)
                .help("Global shortcut \(model.settings.hotKey.spokenAndSymbols): open or collapse the panel (Settings → Panel → Keyboard)")
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
                .foregroundStyle(Theme.text)
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
            HeaderButton(symbol: "chevron.up", help: "Collapse (Escape, \(model.settings.hotKey.spokenAndSymbols), or double-click this bar)", size: model.metrics.headerFont - 1) { model.collapse() }
            if model.canHidePanel {
                // Hide the whole panel; the menu bar icon (or the shortcut) brings it back.
                HeaderButton(symbol: "xmark", help: "Hide floating panel (the menu bar icon or \(model.settings.hotKey.spokenAndSymbols) shows it)", size: model.metrics.headerFont - 1) { model.hidePanel() }
            }
        }
        .padding(.horizontal, 10)
        .foregroundStyle(Theme.text.opacity(0.8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in model.dragHandler?(.changed) }
                .onEnded { _ in model.dragHandler?(.ended) }
        )
        // Double-click the header bar to collapse, without aiming for the chevron.
        .onTapGesture(count: 2) { model.collapse() }
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
                    .background(Capsule().fill(selected ? Theme.text.opacity(0.12) : .clear))
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
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
        // Setup tips (SetupChecklist) sit in the priority groups after the hub's cards;
        // they aren't in the store, so they're never counted or PATCHed.
        let setup = model.setupCards.map { $0.item }
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
                ForEach(setup) { item in CardView(item: item, model: model) }
            } else {
                PriorityGroups(needs: needs + setup, model: model)
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
            if !model.orcaRows.isEmpty {
                // Orca's worktrees (local `orca worktree ps`): plain text, never counted,
                // never a link or a button beyond the fold.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showOrca.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.showOrca ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(verbatim: OrcaWorktrees.header(model.orcaTotal))
                        Spacer()
                    }
                    .font(.system(size: model.metrics.sectionFont, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Orca's worktrees on this Mac and its paired environments (Settings → Panel → Orca)")
                .padding(.top, 4)
                if model.showOrca {
                    ForEach(model.orcaRows) { row in
                        OrcaWorktreeRowView(row: row, model: model)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Orca worktree: name, then status, terminals and host. Text(verbatim:), so a branch
/// name is never read as markdown or a link.
private struct OrcaWorktreeRowView: View {
    let row: OrcaWorktreeRow
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(row.liveTerminals > 0 ? Theme.accent : Theme.faint.opacity(0.5))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name)
                    .font(Theme.body(model.bodyFont))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: row.detail)
                    .font(Theme.meta(model.metrics))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .help(row.branch.isEmpty ? row.name : row.branch)
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
                .foregroundStyle(Theme.text.opacity(0.8))
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
