import SwiftUI
import Observation

enum ThemeAppearance: Hashable {
    case system, light, dark
}

/// Hazır görünüm teması. nil olan değerler sistem rengini kullanır.
struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let appearance: ThemeAppearance
    let accent: Color?
    /// Pencere ve sidebar zemini; birden fazla renk verilirse gradyan olur
    let canvas: [Color]?
    /// Mail listesi ve okuma paneli
    let surface: Color?
    /// Yazma kartı, ekler gibi yükseltilmiş yüzeyler
    let elevated: Color?
    /// Logo ve widget'larla aynı dil: siyah, beyaz ve griler. Avatarlar ve hesap simgeleri de renksiz çizilir.
    var isMonochrome = false

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: opacity)
    }

    /// Açık görünümde siyah, koyuda beyaz
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : NSColor(white: 0.07, alpha: 1)
    })

    static let system = Theme(id: "system", name: String(localized: "System"), appearance: .system, accent: nil, canvas: nil, surface: nil, elevated: nil)

    static let presets: [Theme] = [
        system,
        Theme(id: "light", name: String(localized: "Light"), appearance: .light, accent: nil, canvas: nil, surface: nil, elevated: nil),
        Theme(id: "dark", name: String(localized: "Dark"), appearance: .dark, accent: nil, canvas: nil, surface: nil, elevated: nil),
        // Siyah-beyaz: Nook sistemi izler, Kağıt hep açık, Mürekkep hep koyu
        Theme(id: "nook", name: "Nook", appearance: .system, accent: ink, canvas: nil, surface: nil, elevated: nil, isMonochrome: true),
        Theme(id: "paper", name: String(localized: "Paper"), appearance: .light,
              accent: ink,
              canvas: [rgb(242, 242, 242)],
              surface: rgb(255, 255, 255),
              elevated: rgb(255, 255, 255),
              isMonochrome: true),
        Theme(id: "ink", name: String(localized: "Ink"), appearance: .dark,
              accent: ink,
              canvas: [rgb(0, 0, 0)],
              surface: rgb(9, 9, 9),
              elevated: rgb(22, 22, 22),
              isMonochrome: true),
        Theme(id: "ash", name: String(localized: "Ash"), appearance: .dark,
              accent: rgb(88, 101, 242),
              canvas: [rgb(30, 31, 34)],
              surface: rgb(43, 45, 49),
              elevated: rgb(56, 58, 64)),
        Theme(id: "onyx", name: String(localized: "Onyx"), appearance: .dark,
              accent: rgb(129, 140, 248),
              canvas: [rgb(0, 0, 0)],
              surface: rgb(10, 10, 12),
              elevated: rgb(24, 24, 28)),
        Theme(id: "midnight", name: String(localized: "Midnight"), appearance: .dark,
              accent: rgb(96, 165, 250),
              canvas: [rgb(8, 13, 30), rgb(24, 32, 68)],
              surface: rgb(13, 19, 38),
              elevated: rgb(25, 34, 60)),
        Theme(id: "forest", name: String(localized: "Forest"), appearance: .dark,
              accent: rgb(52, 211, 153),
              canvas: [rgb(8, 22, 17), rgb(18, 42, 31)],
              surface: rgb(13, 27, 21),
              elevated: rgb(24, 44, 35)),
        Theme(id: "sunset", name: String(localized: "Sunset"), appearance: .dark,
              accent: rgb(251, 146, 60),
              canvas: [rgb(52, 18, 64), rgb(92, 30, 52), rgb(120, 54, 28)],
              surface: rgb(30, 17, 32),
              elevated: rgb(50, 30, 48)),
        Theme(id: "sand", name: String(localized: "Sand"), appearance: .light,
              accent: rgb(194, 85, 34),
              canvas: [rgb(234, 224, 207)],
              surface: rgb(251, 247, 240),
              elevated: rgb(255, 253, 249)),
        Theme(id: "lavender", name: String(localized: "Lavender"), appearance: .light,
              accent: rgb(124, 58, 237),
              canvas: [rgb(228, 220, 255), rgb(250, 228, 248)],
              surface: rgb(252, 250, 255),
              elevated: rgb(255, 255, 255)),
        Theme(id: "mint", name: String(localized: "Mint"), appearance: .light,
              accent: rgb(13, 148, 136),
              canvas: [rgb(214, 240, 233)],
              surface: rgb(247, 252, 250),
              elevated: rgb(255, 255, 255)),
    ]

    // MARK: Önizleme kartı için çözümlenmiş renkler

    var previewIsDark: Bool { appearance == .dark }

    var previewCanvas: [Color] {
        canvas ?? (previewIsDark ? [Self.rgb(40, 40, 43)] : [Self.rgb(232, 232, 235)])
    }

    var previewSurface: Color {
        surface ?? (previewIsDark ? Self.rgb(28, 28, 30) : .white)
    }

    var previewAccent: Color { accent ?? .accentColor }
}

/// Seçili temayı saklar ve uygular
@Observable
final class ThemeStore {
    private enum Key {
        static let theme = "themeID"
        static let accent = "accentOverride"
    }

    var themeID: String {
        didSet {
            UserDefaults.standard.set(themeID, forKey: Key.theme)
            apply()
        }
    }

    /// nil: temanın kendi vurgu rengi
    var accentOverride: AccountColor? {
        didSet { UserDefaults.standard.set(accentOverride?.rawValue, forKey: Key.accent) }
    }

    init() {
        // Yeni kurulumda logoyla uyumlu siyah-beyaz tema
        themeID = UserDefaults.standard.string(forKey: Key.theme) ?? "nook"
        accentOverride = UserDefaults.standard.string(forKey: Key.accent).flatMap(AccountColor.init(rawValue:))
    }

    var theme: Theme { Theme.presets.first { $0.id == themeID } ?? .system }

    var accent: Color { accentOverride?.color ?? theme.accent ?? .accentColor }

    /// Vurgu renginin üstündeki yazı ve simgeler; siyah-beyaz temalarda vurgu koyuda beyaz olduğu için tersine döner
    var onAccent: Color {
        theme.isMonochrome && accentOverride == nil ? Self.dynamic(light: .white, dark: .black) : .white
    }

    /// Anahtarlar gibi sistem denetimleri: beyaz zemin üstünde beyaz düğme kaybolmasın diye koyuda gri
    var controlTint: Color {
        theme.isMonochrome && accentOverride == nil ? Self.dynamic(light: NSColor(white: 0.07, alpha: 1), dark: NSColor(white: 0.5, alpha: 1)) : accent
    }

    var surface: Color { theme.surface ?? Color(nsColor: .textBackgroundColor) }

    var elevated: Color { theme.elevated ?? Color(nsColor: .controlBackgroundColor) }

    /// Okuma alanının zemini; açılan mail bunun üstünde bir sayfa gibi durur
    var desk: Color {
        if let surface = theme.surface {
            return theme.appearance == .dark ? surface : surface.mix(with: .black, by: 0.04)
        }
        return Self.dynamic(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.115, alpha: 1))
    }

    /// Hesap şeridi: pencerenin en koyu/en sakin şeridi
    var rail: Color {
        if let surface = theme.surface {
            return theme.appearance == .dark ? surface.mix(with: .black, by: 0.25) : surface.mix(with: .black, by: 0.07)
        }
        return Self.dynamic(light: NSColor(white: 0.915, alpha: 1), dark: NSColor(white: 0.075, alpha: 1))
    }

    /// Kişiler ve kanallar listesi
    var sidebar: Color {
        if let surface = theme.surface {
            return theme.appearance == .dark ? surface.mix(with: .black, by: 0.1) : surface.mix(with: .black, by: 0.03)
        }
        return Self.dynamic(light: NSColor(white: 0.96, alpha: 1), dark: NSColor(white: 0.1, alpha: 1))
    }

    /// Okunan mailin sayfası ve Akış kartları
    var paper: Color {
        theme.elevated ?? Self.dynamic(light: .white, dark: NSColor(white: 0.17, alpha: 1))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    var canvas: AnyShapeStyle {
        guard let colors = theme.canvas else { return AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) }
        if colors.count == 1, let color = colors.first { return AnyShapeStyle(color) }
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    func apply() {
        NSApp?.appearance = switch theme.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension EnvironmentValues {
    /// Siyah-beyaz temada avatarlar ve hesap simgeleri renksiz çizilir
    @Entry var isMonochrome = false
    /// Vurgu renginin üstündeki yazı ve simgeler
    @Entry var onAccent: Color = .white
}

extension View {
    /// Seçili temanın renklerini görünüm ağacına verir
    func theme(_ themes: ThemeStore) -> some View {
        environment(themes)
            .tint(themes.accent)
            .environment(\.isMonochrome, themes.theme.isMonochrome)
            .environment(\.onAccent, themes.onAccent)
    }
}
