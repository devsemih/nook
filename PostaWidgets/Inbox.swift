import SwiftUI

/// Widget'ın gösterdiği gelen kutusu: tüm hesaplar ya da widget'ta seçilen hesap
struct Inbox {
    let snapshot: WidgetSnapshot
    /// nil: tüm hesaplar
    let account: WidgetSnapshot.Account?

    init(snapshot: WidgetSnapshot, accountID: UUID?) {
        self.snapshot = snapshot
        account = accountID.flatMap { id in snapshot.accounts.first { $0.id == id } }
    }

    var hasAccounts: Bool { !snapshot.accounts.isEmpty }
    var isSplit: Bool { snapshot.splitInbox }
    var title: String { isSplit ? String(localized: "People") : String(localized: "inbox.section", defaultValue: "Inbox", comment: "Bölüm başlığı; klasör adı olan Inbox'tan ayrı") }
    var accent: Color { snapshot.accentColor }
    var link: URL { PostaLink.inbox(account: account?.id).url }

    private var accounts: [WidgetSnapshot.Account] {
        account.map { [$0] } ?? snapshot.accounts
    }

    var newCount: Int { accounts.reduce(0) { $0 + $1.people } }
    var feedCount: Int { accounts.reduce(0) { $0 + $1.feed } }

    /// Önce okunmamışlar, sonra en yeniler
    var conversations: [WidgetSnapshot.Conversation] {
        snapshot.people
            .filter { account == nil || $0.accountID == account?.id }
            .sorted { ($0.isUnread ? 1 : 0, $0.date) > ($1.isUnread ? 1 : 0, $1.date) }
    }

    /// Okunmamış konuşmalarda yazan kişiler, en yeni önde; aynı kişi bir kez
    var waitingNames: [String] {
        var seen = Set<String>()
        return conversations
            .filter(\.isUnread)
            .map(\.sender)
            .filter { seen.insert($0).inserted }
    }

    /// Akış'taki göndericiler: yenisi olanlar önde
    var senders: [WidgetSnapshot.Sender] {
        snapshot.feed
            .filter { sender in account.map { sender.accountIDs.contains($0.id) } ?? true }
            .sorted { ($0.unread > 0 ? 1 : 0, $0.date) > ($1.unread > 0 ? 1 : 0, $1.date) }
    }

    /// Akış'taki yenilerin dağılımı: en çok yazan dört gönderici ve geri kalanı
    var feedSegments: [FeedSegment] {
        snapshot.feedSegments(account: account?.id)
    }
}

extension WidgetSnapshot {
    /// Posta'daki temanın vurgu rengi; seçilmemişse sistemin vurgu rengi
    var accentColor: Color {
        guard let accent else { return .accentColor }
        if let named = AccountColor(rawValue: accent) { return named.color }
        guard accent.hasPrefix("#"), let value = Int(accent.dropFirst(), radix: 16) else { return .accentColor }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static let empty = WidgetSnapshot(generated: .now, splitInbox: true, accent: nil, accounts: [], people: [], feed: [])

    /// Widget galerisi için örnek: Posta henüz bir özet yazmadıysa görünür
    static var sample: WidgetSnapshot {
        let personal = UUID()
        let work = UUID()
        let now = Date.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return WidgetSnapshot(
            generated: now,
            splitInbox: true,
            accent: nil,
            accounts: [
                Account(id: personal, name: String(localized: "Personal"), address: "ben@icloud.com", color: .purple, people: 2, feed: 6, hasProblem: false),
                Account(id: work, name: String(localized: "Studio"), address: "merhaba@studyo.com", color: .teal, people: 1, feed: 3, hasProblem: false),
            ],
            people: [
                Conversation(id: UUID(), accountID: personal, sender: "Ayşe Demir", subject: String(localized: "Breakfast on Saturday?"), preview: String(localized: "Ten o'clock at our place, come along. Mom is baking pastries."), date: ago(12), isUnread: true),
                Conversation(id: UUID(), accountID: work, sender: "Mert Kaya", subject: String(localized: "Presentation draft"), preview: String(localized: "I attached the final version. Could you take a look at the third slide?"), date: ago(95), isUnread: true),
                Conversation(id: UUID(), accountID: personal, sender: "Elif Şahin", subject: String(localized: "Photos"), preview: String(localized: "Here are the ones I picked from the wedding. Mark the ones you like."), date: ago(300), isUnread: true),
                Conversation(id: UUID(), accountID: work, sender: "Can Yıldız", subject: String(localized: "About the invoice"), preview: String(localized: "Could you send the October invoice again?"), date: ago(1_500), isUnread: false),
                Conversation(id: UUID(), accountID: personal, sender: "Deniz Arslan", subject: String(localized: "Book recommendation"), preview: String(localized: "The book I mentioned is Madonna in a Fur Coat."), date: ago(3_000), isUnread: false),
            ],
            feed: [
                Sender(id: "github", name: "GitHub", unread: 3, date: ago(40), accountIDs: [work]),
                Sender(id: "apple", name: "App Store Connect", unread: 2, date: ago(120), accountIDs: [work]),
                Sender(id: "yemek", name: "Yemeksepeti", unread: 4, date: ago(200), accountIDs: [personal]),
            ]
        )
    }
}
