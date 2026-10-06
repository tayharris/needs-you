import AppKit

// A menu-bar-less agent app (LSUIElement in the bundle's Info.plist; the activation
// policy is also set here so `swift run NeedsTay` behaves the same).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
