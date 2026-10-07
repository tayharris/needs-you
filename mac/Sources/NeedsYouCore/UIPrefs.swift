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
        public static let alertUrgent = "alertStyleUrgent"
        public static let alertOther = "alertStyleOther"
        public static let panelOpacity = "panelOpacity"
        public static let maxVisibleCards = "maxVisibleCards"
        public static let cardBodies = "cardBodies"
        public static let compactLinks = "compactLinks"
        public static let pillSize = "pillSize"
        public static let pillDetail = "pillDetail"
        public static let pillSplit = "pillSplit"
        public static let pillShowNew = "pillShowNew"
    }

    public var panelSize: PanelSize = .regular
    public var textSize: TextSize = .standard
    /// How loud urgent items are. Never quieter than `AlertStyle.urgentFloor` when drawn.
    public var alertUrgent: AlertIntensity = .normal
    /// How loud normal and low items are.
    public var alertOther: AlertIntensity = .normal
    /// Count pill, preview and open panel opacity when not hovered (one of PanelOpacity.choices).
    public var panelOpacity: Double = PanelOpacity.standard
    /// Cards shown before the list scrolls; 0 = as many as fit.
    public var maxVisibleCards: Int = 0
    public var cardBodies: CardBodyMode = .full
    /// At most three short link labels per card.
    public var compactLinks = false
    /// The collapsed pill (PillContent): its size on top of `panelSize`, how much it says,
    /// how it splits the count, and the "N new" badge.
    public var pillSize: PillSize = .medium
    public var pillDetail: PillDetail = .count
    public var pillSplit: PillSplit = .none
    public var pillShowNew = true

    public init() {}

    public static let defaults = UIPrefs()

    public static func load(from store: UserDefaults) -> UIPrefs {
        var p = UIPrefs()
        if let raw = store.string(forKey: Key.panelSize), let v = PanelSize(rawValue: raw) { p.panelSize = v }
        if let raw = store.string(forKey: Key.textSize), let v = TextSize(rawValue: raw) { p.textSize = v }
        if let raw = store.string(forKey: Key.alertUrgent), let v = AlertIntensity(rawValue: raw) { p.alertUrgent = v }
        if let raw = store.string(forKey: Key.alertOther), let v = AlertIntensity(rawValue: raw) { p.alertOther = v }
        if let v = store.object(forKey: Key.panelOpacity) as? NSNumber { p.panelOpacity = PanelOpacity.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.maxVisibleCards) as? NSNumber, ListHeightPolicy.choices.contains(v.intValue) {
            p.maxVisibleCards = v.intValue
        }
        if let raw = store.string(forKey: Key.cardBodies), let v = CardBodyMode(rawValue: raw) { p.cardBodies = v }
        if let v = store.object(forKey: Key.compactLinks) as? NSNumber { p.compactLinks = v.boolValue }
        if let raw = store.string(forKey: Key.pillSize), let v = PillSize(rawValue: raw) { p.pillSize = v }
        if let raw = store.string(forKey: Key.pillDetail), let v = PillDetail(rawValue: raw) { p.pillDetail = v }
        if let raw = store.string(forKey: Key.pillSplit), let v = PillSplit(rawValue: raw) { p.pillSplit = v }
        if let v = store.object(forKey: Key.pillShowNew) as? NSNumber { p.pillShowNew = v.boolValue }
        return p
    }

    /// Writes the keys whose value differs from `previous` (all of them when nil).
    public func save(to store: UserDefaults, previous: UIPrefs? = nil) {
        if previous?.panelSize != panelSize { store.set(panelSize.rawValue, forKey: Key.panelSize) }
        if previous?.textSize != textSize { store.set(textSize.rawValue, forKey: Key.textSize) }
        if previous?.alertUrgent != alertUrgent { store.set(alertUrgent.rawValue, forKey: Key.alertUrgent) }
        if previous?.alertOther != alertOther { store.set(alertOther.rawValue, forKey: Key.alertOther) }
        if previous?.panelOpacity != panelOpacity { store.set(panelOpacity, forKey: Key.panelOpacity) }
        if previous?.maxVisibleCards != maxVisibleCards { store.set(maxVisibleCards, forKey: Key.maxVisibleCards) }
        if previous?.cardBodies != cardBodies { store.set(cardBodies.rawValue, forKey: Key.cardBodies) }
        if previous?.compactLinks != compactLinks { store.set(compactLinks, forKey: Key.compactLinks) }
        if previous?.pillSize != pillSize { store.set(pillSize.rawValue, forKey: Key.pillSize) }
        if previous?.pillDetail != pillDetail { store.set(pillDetail.rawValue, forKey: Key.pillDetail) }
        if previous?.pillSplit != pillSplit { store.set(pillSplit.rawValue, forKey: Key.pillSplit) }
        if previous?.pillShowNew != pillShowNew { store.set(pillShowNew, forKey: Key.pillShowNew) }
    }

    public var metrics: PanelMetrics { PanelStyle.metrics(panelSize) }
    public var bodyFont: CGFloat { PanelStyle.bodyFont(textSize, panel: panelSize) }
    public var pillOptions: PillOptions {
        PillOptions(size: pillSize, detail: pillDetail, split: pillSplit, showNew: pillShowNew)
    }
    /// The collapsed pill's sizes: the panel size's, scaled by the pill size.
    public var pillMetrics: PillMetrics { PillMetrics.make(metrics, size: pillSize) }

    /// The chosen alert intensity for a priority (before the urgent floor).
    public func alertIntensity(for priority: ItemPriority) -> AlertIntensity {
        priority == .urgent ? alertUrgent : alertOther
    }

    /// What to draw for `priority` (the urgent floor applied).
    public func alertLook(for priority: ItemPriority, basePulses: Int = 1) -> AlertLook {
        AlertStyle.look(alertIntensity(for: priority), priority: priority, basePulses: basePulses)
    }
}
