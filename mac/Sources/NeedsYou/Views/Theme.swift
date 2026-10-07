import NeedsYouCore
import SwiftUI

enum Theme {
    // PLAN.md "Look": urgent = red 400, normal = amber 300, low = slate 400.
    static let urgent = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
    static let normal = Color(red: 252 / 255, green: 211 / 255, blue: 77 / 255)
    static let low = Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)

    static let hairline = Color.white.opacity(0.08)
    static let cardFill = Color.white.opacity(0.05)
    static let muted = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)

    static func color(_ priority: ItemPriority?) -> Color {
        switch priority {
        case .urgent: return urgent
        case .normal: return normal
        case .low: return low
        case nil: return low
        }
    }

    // Type scales with Settings → Panel → Size (PanelStyle); body text has its own size.
    static func title(_ m: PanelMetrics) -> Font { .system(size: m.titleFont, weight: .semibold) }
    static func body(_ points: CGFloat) -> Font { .system(size: points) }
    static func meta(_ m: PanelMetrics) -> Font { .system(size: m.metaFont) }
    static func mono(_ m: PanelMetrics) -> Font { .system(size: m.metaFont, design: .monospaced) }
}

enum Format {
    /// "now", "5m", "2h", "3d".
    static func age(from date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        default: return "\(Int(s / 86_400))d"
        }
    }

    /// `devbox · orca:redo-fixer · 2h`
    static func meta(_ item: Item, now: Date) -> String {
        ((item.source?.displayParts ?? []) + [age(from: item.createdAt, now: now)]).joined(separator: " · ")
    }
}
