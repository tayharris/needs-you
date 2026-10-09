import Foundation

// Settings → Appearance → Theme: the floating panel's colours. Pure values, so every theme's
// contrast can be checked numerically (PanelThemeTests): text and urgent stay legible and
// urgent stays distinct from normal and low in every theme and appearance. `.standard` is
// the original look exactly (the colours that used to be constants in the app's Theme).

/// An sRGB colour, 0...1 per channel.
public struct ThemeRGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0xRRGGBB.
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// "#RRGGBB" or "RRGGBB"; nil for anything else.
    public init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let value = UInt32(s, radix: 16) else { return nil }
        self.init(hex: value)
    }

    public static let white = ThemeRGB(1, 1, 1)
    public static let black = ThemeRGB(0, 0, 0)

    /// "#RRGGBB" (upper case).
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: ThemeRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour at `alpha` over `background`.
    public func over(_ background: ThemeRGB, alpha: Double) -> ThemeRGB {
        let a = min(1, max(0, alpha))
        return ThemeRGB(red * a + background.red * (1 - a),
                        green * a + background.green * (1 - a),
                        blue * a + background.blue * (1 - a))
    }

    /// Straight-line distance in RGB, 0...√3: how different two colours look, roughly.
    public func distance(to other: ThemeRGB) -> Double {
        let dr = red - other.red, dg = green - other.green, db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Hue in degrees, 0..<360 (0 for greys).
    public var hue: Double {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        let d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double
        if mx == red { h = ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == green { h = (blue - red) / d + 2 }
        else { h = (red - green) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }
}

/// Whether a palette is drawn on dark or light glass.
public enum ThemeAppearance: String, Sendable {
    case dark, light
}

/// Everything the floating panel colours: priorities, accent, text and the glass.
public struct PanelPalette: Hashable, Sendable {
    public var appearance: ThemeAppearance
    public var urgent: ThemeRGB
    public var normal: ThemeRGB
    public var low: ThemeRGB
    /// Non-priority highlights: ticked steps, links in card text, the DEMO badge, the
    /// "set by a link" focus badge.
    public var accent: ThemeRGB
    /// Primary text. Secondary text, hairlines and fills are this colour at an opacity.
    public var text: ThemeRGB
    public var mutedOpacity: Double
    public var faintOpacity: Double
    public var hairlineOpacity: Double
    public var cardFillOpacity: Double
    /// The layer behind the glass (Settings → Appearance → Panel and cards → Opacity → Background darkness):
    /// black on dark themes, white on light ones.
    public var backdrop: ThemeRGB
    /// The least backdrop this theme draws, whatever the setting (high contrast).
    public var backdropFloor: Double
    /// A colour wash over the glass (the colourful themes); 0 = none.
    public var tint: ThemeRGB
    public var tintOpacity: Double
    /// What the panel looks like behind its text, for contrast checks and the Settings
    /// samples. (The real glass varies with what's under it; the backdrop keeps it close.)
    public var surface: ThemeRGB
    /// A raised surface (the Settings sample pills).
    public var raised: ThemeRGB

    public var isDark: Bool { appearance == .dark }

    public func color(_ priority: ItemPriority?) -> ThemeRGB {
        switch priority {
        case .urgent: return urgent
        case .normal: return normal
        case .low, nil: return low
        }
    }

    /// Muted and faint text as drawn over the surface.
    public var mutedOnSurface: ThemeRGB { text.over(surface, alpha: mutedOpacity) }
    public var faintOnSurface: ThemeRGB { text.over(surface, alpha: faintOpacity) }

    /// The backdrop opacity actually drawn for the user's setting.
    public func backdropOpacity(_ chosen: Double) -> Double { max(chosen, backdropFloor) }

    /// The same palette with another accent, nudged toward the text colour until it reads
    /// on the surface (at least `ThemeAccent.minimumContrast`). Priorities never change.
    public func withAccent(_ color: ThemeRGB) -> PanelPalette {
        var p = self
        var c = color
        var step = 0
        while c.contrast(with: surface) < ThemeAccent.minimumContrast && step < 20 {
            c = text.over(c, alpha: 0.1)
            step += 1
        }
        p.accent = c
        return p
    }
}

/// Settings → Appearance → Theme. Stored as the raw value under `theme`; unknown → standard.
public enum PanelTheme: String, CaseIterable, Codable, Sendable {
    /// The original dark glass.
    case standard = "default"
    /// Default when macOS is dark, Paper when it's light.
    case system
    case graphite, midnight, paper
    /// Dark or light to match macOS; maximum contrast.
    case highContrast
    case ocean, sunset

    public var title: String {
        switch self {
        case .standard: return "Default"
        case .system: return "Match system"
        case .graphite: return "Graphite"
        case .midnight: return "Midnight"
        case .paper: return "Paper"
        case .highContrast: return "High contrast"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        }
    }

    public var detail: String {
        switch self {
        case .standard: return "Dark glass, the original look."
        case .system: return "Default when macOS is dark, Paper when it's light."
        case .graphite: return "Neutral greys, softer colours."
        case .midnight: return "Deep blue glass."
        case .paper: return "Light glass with dark text."
        case .highContrast: return "Strongest text and colours; dark or light to match macOS."
        case .ocean: return "Teal glass."
        case .sunset: return "Plum glass with warm colours."
        }
    }

    /// Whether this theme follows macOS's light or dark appearance.
    public var followsSystem: Bool { self == .system || self == .highContrast }

    /// The palette for this theme. `systemIsDark` matters only for themes that follow macOS.
    public func palette(systemIsDark: Bool = true) -> PanelPalette {
        switch self {
        case .standard: return Self.standardPalette
        case .system: return systemIsDark ? Self.standardPalette : Self.paperPalette
        case .graphite: return Self.graphitePalette
        case .midnight: return Self.midnightPalette
        case .paper: return Self.paperPalette
        case .highContrast: return systemIsDark ? Self.highContrastDark : Self.highContrastLight
        case .ocean: return Self.oceanPalette
        case .sunset: return Self.sunsetPalette
        }
    }

    /// The palette with the accent override (nil: the theme's own accent).
    public func palette(systemIsDark: Bool = true, accent: ThemeAccent) -> PanelPalette {
        let base = palette(systemIsDark: systemIsDark)
        guard let color = accent.color else { return base }
        return base.withAccent(color)
    }

    // The original look: red 400, amber 300, slate 400 on dark glass with white text.
    public static let standardPalette = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xF87171), normal: ThemeRGB(hex: 0xFCD34D), low: ThemeRGB(hex: 0x94A3B8),
        accent: ThemeRGB(hex: 0xFCD34D), text: .white,
        mutedOpacity: 0.55, faintOpacity: 0.35, hairlineOpacity: 0.08, cardFillOpacity: 0.05,
        backdrop: .black, backdropFloor: 0, tint: .black, tintOpacity: 0,
        surface: ThemeRGB(0.11, 0.11, 0.11), raised: ThemeRGB(0.18, 0.18, 0.18)
    )

    static let graphitePalette = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xF87171), normal: ThemeRGB(hex: 0xE4C77B), low: ThemeRGB(hex: 0xA1A1AA),
        accent: ThemeRGB(hex: 0xD4D4D8), text: ThemeRGB(hex: 0xF4F4F5),
        mutedOpacity: 0.6, faintOpacity: 0.4, hairlineOpacity: 0.1, cardFillOpacity: 0.06,
        backdrop: .black, backdropFloor: 0, tint: ThemeRGB(hex: 0x3F3F46), tintOpacity: 0.35,
        surface: ThemeRGB(hex: 0x232326), raised: ThemeRGB(hex: 0x323236)
    )

    static let midnightPalette = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xFB7185), normal: ThemeRGB(hex: 0xFCD34D), low: ThemeRGB(hex: 0x94A3B8),
        accent: ThemeRGB(hex: 0x60A5FA), text: ThemeRGB(hex: 0xF8FAFC),
        mutedOpacity: 0.6, faintOpacity: 0.4, hairlineOpacity: 0.1, cardFillOpacity: 0.06,
        backdrop: .black, backdropFloor: 0, tint: ThemeRGB(hex: 0x1E3A8A), tintOpacity: 0.45,
        surface: ThemeRGB(hex: 0x0F172A), raised: ThemeRGB(hex: 0x1E293B)
    )

    static let paperPalette = PanelPalette(
        appearance: .light,
        urgent: ThemeRGB(hex: 0xB91C1C), normal: ThemeRGB(hex: 0xA16207), low: ThemeRGB(hex: 0x475569),
        accent: ThemeRGB(hex: 0x2563EB), text: ThemeRGB(hex: 0x1C1917),
        mutedOpacity: 0.7, faintOpacity: 0.55, hairlineOpacity: 0.12, cardFillOpacity: 0.04,
        backdrop: .white, backdropFloor: 0, tint: ThemeRGB(hex: 0xFAFAF9), tintOpacity: 0.35,
        surface: ThemeRGB(hex: 0xF5F5F4), raised: ThemeRGB(hex: 0xE7E5E4)
    )

    static let highContrastDark = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xFF7A7A), normal: ThemeRGB(hex: 0xFFE066), low: ThemeRGB(hex: 0xCBD5E1),
        accent: ThemeRGB(hex: 0x7DD3FC), text: .white,
        mutedOpacity: 0.82, faintOpacity: 0.66, hairlineOpacity: 0.35, cardFillOpacity: 0.1,
        backdrop: .black, backdropFloor: 0.6, tint: .black, tintOpacity: 0,
        surface: ThemeRGB(hex: 0x0A0A0A), raised: ThemeRGB(hex: 0x262626)
    )

    static let highContrastLight = PanelPalette(
        appearance: .light,
        urgent: ThemeRGB(hex: 0xA50E0E), normal: ThemeRGB(hex: 0x7A4A00), low: ThemeRGB(hex: 0x334155),
        accent: ThemeRGB(hex: 0x1D4ED8), text: .black,
        mutedOpacity: 0.8, faintOpacity: 0.66, hairlineOpacity: 0.4, cardFillOpacity: 0.06,
        backdrop: .white, backdropFloor: 0.6, tint: .white, tintOpacity: 0,
        surface: .white, raised: ThemeRGB(hex: 0xE5E5E5)
    )

    static let oceanPalette = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xFB7185), normal: ThemeRGB(hex: 0xFDE047), low: ThemeRGB(hex: 0x67E8F9),
        accent: ThemeRGB(hex: 0x2DD4BF), text: ThemeRGB(hex: 0xF0FDFA),
        mutedOpacity: 0.62, faintOpacity: 0.42, hairlineOpacity: 0.12, cardFillOpacity: 0.06,
        backdrop: .black, backdropFloor: 0, tint: ThemeRGB(hex: 0x0E7490), tintOpacity: 0.4,
        surface: ThemeRGB(hex: 0x0B2530), raised: ThemeRGB(hex: 0x123844)
    )

    static let sunsetPalette = PanelPalette(
        appearance: .dark,
        urgent: ThemeRGB(hex: 0xF87171), normal: ThemeRGB(hex: 0xFDBA74), low: ThemeRGB(hex: 0xC4B5FD),
        accent: ThemeRGB(hex: 0xF0ABFC), text: ThemeRGB(hex: 0xFFF7ED),
        mutedOpacity: 0.62, faintOpacity: 0.42, hairlineOpacity: 0.12, cardFillOpacity: 0.06,
        backdrop: .black, backdropFloor: 0, tint: ThemeRGB(hex: 0x581C87), tintOpacity: 0.45,
        surface: ThemeRGB(hex: 0x1F1030), raised: ThemeRGB(hex: 0x2E1A45)
    )
}

/// Settings → Appearance → Theme → Accent colour: the theme's own, a preset, or any colour.
/// Stored under `themeAccent` as "" (the theme's), a preset name, or "#RRGGBB"; anything
/// else falls back to the theme's.
public enum ThemeAccent: Hashable, Sendable {
    case theme
    case preset(Preset)
    case custom(ThemeRGB)

    /// Accents are nudged until they reach this contrast on the panel.
    public static let minimumContrast = 3.0

    public enum Preset: String, CaseIterable, Sendable {
        case blue, purple, pink, orange, green, teal, graphite

        public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public var color: ThemeRGB {
            switch self {
            case .blue: return ThemeRGB(hex: 0x3B82F6)
            case .purple: return ThemeRGB(hex: 0xA855F7)
            case .pink: return ThemeRGB(hex: 0xEC4899)
            case .orange: return ThemeRGB(hex: 0xF97316)
            case .green: return ThemeRGB(hex: 0x22C55E)
            case .teal: return ThemeRGB(hex: 0x14B8A6)
            case .graphite: return ThemeRGB(hex: 0x8E8E93)
            }
        }
    }

    public init(stored: String?) {
        let raw = (stored ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw == "theme" { self = .theme }
        else if let preset = Preset(rawValue: raw.lowercased()) { self = .preset(preset) }
        else if let rgb = ThemeRGB(hexString: raw), raw.hasPrefix("#") { self = .custom(rgb) }
        else { self = .theme }
    }

    public var storageString: String {
        switch self {
        case .theme: return ""
        case .preset(let p): return p.rawValue
        case .custom(let rgb): return rgb.hexString
        }
    }

    public var color: ThemeRGB? {
        switch self {
        case .theme: return nil
        case .preset(let p): return p.color
        case .custom(let rgb): return rgb
        }
    }

    public var title: String {
        switch self {
        case .theme: return "Theme's own"
        case .preset(let p): return p.title
        case .custom: return "Custom"
        }
    }
}
