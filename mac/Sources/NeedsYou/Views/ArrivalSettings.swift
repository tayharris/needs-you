import NeedsYouCore
import SwiftUI

/// Settings → Alerts → Arrivals: how long the new-item preview (and the Later summary
/// peek) stays out.
struct ArrivalSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: $settings.ui.previewSeconds) {
                ForEach(PeekDuration.choices, id: \.self) { Text(PeekDuration.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Show new items for", "How long the preview of a new item stays out before the pill goes back.")
            }
        } header: {
            Text("Arrivals")
        } footer: {
            Text("Pointing at the preview holds it open; it goes \(Int(PeekDuration.hoverGrace)) s after the pointer leaves. Click it to open the panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
