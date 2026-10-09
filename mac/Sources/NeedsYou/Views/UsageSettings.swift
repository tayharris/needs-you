import AppKit
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
                LabelWithDetail("Show on the pill", "The fullest session and weekly window on the collapsed pill, also when nothing is waiting. The count stays readable.")
            }
            Picker(selection: $settings.usage.pillStyle) {
                ForEach(PillMeterStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("On the pill", "Bars under the count (the pill grows a little taller for two), thin bars along its bottom edge (the pill keeps its size), or the percentages after the count.")
            }
            .disabled(!settings.usage.onPill)
        } header: {
            Text("Meters")
        } footer: {
            Text("The numbers come through your hub from the agents' own hooks (Claude Code's status line helper, the Codex hook) or from Orca's accounts (`needs-you orca usage`). Nothing reads a login, token or cookie, and no email is ever sent. Meters never count as waiting, animate or notify.")
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
        let noNumbers = UsageMeters.providers(model.statuses, now: now).isEmpty
        let statuses = noNumbers ? DemoFeed.statusFixture(now: now) : model.statuses
        let rows = UsageMeters.rows(statuses, prefs: settings.usage, now: now)
        VStack(alignment: .leading, spacing: 8) {
            if noNumbers {
                // The examples below look like real meters: say plainly that the pill and panel
                // stay empty until a machine sends numbers, and how to start that.
                Text("Example meters: no usage numbers have reached your hub yet, so the pill and panel show none.")
                    .font(.callout.weight(.semibold))
                Text("On a machine with Orca, run `needs-you orca usage --enable`. Without Orca, install with `--usage`, which wraps Claude Code's status line. The Codex hook reports Codex on its own.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            preview(rows)
            if settings.usage.onPill {
                pillPreview(UsageMeters.pillBars(rows))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .environment(\.colorScheme, Theme.colorScheme)
    }

    /// The collapsed pill with three waiting and with nothing waiting, in the chosen style.
    @ViewBuilder private func pillPreview(_ bars: [UsageBar]) -> some View {
        let m = settings.ui.pillMetrics
        let panel = settings.ui.metrics
        let style = settings.usage.pillStyle
        let now = Date()
        let items = (1...3).map { i in
            Item(id: "usage-preview-\(i)", key: "usage-preview-\(i)", title: "Example \(i)", createdAt: now)
        }
        let content = PillContent.make(PillInput(context: .work, items: items, needsLabel: settings.needsLabel),
                                       options: PillOptions(size: settings.ui.pillSize), hovering: false)
        let waiting = PillMeterLayout.make(style, count: bars.count, height: m.height, font: m.font)
        let idle = PillMeterLayout.make(style, count: bars.count, height: panel.idleHeight, font: panel.idleFont)
        let idleText = "Nothing \(settings.needsLabel)"
        let idleTextWidth = (idleText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: panel.idleFont)]).width
        HStack(alignment: .center, spacing: 14) {
            Text("On the pill").font(.caption).foregroundStyle(Theme.muted)
            sample(width: PillLayout.size(content, metrics: m).width + PillMeterMetrics.percentWidth(waiting, size: m.smallFont),
                   height: waiting.height, radius: m.cornerRadius) {
                PillWithMeters(bars: bars, layout: waiting, cornerRadius: m.cornerRadius, percentSize: m.smallFont) {
                    PillContentView(content: content, metrics: m)
                }
            }
            sample(width: panel.idleWidth(textWidth: idleTextWidth + PillMeterMetrics.percentWidth(idle, size: panel.idleFont - 1)),
                   height: idle.height, radius: 9) {
                PillWithMeters(bars: bars, layout: idle, cornerRadius: 9, percentSize: panel.idleFont - 1,
                               percentTrailing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                        Text(verbatim: idleText).font(.system(size: panel.idleFont)).foregroundStyle(Theme.text.opacity(0.85))
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, idle.showsPercent ? 0 : 8)
                }
            }
            // As faint as the idle pill rests on the desktop.
            .opacity(PillMeterLayout.idleAlpha(0.35, showsMeters: idle.count > 0))
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sample<V: View>(width: CGFloat, height: CGFloat, radius: CGFloat,
                                 @ViewBuilder _ content: () -> V) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content()
            .frame(width: width, height: height)
            .background(Theme.raised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
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
