import AppKit
import NeedsYouCore
import SwiftUI

extension Color {
    init(_ rgb: ThemeRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}

extension NSColor {
    convenience init(_ rgb: ThemeRGB) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

enum Theme {
    /// The panel's colours (Settings → Appearance; PanelTheme in NeedsYouCore). AppModel
    /// sets it when the theme, the accent or macOS's appearance changes, and RootView
    /// redraws everything then. The default palette is the original look: urgent = red
    /// 400, normal = amber 300, low = slate 400, white text on dark glass.
    nonisolated(unsafe) static var palette = PanelTheme.standardPalette

    /// macOS is in dark mode (for the themes that follow it). AppModel keeps it current.
    nonisolated(unsafe) static var systemIsDark = true

    static var urgent: Color { Color(palette.urgent) }
    static var normal: Color { Color(palette.normal) }
    static var low: Color { Color(palette.low) }
    /// Ticked steps, links in card text, the DEMO badge (Settings → Appearance → Accent).
    static var accent: Color { Color(palette.accent) }
    /// Primary text; the rest is this at an opacity.
    static var text: Color { Color(palette.text) }

    static var hairline: Color { text.opacity(palette.hairlineOpacity) }
    static var cardFill: Color { text.opacity(palette.cardFillOpacity) }
    static var muted: Color { text.opacity(palette.mutedOpacity) }
    static var faint: Color { text.opacity(palette.faintOpacity) }

    /// The layer behind the glass and the theme's wash over it.
    static var backdrop: Color { Color(palette.backdrop) }
    static var tint: Color { Color(palette.tint).opacity(palette.tintOpacity) }
    /// The Settings samples' backgrounds (what the panel looks like behind its text).
    static var surface: Color { Color(palette.surface) }
    static var raised: Color { Color(palette.raised) }
    static var colorScheme: ColorScheme { palette.isDark ? .dark : .light }

    // Card link buttons (LinkChip): a clearly lighter capsule than the card, text-coloured
    // label, and on hover a stronger fill and outline. White on these fills over the dark
    // material stays well above 7:1 (and dark on light the same way).
    static var linkFill: Color { text.opacity(0.14) }
    static var linkFillHover: Color { text.opacity(0.24) }
    static var linkStroke: Color { text.opacity(0.18) }
    static var linkStrokeHover: Color { text.opacity(0.5) }
    static var linkText: Color { text }
    /// The faint "where it really goes" after a link's label.
    static var linkDestination: Color { text.opacity(0.62) }

    static func color(_ priority: ItemPriority?) -> Color {
        Color(palette.color(priority))
    }

    // Type scales with Settings → Panel → Size (PanelStyle); body text has its own size.
    static func title(_ m: PanelMetrics) -> Font { .system(size: m.titleFont, weight: .semibold) }
    static func body(_ points: CGFloat) -> Font { .system(size: points) }
    static func meta(_ m: PanelMetrics) -> Font { .system(size: m.metaFont) }
    static func mono(_ m: PanelMetrics) -> Font { .system(size: m.metaFont, design: .monospaced) }
}

/// The soft glow outside a shape's edge during an arrival pulse (`glow` 0...1 is the
/// pulse's progress; Settings → Alerts sets the look). Shared by the panel and the
/// Settings preview.
struct GlowEdge<S: Shape>: View {
    let shape: S
    let color: Color
    let glow: Double
    let look: AlertLook

    var body: some View {
        let strength = glow * look.glowPeak
        shape
            .stroke(color.opacity(strength * 0.9), lineWidth: look.strokeWidth)
            .shadow(color: color.opacity(strength), radius: look.glowRadius)
            .shadow(color: color.opacity(strength * 0.6), radius: look.glowRadius * 0.43)
    }
}

/// Runs an alert look's pulses by animating `set(1)` / `set(0)`.
@MainActor
enum PulseRunner {
    static func run(_ look: AlertLook, set: @escaping (Double) -> Void) async {
        for _ in 0..<look.pulses {
            withAnimation(.easeOut(duration: look.riseSeconds)) { set(1) }
            try? await Task.sleep(nanoseconds: UInt64(look.holdSeconds * 1_000_000_000))
            withAnimation(.easeIn(duration: look.fallSeconds)) { set(0) }
            try? await Task.sleep(nanoseconds: UInt64(look.gapSeconds * 1_000_000_000))
        }
    }
}

enum Format {
    /// "now", "5m", "2h", "3d".
    static func age(from date: Date, now: Date) -> String {
        CardAge.short(now.timeIntervalSince(date))
    }

    /// `devbox · orca:redo-fixer · 2h`. Without the age when the card shows an age badge.
    static func meta(_ item: Item, now: Date, includeAge: Bool = true) -> String {
        ((item.source?.displayParts ?? []) + (includeAge ? [age(from: item.createdAt, now: now)] : [])).joined(separator: " · ")
    }
}
