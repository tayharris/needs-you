import NeedsYouCore
import SwiftUI

/// Settings → Appearance → Alert style → Arrivals: the arrival animation (urgent and the
/// rest), how many times it plays and how fast, and a Preview that plays it on the pill.
/// How long the preview stays out and the urgent reminder are behaviour, on Alerts
/// (ArrivalTimingSection).
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
            HStack {
                LabelWithDetail("Preview on the pill", model.isPanelVisible
                                ? "A sample item arrives on the floating pill the way a real one does. Nothing is posted."
                                : "Show the floating panel to preview it.")
                Spacer()
                Button("Urgent") { model.previewArrival(.urgent) }
                Button("Normal") { model.previewArrival(.normal) }
            }
            .disabled(!model.isPanelVisible)
        } header: {
            Text("Arrivals")
        } footer: {
            Text("With Reduce Motion on, every animation is a gentle fade. How long a new item stays out, and the reminder for unseen urgent items, are in Alerts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Alerts → New items: how long the new-item preview (and the Later summary
/// peek) stays out, and the repeat reminder for unseen urgent items. How they look is
/// Appearance → Alert style (ArrivalSettingsSection).
struct ArrivalTimingSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
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
        } header: {
            Text("New items")
        } footer: {
            Text("Pointing at the preview holds it open; it goes \(Int(PeekDuration.hoverGrace)) s after the pointer leaves. Click it to open the panel. How a new item looks as it arrives is in Appearance → Alert style.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
