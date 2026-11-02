import SwiftUI
import Observation

struct ThreadSection: Identifiable {
    let id: String
    let title: String
    let threads: [MailThread]
}

/// Akış'ta tek bir göndericinin otomatik mailleri, en yeni üstte
struct SenderStack: Identifiable {
    let id: String
    var sender: Contact
    var threads: [MailThread] = []

    var name: String { sender.name.isEmpty ? sender.address : sender.name }
    var lastDate: Date { threads.first?.lastDate ?? .distantPast }
    var unreadCount: Int { threads.filter(\.isUnread).count }
    var accountIDs: [UUID] {
        var seen = Set<UUID>()
        return threads.map(\.accountID).filter { seen.insert($0).inserted }
    }
}

/// Gelen kutusunda bir kişiyle yazışmalar; kenar çubuğunda Slack'teki özel mesaj gibi tek satır
struct Person: Identifiable {
    let id: String
    var contact: Contact
    /// Gelen kutusundaki konuşmalar, en yeni önde
    var threads: [MailThread] = []

    var name: String { contact.displayName }
    var latest: MailThread? { threads.first }
    var lastDate: Date { threads.first?.lastDate ?? .distantPast }
    var unreadCount: Int { threads.filter(\.isUnread).count }
}

/// Seçilebilen satır: bir konuşma, bir kişi ya da Akış'taki bir gönderici yığını
enum ListItem: Hashable {
    case thread(UUID)
    case person(String)
    case stack(String)
}

/// Arayüzün tek doğru kaynağı. Görünümler yalnızca bu store'u okur ve eylemleri buraya iletir.
/// Veriler yerel SQLite'tan yüklenir ve değiştikçe oraya yazılır; ağ trafiği SyncEngine üzerinden geçer.
@Observable
final class MailStore {
    // MARK: Veri

    var accounts: [Account] = [] {
        didSet { if accounts != oldValue { try? database?.saveAccounts(accounts) } }
    }
    var threads: [MailThread] = [] {
        didSet {
            threadsVersion &+= 1
            schedulePersist()
        }
    }
    /// threads her değiştiğinde artar; liste önbelleği bununla geçersiz olur
    private(set) var threadsVersion = 0
    var savedDrafts: [UUID: SavedDraft] = [:] {
        didSet { saveDrafts() }
    }

    // MARK: Gezinme

    var scope: AccountScope = .all {
        didSet { if scope != oldValue { scopeChanged() } }
    }
    var folder: MailboxRole = .inbox {
        didSet {
            if folder != oldValue, !isRestoring {
                selectedThreadID = nil
                selectedStackID = nil
            }
        }
    }
    /// Liste başlığındaki okunmamış hapı ile açılıp kapanır
    var unreadOnly = false
    var searchText = ""
    var selectedThreadID: UUID? {
        didSet {
            if selectedThreadID != nil, selectedStackID != nil { selectedStackID = nil }
            if selectedThreadID != oldValue { selectionChanged() }
        }
    }
    /// Akış'ta seçili gönderici yığını; okuma alanında o göndericinin mailleri alt alta görünür
    var selectedStackID: String? {
        didSet { if selectedStackID != nil, selectedThreadID != nil { selectedThreadID = nil } }
    }

    // MARK: İnsanlar ve Akış

    /// Gelen kutusu, insanlardan gelenler ve göndericiye göre gruplanmış otomatik mailler olarak ikiye ayrılır
    var splitInbox = UserDefaults.standard.object(forKey: SettingsKey.splitInbox) as? Bool ?? true {
        didSet { UserDefaults.standard.set(splitInbox, forKey: SettingsKey.splitInbox) }
    }
    /// Elle taşınan göndericiler: true Akış'a, false İnsanlar'a
    private(set) var senderOverrides = UserDefaults.standard.dictionary(forKey: SettingsKey.senderOverrides) as? [String: Bool] ?? [:] {
        didSet { UserDefaults.standard.set(senderOverrides, forKey: SettingsKey.senderOverrides) }
    }
    /// Abonelikten çıkılan göndericiler ve tarihi
    private(set) var unsubscribedSenders = (UserDefaults.standard.dictionary(forKey: SettingsKey.unsubscribedSenders) as? [String: Date]) ?? [:] {
        didSet {
            // Örnek verideki göndericiler gerçek tercihlere yazılmaz
            guard !DemoData.isEnabled else { return }
            UserDefaults.standard.set(unsubscribedSenders, forKey: SettingsKey.unsubscribedSenders)
        }
    }
    var showsOlderPeople = false
    var showsOlderStacks = false
    /// Okuma alanının altındaki hızlı yanıtta yazılanlar; thread başına, yalnızca bellekte
    var quickReplies: [UUID: String] = [:]
    /// R tuşu hızlı yanıt alanına odaklanır
    var quickReplyFocusRequest = 0
    /// Akış kartından "Yanıtla": okuma alanı açılınca hızlı yanıta odaklanılır
    var pendingQuickReplyFocus: UUID?

    // MARK: Durum

    var composer: Draft?
    var toast: Toast?
    var syncPhase: SyncPhase = .idle
    /// İndirme süren (veya bu turda biten) hesaplar için indirilen / toplam mail
    var syncProgress: [UUID: SyncProgress] = [:]
    var lastSync: Date = .now
    var isOffline = false {
        didSet { syncPhase = isOffline ? .offline : .idle }
    }

    // MARK: Sunum

    var showAddAccount = false
    var showQuickSwitcher = false
    var showShortcuts = false
    var renamingAccount: Account?
    var reauthAccount: Account?
    var expandAllRequest = 0

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var engine: SyncEngine?
    @ObservationIgnored let database: LocalDatabase?
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var persistedThreads: [UUID: MailThread] = [:]
    @ObservationIgnored private(set) var loadedSyncStates: [UUID: Data] = [:]

    init(database: LocalDatabase?) {
        self.database = database
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistNow() }
        }
    }

    private func load() {
        guard let database, let snapshot = try? database.load() else { return }
        isLoading = true
        defer { isLoading = false }
        accounts = snapshot.accounts
        // Sınıflandırma kuralları değiştiyse işaretler bir sonraki senkronda yeniden hesaplanır
        let reclassify = UserDefaults.standard.integer(forKey: SettingsKey.classifierVersion) < MailClassifier.version
        // Uygulama kapanırken gönderim kuyruğunda kalanlar gönderilmemiştir
        threads = snapshot.threads.compactMap { thread in
            var thread = thread
            thread.messages.removeAll(where: \.isPendingSend)
            if reclassify {
                for index in thread.messages.indices { thread.messages[index].automated = nil }
            }
            return thread.messages.isEmpty ? nil : thread
        }
        if reclassify { UserDefaults.standard.set(MailClassifier.version, forKey: SettingsKey.classifierVersion) }
        if UserDefaults.standard.integer(forKey: SettingsKey.contentRulesVersion) < MailClassifier.contentVersion {
            UserDefaults.standard.set(MailClassifier.contentVersion, forKey: SettingsKey.contentRulesVersion)
            reclassifyLocally()
        }
        persistedThreads = Dictionary(snapshot.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drafts: [UUID: SavedDraft] = [:]
        for (id, stored) in snapshot.drafts {
            drafts[id] = SavedDraft(stored: stored)
        }
        savedDrafts = drafts
        loadedSyncStates = snapshot.syncStates
    }

    /// Yeni ad ve içerik kuralları eldeki maillere uygulanır; sunucuya gidilmez, arayüz beklemez
    private func reclassifyLocally() {
        let snapshot = threads
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { Self.newlyAutomated(in: snapshot) }.value
            guard let self, !found.isEmpty else { return }
            var updated = self.threads
            for index in updated.indices {
                guard let ids = found[updated[index].id] else { continue }
                for message in updated[index].messages.indices where ids.contains(updated[index].messages[message].id) {
                    updated[index].messages[message].automated = true
                }
            }
            withAnimation(.smooth(duration: 0.3)) { self.threads = updated }
        }
    }

    /// Otomatik sayılmamış ama yeni kurallara uyan mesajlar: thread → mesaj kimlikleri
    nonisolated private static func newlyAutomated(in threads: [MailThread]) -> [UUID: Set<UUID>] {
        var found: [UUID: Set<UUID>] = [:]
        for thread in threads {
            for message in thread.messages where message.automated == false {
                if MailClassifier.isAutomatedSender(message.from) || MailClassifier.isAutomatedContent(message.plainText) {
                    found[thread.id, default: []].insert(message.id)
                }
            }
        }
        return found
    }

    // MARK: - Kalıcılık

    private func schedulePersist() {
        guard !isLoading else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Yalnızca değişen thread'leri yazar
    func persistNow() {
        guard let database else { return }
        let current = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let upserts = current.values.filter { persistedThreads[$0.id] != $0 }
        let deletions = persistedThreads.keys.filter { current[$0] == nil }
        do {
            try database.apply(upserts: upserts, deletions: deletions)
            persistedThreads = current
        } catch {
            showToast(String(localized: "Couldn't write to the local database"), symbol: "exclamationmark.triangle", isError: true)
        }
    }

    private func saveDrafts() {
        guard !isLoading else { return }
        try? database?.saveDrafts(savedDrafts.compactMapValues(\.stored))
    }

    // MARK: - Sorgular

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func thread(_ id: UUID?) -> MailThread? {
        guard let id else { return nil }
        return threads.first { $0.id == id }
    }

    var selectedThread: MailThread? { thread(selectedThreadID) }

    var scopedAccount: Account? {
        if case .account(let id) = scope { return account(id) }
        return nil
    }

    var isUnified: Bool { scope == .all && accounts.count > 1 }

    func isFromMe(_ message: Message, accountID: UUID) -> Bool {
        guard let account = account(accountID) else { return false }
        return message.from.address.caseInsensitiveCompare(account.address) == .orderedSame
    }

    private func inScope(_ thread: MailThread, _ scope: AccountScope) -> Bool {
        switch scope {
        case .all: true
        case .account(let id): thread.accountID == id
        }
    }

    private func matches(_ thread: MailThread, folder: MailboxRole) -> Bool {
        switch folder {
        case .inbox: return thread.location == .inbox
        case .starred: return thread.isStarred && thread.location != .trash && thread.location != .drafts
        case .sent:
            guard thread.location != .trash, thread.location != .drafts else { return false }
            return thread.location == .sent
                || thread.messages.contains { !$0.isDraft && isFromMe($0, accountID: thread.accountID) }
        case .drafts: return thread.location == .drafts
        case .archive: return thread.location == .archive
        case .spam: return thread.location == .spam
        case .trash: return thread.location == .trash
        }
    }

    func threads(in scope: AccountScope, folder: MailboxRole) -> [MailThread] {
        threads.filter { inScope($0, scope) && matches($0, folder: folder) }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private struct ListKey: Equatable {
        var version: Int
        var scope: AccountScope
        var folder: MailboxRole
        var unreadOnly: Bool
        var search: String
        var selection: UUID?
        var stackSelection: String?
        var accountCount: Int
        var overrides: [String: Bool]
    }

    @ObservationIgnored private var visibleCache: (key: ListKey, value: [MailThread])?
    @ObservationIgnored private var sectionsCache: (key: ListKey, value: [ThreadSection])?

    /// Okunan her özellik gözlemlenir; böylece önbellek doğru anda yenilenir
    private var listKey: ListKey {
        ListKey(
            version: threadsVersion,
            scope: scope,
            folder: folder,
            unreadOnly: unreadOnly,
            search: searchText,
            selection: unreadOnly ? selectedThreadID : nil,
            stackSelection: unreadOnly ? selectedStackID : nil,
            accountCount: accounts.count,
            overrides: senderOverrides
        )
    }

    /// Mail listesinde görünen thread'ler, en yeni üstte (önbellekli; kaydırırken yeniden hesaplanmaz)
    var visibleThreads: [MailThread] {
        let key = listKey
        if let cache = visibleCache, cache.key == key { return cache.value }
        let value = computeVisibleThreads()
        visibleCache = (key, value)
        return value
    }

    private func computeVisibleThreads() -> [MailThread] {
        var result: [MailThread]
        if isSearching {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            // Arama tüm hesaplarda yapılır
            result = threads.filter { thread in
                guard thread.location != .trash, thread.location != .spam else { return false }
                return matchesSearch(thread, query: query)
            }
        } else {
            result = threads(in: scope, folder: folder)
        }
        if unreadOnly {
            // Seçili mail ve seçili yığın okununca listeden kaybolmaz
            let keptStack = selectedStackID
            let addresses = myAddresses
            result = result.filter { thread in
                thread.isUnread || thread.id == selectedThreadID
                    || (keptStack != nil && feedSender(of: thread, myAddress: addresses[thread.accountID]).map(MailClassifier.senderKey) == keptStack)
            }
        }
        return result.sorted { $0.lastDate > $1.lastDate }
    }

    /// Arama paletindeki sonuçlar: tüm hesaplar ve klasörler, en yeni üstte
    func searchResults(for query: String, limit: Int = 30) -> [MailThread] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return threads
            .filter { matchesSearch($0, query: query) }
            .sorted { $0.lastDate > $1.lastDate }
            .prefix(limit)
            .map { $0 }
    }

    /// Thread'in listede göründüğü klasör
    func homeFolder(of thread: MailThread) -> MailboxRole {
        switch thread.location {
        case .inbox: .inbox
        case .archive: .archive
        case .sent: .sent
        case .drafts: .drafts
        case .spam: .spam
        case .trash: .trash
        }
    }

    private func matchesSearch(_ thread: MailThread, query: String) -> Bool {
        let terms = query.split(separator: " ").map(String.init)
        return terms.allSatisfy { term in
            if thread.subject.localizedStandardContains(term) { return true }
            return thread.messages.contains { message in
                message.from.displayName.localizedStandardContains(term)
                    || message.from.address.localizedStandardContains(term)
                    || message.to.contains { $0.displayName.localizedStandardContains(term) || $0.address.localizedStandardContains(term) }
                    || message.plainText.localizedStandardContains(term)
                    || message.attachments.contains { $0.filename.localizedStandardContains(term) }
            }
        }
    }

    var sections: [ThreadSection] {
        let key = listKey
        if let cache = sectionsCache, cache.key == key { return cache.value }
        let value = computeSections()
        sectionsCache = (key, value)
        return value
    }

    private func computeSections() -> [ThreadSection] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var groups: [String: [MailThread]] = [:]
        for thread in visibleThreads {
            let (key, title) = Fmt.bucket(for: thread.lastDate)
            if groups[key] == nil {
                order.append(key)
                titles[key] = title
            }
            groups[key, default: []].append(thread)
        }
        return order.map { ThreadSection(id: $0, title: titles[$0] ?? "", threads: groups[$0] ?? []) }
    }

    // MARK: İnsanlar ve Akış

    /// Gelen kutusu ayrık mı gösteriliyor; aramada ve diğer klasörlerde liste tarihe göre gruplanır
    var splitsInbox: Bool { splitInbox && folder == .inbox && !isSearching }

    struct InboxGroups {
        var people: [MailThread] = []
        var stacks: [SenderStack] = []
        var stackOfThread: [UUID: String] = [:]
    }

    @ObservationIgnored private var groupsCache: (key: ListKey, value: InboxGroups)?

    /// Görünen thread'lerin İnsanlar ve Akış yığınları olarak dağılımı (önbellekli)
    var inboxGroups: InboxGroups {
        let key = listKey
        if let cache = groupsCache, cache.key == key { return cache.value }
        let value = computeInboxGroups()
        groupsCache = (key, value)
        return value
    }

    private func computeInboxGroups() -> InboxGroups {
        let addresses = myAddresses
        var groups = InboxGroups()
        var order: [String] = []
        var stacks: [String: SenderStack] = [:]
        for thread in visibleThreads {
            guard let sender = feedSender(of: thread, myAddress: addresses[thread.accountID]) else {
                groups.people.append(thread)
                continue
            }
            let key = MailClassifier.senderKey(for: sender)
            if stacks[key] == nil {
                order.append(key)
                stacks[key] = SenderStack(id: key, sender: sender)
            }
            stacks[key]?.threads.append(thread)
            groups.stackOfThread[thread.id] = key
        }
        groups.stacks = order.compactMap { stacks[$0] }
        return groups
    }

    private var myAddresses: [UUID: String] {
        Dictionary(accounts.map { ($0.id, $0.address.lowercased()) }, uniquingKeysWith: { first, _ in first })
    }

    /// Thread yalnızca otomatik maillerden oluşuyorsa göndericisi (Akış'ta yığınlanır); insanlardan geliyorsa nil
    private func feedSender(of thread: MailThread, myAddress: String?) -> Contact? {
        var incoming: [Message] = []
        var repliedByMe = false
        for message in thread.messages where !message.isDraft {
            if message.from.address.lowercased() == myAddress {
                repliedByMe = true
            } else {
                incoming.append(message)
            }
        }
        guard let latest = incoming.last else { return nil }
        let key = MailClassifier.senderKey(for: latest.from)
        if let feed = senderOverrides[key] { return feed ? latest.from : nil }
        // Yanıt verdiğin konuşmalar insanlarla yapılmıştır
        guard !repliedByMe else { return nil }
        if incoming.allSatisfy({ $0.automated ?? MailClassifier.isAutomatedSender($0.from) }) { return latest.from }
        // Aynı kurumun başka bir maili otomatikse bu da Akış'ta, aynı yığında durur
        return automatedSenderKeys.contains(key) ? latest.from : nil
    }

    @ObservationIgnored private var automatedSendersCache: (version: Int, keys: Set<String>)?

    /// Otomatik mail gönderdiği kesinleşmiş kurumsal göndericiler (kişisel posta servisleri hariç)
    private var automatedSenderKeys: Set<String> {
        if let cache = automatedSendersCache, cache.version == threadsVersion { return cache.keys }
        let mine = Set(accounts.map { $0.address.lowercased() })
        var keys = Set<String>()
        for thread in threads {
            for message in thread.messages where message.automated == true {
                let address = message.from.address.lowercased()
                guard !mine.contains(address), !MailClassifier.isPersonalDomain(address) else { continue }
                keys.insert(MailClassifier.senderKey(for: message.from))
            }
        }
        automatedSendersCache = (threadsVersion, keys)
        return keys
    }

    func feedSender(of thread: MailThread) -> Contact? {
        feedSender(of: thread, myAddress: account(thread.accountID)?.address.lowercased())
    }

    /// Thread'e son yazan (sen hariç)
    func incomingSender(of thread: MailThread) -> Contact? {
        thread.messages.last { !$0.isDraft && !isFromMe($0, accountID: thread.accountID) }?.from
    }

    // MARK: Kenar çubuğu: kişiler ve kanallar

    struct Sidebar {
        var people: [Person] = []
        var olderPeople: [Person] = []
        var stacks: [SenderStack] = []
        var olderStacks: [SenderStack] = []

        var allPeople: [Person] { people + olderPeople }
    }

    private struct SidebarKey: Equatable {
        var version: Int
        var scope: AccountScope
        var split: Bool
        var overrides: [String: Bool]
        var accountCount: Int
        var day: Date
    }

    @ObservationIgnored private var sidebarCache: (key: SidebarKey, value: Sidebar)?

    /// Gelen kutusundaki kişiler ve Akış göndericileri; hangi klasör açık olursa olsun aynı kalır.
    /// Son iki haftada yazanlar ve okunmamışı olanlar önde, gerisi "eski" olarak katlanır.
    var sidebar: Sidebar {
        let key = SidebarKey(
            version: threadsVersion,
            scope: scope,
            split: splitInbox,
            overrides: senderOverrides,
            accountCount: accounts.count,
            day: Calendar.current.startOfDay(for: .now)
        )
        if let cache = sidebarCache, cache.key == key { return cache.value }
        let value = computeSidebar()
        sidebarCache = (key, value)
        return value
    }

    private func computeSidebar() -> Sidebar {
        let addresses = myAddresses
        var people: [String: Person] = [:]
        var peopleOrder: [String] = []
        var stacks: [String: SenderStack] = [:]
        var stackOrder: [String] = []
        for thread in threads(in: scope, folder: .inbox).sorted(by: { $0.lastDate > $1.lastDate }) {
            if splitInbox, let sender = feedSender(of: thread, myAddress: addresses[thread.accountID]) {
                let key = MailClassifier.senderKey(for: sender)
                if stacks[key] == nil {
                    stackOrder.append(key)
                    stacks[key] = SenderStack(id: key, sender: sender)
                }
                stacks[key]?.threads.append(thread)
            } else if let contact = counterpart(of: thread) {
                if people[contact.id] == nil {
                    peopleOrder.append(contact.id)
                    people[contact.id] = Person(id: contact.id, contact: contact)
                }
                people[contact.id]?.threads.append(thread)
            }
        }
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: .now)) ?? .distantPast
        var sidebar = Sidebar()
        for person in peopleOrder.compactMap({ people[$0] }) {
            if person.lastDate >= cutoff || person.unreadCount > 0 {
                sidebar.people.append(person)
            } else {
                sidebar.olderPeople.append(person)
            }
        }
        for stack in stackOrder.compactMap({ stacks[$0] }) {
            if stack.lastDate >= cutoff || stack.unreadCount > 0 {
                sidebar.stacks.append(stack)
            } else {
                sidebar.olderStacks.append(stack)
            }
        }
        return sidebar
    }

    /// Konuşmanın karşı tarafı: sana son yazan, yoksa senin yazdığın kişi
    func counterpart(of thread: MailThread) -> Contact? {
        incomingSender(of: thread) ?? thread.messages.last { !$0.isDraft }?.to.first
    }

    /// Bir kişiyle tüm yazışmalar (taslak, çöp ve spam hariç), eskiden yeniye
    func conversation(with personID: String) -> [MailThread] {
        threads
            .filter { thread in
                inScope(thread, scope) && ![.trash, .spam, .drafts].contains(thread.location)
                    && counterpart(of: thread)?.id == personID
            }
            .sorted { $0.lastDate < $1.lastDate }
    }

    /// Gelen kutusunda insanlardan biriyle konuşma seçiliyse o kişi
    var selectedPersonID: String? {
        guard folder == .inbox, !isSearching, let thread = selectedThread, thread.location == .inbox else { return nil }
        if splitInbox, feedSender(of: thread) != nil { return nil }
        return counterpart(of: thread)?.id
    }

    var selectedPerson: Person? {
        guard let id = selectedPersonID else { return nil }
        return sidebar.allPeople.first { $0.id == id }
    }

    struct InboxLayout {
        var people: [MailThread] = []
        var olderPeople: [MailThread] = []
        var stacks: [SenderStack] = []
        var olderStacks: [SenderStack] = []
    }

    /// Son iki hafta, okunmamışlar ve seçili olan öne çıkar; gerisi "eski" olarak katlanır
    var inboxLayout: InboxLayout {
        let groups = inboxGroups
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: .now)) ?? .distantPast
        let highlighted = highlightedStackID
        var layout = InboxLayout()
        for thread in groups.people {
            if thread.lastDate >= cutoff || thread.isUnread || thread.id == selectedThreadID {
                layout.people.append(thread)
            } else {
                layout.olderPeople.append(thread)
            }
        }
        for stack in groups.stacks {
            if stack.lastDate >= cutoff || stack.threads.contains(where: \.isUnread) || stack.id == highlighted {
                layout.stacks.append(stack)
            } else {
                layout.olderStacks.append(stack)
            }
        }
        return layout
    }

    /// Listede vurgulanan yığın: seçili yığın ya da seçili mailin ait olduğu yığın
    var highlightedStackID: String? {
        if let selectedStackID { return selectedStackID }
        guard splitsInbox, let id = selectedThreadID else { return nil }
        return inboxGroups.stackOfThread[id]
    }

    var selectedStack: SenderStack? {
        guard let key = selectedStackID else { return nil }
        return inboxGroups.stacks.first { $0.id == key }
    }

    /// Okunmamış maili olan kişi sayısı (liste başlığı için)
    var waitingPeopleCount: Int {
        Set(inboxGroups.people.filter(\.isUnread).compactMap { incomingSender(of: $0)?.id }).count
    }

    /// Klavye ve menü eylemlerinin hedefi: seçili mail ya da seçili yığındaki tüm mailler
    var actionTargets: [UUID] {
        if let stack = selectedStack { return stack.threads.map(\.id) }
        return selectedThreadID.map { [$0] } ?? []
    }

    /// Göndericiyi elle Akış'a ya da İnsanlar'a taşır (geri alınabilir)
    func moveSender(_ sender: Contact, toFeed feed: Bool) {
        let key = MailClassifier.senderKey(for: sender)
        let previous = senderOverrides[key]
        let stackThreads = selectedStackID == key ? selectedStack?.threads : nil
        withAnimation(.smooth(duration: 0.28)) {
            senderOverrides[key] = feed
            // İnsanlar'a taşınan yığın seçiliyse en yeni maili seçili kalır
            if let first = stackThreads?.first { selectedThreadID = first.id }
        }
        let name = sender.name.isEmpty ? sender.address : sender.name
        showToast(feed ? String(localized: "\(name) is now in Feed") : String(localized: "\(name) is now in People"), symbol: feed ? "tray.full" : "person.2", undoable: undoManager != nil)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                withAnimation(.smooth(duration: 0.28)) { store.senderOverrides[key] = previous }
            }
        }
        undoManager.setActionName(feed ? String(localized: "Move to Feed") : String(localized: "Move to People"))
    }

    // MARK: Sidebar

    func badge(for role: MailboxRole, in scope: AccountScope? = nil) -> Int {
        let list = threads(in: scope ?? self.scope, folder: role)
        switch role {
        case .inbox, .spam: return list.filter(\.isUnread).count
        case .drafts: return list.count
        default: return 0
        }
    }

    func unreadCount(for accountID: UUID) -> Int {
        badge(for: .inbox, in: .account(accountID))
    }

    var totalUnread: Int { badge(for: .inbox, in: .all) }

    struct UnreadSplit: Equatable {
        var people = 0
        var feed = 0
        var total: Int { people + feed }
    }

    /// Gelen kutusundaki okunmamışlar: insanlardan gelenler ve Akış'takiler (hesap şeridindeki rozetler için)
    func unreadSplit(in scope: AccountScope) -> UnreadSplit {
        let addresses = myAddresses
        var split = UnreadSplit()
        for thread in threads where thread.location == .inbox && thread.isUnread && inScope(thread, scope) {
            if feedSender(of: thread, myAddress: addresses[thread.accountID]) != nil {
                split.feed += 1
            } else {
                split.people += 1
            }
        }
        return split
    }

    var folderTitle: String {
        isSearching ? String(localized: "Search results") : folder.title
    }

    var scopeTitle: String {
        scopedAccount?.displayName ?? String(localized: "All accounts")
    }

    /// Listede gösterilecek gönderen satırı: "Mert, Ben, Lena"
    func senderSummary(for thread: MailThread) -> String {
        if thread.location == .drafts || (folder == .sent && !isSearching) {
            let names = thread.lastMessage?.to.map(\.displayName) ?? []
            let prefix = thread.location == .drafts ? String(localized: "Draft") : String(localized: "To")
            return names.isEmpty ? prefix : "\(prefix): " + names.joined(separator: ", ")
        }
        let messages = thread.messages.filter { !$0.isDraft }
        if messages.count == 1, let first = messages.first {
            return isFromMe(first, accountID: thread.accountID) ? String(localized: "Me") : first.from.displayName
        }
        var names: [String] = []
        for message in messages.reversed() {
            let name = isFromMe(message, accountID: thread.accountID) ? String(localized: "Me") : message.from.firstName
            if !names.contains(name) { names.append(name) }
        }
        return names.reversed().suffix(3).joined(separator: ", ")
    }

    /// Avatarda gösterilecek kişi: son gelen mailin göndericisi
    func avatarContact(for thread: MailThread) -> Contact {
        let messages = thread.messages.filter { !$0.isDraft }
        if let incoming = messages.last(where: { !isFromMe($0, accountID: thread.accountID) }) {
            return incoming.from
        }
        return thread.lastMessage?.to.first ?? thread.lastMessage?.from ?? Contact(name: "?", address: "")
    }

    // MARK: Kişiler

    func contactSuggestions(for query: String, excluding: [Contact]) -> [Contact] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let myAddresses = Set(accounts.map { $0.address.lowercased() })
        let excluded = Set(excluding.map(\.id))
        var seen = Set<String>()
        var result: [Contact] = []
        for thread in threads.sorted(by: { $0.lastDate > $1.lastDate }) {
            for message in thread.messages {
                for contact in [message.from] + message.to + message.cc {
                    let id = contact.id
                    guard !myAddresses.contains(id), !excluded.contains(id), seen.insert(id).inserted else { continue }
                    if contact.name.localizedStandardContains(query) || contact.address.localizedStandardContains(query) {
                        result.append(contact)
                    }
                }
            }
        }
        return Array(result.prefix(5))
    }

    // MARK: - Seçim ve gezinme

    func select(_ id: UUID?) {
        selectedThreadID = id
    }

    func select(item: ListItem?) {
        switch item {
        case .thread(let id): selectedThreadID = id
        case .person(let id): selectedThreadID = sidebar.allPeople.first { $0.id == id }?.latest?.id
        case .stack(let key): selectedStackID = key
        case nil:
            selectedThreadID = nil
            selectedStackID = nil
        }
    }

    /// Klavyeyle gezinme sırası: listede görünen satırlar, yukarıdan aşağı
    var navigationItems: [ListItem] {
        guard folder == .inbox, !isSearching else { return visibleThreads.map { .thread($0.id) } }
        let sidebar = sidebar
        var items = sidebar.people.map { ListItem.person($0.id) }
        if showsOlderPeople { items += sidebar.olderPeople.map { .person($0.id) } }
        items += sidebar.stacks.map { .stack($0.id) }
        if showsOlderStacks { items += sidebar.olderStacks.map { .stack($0.id) } }
        return items
    }

    /// Seçimin listedeki satırı; Akış'taki bir mail seçiliyse yığını
    private var currentItem: ListItem? {
        if let person = selectedPersonID { return .person(person) }
        if let stack = highlightedStackID { return .stack(stack) }
        return selectedThreadID.map { .thread($0) }
    }

    func selectNext() { step(1) }

    func selectPrevious() { step(-1) }

    private func step(_ offset: Int) {
        let items = navigationItems
        guard !items.isEmpty else { return }
        guard let current = currentItem, let index = items.firstIndex(of: current) else {
            select(item: items.first)
            return
        }
        if items.indices.contains(index + offset) { select(item: items[index + offset]) }
    }

    func openSelected() {
        if selectedStackID != nil {
            expandAllRequest += 1
            return
        }
        guard let id = selectedThreadID else {
            selectNext()
            return
        }
        markRead(id)
        expandAllRequest += 1
    }

    func selectAccount(at index: Int) {
        guard accounts.indices.contains(index) else { return }
        scope = .account(accounts[index].id)
    }

    func go(scope: AccountScope, folder: MailboxRole) {
        self.scope = scope
        self.folder = folder
        searchText = ""
    }

    /// Arama ikonu, / ve ⌘F aynı paleti açar
    func focusSearch() {
        showQuickSwitcher = true
    }

    /// Bildirimden veya dışarıdan bir thread'i göster
    func reveal(_ threadID: UUID) {
        guard let thread = thread(threadID) else { return }
        searchText = ""
        if !inScope(thread, scope) { scope = .all }
        if !matches(thread, folder: folder) { folder = homeFolder(of: thread) }
        unreadOnly = false
        selectedThreadID = threadID
    }

    private func scopeChanged() {
        guard !isRestoring else { return }
        selectedThreadID = nil
        selectedStackID = nil
    }

    private func selectionChanged() {
        readTask?.cancel()
        guard !isRestoring else { return }
        if let composer, composer.anchorID != selectedThreadID {
            closeComposer(save: true)
        }
        guard let id = selectedThreadID, let thread = thread(id) else { return }
        if thread.location == .drafts {
            if composer?.savedDraftThreadID != id { openDraft(thread) }
            return
        }
        guard thread.isUnread else { return }
        let behavior = ReadBehavior(rawValue: UserDefaults.standard.string(forKey: SettingsKey.readBehavior) ?? "") ?? .onSelect
        switch behavior {
        case .onSelect:
            markRead(id)
        case .delayed:
            readTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.selectedThreadID == id else { return }
                self.markRead(id)
            }
        case .manual:
            break
        }
    }

    /// Akış kartı açıldı: Elle ayarı dışında okundu sayılır
    func markOpened(_ id: UUID) {
        let behavior = ReadBehavior(rawValue: UserDefaults.standard.string(forKey: SettingsKey.readBehavior) ?? "") ?? .onSelect
        if behavior != .manual { markRead(id) }
    }

    func markRead(_ id: UUID) {
        guard thread(id)?.isUnread == true else { return }
        let before = threads
        update(id) { thread in
            for index in thread.messages.indices { thread.messages[index].isRead = true }
        }
        engine?.push(before: before, after: threads)
    }

    // MARK: - Eylemler (geri alınabilir)

    func archive(_ ids: [UUID]) {
        let targets = ids.filter { thread($0)?.location != .archive && thread($0)?.location != .drafts }
        guard !targets.isEmpty else { return }
        move(targets, to: .archive)
    }

    func trash(_ ids: [UUID]) {
        let drafts = ids.filter { thread($0)?.location == .drafts }
        if !drafts.isEmpty {
            mutate(String(localized: "Delete Draft"), toast: String(localized: "Draft deleted"), symbol: "trash") {
                if let composer, let saved = composer.savedDraftThreadID, drafts.contains(saved) { self.composer = nil }
                threads.removeAll { drafts.contains($0.id) }
                drafts.forEach { savedDrafts[$0] = nil }
            }
            return
        }
        let targets = ids.filter { thread($0)?.location != .trash }
        guard !targets.isEmpty else {
            showToast(String(localized: "Messages in the trash are deleted automatically after 30 days"), symbol: "info.circle")
            return
        }
        move(targets, to: .trash)
    }

    func move(_ ids: [UUID], to location: ThreadLocation) {
        let (name, message, symbol): (String, String, String) = switch location {
        case .archive: (String(localized: "archive.action", defaultValue: "Archive", comment: "Arşivleme eylemi; klasör adı olan Archive'dan ayrı"), String(localized: "Archived"), "archivebox")
        case .trash: (String(localized: "Move to Trash"), String(localized: "Moved to trash"), "trash")
        case .inbox: (String(localized: "Move to Inbox"), String(localized: "Moved to inbox"), "tray")
        case .spam: (String(localized: "Mark as Spam"), String(localized: "Marked as spam"), "xmark.bin")
        case .sent, .drafts: (String(localized: "Move"), String(localized: "Moved"), "folder")
        }
        let lowered = message.lowercased(with: Locale.current)
        let text = ids.count > 1 ? String(localized: "\(ids.count) messages · \(lowered)") : message
        mutate(name, toast: text, symbol: symbol) {
            for id in ids { update(id) { $0.location = location } }
        }
    }

    func toggleRead(_ ids: [UUID]) {
        let markAsRead = ids.contains { thread($0)?.isUnread == true }
        if !markAsRead { readTask?.cancel() }
        mutate(markAsRead ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"), toast: nil) {
            for id in ids {
                update(id) { thread in
                    if markAsRead {
                        for index in thread.messages.indices { thread.messages[index].isRead = true }
                    } else if let last = thread.messages.indices.last {
                        thread.messages[last].isRead = false
                    }
                }
            }
        }
    }

    func toggleStar(_ ids: [UUID]) {
        let star = ids.contains { thread($0)?.isStarred == false }
        mutate(star ? String(localized: "Star") : String(localized: "Unstar"), toast: nil) {
            for id in ids { update(id) { $0.isStarred = star } }
        }
    }

    /// Görünen listedeki tüm okunmamışları okundu yapar (geri alınabilir)
    func markAllRead() {
        let ids = threads(in: scope, folder: folder).filter(\.isUnread).map(\.id)
        guard !ids.isEmpty else { return }
        let count = ids.count
        mutate(String(localized: "Mark All as Read"), toast: String(localized: "Marked \(count) messages as read"), symbol: "envelope.open") {
            for id in ids {
                update(id) { thread in
                    for index in thread.messages.indices { thread.messages[index].isRead = true }
                }
            }
        }
    }

    func toggleUnreadOnly() {
        withAnimation(.smooth(duration: 0.25)) { unreadOnly.toggle() }
    }

    func allowRemoteImages(_ threadID: UUID) {
        update(threadID) { $0.remoteImagesAllowed = true }
    }

    // MARK: - Yazma

    func compose(to recipients: [Contact] = []) {
        closeComposer(save: true)
        if selectedThreadID != nil { selectedThreadID = nil }
        guard let account = scopedAccount ?? accounts.first else { return }
        composer = Draft(
            mode: .new,
            presentation: .sheet,
            accountID: account.id,
            to: recipients,
            body: signatureBody(for: account)
        )
    }

    func reply(_ mode: Draft.Mode, threadID: UUID? = nil, text: String = "") {
        guard let thread = thread(threadID ?? selectedThreadID),
              thread.location != .drafts,
              let account = account(thread.accountID) else { return }

        if let composer, composer.presentation == .inline, composer.threadID == thread.id {
            switchMode(of: composer, to: mode, thread: thread)
            return
        }

        closeComposer(save: true)
        if selectedThreadID != thread.id { selectedThreadID = thread.id }
        engine?.loadBodies(for: thread.id)
        composer = makeReplyDraft(mode, thread: thread, account: account, text: text)
    }

    private func makeReplyDraft(_ mode: Draft.Mode, thread: MailThread, account: Account, text: String) -> Draft {
        let (to, cc) = recipients(for: mode, thread: thread)
        let last = thread.messages.last { !$0.isDraft }
        let draft = Draft(
            mode: mode,
            presentation: .inline,
            threadID: thread.id,
            accountID: account.id,
            to: to,
            cc: cc,
            subject: subject(for: mode, original: thread.subject),
            body: signatureBody(for: account),
            attachments: mode == .forward ? (last?.attachments ?? []) : []
        )
        // Önceden yazılan metin taslağı değişmiş sayar; yazma alanı kapatılınca kaybolmaz
        if !text.isEmpty { draft.body = signatureBody(for: account, text: text) }
        return draft
    }

    // MARK: Hızlı yanıt

    /// Hızlı yanıtın gideceği kişi; taslaklarda ve yanıt kabul etmeyen (noreply) göndericilerde nil
    func quickReplyTarget(for thread: MailThread) -> Contact? {
        guard thread.location != .drafts,
              let target = recipients(for: .reply, thread: thread).0.first,
              !MailClassifier.isNoReply(target.address) else { return nil }
        return target
    }

    /// R ve Yanıtla: hızlı yanıt varsa ona odaklanır, yoksa yazma alanını açar
    func startReply() {
        guard let thread = selectedThread, thread.location != .drafts else { return }
        if composer?.threadID != thread.id, quickReplyTarget(for: thread) != nil {
            quickReplyFocusRequest += 1
        } else {
            reply(.reply)
        }
    }

    /// ⌘↩ açık yazma alanını ya da seçili maildeki hızlı yanıtı gönderir
    var canSend: Bool {
        if composer != nil { return true }
        guard let id = selectedThreadID, let text = quickReplies[id] else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendCurrent() {
        if composer != nil {
            send()
        } else if let id = selectedThreadID {
            sendQuickReply(threadID: id)
        }
    }

    func sendQuickReply(threadID: UUID) {
        guard let text = quickReplies[threadID]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let thread = thread(threadID), let account = account(thread.accountID) else { return }
        let draft = makeReplyDraft(.reply, thread: thread, account: account, text: text)
        quickReplies[threadID] = nil
        send(draft)
    }

    /// Maili okuma alanında açar ve hızlı yanıta odaklanır
    func replyQuickly(to threadID: UUID) {
        pendingQuickReplyFocus = threadID
        selectedThreadID = threadID
    }

    /// Hızlı yanıtta yazılanı tam yazma alanına taşır
    func expandQuickReply(threadID: UUID, mode: Draft.Mode = .reply) {
        let text = quickReplies[threadID] ?? ""
        quickReplies[threadID] = nil
        reply(mode, threadID: threadID, text: text)
    }

    func switchMode(of draft: Draft, to mode: Draft.Mode, thread: MailThread) {
        let (to, cc) = recipients(for: mode, thread: thread)
        draft.mode = mode
        draft.to = to
        draft.cc = cc
        draft.showCc = !cc.isEmpty
        draft.subject = subject(for: mode, original: thread.subject)
        let last = thread.messages.last { !$0.isDraft }
        if mode == .forward {
            draft.attachments = last?.attachments ?? []
        } else {
            draft.attachments.removeAll { attachment in last?.attachments.contains(attachment) == true }
        }
    }

    private func recipients(for mode: Draft.Mode, thread: MailThread) -> ([Contact], [Contact]) {
        guard let last = thread.messages.last(where: { !$0.isDraft }),
              let account = account(thread.accountID) else { return ([], []) }
        let me = account.address.lowercased()
        let fromMe = last.from.id == me
        switch mode {
        case .new, .forward:
            return ([], [])
        case .reply:
            return (fromMe ? Array(last.to.prefix(1)) : [last.from], [])
        case .replyAll:
            var seen = Set([me])
            let to = (fromMe ? last.to : [last.from] + last.to).filter { seen.insert($0.id).inserted }
            let cc = last.cc.filter { seen.insert($0.id).inserted }
            return (to, cc)
        }
    }

    private func subject(for mode: Draft.Mode, original: String) -> String {
        let base = original.replacingOccurrences(of: #"^((re|fwd?|ynt|ilt):\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
        switch mode {
        case .new: return original
        case .reply, .replyAll: return "Re: \(base)"
        case .forward: return "Fwd: \(base)"
        }
    }

    private func signatureBody(for account: Account, text: String = "") -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString(string: text, attributes: base)
        guard !account.signature.isEmpty else { return result }
        result.append(NSAttributedString(string: "\n\n", attributes: base))
        result.append(NSAttributedString(
            string: "-- \n\(account.signature)",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return result
    }

    private func openDraft(_ thread: MailThread) {
        guard let message = thread.messages.first else { return }
        let saved = savedDrafts[thread.id]
        let body = saved?.body ?? NSAttributedString(
            string: message.plainText,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        composer = Draft(
            mode: saved?.mode ?? .new,
            presentation: .sheet,
            threadID: saved?.replyToThreadID,
            savedDraftThreadID: thread.id,
            accountID: thread.accountID,
            to: message.to,
            cc: message.cc,
            subject: thread.subject,
            body: body,
            attachments: message.attachments
        )
    }

    func closeComposer(save: Bool) {
        guard let draft = composer else { return }
        composer = nil
        guard save, draft.isModified else { return }
        if draft.isBlank, let savedID = draft.savedDraftThreadID {
            threads.removeAll { $0.id == savedID }
            savedDrafts[savedID] = nil
            return
        }
        saveDraft(draft)
        showToast(String(localized: "Draft saved"), symbol: "doc.text")
    }

    /// Sheet kapanınca taslak kaydedilir; Taslaklar'dan açıldıysa seçim de bırakılır ki tekrar tıklanabilsin
    func dismissComposeSheet() {
        guard let draft = composer, draft.presentation == .sheet else { return }
        closeComposer(save: true)
        if let savedID = draft.savedDraftThreadID, selectedThreadID == savedID {
            setSelectionQuietly(nil)
        }
    }

    func discardComposer() {
        guard let draft = composer else { return }
        let before = snapshot()
        withAnimation(.smooth(duration: 0.25)) {
            composer = nil
            if let savedID = draft.savedDraftThreadID {
                threads.removeAll { $0.id == savedID }
                savedDrafts[savedID] = nil
                if selectedThreadID == savedID { setSelectionQuietly(nil) }
            }
        }
        registerUndo(before, name: String(localized: "Delete Draft"),
                     afterRestore: { [weak self] in self?.composer = draft },
                     afterReapply: { [weak self] in self?.composer = nil })
        showToast(String(localized: "Draft deleted"), symbol: "trash", undoable: true)
    }

    private func saveDraft(_ draft: Draft) {
        guard let account = account(draft.accountID) else { return }
        let message = Message(
            from: account.contact,
            to: draft.to,
            cc: draft.cc,
            date: .now,
            html: draft.body.mailHTML,
            isRead: true,
            attachments: draft.attachments,
            isDraft: true
        )
        let id: UUID
        if let savedID = draft.savedDraftThreadID, let index = threads.firstIndex(where: { $0.id == savedID }) {
            threads[index].messages = [message]
            threads[index].subject = draft.subject
            threads[index].accountID = draft.accountID
            id = savedID
        } else {
            let thread = MailThread(accountID: draft.accountID, subject: draft.subject, messages: [message], location: .drafts)
            threads.append(thread)
            id = thread.id
        }
        savedDrafts[id] = SavedDraft(mode: draft.mode, replyToThreadID: draft.threadID, body: draft.body)
    }

    func send() {
        guard let draft = composer else { return }
        send(draft)
    }

    private func send(_ draft: Draft) {
        guard let account = account(draft.accountID) else { return }
        let recipients = draft.to + draft.cc
        guard !recipients.isEmpty else {
            showToast(String(localized: "Add a recipient first"), symbol: "exclamationmark.circle", isError: true)
            return
        }
        if let invalid = recipients.first(where: { !$0.isValid }) {
            showToast(String(localized: "\(invalid.address) isn't a valid address"), symbol: "exclamationmark.circle", isError: true)
            return
        }

        let original = thread(draft.threadID)
        let replied = original?.messages.last { !$0.isDraft && !$0.isPendingSend }
        let messageIDHeader = MIMEBuilder.makeMessageID(for: account.address)
        let bodyHTML = draft.body.mailHTML
        let subject = draft.subject

        var outgoing = MIMEBuilder.Outgoing(
            from: account.contact,
            to: draft.to,
            cc: draft.cc,
            subject: subject,
            html: bodyHTML + quotedHTML(for: draft.mode, message: replied),
            plainText: draft.body.string + quotedText(for: draft.mode, message: replied),
            attachments: draft.attachments.compactMap { attachment in
                guard let url = attachment.localURL, let data = try? Data(contentsOf: url) else { return nil }
                return MIMEBuilder.OutgoingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data)
            },
            inReplyTo: nil,
            references: [],
            messageID: messageIDHeader,
            date: .now
        )
        if draft.mode == .reply || draft.mode == .replyAll, let replied, let header = replied.messageIDHeader {
            outgoing.inReplyTo = header
            outgoing.references = replied.references + [header]
        }

        let before = snapshot()
        let message = Message(
            messageIDHeader: messageIDHeader,
            inReplyTo: outgoing.inReplyTo,
            references: outgoing.references,
            subject: subject,
            from: account.contact,
            to: draft.to,
            cc: draft.cc,
            date: .now,
            html: bodyHTML,
            isRead: true,
            attachments: draft.attachments,
            isPendingSend: true
        )
        let replyIndex = draft.mode == .forward ? nil : draft.threadID.flatMap { id in threads.firstIndex { $0.id == id } }
        let targetThreadID = replyIndex.map { threads[$0].id } ?? UUID()
        withAnimation(.smooth(duration: 0.3)) {
            if composer === draft { composer = nil }
            if let savedID = draft.savedDraftThreadID {
                threads.removeAll { $0.id == savedID }
                savedDrafts[savedID] = nil
            }
            if let index = threads.firstIndex(where: { $0.id == targetThreadID }) {
                threads[index].messages.append(message)
                if draft.savedDraftThreadID != nil { setSelectionQuietly(targetThreadID) }
            } else {
                threads.append(MailThread(id: targetThreadID, accountID: account.id, subject: subject, messages: [message], location: .sent))
                if draft.savedDraftThreadID != nil { setSelectionQuietly(nil) }
            }
        }
        let threadRemoteID = draft.mode == .forward ? nil : original?.remoteID
        engine?.scheduleSend(messageID: message.id, threadID: targetThreadID, accountID: account.id, outgoing: outgoing, threadRemoteID: threadRemoteID)

        // Geri al yalnızca gönderim henüz başlamadıysa çalışır
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    if store.engine?.cancelSend(messageID: message.id) ?? true {
                        withAnimation(.smooth(duration: 0.28)) { store.restore(before) }
                        store.composer = draft
                    } else {
                        store.showToast(String(localized: "Message sent and can no longer be undone"), symbol: "paperplane")
                    }
                }
            }
            undoManager.setActionName(String(localized: "Send"))
        }
        showToast(isOffline ? String(localized: "Will send when you're back online") : String(localized: "Sending…"), symbol: "paperplane", undoable: true)
    }

    private func quotedHTML(for mode: Draft.Mode, message: Message?) -> String {
        guard let message, mode != .new else { return "" }
        let date = message.date.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(Fmt.locale))
        let sender = HTMLText.escape(message.from.name.isEmpty ? message.from.address : "\(message.from.name) <\(message.from.address)>")
        let original = message.isBodyLoaded ? message.html : MIME.htmlFromPlainText(message.plainText)
        if mode == .forward {
            let to = HTMLText.escape(message.to.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", "))
            let subject = HTMLText.escape(message.subject ?? "")
            return "<br><br><div>---------- \(String(localized: "Forwarded message")) ----------<br>\(String(localized: "From")): \(sender)<br>\(String(localized: "Date")): \(date)<br>\(String(localized: "Subject")): \(subject)<br>\(String(localized: "To")): \(to)</div><br>\(original)"
        }
        return "<br><br><div>\(String(localized: "On \(date), \(sender) wrote:"))</div><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(original)</blockquote>"
    }

    private func quotedText(for mode: Draft.Mode, message: Message?) -> String {
        guard let message, mode != .new else { return "" }
        let sender = message.from.name.isEmpty ? message.from.address : "\(message.from.name) <\(message.from.address)>"
        if mode == .forward {
            return "\n\n---------- \(String(localized: "Forwarded message")) ----------\n\(String(localized: "From")): \(sender)\n\(String(localized: "Subject")): \(message.subject ?? "")\n\n\(message.plainText)"
        }
        let quoted = message.plainText.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return "\n\n\(String(localized: "\(sender) wrote:"))\n\(quoted)"
    }

    /// Gönderim tamamlandı
    func markSent(messageID: UUID, threadID: UUID, result: SentResult) {
        update(threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[index].isPendingSend = false
            thread.messages[index].remoteID = result.remoteID
            if thread.remoteID == nil, let remote = result.threadRemoteID { thread.remoteID = remote }
        }
        showToast(String(localized: "Message sent"), symbol: "checkmark.circle")
    }

    /// Gönderilemedi: mail kaybolmasın diye taslaklara geri konur
    func markSendFailed(messageID: UUID, threadID: UUID, error: Error) {
        guard let thread = thread(threadID), let message = thread.messages.first(where: { $0.id == messageID }) else { return }
        withAnimation(.smooth) {
            update(threadID) { $0.messages.removeAll { $0.id == messageID } }
            if self.thread(threadID)?.messages.isEmpty == true { threads.removeAll { $0.id == threadID } }
            var draftMessage = message
            draftMessage.isPendingSend = false
            draftMessage.isDraft = true
            let draftThread = MailThread(accountID: thread.accountID, subject: message.subject ?? thread.subject, messages: [draftMessage], location: .drafts)
            threads.append(draftThread)
            let body = NSAttributedString(string: message.plainText, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            savedDrafts[draftThread.id] = SavedDraft(mode: .new, replyToThreadID: thread.location == .sent ? nil : thread.id, body: body)
        }
        showToast(String(localized: "Couldn't send; saved to drafts: \(error.localizedDescription)"), symbol: "exclamationmark.triangle", isError: true)
    }

    // MARK: - Hesaplar

    func addAccount(kind: AccountKind, address: String, senderName: String, displayName: String, color: AccountColor, credentials: IMAPCredentials) {
        let account = Account(
            id: UUID(), kind: kind, address: address,
            displayName: displayName, senderName: senderName,
            color: color, status: .syncing, signature: senderName
        )
        do {
            try Keychain.setCodable(credentials, for: .imapPassword(account.id))
        } catch {
            showToast(String(localized: "Couldn't save sign-in details to the Keychain"), symbol: "exclamationmark.triangle", isError: true)
            return
        }
        withAnimation(.smooth) { accounts.append(account) }
        showToast(String(localized: "\(address) added, downloading mail"), symbol: "checkmark.circle")
        engine?.accountAdded(account.id)
    }

    /// Yeniden giriş sonrası yeni bilgileri kaydeder ve senkronu yeniden başlatır
    func updateCredentials(_ accountID: UUID, _ credentials: IMAPCredentials) throws {
        try Keychain.setCodable(credentials, for: .imapPassword(accountID))
        engine?.reconnect(accountID)
        if let account = account(accountID) {
            showToast(String(localized: "\(account.address) reconnected"), symbol: "checkmark.circle")
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        withAnimation { accounts.move(fromOffsets: source, toOffset: destination) }
    }

    func updateAccount(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
    }

    func removeAccount(_ id: UUID) {
        guard let account = account(id) else { return }
        mutate(String(localized: "Remove Account"), toast: String(localized: "\(account.address) removed"), symbol: "person.crop.circle.badge.minus") {
            if composer?.accountID == id { composer = nil }
            if scope == .account(id) { scope = .all }
            accounts.removeAll { $0.id == id }
            let removed = Set(threads.filter { $0.accountID == id }.map(\.id))
            threads.removeAll { removed.contains($0.id) }
            removed.forEach { savedDrafts[$0] = nil }
        }
        engine?.accountRemoved(id)
        // Geri alma süresi geçince Keychain'deki giriş bilgileri silinir
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.account(id) == nil else { return }
            Keychain.deleteAll(for: id)
        }
    }

    /// Tüm hesaplardaki toplam indirme ilerlemesi, mail sayısıyla ağırlıklı; indirme yoksa nil
    var overallSyncProgress: Double? {
        let total = syncProgress.values.reduce(0) { $0 + $1.total }
        guard total > 0, syncProgress.values.contains(where: { !$0.isComplete }) else { return nil }
        return Double(syncProgress.values.reduce(0) { $0 + $1.done }) / Double(total)
    }

    /// Şu an indirme yapan hesap sayısı
    var downloadingAccountCount: Int {
        syncProgress.values.filter { !$0.isComplete }.count
    }

    var accountsNeedingReauth: [Account] {
        accounts.filter { $0.status == .needsReauth }
    }

    var accountsWithErrors: [Account] {
        accounts.filter { if case .failed = $0.status { true } else { false } }
    }

    // MARK: - Senkron

    func refresh() {
        engine?.syncAll(notify: true, visible: true)
    }

    func loadBodies(for threadID: UUID) {
        engine?.loadBodies(for: threadID)
    }

    /// Bildirim gönderilecek yeni mail
    struct Arrival {
        var threadID: UUID
        var subject: String
        var message: Message
    }

    /// Sunucudan gelen sonucu yerel veriyle birleştirir; gelen kutusuna yeni düşen okunmamış mailleri döner
    @discardableResult
    func applySync(accountID: UUID, output: SyncOutput, protecting protected: Set<UUID>) -> [Arrival] {
        let existing = threads.filter { $0.accountID == accountID }
        let knownMessageIDs = Set(existing.flatMap(\.messages).map(\.id))
        let knownHeaders = Set(existing.flatMap(\.messages).compactMap(\.messageIDHeader))
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var incomingRemoteIDs = Set<String>()
        var incomingHeaders = Set<String>()
        for thread in output.threads {
            for message in thread.messages {
                if let remote = message.remoteID { incomingRemoteIDs.insert(remote) }
                if let header = message.messageIDHeader { incomingHeaders.insert(header) }
            }
        }
        func isOnServer(_ message: Message) -> Bool {
            (message.remoteID.map(incomingRemoteIDs.contains) ?? false) || (message.messageIDHeader.map(incomingHeaders.contains) ?? false)
        }
        func isLocalOnly(_ message: Message) -> Bool {
            message.isPendingSend || (message.remoteID == nil && message.uid == nil && !message.isDraft)
        }

        var arrivals: [Arrival] = []
        var merged: [MailThread] = []
        for var thread in output.threads {
            // Yeni konuşmalar ve mevcut konuşmalara gelen yanıtlar. Okunmamış olması yeter:
            // Posta'dan ya da başka cihazdan gönderdiklerin okunmuş olarak kaydedilir.
            if thread.location == .inbox {
                for message in thread.messages where !message.isRead && !knownMessageIDs.contains(message.id)
                    && !(message.messageIDHeader.map(knownHeaders.contains) ?? false) {
                    arrivals.append(Arrival(threadID: thread.id, subject: thread.displaySubject, message: message))
                }
            }
            if let old = existingByID[thread.id] {
                thread.remoteImagesAllowed = old.remoteImagesAllowed
                let oldMessages = Dictionary(old.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                thread.messages = thread.messages.map { incoming in
                    var message = incoming
                    if let previous = oldMessages[message.id] {
                        if !message.isBodyLoaded && previous.isBodyLoaded {
                            message.html = previous.html
                            message.plainText = previous.plainText
                            message.preview = previous.preview
                            message.attachments = previous.attachments
                            message.isBodyLoaded = true
                        }
                        // Sunucuya henüz iletilmemiş yerel değişiklik ezilmez
                        if protected.contains(thread.id) { message.isRead = previous.isRead }
                    }
                    return message
                }
                if protected.contains(thread.id) {
                    thread.location = old.location
                    thread.isStarred = old.isStarred
                }
                let localOnly = old.messages.filter { isLocalOnly($0) && !isOnServer($0) }
                if !localOnly.isEmpty {
                    thread.messages = (thread.messages + localOnly).sorted { $0.date < $1.date }
                }
            }
            merged.append(thread)
        }

        let incomingIDs = Set(output.threads.map(\.id))
        for old in existing where !incomingIDs.contains(old.id) {
            if old.location == .drafts {
                merged.append(old)
                continue
            }
            if output.removedThreadIDs.contains(old.id) { continue }
            var kept = old
            if output.isFullSnapshot {
                kept.messages = old.messages.filter { isLocalOnly($0) && !isOnServer($0) }
            } else {
                kept.messages.removeAll { isLocalOnly($0) && isOnServer($0) }
            }
            if !kept.messages.isEmpty { merged.append(kept) }
        }

        let newByID = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard newByID != existingByID else { return [] }

        let previousSelection = selectedThread
        withAnimation(.smooth(duration: 0.25)) {
            threads = threads.filter { $0.accountID != accountID } + merged
        }
        // Seçili thread yeniden gruplandıysa aynı mesajları içeren thread seçili kalır
        if let previousSelection, previousSelection.accountID == accountID, newByID[previousSelection.id] == nil {
            let headers = Set(previousSelection.messages.compactMap(\.messageIDHeader))
            let replacement = merged.first { thread in thread.messages.contains { $0.messageIDHeader.map(headers.contains) ?? false } }
            setSelectionQuietly(replacement?.id)
        }
        return arrivals
    }

    func applyBody(_ body: FetchedBody, messageID: UUID, threadID: UUID) {
        update(threadID) { thread in
            guard let index = thread.messages.firstIndex(where: { $0.id == messageID }) else { return }
            thread.messages[index].applyBody(html: body.html, attachments: body.attachments)
        }
    }

    func markBodyFailed(messageID: UUID, threadID: UUID, error: Error) {
        if selectedThreadID == threadID {
            showToast(String(localized: "Couldn't download the message: \(error.localizedDescription)"), symbol: "exclamationmark.triangle", isError: true)
        }
    }

    /// Yerel önbelleği temizler; hesaplar ve taslaklar kalır, mailler yeniden indirilir
    func eraseLocalCache() {
        setSelectionQuietly(nil)
        threads.removeAll { $0.location != .drafts }
        persistNow()
        engine?.eraseAndResync()
        undoManager?.removeAllActions()
    }

    // MARK: - Altyapı: mutasyon, geri al, toast

    private func update(_ id: UUID, _ change: (inout MailThread) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[index])
    }

    private func setSelectionQuietly(_ id: UUID?) {
        isRestoring = true
        selectedThreadID = id
        isRestoring = false
    }

    private struct Snapshot {
        var accounts: [Account]
        var threads: [MailThread]
        var savedDrafts: [UUID: SavedDraft]
        var scope: AccountScope
        var folder: MailboxRole
        var selectedThreadID: UUID?
        var selectedStackID: String?
    }

    private func snapshot() -> Snapshot {
        Snapshot(accounts: accounts, threads: threads, savedDrafts: savedDrafts,
                 scope: scope, folder: folder, selectedThreadID: selectedThreadID, selectedStackID: selectedStackID)
    }

    private func restore(_ snapshot: Snapshot) {
        isRestoring = true
        defer { isRestoring = false }
        accounts = snapshot.accounts
        threads = snapshot.threads
        savedDrafts = snapshot.savedDrafts
        scope = snapshot.scope
        folder = snapshot.folder
        selectedThreadID = snapshot.selectedThreadID
        selectedStackID = snapshot.selectedStackID
    }

    /// Değişikliği uygular, geri alma kaydeder ve görünür listeden çıkan seçili mailin yerine sıradakini seçer.
    private func mutate(_ name: String, toast message: String?, symbol: String? = nil, _ change: () -> Void) {
        let before = snapshot()
        let oldItems = navigationItems
        let oldCurrent = currentItem
        withAnimation(.smooth(duration: 0.28)) {
            change()
            reselectIfHidden(oldItems: oldItems, oldCurrent: oldCurrent)
        }
        engine?.push(before: before.threads, after: threads)
        registerUndo(before, name: name)
        if let message {
            showToast(message, symbol: symbol, undoable: undoManager != nil)
        }
    }

    /// Seçili mail ya da yığın listeden çıktıysa yerine sıradaki satır seçilir
    private func reselectIfHidden(oldItems: [ListItem], oldCurrent: ListItem?) {
        guard let oldCurrent else { return }
        if let id = selectedThreadID, visibleThreads.contains(where: { $0.id == id }) { return }
        let items = navigationItems
        if let stack = selectedStackID, items.contains(.stack(stack)) { return }
        // Seçili mail arşivlendi ama yığını duruyorsa yığın seçilir
        if items.contains(oldCurrent) {
            select(item: oldCurrent)
            return
        }
        select(item: Self.neighbor(of: oldCurrent, in: oldItems, visible: Set(items)))
    }

    private static func neighbor<T: Hashable>(of item: T, in order: [T], visible: Set<T>) -> T? {
        guard let index = order.firstIndex(of: item) else { return nil }
        if let next = order[(index + 1)...].first(where: visible.contains) { return next }
        return order[..<index].reversed().first(where: visible.contains)
    }

    private func registerUndo(_ before: Snapshot, name: String, afterRestore: (() -> Void)? = nil, afterReapply: (() -> Void)? = nil) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                let current = store.snapshot()
                withAnimation(.smooth(duration: 0.28)) { store.restore(before) }
                store.engine?.push(before: current.threads, after: store.threads)
                afterRestore?()
                store.registerUndo(current, name: name, afterRestore: afterReapply, afterReapply: afterRestore)
            }
        }
        undoManager.setActionName(name)
    }

    func undo() {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        withAnimation(.snappy) { toast = nil }
    }

    func showToast(_ message: String, symbol: String? = nil, undoable: Bool = false, isError: Bool = false) {
        let toast = Toast(message: message, symbol: symbol, undoable: undoable, isError: isError)
        withAnimation(.snappy(duration: 0.25)) { self.toast = toast }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undoable ? 5 : 3))
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            withAnimation(.smooth(duration: 0.3)) { self.toast = nil }
        }
    }

    // MARK: Abonelikten çıkma

    func isUnsubscribed(_ stack: SenderStack) -> Bool { unsubscribedSenders[stack.id] != nil }

    /// Göndericiden çıkar; istenirse mailleri de arşivler
    func unsubscribe(_ stack: SenderStack, archive: Bool) {
        let name = stack.name
        let ids = stack.threads.map(\.id)
        Task {
            do {
                // Örnek veri modunda ağ yok; yalnızca sonuç gösterilir
                let outcome = try await engine?.unsubscribe(from: stack) ?? .done
                switch outcome {
                case .done:
                    unsubscribedSenders[stack.id] = .now
                    if archive { self.archive(ids) }
                    showToast(String(localized: "Unsubscribed from \(name)"), symbol: "checkmark.circle")
                case .openedInBrowser:
                    unsubscribedSenders[stack.id] = .now
                    if archive { self.archive(ids) }
                    showToast(String(localized: "Finish unsubscribing on \(name)'s page in your browser"), symbol: "safari")
                case .unavailable:
                    showToast(String(localized: "\(name) doesn't offer a way to unsubscribe"), symbol: "exclamationmark.triangle", isError: true)
                }
            } catch {
                showToast(String(localized: "Couldn't unsubscribe: \(error.localizedDescription)"), symbol: "exclamationmark.triangle", isError: true)
            }
        }
    }

    func dismissToast() {
        withAnimation(.smooth(duration: 0.2)) { toast = nil }
    }
}
