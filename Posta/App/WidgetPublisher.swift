import AppKit
import SwiftUI
import WidgetKit
import os

/// Widget'ların okuduğu özeti uygulama grubunun ortak kabına yazar ve widget'ları yeniler.
/// Gelen kutusu, hesaplar ya da tema değişince en geç iki saniye sonra yazılır; senkron sürerken de
/// iki saniyede bir kereden sık yazılmaz. Widget'ta görünen bir şey değişmediyse widget'lar yeniden çizilmez.
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private weak var store: MailStore?
    private weak var themes: ThemeStore?
    private var pending: Task<Void, Never>?
    private var published: WidgetSnapshot?

    func start(store: MailStore, themes: ThemeStore) {
        guard self.store == nil else { return }
        self.store = store
        self.themes = themes
        publish()
        // Widget'lar uygulama derlenirken ya da güncellenirken yüklenemediyse sistem yeniden denemeyi saatlerce
        // erteleyebiliyor; her açılışta bir kez yenilemek istenir
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func publish() {
        defer { observe() }
        guard let store, let themes else { return }
        let snapshot = store.widgetSnapshot(accent: accentToken(themes))
        if let published, snapshot.hasSameContent(as: published) { return }
        do {
            try snapshot.save()
            published = snapshot
            WidgetCenter.shared.reloadAllTimelines()
            Log.app.info("Widget özeti yazıldı: \(snapshot.accounts.count) hesap, \(snapshot.people.count) konuşma")
        } catch {
            Log.app.error("Widget özeti yazılamadı: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Özette kullanılan her değer gözlemlenir; biri değişince bir sonraki yazım planlanır
    private func observe() {
        guard let store, let themes else { return }
        withObservationTracking {
            _ = store.threadsVersion
            _ = store.accounts
            _ = store.splitInbox
            _ = store.senderOverrides
            _ = themes.themeID
            _ = themes.accentOverride
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.schedule() }
        }
    }

    private func schedule() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.pending = nil
            self?.publish()
        }
    }

    /// Hesap rengi seçiliyse adı (açık ve koyu zeminde sistem rengi), temanın kendi rengiyse onaltılık değeri
    private func accentToken(_ themes: ThemeStore) -> String? {
        if let color = themes.accentOverride { return color.rawValue }
        guard let accent = themes.theme.accent, let rgb = NSColor(accent).usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}

extension MailStore {
    /// Tüm hesaplarda gelen kutusu: hesap başına sayılar, insanlardan gelen son konuşmalar ve Akış'taki göndericiler
    func widgetSnapshot(accent: String?) -> WidgetSnapshot {
        var people: [UUID: [MailThread]] = [:]
        var unread: [UUID: (people: Int, feed: Int)] = [:]
        var stacks: [String: (sender: Contact, threads: [MailThread])] = [:]

        for thread in threads(in: .all, folder: .inbox) {
            if splitInbox, let sender = feedSender(of: thread) {
                if thread.isUnread { unread[thread.accountID, default: (0, 0)].feed += 1 }
                let key = MailClassifier.senderKey(for: sender)
                stacks[key, default: (sender, [])].threads.append(thread)
            } else {
                if thread.isUnread { unread[thread.accountID, default: (0, 0)].people += 1 }
                people[thread.accountID, default: []].append(thread)
            }
        }

        let accounts = accounts.map { account in
            let counts = unread[account.id] ?? (0, 0)
            let hasProblem = switch account.status {
            case .needsReauth, .failed: true
            case .ok, .syncing: false
            }
            return WidgetSnapshot.Account(
                id: account.id,
                name: account.displayName,
                address: account.address,
                color: account.color,
                people: counts.people,
                feed: counts.feed,
                hasProblem: hasProblem
            )
        }

        // Hesap başına sekiz konuşma, en büyük widget'a ve hesaba göre süzmeye yeter
        let conversations = people.values.flatMap { threads in
            threads
                .sorted { ($0.isUnread ? 1 : 0, $0.lastDate) > ($1.isUnread ? 1 : 0, $1.lastDate) }
                .prefix(8)
                .map { thread in
                    let last = thread.messages.last { !$0.isDraft }
                    let sender = incomingSender(of: thread) ?? last?.from
                    return WidgetSnapshot.Conversation(
                        id: thread.id,
                        accountID: thread.accountID,
                        sender: sender?.displayName ?? "",
                        subject: thread.displaySubject,
                        preview: String((last?.previewLine ?? "").prefix(160)),
                        date: thread.lastDate,
                        isUnread: thread.isUnread
                    )
                }
        }

        let senders = stacks.map { key, stack in
            let accountIDs = stack.threads.reduce(into: [UUID]()) { ids, thread in
                if !ids.contains(thread.accountID) { ids.append(thread.accountID) }
            }
            return WidgetSnapshot.Sender(
                id: key,
                name: stack.sender.displayName,
                unread: stack.threads.filter(\.isUnread).count,
                date: stack.threads.map(\.lastDate).max() ?? .distantPast,
                accountIDs: accountIDs
            )
        }

        return WidgetSnapshot(
            generated: .now,
            splitInbox: splitInbox,
            accent: accent,
            accounts: accounts,
            people: conversations.sorted { $0.date > $1.date },
            feed: Array(senders.sorted { $0.date > $1.date }.prefix(24))
        )
    }

    /// Widget'tan gelen bağlantı: konuşmayı, hesabın gelen kutusunu ya da yeni maili açar
    func open(_ link: PostaLink) {
        switch link {
        case .thread(let id):
            reveal(id)
        case .reply(let id):
            reveal(id)
            startReply()
        case .inbox(let account):
            go(scope: account.flatMap { self.account($0) }.map { .account($0.id) } ?? .all, folder: .inbox)
        case .compose(let account):
            if let account, self.account(account) != nil, scope != .account(account) {
                go(scope: .account(account), folder: .inbox)
            }
            compose()
        }
    }
}
