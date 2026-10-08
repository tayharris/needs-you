import AppKit
import NeedsYouCore
import SwiftUI

/// Settings → Appearance: the theme (PanelTheme) and an accent colour, with a live sample.
/// Lives in the Settings window only; the panel never takes focus.
struct AppearanceSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(PanelTheme.allCases, id: \.self) { theme in
                    ThemeSwatch(theme: theme, selected: settings.ui.theme == theme) {
                        settings.ui.theme = theme
                    }
                }
            }
            .padding(.vertical, 4)
            Text(settings.ui.theme.detail)
                .font(.caption).foregroundStyle(.secondary)
            ThemeSample(model: model, settings: settings)
        } header: {
            Text("Theme")
        } footer: {
            Text("Urgent stays red and easy to read in every theme. Match system and High contrast switch between dark and light with macOS. Default is the original look.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker(selection: accentChoice) {
                Text("Theme's own").tag("")
                ForEach(ThemeAccent.Preset.allCases, id: \.self) { preset in
                    Label {
                        Text(preset.title)
                    } icon: {
                        Image(nsImage: Self.dot(NSColor(preset.color)))
                    }
                    .tag(preset.rawValue)
                }
                Text("Custom").tag("custom")
            } label: {
                LabelWithDetail("Accent colour", "Ticked steps, links in card text and small badges. Priority colours don't change.")
            }
            if case .custom = settings.ui.accent {
                ColorPicker(selection: customColor, supportsOpacity: false) {
                    LabelWithDetail("Custom colour", "Made lighter or darker if it wouldn't read on the panel.")
                }
            }
        } header: {
            Text("Accent")
        }
    }

    /// The accent picker's tag: "" (theme), a preset name, or "custom".
    private var accentChoice: Binding<String> {
        Binding(
            get: {
                switch settings.ui.accent {
                case .theme: return ""
                case .preset(let p): return p.rawValue
                case .custom: return "custom"
                }
            },
            set: { tag in
                if tag == "custom" {
                    if case .custom = settings.ui.accent { return }
                    settings.ui.accent = .custom(Theme.palette.accent)
                } else {
                    settings.ui.accent = ThemeAccent(stored: tag)
                }
            }
        )
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(settings.ui.accent.color ?? Theme.palette.accent) },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.ui.accent = .custom(ThemeRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
            }
        )
    }

    static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}

/// One theme in the grid: its surface with a line of text and the three priority dots.
private struct ThemeSwatch: View {
    let theme: PanelTheme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        // Themes that follow macOS show the palette for its current appearance.
        let p = theme.palette(systemIsDark: Theme.systemIsDark)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aa")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(p.text))
                    HStack(spacing: 4) {
                        ForEach([ItemPriority.urgent, .normal, .low], id: \.self) { priority in
                            Circle().fill(Color(p.color(priority))).frame(width: 8, height: 8)
                        }
                        Spacer(minLength: 0)
                        Capsule().fill(Color(p.accent)).frame(width: 14, height: 5)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .background(Color(p.tint).opacity(p.tintOpacity))
                .background(Color(p.surface))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5)
                )
                Text(theme.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The theme on the panel's own views: a count pill per priority and a sample card.
private struct ThemeSample: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let m = settings.ui.metrics
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach([ItemPriority.urgent, .normal, .low], id: \.self) { priority in
                    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                    let look = settings.ui.alertLook(for: priority)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.color(priority)).frame(width: 6, height: 6)
                        Text(priority.rawValue)
                            .font(.system(size: m.countFont - 1, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.text.opacity(0.95))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: m.countHeight)
                    .background(Theme.tint)
                    .background(Theme.raised)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.color(priority).opacity(look.ringOpacity), lineWidth: look.ringWidth))
                }
                Spacer(minLength: 0)
            }
            CardView(item: PanelPreview.sample(now: model.now), model: model)
                .frame(width: m.expandedWidth - 2 * m.listPadding)
                .padding(m.listPadding)
                .background(Theme.tint)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .id(Theme.palette)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .environment(\.colorScheme, Theme.colorScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
