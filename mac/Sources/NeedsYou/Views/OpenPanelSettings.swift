import NeedsYouCore
import SwiftUI

/// Settings → Panel → Open panel: whether a click elsewhere closes it, and its dragged height.
struct OpenPanelSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.ui.collapseOnClickOutside) {
                LabelWithDetail("Collapse when clicking elsewhere", "Off: the open panel stays up, even after you open a card's link, so you can keep reading the card.")
            }
            HStack {
                LabelWithDetail("List height", settings.ui.expandedListHeight > 0
                                ? "\(Int(settings.ui.expandedListHeight)) pt, set by dragging the panel's edge."
                                : "Automatic. Drag the open panel's bottom (or top) edge to set it.")
                Spacer()
                Button("Automatic") { settings.ui.expandedListHeight = 0 }
                    .disabled(settings.ui.expandedListHeight <= 0)
            }
        } header: {
            Text("Open panel")
        } footer: {
            Text("The chevron and the shortcut always close it. Esc does too, except right after you click in another app (point at the panel again first). A dragged height replaces Cards before scrolling; double-click the edge to go back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
