import AppKit
import NeedsYouCore
import SwiftUI

// The pieces the Settings samples draw the panel with, so they look like the real thing:
// a fixed sample desktop that stands for the user's screen (it never changes with the
// theme), and the panel's glass on it, layered the way RootView and PanelController layer
// the real panel (the material, the theme's backdrop and its tint). Settings window only;
// nothing here is focusable or clickable.

/// A sample desktop: a wallpaper and another app's window. Always the same, whatever the
/// theme or macOS's appearance, so a theme change shows only on the panel.
struct DesktopBackdrop: View {
    var body: some View {
        // Overlays, so the desktop takes whatever size it's given and never sizes the stage.
        LinearGradient(colors: [Color(red: 0.13, green: 0.30, blue: 0.58),
                                Color(red: 0.42, green: 0.30, blue: 0.62),
                                Color(red: 0.90, green: 0.56, blue: 0.44)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color(red: 1, green: 0.85, blue: 0.6).opacity(0.35))
                    .frame(width: 260, height: 260)
                    .blur(radius: 50)
                    .offset(x: 260, y: 120)
            }
            .overlay(alignment: .topLeading) {
                SampleAppWindow()
                    .frame(width: 330, height: 210)
                    .offset(x: 22, y: 26)
            }
            .clipped()
            .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

/// Another app's window on the sample desktop: a title bar and some lines of text.
private struct SampleAppWindow: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                    Circle().fill(c).frame(width: 9, height: 9)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(white: 0.93))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array([0.85, 0.62, 0.9, 0.5, 0.75, 0.68, 0.4].enumerated()), id: \.offset) { i, width in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == 0 ? Color(white: 0.35) : Color(white: 0.72))
                        .frame(height: i == 0 ? 9 : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: width, y: 1, anchor: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .background(Color.white)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

/// The panel's glass for a Settings sample: the material PanelController uses (dark HUD,
/// or light for a light theme), Background darkness in the theme's backdrop colour, and
/// the theme's tint, as RootView draws them. Blends with what's behind it in the window.
struct PanelGlass: View {
    let palette: PanelPalette
    /// Settings → Appearance → Panel and cards → Opacity → Background darkness.
    let backdrop: Double
    /// The faint idle pill has no backdrop or tint (RootView).
    var idle = false

    var body: some View {
        ZStack {
            PanelMaterial(isDark: palette.isDark)
            if !idle {
                Color(palette.backdrop).opacity(palette.backdropOpacity(backdrop))
                if palette.tintOpacity > 0 { Color(palette.tint).opacity(palette.tintOpacity) }
            }
        }
    }
}

/// NSVisualEffectView with the floating panel's material and appearance
/// (PanelController.applyPalette), blending with the window's own content.
private struct PanelMaterial: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        update(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { update(view) }

    private func update(_ view: NSVisualEffectView) {
        view.material = isDark ? .hudWindow : .popover
        view.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
    }
}

/// The collapsed pill for `items` (Settings → Appearance → Pill), on the glass with
/// the ring and Bright's tint in the top item's colour and the pill's opacity, as RootView
/// and PanelController draw it.
struct SamplePill: View {
    @ObservedObject var settings: AppSettings
    let items: [Item]
    var newCount = 0

    static func content(_ items: [Item], newCount: Int, settings: AppSettings) -> PillContent {
        let input = PillInput(context: .work, items: items, newCount: newCount, needsLabel: settings.needsLabel)
        return PillContent.make(input, options: settings.ui.pillOptions, hovering: false)
    }

    var body: some View {
        let pm = settings.ui.pillMetrics
        let content = Self.content(items, newCount: newCount, settings: settings)
        let size = PillLayout.size(content, metrics: pm)
        let shape = RoundedRectangle(cornerRadius: content.isDot ? pm.height / 2 : pm.cornerRadius, style: .continuous)
        let top = items.map(\.priority).min()
        let look = settings.ui.alertLook(for: top ?? .low)
        PillContentView(content: content, metrics: pm)
            .frame(width: size.width, height: size.height)
            .background(look.fillOpacity > 0 && top != nil ? Theme.color(top).opacity(look.fillOpacity) : Color.clear)
            .background(PanelGlass(palette: Theme.palette, backdrop: settings.ui.backdrop))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.color(top).opacity(look.ringOpacity), lineWidth: look.ringWidth))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .opacity(settings.ui.pillOpacity)
    }
}
