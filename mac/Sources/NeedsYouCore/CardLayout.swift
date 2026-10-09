import CoreGraphics
import Foundation

// Rules behind the smaller look-and-feel settings: card bodies, the links row, panel
// opacity and how many cards show before the list scrolls. Pure, so they're unit-tested;
// the views only read the answers. Every default is the original behaviour.

/// Settings → Appearance → Panel and cards → Card text: show bodies in full (the original), the first few lines,
/// or not at all until the card's "Show details" is clicked.
public enum CardBodyMode: String, CaseIterable, Codable, Sendable {
    case full, preview, hidden

    public var title: String {
        switch self {
        case .full: return "Full"
        case .preview: return "First lines"
        case .hidden: return "Title only"
        }
    }
}

public enum CardBodyPolicy {
    /// Lines shown in `.preview` mode.
    public static let previewLines = 3
    /// Rough characters per line at the regular size, for deciding whether a body is long.
    public static let charsPerLine = 55

    /// Is the body drawn at all?
    public static func showsBody(_ mode: CardBodyMode, expanded: Bool) -> Bool {
        expanded || mode != .hidden
    }

    /// The line limit for the body (nil = no limit).
    public static func lineLimit(_ mode: CardBodyMode, expanded: Bool) -> Int? {
        if expanded { return nil }
        switch mode {
        case .full: return nil
        case .preview: return previewLines
        case .hidden: return 0
        }
    }

    /// Would the body be cut off in preview mode?
    public static func isLong(_ body: String, lines: Int = previewLines, charsPerLine: Int = charsPerLine) -> Bool {
        let rows = body.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, Int((Double(line.count) / Double(max(1, charsPerLine))).rounded(.up)))
        }
        return rows > lines
    }

    /// Does the card get a "Show more" / "Show details" toggle?
    public static func canExpand(body: String?, mode: CardBodyMode) -> Bool {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch mode {
        case .full: return false
        case .preview: return isLong(body)
        case .hidden: return true
        }
    }

    /// The toggle's label.
    public static func toggleTitle(_ mode: CardBodyMode, expanded: Bool) -> String {
        if expanded { return "Show less" }
        return mode == .hidden ? "Show details" : "Show more"
    }
}

/// Which links a card's row shows.
public struct LinkRowPlan: Equatable, Sendable {
    public var shown: [ItemLink]
    /// Links left out (shown as "+N", which expands the card).
    public var overflow: Int
    /// Labels longer than this are shortened (nil = never).
    public var maxLabelLength: Int?
}

public enum LinkRowPolicy {
    /// The original row: up to six links, wrapping.
    public static let maxLinks = 6
    /// Settings → Appearance → Panel and cards → Compact links: at most three short labels on one line.
    public static let compactLinks = 3
    public static let compactLabelLength = 18

    public static func plan(_ links: [ItemLink], compact: Bool, expanded: Bool) -> LinkRowPlan {
        let all = Array(links.prefix(maxLinks))
        guard compact, !expanded else { return LinkRowPlan(shown: all, overflow: 0, maxLabelLength: nil) }
        let shown = Array(all.prefix(compactLinks))
        return LinkRowPlan(shown: shown, overflow: all.count - shown.count, maxLabelLength: compactLabelLength)
    }

    /// The link's label, shortened with an ellipsis. An empty label falls back to the URL's
    /// host (the full URL only when there's no host), so shortening can never hide where the
    /// link really goes behind a look-alike prefix such as `https://github.co…`.
    public static func label(_ link: ItemLink, maxLength: Int?) -> String {
        let text: String
        if let name = actionName(link.url) {
            // The app's own actions are named for where they go, whatever the sender called them
            // (hooks before 0.4.0 labelled the Orca jump "Terminal").
            text = name
        } else if link.label.trimmingCharacters(in: .whitespaces).isEmpty {
            if let host = URL(string: link.url)?.host, !host.isEmpty {
                // Keep the end of the host (the registrable part), not the start.
                if let maxLength, maxLength > 1, host.count > maxLength {
                    return "…" + String(host.suffix(maxLength - 1))
                }
                return host
            }
            text = link.url
        } else {
            text = link.label
        }
        guard let maxLength, maxLength > 1, text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The button name for one of the app's own actions: "Orca", or the terminal app
    /// ("iTerm2", "tmux"). nil for any other link.
    public static func actionName(_ url: String) -> String? {
        switch AppAction.parse(url) {
        case .orca?: return "Orca"
        case .terminal(let jump)?: return jump.app.displayName
        case nil: return nil
        }
    }

    /// Where an allowed link really goes, shown faintly after its label so a label can't
    /// pass for a different site: the host for https ("github.com", without "www."), the
    /// app for other schemes ("slack", "vscode"). nil for the app's own actions (the Orca
    /// and terminal jumps), for links that aren't allowed, and when the label is already exactly
    /// the URL or the host.
    public static func destination(_ link: ItemLink) -> String? {
        guard AppAction.parse(link.url) == nil, let url = LinkPolicy.externalURL(link.url),
              let scheme = url.scheme?.lowercased() else { return nil }
        let where_: String
        if scheme == "https" {
            guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            where_ = host
        } else {
            where_ = scheme
        }
        let label = link.label.trimmingCharacters(in: .whitespaces).lowercased()
        if label.isEmpty || label == link.url.lowercased() || label == where_ { return nil }
        return where_
    }
}

/// Settings → Appearance → Panel and cards → Opacity: how see-through the count pill, preview and open panel are
/// when the pointer isn't over them. Hovering always shows them at full strength.
public enum PanelOpacity {
    public static let choices: [Double] = [1.0, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3]
    public static let standard = 1.0
    /// The collapsed pill with the pointer away (the original 85%).
    public static let pillRestStandard = 0.85
    public static let minimum = 0.3

    /// The closest offered choice (hand-edited or out-of-range values snap to one).
    public static func nearestChoice(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        return choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? standard
    }

    /// The alpha for a shape: `rest` while the pointer is away, `hover` while it's over,
    /// never below `minimum` whatever is stored.
    public static func alpha(rest: Double, hover: Double, hovering: Bool) -> Double {
        let v = hovering ? hover : rest
        guard v.isFinite else { return standard }
        return min(1, max(minimum, v))
    }
}

/// Settings → Appearance → Panel and cards → Opacity → Background: how dark the layer behind the glass is.
public enum PanelBackdrop {
    public static let choices: [Double] = [0, 0.15, 0.3, 0.45, 0.6, 0.75]
    public static let standard = 0.3

    public static func nearestChoice(_ value: Double) -> Double {
        guard value.isFinite else { return standard }
        return choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? standard
    }

    public static func title(_ value: Double) -> String {
        value <= 0 ? "None (plain glass)" : "\(Int((value * 100).rounded()))%"
    }
}

/// Settings → Appearance → Panel and cards → Cards before scrolling: the expanded list's height.
public enum ListHeightPolicy {
    /// 0 = as many as fit (the original: up to the size's maximum height).
    public static let choices = [0, 2, 3, 5, 8]
    /// How much of the next card shows, so it's clear the list scrolls.
    public static let peek: CGFloat = 18

    /// - content: the laid-out list height.
    /// - cardBottoms: each card's bottom edge in the list's coordinates (any order).
    /// - maxCards: the setting (0 = no card limit).
    /// - cap: the most the screen and panel size allow.
    /// - minimum: the smallest list (the empty state).
    public static func height(content: CGFloat, cardBottoms: [CGFloat], maxCards: Int, cap: CGFloat, minimum: CGFloat) -> CGFloat {
        var limit = cap
        let bottoms = cardBottoms.sorted()
        if maxCards > 0, bottoms.count > maxCards {
            limit = min(cap, bottoms[maxCards - 1] + peek)
        }
        return min(max(content, minimum), max(limit, minimum))
    }

    public static func title(_ choice: Int) -> String {
        choice <= 0 ? "As many as fit" : "\(choice)"
    }
}
