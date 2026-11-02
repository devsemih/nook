import SwiftUI

/// Sağdaki alan: bir kişiyle sohbet, Akış'taki bir göndericinin kartları ya da tek bir mail
struct DetailView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        let thread = store.selectedThread
        let stack = store.selectedStack
        let person = store.selectedPerson

        Group {
            if let stack {
                StackFeedView(stack: stack)
                    .id(stack.id)
            } else if let thread {
                ReaderView(thread: thread)
                    .id(thread.id)
                    // Pencerenin üst kenarına yapışmasın; sağ üstteki eylemlerle aynı hizada başlasın
                    .safeAreaPadding(.top, 44)
                    // Kişinin gelen kutusunda birden çok konuşması varsa üstte aralarında geçilir
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let person, person.threads.count > 1 { PersonThreads(person: person, selected: thread.id) }
                    }
                    .overlay(alignment: .topTrailing) { ThreadActions(thread: thread) }
            } else {
                EmptyReaderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sağ taraf tek parça sayfa; kenar çubuğunun grisinden ayrılır
        .background(themes.paper)
    }
}

/// Bir kişiyle gelen kutusundaki konuşmalar: konu başlıklarıyla yatay sekmeler
private struct PersonThreads: View {
    @Environment(MailStore.self) private var store
    let person: Person
    let selected: UUID

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(person.threads) { thread in
                    let isSelected = thread.id == selected
                    Button {
                        store.select(thread.id)
                    } label: {
                        HStack(spacing: 6) {
                            if thread.isUnread {
                                Circle().fill(.tint).frame(width: 6, height: 6)
                            }
                            Text(thread.displaySubject)
                                .lineLimit(1)
                            Text(Fmt.listDate(thread.lastDate))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .frame(maxWidth: 260)
                        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.05)), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .handCursor()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        // Sağ üstteki eylem düğmeleriyle çakışmasın
        .padding(.trailing, 190)
    }
}

/// Tek bir mail açıkken sağ üstte yüzen eylemler
private struct ThreadActions: View {
    @Environment(MailStore.self) private var store
    let thread: MailThread

    var body: some View {
        let replyable = thread.location != .drafts
        HStack(spacing: 2) {
            if thread.location != .archive, replyable {
                HeaderButton(symbol: "archivebox", help: String(localized: "Archive (E)")) { store.archive([thread.id]) }
            }
            HeaderButton(symbol: "trash", help: String(localized: "Move to trash (⌫)")) { store.trash([thread.id]) }
            if replyable {
                HeaderButton(symbol: "arrowshape.turn.up.left", help: String(localized: "Reply (R)")) { store.startReply() }
                Menu {
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { store.reply(.replyAll) }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { store.reply(.forward) }
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
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 14)
        .padding(.trailing, 18)
    }
}

private struct EmptyReaderView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let unread = store.sidebar.allPeople.filter { $0.unreadCount > 0 }.count
        ContentUnavailableView {
            Label(unread > 0 ? "\(unread) people are waiting for you" : "All caught up", systemImage: unread > 0 ? "person.2" : "checkmark.circle")
        } description: {
            Text(unread > 0 ? "Pick someone on the left, or use J and K to browse." : "New messages will show up here.")
        }
    }
}
