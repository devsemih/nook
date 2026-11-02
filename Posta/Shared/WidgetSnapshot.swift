import Foundation

/// Uygulamanın widget'lar için yazdığı özet. Uygulama grubunun ortak kabında JSON olarak durur;
/// widget'lar yalnızca bunu okur, posta sunucusuna ya da uygulamanın veritabanına erişmez.
nonisolated struct WidgetSnapshot: Codable, Equatable, Sendable {
    nonisolated struct Account: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var name: String
        var address: String
        var color: AccountColor
        /// İnsanlardan gelen okunmamış konuşmalar; ayrım kapalıysa gelen kutusundaki tüm okunmamışlar
        var people: Int
        /// Akış'taki okunmamış mailler
        var feed: Int
        /// Yeniden giriş gerekiyor ya da eşitlenemiyor
        var hasProblem: Bool
    }

    nonisolated struct Conversation: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var accountID: UUID
        var sender: String
        var subject: String
        var preview: String
        var date: Date
        var isUnread: Bool
    }

    /// Akış'ta bir gönderici
    nonisolated struct Sender: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var unread: Int
        var date: Date
        var accountIDs: [UUID]
    }

    var generated: Date
    /// İnsanlar ve Akış ayrımı açık mı; kapalıysa `people` gelen kutusunun tamamıdır
    var splitInbox: Bool
    /// Temanın vurgu rengi: hesap rengi adı ("purple") ya da "#5865F2"; nil ise sistemin vurgu rengi
    var accent: String?
    var accounts: [Account]
    /// Hesap başına en fazla birkaç konuşma: önce okunmamışlar, sonra en yeniler
    var people: [Conversation]
    /// Akış'taki göndericiler, en yeni üstte
    var feed: [Sender]

    /// Uygulama ile widget'ların ortak kabı. Başında imzalayan ekibin kimliği var; derleme sırasında Info.plist'e yazılır.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "NookAppGroup") as? String ?? "com.odinstudio.posta"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widgets.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Widget'ta görünen bir şey değişti mi (yazılma zamanı sayılmaz)
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        var other = other
        other.generated = generated
        return self == other
    }
}

/// Widget'tan Posta'ya açılan bağlantılar: posta://thread/<id>, posta://inbox?account=<id>, posta://compose
nonisolated enum PostaLink: Equatable {
    case inbox(account: UUID?)
    case thread(UUID)
    /// Konuşmayı açıp hızlı yanıta odaklanır
    case reply(UUID)
    case compose(account: UUID?)

    static let scheme = "posta"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .inbox(let account):
            components.host = "inbox"
            components.queryItems = account.map { [URLQueryItem(name: "account", value: $0.uuidString)] }
        case .thread(let id):
            components.host = "thread"
            components.path = "/\(id.uuidString)"
        case .reply(let id):
            components.host = "reply"
            components.path = "/\(id.uuidString)"
        case .compose(let account):
            components.host = "compose"
            components.queryItems = account.map { [URLQueryItem(name: "account", value: $0.uuidString)] }
        }
        return components.url ?? URL(string: "\(Self.scheme)://inbox")!
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let account = components.queryItems?.first { $0.name == "account" }?.value.flatMap(UUID.init(uuidString:))
        switch components.host {
        case "inbox":
            self = .inbox(account: account)
        case "thread":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .thread(id)
        case "reply":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .reply(id)
        case "compose":
            self = .compose(account: account)
        default:
            return nil
        }
    }
}
