import CoreGraphics
import Foundation

/// The look-and-feel settings (panel size, text size, alerts, ...), read from and written to
/// UserDefaults as plain values so `defaults read app.needsyou.mac` stays readable.
///
/// - The defaults are the original look, so an upgrade changes nothing until the user
///   picks something. The exceptions are deliberate: arrival peeks stay out 14 s (was 4 s)
///   and a light dark backdrop sits behind the glass.
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
        public static let panelHoverOpacity = "panelHoverOpacity"
        public static let pillOpacity = "pillOpacity"
        public static let pillHoverOpacity = "pillHoverOpacity"
        public static let maxVisibleCards = "maxVisibleCards"
        public static let cardBodies = "cardBodies"
        public static let compactLinks = "compactLinks"
        public static let pillSize = "pillSize"
        public static let pillDetail = "pillDetail"
        public static let pillSplit = "pillSplit"
        public static let pillShowNew = "pillShowNew"
        public static let previewSeconds = "previewSeconds"
        public static let collapseOnClickOutside = "collapseOnClickOutside"
        public static let backdrop = "panelBackdrop"
        public static let expandedListHeight = "expandedListHeight"
        public static let theme = "theme"
        public static let accent = "themeAccent"
        public static let arrivalUrgent = "arrivalUrgent"
        public static let arrivalOther = "arrivalOther"
        public static let arrivalRepeats = "arrivalRepeats"
        public static let arrivalSpeed = "arrivalSpeed"
        public static let urgentReminderMinutes = "urgentReminderMinutes"
    }

    public var panelSize: PanelSize = .regular
    public var textSize: TextSize = .standard
    /// How loud urgent items are. Never quieter than `AlertStyle.urgentFloor` when drawn.
    public var alertUrgent: AlertIntensity = .normal
    /// How loud normal and low items are.
    public var alertOther: AlertIntensity = .normal
    /// Opacity (one of PanelOpacity.choices) of the open panel and the arrival preview with
    /// the pointer away and over them, and of the collapsed count pill likewise.
    public var panelOpacity: Double = PanelOpacity.standard
    public var panelHoverOpacity: Double = PanelOpacity.standard
    public var pillOpacity: Double = PanelOpacity.pillRestStandard
    public var pillHoverOpacity: Double = PanelOpacity.standard
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
    /// Seconds an arrival peek stays out (one of PeekDuration.choices; 0 = until clicked or
    /// pointed at). Default 14.
    public var previewSeconds: Int = PeekDuration.standard
    /// The open panel collapses when you click anywhere else (the default). Off: it stays
    /// open, so you can read a card while its link is open; Esc, the chevron, a double-click
    /// on the header and the shortcut still close it.
    public var collapseOnClickOutside = true
    /// A dark layer behind the pill's, preview's and open panel's glass, so text reads over
    /// busy or bright windows (one of PanelBackdrop.choices; 0 = plain glass).
    public var backdrop: Double = PanelBackdrop.standard
    /// The open panel's list height in points, set by dragging its grip; 0 = automatic.
    public var expandedListHeight: Double = 0
    /// Settings → Appearance → Theme: the panel's colours (PanelTheme) and an accent override.
    public var theme: PanelTheme = .standard
    public var accent: ThemeAccent = .theme
    /// Settings → Appearance → Alert style → Arrivals, for urgent items and for the rest
    /// (ArrivalMotion). Glow pulse is the original.
    public var arrivalUrgent: ArrivalAnimation = .glow
    public var arrivalOther: ArrivalAnimation = .glow
    /// How many times it plays (ArrivalRepeats.choices; 0 = from the alert loudness).
    public var arrivalRepeats: Int = ArrivalRepeats.automatic
    public var arrivalSpeed: PulseSpeed = .normal
    /// Play urgent's arrival again every N minutes while it's unseen (UrgentReminder; 0 = off).
    public var urgentReminderMinutes: Int = UrgentReminder.off

    public init() {}

    public static let defaults = UIPrefs()

    public static func load(from store: UserDefaults) -> UIPrefs {
        var p = UIPrefs()
        if let raw = store.string(forKey: Key.panelSize), let v = PanelSize(rawValue: raw) { p.panelSize = v }
        if let raw = store.string(forKey: Key.textSize), let v = TextSize(rawValue: raw) { p.textSize = v }
        if let raw = store.string(forKey: Key.alertUrgent), let v = AlertIntensity(rawValue: raw) { p.alertUrgent = v }
        if let raw = store.string(forKey: Key.alertOther), let v = AlertIntensity(rawValue: raw) { p.alertOther = v }
        if let v = store.object(forKey: Key.panelOpacity) as? NSNumber { p.panelOpacity = PanelOpacity.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.panelHoverOpacity) as? NSNumber { p.panelHoverOpacity = PanelOpacity.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.pillOpacity) as? NSNumber { p.pillOpacity = PanelOpacity.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.pillHoverOpacity) as? NSNumber { p.pillHoverOpacity = PanelOpacity.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.maxVisibleCards) as? NSNumber, ListHeightPolicy.choices.contains(v.intValue) {
            p.maxVisibleCards = v.intValue
        }
        if let raw = store.string(forKey: Key.cardBodies), let v = CardBodyMode(rawValue: raw) { p.cardBodies = v }
        if let v = store.object(forKey: Key.compactLinks) as? NSNumber { p.compactLinks = v.boolValue }
        if let raw = store.string(forKey: Key.pillSize), let v = PillSize(rawValue: raw) { p.pillSize = v }
        if let raw = store.string(forKey: Key.pillDetail), let v = PillDetail(rawValue: raw) { p.pillDetail = v }
        if let raw = store.string(forKey: Key.pillSplit), let v = PillSplit(rawValue: raw) { p.pillSplit = v }
        if let v = store.object(forKey: Key.pillShowNew) as? NSNumber { p.pillShowNew = v.boolValue }
        if let v = store.object(forKey: Key.previewSeconds) as? NSNumber { p.previewSeconds = PeekDuration.sanitized(v.intValue) }
        if let v = store.object(forKey: Key.backdrop) as? NSNumber { p.backdrop = PanelBackdrop.nearestChoice(v.doubleValue) }
        if let v = store.object(forKey: Key.collapseOnClickOutside) as? NSNumber { p.collapseOnClickOutside = v.boolValue }
        if let v = store.object(forKey: Key.expandedListHeight) as? NSNumber { p.expandedListHeight = ListResize.sanitized(v.doubleValue) }
        if let raw = store.string(forKey: Key.theme), let v = PanelTheme(rawValue: raw) { p.theme = v }
        p.accent = ThemeAccent(stored: store.string(forKey: Key.accent))
        if let raw = store.string(forKey: Key.arrivalUrgent), let v = ArrivalAnimation(rawValue: raw) {
            p.arrivalUrgent = ArrivalAnimation.effective(v, for: .urgent)
        }
        if let raw = store.string(forKey: Key.arrivalOther), let v = ArrivalAnimation(rawValue: raw) { p.arrivalOther = v }
        if let v = store.object(forKey: Key.arrivalRepeats) as? NSNumber { p.arrivalRepeats = ArrivalRepeats.sanitized(v.intValue) }
        if let raw = store.string(forKey: Key.arrivalSpeed), let v = PulseSpeed(rawValue: raw) { p.arrivalSpeed = v }
        if let v = store.object(forKey: Key.urgentReminderMinutes) as? NSNumber {
            p.urgentReminderMinutes = UrgentReminder.sanitized(v.intValue)
        }
        return p
    }

    /// Writes the keys whose value differs from `previous` (all of them when nil).
    public func save(to store: UserDefaults, previous: UIPrefs? = nil) {
        if previous?.panelSize != panelSize { store.set(panelSize.rawValue, forKey: Key.panelSize) }
        if previous?.textSize != textSize { store.set(textSize.rawValue, forKey: Key.textSize) }
        if previous?.alertUrgent != alertUrgent { store.set(alertUrgent.rawValue, forKey: Key.alertUrgent) }
        if previous?.alertOther != alertOther { store.set(alertOther.rawValue, forKey: Key.alertOther) }
        if previous?.panelOpacity != panelOpacity { store.set(panelOpacity, forKey: Key.panelOpacity) }
        if previous?.panelHoverOpacity != panelHoverOpacity { store.set(panelHoverOpacity, forKey: Key.panelHoverOpacity) }
        if previous?.pillOpacity != pillOpacity { store.set(pillOpacity, forKey: Key.pillOpacity) }
        if previous?.pillHoverOpacity != pillHoverOpacity { store.set(pillHoverOpacity, forKey: Key.pillHoverOpacity) }
        if previous?.maxVisibleCards != maxVisibleCards { store.set(maxVisibleCards, forKey: Key.maxVisibleCards) }
        if previous?.cardBodies != cardBodies { store.set(cardBodies.rawValue, forKey: Key.cardBodies) }
        if previous?.compactLinks != compactLinks { store.set(compactLinks, forKey: Key.compactLinks) }
        if previous?.pillSize != pillSize { store.set(pillSize.rawValue, forKey: Key.pillSize) }
        if previous?.pillDetail != pillDetail { store.set(pillDetail.rawValue, forKey: Key.pillDetail) }
        if previous?.pillSplit != pillSplit { store.set(pillSplit.rawValue, forKey: Key.pillSplit) }
        if previous?.pillShowNew != pillShowNew { store.set(pillShowNew, forKey: Key.pillShowNew) }
        if previous?.previewSeconds != previewSeconds { store.set(previewSeconds, forKey: Key.previewSeconds) }
        if previous?.backdrop != backdrop { store.set(backdrop, forKey: Key.backdrop) }
        if previous?.collapseOnClickOutside != collapseOnClickOutside { store.set(collapseOnClickOutside, forKey: Key.collapseOnClickOutside) }
        if previous?.expandedListHeight != expandedListHeight { store.set(expandedListHeight, forKey: Key.expandedListHeight) }
        if previous?.theme != theme { store.set(theme.rawValue, forKey: Key.theme) }
        if previous?.accent != accent { store.set(accent.storageString, forKey: Key.accent) }
        if previous?.arrivalUrgent != arrivalUrgent { store.set(arrivalUrgent.rawValue, forKey: Key.arrivalUrgent) }
        if previous?.arrivalOther != arrivalOther { store.set(arrivalOther.rawValue, forKey: Key.arrivalOther) }
        if previous?.arrivalRepeats != arrivalRepeats { store.set(arrivalRepeats, forKey: Key.arrivalRepeats) }
        if previous?.arrivalSpeed != arrivalSpeed { store.set(arrivalSpeed.rawValue, forKey: Key.arrivalSpeed) }
        if previous?.urgentReminderMinutes != urgentReminderMinutes {
            store.set(urgentReminderMinutes, forKey: Key.urgentReminderMinutes)
        }
    }

    public var metrics: PanelMetrics { PanelStyle.metrics(panelSize) }
    /// The panel's colours for the theme, the accent override and macOS's appearance.
    public func palette(systemIsDark: Bool) -> PanelPalette {
        theme.palette(systemIsDark: systemIsDark, accent: accent)
    }
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

    /// The arrival animation chosen for a priority (urgent never None).
    public func arrivalAnimation(for priority: ItemPriority) -> ArrivalAnimation {
        ArrivalAnimation.effective(priority == .urgent ? arrivalUrgent : arrivalOther, for: priority)
    }

    /// The arrival to play for `priority`: the chosen animation at the alert loudness,
    /// with the timing settings.
    public func arrivalPlan(for priority: ItemPriority, basePulses: Int = 1, reduceMotion: Bool = false) -> ArrivalPlan {
        ArrivalMotion.plan(arrivalAnimation(for: priority), look: alertLook(for: priority, basePulses: basePulses),
                           speed: arrivalSpeed, repeats: arrivalRepeats, reduceMotion: reduceMotion)
    }

    /// What to draw for `priority` (the urgent floor applied).
    public func alertLook(for priority: ItemPriority, basePulses: Int = 1) -> AlertLook {
        AlertStyle.look(alertIntensity(for: priority), priority: priority, basePulses: basePulses)
    }
}
