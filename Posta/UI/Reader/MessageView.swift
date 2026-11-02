import SwiftUI

struct MessageView: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let thread: MailThread
    let isExpanded: Bool
    let allowRemote: Bool
    let isLast: Bool
    let onToggle: () -> Void

    @State private var showsDetails = false

    private var fromMe: Bool { store.isFromMe(message, accountID: thread.accountID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture { if !isLast || !isExpanded { onToggle() } }
                .pointerStyle(isLast && isExpanded ? nil : .link)

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    if message.isBodyLoaded {
                        MailBodyView(
                            html: message.html,
                            allowRemote: allowRemote,
                            estimatedHeight: MailBodyView.estimate(for: message.plainText, hasImages: allowRemote && message.hasRemoteImages)
                        )
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Downloading content…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    }

                    if !message.attachments.isEmpty {
                        AttachmentsSection(attachments: message.attachments)
                    }
                }
                .padding(.leading, 48)
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: message.from.displayName, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fromMe ? String(localized: "Me") : message.from.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if isExpanded {
                        Text(message.from.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if isExpanded {
                    recipients
                } else {
                    Text(message.previewLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if !message.attachments.isEmpty {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if message.isPendingSend {
                    Label(store.isOffline ? "Waiting for connection" : "Sending", systemImage: store.isOffline ? "wifi.slash" : "paperplane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.fullDate(message.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if isExpanded {
                    Menu {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") { store.reply(.reply, threadID: thread.id) }
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.reply(.replyAll, threadID: thread.id) }
                        Button("Forward", systemImage: "arrowshape.turn.up.right") { store.reply(.forward, threadID: thread.id) }
                        Divider()
                        Button("Copy Address", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.from.address, forType: .string)
                        }
                        if !fromMe {
                            Button("New message to \(message.from.firstName)", systemImage: "square.and.pencil") {
                                store.compose(to: [message.from])
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 22, height: 18)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .handCursor()
                }
            }
        }
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(recipientSummary)
                        .lineLimit(showsDetails ? nil : 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .handCursor()

            if showsDetails {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                    detailRow("From", [message.from])
                    detailRow("To", message.to)
                    if !message.cc.isEmpty { detailRow("Cc", message.cc) }
                    GridRow {
                        Text("Date").foregroundStyle(.tertiary)
                        Text(message.date.formatted(.dateTime.day().month(.wide).year().weekday(.wide).hour().minute(.twoDigits).locale(Fmt.locale)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
            }
        }
    }

    private func detailRow(_ title: LocalizedStringKey, _ contacts: [Contact]) -> some View {
        GridRow {
            Text(title).foregroundStyle(.tertiary)
            Text(contacts.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", "))
        }
    }

    private var recipientSummary: String {
        let to: String = message.to.map { describe($0) }.joined(separator: ", ")
        guard !message.cc.isEmpty else { return String(localized: "To: \(to)") }
        let cc: String = message.cc.map { describe($0) }.joined(separator: ", ")
        return String(localized: "To: \(to)  ·  Cc: \(cc)")
    }

    private func describe(_ contact: Contact) -> String {
        if let account = store.account(thread.accountID), contact.id == account.address.lowercased() { return String(localized: "me") }
        return contact.firstName
    }
}

struct AttachmentsSection: View {
    let attachments: [Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(attachments.count) attachments")
                Text("·")
                Text(Fmt.fileSize(attachments.reduce(0) { $0 + $1.size }))
                Spacer()
                if attachments.count > 1 {
                    Button("Save all") { AttachmentFiles.saveAll(attachments) }
                        .buttonStyle(.borderless)
                        .handCursor()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(attachments) { AttachmentCard(attachment: $0) }
            }
        }
    }
}
