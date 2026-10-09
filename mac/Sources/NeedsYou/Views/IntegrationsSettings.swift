import AppKit
import NeedsYouCore
import SwiftUI

/// Settings → Integrations → Cards from your tools: one row per poller in
/// IntegrationCatalog, each with one level of detail under it (what it needs, its settings,
/// the commands with Copy, and the agent prompt). Nothing here runs a command or holds a
/// token: the pollers run on a sender machine, set up by the person or their agent.
struct IntegrationsSettingsSection: View {
    /// Rows open at first (the snapshot tour opens one to show what's inside).
    var initiallyOpen: Set<String> = []

    var body: some View {
        Section {
            ForEach(IntegrationCatalog.all) { integration in
                IntegrationRow(integration: integration, open: initiallyOpen.contains(integration.id))
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
    @State private var open: Bool

    init(integration: Integration, open: Bool) {
        self.integration = integration
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
                LabelWithDetail(integration.name, integration.summary)
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
