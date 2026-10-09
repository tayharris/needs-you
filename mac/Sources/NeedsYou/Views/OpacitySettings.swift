import NeedsYouCore
import SwiftUI

/// Settings → Appearance → Panel and cards → Opacity: the collapsed pill and the open panel, each with the pointer
/// away and over it. The open panel's values also apply to the arrival preview. Glass only:
/// Theme → Background → Solid is always opaque, so these are dimmed then.
struct OpacitySettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let solid = settings.ui.background == .solid
        Section {
            Picker(selection: $settings.ui.backdrop) {
                ForEach(PanelBackdrop.choices, id: \.self) { Text(PanelBackdrop.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Background darkness", "A dark layer behind the glass so cards are easy to read over bright or busy windows. It stays see-through.")
            }
            .disabled(solid)
            picker($settings.ui.pillOpacity, "Collapsed pill", "The count pill while the pointer is elsewhere.", disabled: solid)
            picker($settings.ui.pillHoverOpacity, "Collapsed pill, pointer over it", "While you point at the count pill.", disabled: solid)
            picker($settings.ui.panelOpacity, "Open panel", "The open panel and new-item previews while the pointer is elsewhere.", disabled: solid)
            picker($settings.ui.panelHoverOpacity, "Open panel, pointer over it", "While you point at the open panel or a preview.", disabled: solid)
        } header: {
            Text("Opacity")
        } footer: {
            Text(solid
                 ? "Theme → Background is Solid, which is always opaque, so these apply only to Glass."
                 : "Background darkness tints the glass; the percentages below fade the whole panel. Lower is more see-through. The idle “Nothing needs you” pill stays faint on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func picker(_ value: Binding<Double>, _ title: String, _ detail: String, disabled: Bool) -> some View {
        Picker(selection: value) {
            ForEach(PanelOpacity.choices, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
        } label: {
            LabelWithDetail(title, detail)
        }
        .disabled(disabled)
    }
}
