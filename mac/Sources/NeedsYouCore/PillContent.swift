import CoreGraphics
import Foundation

// What the collapsed ("waiting") pill shows and how wide it is. Pure data, so every
// combination of Settings → Appearance → Pill can be unit-tested; CountPill draws the
// segments and PanelController sizes the panel from `units` (plus the measured title).
// The defaults (medium, count only, no split) are the original "3 · 1 +2" pill, and
// PillContentTests pins that.

/// How big the collapsed pill is, on top of the panel size (Settings → Appearance → Panel and cards → Size).
public enum PillSize: String, CaseIterable, Codable, Sendable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Scale applied to the panel size's count-pill numbers. Medium is the original look.
    public var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.35
        }
    }
}

/// How much the collapsed pill says.
public enum PillDetail: String, CaseIterable, Codable, Sendable {
    /// The count (the original look).
    case count
    /// The count and the top card's title, truncated.
    case topItem
    /// Just a dot in the highest priority's colour; hovering shows the count.
    case dot

    public var title: String {
        switch self {
        case .count: return "Count only"
        case .topItem: return "Count and top item"
        case .dot: return "Minimal dot"
        }
    }
}

/// How the collapsed pill splits its count.
public enum PillSplit: String, CaseIterable, Codable, Sendable {
    /// One count for the current context, the other context faint ("3 · 1").
    case none
    /// Work and personal side by side ("W 3 | P 1"), the current one brighter.
    case context
    /// Urgent, normal and low counts in their colours; empty ones hidden.
    case priority

    public var title: String {
        switch self {
        case .none: return "None"
        case .context: return "Work | Personal"
        case .priority: return "By priority"
        }
    }
}

/// The collapsed pill's sizes, in points: the panel size's count-pill numbers scaled by
/// the pill size. `.medium` is exactly the panel size's numbers.
public struct PillMetrics: Equatable, Sendable {
    public var font: CGFloat
    /// The W/P labels and the "new" badge.
    public var smallFont: CGFloat
    /// The top item's title.
    public var titleFont: CGFloat
    public var height: CGFloat
    public var minWidth: CGFloat
    public var baseWidth: CGFloat
    public var digitWidth: CGFloat
    public var cornerRadius: CGFloat
    /// The coloured dot in "Minimal dot".
    public var dotSize: CGFloat
    /// Room between the counts and the title.
    public var titleGap: CGFloat
    /// The pill never grows wider than this (a long title is truncated).
    public var maxWidth: CGFloat

    /// The original count pill's corner radius (RootView, PanelController).
    public static let baseCornerRadius: CGFloat = 11

    public static func make(_ m: PanelMetrics, size: PillSize) -> PillMetrics {
        let s = size.scale
        func r(_ v: CGFloat) -> CGFloat { size == .medium ? v : (v * s * 2).rounded() / 2 }
        let height = r(m.countHeight)
        return PillMetrics(
            font: r(m.countFont),
            smallFont: r(m.countFont - 2),
            titleFont: r(m.countFont - 1),
            height: height,
            minWidth: r(m.countMinWidth),
            baseWidth: r(m.countBaseWidth),
            digitWidth: r(m.countDigitWidth),
            cornerRadius: size == .medium ? baseCornerRadius : min(r(baseCornerRadius), height / 2),
            dotSize: r(8),
            titleGap: r(6),
            maxWidth: r(m.idleMaxWidth)
        )
    }

    /// The pill's width for `units` digit-widths of counts, plus a title `titleWidth`
    /// points wide (measured by the app), capped at `maxWidth`. With no title this is
    /// `PanelMetrics.countWidth(digits:)`, the original formula.
    public func width(units: Int, titleWidth: CGFloat? = nil) -> CGFloat {
        var w = baseWidth + CGFloat(max(0, units)) * digitWidth
        if let titleWidth, titleWidth > 0 { w += titleGap + ceil(titleWidth) }
        return min(maxWidth, max(minWidth, w))
    }

    /// The dot pill is a circle.
    public var dotWidth: CGFloat { height }
}

/// One piece of the pill's text.
public struct PillSegment: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// The current context's count; `dim` when it's 0 (only Later or the other side).
        case count(dim: Bool)
        /// The other context, faint ("· 1").
        case other
        /// Held under Later, fainter ("+2").
        case later
        /// One side of the work | personal split; `current` is drawn brighter.
        case context(ItemContext, current: Bool)
        /// The "|" between the two sides.
        case divider
        /// One priority's count, in its colour.
        case priority(ItemPriority)
        /// "2 new": arrived since the panel was last open.
        case new
    }

    public var text: String
    /// "W" / "P" before a context count (drawn smaller); nil otherwise.
    public var label: String?
    public var style: Style
    /// Digit-widths this segment takes (with its gap), for the pill's width.
    public var units: Int

    public init(_ text: String, label: String? = nil, style: Style, units: Int) {
        self.text = text
        self.label = label
        self.style = style
        self.units = units
    }
}

/// The collapsed pill's settings (UIPrefs keys pillSize, pillDetail, pillSplit, pillShowNew).
public struct PillOptions: Equatable, Sendable {
    public var size: PillSize = .medium
    public var detail: PillDetail = .count
    public var split: PillSplit = .none
    /// Show how many arrived since the panel was last open. Default on.
    public var showNew = true

    public init(size: PillSize = .medium, detail: PillDetail = .count, split: PillSplit = .none, showNew: Bool = true) {
        self.size = size
        self.detail = detail
        self.split = split
        self.showNew = showNew
    }

    public static let defaults = PillOptions()
}

/// What the pill knows about: the current context's counted `needs` items (in the card
/// order, urgent first), the other context's count, Later, "new" and focus.
public struct PillInput: Equatable, Sendable {
    public var context: ItemContext
    public var items: [Item]
    public var otherCount: Int
    public var laterCount: Int
    public var newCount: Int
    public var focused: Bool
    public var focusSetByLink: Bool
    /// "needs you" / "needs Sam", for the tooltip.
    public var needsLabel: String

    public init(context: ItemContext, items: [Item], otherCount: Int = 0, laterCount: Int = 0, newCount: Int = 0,
                focused: Bool = false, focusSetByLink: Bool = false, needsLabel: String = "needs you") {
        self.context = context
        self.items = items
        self.otherCount = otherCount
        self.laterCount = laterCount
        self.newCount = newCount
        self.focused = focused
        self.focusSetByLink = focusSetByLink
        self.needsLabel = needsLabel
    }

    public var count: Int { items.count }
}

public struct PillContent: Equatable, Sendable {
    /// Drawn left to right after the focus moon (and link badge).
    public var segments: [PillSegment]
    /// The top card's title, already truncated ("Count and top item"); nil otherwise.
    public var title: String?
    /// "Minimal dot" at rest: draw only the dot.
    public var isDot: Bool
    /// The dot's colour (the highest priority here); nil = faint (only Later or the other side).
    public var dotPriority: ItemPriority?
    /// Digit-widths of everything except the title, focus moon and link badge included.
    public var units: Int
    /// The tooltip, without the focus and status line the app adds.
    public var help: String

    /// Longest top-item title on the pill, in characters (the tooltip has more).
    public static let titleLimit = 32
    /// Longest title in the tooltip.
    public static let helpTitleLimit = 80

    public static func make(_ input: PillInput, options: PillOptions, hovering: Bool) -> PillContent {
        let help = helpText(input, options: options)
        let focusUnits = (input.focused ? 2 : 0) + (input.focusSetByLink ? 2 : 0)
        let top = input.items.first
        if options.detail == .dot && !hovering {
            return PillContent(segments: [], title: nil, isDot: true, dotPriority: input.items.map(\.priority).min(),
                               units: 0, help: help)
        }

        var segments: [PillSegment] = []
        switch options.split {
        case .none:
            segments.append(countSegment(input.count))
        case .context:
            // Always work first, so the sides don't swap when the context changes.
            for side in [ItemContext.work, .personal] {
                let n = side == input.context ? input.count : input.otherCount
                if side == .personal { segments.append(PillSegment("|", style: .divider, units: 1)) }
                segments.append(PillSegment("\(n)", label: side == .work ? "W" : "P",
                                            style: .context(side, current: side == input.context),
                                            units: digits(n) + 2))
            }
        case .priority:
            for priority in ItemPriority.allCases {
                let n = input.items.filter { $0.priority == priority }.count
                if n > 0 { segments.append(PillSegment("\(n)", style: .priority(priority), units: digits(n) + 1)) }
            }
            if segments.isEmpty { segments.append(countSegment(0)) }
        }
        if options.showNew, input.newCount > 0 {
            segments.append(PillSegment("\(input.newCount) new", style: .new, units: digits(input.newCount) + 4))
        }
        if options.split != .context, input.otherCount > 0 {
            // Out-of-context items: a faint second number ("3 · 1").
            segments.append(PillSegment("· \(input.otherCount)", style: .other, units: digits(input.otherCount) + 2))
        }
        if input.laterCount > 0 {
            segments.append(PillSegment("+\(input.laterCount)", style: .later, units: digits(input.laterCount) + 1))
        }

        let title = options.detail == .topItem ? top.map { truncate($0.title, limit: titleLimit) } : nil
        let units = segments.reduce(focusUnits) { $0 + $1.units }
        return PillContent(segments: segments, title: title?.isEmpty == true ? nil : title, isDot: false,
                           dotPriority: input.items.map(\.priority).min(), units: units, help: help)
    }

    /// The main count: as many units as digits, so the default pill keeps its width.
    private static func countSegment(_ n: Int) -> PillSegment {
        PillSegment("\(n)", style: .count(dim: n == 0), units: digits(n))
    }

    static func digits(_ n: Int) -> Int { String(n).count }

    /// One line, at most `limit` characters, "…" when cut.
    public static func truncate(_ text: String, limit: Int) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard line.count > limit, limit > 1 else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "needs you: 3 work items (1 urgent, 2 normal), 2 new since you last opened it,
    /// 1 personal, 2 under Later · Top: Approve the deploy".
    public static func helpText(_ input: PillInput, options: PillOptions) -> String {
        let n = input.count
        var text = "\(input.needsLabel): \(n) \(input.context.rawValue) item\(n == 1 ? "" : "s")"
        if n > 0 && (options.split == .priority || options.detail == .dot) {
            let parts = ItemPriority.allCases.compactMap { p -> String? in
                let c = input.items.filter { $0.priority == p }.count
                return c > 0 ? "\(c) \(p.rawValue)" : nil
            }
            text += " (\(parts.joined(separator: ", ")))"
        }
        if options.showNew, input.newCount > 0 {
            text += ", \(input.newCount) new since you last opened it"
        }
        if input.otherCount > 0 {
            text += ", \(input.otherCount) \(input.context.other.rawValue)"
        }
        if input.laterCount > 0 {
            text += ", \(input.laterCount) under Later"
        }
        if options.detail == .topItem, let top = input.items.first {
            text += " · Top: \(truncate(top.title, limit: helpTitleLimit))"
        }
        return text
    }
}
