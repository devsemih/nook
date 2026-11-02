import SwiftUI

// MARK: - Hesap

nonisolated enum AccountKind: String, Codable, Hashable, Sendable {
    case gmail, icloud

    var title: String { self == .gmail ? "Gmail" : "iCloud" }
    var symbol: String { self == .gmail ? "envelope.fill" : "icloud.fill" }
}

nonisolated enum AccountStatus: Hashable, Codable, Sendable {
    case ok, syncing, needsReauth
    case failed(String)
}

nonisolated struct Account: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var kind: AccountKind
    var address: String
    /// Sidebar'da görünen hesap adı ("Kişisel", "İş"…)
    var displayName: String
    /// Giden maillerde görünen gönderen adı
    var senderName: String
    var color: AccountColor
    var status: AccountStatus = .ok
    var signature: String = ""

    var contact: Contact { Contact(name: senderName, address: address) }
}

// MARK: - Kişi

nonisolated struct Contact: Hashable, Identifiable, Codable, Sendable {
    var name: String
    var address: String

    var id: String { address.lowercased() }
    var displayName: String { name.isEmpty ? address : name }
    var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }

    var isValid: Bool {
        address.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[^@\s]{2,}/#) != nil
    }

    var initials: String { Contact.initials(for: displayName) }

    static func initials(for text: String) -> String {
        Monogram.initials(for: text)
    }
}

// MARK: - Klasör

nonisolated enum MailboxRole: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case inbox, starred, sent, drafts, archive, spam, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .starred: String(localized: "Starred")
        case .sent: String(localized: "Sent")
        case .drafts: String(localized: "Drafts")
        case .archive: String(localized: "Archive")
        case .spam: String(localized: "Spam")
        case .trash: String(localized: "Trash")
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        }
    }
}

/// Bir thread'in fiziksel olarak durduğu yer. Yıldızlı ve Gönderilen sanal klasörlerdir.
nonisolated enum ThreadLocation: String, Hashable, Codable, Sendable {
    case inbox, archive, sent, drafts, spam, trash
}

nonisolated enum AccountScope: Hashable, Sendable {
    case all
    case account(UUID)
}

// MARK: - Ek

nonisolated enum AttachmentKind: Sendable {
    case pdf, image, archive, document, spreadsheet, presentation, audio, video, other

    init(filename: String) {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": self = .image
        case "zip", "rar", "7z", "gz", "tar": self = .archive
        case "doc", "docx", "pages", "txt", "rtf", "md": self = .document
        case "xls", "xlsx", "numbers", "csv": self = .spreadsheet
        case "ppt", "pptx", "key": self = .presentation
        case "mp3", "m4a", "wav", "aac": self = .audio
        case "mp4", "mov", "m4v": self = .video
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .image: "photo.fill"
        case .archive: "doc.zipper"
        case .document: "doc.text.fill"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.on.rectangle.angled.fill"
        case .audio: "waveform"
        case .video: "film.fill"
        case .other: "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pdf: .red
        case .image: .teal
        case .archive: .gray
        case .document: .blue
        case .spreadsheet: .green
        case .presentation: .orange
        case .audio: .pink
        case .video: .purple
        case .other: .secondary
        }
    }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .image: String(localized: "Image")
        case .archive: String(localized: "Archive")
        case .document: String(localized: "Document")
        case .spreadsheet: String(localized: "Spreadsheet")
        case .presentation: String(localized: "Presentation")
        case .audio: String(localized: "Audio")
        case .video: String(localized: "Video")
        case .other: String(localized: "File")
        }
    }

    var canPreview: Bool { self == .pdf || self == .image }
}

nonisolated struct Attachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var filename: String
    var size: Int64
    var mimeType: String
    /// İndirilmiş veya yazma ekranında eklenmiş yerel dosya
    var localURL: URL?

    init(id: UUID = UUID(), filename: String, size: Int64, mimeType: String = "application/octet-stream", localURL: URL? = nil) {
        self.id = id
        self.filename = filename
        self.size = size
        self.mimeType = mimeType
        self.localURL = localURL
    }

    var kind: AttachmentKind { AttachmentKind(filename: filename) }
}

// MARK: - Mesaj ve thread

nonisolated struct Message: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    /// Gmail mesaj kimliği
    var remoteID: String?
    /// IMAP klasörü ve UID
    var mailbox: String?
    var uid: UInt32?
    /// Message-ID, In-Reply-To ve References başlıkları (thread gruplama ve yanıt için)
    var messageIDHeader: String?
    var inReplyTo: String?
    var references: [String]
    /// Mesajın kendi konusu (thread gruplama için)
    var subject: String?
    var from: Contact
    var to: [Contact]
    var cc: [Contact]
    var date: Date
    var html: String
    var plainText: String
    var preview: String
    var isRead: Bool
    var isFlagged: Bool
    var attachments: [Attachment]
    /// Gövde henüz indirilmediyse listede ek ikonunu göstermek için
    var hasAttachmentHint: Bool
    var isDraft: Bool
    var isBodyLoaded: Bool
    /// Gönderim kuyruğunda bekliyor
    var isPendingSend: Bool
    /// Bülten, bildirim gibi otomatik gönderilmiş; nil: eski sürümde indirildi, henüz bilinmiyor
    var automated: Bool?

    init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        mailbox: String? = nil,
        uid: UInt32? = nil,
        messageIDHeader: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String? = nil,
        from: Contact,
        to: [Contact],
        cc: [Contact] = [],
        date: Date,
        html: String,
        snippet: String? = nil,
        isRead: Bool = true,
        isFlagged: Bool = false,
        attachments: [Attachment] = [],
        hasAttachmentHint: Bool = false,
        isDraft: Bool = false,
        isBodyLoaded: Bool = true,
        isPendingSend: Bool = false,
        automated: Bool? = nil
    ) {
        self.id = id
        self.remoteID = remoteID
        self.mailbox = mailbox
        self.uid = uid
        self.messageIDHeader = messageIDHeader
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.html = html
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.attachments = attachments
        self.hasAttachmentHint = hasAttachmentHint
        self.isDraft = isDraft
        self.isBodyLoaded = isBodyLoaded
        self.isPendingSend = isPendingSend
        self.automated = automated
        let plain = HTMLText.plain(from: html)
        self.plainText = plain
        self.preview = snippet ?? Message.makePreview(plain)
    }

    static func makePreview(_ plain: String) -> String {
        String(plain.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(220))
    }

    /// Tek satırda akan önizleme; eski sürümde kaydedilenlerde kalan satır sonları (\r) atılır
    var previewLine: String {
        guard preview.contains(where: \.isNewline) else { return preview }
        return preview.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Sunucudan inen gövdeyi yerleştirir
    mutating func applyBody(html: String, attachments: [Attachment]) {
        self.html = html
        self.attachments = attachments
        self.hasAttachmentHint = !attachments.isEmpty
        self.plainText = HTMLText.plain(from: html)
        self.preview = Message.makePreview(plainText)
        self.isBodyLoaded = true
    }

    var hasRemoteImages: Bool {
        html.range(of: #"src\s*=\s*["']https?://"#, options: .regularExpression) != nil
    }
}

nonisolated struct MailThread: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var accountID: UUID
    /// Gmail thread kimliği
    var remoteID: String?
    var subject: String
    var messages: [Message]
    var location: ThreadLocation
    var isStarred: Bool = false
    var remoteImagesAllowed = false

    init(
        id: UUID = UUID(),
        accountID: UUID,
        remoteID: String? = nil,
        subject: String,
        messages: [Message],
        location: ThreadLocation,
        isStarred: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.remoteID = remoteID
        self.subject = subject
        self.messages = messages.sorted { $0.date < $1.date }
        self.location = location
        self.isStarred = isStarred
    }

    var lastMessage: Message? { messages.last }
    var lastDate: Date { messages.last?.date ?? .distantPast }
    var isUnread: Bool { messages.contains { !$0.isRead } }
    var hasAttachments: Bool { messages.contains { !$0.attachments.isEmpty || $0.hasAttachmentHint } }
    var hasRemoteImages: Bool { messages.contains { $0.hasRemoteImages } }
    var displaySubject: String { subject.isEmpty ? String(localized: "(No subject)") : subject }
}

// MARK: - Bildirim (toast)

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var symbol: String?
    var undoable: Bool
    var isError: Bool
}

// MARK: - Senkron durumu

nonisolated struct SyncProgress: Hashable, Sendable {
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 1 }
    var isComplete: Bool { done >= total }
}

enum SyncPhase: Equatable {
    case idle, syncing, offline
}

enum ReadBehavior: String, CaseIterable, Identifiable {
    case onSelect, delayed, manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onSelect: String(localized: "On selection")
        case .delayed: String(localized: "After 2 seconds")
        case .manual: String(localized: "Manually")
        }
    }
}

/// Koyu temada tasarlanmış maillerin gösterimi
enum DarkMailStyle: String, CaseIterable, Identifiable {
    case lightCard, inverted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lightCard: String(localized: "On a light background")
        case .inverted: String(localized: "Dark (invert colors)")
        }
    }
}

enum SettingsKey {
    static let darkMailStyle = "darkMailStyle"
    static let readBehavior = "readBehavior"
    static let alwaysLoadRemoteImages = "alwaysLoadRemoteImages"
    static let notificationsEnabled = "notificationsEnabled"
    static let splitInbox = "splitInbox"
    static let senderOverrides = "senderOverrides"
    static let classifierVersion = "classifierVersion"
    static let contentRulesVersion = "contentRulesVersion"
    static let showsIsland = "showsIsland"
}
