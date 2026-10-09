import AppKit
import NeedsYouCore
import SwiftUI

/// Settings → Appearance → Theme: the theme (PanelTheme), an accent colour (ThemeAccent) and
/// the background (PanelBackground), with a live sample of the pill and the open panel.
/// Lives in the Settings window only; the panel never takes focus.
struct AppearanceSettingsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 12)]

    var body: some View {
        Section {
            ThemeSample(model: model, settings: settings)
        } header: {
            Text("Preview")
        } footer: {
            Text("Urgent stays red and easy to read in every theme. With macOS's Increase Contrast on, secondary text and borders get stronger.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        } header: {
            Text("Theme")
        } footer: {
            Text("Match system and High contrast switch between dark and light with macOS. Default is the original look.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            AccentRow(settings: settings)
            if case .custom = settings.ui.accent {
                ColorPicker(selection: customColor, supportsOpacity: false) {
                    LabelWithDetail("Custom colour", customDetail)
                }
            }
        } header: {
            Text("Accent colour")
        } footer: {
            Text("Ticked steps, links in card text and small badges. Priority colours never change, and red is kept for urgent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker(selection: $settings.ui.background) {
                ForEach(PanelBackground.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                LabelWithDetail("Behind the pill and panel", settings.ui.background.detail)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Background")
        }
    }

    /// What the custom colour does, and whether it's refused for looking like urgent.
    private var customDetail: String {
        let palette = settings.ui.theme.palette(systemIsDark: Theme.systemIsDark)
        if let color = settings.ui.accent.color, palette.refusesAccent(color) {
            return "Too close to urgent's red, so the theme's own accent is used. Pick another colour."
        }
        return "Made lighter or darker if it wouldn't read on the panel."
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
}

/// The accent swatches: the theme's own, the presets, then Custom, with the chosen one's
/// name. Plain buttons in the Settings window.
private struct AccentRow: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let own = settings.ui.theme.palette(systemIsDark: Theme.systemIsDark).accent
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                swatch(.theme, fill: AnyShapeStyle(Color(own)), help: "The theme's own accent")
                Divider().frame(height: 18)
                ForEach(ThemeAccent.Preset.allCases, id: \.self) { preset in
                    swatch(.preset(preset), fill: AnyShapeStyle(Color(preset.color)), help: preset.title)
                }
                Divider().frame(height: 18)
                swatch(customChoice, fill: AnyShapeStyle(AngularGradient(
                    colors: [.yellow, .green, .teal, .blue, .purple, .pink, .orange, .yellow], center: .center)),
                       help: "Any colour")
                Spacer(minLength: 0)
            }
            Text(settings.ui.accent.title)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Choosing Custom starts from the colour on the panel now.
    private var customChoice: ThemeAccent {
        if case .custom = settings.ui.accent { return settings.ui.accent }
        return .custom(Theme.palette.accent)
    }

    private func isSelected(_ choice: ThemeAccent) -> Bool {
        switch (choice, settings.ui.accent) {
        case (.custom, .custom): return true
        default: return choice == settings.ui.accent
        }
    }

    private func swatch(_ choice: ThemeAccent, fill: AnyShapeStyle, help: String) -> some View {
        let selected = isSelected(choice)
        return Button { settings.ui.accent = choice } label: {
            Circle()
                .fill(fill)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// A card with the accent on it: a ticked step and a link in its text.
    private static func card(now: Date) -> Item {
        Item(id: "theme-sample-card", key: "theme-sample-card", priority: .normal,
             title: "Approve the prod deploy for ACME-4700",
             body: "Canary is green. See the [runbook](https://example.com/runbook).",
             links: [ItemLink(label: "Pull request", url: "https://example.com/pr/4700")],
             steps: [ItemStep(text: "Check the canary dashboard", done: true),
                     ItemStep(text: "Approve in the deploy channel")],
             source: ItemSource(host: "devbox", agent: "claude"),
             createdAt: now.addingTimeInterval(-26 * 3600))
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
            CardView(item: Self.card(now: model.now), model: model)
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
        .background(PanelGlass(palette: Theme.palette, backdrop: settings.ui.backdrop, background: settings.ui.background))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: Theme.borderWidth))
        .opacity(settings.ui.panelAlpha(hovering: false))
    }
}
