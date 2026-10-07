import NeedsYouCore
import SwiftUI

/// Settings → Panel → Opacity: the collapsed pill and the open panel, each with the pointer
/// away and over it. The open panel's values also apply to the arrival preview.
struct OpacitySettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            picker($settings.ui.pillOpacity, "Collapsed pill", "The count pill while the pointer is elsewhere.")
            picker($settings.ui.pillHoverOpacity, "Collapsed pill, pointer over it", "While you point at the count pill.")
            picker($settings.ui.panelOpacity, "Open panel", "The open panel and new-item previews while the pointer is elsewhere.")
            picker($settings.ui.panelHoverOpacity, "Open panel, pointer over it", "While you point at the open panel or a preview.")
        } header: {
            Text("Opacity")
        } footer: {
            Text("Lower is more see-through. The idle “Nothing needs you” pill stays faint on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker(_ value: Binding<Double>, _ title: String, _ detail: String) -> some View {
        Picker(selection: value) {
            ForEach(PanelOpacity.choices, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
        } label: {
            LabelWithDetail(title, detail)
        }
    }
}
