import SwiftUI

struct ThreadRow: View {
    @Environment(MailStore.self) private var store
    let thread: MailThread
    let isSelected: Bool
    let showsAccount: Bool
    let hover: HoverTracker

    private var isHovering: Bool { hover.id == AnyHashable(thread.id) }

    private var account: Account? { store.account(thread.accountID) }
    private var messageCount: Int { thread.messages.filter { !$0.isDraft }.count }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(thread.isUnread ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
                .frame(width: 7, height: 7)
                .padding(.top, 14)

            AvatarView(name: store.avatarContact(for: thread).displayName, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showsAccount, let account {
                        ColorDot(color: account.color.color, size: 7)
                            .help(account.address)
                    }
                    Text(store.senderSummary(for: thread))
                        .font(.system(size: 13, weight: thread.isUnread ? .bold : .semibold))
                        .foregroundStyle(thread.location == .drafts ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if messageCount > 1 {
                        Text("\(messageCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 6)
                    trailing
                }
                .frame(height: 18)

                HStack(spacing: 5) {
                    Text(thread.displaySubject)
                        .font(.system(size: 13, weight: thread.isUnread ? .medium : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(thread.lastMessage?.previewLine ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.045 : 0)))
        }
        .onHover { hovering in
            if hovering {
                hover.id = thread.id
            } else if hover.id == AnyHashable(thread.id) {
                hover.id = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering && thread.location != .drafts {
            HStack(spacing: 2) {
                QuickAction(symbol: "archivebox", help: String(localized: "Archive (E)")) { store.archive([thread.id]) }
                    .disabled(thread.location == .archive)
                QuickAction(symbol: "trash", help: String(localized: "Move to trash (⌫)")) { store.trash([thread.id]) }
                QuickAction(symbol: thread.isUnread ? "envelope.open" : "envelope.badge", help: thread.isUnread ? String(localized: "Mark as read (U)") : String(localized: "Mark as unread (U)")) {
                    store.toggleRead([thread.id])
                }
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 4) {
                if thread.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(Fmt.listDate(thread.lastDate))
                    .font(.caption)
                    .foregroundStyle(thread.isUnread ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
        }
    }
}

struct QuickAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 20)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

/// Satır ve okuma panelinde ortak sağ tık menüsü
struct ThreadMenu: View {
    @Environment(MailStore.self) private var store
    let thread: MailThread

    var body: some View {
        if thread.location != .drafts {
            Button("Reply") { store.reply(.reply, threadID: thread.id) }
            Button("Reply All") { store.reply(.replyAll, threadID: thread.id) }
            Button("Forward") { store.reply(.forward, threadID: thread.id) }

            Divider()

            Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") { store.toggleRead([thread.id]) }
            Button(thread.isStarred ? "Unstar" : "Star") { store.toggleStar([thread.id]) }

            Menu("Move to") {
                if thread.location != .inbox { Button("Inbox") { store.move([thread.id], to: .inbox) } }
                if thread.location != .archive { Button("Archive") { store.move([thread.id], to: .archive) } }
                if thread.location != .spam { Button("Spam") { store.move([thread.id], to: .spam) } }
            }

            Divider()

            if thread.location != .archive {
                Button(String(localized: "archive.action", defaultValue: "Archive", comment: "Arşivleme eylemi; klasör adı olan Archive'dan ayrı")) { store.archive([thread.id]) }
            }

            if thread.location == .inbox, store.splitInbox {
                if let sender = store.feedSender(of: thread) {
                    Button("Move to People") { store.moveSender(sender, toFeed: false) }
                } else if let sender = store.incomingSender(of: thread) {
                    Button("Move to Feed") { store.moveSender(sender, toFeed: true) }
                }
            }
        }
        Button(thread.location == .drafts ? "Delete Draft" : "Move to Trash", role: .destructive) { store.trash([thread.id]) }
    }
}
