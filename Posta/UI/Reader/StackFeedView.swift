import SwiftUI

/// Akış'ta seçilen göndericinin mailleri: solda tarih, sağda konu ve kısa önizleme olan sade bir liste.
/// Bir satıra tıklayınca mail yerinde açılır.
struct StackFeedView: View {
    @Environment(MailStore.self) private var store
    let stack: SenderStack

    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 24)

                    ForEach(stack.threads) { thread in
                        Rectangle()
                            .fill(.separator.opacity(0.5))
                            .frame(height: 0.5)
                            .padding(.horizontal, 12)
                        FeedCard(thread: thread, isExpanded: expanded.contains(thread.id)) {
                            toggle(thread)
                        }
                        .id(thread.id)
                    }
                }
                .padding(.horizontal, 44)
                .padding(.top, 44)
                .padding(.bottom, 40)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.expandAllRequest) {
                // Enter: en yeni okunmamış (yoksa en yeni) kart açılır
                guard let first = stack.threads.first(where: \.isUnread) ?? stack.threads.first else { return }
                open(first)
                withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private var header: some View {
        let unread = stack.threads.filter(\.isUnread).map(\.id)
        return HStack(alignment: .center, spacing: 16) {
            SenderTile(name: stack.name, count: 1, size: 48)
                .frame(height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(stack.name)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.6)
                    .lineLimit(1)
                Text(subtitle(unread: unread.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if !unread.isEmpty {
                HeaderButton(symbol: "envelope.open", help: String(localized: "Mark all as read")) { store.toggleRead(unread) }
            }
            HeaderButton(symbol: "archivebox", help: String(localized: "Archive all messages from this sender (E)")) {
                store.archive(stack.threads.map(\.id))
            }

            Menu {
                Button("Move to People") { store.moveSender(stack.sender, toFeed: false) }
                Divider()
                Button("Move All to Trash", role: .destructive) { store.trash(stack.threads.map(\.id)) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .handCursor()
        }
    }

    private func subtitle(unread: Int) -> String {
        var parts = [stack.sender.address, String(localized: "\(stack.threads.count) emails")]
        if unread > 0 { parts.append(String(localized: "\(unread) new")) }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ thread: MailThread) {
        if expanded.contains(thread.id) {
            withAnimation(.smooth(duration: 0.22)) { _ = expanded.remove(thread.id) }
        } else {
            open(thread)
        }
    }

    private func open(_ thread: MailThread) {
        withAnimation(.smooth(duration: 0.25)) { _ = expanded.insert(thread.id) }
        store.loadBodies(for: thread.id)
        store.markOpened(thread.id)
    }
}

/// Akış'taki tek mail: kapalıyken konu ve önizleme, açıkken mailin kendisi
private struct FeedCard: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @AppStorage(SettingsKey.alwaysLoadRemoteImages) private var alwaysLoadRemote = false
    let thread: MailThread
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    private var message: Message? { thread.messages.last { !$0.isDraft } }
    private var allowRemote: Bool { alwaysLoadRemote || thread.remoteImagesAllowed }
    private var conversationCount: Int { thread.messages.filter { !$0.isDraft }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) { summary }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .handCursor()

            if isExpanded {
                content
                    .padding(.leading, 100)
                    .transition(.opacity)
            }
        }
        .background(Color.primary.opacity(isHovering && !isExpanded ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contextMenu { ThreadMenu(thread: thread) }
    }

    /// Solda gün ve saat, sağda konu ve iki satırlık önizleme
    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            HStack(spacing: 5) {
                Text(Fmt.listDate(thread.lastDate))
                    .font(.system(size: 12, weight: thread.isUnread ? .semibold : .medium))
                    .foregroundStyle(thread.isUnread ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                // Birden çok hesap görünüyorsa hangi hesaba geldiği renginden anlaşılır
                if store.isUnified, let account = store.account(thread.accountID) {
                    ColorDot(color: account.color.color, size: 5)
                        .help(account.displayName)
                }
            }
            .monospacedDigit()
            .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.displaySubject)
                        .font(.system(size: 15, weight: thread.isUnread ? .bold : .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !isExpanded, let preview = message?.previewLine, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if thread.hasRemoteImages && !allowRemote {
                RemoteImagesBanner { store.allowRemoteImages(thread.id) }
            }

            if let message {
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

            actions
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                store.archive([thread.id])
            } label: {
                Label(String(localized: "archive.action", defaultValue: "Archive", comment: "Arşivleme eylemi; klasör adı olan Archive'dan ayrı"), systemImage: "archivebox")
            }
            .handCursor()
            Button {
                store.trash([thread.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .handCursor()
            if store.quickReplyTarget(for: thread) != nil {
                Button {
                    store.replyQuickly(to: thread.id)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .handCursor()
            }
            if conversationCount > 1 {
                Button {
                    store.select(thread.id)
                } label: {
                    Label("Open conversation · \(conversationCount)", systemImage: "text.bubble")
                }
                .handCursor()
            }
            Spacer()
        }
        .controlSize(.small)
    }
}
