import NeedsYouCore
import SwiftUI

/// Settings → Panel → Setup tips: the local cards about what isn't set up yet
/// (SetupChecklist), and bringing back dismissed ones.
struct SetupTipsSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.showSetupTips) {
                LabelWithDetail("Show setup tips", "Cards in the panel when something isn't set up yet: no hub, nothing connected, other machines can't reach this Mac, no Claude Code hooks.")
            }
            HStack {
                LabelWithDetail("Dismissed tips", settings.setupTipsDismissed.isEmpty
                                ? "None."
                                : "\(settings.setupTipsDismissed.count) dismissed. They come back only if they still apply.")
                Spacer()
                Button("Show Again") { settings.setupTipsDismissed = [] }
                    .disabled(settings.setupTipsDismissed.isEmpty)
            }
        } header: {
            Text("Setup tips")
        } footer: {
            Text("Setup tips stay on this Mac: they're never sent to a hub, never counted in the pill or the menu bar, and never pulse. Each one goes for good once it's done.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension SettingsTab {
    /// Where a setup card's Open Settings goes: the one place that maps Core's pages to tabs.
    init(setupPage: SetupSettingsPage) {
        switch setupPage {
        case .thisMac: self = .hubs
        }
    }
}
