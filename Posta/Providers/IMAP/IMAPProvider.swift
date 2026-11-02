import Foundation
import os

nonisolated struct IMAPCredentials: Codable, Sendable {
    var username: String
    var password: String
}

/// IMAP/SMTP sunucu ayarları. iCloud ve Gmail aynı istemciyi kullanır, farkları burada.
nonisolated struct IMAPServer: Sendable {
    var imapHost: String
    var smtpHost: String
    /// iCloud SMTP gönderilenleri saklamaz, Gönderilenler'e elle eklenir; Gmail kendisi saklar
    var appendsSentCopy: Bool
    /// Adresin @ öncesiyle de giriş denenir (iCloud'da bazı eski hesaplar)
    var triesLocalPartLogin: Bool

    static let icloud = IMAPServer(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com", appendsSentCopy: true, triesLocalPartLogin: true)
    static let gmail = IMAPServer(imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com", appendsSentCopy: false, triesLocalPartLogin: false)

    static func `for`(_ kind: AccountKind) -> IMAPServer {
        kind == .gmail ? .gmail : .icloud
    }
}

nonisolated struct IMAPSyncState: Codable, Sendable {
    struct MailboxState: Codable, Sendable {
        var uidValidity: UInt32
        /// Klasördeki takip edilen UID → Message-ID (kopyalar dahil). Gmail'de aynı mail hem Gelen Kutusu'nda
        /// hem Tüm Postalar'da durur; ekranda tek kopya tutulsa da sunucudaki her kopya burada bilinir,
        /// böylece aynı mail her senkronda yeniden indirilmez.
        var uids: [UInt32: String]?
        /// Klasör değişmediyse arama ve bayrak sorguları atlanır
        var uidNext: UInt32?
        var exists: Int?
        var highestModSeq: UInt64?
    }

    var mailboxes: [String: MailboxState] = [:]
}

/// IMAP (993, TLS) ile okuma, SMTP (587, STARTTLS) ile gönderim. iCloud ve Gmail (uygulama şifresiyle).
actor IMAPProvider: MailProvider {
    private let server: IMAPServer
    private let accountID: UUID
    private let address: String
    private let credentials: IMAPCredentials
    /// Senkron ve eylemler bir bağlantıda, gövde indirme ayrı bağlantıda; biri diğerini bekletmez
    private let syncClient: IMAPClient
    private let fetchClient: IMAPClient
    /// Gelen kutusunu IDLE ile dinleyen üçüncü bağlantı
    private let idleClient: IMAPClient
    private var roles: [ThreadLocation: String] = [:]
    /// Gmail'in "Tüm Postalar" klasörü; buradan taşımak maili siler, bu yüzden yalnızca kopyalanır
    private var allMailMailbox: String?

    private static let initialWindowDays = 90
    private static let limits: [(ThreadLocation, Int)] = [(.inbox, 500), (.archive, 500), (.sent, 300), (.spam, 50), (.trash, 50)]
    private static let partialBytes = 64 * 1024

    init(server: IMAPServer, accountID: UUID, address: String, credentials: IMAPCredentials) {
        self.server = server
        self.accountID = accountID
        self.address = address
        self.credentials = credentials
        syncClient = IMAPClient(host: server.imapHost, username: credentials.username, password: credentials.password)
        fetchClient = IMAPClient(host: server.imapHost, username: credentials.username, password: credentials.password)
        idleClient = IMAPClient(host: server.imapHost, username: credentials.username, password: credentials.password)
    }

    /// Hesap eklerken bağlantıyı dener; çalışan kullanıcı adını döner
    static func testLogin(server: IMAPServer, address: String, password: String) async throws -> String {
        var candidates = [address]
        if server.triesLocalPartLogin, let local = address.split(separator: "@").first, local.count < address.count {
            candidates.append(String(local))
        }
        var lastError: Error = IMAPError.authenticationFailed("")
        for username in candidates {
            let client = IMAPClient(host: server.imapHost, username: username, password: password)
            do {
                try await client.connect()
                await client.disconnect()
                return username
            } catch let error as IMAPError {
                lastError = error
                if case .authenticationFailed = error { continue }
                throw error
            }
        }
        throw lastError
    }

    func close() async {
        await syncClient.disconnect()
        await fetchClient.disconnect()
        await idleClient.disconnect()
    }

    // MARK: - Anlık bildirim (IDLE)

    /// Sunucular IDLE bağlantısını 29 dakikada keser; daha önce yenilenir
    private static let idleDuration: TimeInterval = 25 * 60

    func waitForChanges() async throws -> Bool {
        do {
            try await idleClient.connect()
            guard await idleClient.capabilities.contains("IDLE") else {
                // IDLE desteklenmiyorsa periyodik senkron yeterli
                try await Task.sleep(for: .seconds(Self.idleDuration))
                return false
            }
            if roles.isEmpty { try await resolveRoles(using: idleClient) }
            try await idleClient.select(roles[.inbox] ?? "INBOX")
            return try await idleClient.idle(maxDuration: Self.idleDuration)
        } catch {
            // Kopan bağlantı bir sonraki turda baştan kurulur
            await idleClient.disconnect()
            throw error
        }
    }

    // MARK: - Senkron

    func sync(existing: [Message], state: Data?, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> SyncOutput {
        try await withReconnect(syncClient) {
            try await self.performSync(existing: existing, state: state, progress: progress)
        }
    }

    /// Üç aşama: (1) her klasörde sunucudaki UID'ler ve Message-ID'leri öğrenilir, bayraklar güncellenir;
    /// (2) yalnızca elde hiçbir kopyası olmayan mailler indirilmek üzere seçilir; (3) seçilenler indirilir.
    private func performSync(existing: [Message], state stateData: Data?, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> SyncOutput {
        var state = stateData.flatMap { try? JSONDecoder().decode(IMAPSyncState.self, from: $0) } ?? IMAPSyncState()
        // Klasör listesi bağlantı başına bir kez alınır
        if roles.isEmpty { try await resolveRoles(using: syncClient) }

        var cache: [String: [UInt32: Message]] = [:]
        var existingByHeader: [String: Message] = [:]
        for message in existing where !message.isDraft && !message.isPendingSend {
            if let mailbox = message.mailbox, let uid = message.uid {
                cache[mailbox, default: [:]][uid] = message
            }
            if let header = message.messageIDHeader { existingByHeader[header] = message }
        }

        let since = Calendar.current.date(byAdding: .day, value: -Self.initialWindowDays, to: .now) ?? .now
        var tracked: [String: [UInt32: String]] = [:]
        var kept: [String: [UInt32: Message]] = [:]

        // 1. Aşama: sunucudaki durumu öğren
        for (location, limit) in Self.limits {
            guard let mailbox = roles[location] else { continue }
            let mailboxStarted = Date.now
            let info = try await syncClient.select(mailbox)
            let known = state.mailboxes[mailbox]
            var mode = "boş"
            var map: [UInt32: String] = [:]
            var messages = known?.uidValidity == info.uidValidity ? (cache[mailbox] ?? [:]) : [:]

            let unchanged = known?.uidValidity == info.uidValidity && known?.uidNext == info.uidNext && known?.exists == info.exists
            if info.exists == 0 {
                messages = [:]
            } else if unchanged, let knownUIDs = known?.uids, let modSeq = info.highestModSeq, known?.highestModSeq == modSeq {
                // Klasörde hiçbir değişiklik yok (yeni mail, silme, bayrak): sunucuya başka komut gönderilmez
                mode = "değişmedi"
                map = knownUIDs
                messages = messages.filter { map[$0.key] != nil }
            } else if unchanged, let knownUIDs = known?.uids, info.highestModSeq == nil {
                // CONDSTORE yok ama yeni/silinen mail de yok: yalnızca bayraklar
                mode = "bayrak"
                map = knownUIDs
                messages = messages.filter { map[$0.key] != nil }
                try await refreshFlags(of: &messages)
            } else if let known, known.uidValidity == info.uidValidity, let knownUIDs = known.uids, !knownUIDs.isEmpty {
                // Artımlı: silinenleri çıkar, bayrakları güncelle, yeni UID'lerin yalnızca Message-ID'sini al
                mode = "artımlı"
                let minimum = knownUIDs.keys.min() ?? 1
                let maximum = knownUIDs.keys.max() ?? 0
                let present = Set(try await syncClient.uidSearch("UID \(minimum):*"))
                map = knownUIDs.filter { present.contains($0.key) }
                messages = messages.filter { present.contains($0.key) }
                try await refreshFlags(of: &messages)
                let newUIDs = Array(present.filter { $0 > maximum }.sorted().suffix(limit))
                for (uid, remote) in try await fetchHeaders(newUIDs) {
                    map[uid] = remote.header
                }
            } else {
                // İlk senkron, UIDVALIDITY değişti veya eski biçimdeki durum: pencere içindeki UID'ler
                mode = "tam"
                let uids = Array(try await syncClient.uidSearch("SINCE \(IMAPClient.searchDate(since))").sorted().suffix(limit))
                let headers = try await fetchHeaders(uids)
                map = headers.mapValues(\.header)
                messages = messages.filter { headers[$0.key] != nil }
                for (uid, remote) in headers {
                    messages[uid]?.isRead = remote.flags.contains("\\seen")
                    messages[uid]?.isFlagged = remote.flags.contains("\\flagged")
                }
            }

            // Sınırı aşan en eski mailler düşer
            if map.count > limit {
                for uid in map.keys.sorted().prefix(map.count - limit) {
                    map[uid] = nil
                    messages[uid] = nil
                }
            }

            // Önceki sürümde indirilen maillerin otomatik olup olmadığı bir kez, yalnızca birkaç başlıkla öğrenilir
            let unclassified = messages.compactMap { $0.value.automated == nil ? $0.key : nil }
            if !unclassified.isEmpty {
                if location == .sent {
                    for uid in unclassified { messages[uid]?.automated = false }
                } else {
                    for (uid, automated) in try await fetchAutomation(unclassified) {
                        guard let text = messages[uid]?.plainText else { continue }
                        messages[uid]?.automated = automated || MailClassifier.isAutomatedContent(text)
                    }
                }
            }
            tracked[mailbox] = map
            kept[mailbox] = messages
            Log.sync.debug("Klasör \(location.rawValue, privacy: .public) [\(mode, privacy: .public)]: \(info.exists, privacy: .public) mail sunucuda, \(map.count, privacy: .public) takipte, \(Date.now.timeIntervalSince(mailboxStarted), format: .fixed(precision: 1), privacy: .public) sn")
            state.mailboxes[mailbox] = IMAPSyncState.MailboxState(
                uidValidity: info.uidValidity,
                uids: map,
                uidNext: info.uidNext,
                exists: info.exists,
                highestModSeq: info.highestModSeq
            )
        }

        // 2. Aşama: elde kopyası olmayanları seç (öncelik: Gelen Kutusu > Gönderilenler > Arşiv > Spam > Çöp)
        var covered = Set(kept.values.flatMap(\.values).compactMap(\.messageIDHeader))
        var plan: [(mailbox: String, uids: [UInt32])] = []
        for location in [ThreadLocation.inbox, .sent, .archive, .spam, .trash] {
            guard let mailbox = roles[location], let map = tracked[mailbox] else { continue }
            var needed: [UInt32] = []
            for (uid, header) in map.sorted(by: { $0.key < $1.key }) where kept[mailbox]?[uid] == nil {
                if !header.isEmpty && covered.contains(header) { continue }
                if !header.isEmpty, var reused = existingByHeader[header] {
                    // Başka klasörden taşınmış: içerik zaten elde, yeniden indirilmez
                    reused.id = UUID.stable("icloud|\(accountID)|\(mailbox)|\(header)")
                    reused.mailbox = mailbox
                    reused.uid = uid
                    kept[mailbox, default: [:]][uid] = reused
                } else {
                    needed.append(uid)
                }
                if !header.isEmpty { covered.insert(header) }
            }
            if !needed.isEmpty { plan.append((mailbox, needed)) }
        }

        // 3. Aşama: indir
        let total = plan.reduce(0) { $0 + $1.uids.count }
        var done = 0
        if total > 0 { progress(0, total) }
        for item in plan {
            try await syncClient.select(item.mailbox)
            for chunk in item.uids.chunked(into: 25) {
                for message in try await fetchMessages(chunk, mailbox: item.mailbox) {
                    if let uid = message.uid { kept[item.mailbox, default: [:]][uid] = message }
                }
                done += chunk.count
                progress(done, total)
            }
        }
        Log.sync.info("IMAP planı: \(total, privacy: .public) mail indirildi")

        let all = kept.values.flatMap(\.values)
        let threads = ThreadBuilder.build(all, accountID: accountID, roles: roles)
        return SyncOutput(threads: threads, isFullSnapshot: true, removedThreadIDs: [], state: try? JSONEncoder().encode(state))
    }

    /// Seçili klasördeki mailler için okundu ve yıldız bayrakları
    private func refreshFlags(of messages: inout [UInt32: Message]) async throws {
        for chunk in Array(messages.keys).chunked(into: 400) {
            for item in try await syncClient.uidFetch(chunk, items: "(UID FLAGS)") {
                messages[item.uid]?.isRead = item.flags.contains("\\seen")
                messages[item.uid]?.isFlagged = item.flags.contains("\\flagged")
            }
        }
    }

    /// Seçili klasördeki UID'lerin yalnızca Message-ID başlığı ve bayrakları (gövde indirilmez, çok hafif)
    private func fetchHeaders(_ uids: [UInt32]) async throws -> [UInt32: (header: String, flags: Set<String>)] {
        var result: [UInt32: (header: String, flags: Set<String>)] = [:]
        for chunk in uids.chunked(into: 250) {
            for item in try await syncClient.uidFetch(chunk, items: "(UID FLAGS BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])") {
                let header = item.body.flatMap { MIME.parse($0).header("message-id") }.map(MIME.cleanMessageID) ?? ""
                result[item.uid] = (header, item.flags)
            }
        }
        return result
    }

    /// Seçili klasördeki UID'lerin otomatik gönderim işaretleri (yalnızca ilgili başlıklar)
    private func fetchAutomation(_ uids: [UInt32]) async throws -> [UInt32: Bool] {
        var result: [UInt32: Bool] = [:]
        for chunk in uids.chunked(into: 250) {
            for item in try await syncClient.uidFetch(chunk, items: "(UID BODY.PEEK[HEADER.FIELDS (\(MailClassifier.headerFields))])") {
                let part = item.body.map(MIME.parse)
                let from = part.flatMap { MIME.addresses($0.header("from") ?? "").first }
                result[item.uid] = MailClassifier.isAutomated(header: { part?.header($0) }, from: from)
            }
        }
        return result
    }

    private func resolveRoles(using client: IMAPClient) async throws {
        let mailboxes = try await client.list()
        var found: [ThreadLocation: String] = [:]
        var allMail: String?
        for mailbox in mailboxes where !mailbox.attributes.contains("\\noselect") {
            let name = mailbox.name
            let lower = name.lowercased()
            if lower == "inbox" { found[.inbox] = name }
            if mailbox.attributes.contains("\\sent") || lower == "sent messages" || lower == "sent" { found[.sent] = found[.sent] ?? name }
            if mailbox.attributes.contains("\\trash") || lower == "deleted messages" || lower == "trash" { found[.trash] = found[.trash] ?? name }
            if mailbox.attributes.contains("\\junk") || lower == "junk" || lower == "spam" { found[.spam] = found[.spam] ?? name }
            if mailbox.attributes.contains("\\archive") || lower == "archive" { found[.archive] = found[.archive] ?? name }
            if mailbox.attributes.contains("\\all") {
                // Gmail: arşivlenen mailler "Tüm Postalar"da durur
                found[.archive] = name
                allMail = name
            }
            if mailbox.attributes.contains("\\drafts") || lower == "drafts" { found[.drafts] = found[.drafts] ?? name }
        }
        if found[.inbox] == nil { found[.inbox] = "INBOX" }
        roles = found
        allMailMailbox = allMail
    }

    private func fetchMessages(_ uids: [UInt32], mailbox: String) async throws -> [Message] {
        var messages: [Message] = []
        for chunk in uids.chunked(into: 25) {
            let items = try await syncClient.uidFetch(chunk, items: "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[]<0.\(Self.partialBytes)>)")
            for item in items {
                messages.append(makeMessage(item, mailbox: mailbox))
            }
        }
        return messages
    }

    private func makeMessage(_ item: IMAPClient.FetchItem, mailbox: String) -> Message {
        let raw = item.body ?? Data()
        let parsed = MIME.message(from: raw)
        let isComplete = item.size == 0 || raw.count >= item.size
        let key = parsed.messageID ?? "uid-\(item.uid)"
        let id = UUID.stable("icloud|\(accountID)|\(mailbox)|\(key)")
        let attachments = isComplete ? AttachmentStore.save(parsed.attachments, messageID: id) : []
        var message = Message(
            id: id,
            mailbox: mailbox,
            uid: item.uid,
            messageIDHeader: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            subject: parsed.subject,
            from: parsed.from ?? Contact(name: "", address: ""),
            to: parsed.to,
            cc: parsed.cc,
            date: parsed.date ?? item.internalDate ?? .now,
            // Yarım inen gövde saklanmaz; tam gövde mail açılınca iner
            html: isComplete ? parsed.html : "",
            isRead: item.flags.contains("\\seen"),
            isFlagged: item.flags.contains("\\flagged"),
            attachments: attachments,
            hasAttachmentHint: parsed.hasAttachments,
            isBodyLoaded: isComplete
        )
        if !isComplete {
            // Önizleme ve arama için kısa metin yeter
            let plain = String(HTMLText.plain(from: parsed.html).prefix(2000))
            message.plainText = plain
            message.preview = Message.makePreview(plain)
        }
        message.automated = parsed.isAutomated || MailClassifier.isAutomatedContent(message.plainText)
        message.unsubscribe = parsed.unsubscribe
        return message
    }

    // MARK: - Gövde

    func fetchBody(of message: Message) async throws -> FetchedBody {
        try await withReconnect(fetchClient) {
            if self.roles.isEmpty { try await self.resolveRoles(using: self.fetchClient) }
            guard let location = try await self.locate(message, using: self.fetchClient) else {
                throw ProviderError.server(String(localized: "The message wasn't found on the server. It may have been moved or deleted."))
            }
            try await self.fetchClient.select(location.mailbox)
            guard let item = try await self.fetchClient.uidFetch([location.uid], items: "(UID BODY.PEEK[])").first, let raw = item.body else {
                throw ProviderError.server(String(localized: "Couldn't download the message."))
            }
            let parsed = MIME.message(from: raw)
            return FetchedBody(html: parsed.html, attachments: AttachmentStore.save(parsed.attachments, messageID: message.id))
        }
    }

    /// Eski sürümde indirilmiş maillerde abonelik başlıkları saklanmadı; yalnızca o iki başlık okunur
    func unsubscribeInfo(of message: Message) async throws -> Unsubscribe? {
        try await withReconnect(fetchClient) {
            if self.roles.isEmpty { try await self.resolveRoles(using: self.fetchClient) }
            guard let location = try await self.locate(message, using: self.fetchClient) else { return nil }
            try await self.fetchClient.select(location.mailbox)
            let items = try await self.fetchClient.uidFetch([location.uid], items: "(UID BODY.PEEK[HEADER.FIELDS (LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)])")
            guard let raw = items.first?.body else { return nil }
            let part = MIME.parse(raw)
            return Unsubscribe(header: part.header("list-unsubscribe"), post: part.header("list-unsubscribe-post"))
        }
    }

    // MARK: - Eylemler

    func apply(_ change: RemoteChange) async throws {
        try await withReconnect(syncClient) {
            if self.roles.isEmpty { try await self.resolveRoles(using: self.syncClient) }
            switch change {
            case .move(let thread, let from, let to):
                guard let source = self.roles[from] else { return }
                guard let target = self.roles[to] else { throw ProviderError.missingMailbox(to.rawValue) }
                var uids: [UInt32] = []
                for message in thread.messages where !message.isDraft {
                    if let found = try await self.locate(message, using: self.syncClient, only: source) {
                        uids.append(found.uid)
                    }
                }
                guard !uids.isEmpty else { return }
                try await self.syncClient.select(source)
                if source == self.allMailMailbox {
                    // Gmail: Tüm Postalar'dan taşımak maili çöpe atar; kopyalamak etiketi ekler
                    try await self.syncClient.uidCopy(uids, to: target)
                } else {
                    try await self.syncClient.uidMove(uids, to: target)
                }

            case .setRead(_, let messages, let read):
                try await self.store(flag: "\\Seen", on: messages, add: read)

            case .setStarred(let thread, let starred):
                let targets = starred ? Array(thread.messages.filter { !$0.isDraft }.suffix(1)) : thread.messages.filter { !$0.isDraft }
                try await self.store(flag: "\\Flagged", on: targets, add: starred)
            }
        }
    }

    private func store(flag: String, on messages: [Message], add: Bool) async throws {
        var byMailbox: [String: [UInt32]] = [:]
        for message in messages {
            if let found = try await locate(message, using: syncClient) {
                byMailbox[found.mailbox, default: []].append(found.uid)
            }
        }
        for (mailbox, uids) in byMailbox {
            try await syncClient.select(mailbox)
            try await syncClient.uidStore(uids, "\(add ? "+" : "-")FLAGS.SILENT (\(flag))")
        }
    }

    /// Mesajın sunucudaki güncel yeri. Taşınmış olabileceği için Message-ID ile aranır.
    private func locate(_ message: Message, using client: IMAPClient, only mailbox: String? = nil) async throws -> (mailbox: String, uid: UInt32)? {
        guard let header = message.messageIDHeader else {
            guard let current = message.mailbox, let uid = message.uid, mailbox == nil || mailbox == current else { return nil }
            return (current, uid)
        }
        var candidates: [String] = []
        if let mailbox {
            candidates = [mailbox]
        } else {
            if let current = message.mailbox { candidates.append(current) }
            for (_, name) in roles.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !candidates.contains(name) {
                candidates.append(name)
            }
        }
        let escaped = header.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        for candidate in candidates {
            try await client.select(candidate)
            if let uid = try await client.uidSearch("HEADER Message-ID \"<\(escaped)>\"").last {
                return (candidate, uid)
            }
        }
        return nil
    }

    // MARK: - Gönderim

    func send(_ outgoing: MIMEBuilder.Outgoing, threadRemoteID: String?) async throws -> SentResult {
        let raw = MIMEBuilder.build(outgoing)
        let recipients = (outgoing.to + outgoing.cc).map(\.address)
        try await SMTPClient.send(
            host: server.smtpHost,
            username: credentials.username,
            password: credentials.password,
            from: address,
            recipients: recipients,
            data: raw
        )
        // iCloud SMTP gönderilenleri kendisi saklamaz; Gönderilenler klasörüne eklenir
        guard server.appendsSentCopy else { return SentResult(remoteID: nil, threadRemoteID: nil) }
        try? await withReconnect(syncClient) {
            if self.roles.isEmpty { try await self.resolveRoles(using: self.syncClient) }
            if let sent = self.roles[.sent] {
                try await self.syncClient.append(raw, to: sent, flags: ["\\Seen"])
            }
        }
        return SentResult(remoteID: nil, threadRemoteID: nil)
    }

    // MARK: - Bağlantı

    /// Kopan bağlantıyı bir kez yeniden kurup dener
    private func withReconnect<T>(_ client: IMAPClient, _ body: () async throws -> T) async throws -> T {
        do {
            try await client.connect()
            return try await body()
        } catch let error where Self.isConnectionError(error) {
            await client.disconnect()
            try await client.connect()
            return try await body()
        }
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        error is ConnectionError || error is URLError || (error as NSError).domain == NSPOSIXErrorDomain
    }
}

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// IMAP mesajlarını thread'lere ayırır: References / In-Reply-To zinciri, yoksa normalize edilmiş konu
nonisolated enum ThreadBuilder {
    static func build(_ input: [Message], accountID: UUID, roles: [ThreadLocation: String]) -> [MailThread] {
        let locationOf = Dictionary(roles.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        func priority(_ message: Message) -> Int {
            switch message.mailbox.flatMap({ locationOf[$0] }) {
            case .inbox: 0
            case .sent: 1
            case .archive: 2
            case .spam: 3
            case .trash: 4
            default: 5
            }
        }
        func key(_ message: Message) -> String {
            message.messageIDHeader ?? "\(message.mailbox ?? "")#\(message.uid ?? 0)"
        }

        // Aynı mailin farklı klasörlerdeki kopyalarından biri kalır
        var unique: [String: Message] = [:]
        for message in input {
            let k = key(message)
            if let existing = unique[k], priority(existing) <= priority(message) { continue }
            unique[k] = message
        }
        let messages = unique.values.sorted { $0.date < $1.date }

        var parent: [String: String] = [:]
        func find(_ node: String) -> String {
            var node = node
            while let next = parent[node], next != node {
                parent[node] = parent[next] ?? next
                node = next
            }
            return node
        }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        var firstBySubject: [String: String] = [:]
        for message in messages {
            let node = key(message)
            if parent[node] == nil { parent[node] = node }
            for reference in message.references + [message.inReplyTo].compactMap({ $0 }) {
                union(node, reference)
            }
            let subject = message.subject ?? ""
            let normalized = subject.normalizedSubject
            guard !normalized.isEmpty else { continue }
            if let first = firstBySubject[normalized] {
                if subject.hasReplyPrefix && message.references.isEmpty && message.inReplyTo == nil {
                    union(first, node)
                }
            } else {
                firstBySubject[normalized] = node
            }
        }

        var groups: [String: [Message]] = [:]
        for message in messages {
            groups[find(key(message)), default: []].append(message)
        }

        return groups.values.map { group in
            let sorted = group.sorted { $0.date < $1.date }
            let first = sorted[0]
            let locations = Set(sorted.compactMap { $0.mailbox.flatMap { locationOf[$0] } })
            let location: ThreadLocation =
                locations.contains(.inbox) ? .inbox
                : locations.contains(.archive) ? .archive
                : locations.contains(.spam) ? .spam
                : locations.contains(.trash) ? .trash
                : .sent
            return MailThread(
                id: UUID.stable("icloud|\(accountID)|thread|\(key(first))"),
                accountID: accountID,
                subject: first.subject ?? "",
                messages: sorted,
                location: location,
                isStarred: sorted.contains(where: \.isFlagged)
            )
        }
    }
}
