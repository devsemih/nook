import Foundation
import os

nonisolated enum IMAPError: LocalizedError {
    case authenticationFailed(String)
    case commandFailed(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message): String(localized: "Sign-in rejected: \(message)")
        case .commandFailed(let message): String(localized: "The server rejected the request: \(message)")
        case .unexpected(let message): message
        }
    }
}

/// Sade bir IMAP4rev1 istemcisi: Posta'nın ihtiyaç duyduğu komutlar kadarı
actor IMAPClient {
    struct MailboxInfo: Sendable {
        var name: String
        var attributes: Set<String>
    }

    struct SelectInfo: Sendable {
        var uidValidity: UInt32
        var uidNext: UInt32
        var exists: Int
        /// CONDSTORE: klasördeki her değişiklikte (yeni mail, silme, bayrak) artar
        var highestModSeq: UInt64?
    }

    struct FetchItem: Sendable {
        var uid: UInt32
        var flags: Set<String>
        var internalDate: Date?
        var size: Int
        var body: Data?
    }

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private var connection: StreamConnection?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selectedMailbox: String?

    init(host: String, port: Int = 993, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    var isConnected: Bool { connection != nil }

    // MARK: Bağlantı

    func connect() async throws {
        if connection != nil { return }
        let connection = StreamConnection(host: host, port: port)
        await connection.open(tls: true)
        self.connection = connection
        do {
            let greeting = try await connection.readLine()
            guard String(decoding: greeting, as: UTF8.self).hasPrefix("* OK") else {
                throw IMAPError.unexpected(String(localized: "Didn't receive a greeting from the server."))
            }
            do {
                let responses = try await command("LOGIN \(quote(username)) \(quote(password))", redacted: true)
                _ = responses
            } catch IMAPError.commandFailed(let message) {
                throw IMAPError.authenticationFailed(message)
            }
            let capabilityResponses = try await command("CAPABILITY")
            for response in capabilityResponses where response.first?.text?.uppercased() == "CAPABILITY" {
                capabilities = Set(response.dropFirst().compactMap { $0.text?.uppercased() })
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        if let connection {
            try? await connection.write("Z LOGOUT\r\n")
            await connection.close()
        }
        connection = nil
        selectedMailbox = nil
    }

    // MARK: Komutlar

    func list() async throws -> [MailboxInfo] {
        try await command("LIST \"\" \"*\"").compactMap { response in
            guard response.first?.text?.uppercased() == "LIST", response.count >= 4 else { return nil }
            let attributes = Set((response[1].list ?? []).compactMap { $0.text?.lowercased() })
            guard let name = response[3].text else { return nil }
            return MailboxInfo(name: name, attributes: attributes)
        }
    }

    @discardableResult
    func select(_ mailbox: String) async throws -> SelectInfo {
        var info = SelectInfo(uidValidity: 0, uidNext: 0, exists: 0, highestModSeq: nil)
        let condstore = capabilities.contains("CONDSTORE")
        let responses = try await command("SELECT \(quote(mailbox))" + (condstore ? " (CONDSTORE)" : ""))
        for response in responses {
            if response.count >= 2, response[1].text?.uppercased() == "EXISTS" {
                info.exists = Int(response[0].text ?? "") ?? 0
            }
            if response.first?.text?.uppercased() == "OK" {
                let joined = response.compactMap(\.text).joined(separator: " ")
                if let value = Self.bracketNumber("UIDVALIDITY", in: joined) { info.uidValidity = value }
                if let value = Self.bracketNumber("UIDNEXT", in: joined) { info.uidNext = value }
                if let range = joined.range(of: "[HIGHESTMODSEQ ") {
                    info.highestModSeq = UInt64(joined[range.upperBound...].prefix { $0.isNumber })
                }
            }
        }
        selectedMailbox = mailbox
        return info
    }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let responses = try await command("UID SEARCH \(criteria)")
        return responses
            .filter { $0.first?.text?.uppercased() == "SEARCH" }
            .flatMap { $0.dropFirst().compactMap(\.number) }
    }

    func uidFetch(_ uids: [UInt32], items: String) async throws -> [FetchItem] {
        guard !uids.isEmpty else { return [] }
        let responses = try await command("UID FETCH \(uids.imapSequenceSet) \(items)")
        return responses.compactMap { response in
            guard response.count >= 3, response[1].text?.uppercased() == "FETCH", let pairs = response[2].list else { return nil }
            var item = FetchItem(uid: 0, flags: [], internalDate: nil, size: 0, body: nil)
            var index = 0
            while index + 1 < pairs.count {
                let key = (pairs[index].text ?? "").uppercased()
                let value = pairs[index + 1]
                switch key {
                case "UID": item.uid = value.number ?? 0
                case "FLAGS": item.flags = Set((value.list ?? []).compactMap { $0.text?.lowercased() })
                case "INTERNALDATE": item.internalDate = value.text.flatMap(Self.parseInternalDate)
                case "RFC822.SIZE": item.size = Int(value.text ?? "") ?? 0
                default:
                    if key.hasPrefix("BODY[") { item.body = value.data }
                }
                index += 2
            }
            return item.uid == 0 ? nil : item
        }
    }

    func uidStore(_ uids: [UInt32], _ change: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await command("UID STORE \(uids.imapSequenceSet) \(change)")
    }

    func uidCopy(_ uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        _ = try await command("UID COPY \(uids.imapSequenceSet) \(quote(mailbox))")
    }

    /// Mesajları başka klasöre taşır; MOVE yoksa COPY + \Deleted + EXPUNGE
    func uidMove(_ uids: [UInt32], to mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        let set = uids.imapSequenceSet
        if capabilities.contains("MOVE") {
            _ = try await command("UID MOVE \(set) \(quote(mailbox))")
        } else {
            _ = try await command("UID COPY \(set) \(quote(mailbox))")
            _ = try await command("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                _ = try await command("UID EXPUNGE \(set)")
            } else {
                _ = try await command("EXPUNGE")
            }
        }
    }

    func append(_ data: Data, to mailbox: String, flags: [String]) async throws {
        guard let connection else { throw ConnectionError.closed }
        tagCounter += 1
        let tag = "P\(tagCounter)"
        let flagList = flags.joined(separator: " ")
        try await connection.write("\(tag) APPEND \(quote(mailbox)) (\(flagList)) {\(data.count)}\r\n")
        let continuation = try await connection.readLine()
        guard continuation.first == 0x2B else {
            throw IMAPError.commandFailed(String(decoding: continuation, as: UTF8.self))
        }
        try await connection.write(data + Data("\r\n".utf8))
        _ = try await readUntilTagged(tag, on: connection)
    }

    /// IMAP IDLE: sunucu bir değişiklik bildirene ya da süre dolana kadar bekler.
    /// true: yeni mail, silinme veya bayrak değişikliği geldi.
    func idle(maxDuration: TimeInterval) async throws -> Bool {
        guard let connection else { throw ConnectionError.closed }
        tagCounter += 1
        let tag = "P\(tagCounter)"
        try await connection.write("\(tag) IDLE\r\n")
        let first = String(decoding: try await connection.readLine(timeout: 60), as: UTF8.self)
        guard first.hasPrefix("+") else {
            throw IMAPError.commandFailed(first)
        }

        // Süre dolunca DONE gönderilir; sunucu etiketli OK ile IDLE'ı bitirir
        let timer = Task {
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled else { return }
            try? await connection.write("DONE\r\n")
        }
        defer { timer.cancel() }

        var changed = false
        var sentDone = false
        while true {
            let line = String(decoding: try await connection.readLine(timeout: maxDuration + 120), as: UTF8.self)
            if line.hasPrefix("* ") {
                let upper = line.uppercased()
                if upper.hasSuffix(" EXISTS") || upper.hasSuffix(" EXPUNGE") || upper.contains(" FETCH ") || upper.hasSuffix(" RECENT") {
                    changed = true
                    if !sentDone {
                        // Değişikliği hemen işlemek için IDLE erken bitirilir
                        timer.cancel()
                        sentDone = true
                        try await connection.write("DONE\r\n")
                    }
                }
                continue
            }
            if line.hasPrefix(tag + " ") {
                let status = line.dropFirst(tag.count + 1).uppercased()
                guard status.hasPrefix("OK") else { throw IMAPError.commandFailed(String(status)) }
                return changed
            }
        }
    }

    // MARK: Altyapı

    private func command(_ text: String, redacted: Bool = false) async throws -> [[IMAPValue]] {
        guard let connection else { throw ConnectionError.closed }
        tagCounter += 1
        let tag = "P\(tagCounter)"
        let started = Date.now
        try await connection.write("\(tag) \(text)\r\n")
        let result = try await readUntilTagged(tag, on: connection)
        let elapsed = Date.now.timeIntervalSince(started)
        if elapsed > 1 {
            // Yalnızca komut adı loglanır (giriş bilgisi ve içerik yok)
            let verb = redacted ? "LOGIN" : text.split(separator: " ").prefix(2).joined(separator: " ")
            Log.sync.debug("Yavaş IMAP komutu \(verb, privacy: .public): \(elapsed, format: .fixed(precision: 1), privacy: .public) sn, \(result.count, privacy: .public) yanıt")
        }
        return result
    }

    /// Etiketli sonuç satırına kadar gelen tüm etiketsiz yanıtlar (* ile başlayan)
    private func readUntilTagged(_ tag: String, on connection: StreamConnection) async throws -> [[IMAPValue]] {
        var untagged: [[IMAPValue]] = []
        while true {
            let raw = try await readResponse(on: connection)
            let text = String(decoding: raw.prefix(200), as: UTF8.self)
            if raw.first == 0x2A { // *
                untagged.append(Array(IMAPTokenizer.parse(Array(raw.dropFirst(2)))))
                continue
            }
            if text.hasPrefix(tag + " ") {
                let status = text.dropFirst(tag.count + 1)
                if status.uppercased().hasPrefix("OK") {
                    let joined = String(decoding: raw, as: UTF8.self)
                    untagged.append([.atom("OK"), .atom(joined)])
                    return untagged
                }
                throw IMAPError.commandFailed(String(status.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
            // Beklenmeyen devam (+) satırları yok sayılır
        }
    }

    /// Literal'ları ({n}) içeren tam yanıtı okur
    private func readResponse(on connection: StreamConnection) async throws -> [UInt8] {
        var result: [UInt8] = []
        while true {
            let line = try await connection.readLine()
            result += line
            guard let count = Self.literalLength(line) else { return result }
            result += [0x0D, 0x0A]
            result += try await connection.read(count: count)
        }
    }

    private static func literalLength(_ line: [UInt8]) -> Int? {
        guard line.last == 0x7D, let open = line.lastIndex(of: 0x7B) else { return nil }
        let digits = line[(open + 1)..<(line.count - 1)].filter { $0 != 0x2B }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func bracketNumber(_ key: String, in text: String) -> UInt32? {
        guard let range = text.range(of: "[\(key) ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return UInt32(digits)
    }

    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    nonisolated static func parseInternalDate(_ value: String) -> Date? {
        internalDateFormatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    nonisolated static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
    }
}
