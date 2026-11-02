import SwiftUI

/// Fare hangi satırın üzerinde; değişince yalnızca satırlar güncellenir, liste yeniden hesaplanmaz.
/// Tek kaynakta tutulduğu için satırlar kayınca birden fazla satırda takılı kalmaz.
@Observable
final class HoverTracker {
    var id: AnyHashable?
}

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @State private var hover = HoverTracker()

    private var showsAccount: Bool {
        store.isUnified || (store.isSearching && store.accounts.count > 1)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.splitsInbox {
                        if !store.visibleThreads.isEmpty { splitContent }
                    } else {
                        datedContent
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .overlay { EmptyListView() }
            .onChange(of: store.selectedThreadID) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id) }
            }
            .onChange(of: store.selectedStackID) { _, key in
                guard let key else { return }
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(SenderStackRow.rowID(key)) }
            }
        }
        // Başlık kayan listenin üstünde durur; macOS 26 kaydırma kenarı efektiyle içerik altında soluklaşır
        .safeAreaBar(edge: .top, spacing: 0) { ListHeader() }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(themes.sidebar)
    }
}

// MARK: - Bölümler

private extension MessageListView {
    /// Arşiv, Gönderilen ve arama: tarihe göre gruplanmış düz liste
    @ViewBuilder
    var datedContent: some View {
        let sections = store.sections
        ForEach(sections) { section in
            ListSectionHeader(title: section.title, isFirst: section.id == sections.first?.id)
            ForEach(section.threads) { threadRow($0) }
        }
    }

    /// Gelen kutusu: önce insanlardan gelenler, sonra göndericiye göre yığınlanmış otomatik mailler
    @ViewBuilder
    var splitContent: some View {
        let layout = store.inboxLayout
        let highlighted = store.highlightedStackID
        let waiting = layout.people.filter(\.isUnread).count

        ListSectionHeader(title: String(localized: "People"), detail: waiting > 0 ? String(localized: "\(waiting) new") : nil, isFirst: true)
        if layout.people.isEmpty {
            Text(store.unreadOnly ? "No unread conversations" : "No new conversations in the last two weeks")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        ForEach(layout.people) { threadRow($0) }
        if !layout.olderPeople.isEmpty {
            OlderToggle(
                title: String(localized: "\(layout.olderPeople.count) older conversations"),
                expandedTitle: String(localized: "Hide older conversations"),
                isExpanded: store.showsOlderPeople
            ) { store.showsOlderPeople.toggle() }
            if store.showsOlderPeople {
                ForEach(layout.olderPeople) { threadRow($0) }
            }
        }

        if !layout.stacks.isEmpty || !layout.olderStacks.isEmpty {
            let fresh = (layout.stacks + layout.olderStacks).reduce(0) { $0 + $1.unreadCount }
            ListSectionHeader(title: String(localized: "Feed"), detail: fresh > 0 ? String(localized: "\(fresh) new") : nil)
            ForEach(layout.stacks) { stackRow($0, isSelected: highlighted == $0.id) }
            if !layout.olderStacks.isEmpty {
                OlderToggle(
                    title: String(localized: "\(layout.olderStacks.count) older senders"),
                    expandedTitle: String(localized: "Hide older senders"),
                    isExpanded: store.showsOlderStacks
                ) { store.showsOlderStacks.toggle() }
                if store.showsOlderStacks {
                    ForEach(layout.olderStacks) { stackRow($0, isSelected: highlighted == $0.id) }
                }
            }
        }
    }

    func threadRow(_ thread: MailThread) -> some View {
        Button {
            NSApplication.resignTextFocus()
            store.select(thread.id)
        } label: {
            ThreadRow(
                thread: thread,
                isSelected: store.selectedThreadID == thread.id,
                showsAccount: showsAccount,
                hover: hover
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .handCursor()
        .id(thread.id)
        .contextMenu { ThreadMenu(thread: thread) }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        ))
    }

    func stackRow(_ stack: SenderStack, isSelected: Bool) -> some View {
        Button {
            NSApplication.resignTextFocus()
            store.select(item: .stack(stack.id))
        } label: {
            SenderStackRow(stack: stack, isSelected: isSelected, showsAccount: store.isUnified, hover: hover)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .handCursor()
        .id(SenderStackRow.rowID(stack.id))
        .contextMenu { StackMenu(stack: stack) }
        .transition(.opacity)
    }
}

private struct ListSectionHeader: View {
    let title: String
    var detail: String?
    var isFirst = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, isFirst ? 4 : 18)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "37 eski konuşma" satırı; tıklayınca eski satırlar listenin içinde açılır
private struct OlderToggle: View {
    let title: String
    let expandedTitle: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(isExpanded ? expandedTitle : title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .handCursor()
    }
}

/// Klasör başlığı ve okunmamış hapı. Hap hem sayaç hem filtre: tıklayınca yalnızca okunmamışlar kalır.
private struct ListHeader: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    @ViewBuilder
    private var subtitle: some View {
        let scope = store.scopeTitle
        if store.isSearching {
            Text("“\(store.searchText)” · \(store.visibleThreads.count) results")
        } else if let progress = store.overallSyncProgress {
            Text("\(scope) · Downloading \(Int(progress * 100))%")
                .monospacedDigit()
                .contentTransition(.numericText(value: progress))
                .animation(.snappy, value: progress)
        } else if store.syncPhase == .offline {
            Text("\(scope) · Offline")
        } else if store.splitsInbox, store.waitingPeopleCount > 0 {
            Text("\(scope) · New mail from \(store.waitingPeopleCount) people")
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("\(scope) · \(Fmt.syncStatus(store.lastSync, now: context.date))")
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                FolderMenu()
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if store.isSearching {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { store.searchText = "" }
                } label: {
                    Label("Close search", systemImage: "xmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .handCursor()
            } else {
                HeaderButton(symbol: "magnifyingglass", help: String(localized: "Search (/ or ⌘F)")) { store.focusSearch() }
                HeaderButton(symbol: "square.and.pencil", help: String(localized: "New message (C or ⌘N)")) { store.compose() }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // Kayan liste başlığın altından görünmesin
        .background(themes.sidebar)
    }
}

/// Klasör başlığı aynı zamanda klasör seçici; kenar çubuğu yerine buradan geçilir (⌥⌘1…7, ⌘K)
private struct FolderMenu: View {
    @Environment(MailStore.self) private var store
    @State private var isHovering = false

    private var folder: Binding<MailboxRole> {
        Binding(
            get: { store.folder },
            set: { store.go(scope: store.scope, folder: $0) }
        )
    }

    var body: some View {
        Menu {
            Picker("Folder", selection: folder) {
                ForEach(MailboxRole.allCases) { role in
                    Label(title(for: role), systemImage: role.symbol)
                        .tag(role)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(store.folderTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
        .handCursor()
        .onHover { isHovering = $0 }
        .help("Change folder (⌥⌘1…7)")
    }

    private func title(for role: MailboxRole) -> String {
        let count = store.badge(for: role)
        return count > 0 ? "\(role.title)  \(count)" : role.title
    }
}

private struct UnreadPill: View {
    @Environment(MailStore.self) private var store
    @Environment(\.onAccent) private var onAccent
    @State private var isHovering = false

    private var count: Int {
        store.threads(in: store.scope, folder: store.folder).filter(\.isUnread).count
    }

    var body: some View {
        let count = self.count
        let active = store.unreadOnly

        if count == 0 && !active {
            Label("All read", systemImage: "checkmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        } else {
            Button {
                store.toggleUnreadOnly()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(active ? AnyShapeStyle(onAccent) : AnyShapeStyle(.tint))
                        .frame(width: 6, height: 6)
                    Text("\(count) unread")
                        .contentTransition(.numericText(value: Double(count)))
                    if active {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(active ? AnyShapeStyle(onAccent) : AnyShapeStyle(.tint))
                .background {
                    Capsule().fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(isHovering ? 0.2 : 0.12)))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .handCursor()
            .onHover { isHovering = $0 }
            .help(active ? "Show all mail (⇧U)" : "Show unread only (⇧U)")
            .contextMenu {
                Button(active ? "Show All Mail" : "Show Unread Only") { store.toggleUnreadOnly() }
                Button("Mark All as Read") { store.markAllRead() }
                    .disabled(count == 0)
            }
            .animation(.snappy(duration: 0.2), value: active)
            .animation(.snappy(duration: 0.2), value: count)
        }
    }
}

private struct EmptyListView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if store.visibleThreads.isEmpty {
            Group {
                if store.isSearching {
                    ContentUnavailableView.search(text: store.searchText)
                } else if store.unreadOnly {
                    ContentUnavailableView("No unread mail", systemImage: "checkmark.circle", description: Text("You've read everything."))
                } else {
                    switch store.folder {
                    case .inbox:
                        ContentUnavailableView("Inbox is empty", systemImage: "tray", description: Text("New mail will appear here."))
                    case .drafts:
                        ContentUnavailableView("No drafts", systemImage: "doc", description: Text("Unfinished messages are saved here automatically."))
                    case .starred:
                        ContentUnavailableView("No starred mail", systemImage: "star", description: Text("Press S to star a message."))
                    case .trash:
                        ContentUnavailableView("Trash is empty", systemImage: "trash")
                    case .spam:
                        ContentUnavailableView("No spam", systemImage: "xmark.bin")
                    case let role:
                        ContentUnavailableView("\(role.title) is empty", systemImage: role.symbol)
                    }
                }
            }
            .transition(.opacity)
        }
    }
}
