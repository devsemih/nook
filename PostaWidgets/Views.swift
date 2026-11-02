import SwiftUI
import WidgetKit

// Logoyla aynı dil: yalnızca siyah ve beyaz. Açık temada beyaz kart üstünde siyah, koyu temada tersi.
// Renk yok; vurguyu ağırlık ve büyüklük taşır. Sol üstte Nook'un kemer işareti.

// MARK: - Sana yazanlar (küçük)

struct NewConversationsView: View {
    let inbox: Inbox

    var body: some View {
        if !inbox.hasAccounts {
            SetupView()
        } else {
            let names = inbox.waitingNames
            VStack(alignment: .leading, spacing: 0) {
                NookMark(size: 22)
                Spacer(minLength: 0)
                Text(names.isEmpty ? "All\ncaught up" : "\(names.count) people\nwrote to you")
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.6)
                    .lineSpacing(-2)
                    // İngilizcede ikinci satır uzun; iki satıra sığacak kadar küçülür
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Text(names.isEmpty ? (inbox.feedCount > 0 ? String(localized: "\(inbox.feedCount) new in Feed") : String(localized: "Your inbox is quiet")) : Self.list(names))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(inbox.link)
        }
    }

    static func list(_ names: [String]) -> String {
        names.prefix(3).map(firstName).joined(separator: ", ")
    }
}

// MARK: - Son yazan (küçük)

/// En son yazan kişi ortada; altında aç ve yanıtla
struct LatestPersonView: View {
    let inbox: Inbox

    var body: some View {
        if !inbox.hasAccounts {
            SetupView()
        } else if let latest = inbox.conversations.first {
            VStack(spacing: 0) {
                Avatar(name: latest.sender, size: 46)
                Text(firstName(latest.sender))
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .padding(.top, 7)
                Text(latest.isUnread ? Fmt.listDate(latest.date) : latest.subject)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    CircleLink(symbol: "envelope.open", url: PostaLink.thread(latest.id).url, isPrimary: false)
                    CircleLink(symbol: "arrowshape.turn.up.left.fill", url: PostaLink.reply(latest.id).url, isPrimary: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(PostaLink.thread(latest.id).url)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                NookMark(size: 22)
                Spacer(minLength: 0)
                Text("No one\nyet")
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Özet (orta)

/// Gelen kutusu tek cümlede: "Ayşe ve Mert sana yazdı, Akış'ta 23 yeni var."
struct BriefingView: View {
    let inbox: Inbox

    var body: some View {
        if !inbox.hasAccounts {
            SetupView()
        } else {
            let latest = inbox.conversations.first
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    NookMark(size: 18)
                    Spacer()
                    if let account = inbox.account {
                        Text(account.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(sentence)
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.4)
                    .lineSpacing(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                Spacer(minLength: 8)
                if let latest {
                    Link(destination: PostaLink.thread(latest.id).url) {
                        HStack(spacing: 10) {
                            Avatar(name: latest.sender, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(latest.sender)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(latest.subject)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(inbox.link)
        }
    }

    /// Gri bir cümle; kişiler ve sayılar koyu. Çevirideki **kalın** parçalar koyu gösterilir, böylece her dil kendi kelime sırasını kurar.
    private var sentence: AttributedString {
        let names = inbox.waitingNames.map(firstName)
        var text: AttributedString = switch names.count {
        case 0: AttributedString(localized: "No new mail from people")
        case 1: AttributedString(localized: "**\(names[0])** wrote to you")
        case 2: AttributedString(localized: "**\(names[0])** and **\(names[1])** wrote to you")
        case 3: AttributedString(localized: "**\(names[0])**, **\(names[1])**, and **\(names[2])** wrote to you")
        default: AttributedString(localized: "**\(names[0])**, **\(names[1])**, and **\(names.count - 2) others** wrote to you")
        }
        if inbox.isSplit, inbox.feedCount > 0 {
            text += AttributedString(localized: ", **\(inbox.feedCount) new** in Feed.")
        } else {
            text += AttributedString(".")
        }
        let ranges = text.runs.map { ($0.range, $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true) }
        for (range, isStrong) in ranges {
            text[range].inlinePresentationIntent = nil
            text[range].foregroundColor = isStrong ? .primary : .secondary
        }
        return text
    }
}

// MARK: - İnsanlar (orta, büyük)

/// Sana yazan son kişiler; her satır o konuşmayı açar
struct PeopleView: View {
    let inbox: Inbox
    let isLarge: Bool

    var body: some View {
        if !inbox.hasAccounts {
            SetupView()
        } else {
            let rows = Array(inbox.conversations.prefix(isLarge ? 5 : 2))
            VStack(alignment: .leading, spacing: isLarge ? 14 : 11) {
                HStack(spacing: 9) {
                    NookMark(size: 16)
                    Text(inbox.title)
                        .font(.system(size: 17, weight: .bold))
                    Spacer(minLength: 6)
                    if inbox.newCount > 0 {
                        Text("\(inbox.newCount) new")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if rows.isEmpty {
                    Text("No mail from people yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { conversation in
                        PersonRow(conversation: conversation)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(inbox.link)
        }
    }
}

private struct PersonRow: View {
    let conversation: WidgetSnapshot.Conversation

    var body: some View {
        Link(destination: PostaLink.thread(conversation.id).url) {
            HStack(spacing: 11) {
                Avatar(name: conversation.sender, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.sender)
                        .font(.system(size: 14, weight: conversation.isUnread ? .bold : .medium))
                    Text(conversation.subject)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Fmt.listDate(conversation.date))
                        .font(.system(size: 11.5, weight: conversation.isUnread ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(conversation.isUnread ? .primary : .secondary)
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                        .opacity(conversation.isUnread ? 1 : 0)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Akış (küçük, orta)

/// Setin ters kartı: her zaman siyah zemin, beyaz yazı. Orta boyda sağda en çok yazanlar sıralanır.
struct FeedView: View {
    let inbox: Inbox
    var isMedium = false

    var body: some View {
        Group {
            if !inbox.hasAccounts {
                SetupView()
            } else {
                let top = inbox.senders.filter { $0.unread > 0 }.sorted { $0.unread > $1.unread }
                if isMedium {
                    HStack(spacing: 22) {
                        summary(top: top)
                        VStack(alignment: .leading, spacing: 9) {
                            if top.isEmpty {
                                Text("No newsletters or notifications")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(top.prefix(4), id: \.id) { sender in
                                HStack(spacing: 8) {
                                    Text(sender.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(sender.unread, format: .number)
                                        .font(.system(size: 13, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    summary(top: top)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .widgetURL(inbox.link)
    }

    private func summary(top: [WidgetSnapshot.Sender]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NookMark(size: 18)
                Spacer()
                if !isMedium {
                    Text("Feed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isMedium {
                Text("Feed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(inbox.feedCount, format: .number)
                    .font(.system(size: 42, weight: .bold))
                    .tracking(-1.2)
                Text(inbox.isSplit ? "new" : "off")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            if !isMedium {
                Text(top.first.map { "Mostly \($0.name)" } ?? "No newsletters or notifications")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: isMedium ? 120 : .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Hesaplar (küçük, orta)

/// Hesaplar baş harfleriyle; insanlardan gelen yeniler küçük bir sayıyla
struct AccountsView: View {
    let snapshot: WidgetSnapshot
    var isMedium = false

    var body: some View {
        if snapshot.accounts.isEmpty {
            SetupView()
        } else if isMedium {
            HStack(alignment: .top, spacing: 0) {
                ForEach(snapshot.accounts.prefix(4)) { account in
                    Link(destination: PostaLink.inbox(account: account.id).url) {
                        VStack(spacing: 9) {
                            AccountTile(account: account, size: 54)
                            Text(account.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(account.people > 0 ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(PostaLink.inbox(account: nil).url)
        } else {
            let accounts = snapshot.accounts
            let shown = accounts.count > 4 ? Array(accounts.prefix(3)) : accounts
            let size: CGFloat = accounts.count == 1 ? 72 : 50
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: 16), count: min(accounts.count, 2)), spacing: 16) {
                ForEach(shown) { account in
                    Link(destination: PostaLink.inbox(account: account.id).url) {
                        AccountTile(account: account, size: size)
                    }
                    .buttonStyle(.plain)
                }
                if accounts.count > 4 {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(.primary.opacity(0.2), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .overlay {
                            Text("+\(accounts.count - 3)")
                                .font(.system(size: size * 0.3, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(PostaLink.inbox(account: nil).url)
        }
    }
}

// MARK: - Ortak parçalar

private func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}

/// Widget zemini: açıkta beyaz, koyuda siyah
struct CardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        colorScheme == .dark ? Color(white: 0.06) : Color.white
    }
}

/// Akış kartının her zaman siyah zemini
struct NightBackground: View {
    var body: some View {
        Color.black
    }
}

/// Logodaki kemer: kalın, uçları yuvarlak bir "n"
struct NookMark: View {
    var size: CGFloat = 22

    var body: some View {
        let line = size * 0.22
        ArchLine()
            .stroke(.primary, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .padding(line / 2)
            .frame(width: size * 0.8, height: size)
            .widgetAccentable()
            .accessibilityHidden(true)
    }
}

/// Yuvarlak bağlantı düğmesi: asıl eylem dolu, diğeri açık gri
private struct CircleLink: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let url: URL
    let isPrimary: Bool

    var body: some View {
        Link(destination: url) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPrimary ? (colorScheme == .dark ? Color.black : .white) : .primary)
                .frame(width: 40, height: 40)
                .background(isPrimary ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.08)), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Nook açılmadıysa ya da hesap yoksa
struct SetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NookMark(size: 22)
            Spacer(minLength: 0)
            Text("Open\nNook")
                .font(.system(size: 25, weight: .bold))
                .tracking(-0.6)
            Text("Your accounts will appear here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(PostaLink.inbox(account: nil).url)
    }
}

/// Kişinin baş harfleri; renksiz, ince bir daire içinde
struct Avatar: View {
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Circle()
            .fill(.primary.opacity(0.07))
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .overlay {
                Text(Monogram.initials(for: name))
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: size, height: size)
    }
}

/// Hesabın baş harfleri; insanlardan yeni varsa köşede siyah (koyuda beyaz) sayı
struct AccountTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: WidgetSnapshot.Account
    var size: CGFloat = 46

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(.primary.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .overlay {
                Text(Monogram.initials(for: account.name))
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if account.hasProblem || account.people > 0 {
                    Text(account.hasProblem ? "!" : (account.people > 99 ? "99+" : "\(account.people)"))
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(colorScheme == .dark ? Color.black : .white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.primary, in: Capsule())
                        .padding(2)
                        .background(colorScheme == .dark ? Color(white: 0.06) : .white, in: Capsule())
                        .offset(x: 5, y: 5)
                }
            }
    }
}
