import NeedsYouCore
import SwiftUI

// Settings → Alerts: delivery tiers and bypass rules (docs/roadmap/focus-tiers.md). Lives in
// the Settings window only (which may take focus), never in the floating panel.

/// The tier per priority and kind with no focus, the "urgent breaks through Focus" switch,
/// and a read-only table of what each focus level does.
struct DeliverySection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            TierPreviewTable(defaults: settings.delivery, urgentBreaksSnooze: settings.urgentBreaksSnooze)
            Picker(selection: $settings.delivery.normal) {
                ForEach(DeliveryDefaults.needsChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Normal items", "With no focus. Urgent items always interrupt.")
            }
            Picker(selection: $settings.delivery.low) {
                ForEach(DeliveryDefaults.needsChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Low items", "Later collects them for the start of the day.")
            }
            Picker(selection: $settings.delivery.recent) {
                ForEach(DeliveryDefaults.quietChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Done and info", "Recent rows; never counted.")
            }
            Picker(selection: $settings.delivery.otherContext) {
                ForEach(DeliveryDefaults.quietChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("The other context", "Non-urgent work items in the evening, personal ones by day: the faint second number.")
            }
            Toggle(isOn: $settings.delivery.urgentBreaksFocus) {
                LabelWithDetail("Urgent items break through Focus",
                                "Under Agents and urgent only, and Urgent only. Off (for a presentation): they arrive ambient. Everything later holds urgent too.")
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Interrupt: the preview springs out with a glow. Ambient: the count changes with one soft glow. Later: held out of the count and delivered as one peek when the focus or snooze ends, or at the start of the day. Turn Focus on from the pill's right-click menu, the menu bar, or needsyou://focus.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What each kind of item does under each focus level and a snooze, from DeliveryPolicy.
struct TierPreviewTable: View {
    let defaults: DeliveryDefaults
    let urgentBreaksSnooze: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("")
                ForEach(DeliveryPolicy.PreviewColumn.all, id: \.self) { column in
                    Text(column.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(DeliveryPolicy.PreviewRow.allCases, id: \.self) { row in
                GridRow {
                    Text(row.title).font(.caption)
                    ForEach(DeliveryPolicy.PreviewColumn.all, id: \.self) { column in
                        let tier = DeliveryPolicy.preview(row, column, defaults: defaults, urgentBreaksSnooze: urgentBreaksSnooze)
                        Text(tier.title).font(.caption).foregroundStyle(Self.color(tier))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What each item does under each focus level")
    }

    static func color(_ tier: DeliveryTier) -> Color {
        switch tier {
        case .interrupt: return Color.primary
        case .ambient: return Color.secondary
        case .later: return Color.secondary.opacity(0.6)
        }
    }
}

/// The bypass list: per key prefix, sender agent or host; checked top to bottom.
struct BypassRulesSection: View {
    @ObservedObject var settings: AppSettings
    @State private var drafts: [Draft] = []
    @State private var loaded = false

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var match: BypassMatch
        var value: String
        var action: BypassAction
    }

    var body: some View {
        Section {
            ForEach($drafts) { $draft in
                HStack(spacing: 6) {
                    Picker("Match", selection: $draft.match) {
                        ForEach(BypassMatch.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField(Self.placeholder(draft.match), text: $draft.value)
                        .textFieldStyle(.roundedBorder)
                    Picker("Action", selection: $draft.action) {
                        ForEach(BypassAction.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        let id = draft.id
                        drafts.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                }
            }
            HStack {
                Button("Add Rule") {
                    drafts.append(Draft(match: .keyPrefix, value: "", action: .alwaysInterrupt))
                }
                .disabled(drafts.count >= RuleBook.maxRules)
                if !drafts.contains(where: { $0.match == .keyPrefix && $0.value == FocusLevel.agentKeyPrefix }) {
                    Button("Agents Always Interrupt") {
                        drafts.append(Draft(match: .keyPrefix, value: FocusLevel.agentKeyPrefix, action: .alwaysInterrupt))
                    }
                    .disabled(drafts.count >= RuleBook.maxRules)
                    .help("Every Claude Code session's card (keys starting agent:) interrupts, whatever the focus")
                }
                Spacer()
                Text("\(drafts.count) of \(RuleBook.maxRules)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Bypass rules")
        } footer: {
            Text("Checked top to bottom; the first match wins. Always interrupt gets through any focus or snooze (a hidden panel stays hidden). Never interrupt: ambient at most. Always later: held under Later. A sender that would interrupt more than \(NoisySenderGuard.defaultThreshold) times in an hour is held to ambient for the rest of it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            drafts = settings.bypassRules.rules.map { Draft(match: $0.match, value: $0.value, action: $0.action) }
        }
        .onChange(of: drafts) { _, edited in
            // Rows with an empty value are kept on screen but not saved.
            settings.bypassRules = RuleBook(edited.compactMap { BypassRule(match: $0.match, value: $0.value, action: $0.action) })
        }
    }

    static func placeholder(_ match: BypassMatch) -> String {
        switch match {
        case .keyPrefix: return "agent: or work:gh:deploy:"
        case .agentPrefix: return "orca: or claude-code"
        case .host: return "devbox"
        }
    }
}
