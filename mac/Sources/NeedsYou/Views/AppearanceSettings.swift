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

/// The theme on the panel's own views, over a sample desktop that stands for your screen
/// and stays the same for every theme: the collapsed pill with a top item of each
/// priority, and the open panel with a card, on the panel's glass as the app draws them.
private struct ThemeSample: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let m = settings.ui.metrics
        VStack(alignment: .trailing, spacing: 12) {
            HStack(spacing: 14) {
                ForEach([ItemPriority.urgent, .normal, .low], id: \.self) { priority in
                    SamplePill(settings: settings, items: [Self.item(priority)])
                }
            }
            panel(m)
        }
        .id(Theme.palette)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(DesktopBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, Theme.colorScheme)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func item(_ priority: ItemPriority) -> Item {
        Item(id: "theme-sample-\(priority.rawValue)", key: "theme-sample-\(priority.rawValue)",
             priority: priority, title: "Sample", createdAt: Date())
    }

    /// The open panel: its header, a card and the footer (ExpandedView's layout).
    private func panel(_ m: PanelMetrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(settings.needsLabel)
                    .font(.system(size: m.headerFont, weight: .semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 3) {
                    Text("Work").foregroundStyle(Theme.text)
                    Text("1").foregroundStyle(Theme.normal)
                }
                .font(.system(size: m.headerFont - 1, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.cardFill))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: m.headerHeight - 0.5)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            CardView(item: PanelPreview.sample(now: model.now), model: model)
                .frame(width: m.expandedWidth - 2 * m.listPadding)
                .padding(m.listPadding)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack {
                Text(LocalHub.displayName).font(Theme.meta(m)).foregroundStyle(Theme.faint)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: m.footerHeight - 0.5)
        }
        .frame(width: m.expandedWidth)
        .background(PanelGlass(palette: Theme.palette, backdrop: settings.ui.backdrop))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        .opacity(settings.ui.panelOpacity)
    }
}
