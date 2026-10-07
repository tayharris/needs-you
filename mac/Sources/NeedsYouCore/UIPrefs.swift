import CoreGraphics
import Foundation

/// The look-and-feel settings (panel size, text size, alerts, ...), read from and written to
/// UserDefaults as plain values so `defaults read app.needsyou.mac` stays readable.
///
/// - The defaults are the original look, so an upgrade changes nothing until the user
///   picks something.
/// - Unknown or out-of-range stored values fall back to the default for that key (a newer
///   build may store a choice this one doesn't know).
/// - `load` never writes, and `save` only writes these keys, so a rollback loses nothing.
public struct UIPrefs: Equatable, Sendable {
    public enum Key {
        public static let panelSize = "panelSize"
        public static let textSize = "cardTextSize"
    }

    public var panelSize: PanelSize = .regular
    public var textSize: TextSize = .standard

    public init() {}

    public static let defaults = UIPrefs()

    public static func load(from store: UserDefaults) -> UIPrefs {
        var p = UIPrefs()
        if let raw = store.string(forKey: Key.panelSize), let v = PanelSize(rawValue: raw) { p.panelSize = v }
        if let raw = store.string(forKey: Key.textSize), let v = TextSize(rawValue: raw) { p.textSize = v }
        return p
    }

    /// Writes the keys whose value differs from `previous` (all of them when nil).
    public func save(to store: UserDefaults, previous: UIPrefs? = nil) {
        if previous?.panelSize != panelSize { store.set(panelSize.rawValue, forKey: Key.panelSize) }
        if previous?.textSize != textSize { store.set(textSize.rawValue, forKey: Key.textSize) }
    }

    public var metrics: PanelMetrics { PanelStyle.metrics(panelSize) }
    public var bodyFont: CGFloat { PanelStyle.bodyFont(textSize, panel: panelSize) }
}
