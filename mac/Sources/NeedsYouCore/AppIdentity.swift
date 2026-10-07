import Foundation

/// The app's bundle id: its UserDefaults domain, its log subsystem and what the updater and
/// install.sh expect. Changing it resets settings and the login item for everyone.
public enum AppIdentity {
    public static let bundleID = "app.needsyou.mac"
    /// The unified log subsystem (`log show --predicate 'subsystem == "app.needsyou.mac"'`).
    public static let logSubsystem = bundleID
}
