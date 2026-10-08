import NeedsYouCore
import SwiftUI

/// Settings → Alerts → Arrivals: the arrival animation (urgent and the rest), its timing,
/// how long the new-item preview (and the Later summary peek) stays out, the repeat
/// reminder for unseen urgent items, and a Preview that plays it on the pill.
struct ArrivalSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Picker(selection: $settings.ui.arrivalUrgent) {
                ForEach(ArrivalAnimation.choices(for: .urgent), id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Urgent items arrive with", "Never None: urgent always moves at least once.")
            }
            Picker(selection: $settings.ui.arrivalOther) {
                ForEach(ArrivalAnimation.choices(for: .normal), id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Normal and low items arrive with", "None: no motion, just the preview and the ring.")
            }
            Picker(selection: $settings.ui.arrivalRepeats) {
                ForEach(ArrivalRepeats.choices, id: \.self) { Text(ArrivalRepeats.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Plays", "Automatic: urgent twice and the rest once, one more at Bright. Slide in plays once.")
            }
            Picker(selection: $settings.ui.arrivalSpeed) {
                ForEach(PulseSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Speed", "How quickly each pulse, hop or shake plays.")
            }
            Picker(selection: $settings.ui.previewSeconds) {
                ForEach(PeekDuration.choices, id: \.self) { Text(PeekDuration.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Show new items for", "How long the preview of a new item stays out before the pill goes back.")
            }
            Picker(selection: $settings.ui.urgentReminderMinutes) {
                ForEach(UrgentReminder.choices, id: \.self) { Text(UrgentReminder.title($0)).tag($0) }
            } label: {
                LabelWithDetail("Remind about unseen urgent items",
                                "Plays urgent's arrival again until you open the panel. Not while snoozed, hidden or in a focus that holds urgent.")
            }
            HStack {
                LabelWithDetail("Preview on the pill", model.isPanelVisible
                                ? "Plays your choice on the floating pill. Nothing is posted."
                                : "Show the floating panel to preview it.")
                Spacer()
                Button("Urgent") { model.previewArrival(.urgent) }
                Button("Normal") { model.previewArrival(.normal) }
            }
            .disabled(!model.isPanelVisible)
        } header: {
            Text("Arrivals")
        } footer: {
            Text("Pointing at the preview holds it open; it goes \(Int(PeekDuration.hoverGrace)) s after the pointer leaves. Click it to open the panel. With Reduce Motion on, every animation is a gentle fade.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
