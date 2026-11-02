import Foundation

nonisolated struct GmailSyncState: Codable, Sendable {
    var historyId: String
}

private nonisolated enum GmailError: Error {
    case notFound
}

/// Gmail REST API: thread ve etiketleri doğal olarak verir, history.list ile artımlı senkron yapar
actor GmailProvider: MailProvider {
    private let accountID: UUID
    private var tokens: GoogleTokens
    private var refreshTask: Task<GoogleTokens, Error>?

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"
    private static let initialQuery = "newer_than:90d"
    private static let initialThreadLimit = 400
    private static let parallelRequests = 8

    init(accountID: UUID, tokens: GoogleTokens) {
        self.accountID = accountID
        self.tokens = tokens
    }

    func close() async {}

    // MARK: - Senkron

    func sync(existing: [Message], state: Data?) async throws -> SyncOutput {
        if let state, let previous = try? JSONDecoder().decode(GmailSyncState.self, from: state) {
            do {
                return try await incrementalSync(from: previous.historyId)
            } catch GmailError.notFound {
                // historyId süresi dolmuş: tam senkrona düşülür
            }
        }
        return try await fullSync()
    }

    private func fullSync() async throws -> SyncOutput {
        let profile: Profile = try await get("profile")
        var threadIDs: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: Self.initialQuery), URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "includeSpamTrash", value: "true")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let list: ThreadList = try await get("threads", query: query)
            threadIDs += list.threads?.map(\.id) ?? []
            pageToken = list.nextPageToken
        } while pageToken != nil && threadIDs.count < Self.initialThreadLimit

        let (threads, _) = try await fetchThreads(Array(threadIDs.prefix(Self.initialThreadLimit)))
        return SyncOutput(threads: threads, isFullSnapshot: true, removedThreadIDs: [], state: encodeState(profile.historyId))
    }

    private func incrementalSync(from historyId: String) async throws -> SyncOutput {
        var changed = Set<String>()
        var latest = historyId
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "startHistoryId", value: historyId), URLQueryItem(name: "maxResults", value: "500")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: HistoryList = try await get("history", query: query)
            for entry in page.history ?? [] {
                for message in entry.messages ?? [] { changed.insert(message.threadId) }
            }
            if let id = page.historyId { latest = id }
            pageToken = page.nextPageToken
        } while pageToken != nil

        guard !changed.isEmpty else {
            return SyncOutput(threads: [], isFullSnapshot: false, removedThreadIDs: [], state: encodeState(latest))
        }
        let (threads, removed) = try await fetchThreads(Array(changed))
        return SyncOutput(threads: threads, isFullSnapshot: false, removedThreadIDs: removed, state: encodeState(latest))
    }

    private func fetchThreads(_ ids: [String]) async throws -> ([MailThread], Set<UUID>) {
        var threads: [MailThread] = []
        var removed = Set<UUID>()
        for chunk in ids.chunked(into: Self.parallelRequests) {
            try await withThrowingTaskGroup(of: (String, ThreadResource?).self) { group in
                for id in chunk {
                    group.addTask {
                        do {
                            let resource: ThreadResource = try await self.get("threads/\(id)", query: [
                                URLQueryItem(name: "format", value: "metadata"),
                            ] + ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References"].map {
                                URLQueryItem(name: "metadataHeaders", value: $0)
                            })
                            return (id, resource)
                        } catch GmailError.notFound {
                            return (id, nil)
                        }
                    }
                }
                for try await (id, resource) in group {
                    if let resource, let thread = convert(resource) {
                        threads.append(thread)
                    } else {
                        removed.insert(threadID(id))
                    }
                }
            }
        }
        return (threads, removed)
    }

    private func threadID(_ remoteID: String) -> UUID {
        UUID.stable("gmail|\(accountID)|thread|\(remoteID)")
    }

    private func convert(_ resource: ThreadResource) -> MailThread? {
        let resources = (resource.messages ?? []).filter { !($0.labelIds ?? []).contains("DRAFT") }
        guard !resources.isEmpty else { return nil }
        let messages = resources.map { item -> Message in
            let labels = Set(item.labelIds ?? [])
            var headers: [String: String] = [:]
            for header in item.payload?.headers ?? [] { headers[header.name.lowercased()] = header.value }
            let date = item.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? headers["date"].flatMap(MIME.parseDate) ?? .now
            return Message(
                id: UUID.stable("gmail|\(accountID)|\(item.id)"),
                remoteID: item.id,
                messageIDHeader: headers["message-id"].map(MIME.cleanMessageID),
                inReplyTo: headers["in-reply-to"].map(MIME.cleanMessageID),
                references: (headers["references"] ?? "").split(separator: " ").map { MIME.cleanMessageID(String($0)) }.filter { !$0.isEmpty },
                subject: MIME.decodeEncodedWords(headers["subject"] ?? ""),
                from: MIME.addresses(headers["from"] ?? "").first ?? Contact(name: "", address: ""),
                to: MIME.addresses(headers["to"] ?? ""),
                cc: MIME.addresses(headers["cc"] ?? ""),
                date: date,
                html: "",
                snippet: HTMLText.plain(from: item.snippet ?? ""),
                isRead: !labels.contains("UNREAD"),
                isFlagged: labels.contains("STARRED"),
                hasAttachmentHint: item.payload?.mimeType == "multipart/mixed",
                isBodyLoaded: false
            )
        }
        let labelSets = resources.map { Set($0.labelIds ?? []) }
        let location: ThreadLocation =
            labelSets.contains { $0.contains("INBOX") } ? .inbox
            : labelSets.allSatisfy { $0.contains("TRASH") } ? .trash
            : labelSets.contains { $0.contains("SPAM") } ? .spam
            : labelSets.allSatisfy { $0.contains("SENT") } ? .sent
            : .archive
        return MailThread(
            id: threadID(resource.id),
            accountID: accountID,
            remoteID: resource.id,
            subject: messages.first?.subject ?? "",
            messages: messages,
            location: location,
            isStarred: messages.contains(where: \.isFlagged)
        )
    }

    private func encodeState(_ historyId: String) -> Data? {
        try? JSONEncoder().encode(GmailSyncState(historyId: historyId))
    }

    // MARK: - Gövde

    func fetchBody(of message: Message) async throws -> FetchedBody {
        guard let remoteID = message.remoteID else { throw ProviderError.server("Mesaj kimliği eksik.") }
        let raw: RawMessage = try await get("messages/\(remoteID)", query: [URLQueryItem(name: "format", value: "raw")])
        guard let data = Data(base64URLEncoded: raw.raw) else { throw ProviderError.server("Mail içeriği çözülemedi.") }
        let parsed = MIME.message(from: data)
        return FetchedBody(html: parsed.html, attachments: AttachmentStore.save(parsed.attachments, messageID: message.id))
    }

    // MARK: - Eylemler

    func apply(_ change: RemoteChange) async throws {
        switch change {
        case .move(let thread, let from, let to):
            guard let id = thread.remoteID else { return }
            if to == .trash {
                try await post("threads/\(id)/trash")
                return
            }
            if from == .trash {
                try await post("threads/\(id)/untrash")
            }
            let add = label(for: to).map { [$0] } ?? []
            let remove = from == .trash ? [] : (label(for: from).map { [$0] } ?? [])
            if !add.isEmpty || !remove.isEmpty {
                try await post("threads/\(id)/modify", json: ["addLabelIds": add, "removeLabelIds": remove])
            }

        case .setRead(_, let messages, let read):
            let ids = messages.compactMap(\.remoteID)
            guard !ids.isEmpty else { return }
            try await post("messages/batchModify", json: [
                "ids": ids,
                read ? "removeLabelIds" : "addLabelIds": ["UNREAD"],
            ])

        case .setStarred(let thread, let starred):
            if starred {
                guard let last = thread.messages.last(where: { !$0.isDraft })?.remoteID else { return }
                try await post("messages/\(last)/modify", json: ["addLabelIds": ["STARRED"]])
            } else if let id = thread.remoteID {
                try await post("threads/\(id)/modify", json: ["removeLabelIds": ["STARRED"]])
            }
        }
    }

    private func label(for location: ThreadLocation) -> String? {
        switch location {
        case .inbox: "INBOX"
        case .spam: "SPAM"
        default: nil
        }
    }

    // MARK: - Gönderim

    func send(_ outgoing: MIMEBuilder.Outgoing, threadRemoteID: String?) async throws -> SentResult {
        let raw = MIMEBuilder.build(outgoing)
        var body: [String: Any] = ["raw": raw.base64URLEncoded]
        if let threadRemoteID { body["threadId"] = threadRemoteID }
        let data = try await request("messages/send", method: "POST", json: body)
        let sent = try JSONDecoder().decode(SentMessage.self, from: data)
        return SentResult(remoteID: sent.id, threadRemoteID: sent.threadId)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, json: [String: Any]? = nil) async throws {
        _ = try await request(path, method: "POST", json: json)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty { components.queryItems = query }
        var lastMessage = "Gmail yanıt vermedi."
        for attempt in 0..<5 {
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 401:
                if attempt == 0 {
                    tokens.expiry = .distantPast
                    continue
                }
                throw ProviderError.authenticationRequired
            case 404, 410:
                throw GmailError.notFound
            case 403, 429, 500..<600:
                lastMessage = Self.errorMessage(data) ?? "Gmail hatası (\(status))"
                let isRateLimit = status != 403 || lastMessage.lowercased().contains("rate") || lastMessage.lowercased().contains("quota")
                guard isRateLimit else { throw ProviderError.server(lastMessage) }
                // Üstel geri çekilme
                let delay = pow(2.0, Double(attempt)) * 0.5 + Double.random(in: 0...0.3)
                try await Task.sleep(for: .seconds(delay))
            default:
                throw ProviderError.server(Self.errorMessage(data) ?? "Gmail hatası (\(status))")
            }
        }
        throw ProviderError.server(lastMessage)
    }

    private func accessToken() async throws -> String {
        if tokens.expiry > Date.now.addingTimeInterval(60) { return tokens.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let current = tokens
        let task = Task { try await GoogleOAuth.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        tokens = refreshed
        try? Keychain.setCodable(refreshed, for: .googleTokens(accountID))
        return refreshed.accessToken
    }

    private static func errorMessage(_ data: Data) -> String? {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (body?["error"] as? [String: Any])?["message"] as? String
    }

    // MARK: - API modelleri

    private struct Profile: Decodable {
        var emailAddress: String
        var historyId: String
    }

    private struct ThreadList: Decodable {
        struct Item: Decodable { var id: String }
        var threads: [Item]?
        var nextPageToken: String?
    }

    private struct ThreadResource: Decodable {
        var id: String
        var messages: [MessageResource]?
    }

    private struct MessageResource: Decodable {
        struct Payload: Decodable {
            struct Header: Decodable {
                var name: String
                var value: String
            }

            var mimeType: String?
            var headers: [Header]?
        }

        var id: String
        var threadId: String
        var labelIds: [String]?
        var snippet: String?
        var internalDate: String?
        var payload: Payload?
    }

    private struct HistoryList: Decodable {
        struct Entry: Decodable {
            struct Item: Decodable {
                var id: String
                var threadId: String
            }

            var messages: [Item]?
        }

        var history: [Entry]?
        var nextPageToken: String?
        var historyId: String?
    }

    private struct RawMessage: Decodable {
        var raw: String
    }

    private struct SentMessage: Decodable {
        var id: String
        var threadId: String
    }
}
