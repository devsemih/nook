import AppKit
import Observation

/// Açık olan yazma alanının durumu.
@Observable
final class Draft: Identifiable {
    enum Mode: String, Hashable {
        case new, reply, replyAll, forward

        var title: String {
            switch self {
            case .new: String(localized: "New message")
            case .reply: String(localized: "Reply")
            case .replyAll: String(localized: "Reply all")
            case .forward: String(localized: "Forward")
            }
        }

        var symbol: String {
            switch self {
            case .new: "square.and.pencil"
            case .reply: "arrowshape.turn.up.left"
            case .replyAll: "arrowshape.turn.up.left.2"
            case .forward: "arrowshape.turn.up.right"
            }
        }
    }

    /// Yanıt okuma panelinde satır içi, yeni mail ve taslaklar sheet içinde açılır
    enum Presentation: Hashable {
        case inline, sheet
    }

    let id = UUID()
    var mode: Mode
    var presentation: Presentation
    /// Yanıtlanan veya iletilen thread
    var threadID: UUID?
    /// Taslaklar'dan açıldıysa taslak thread'i
    var savedDraftThreadID: UUID?
    var accountID: UUID
    var to: [Contact]
    var cc: [Contact]
    var showCc: Bool
    var subject: String
    var body: NSAttributedString
    var attachments: [Attachment]

    @ObservationIgnored private let initial: (to: [Contact], cc: [Contact], subject: String, body: String, attachments: [Attachment])

    init(
        mode: Mode,
        presentation: Presentation,
        threadID: UUID? = nil,
        savedDraftThreadID: UUID? = nil,
        accountID: UUID,
        to: [Contact] = [],
        cc: [Contact] = [],
        subject: String = "",
        body: NSAttributedString = NSAttributedString(),
        attachments: [Attachment] = []
    ) {
        self.mode = mode
        self.presentation = presentation
        self.threadID = threadID
        self.savedDraftThreadID = savedDraftThreadID
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.showCc = !cc.isEmpty
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.initial = (to, cc, subject, body.string, attachments)
    }

    /// Yazma alanı veya Taslaklar'dan açılan taslağın hangi listedeki öğeye bağlı olduğu
    var anchorID: UUID? { presentation == .inline ? threadID : savedDraftThreadID }

    /// Kullanıcı açıldığı halinden bir şey değiştirdi mi
    var isModified: Bool {
        body.string.trimmingCharacters(in: .whitespacesAndNewlines) != initial.body.trimmingCharacters(in: .whitespacesAndNewlines)
            || to != initial.to || cc != initial.cc
            || subject != initial.subject
            || attachments != initial.attachments
    }

    var isBlank: Bool {
        to.isEmpty && cc.isEmpty && subject.isEmpty && attachments.isEmpty
            && body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SavedDraft: Hashable {
    var mode: Draft.Mode
    var replyToThreadID: UUID?
    var body: NSAttributedString

    init(mode: Draft.Mode, replyToThreadID: UUID?, body: NSAttributedString) {
        self.mode = mode
        self.replyToThreadID = replyToThreadID
        self.body = body
    }

    /// Veritabanından: RTF renkleri sabitlendiği için metin rengi yeniden dinamik yapılır
    init?(stored: StoredDraft) {
        guard let body = NSMutableAttributedString(rtf: stored.rtf, documentAttributes: nil) else { return nil }
        body.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: body.length))
        self.init(mode: Draft.Mode(rawValue: stored.mode) ?? .new, replyToThreadID: stored.replyToThreadID, body: body)
    }

    var stored: StoredDraft? {
        guard let rtf = body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:]) else { return nil }
        return StoredDraft(mode: mode.rawValue, replyToThreadID: replyToThreadID, rtf: rtf)
    }
}
