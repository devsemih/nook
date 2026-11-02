import AppIntents
import WidgetKit

// MARK: - Zaman çizelgesi

struct InboxEntry: TimelineEntry {
    let date: Date
    let inbox: Inbox
}

/// Uygulama yeni bir özet yazınca widget'ları kendisi yeniler; burada yalnızca gece yarısı yenilenir ki
/// "14:32" gibi saatler ertesi gün "Dün" olsun
struct InboxProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> InboxEntry {
        InboxEntry(date: .now, inbox: Inbox(snapshot: .sample, accountID: nil))
    }

    func snapshot(for configuration: SelectAccountIntent, in context: Context) async -> InboxEntry {
        entry(for: configuration, isPreview: context.isPreview)
    }

    func timeline(for configuration: SelectAccountIntent, in context: Context) async -> Timeline<InboxEntry> {
        Timeline(entries: [entry(for: configuration, isPreview: false)], policy: .after(.nextMidnight))
    }

    /// Widget galerisinde, Posta henüz özet yazmadıysa örnek veri görünür
    private func entry(for configuration: SelectAccountIntent, isPreview: Bool) -> InboxEntry {
        let snapshot = WidgetSnapshot.load() ?? (isPreview ? .sample : .empty)
        return InboxEntry(date: .now, inbox: Inbox(snapshot: snapshot, accountID: configuration.account?.accountID))
    }
}

struct AccountsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AccountsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AccountsEntry {
        AccountsEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AccountsEntry) -> Void) {
        completion(AccountsEntry(date: .now, snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .sample : .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccountsEntry>) -> Void) {
        let entry = AccountsEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private extension Date {
    static var nextMidnight: Date {
        Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime)
            ?? .now.addingTimeInterval(3600)
    }
}

// MARK: - Hesap seçimi

/// Widget'a sağ tıklayıp "Düzenle" denince: tüm hesaplar ya da tek bir hesap
struct SelectAccountIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account"
    static let description = IntentDescription("The account to show in the widget.")

    @Parameter(title: "Account")
    var account: AccountEntity?
}

struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountQuery()
    static let all = AccountEntity(id: "all", name: String(localized: "All accounts"), address: nil)

    let id: String
    let name: String
    let address: String?

    /// nil: tüm hesaplar
    var accountID: UUID? { UUID(uuidString: id) }

    var displayRepresentation: DisplayRepresentation {
        if let address {
            DisplayRepresentation(title: "\(name)", subtitle: "\(address)")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        choices().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        choices()
    }

    func defaultResult() async -> AccountEntity? {
        .all
    }

    private func choices() -> [AccountEntity] {
        let accounts = WidgetSnapshot.load()?.accounts ?? []
        return [.all] + accounts.map { AccountEntity(id: $0.id.uuidString, name: $0.name, address: $0.address) }
    }
}
