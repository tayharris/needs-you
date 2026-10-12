import NeedsYouCore
import SwiftUI

// settings-section: openPanel
/// Settings → Panel → Open panel: whether it opens when the app starts and whether a click
/// elsewhere closes it. Its height (dragged or Cards before scrolling) is look:
/// Appearance → Panel and cards.
struct OpenPanelSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.openPanelAtLaunch) {
                LabelWithDetail("Open the panel when Needs You starts", "When you start the app yourself, the panel opens once so you can see your items, without taking focus. It closes after \(LaunchOpen.seconds) seconds with the pointer away, or when you click elsewhere. At login, and when an update restarts the app, only the pill shows.")
            }
            Toggle(isOn: $settings.ui.collapseOnClickOutside) {
                LabelWithDetail("Collapse when clicking elsewhere", "On: a click anywhere else closes it. Off: it stays up, even after you open a card's link, so you can keep reading the card.")
            }
        } header: {
            Text("Open panel")
        } footer: {
            Text("The chevron, a double-click on the header bar and the shortcut always close it. With the setting off, Esc does too, except right after you click in another app (point at the panel again first). How tall it is: Appearance → Panel and cards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
