import Foundation

// Where every setting lives in the Settings window, and whether it is a look setting or a
// behaviour setting. The rule (mac/README.md, docs/guides/mac-app.md):
//
// - Look: changes only how something already on screen is drawn (colour, size, shape,
//   density, opacity, animation, style). Every look setting is on a page in the ONE
//   Appearance group: Theme, Pill, Panel and cards, Alert style or Usage meters.
// - Behaviour: what shows, where, when, and what may interrupt you. Never under
//   Appearance: Panel, Alerts, Integrations, General, Updates, Advanced or a hub page.
// - One feature's look is never split across groups.
//
// `SettingsRegistry.all` says, for each stored key, which kind it is and which page shows
// it. `SettingsSection` lists every section of every page, in order; the Settings window
// builds each page from `SettingsSection.sections(on:)`. SettingsLayoutTests checks the
// registry against the rule, checks that every UIPrefs (and usage, delivery, update,
// app) key is registered, and reads the app's Settings sources to check that each
// section only writes keys registered to its page.

/// Look or behaviour (see above).
public enum SettingKind: String, Sendable {
    case look, behaviour
}

/// One stored setting: its UserDefaults key, how the Settings views write it, its kind and
/// the page that shows it.
public struct SettingPlacement: Equatable, Sendable {
    /// The UserDefaults key.
    public let key: String
    /// The property the Settings views bind or assign, as written after `settings.` in the
    /// app (`ui.pillSize` for `$settings.ui.pillSize`); other owners keep their root
    /// (`phase3.useStream`, `updates.prefs.channel`). The source check matches on this.
    public let path: String
    public let kind: SettingKind
    public let tab: SettingsTab

    public static func look(_ key: String, _ path: String, on tab: SettingsTab) -> SettingPlacement {
        SettingPlacement(key: key, path: path, kind: .look, tab: tab)
    }

    public static func behaviour(_ key: String, _ path: String, on tab: SettingsTab) -> SettingPlacement {
        SettingPlacement(key: key, path: path, kind: .behaviour, tab: tab)
    }
}

public enum SettingsRegistry {
    // HOW TO ADD A SETTING (one line):
    //   1. Add the key (UIPrefs.Key, UsagePrefs.Key, AppPrefKey, ...) and its control.
    //   2. Add one line below: `.look(key, "path", on: page)` if it only changes how
    //      something looks (the page must be under Appearance: .theme, .pill, .cards,
    //      .alertStyle, .usageMeters), else `.behaviour(key, "path", on: page)` (never an
    //      Appearance page). `path` is what the control binds after `settings.`, e.g.
    //      "ui.pillShape" for `$settings.ui.pillShape`.
    //   3. Put the control in the view of a `SettingsSection` on that page.
    // SettingsLayoutTests fails until all three agree. Keys that no page shows (state the
    // app keeps for itself) go in `unlisted` instead, with the reason.
    public static let all: [SettingPlacement] = [
        // Appearance → Theme
        .look(UIPrefs.Key.theme, "ui.theme", on: .theme),
        .look(UIPrefs.Key.accent, "ui.accent", on: .theme),
        .look(UIPrefs.Key.background, "ui.background", on: .theme),
        // Appearance → Pill
        .look(UIPrefs.Key.panelShape, "ui.panelShape", on: .pill),
        .look(UIPrefs.Key.pillSize, "ui.pillSize", on: .pill),
        .look(UIPrefs.Key.pillDetail, "ui.pillDetail", on: .pill),
        .look(UIPrefs.Key.pillSplit, "ui.pillSplit", on: .pill),
        .look(UIPrefs.Key.pillShowNew, "ui.pillShowNew", on: .pill),
        // Appearance → Panel and cards
        .look(UIPrefs.Key.panelSize, "ui.panelSize", on: .cards),
        .look(UIPrefs.Key.cardDensity, "ui.cardDensity", on: .cards),
        .look(UIPrefs.Key.textSize, "ui.textSize", on: .cards),
        .look(UIPrefs.Key.cardBodies, "ui.cardBodies", on: .cards),
        .look(UIPrefs.Key.compactLinks, "ui.compactLinks", on: .cards),
        .look(UIPrefs.Key.maxVisibleCards, "ui.maxVisibleCards", on: .cards),
        .look(UIPrefs.Key.expandedListHeight, "ui.expandedListHeight", on: .cards),
        .look(UIPrefs.Key.backdrop, "ui.backdrop", on: .cards),
        .look(UIPrefs.Key.pillOpacity, "ui.pillOpacity", on: .cards),
        .look(UIPrefs.Key.pillHoverOpacity, "ui.pillHoverOpacity", on: .cards),
        .look(UIPrefs.Key.panelOpacity, "ui.panelOpacity", on: .cards),
        .look(UIPrefs.Key.panelHoverOpacity, "ui.panelHoverOpacity", on: .cards),
        // Appearance → Alert style
        .look(UIPrefs.Key.alertUrgent, "ui.alertUrgent", on: .alertStyle),
        .look(UIPrefs.Key.alertOther, "ui.alertOther", on: .alertStyle),
        .look(UIPrefs.Key.arrivalUrgent, "ui.arrivalUrgent", on: .alertStyle),
        .look(UIPrefs.Key.arrivalOther, "ui.arrivalOther", on: .alertStyle),
        .look(UIPrefs.Key.arrivalRepeats, "ui.arrivalRepeats", on: .alertStyle),
        .look(UIPrefs.Key.arrivalSpeed, "ui.arrivalSpeed", on: .alertStyle),
        .look(EdgeGlowMode.defaultsKey, "edgeGlow", on: .alertStyle),
        // Appearance → Usage meters
        .look(UsagePrefs.Key.pillStyle, "usage.pillStyle", on: .usageMeters),
        .look(UsagePrefs.Key.pillSize, "usage.pillSize", on: .usageMeters),
        .look(UsagePrefs.Key.pillArrangement, "usage.pillArrangement", on: .usageMeters),
        .look(UsagePrefs.Key.pillNumbers, "usage.pillNumbers", on: .usageMeters),
        .look(UsagePrefs.Key.warnPct, "usage.warnPct", on: .usageMeters),

        // General
        .behaviour(AppPrefKey.userName.rawValue, "userName", on: .general),
        .behaviour(AppPrefKey.demoMode.rawValue, "demoMode", on: .general),
        // Built-in hub, Other hubs
        .behaviour(AppPrefKey.runLocalHub.rawValue, "runLocalHub", on: .inbox),
        .behaviour(AppPrefKey.hubURLs.rawValue, "hubURLStrings", on: .otherHubs),
        // Panel
        .behaviour(AppPrefKey.panelHidden.rawValue, "panelHidden", on: .panel),
        .behaviour(AppPrefKey.showMenuBarIcon.rawValue, "showMenuBarIcon", on: .panel),
        .behaviour(AppPrefKey.showMenuBarCount.rawValue, "showMenuBarCount", on: .panel),
        .behaviour(AppPrefKey.snapToCorners.rawValue, "snapToCorners", on: .panel),
        .behaviour(AppPrefKey.openPanelAtLaunch.rawValue, "openPanelAtLaunch", on: .panel),
        .behaviour(UIPrefs.Key.collapseOnClickOutside, "ui.collapseOnClickOutside", on: .panel),
        .behaviour(UsagePrefs.Key.inPanel, "usage.inPanel", on: .panel),
        .behaviour(UsagePrefs.Key.onPill, "usage.onPill", on: .panel),
        .behaviour(UsagePrefs.Key.providers, "usage.providers", on: .panel),
        .behaviour(UsagePrefs.Key.windows, "usage.windows", on: .panel),
        .behaviour(UsagePrefs.Key.hideUnderPct, "usage.hideUnderPct", on: .panel),
        .behaviour(AppPrefKey.showSetupTips.rawValue, "showSetupTips", on: .panel),
        .behaviour(AppPrefKey.setupTipsDismissed.rawValue, "setupTipsDismissed", on: .panel),
        .behaviour(AppPrefKey.showOrcaWorktrees.rawValue, "showOrcaWorktrees", on: .panel),
        .behaviour(AppPrefKey.hotKey.rawValue, "hotKey", on: .panel),
        // Alerts
        .behaviour(UIPrefs.Key.previewSeconds, "ui.previewSeconds", on: .alerts),
        .behaviour(UIPrefs.Key.urgentReminderMinutes, "ui.urgentReminderMinutes", on: .alerts),
        .behaviour(DeliveryDefaults.Key.normal, "delivery.normal", on: .alerts),
        .behaviour(DeliveryDefaults.Key.low, "delivery.low", on: .alerts),
        .behaviour(DeliveryDefaults.Key.recent, "delivery.recent", on: .alerts),
        .behaviour(DeliveryDefaults.Key.otherContext, "delivery.otherContext", on: .alerts),
        .behaviour(DeliveryDefaults.Key.urgentBreaksFocus, "delivery.urgentBreaksFocus", on: .alerts),
        .behaviour(AppPrefKey.allowFocusLinks.rawValue, "allowFocusLinks", on: .alerts),
        .behaviour(AppPrefKey.urgentBreaksSnooze.rawValue, "urgentBreaksSnooze", on: .alerts),
        .behaviour(AppPrefKey.urgentShowsHiddenPanel.rawValue, "urgentShowsHiddenPanel", on: .alerts),
        .behaviour(RuleBook.defaultsKey, "bypassRules", on: .alerts),
        .behaviour(PreviewDisplay.defaultsKey, "previewDisplay", on: .alerts),
        .behaviour(AppPrefKey.followSchedule.rawValue, "phase3.followSchedule", on: .alerts),
        .behaviour(AppPrefKey.morningSummary.rawValue, "phase3.morningSummaryEnabled", on: .alerts),
        // Integrations
        .behaviour(AppPrefKey.terminalAppleScript.rawValue, "terminalAppleScript", on: .integrations),
        // Updates
        .behaviour(UpdatePrefs.Key.check, "updates.prefs.checkAutomatically", on: .updates),
        .behaviour(UpdatePrefs.Key.install, "updates.prefs.installAutomatically", on: .updates),
        .behaviour(UpdatePrefs.Key.channel, "updates.prefs.channel", on: .updates),
        .behaviour(UpdatePrefs.Key.soakHours, "updates.prefs.soakHours", on: .updates),
        // Advanced
        .behaviour(AppPrefKey.useStream.rawValue, "phase3.useStream", on: .advanced),
        .behaviour(AppPrefKey.developerMode.rawValue, "developerMode", on: .advanced),
    ]

    /// Stored keys no Settings page shows: state the app keeps, not a choice. Key: why.
    public static let unlisted: [String: String] = [
        AppPrefKey.viewContext.rawValue: "the work / personal side picked in the panel",
        AppPrefKey.placements.rawValue: "where the pill was dragged, per screen layout",
        AppPrefKey.pillLastOpenedAt.rawValue: "when the panel was last opened (the pill's new badge)",
        AppPrefKey.setupTipsDone.rawValue: "setup tips done for good",
        AppPrefKey.lastMorningSummary.rawValue: "when the start-of-day summary last showed",
        AppPrefKey.toolSightings.rawValue: "which tool pollers have sent cards, for what (Integrations → Your tools)",
        UpdatePrefs.Key.skipped: "versions skipped from the update banner",
        UpdatePrefs.Key.lastCheck: "when updates were last checked",
        UpdatePrefs.Key.feedURL: "testing only: a local update feed",
    ]

    public static func placement(forKey key: String) -> SettingPlacement? {
        all.first { $0.key == key }
    }

    public static func placement(forPath path: String) -> SettingPlacement? {
        all.first { $0.path == path }
    }

    /// The keys a page shows, in registry order.
    public static func keys(on tab: SettingsTab) -> [String] {
        all.filter { $0.tab == tab }.map(\.key)
    }
}

/// The app's own UserDefaults keys (AppSettings and the phase 3 controller use these).
/// Every case must be in `SettingsRegistry.all` or `SettingsRegistry.unlisted`.
public enum AppPrefKey: String, CaseIterable, Sendable {
    case hubURLs, userName, demoMode, urgentBreaksSnooze, viewContext
    case placements = "panelPlacements"
    case runLocalHub, showMenuBarIcon, showMenuBarCount, urgentShowsHiddenPanel, panelHidden
    case snapToCorners, openPanelAtLaunch, hotKey, allowFocusLinks, terminalAppleScript
    case pillLastOpenedAt, showSetupTips, showOrcaWorktrees, setupTipsDone, setupTipsDismissed
    case developerMode, toolSightings
    // Phase 3 (Phase3Controller).
    case followSchedule, morningSummary, useStream
    case lastMorningSummary
}

/// Every section of every Settings page, in page order. The window draws a page as
/// `sections(on: page)`, each section's view tagged `// settings-section: <case>` in the app
/// so SettingsLayoutTests can check what it writes. Add a case here, in the place it
/// should show, when a page gets a new section.
public enum SettingsSection: String, CaseIterable, Sendable {
    // General
    case moveToApplications, welcome, you, startup, demo
    // Connect a machine: the Setup overview first
    case setupOverview, inviteWarning, invite, inviteUnavailable
    // Built-in hub
    case howItWorks, builtInHub, hubAddresses, alwaysOnHubs
    // Machines
    case machines, openInvites
    // Integrations: what's already sending first
    case yourTools, toolCards, terminalButton, usageSetup
    // Other hubs
    case otherHubsIntro, joinWithLink, linkSources, serverHubs, hubList
    // Appearance → Theme
    case theme
    // Appearance → Pill
    case pill
    // Appearance → Panel and cards
    case panelAndCards, opacity
    // Appearance → Alert style
    case glowAndRing, arrivals, edgeGlow
    // Appearance → Usage meters
    case usageMeterLook
    // Panel
    case panelAndMenuBar, openPanel, usageMeterContent, setupTips, orca, keyboard
    // Alerts
    case newItems, workScreen, delivery, snoozedOrHidden, bypassRules, schedule
    // Updates
    case updates
    // Advanced
    case liveUpdates, advanced

    /// The page that shows this section.
    public var tab: SettingsTab {
        switch self {
        case .moveToApplications, .welcome, .you, .startup, .demo: return .general
        case .setupOverview, .inviteWarning, .invite, .inviteUnavailable: return .connect
        case .howItWorks, .builtInHub, .hubAddresses, .alwaysOnHubs: return .inbox
        case .machines, .openInvites: return .machines
        case .otherHubsIntro, .joinWithLink, .linkSources, .serverHubs, .hubList: return .otherHubs
        case .theme: return .theme
        case .pill: return .pill
        case .panelAndCards, .opacity: return .cards
        case .glowAndRing, .arrivals, .edgeGlow: return .alertStyle
        case .usageMeterLook: return .usageMeters
        case .panelAndMenuBar, .openPanel, .usageMeterContent, .setupTips, .orca, .keyboard: return .panel
        case .newItems, .workScreen, .delivery, .snoozedOrHidden, .bypassRules, .schedule: return .alerts
        case .yourTools, .toolCards, .terminalButton, .usageSetup: return .integrations
        case .updates: return .updates
        case .liveUpdates, .advanced: return .advanced
        }
    }

    /// A page's sections, in order.
    public static func sections(on tab: SettingsTab) -> [SettingsSection] {
        allCases.filter { $0.tab == tab }
    }
}

/// Advanced → Reset Appearance: every look setting (the `.look` lines in
/// `SettingsRegistry.all`, on the Appearance pages) back to its default, and nothing else.
/// Behaviour settings that share a value type with look ones (how long new items show, the
/// urgent reminder, Collapse when clicking elsewhere; whether the usage meters show, which
/// providers and windows) keep their values. SettingsLayoutTests checks this against the
/// registry, key by key.
public enum AppearanceReset {
    public static func ui(_ prefs: UIPrefs) -> UIPrefs {
        var reset = UIPrefs.defaults
        reset.previewSeconds = prefs.previewSeconds
        reset.urgentReminderMinutes = prefs.urgentReminderMinutes
        reset.collapseOnClickOutside = prefs.collapseOnClickOutside
        return reset
    }

    public static func usage(_ prefs: UsagePrefs) -> UsagePrefs {
        let standard = UsagePrefs()
        var reset = prefs
        reset.pillStyle = standard.pillStyle
        reset.pillSize = standard.pillSize
        reset.pillArrangement = standard.pillArrangement
        reset.pillNumbers = standard.pillNumbers
        reset.warnPct = standard.warnPct
        return reset
    }

    public static let edgeGlow = EdgeGlowMode.standard

    /// Whether every look setting is already at its default (the button is then disabled).
    public static func isDefault(ui: UIPrefs, usage: UsagePrefs, edgeGlow: EdgeGlowMode) -> Bool {
        Self.ui(ui) == ui && Self.usage(usage) == usage && edgeGlow == Self.edgeGlow
    }
}
