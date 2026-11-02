import Foundation

enum Fmt {
    /// Uygulamanın gösterdiği dil (Türkçe ya da İngilizce) ve kullanıcının bölge ayarları; tarihler arayüzle aynı dilde görünür
    static let locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }()

    /// Biçimlendiriciler bir kez kurulur; liste kayarken her satırda yeniden oluşturulmaz
    private static let calendar: Calendar = {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        return calendar
    }()

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let time = formatter("HHmm")
    private static let weekday = formatter("EEEE")
    private static let dayMonth = formatter("dMMM")
    private static let numeric = formatter("ddMMyyyy")
    private static let dayMonthWeekday = formatter("EEEdMMM")
    private static let dayMonthYear = formatter("dMMMyyyy")
    private static let monthName = formatter("MMMM")
    private static let monthYear = formatter("MMMMyyyy")

    /// Mail listesindeki kısa tarih
    static func listDate(_ date: Date, now: Date = .now) -> String {
        let cal = calendar
        if cal.isDateInToday(date) {
            return time.string(from: date)
        }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, days < 7 {
            return weekday.string(from: date)
        }
        if cal.isDate(date, equalTo: now, toGranularity: .year) {
            return dayMonth.string(from: date)
        }
        return numeric.string(from: date)
    }

    /// Okuma panelindeki tam tarih
    static func fullDate(_ date: Date) -> String {
        let cal = calendar
        let time = Self.time.string(from: date)
        if cal.isDateInToday(date) { return String(localized: "Today \(time)") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return dayMonthWeekday.string(from: date) + " \(time)"
        }
        return dayMonthYear.string(from: date) + " \(time)"
    }

    /// Sohbetteki gün ayracı: "Bugün", "Dün", "26 Eki Pzt"
    static func dayTitle(_ date: Date, now: Date = .now) -> String {
        let cal = calendar
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if cal.isDate(date, equalTo: now, toGranularity: .year) { return dayMonthWeekday.string(from: date) }
        return dayMonthYear.string(from: date)
    }

    static func bucket(for date: Date, now: Date = .now) -> (key: String, title: String) {
        let cal = calendar
        if cal.isDateInToday(date) { return ("today", String(localized: "Today")) }
        if cal.isDateInYesterday(date) { return ("yesterday", String(localized: "Yesterday")) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day, days < 7 {
            return ("week", String(localized: "This week"))
        }
        if cal.isDate(date, equalTo: now, toGranularity: .month) { return ("month", String(localized: "This month")) }
        let comps = cal.dateComponents([.year, .month], from: date)
        let sameYear = cal.isDate(date, equalTo: now, toGranularity: .year)
        let title = sameYear
            ? monthName.string(from: date)
            : monthYear.string(from: date)
        return ("m\(comps.year ?? 0)-\(comps.month ?? 0)", title.capitalized(with: locale))
    }

    /// Yönelme eki: "Ayşe" → "Ayşe'ye", "Mert" → "Mert'e", "Burak" → "Burak'a". Arayüz Türkçe değilse ad olduğu gibi kalır.
    static func dative(_ name: String) -> String {
        guard locale.language.languageCode == .turkish else { return name }
        let vowels: Set<Character> = ["a", "ı", "o", "u", "e", "i", "ö", "ü"]
        let lower = name.lowercased(with: locale)
        guard let last = lower.last(where: vowels.contains) else { return name + "'e" }
        let suffix = ["a", "ı", "o", "u"].contains(last) ? "a" : "e"
        let buffer = lower.last.map(vowels.contains) == true ? "y" : ""
        return "\(name)'\(buffer)\(suffix)"
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func syncStatus(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "Updated just now") }
        if seconds < 3600 { return String(localized: "Updated \(Int(seconds / 60)) min ago") }
        let time = Self.time.string(from: date)
        return String(localized: "Up to date as of \(time)")
    }
}
