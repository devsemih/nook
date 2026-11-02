import SwiftUI

/// Açılan mail: sağ tarafın tamamı tek bir sakin sayfa; geniş kenar boşlukları, büyük konu başlığı.
/// Altta hızlı yanıt alanı durur.
struct ReaderView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @AppStorage(SettingsKey.alwaysLoadRemoteImages) private var alwaysLoadRemote = false
    let thread: MailThread

    @State private var expanded: Set<UUID> = []
    @State private var showsHiddenMiddle = false

    private var messages: [Message] { thread.messages.filter { !$0.isDraft } }
    private var account: Account? { store.account(thread.accountID) }
    private var allowRemote: Bool { alwaysLoadRemote || thread.remoteImagesAllowed }
    private var inlineComposer: Draft? {
        guard let composer = store.composer, composer.presentation == .inline, composer.threadID == thread.id else { return nil }
        return composer
    }
    private var showsQuickReply: Bool { inlineComposer == nil && store.quickReplyTarget(for: thread) != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                page
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 56)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsQuickReply {
                    QuickReplyBar(thread: thread)
                        .frame(maxWidth: 740)
                        .padding(.horizontal, 44)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: inlineComposer?.id) { _, id in
                guard id != nil else { return }
                withAnimation(.smooth) { proxy.scrollTo("composer", anchor: .bottom) }
            }
        }
        .animation(.smooth(duration: 0.25), value: inlineComposer?.id)
        .onAppear {
            resetExpansion()
            store.loadBodies(for: thread.id)
        }
        .onChange(of: thread.messages.count) { resetExpansion() }
        .onChange(of: store.expandAllRequest) { expanded = Set(messages.map(\.id)); showsHiddenMiddle = true }
    }

    // MARK: Sayfa

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 26)

            if thread.hasRemoteImages && !allowRemote {
                RemoteImagesBanner { store.allowRemoteImages(thread.id) }
                    .padding(.bottom, 14)
            }

            Rectangle()
                .fill(.separator.opacity(0.6))
                .frame(height: 0.5)

            messageList

            if let composer = inlineComposer {
                ComposerView(draft: composer, style: .inline)
                    .padding(.top, 18)
                    .id("composer")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            meta
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(thread.displaySubject)
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.7)
                    .lineSpacing(1)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    store.toggleStar([thread.id])
                } label: {
                    Image(systemName: thread.isStarred ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundStyle(thread.isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help(thread.isStarred ? "Unstar (S)" : "Star (S)")
                .handCursor()
            }

        }
    }

    /// Konunun üstünde küçük bir satır: hangi hesap, kaç mesaj, hangi klasör
    private var meta: some View {
        HStack(spacing: 8) {
            if let account, store.accounts.count > 1 {
                HStack(spacing: 5) {
                    ColorDot(color: account.color.color, size: 6)
                    Text(account.displayName)
                }
            }
            if messages.count > 1 {
                Text("\(messages.count) messages")
            }
            if thread.location == .spam || thread.location == .trash || thread.location == .archive {
                Text(thread.location == .spam ? "Spam" : thread.location == .trash ? "Trash" : "Archive")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }

    // MARK: Mesajlar

    @ViewBuilder
    private var messageList: some View {
        let hideMiddle = messages.count > 4 && !showsHiddenMiddle
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                if hideMiddle && index > 0 && index < messages.count - 2 {
                    if index == 1 {
                        HiddenMessagesButton(count: messages.count - 3) {
                            withAnimation(.smooth) { showsHiddenMiddle = true }
                        }
                    }
                } else {
                    if index > 0 { Divider().padding(.vertical, 2) }
                    MessageView(
                        message: message,
                        thread: thread,
                        isExpanded: expanded.contains(message.id),
                        allowRemote: allowRemote,
                        isLast: index == messages.count - 1
                    ) {
                        withAnimation(.smooth(duration: 0.22)) {
                            if expanded.contains(message.id) { expanded.remove(message.id) } else { expanded.insert(message.id) }
                        }
                    }
                }
            }
        }
    }

    private func resetExpansion() {
        var ids = Set(messages.filter { !$0.isRead }.map(\.id))
        if let last = messages.last { ids.insert(last.id) }
        expanded = ids
    }
}

struct RemoteImagesBanner: View {
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Remote images weren't loaded to protect your privacy.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show images", action: onAllow)
                .controlSize(.small)
                .handCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct HiddenMessagesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack { Divider() }
                Text("\(count) earlier messages")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                VStack { Divider() }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .handCursor()
    }
}
