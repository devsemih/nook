import SwiftUI
import AppKit

// Uygulama ve widget'lar ortak kullanır: aynı hesap ve aynı kişi her yerde aynı renkte, aynı harflerle görünür.

nonisolated enum AccountColor: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .gray: .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .gray: .systemGray
        }
    }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .indigo: String(localized: "Indigo")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .mint: String(localized: "Mint")
        case .teal: String(localized: "Teal")
        case .gray: String(localized: "Gray")
        }
    }
}

nonisolated enum Monogram {
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .red, .cyan, .brown]

    /// Aynı isim her yerde aynı renkte görünür
    static func color(for name: String) -> Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }

    /// "Semih Aslan" → "SA", "hey@odin.studio" → "HO"
    static func initials(for text: String) -> String {
        let words = text
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "-" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
        let result = letters.isEmpty ? String(text.prefix(1)) : letters
        return result.uppercased(with: Locale.current)
    }
}
