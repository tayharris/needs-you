import NeedsYouCore
import SwiftUI

// Settings → Alerts: delivery tiers and bypass rules (docs/roadmap/focus-tiers.md). Lives in
// the Settings window only (which may take focus), never in the floating panel.

// settings-section: delivery
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
                LabelWithDetail("Normal items", "With no Focus on. Urgent items always interrupt.")
            }
            Picker(selection: $settings.delivery.low) {
                ForEach(DeliveryDefaults.needsChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Low items", "With no Focus on. Ambient (the default) changes the count; nothing springs out.")
            }
            Picker(selection: $settings.delivery.recent) {
                ForEach(DeliveryDefaults.quietChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Done and info items", "Cards that say something finished, or are just for your information. They show under Recent and are never counted.")
            }
            Picker(selection: $settings.delivery.otherContext) {
                ForEach(DeliveryDefaults.quietChoices, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Items for the other side", "Work items in the evening and personal ones by day, except urgent: the faint second number on the pill.")
            }
            Toggle(isOn: $settings.delivery.urgentBreaksFocus) {
                LabelWithDetail("Urgent items break through Focus",
                                "On: urgent items still interrupt under Agents and urgent only, and Urgent only. Off, for a presentation: they arrive ambient. Everything later holds them either way, and a Focus turned on by a link always lets them through.")
            }
            Toggle(isOn: $settings.allowFocusLinks) {
                LabelWithDetail("Allow focus links from other apps (Shortcuts, scripts)",
                                "needsyou://focus links turn Focus on without asking. Off: the app asks first, since any web page can open one. A link focus lasts at most 12 h (or until tomorrow), never holds back urgent items, and shows a link badge on the pill.")
            }
        } header: {
            Text("Delivery")
        } footer: {
            Text("Interrupt: the preview springs out with a glow. Ambient: the count changes with one soft glow. Later: held out of the count and shown as one peek when the Focus or snooze ends, or at the start of the day. Focus is this app's own (not macOS's): turn it on from the pill's right-click menu, the menu bar, or a needsyou://focus link.")
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

// settings-section: workScreen
/// Where an arrival shows: the display you're working on. (The urgent edge glow is look:
/// Appearance → Alert style, EdgeGlowSection.)
struct WorkScreenSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: $settings.previewDisplay) {
                ForEach(PreviewDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("New items spring out on", settings.previewDisplay == .pill
                                ? "Always where the pill is, whichever display you're using."
                                : "The display with the app you're using (else the pointer's). The pill goes back home after.")
            }
        } header: {
            Text("On the work screen")
        } footer: {
            Text("Uses only window positions, no Screen Recording or Accessibility permission, and never takes focus from what you're typing. The red edge glow for urgent arrivals is in Appearance → Alert style.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// settings-section: bypassRules
/// The bypass list: per key prefix, session, sender agent or host, optionally only for one
/// `source.event`; checked top to bottom. Agent cards' "…" menu adds rules here too.
struct BypassRulesSection: View {
    @ObservedObject var settings: AppSettings
    @State private var drafts: [Draft] = []
    @State private var loaded = false

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var match: BypassMatch
        var value: String
        var action: BypassAction
        /// "" = any event.
        var event: String = ""

        init(match: BypassMatch, value: String, action: BypassAction, event: String? = nil) {
            self.match = match
            self.value = value
            self.action = action
            self.event = event ?? ""
        }

        init(_ rule: BypassRule) {
            self.init(match: rule.match, value: rule.value, action: rule.action, event: rule.event)
        }

        var rule: BypassRule? { BypassRule(match: match, value: value, action: action, event: event) }
    }

    /// One-click rules, put at the top of the list (the first match wins).
    struct Preset {
        let title: String
        let help: String
        let rule: BypassRule
    }

    static let presets: [Preset] = [
        Preset(title: "Agent questions are urgent",
               help: "An agent's question card (source.event question, keys starting agent:) is treated as urgent",
               rule: BypassRule(match: .keyPrefix, value: FocusLevel.agentKeyPrefix, action: .urgent,
                                event: AgentEvent.question.rawValue)!),
        Preset(title: "Agent failures are urgent",
               help: "An agent that stopped on an error, a rate limit or a sign-in (source.event failed) is treated as urgent",
               rule: BypassRule(match: .keyPrefix, value: FocusLevel.agentKeyPrefix, action: .urgent,
                                event: AgentEvent.failed.rawValue)!),
        Preset(title: "Agents always interrupt",
               help: "Every agent session's card (keys starting agent:) interrupts, whatever the focus",
               rule: BypassRule(match: .keyPrefix, value: FocusLevel.agentKeyPrefix, action: .alwaysInterrupt)!),
    ]

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
                        .accessibilityLabel(draft.match.title)
                    Picker("Event", selection: $draft.event) {
                        Text(AgentEvent.title(of: nil)).tag("")
                        ForEach(AgentEvent.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                        if !draft.event.isEmpty && AgentEvent(rawValue: draft.event) == nil {
                            Text(AgentEvent.title(of: draft.event)).tag(draft.event)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Only cards whose sender says this happened (source.event); the agent hooks set it")
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
                    .accessibilityLabel("Remove this rule")
                }
            }
            HStack {
                Button("Add rule") {
                    drafts.append(Draft(match: .keyPrefix, value: "", action: .alwaysInterrupt))
                }
                .disabled(drafts.count >= RuleBook.maxRules)
                ForEach(Self.presets, id: \.title) { preset in
                    if !drafts.contains(where: { $0.rule == preset.rule }) {
                        Button(preset.title) { drafts.insert(Draft(preset.rule), at: 0) }
                            .disabled(drafts.count >= RuleBook.maxRules)
                            .help(preset.help)
                    }
                }
                Spacer()
                Text("\(drafts.count) of \(RuleBook.maxRules)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Bypass rules")
        } footer: {
            Text("Checked top to bottom; the first match wins. Treat as urgent: the card is red, sorts first and arrives as urgent does; treat as low: the opposite. Always interrupt gets through any focus or snooze (a hidden panel stays hidden). Never interrupt: ambient at most. Always later: held under Later. An event narrows a rule to what the agent did: asked, needs approval, finished, failed, or context nearly full. An agent card's … menu sets rules for its session or its agent. A sender that would interrupt more than \(NoisySenderGuard.defaultThreshold) times in an hour is held to ambient for the rest of it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            drafts = settings.bypassRules.rules.map(Draft.init)
        }
        .onChange(of: settings.bypassRules) { _, saved in
            // A card's menu changed the rules while Settings is open: show them. (Rows with
            // an empty value, never saved, are dropped then.)
            if RuleBook(drafts.compactMap(\.rule)) != saved { drafts = saved.rules.map(Draft.init) }
        }
        .onChange(of: drafts) { _, edited in
            // Rows with an empty value are kept on screen but not saved.
            settings.bypassRules = RuleBook(edited.compactMap(\.rule))
        }
    }

    static func placeholder(_ match: BypassMatch) -> String {
        switch match {
        case .keyPrefix: return "agent: or work:gh:deploy:"
        case .session: return "agent:devbox:<session id>"
        case .agentPrefix: return "orca: or claude-code"
        case .host: return "devbox"
        }
    }
}
