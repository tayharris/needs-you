import NeedsYouCore
import SwiftUI

// Settings → Usage: where the usage meters show, for which providers and windows, and when
// they take a colour (UsagePrefs; UsageMeters in NeedsYouCore). Settings window only.

struct UsageSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    /// Providers with a producer today, plus any other one reporting now.
    private var knownProviders: [String] {
        Array(Set(["claude", "codex"] + UsageMeters.providers(model.statuses, now: model.now)
                  + settings.usage.providers)).sorted()
    }

    private func providerBinding(_ provider: String) -> Binding<Bool> {
        Binding(get: { settings.usage.shows(provider: provider) }, set: { on in
            var chosen = Set(settings.usage.providers.isEmpty ? knownProviders : settings.usage.providers)
            if on { chosen.insert(provider) } else { chosen.remove(provider) }
            // Every known one again: back to "all", so a new provider shows by itself.
            settings.usage.providers = chosen.isSuperset(of: knownProviders) ? [] : chosen.sorted()
        })
    }

    var body: some View {
        Section {
            UsagePreview(model: model, settings: settings)
            Toggle(isOn: $settings.usage.inPanel) {
                LabelWithDetail("Show in the panel", "A USAGE section at the top of the open panel: a bar per window, with the percentage used and when it resets.")
            }
            Toggle(isOn: $settings.usage.onPill) {
                LabelWithDetail("Show on the pill", "Two hairlines along the collapsed pill's bottom edge: the fullest session and weekly window. The count stays as it is.")
            }
        } header: {
            Text("Meters")
        } footer: {
            Text("The numbers come from the agents' own hooks (Claude Code's status line helper, the Codex hook) through your hub. Nothing reads a login, token or cookie, and no email is ever sent. Meters never count as waiting, animate or notify.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(knownProviders, id: \.self) { provider in
                Toggle(UsageMeters.providerTitle(provider), isOn: providerBinding(provider))
            }
            Picker(selection: $settings.usage.windows) {
                ForEach(UsageWindowChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Windows", "The 5-hour session limit, the weekly one, or both.")
            }
            Picker(selection: $settings.usage.hideUnderPct) {
                ForEach(UsagePrefs.hideUnderChoices, id: \.self) { pct in
                    Text(pct == 0 ? "Always show" : "Under \(pct)%").tag(pct)
                }
            } label: {
                LabelWithDetail("Hide a bar", "Keep the meters out of the way until a window fills up.")
            }
            Picker(selection: $settings.usage.warnPct) {
                ForEach(UsagePrefs.warnChoices, id: \.self) { Text("\($0)%").tag($0) }
            } label: {
                LabelWithDetail("Warning colour from", "Bars are plain until here, then amber; red at 100%.")
            }
        } header: {
            Text("What shows")
        }
    }
}

/// The meters as they look with these settings: the hub's numbers, or examples before any
/// arrive.
private struct UsagePreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let now = model.now
        let statuses = UsageMeters.providers(model.statuses, now: now).isEmpty
            ? DemoFeed.statusFixture(now: now) : model.statuses
        let rows = UsageMeters.rows(statuses, prefs: settings.usage, now: now)
        Group {
            if rows.isEmpty {
                Text("Nothing to show with these settings.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            } else {
                UsageSection(rows: rows, metrics: settings.ui.metrics, bodyFont: settings.ui.bodyFont)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .environment(\.colorScheme, Theme.colorScheme)
    }
}
