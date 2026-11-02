import SwiftUI

/// Akış'ta bir göndericinin tüm mailleri tek satırda: simge, ad, mail sayısı ve son konu
struct SenderStackRow: View {
    @Environment(MailStore.self) private var store
    let stack: SenderStack
    let isSelected: Bool
    let showsAccount: Bool
    let hover: HoverTracker

    static func rowID(_ key: String) -> String { "stack|\(key)" }

    private var hoverID: String { Self.rowID(stack.id) }
    private var isHovering: Bool { hover.id == AnyHashable(hoverID) }

    var body: some View {
        let unread = stack.unreadCount
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unread > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
                .frame(width: 7, height: 7)
                .padding(.top, 12)

            SenderTile(name: stack.name, count: stack.threads.count, size: 30)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showsAccount {
                        HStack(spacing: 2) {
                            ForEach(stack.accountIDs.prefix(3), id: \.self) { id in
                                if let account = store.account(id) {
                                    ColorDot(color: account.color.color, size: 7)
                                        .help(account.address)
                                }
                            }
                        }
                    }
                    Text(stack.name)
                        .font(.system(size: 13, weight: unread > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Text(unread > 0 ? "\(unread) new" : "\(stack.threads.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(unread > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(unread > 0 ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary), in: Capsule())
                    Spacer(minLength: 6)
                    trailing(unread: unread)
                }
                .frame(height: 18)

                Text(stack.threads.first?.displaySubject ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.045 : 0)))
        }
        .onHover { hovering in
            if hovering {
                hover.id = hoverID
            } else if hover.id == AnyHashable(hoverID) {
                hover.id = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func trailing(unread: Int) -> some View {
        if isHovering {
            HStack(spacing: 2) {
                if unread > 0 {
                    QuickAction(symbol: "envelope.open", help: String(localized: "Mark all as read")) {
                        store.toggleRead(stack.threads.filter(\.isUnread).map(\.id))
                    }
                }
                QuickAction(symbol: "archivebox", help: String(localized: "Archive all (E)")) {
                    store.archive(stack.threads.map(\.id))
                }
            }
            .transition(.opacity)
        } else {
            Text(Fmt.listDate(stack.lastDate))
                .font(.caption)
                .foregroundStyle(unread > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
    }
}

/// Yığının sağ tık menüsü
struct StackMenu: View {
    @Environment(MailStore.self) private var store
    let stack: SenderStack

    var body: some View {
        let ids = stack.threads.map(\.id)
        let unread = stack.threads.filter(\.isUnread).map(\.id)
        if !unread.isEmpty {
            Button("Mark All as Read") { store.toggleRead(unread) }
        }
        Button("Archive All") { store.archive(ids) }

        Divider()

        Button("Move to People") { store.moveSender(stack.sender, toFeed: false) }

        Divider()

        Button("Move All to Trash", role: .destructive) { store.trash(ids) }
    }
}
