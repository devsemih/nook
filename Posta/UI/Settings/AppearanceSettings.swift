import SwiftUI

struct AppearanceSettings: View {
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        @Bindable var themes = themes

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 160), spacing: 14)], alignment: .leading, spacing: 16) {
                        ForEach(Theme.presets) { theme in
                            Button {
                                withAnimation(.smooth(duration: 0.25)) { themes.themeID = theme.id }
                            } label: {
                                ThemeCard(theme: theme, isSelected: themes.themeID == theme.id)
                            }
                            .buttonStyle(.plain)
                            .handCursor()
                            .accessibilityLabel(theme.name)
                            .accessibilityAddTraits(themes.themeID == theme.id ? .isSelected : [])
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent color")
                        .font(.headline)
                    HStack(spacing: 10) {
                        AccentSwatch(
                            fill: AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)),
                            isSelected: themes.accentOverride == nil,
                            help: String(localized: "Theme color")
                        ) { themes.accentOverride = nil }

                        Divider().frame(height: 18)

                        ForEach(AccountColor.allCases) { color in
                            AccentSwatch(fill: AnyShapeStyle(color.color), isSelected: themes.accentOverride == color, help: color.title) {
                                themes.accentOverride = color
                            }
                        }
                    }
                    Text("The selected message, unread indicator, buttons, and links use this color.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccentSwatch: View {
    let fill: AnyShapeStyle
    let isSelected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(.white, lineWidth: 2).padding(2.5)
                    }
                }
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .handCursor()
        .accessibilityLabel(help)
    }
}

/// Mini pencere önizlemesi: sidebar, liste ve okuma paneli
struct ThemeCard: View {
    @Environment(\.onAccent) private var onAccent
    let theme: Theme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
                .frame(height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2.5 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(onAccent, .tint)
                            .font(.system(size: 15))
                            .padding(5)
                    }
                }
            Text(theme.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .padding(.leading, 2)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        if theme.appearance == .system {
            // Sistemi izleyen tema: yarısı açık, yarısı koyu
            MiniWindow(theme: Self.variant(of: theme, dark: false))
                .overlay {
                    MiniWindow(theme: Self.variant(of: theme, dark: true))
                        .mask {
                            GeometryReader { proxy in
                                Path { path in
                                    path.move(to: CGPoint(x: proxy.size.width * 0.62, y: 0))
                                    path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
                                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                                    path.addLine(to: CGPoint(x: proxy.size.width * 0.38, y: proxy.size.height))
                                }
                            }
                        }
                }
        } else {
            MiniWindow(theme: theme)
        }
    }

    /// Sistemi izleyen temanın açık ve koyu hali: Nook için Kağıt ve Mürekkep
    private static func variant(of theme: Theme, dark: Bool) -> Theme {
        let id = theme.isMonochrome ? (dark ? "ink" : "paper") : (dark ? "dark" : "light")
        return Theme.presets.first { $0.id == id } ?? theme
    }
}

private struct MiniWindow: View {
    let theme: Theme

    private var line: Color { theme.previewIsDark ? .white.opacity(0.28) : .black.opacity(0.14) }
    private var faint: Color { theme.previewIsDark ? .white.opacity(0.14) : .black.opacity(0.07) }

    var body: some View {
        let canvas = theme.previewCanvas
        ZStack {
            Rectangle().fill(LinearGradient(colors: canvas.count > 1 ? canvas : [canvas[0], canvas[0]], startPoint: .topLeading, endPoint: .bottomTrailing))

            HStack(spacing: 4) {
                // Sidebar
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<4) { index in
                        Capsule()
                            .fill(index == 0 ? theme.previewAccent.opacity(0.6) : line)
                            .frame(width: index == 0 ? 22 : 18, height: 3)
                    }
                    Spacer()
                    if theme.isMonochrome {
                        ArchLine()
                            .stroke(theme.previewAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .padding(1)
                            .frame(width: 7, height: 9)
                    } else {
                        Circle().fill(theme.previewAccent).frame(width: 7, height: 7)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(width: 34)

                // Liste
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4) { index in
                        HStack(spacing: 3) {
                            Circle().fill(index < 2 ? theme.previewAccent : .clear).frame(width: 3, height: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Capsule().fill(line).frame(width: 22, height: 2.5)
                                Capsule().fill(faint).frame(width: 30, height: 2)
                            }
                        }
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == 1 ? theme.previewAccent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                }
                .padding(3)
                .frame(width: 48)
                .frame(maxHeight: .infinity)
                .background(theme.previewSurface, in: RoundedRectangle(cornerRadius: 5))

                // Okuma paneli
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(line).frame(width: 30, height: 4)
                    ForEach(0..<3) { _ in
                        Capsule().fill(faint).frame(height: 2.5)
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(theme.previewAccent).frame(width: 16, height: 6)
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.previewSurface, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(4)
        }
        // Siyah-beyaz temaların vurgusu görünüme göre değiştiği için önizleme kendi görünümünde çizilir
        .environment(\.colorScheme, theme.previewIsDark ? .dark : .light)
    }
}
