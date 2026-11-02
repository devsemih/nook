import SwiftUI
import WidgetKit

@main
struct PostaWidgetBundle: WidgetBundle {
    var body: some Widget {
        NewConversationsWidget()
        LatestPersonWidget()
        BriefingWidget()
        PeopleWidget()
        FeedWidget()
        AccountsWidget()
    }
}

/// Küçük: kaç kişi yazdı
struct NewConversationsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NewConversations", intent: SelectAccountIntent.self, provider: InboxProvider()) { entry in
            NewConversationsView(inbox: entry.inbox)
                .containerBackground(for: .widget) { CardBackground() }
        }
        .configurationDisplayName("Who wrote to you")
        .description("Unread conversations from people.")
        .supportedFamilies([.systemSmall])
    }
}

/// Küçük: en son yazan kişi, yanıtla ve aç
struct LatestPersonWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LatestPerson", intent: SelectAccountIntent.self, provider: InboxProvider()) { entry in
            LatestPersonView(inbox: entry.inbox)
                .containerBackground(for: .widget) { CardBackground() }
        }
        .configurationDisplayName("Latest sender")
        .description("The last person who wrote to you. Reply with one click.")
        .supportedFamilies([.systemSmall])
    }
}

/// Orta: gelen kutusu tek cümlede
struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Briefing", intent: SelectAccountIntent.self, provider: InboxProvider()) { entry in
            BriefingView(inbox: entry.inbox)
                .containerBackground(for: .widget) { CardBackground() }
        }
        .configurationDisplayName("Summary")
        .description("Who wrote to you and what's waiting in Feed, in one sentence.")
        .supportedFamilies([.systemMedium])
    }
}

/// Orta ve büyük: sana yazan son kişiler
struct PeopleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "People", intent: SelectAccountIntent.self, provider: InboxProvider()) { entry in
            PeopleWidgetView(inbox: entry.inbox)
                .containerBackground(for: .widget) { CardBackground() }
        }
        .configurationDisplayName("People")
        .description("The latest people who wrote to you. Click a conversation to open it in Nook.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

/// Küçük ve orta: Akış'ta kaç yeni var
struct FeedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Feed", intent: SelectAccountIntent.self, provider: InboxProvider()) { entry in
            FamilyReader { FeedView(inbox: entry.inbox, isMedium: $0 == .systemMedium) }
                .containerBackground(for: .widget) { NightBackground() }
        }
        .configurationDisplayName("Feed")
        .description("Newsletters, notifications, and invoices: how many are new and who sent the most.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Küçük ve orta: hesaplar, hesap şeridindeki gibi
struct AccountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Accounts", provider: AccountsProvider()) { entry in
            FamilyReader { AccountsView(snapshot: entry.snapshot, isMedium: $0 == .systemMedium) }
                .containerBackground(for: .widget) { CardBackground() }
        }
        .configurationDisplayName("Accounts")
        .description("How many new conversations each account has.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PeopleWidgetView: View {
    let inbox: Inbox

    var body: some View {
        FamilyReader { PeopleView(inbox: inbox, isLarge: $0 == .systemLarge) }
    }
}

/// Widget'ın boyutunu görünüme parametre olarak verir; görünümler önizlemede de çizilebilsin
private struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content

    var body: some View {
        content(family)
    }
}
