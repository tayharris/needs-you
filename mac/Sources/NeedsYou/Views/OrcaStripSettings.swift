import NeedsYouCore
import SwiftUI

/// Settings → Panel → Orca: the open panel's list of Orca worktrees (OrcaWorktrees).
struct OrcaStripSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.showOrcaWorktrees) {
                LabelWithDetail("Show Orca worktrees", "A folded ORCA section at the bottom of the open panel: each worktree's name, status and live terminals, from this Mac's Orca and its paired environments.")
            }
        } header: {
            Text("Orca")
        } footer: {
            Text("Read on this Mac with `orca worktree ps` while the panel is open, about every \(Int(OrcaWorktrees.refreshInterval)) seconds. Nothing is sent to a hub, counted or announced. Shown only when the Orca CLI is installed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
