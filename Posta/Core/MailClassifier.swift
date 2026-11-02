import Foundation

/// Otomatik gönderilen mailleri (bülten, bildirim, fatura…) insanların yazdıklarından ayırır.
/// Etiket ya da yapay zekâ kullanmaz: mail başlıklarındaki standart işaretlere ve gönderen adresine bakar.
nonisolated enum MailClassifier {
    /// Başlık kuralları değişince artar; eski işaretler bir sonraki senkronda sunucudan yeniden hesaplanır
    static let version = 2
    /// Ad ve içerik kuralları değişince artar; eldeki metinle, ağa çıkmadan yeniden hesaplanır
    static let contentVersion = 5

    /// Toplu gönderim listelerinin ve e-posta servislerinin eklediği başlıklar
    private static let bulkHeaders = [
        "list-unsubscribe", "list-id", "feedback-id", "x-campaign", "x-csa-complaints",
        "x-ses-outgoing", "x-sg-eid", "x-mailgun-sid", "x-mc-user", "x-mandrill-user",
        "x-pm-message-id", "x-sfmc-stack",
    ]

    /// Eski maillerin sınıflandırılması için sunucudan yalnızca bu başlıklar istenir
    static let headerFields = (["from", "precedence", "auto-submitted", "return-path", "x-mailer"] + bulkHeaders)
        .map { $0.uppercased() }
        .joined(separator: " ")

    static func isAutomated(header: (String) -> String?, from sender: Contact?) -> Bool {
        if bulkHeaders.contains(where: { header($0) != nil }) { return true }
        if let precedence = header("precedence")?.lowercased(),
           ["bulk", "list", "junk", "auto_reply"].contains(where: precedence.contains) {
            return true
        }
        if let submitted = header("auto-submitted")?.trimmingCharacters(in: .whitespaces).lowercased(),
           !submitted.isEmpty, !submitted.hasPrefix("no") {
            return true
        }
        // Gönderim servislerinin geri dönen mailleri topladığı adres (VERP)
        if let path = header("return-path")?.lowercased(),
           path.contains("bounce") || bulkServices.contains(where: path.contains) {
            return true
        }
        if let mailer = header("x-mailer")?.lowercased(), automatedMailers.contains(where: mailer.contains) {
            return true
        }
        return sender.map(isAutomatedSender) ?? false
    }

    /// Gönderen adı ya da adresi bir otomasyona işaret ediyor mu: "Google Workspace Ekibi", "X via TestFlight"
    static func isAutomatedSender(_ contact: Contact) -> Bool {
        if isAutomatedAddress(contact.address) { return true }
        let words = normalize(contact.name).split(whereSeparator: { !$0.isLetter })
        return words.contains { automatedNameWords.contains(String($0)) }
    }

    private static let automatedNameWords: Set<String> = [
        "via", "team", "ekibi", "support", "destek", "bilgilendirme", "bildirim", "bildirimleri",
        "notification", "notifications", "noreply", "newsletter", "bulten", "servisi", "service", "hizmetleri",
    ]

    private static let bulkServices = [
        "amazonses.com", "sendgrid.net", "mailgun", "mcsv.net", "mandrillapp.com", "sparkpostmail.com",
        "mktomail.com", "exacttarget.com", "rsgsv.net", "postmarkapp.com", "mailjet", "sendinblue", "brevo",
        "hubspot", "salesforce", "emarsys", "euromsg", "relateddigital", "dengage", "useinsider",
    ]

    private static let automatedMailers = [
        "phpmailer", "swiftmailer", "symfony", "nodemailer", "mailchimp", "sendgrid", "sendinblue", "brevo",
        "hubspot", "salesforce", "marketo", "mailjet", "euromsg", "dengage", "campaign",
    ]

    /// Metindeki toplu gönderim izleri: abonelikten çık, lütfen yanıtlamayın, tarayıcıda görüntüle…
    /// Yanıt ve iletilerde alıntılanan kısım sayılmaz; insanın ilettiği bülten insanlarda kalır.
    static func isAutomatedContent(_ text: String) -> Bool {
        var body = Substring(text.prefix(20_000))
        for marker in quoteMarkers {
            if let range = body.range(of: marker, options: .caseInsensitive) { body = body[..<range.lowerBound] }
        }
        // Kurumların hitabı: "Sayın SEMİH ASLAN"; maskeli kart numarası: 5549********6021
        if body.firstMatch(of: capsSalutation) != nil || body.firstMatch(of: maskedNumber) != nil { return true }
        let normalized = normalize(body)
        return automatedPhrases.contains(where: normalized.contains)
    }

    nonisolated(unsafe) private static let capsSalutation = #/(Sayın|Sayin|Merhaba|Değerli|Dear|Hello|Hi)\s+[A-ZÇĞİÖŞÜ]{2,}\s+[A-ZÇĞİÖŞÜ]{2,}/#
    nonisolated(unsafe) private static let maskedNumber = #/\d{2,6}[*Xx•]{4,}\d{2,4}/#

    /// Küçük harf, aksansız; Türkçe ı da i sayılır
    private static func normalize<S: StringProtocol>(_ text: S) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "’", with: "'")
    }

    private static let quoteMarkers = [
        "---------- Forwarded message", "---------- İletilen mesaj", "Begin forwarded message",
        "-----Original Message-----", " wrote:", "şunu yazdı:",
    ]

    /// Küçük harfe çevrilmiş, aksanları atılmış (ı → i) hâlleriyle
    private static let automatedPhrases = [
        "unsubscribe", "opt-out", "email preferences", "e-mail preferences", "manage your preferences",
        "notification settings", "manage notifications", "you are receiving this", "you're receiving this",
        "you received this email", "this email was sent to", "this message was sent to",
        "do not reply", "don't reply", "please do not respond", "automated message", "automatically generated",
        "this is an automated", "automated email", "view in browser", "view this email in your browser",
        "view it in your browser", "all rights reserved",
        "abonelikten cik", "abonelikten ayril", "aboneligi iptal", "aboneliginizi iptal", "e-posta listesinden",
        "listemizden cik", "lutfen yanitlamayin", "yanitlamayiniz", "cevaplamayiniz", "cevap vermeyiniz",
        "yanit vermeyiniz", "otomatik olarak gonderil", "otomatik olarak olusturul", "otomatik bir e-posta",
        "otomatik bir mesaj", "otomatik mesaj", "otomatik e-posta", "otomatik bilgilendirme",
        "tarayicida goruntule", "tarayicinizda goruntule", "web tarayicinizda", "tum haklari saklidir",
        "bu e-postayi sana", "bu e-postayi size", "bu e-postayi aldiniz", "e-posta tercihleri",
        "bildirim ayarlari", "iletisim tercihleri", "ticari elektronik ileti",
        "degerli musterimiz", "sayin musterimiz", "degerli uyemiz", "degerli kullanicimiz", "sevgili kullanicimiz",
        "degerli abonemiz", "sayin abonemiz", "dear customer", "dear valued customer", "dear member",
        "bilgilendirme amacli", "bilgilendirme mesajidir", "bilgilendirme e-postasi",
        "goruntuleyemiyorsaniz", "goruntuleyemiyor musunuz", "goruntulenemiyorsa", "having trouble viewing",
    ]

    /// Adres bir otomasyona işaret ediyor mu: noreply@, bildirim@, info@, …@email.ornek.com
    static func isAutomatedAddress(_ address: String) -> Bool {
        guard let (local, domain) = split(address) else { return false }
        if isNoReply(local: local) || automatedNames.contains(local) || automatedPrefixes.contains(where: local.hasPrefix) {
            return true
        }
        let labels = domain.split(separator: ".")
        return labels.count > 2 && automatedSubdomains.contains(String(labels[0]))
    }

    /// Yanıtların kimseye ulaşmadığı adres
    static func isNoReply(_ address: String) -> Bool {
        guard let (local, _) = split(address) else { return false }
        return isNoReply(local: local)
    }

    private static func isNoReply(local: String) -> Bool {
        local.contains("noreply") || local.contains("donotreply") || local.contains("dontreply")
    }

    /// Yerel kısım harf ve rakamlara indirgenir: "no-reply" ve "no_reply" aynı sayılır
    private static func split(_ address: String) -> (local: String, domain: String)? {
        let parts = address.lowercased().split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0].filter { $0.isLetter || $0.isNumber }), String(parts[1]))
    }

    private static let automatedNames: Set<String> = [
        "info", "news", "newsletter", "newsletters", "updates", "update", "digest", "alerts", "alert",
        "notify", "notifications", "notification", "marketing", "promo", "promotions", "offers", "deals",
        "billing", "invoice", "invoices", "receipt", "receipts", "order", "orders", "shipping", "delivery",
        "account", "accounts", "security", "verify", "verification", "auth", "feedback", "survey",
        "mailer", "mailerdaemon", "postmaster", "bounce", "bounces", "automated", "auto", "system", "robot", "bot",
        "bilgi", "bilgilendirme", "bildirim", "bildirimler", "duyuru", "haber", "bulten", "bülten",
        "kampanya", "fatura", "siparis", "sipariş",
    ]

    private static let automatedPrefixes = ["notification", "newsletter", "mailer", "bounce", "alert", "bildirim"]

    private static let automatedSubdomains: Set<String> = [
        "email", "e", "em", "mail", "mailer", "mailing", "news", "newsletter", "marketing", "mkt",
        "notifications", "notification", "notify", "info", "updates", "send", "bounce", "reply", "comms",
        "communication", "communications", "notice", "notices",
    ]

    /// Kişisel posta servisleri: buradaki bir adresin tek bir otomatik görünen maili, kişinin tamamını Akış'a taşımaz
    static func isPersonalDomain(_ address: String) -> Bool {
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        return personalDomains.contains(domain)
    }

    private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "hotmail.com", "outlook.com",
        "live.com", "msn.com", "yahoo.com", "ymail.com", "aol.com", "yandex.com", "yandex.com.tr", "yandex.ru",
        "proton.me", "protonmail.com", "gmx.com", "gmx.de", "mail.ru", "hotmail.com.tr", "windowslive.com",
    ]

    // MARK: - Gönderici yığını

    /// "email.apple.com" → "apple.com", "mail.yemeksepeti.com.tr" → "yemeksepeti.com.tr"
    static func baseDomain(of address: String) -> String {
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return domain }
        let secondLevel: Set<String> = ["com", "co", "org", "net", "gov", "edu", "ac", "gen", "biz", "info", "web", "tv", "k12", "bel"]
        let isCountryPair = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2])
        return labels.suffix(isCountryPair ? 3 : 2).joined(separator: ".")
    }

    /// Akış'taki yığının anahtarı: gönderen adı ve kök alan adı.
    /// "App Store Connect" ile "Apple" aynı adresten gelse de ayrı yığınlardır.
    static func senderKey(for contact: Contact) -> String {
        let name = contact.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        return "\(name.isEmpty ? contact.address.lowercased() : name)|\(baseDomain(of: contact.address))"
    }
}
