import AppKit
import NeedsYouCore

/// Focus ▸ Off, then Agents and urgent only ▸ / Urgent only ▸ / Everything later ▸, each
/// for 30 min, 1 hr, 2 hr or until tomorrow (docs/roadmap/focus-tiers.md). Shared by the
/// pill's right-click menu and the menu bar menu. Choosing one never activates the app.
@MainActor
enum FocusMenu {
    static func item(model: AppModel) -> NSMenuItem {
        let level = model.focusLevel
        let root = NSMenuItem(title: level == .off ? "Focus" : "Focus: \(level.title)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if let summary = model.focusSummary {
            let info = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
        }
        let off = ClosureMenuItem(title: "Off") { [weak model] in model?.endFocus() }
        off.state = level == .off ? .on : .off
        sub.addItem(off)
        sub.addItem(.separator())
        for choice in FocusLevel.choices {
            let row = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            row.state = choice == level ? .on : .off
            let durations = NSMenu()
            durations.autoenablesItems = false
            for duration in FocusDuration.allCases {
                durations.addItem(ClosureMenuItem(title: duration.title) { [weak model] in
                    model?.setFocus(choice, for: duration)
                })
            }
            row.submenu = durations
            sub.addItem(row)
        }
        root.submenu = sub
        return root
    }
}
