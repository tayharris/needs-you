import AppKit
import NeedsYouCore
import SwiftUI

// The usage meters' settings (UsagePrefs; UsageMeters in NeedsYouCore), in three places by
// the Settings layout rule (SettingsLayout.swift): how they look under Appearance → Usage
// meters, what shows on Panel, and how to start sending numbers on Integrations. Settings
// window only.

// settings-section: usageMeterLook
/// Settings → Appearance → Usage meters: the panel's meters as they look now, the warning
/// colour, and the pill's meter style.
struct UsageSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            UsagePreview(model: model, settings: settings)
            Picker(selection: $settings.usage.warnPct) {
                ForEach(UsagePrefs.warnChoices, id: \.self) { Text("\($0)%").tag($0) }
            } label: {
                LabelWithDetail("Warning colour from", "Bars are plain until here, then amber; red at 100%.")
            }
        } header: {
            Text("Meters")
        } footer: {
            Text("Which meters show, in the panel and on the pill, is in Panel → Usage meters.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            // Style, size, layout and percentages, with a preview of the pill.
            UsageMeterAppearanceSection(settings: settings)
        } header: {
            Text("On the pill")
        } footer: {
            Text(settings.usage.onPill
                 ? "Meters never count as waiting, animate or notify."
                 : "Show on the pill is off (Panel → Usage meters), so the pill shows no meters.")
                .font(.caption).foregroundStyle(.secondary)
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
        let noNumbers = UsageMeters.providers(model.statuses, now: now).isEmpty
        let statuses = noNumbers ? DemoFeed.statusFixture(now: now) : model.statuses
        let rows = UsageMeters.rows(statuses, prefs: settings.usage, now: now)
        VStack(alignment: .leading, spacing: 8) {
            if noNumbers {
                // The examples below look like real meters: say plainly that the pill and panel
                // stay empty until a machine sends numbers.
                Text("Example meters: no usage numbers have reached your hub yet, so the pill and panel show none. Integrations → Usage meters says how to send them.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview(rows)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .environment(\.colorScheme, Theme.colorScheme)
    }

    @ViewBuilder private func preview(_ rows: [UsageRow]) -> some View {
        Group {
            if rows.isEmpty {
                Text("Nothing to show with these settings.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            } else {
                UsageSection(rows: rows, metrics: settings.ui.metrics, bodyFont: settings.ui.bodyFont)
            }
        }
    }
}

// settings-section: usageMeterContent
/// Settings → Panel → Usage meters: where the meters show, for which providers and windows,
/// and when a bar hides. How they look is Appearance → Usage meters.
struct UsageContentSection: View {
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
            Toggle(isOn: $settings.usage.inPanel) {
                LabelWithDetail("Show in the panel", "A USAGE section at the top of the open panel: a bar per window, with the percentage used and when it resets.")
            }
            Toggle(isOn: $settings.usage.onPill) {
                LabelWithDetail("Show on the pill", "The fullest session and weekly window on the collapsed pill, also when nothing is waiting. The count stays readable.")
            }
            Group {
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
            }
            .disabled(!settings.usage.isShown)
        } header: {
            Text("Usage meters")
        } footer: {
            Text(settings.usage.isShown
                 ? "Meters for your agents' session and weekly limits, as their hooks report them. They never count as waiting, animate or notify. How they look: Appearance → Usage meters."
                 : "Both are off, so no meters show and the app doesn't ask the hub for them. Turn one on to choose which.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// settings-section: usageSetup
/// Settings → Integrations → Usage meters: how a machine starts sending the numbers.
struct UsageSetupSection: View {
    var body: some View {
        Section {
            Text("On a machine with Orca, run `needs-you orca usage --enable`. Without Orca, set the machine up with the `--usage` option, which adds a helper for Claude Code's status line. Codex needs nothing more: its hook reports the numbers.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } header: {
            Text("Usage meters")
        } footer: {
            Text("The numbers come through your hub from the agents' own hooks (Claude Code's status line helper, the Codex hook) or from Orca's accounts (`needs-you orca usage`). Nothing reads a login, token or cookie, and no email is ever sent. Panel → Usage meters picks what shows.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
