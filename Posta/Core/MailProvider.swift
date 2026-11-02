import Foundation
import CryptoKit

// Provider katmanının ortak arayüzü. Arayüz ve senkron motoru hesap tipini bilmez:
// Gmail (REST API) ve iCloud (IMAP/SMTP) aynı protokole uyar.

nonisolated enum ProviderError: LocalizedError {
    case authenticationRequired
    case missingCredentials
    case missingMailbox(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: String(localized: "Your session expired. Please sign in again.")
        case .missingCredentials: String(localized: "The account's sign-in details weren't found in the Keychain.")
        case .missingMailbox(let name): String(localized: "The \(name) folder wasn't found on the server.")
        case .server(let message): message
        }
    }
}

/// Senkron sonucu: hesap için güncel thread'ler
nonisolated struct SyncOutput: Sendable {
    var threads: [MailThread]
    /// true: hesabın tüm thread'leri bu listedir (listede olmayanlar silinir); false: yalnızca değişenler
    var isFullSnapshot: Bool
    var removedThreadIDs: Set<UUID>
    var state: Data?
}

nonisolated struct FetchedBody: Sendable {
    var html: String
    var attachments: [Attachment]
}

nonisolated struct SentResult: Sendable {
    var remoteID: String?
    var threadRemoteID: String?
}

/// Arayüzdeki bir değişikliğin sunucudaki karşılığı
nonisolated enum RemoteChange: Sendable {
    case move(thread: MailThread, from: ThreadLocation, to: ThreadLocation)
    case setRead(thread: MailThread, messages: [Message], read: Bool)
    case setStarred(thread: MailThread, starred: Bool)
}

protocol MailProvider: Actor {
    /// existing: hesabın yerel mesajları (artımlı senkron için), state: son senkron imleci,
    /// progress: indirilen ve toplam mail sayısı; yalnızca indirilecek mail varsa çağrılır
    func sync(existing: [Message], state: Data?, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> SyncOutput
    func fetchBody(of message: Message) async throws -> FetchedBody
    func apply(_ change: RemoteChange) async throws
    func send(_ outgoing: MIMEBuilder.Outgoing, threadRemoteID: String?) async throws -> SentResult
    /// Sunucu bir değişiklik bildirene kadar bekler (IMAP IDLE). true: senkron gerekli.
    func waitForChanges() async throws -> Bool
    func close() async
}

nonisolated extension UUID {
    /// Aynı girdiden her zaman aynı UUID (sunucu kimliklerini yerel kimliklere eşlemek için)
    static func stable(_ key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// İndirilen ekleri uygulama kabındaki klasöre yazar
nonisolated enum AttachmentStore {
    static func save(_ attachments: [MIME.ParsedAttachment], messageID: UUID) -> [Attachment] {
        let folder = LocalDatabase.attachmentsFolder.appendingPathComponent(messageID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var usedNames = Set<String>()
        return attachments.map { parsed in
            var name = parsed.filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty { name = "ek" }
            var candidate = name
            var counter = 2
            while usedNames.contains(candidate) {
                candidate = "\(counter)-\(name)"
                counter += 1
            }
            usedNames.insert(candidate)
            let url = folder.appendingPathComponent(candidate)
            try? parsed.data.write(to: url)
            return Attachment(
                id: UUID.stable("\(messageID)|\(candidate)"),
                filename: candidate,
                size: Int64(parsed.data.count),
                mimeType: parsed.mimeType,
                localURL: url
            )
        }
    }
}

nonisolated extension String {
    /// "Re: Fwd: Konu" → "konu"
    var normalizedSubject: String {
        replacingOccurrences(of: #"^\s*((re|fw|fwd|ynt|ilt|aw|wg|sv|tr)\s*(\[\d+\])?\s*:\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    var hasReplyPrefix: Bool {
        range(of: #"^\s*(re|fw|fwd|ynt|ilt|aw|wg|sv|tr)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
