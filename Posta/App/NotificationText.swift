import Foundation

/// Bildirimde okunaklı metin: gönderen adı, sade konu, alıntısız ve linksiz kısa önizleme
nonisolated enum NotificationText {
    private static let locale = Locale.autoupdatingCurrent

    /// Adı olmayan "noreply@github.com" gibi adresler için şirket adı ("GitHub")
    static func sender(_ contact: Contact) -> String {
        let name = contact.name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && name.lowercased() != contact.address.lowercased() { return name }

        let parts = contact.address.lowercased().split(separator: "@")
        guard parts.count == 2 else { return contact.address }
        let local = String(parts[0])
        let generic = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications", "notification",
                       "notify", "info", "mailer", "bilgi", "hello", "hi", "support", "destek", "mail", "news",
                       "newsletter", "team", "account", "accounts", "billing", "security", "alerts", "updates", "bildirim"]
        if generic.contains(local) || local.hasPrefix("noreply") || local.hasPrefix("no-reply") {
            return brand(from: String(parts[1])) ?? contact.address
        }
        // "ahmet.demir" → "Ahmet Demir"
        return local.split(whereSeparator: { ".-_".contains($0) })
            .map { $0.prefix(1).uppercased(with: locale) + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// accounts.google.com → Google, trendyol.com.tr → Trendyol
    private static func brand(from domain: String) -> String? {
        var labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        labels.removeLast()
        if labels.count >= 2, ["com", "net", "org", "co", "gov", "edu", "ac", "gen", "web"].contains(labels.last!) {
            labels.removeLast()
        }
        guard let name = labels.last, !name.isEmpty else { return nil }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// "Re: Fwd: Teklif" → "Teklif"
    static func subject(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"^\s*((re|fw|fwd|ynt|ilt|aw|wg|sv|tr)\s*(\[\d+\])?\s*:\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? String(localized: "(No subject)") : cleaned
    }

    /// Yazışmanın yeni kısmı: alıntılar, eski mesaj başlıkları ve uzun linkler çıkarılır
    static func body(for message: Message) -> String {
        var text = message.plainText.isEmpty ? message.preview : message.plainText
        // Yanıtlarda alıntılanan eski yazışma kesilir
        let markers = [
            #"(?m)^\s*On .{4,200}wrote:\s*$"#,
            #"(?m)^.{4,200}(tarihinde|zamanında).{0,200}(şunu yazdı|yazdı):\s*$"#,
            #"(?m)^\s*-{2,}\s*(Original Message|Forwarded message|İletilen mesaj|Orijinal Mesaj)"#,
            #"(?m)^\s*(From|Kimden):\s.+$"#,
        ]
        for pattern in markers {
            if let range = text.range(of: pattern, options: .regularExpression), range.lowerBound > text.startIndex {
                text = String(text[..<range.lowerBound])
            }
        }
        text = text
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: " ")
            .replacingOccurrences(of: #"<?https?://\S+>?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            if let first = message.attachments.first {
                let rest = message.attachments.count - 1
                return rest > 0 ? String(localized: "📎 \(first.filename) and \(rest) more") : "📎 \(first.filename)"
            }
            return message.hasAttachmentHint ? String(localized: "📎 A message with attachments") : String(localized: "New message")
        }
        return truncate(text, to: 150)
    }

    /// Kelime ortasında kesmeden kısaltır
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—")) + "…"
    }

    /// "Mert, GitHub ve 3 kişi daha"
    static func senderList(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        switch unique.count {
        case 0: return ""
        case 1: return unique[0]
        case 2: return String(localized: "\(unique[0]) and \(unique[1])")
        default:
            let rest = unique.count - 2
            return String(localized: "\(unique[0]), \(unique[1]), and \(rest) more")
        }
    }
}
