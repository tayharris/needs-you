import AppKit
import NeedsYouCore
import SwiftUI

// settings-section: yourTools
/// Settings → Integrations → Your tools: the pollers already sending cards (ToolSightings,
/// learned from their cards), with what each watches and where it runs, a Work / Personal
/// picker per team, project or owner, and Add another. The pollers run on a sender machine
/// and the app never writes there: a changed picker shows the `needs-you context` line to
/// run on that machine.
struct YourToolsSection: View {
    @ObservedObject var model: AppModel
    /// The snapshot tour opens the first row, to show the pickers.
    var openFirst = false

    private var tools: [ToolSighting] { model.shownToolSightings.all }

    var body: some View {
        // Two Sections rather than an if inside one, and the note as a row, not a footer:
        // with a footer, the grouped Form laid the last tool's row out beside it.
        if tools.isEmpty {
            Section {
                Text("No tool has sent a card yet. Once Linear, Jira, GitHub or expiry cards arrive, each shows here with what it watches, where it runs, and work or personal for each team, project or owner. Set one up under Cards from your tools, below.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Your tools")
            }
        } else {
            Section {
                ForEach(tools) { tool in
                    ConfiguredToolRow(tool: tool, open: openFirst && tool.id == tools.first?.id)
                }
                Text("Learned from the cards each tool posted in the last 30 days: Needs You never reads their settings or tokens. They run on a sender machine, so changing work or personal gives you a command to run there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Your tools")
            }
        }
    }
}

private struct ConfiguredToolRow: View {
    let tool: ToolSighting
    @State private var open: Bool
    /// Picks that differ from what the cards say, by team, project or owner (`*`: the
    /// whole poller). A pick the cards later confirm stops showing a command.
    @State private var picks: [String: ItemContext] = [:]

    init(tool: ToolSighting, open: Bool) {
        self.tool = tool
        _open = State(initialValue: open)
    }

    private var host: String? { tool.hostNames.first }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                contexts
                if !commandLines.isEmpty { commandBox }
                if tool.id == "github" {
                    Text("It watches every repo whose notifications you get. One repo on its own: `needs-you context github owner/repo personal` there. Projects statuses and Dependabot alerts are opt-in, under Cards from your tools.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline) {
                    if let title = ConfiguredTools.addAnotherTitle(tool.id),
                       let prompt = ConfiguredTools.addAnotherPrompt(tool.id, host: host) {
                        SettingsCopyButton(title: title, text: prompt)
                            .help("Copies a prompt for an agent on \(host ?? "that machine")")
                        Text("Copies a prompt for an agent on \(host ?? "that machine").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = URL(string: ConfiguredTools.guideURL(tool.id)) {
                        Link("Guide", destination: url)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ConfiguredTools.symbol(tool.id))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ConfiguredTools.name(tool.id))
                        SendingBadge()
                    }
                    Text(ConfiguredTools.detail(tool) + " · last card " + Self.relative(tool.lastSeen))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private var contexts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Work or personal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch tool.id {
            case "github":
                ForEach(tool.owners, id: \.owner) { owner in
                    contextRow(owner.owner, detail: owner.repos.map(\.name).prefix(4).joined(separator: ", "),
                               seen: owner.repos.first?.context ?? .work)
                }
            case "linear", "jira":
                ForEach(tool.scopeList, id: \.name) { scope in
                    contextRow(scope.name, detail: nil, seen: scope.context)
                }
                if tool.scopes.isEmpty {
                    Text("No team or project seen on its cards yet.").font(.caption).foregroundStyle(.secondary)
                }
            default:
                contextRow("*", detail: nil, seen: tool.context, title: "All its cards")
            }
        }
    }

    private func contextRow(_ name: String, detail: String?, seen: ItemContext, title: String? = nil) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? name).font(title == nil ? .callout.monospaced() : .callout)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { picks[name] ?? seen },
                set: { picks[name] = $0 == seen ? nil : $0 }
            )) {
                Text("Work").tag(ItemContext.work)
                Text("Personal").tag(ItemContext.personal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // A name the CLI wouldn't take gets no command, so no picker either.
            .disabled(ToolContextCommand.line(tool: tool.id, name: name == "*" ? nil : name, context: seen) == nil)
        }
    }

    /// One `needs-you context` line per changed pick, for picks the cards don't show yet.
    private var commandLines: String {
        picks.sorted { $0.key < $1.key }.compactMap { name, ctx -> String? in
            let seen = seenContext(name)
            guard ctx != seen else { return nil }
            return ToolContextCommand.line(tool: tool.id, name: name == "*" ? nil : name, context: ctx)
        }.joined(separator: "\n")
    }

    private func seenContext(_ name: String) -> ItemContext {
        switch tool.id {
        case "github": return tool.owners.first { $0.owner == name }?.repos.first?.context ?? .work
        case "linear", "jira": return tool.scopes[name]?.context ?? .work
        default: return tool.context
        }
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(commandLines)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                SettingsCopyButton(title: "Copy", text: commandLines).controlSize(.small)
            }
            Text(ToolContextCommand.instructions(host: host))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }
}

/// "Sending cards", on a poller the app has seen at work.
private struct SendingBadge: View {
    var body: some View {
        Label("Sending cards", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.green)
    }
}

// settings-section: toolCards
/// Settings → Integrations → Cards from your tools: one row per poller in
/// IntegrationCatalog, each with one level of detail under it (what it needs, its settings,
/// the commands with Copy, and the agent prompt). Nothing here runs a command or holds a
/// token: the pollers run on a sender machine, set up by the person or their agent. A row
/// whose cards have arrived says so (Your tools, above, has the details).
struct IntegrationsSettingsSection: View {
    @ObservedObject var model: AppModel
    /// Rows open at first (the snapshot tour opens one to show what's inside).
    var initiallyOpen: Set<String> = []

    var body: some View {
        Section {
            ForEach(IntegrationCatalog.all) { integration in
                IntegrationRow(integration: integration, open: initiallyOpen.contains(integration.id),
                               sending: ConfiguredTools.isSending(integration, in: model.shownToolSightings))
            }
        } header: {
            Text("Cards from your tools")
        } footer: {
            Text("Each runs on one always-on machine that already sends alerts (Connect a machine sets one up), every few minutes, and only reads. Copy the agent prompt into Claude Code or another agent there: it never holds a token, and asks you to put yours in place yourself.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct IntegrationRow: View {
    let integration: Integration
    let sending: Bool
    @State private var open: Bool

    init(integration: Integration, open: Bool, sending: Bool) {
        self.integration = integration
        self.sending = sending
        _open = State(initialValue: open)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                Text("**Needs:** \(integration.needs)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                settings
                commands
                HStack {
                    SettingsCopyButton(title: "Copy agent prompt", text: integration.agentPrompt)
                    Spacer()
                    if let url = URL(string: integration.guideURL) {
                        Link("Guide", destination: url)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: integration.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(integration.name)
                        if sending { SendingBadge() }
                    }
                    Text(integration.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings, in ~/.config/needs-you/env").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(integration.settings, id: \.name) { setting in
                VStack(alignment: .leading, spacing: 1) {
                    Text(setting.example ?? setting.name).font(.caption.monospaced()).textSelection(.enabled)
                    Text(setting.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commands, on that machine").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(integration.commands, id: \.title) { command in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(command.title).font(.caption)
                        Text(command.command)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    SettingsCopyButton(title: "Copy", text: command.command)
                        .controlSize(.small)
                }
            }
        }
    }
}
