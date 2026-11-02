import SwiftUI
import Network
import os

/// Ağ trafiğinin tek geçtiği yer. Provider'ları yönetir, senkron ve eylemleri hesap başına sıraya koyar,
/// sonuçları store'a yazar. Görünümler bu sınıfı bilmez.
@MainActor
final class SyncEngine {
    private unowned let store: MailStore
    private let database: LocalDatabase?
    private var providers: [UUID: any MailProvider] = [:]
    private var syncStates: [UUID: Data]
    private var queues: [String: Task<Void, Never>] = [:]
    private var syncingAccounts: Set<UUID> = []
    /// Kullanıcının başlattığı senkronlar (yalnızca bunlar "Eşitleniyor…" gösterir)
    private var visibleSyncs: Set<UUID> = []
    /// Senkron sürerken gelen istekler; senkron bitince bir kez daha çalışır. Değer: isteklerden biri bildirim istedi mi
    private var resyncRequested: [UUID: Bool] = [:]
    private var idleTasks: [UUID: Task<Void, Never>] = [:]
    private var lastCleanup: Date = .distantPast
    /// Çevrimdışıyken yapılan, bağlantı gelince sunucuya iletilecek değişiklikler
    private var deferredChanges: [UUID: [(threadID: UUID, change: RemoteChange)]] = [:]
    private var loadingBodies: Set<UUID> = []
    private var reconcileTasks: [UUID: Task<Void, Never>] = [:]
    /// Sunucuya henüz iletilmemiş yerel değişikliği olan thread'ler; senkron bunları ezmez
    private var pendingThreadOps: [UUID: Int] = [:]
    private var pendingSends: [UUID: (task: Task<Void, Never>, started: Bool)] = [:]
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()

    /// Gelen kutusu IDLE ile anlık dinlenir; diğer klasörler için periyodik kontrol yeterli
    private static let syncInterval: TimeInterval = 300
    private static let sendDelay: Duration = .seconds(5)

    init(store: MailStore, database: LocalDatabase?, syncStates: [UUID: Data]) {
        self.store = store
        self.database = database
        self.syncStates = syncStates
    }

    private var isStarted = false
    private var isSleeping = false

    /// Ana pencere her açıldığında çağrılır; yalnızca ilkinde başlar
    func start() {
        guard !isStarted else { return }
        isStarted = true
        // İzleyici ve zamanlayıcı ana kuyrukta çalışır
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let offline = path.status != .satisfied
                guard offline != self.store.isOffline else { return }
                self.store.isOffline = offline
                self.updatePhase()
                if offline {
                    self.store.showToast(String(localized: "You're offline. Changes will sync when you're back online."), symbol: "wifi.slash")
                } else {
                    let waiting = self.deferredChanges.values.reduce(0) { $0 + $1.count }
                    self.store.showToast(waiting > 0 ? String(localized: "Back online, syncing pending changes") : String(localized: "Back online"), symbol: "wifi")
                    for accountID in self.deferredChanges.keys { self.flushDeferred(accountID) }
                    self.syncAll()
                }
            }
        }
        pathMonitor.start(queue: .main)
        // Uykuya geçerken bağlantılar düzgünce kapatılır, uyanınca baştan kurulur;
        // uykudan kalan kopuk bağlantılar hiç kullanılmaz
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterWake() }
        }
        NotificationService.shared.requestAuthorization()
        syncAll()
        for account in store.accounts { startListening(account.id) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll(notify: true) }
        }
    }

    // MARK: - Uyku

    private func prepareForSleep() {
        Log.sync.info("Uyku: bağlantılar kapatılıyor")
        isSleeping = true
        for task in idleTasks.values { task.cancel() }
        idleTasks = [:]
        let open = providers.values
        providers = [:]
        Task { for provider in open { await provider.close() } }
    }

    private func resumeAfterWake() {
        Log.sync.info("Uyandı: bağlantılar yeniden kuruluyor")
        isSleeping = false
        Task { [weak self] in
            // Wi-Fi'nin yeniden bağlanması için kısa bekleme
            try? await Task.sleep(for: .seconds(4))
            guard let self, !self.isSleeping else { return }
            for account in self.store.accounts { self.startListening(account.id) }
            self.syncAll()
        }
    }

    // MARK: - Provider

    private func provider(for account: Account) -> (any MailProvider)? {
        if let provider = providers[account.id] { return provider }
        let provider = Keychain.codable(IMAPCredentials.self, for: .imapPassword(account.id)).map {
            IMAPProvider(server: .for(account.kind), accountID: account.id, address: account.address, credentials: $0) as any MailProvider
        }
        providers[account.id] = provider
        return provider
    }

    /// Giriş bilgileri değişince (yeniden giriş) provider baştan kurulur
    func reconnect(_ accountID: UUID) {
        let old = providers.removeValue(forKey: accountID)
        Task { await old?.close() }
        store.updateAccount(accountID) { $0.status = .ok }
        sync(accountID)
    }

    func accountAdded(_ accountID: UUID) {
        sync(accountID, notify: false, visible: true)
        startListening(accountID)
    }

    func accountRemoved(_ accountID: UUID) {
        idleTasks.removeValue(forKey: accountID)?.cancel()
        let old = providers.removeValue(forKey: accountID)
        Task { await old?.close() }
        syncStates[accountID] = nil
    }

    // MARK: - Sıra

    /// Aynı anahtardaki işler sırayla çalışır (bir hesabın senkronu ile eylemleri karışmaz)
    private func enqueue(_ key: String, _ operation: @escaping @MainActor () async -> Void) {
        let previous = queues[key]
        queues[key] = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    // MARK: - Senkron

    /// visible: kullanıcı başlattıysa "Eşitleniyor…" gösterilir; arka plan kontrolleri sessizdir
    func syncAll(notify: Bool = true, visible: Bool = false) {
        guard !store.isOffline, !isSleeping else { return }
        for account in store.accounts where account.status != .needsReauth {
            sync(account.id, notify: notify, visible: visible)
        }
    }

    func sync(_ accountID: UUID, notify: Bool = true, visible: Bool = false) {
        guard !store.isOffline else { return }
        // Bekleyen değişiklikler senkrondan önce iletilir
        flushDeferred(accountID)
        guard !syncingAccounts.contains(accountID) else {
            // Sessiz bir senkron sürerken gelen yeni mail haberi bildirimini kaybetmesin
            resyncRequested[accountID] = (resyncRequested[accountID] ?? false) || notify
            return
        }
        syncingAccounts.insert(accountID)
        if visible { visibleSyncs.insert(accountID) }
        updatePhase()
        enqueue(accountID.uuidString) { [weak self] in
            await self?.performSync(accountID, notify: notify)
            guard let self else { return }
            self.syncingAccounts.remove(accountID)
            self.visibleSyncs.remove(accountID)
            self.finishProgress(accountID)
            self.updatePhase()
            if let again = self.resyncRequested.removeValue(forKey: accountID) {
                self.sync(accountID, notify: again)
            }
        }
    }

    // MARK: - Anlık dinleme (IMAP IDLE)

    /// Hesabın gelen kutusunu dinler; sunucu değişiklik bildirince hemen senkron başlar
    private func startListening(_ accountID: UUID) {
        guard idleTasks[accountID] == nil else { return }
        idleTasks[accountID] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let account = self.store.account(accountID), !self.isSleeping else { return }
                guard account.status != .needsReauth, !self.store.isOffline, let provider = self.provider(for: account) else {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                do {
                    Log.sync.info("IDLE dinleniyor: \(account.kind.rawValue, privacy: .public)")
                    let changed = try await provider.waitForChanges()
                    failures = 0
                    Log.sync.info("IDLE bitti, değişiklik: \(changed, privacy: .public)")
                    if changed && !Task.isCancelled { self.sync(accountID) }
                } catch {
                    guard !Task.isCancelled else { return }
                    // Bağlantı koptu: kademeli bekleyip yeniden dinle
                    failures += 1
                    Log.sync.error("IDLE hatası (\(failures, privacy: .public)): \(String(describing: type(of: error)), privacy: .public) \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .seconds(min(300, 10 * failures)))
                }
            }
        }
    }

    /// Biten hesap toplamdan çıkarılmaz (yüzde geri düşmesin); tüm indirmeler bitince sıfırlanır
    private func finishProgress(_ accountID: UUID) {
        if let progress = store.syncProgress[accountID] {
            store.syncProgress[accountID] = SyncProgress(done: progress.total, total: progress.total)
        }
        if store.syncProgress.values.allSatisfy(\.isComplete) {
            store.syncProgress = [:]
        }
    }

    private func updatePhase() {
        if store.isOffline {
            store.syncPhase = .offline
        } else {
            // İndirme sürüyorsa ya da kullanıcı başlattıysa görünür
            let busy = !visibleSyncs.isEmpty || store.overallSyncProgress != nil
            store.syncPhase = busy ? .syncing : .idle
        }
    }

    private func performSync(_ accountID: UUID, notify: Bool) async {
        guard let account = store.account(accountID) else { return }
        guard let provider = provider(for: account) else {
            store.updateAccount(accountID) { $0.status = .needsReauth }
            return
        }
        let existing = store.threads.filter { $0.accountID == accountID }.flatMap(\.messages)
        let previousState = syncStates[accountID]
        do {
            let started = Date.now
            // Motor uygulama boyunca yaşar; güçlü yakalama güvenli
            let output = try await provider.sync(existing: existing, state: previousState) { [self] done, total in
                Task { @MainActor in
                    // Senkron bittikten sonra gelen geç güncelleme yok sayılır
                    guard self.syncingAccounts.contains(accountID) else { return }
                    self.store.syncProgress[accountID] = SyncProgress(done: done, total: total)
                    self.updatePhase()
                }
            }
            guard store.account(accountID) != nil else { return }
            let protected = Set(pendingThreadOps.filter { $0.value > 0 }.keys)
            let arrivals = store.applySync(accountID: accountID, output: output, protecting: protected)
            syncStates[accountID] = output.state
            try? database?.saveSyncState(output.state, for: accountID)
            store.updateAccount(accountID) { $0.status = .ok }
            store.lastSync = .now
            Log.sync.info("Senkron \(account.kind.rawValue, privacy: .public): \(output.threads.count, privacy: .public) thread, \(arrivals.count, privacy: .public) yeni mail, \(Date.now.timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) sn")
            if notify && previousState != nil { notifyArrivals(arrivals) }
            cleanUpStorageIfNeeded()
        } catch {
            Log.sync.error("Senkron hatası: \(error.localizedDescription, privacy: .public)")
            handle(error, accountID: accountID)
        }
    }

    private func notifyArrivals(_ arrivals: [MailStore.Arrival]) {
        // Eski bir mailin klasörler arası taşınması bildirim sayılmaz
        let recent = arrivals.filter { $0.message.date > Date.now.addingTimeInterval(-3600) }
        // Çentikteki ada yalnızca insanlardan gelenlerde açılır
        let people = recent.filter { arrival in store.thread(arrival.threadID).map { store.feedSender(of: $0) == nil } ?? false }
        // Son on beş dakikadaki doğrulama kodu her şeyden önce gelir
        let codes = recent.filter { $0.message.date > Date.now.addingTimeInterval(-900) }.compactMap { arrival in
            VerificationCode.find(subject: arrival.message.subject ?? arrival.subject, text: arrival.message.plainText).map { (arrival, $0) }
        }
        if let (arrival, code) = codes.last {
            Log.notifications.info("Doğrulama kodu bulundu")
            MailIsland.shared.announce(code: MailIsland.Code(
                threadID: arrival.threadID,
                sender: NotificationText.sender(arrival.message.from),
                code: code
            ))
        } else if let latest = people.last {
            MailIsland.shared.announce(MailIsland.Peek(
                threadID: latest.threadID,
                sender: NotificationText.sender(latest.message.from),
                subject: NotificationText.subject(latest.message.subject ?? latest.subject),
                others: people.count - 1
            ))
        }
        guard UserDefaults.standard.object(forKey: SettingsKey.notificationsEnabled) as? Bool ?? true else { return }
        Log.notifications.info("Bildirim: \(arrivals.count, privacy: .public) yeni, \(recent.count, privacy: .public) gönderiliyor")
        guard !recent.isEmpty else { return }
        // Aynı anda çok mail gelirse tek bir özet bildirim
        if recent.count > 3 {
            let senders = recent.reversed().map { NotificationText.sender($0.message.from) }
            NotificationService.shared.notifySummary(count: recent.count, senders: NotificationText.senderList(senders))
            return
        }
        for arrival in recent {
            NotificationService.shared.notify(
                identifier: arrival.message.id,
                threadID: arrival.threadID,
                sender: NotificationText.sender(arrival.message.from),
                subject: NotificationText.subject(arrival.message.subject ?? arrival.subject),
                preview: NotificationText.body(for: arrival.message)
            )
        }
    }

    private func handle(_ error: Error, accountID: UUID) {
        switch error {
        case ProviderError.authenticationRequired, ProviderError.missingCredentials, IMAPError.authenticationFailed:
            store.updateAccount(accountID) { $0.status = .needsReauth }
            let old = providers.removeValue(forKey: accountID)
            Task { await old?.close() }
        case let error where Self.isNetworkError(error):
            // Geçici ağ sorunu: bir sonraki turda yeniden denenir
            let old = providers.removeValue(forKey: accountID)
            Task { await old?.close() }
        default:
            store.updateAccount(accountID) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        error is URLError || error is ConnectionError || (error as NSError).domain == NSPOSIXErrorDomain
    }

    // MARK: - Gövde

    func loadBodies(for threadID: UUID) {
        guard let thread = store.thread(threadID), let account = store.account(thread.accountID),
              let provider = provider(for: account) else { return }
        let missing = thread.messages.filter { !$0.isBodyLoaded && !$0.isDraft && !$0.isPendingSend && !loadingBodies.contains($0.id) }
        for message in missing {
            loadingBodies.insert(message.id)
            enqueue("\(account.id.uuidString)-body") { [weak self] in
                defer { self?.loadingBodies.remove(message.id) }
                do {
                    let body = try await provider.fetchBody(of: message)
                    self?.store.applyBody(body, messageID: message.id, threadID: threadID)
                } catch {
                    self?.store.markBodyFailed(messageID: message.id, threadID: threadID, error: error)
                }
            }
        }
    }

    // MARK: - Yerel değişiklikleri sunucuya iletme

    /// Kullanıcı eylemi (veya geri alma) sonrası önceki ve sonraki hali karşılaştırır, farkları sunucuya gönderir
    func push(before: [MailThread], after: [MailThread]) {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [UUID: [(UUID, RemoteChange)]] = [:]
        for thread in after {
            guard let previous = old[thread.id], previous != thread,
                  thread.location != .drafts, previous.location != .drafts else { continue }
            var list: [RemoteChange] = []
            if previous.location != thread.location {
                list.append(.move(thread: thread, from: previous.location, to: thread.location))
            }
            if previous.isStarred != thread.isStarred {
                list.append(.setStarred(thread: thread, starred: thread.isStarred))
            }
            let oldMessages = Dictionary(previous.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let changed = thread.messages.filter { message in
                guard let before = oldMessages[message.id], !message.isPendingSend else { return false }
                return before.isRead != message.isRead
            }
            for read in [true, false] {
                let group = changed.filter { $0.isRead == read }
                if !group.isEmpty { list.append(.setRead(thread: thread, messages: group, read: read)) }
            }
            changes[thread.accountID, default: []] += list.map { (thread.id, $0) }
        }

        for (accountID, list) in changes {
            for (threadID, _) in list { pendingThreadOps[threadID, default: 0] += 1 }
            let items = list.map { (threadID: $0.0, change: $0.1) }
            if store.isOffline {
                deferredChanges[accountID, default: []] += items
            } else {
                apply(items, accountID: accountID)
            }
        }
    }

    /// Değişiklikleri sırayla sunucuya iletir. Ağ koparsa kalanlar bağlantı gelince yeniden denenir.
    private func apply(_ items: [(threadID: UUID, change: RemoteChange)], accountID: UUID) {
        guard let account = store.account(accountID), let provider = provider(for: account) else {
            for item in items { pendingThreadOps[item.threadID, default: 1] -= 1 }
            return
        }
        enqueue(accountID.uuidString) { [weak self] in
            guard let self else { return }
            var failed = false
            for (index, item) in items.enumerated() {
                do {
                    try await provider.apply(item.change)
                    self.pendingThreadOps[item.threadID, default: 1] -= 1
                } catch let error where Self.isNetworkError(error) {
                    // Kalanlar sırada bekler; yerel değişiklikler korunur
                    self.deferredChanges[accountID, default: []] += items[index...]
                    self.handle(error, accountID: accountID)
                    return
                } catch {
                    failed = true
                    self.pendingThreadOps[item.threadID, default: 1] -= 1
                    self.handle(error, accountID: accountID)
                }
            }
            if failed {
                self.store.showToast(String(localized: "Couldn't send a change to the server, syncing again"), symbol: "exclamationmark.triangle", isError: true)
            }
            self.scheduleReconcile(accountID)
        }
    }

    private func flushDeferred(_ accountID: UUID) {
        guard !store.isOffline, let items = deferredChanges.removeValue(forKey: accountID), !items.isEmpty else { return }
        Log.sync.info("Bekleyen \(items.count, privacy: .public) değişiklik iletiliyor")
        apply(items, accountID: accountID)
    }

    /// Eylemlerden birkaç saniye sonra sunucu durumuyla yeniden eşleşir
    private func scheduleReconcile(_ accountID: UUID) {
        reconcileTasks[accountID]?.cancel()
        reconcileTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // Bu arada gelen yeni mail de duyurulur; kullanıcının taşıdıkları zaten bilindiği için yeni sayılmaz
            self?.sync(accountID, notify: true)
        }
    }

    // MARK: - Gönderim

    /// Gönderim birkaç saniye bekletilir; bu sürede "Geri al" gönderimi iptal eder
    func scheduleSend(messageID: UUID, threadID: UUID, accountID: UUID, outgoing: MIMEBuilder.Outgoing, threadRemoteID: String?) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.sendDelay)
            guard !Task.isCancelled, let self else { return }
            // Bağlantı yoksa gelene kadar bekler; bu sürede "Geri al" hâlâ çalışır
            while self.store.isOffline {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            self.pendingSends[messageID]?.started = true
            self.enqueue(accountID.uuidString) { [weak self] in
                guard let self else { return }
                defer { self.pendingSends[messageID] = nil }
                guard let account = self.store.account(accountID), let provider = self.provider(for: account) else {
                    self.store.markSendFailed(messageID: messageID, threadID: threadID, error: ProviderError.missingCredentials)
                    return
                }
                do {
                    let result = try await provider.send(outgoing, threadRemoteID: threadRemoteID)
                    self.store.markSent(messageID: messageID, threadID: threadID, result: result)
                    self.scheduleReconcile(accountID)
                } catch {
                    self.store.markSendFailed(messageID: messageID, threadID: threadID, error: error)
                }
            }
        }
        pendingSends[messageID] = (task, false)
    }

    /// true: gönderim iptal edildi; false: çoktan gönderildi
    func cancelSend(messageID: UUID) -> Bool {
        guard let pending = pendingSends[messageID], !pending.started else { return false }
        pending.task.cancel()
        pendingSends[messageID] = nil
        return true
    }

    // MARK: - Abonelikten çıkma

    enum UnsubscribeOutcome {
        /// Gönderici isteği aldı (tek tık ya da e-posta)
        case done
        /// Göndericinin sayfası tarayıcıda açıldı; çıkışı kullanıcı tamamlar
        case openedInBrowser
        /// Gönderici bir yol sunmuyor
        case unavailable
    }

    /// Göndericinin en yeni maillerinden abonelik bilgisini bulur ve en sessiz yolla çıkar:
    /// tek tık varsa arka planda istek, yoksa e-posta, o da yoksa tarayıcı.
    func unsubscribe(from stack: SenderStack) async throws -> UnsubscribeOutcome {
        let messages = stack.threads
            .flatMap { thread in thread.messages.filter { !$0.isDraft }.map { (thread.accountID, $0) } }
            .sorted { $0.1.date > $1.1.date }
            .prefix(3)
        var found: (accountID: UUID, info: Unsubscribe)?
        for (accountID, message) in messages {
            if let info = message.unsubscribe {
                found = (accountID, info)
                break
            }
            guard let account = store.account(accountID), let provider = provider(for: account) else { continue }
            if let info = try await provider.unsubscribeInfo(of: message) {
                found = (accountID, info)
                break
            }
        }
        guard let found else {
            Log.sync.info("Abonelik: yol yok")
            return .unavailable
        }

        if found.info.oneClick, let url = found.info.web {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
            // Çerez ve önbellek taşınmaz
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.sync.info("Abonelik: tek tık, durum \(status, privacy: .public)")
            guard (200..<300).contains(status) else { throw ProviderError.server(String(localized: "The sender didn't accept the request.")) }
            return .done
        }

        if let mailto = found.info.mailto,
           let account = store.account(found.accountID),
           let provider = provider(for: account),
           let components = URLComponents(url: mailto, resolvingAgainstBaseURL: false),
           !components.path.isEmpty {
            let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            let body = query["body"].flatMap { $0.isEmpty ? nil : $0 } ?? "unsubscribe"
            let outgoing = MIMEBuilder.Outgoing(
                from: account.contact,
                to: [Contact(name: "", address: components.path)],
                cc: [],
                subject: query["subject"].flatMap { $0.isEmpty ? nil : $0 } ?? "unsubscribe",
                html: "<p>\(body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</p>",
                plainText: body,
                attachments: [],
                inReplyTo: nil,
                references: [],
                messageID: MIMEBuilder.makeMessageID(for: account.address),
                date: .now
            )
            _ = try await provider.send(outgoing, threadRemoteID: nil)
            Log.sync.info("Abonelik: e-posta gönderildi")
            return .done
        }

        if let url = found.info.web {
            NSWorkspace.shared.open(url)
            Log.sync.info("Abonelik: tarayıcıda açıldı")
            return .openedInBrowser
        }
        return .unavailable
    }

    // MARK: - Bakım

    /// Saatte en fazla bir kez, arka planda
    private func cleanUpStorageIfNeeded() {
        guard Date.now.timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = .now
        let referenced = Set(store.threads.flatMap(\.messages).flatMap(\.attachments).compactMap {
            $0.localURL?.deletingLastPathComponent().standardizedFileURL.path
        })
        let database = self.database
        Task.detached(priority: .background) {
            StorageMaintenance.cleanAttachments(keeping: referenced)
            database?.compactIfNeeded()
        }
    }

    func eraseAndResync() {
        for (_, provider) in providers { Task { await provider.close() } }
        providers = [:]
        syncStates = [:]
        try? database?.eraseAll()
        syncAll(notify: false)
    }
}
