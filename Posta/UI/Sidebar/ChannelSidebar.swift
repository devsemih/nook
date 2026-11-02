import SwiftUI

/// Slack'teki kanal listesi gibi: üstte hesap adı, altında insanlar (her kişi bir özel mesaj),
/// Akış'taki göndericiler (her biri bir kanal) ve katlanmış klasörler.
struct ChannelSidebar: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        let sidebar = store.sidebar
        let inInbox = store.folder == .inbox && !store.isSearching
        let selectedPerson = inInbox ? store.selectedPersonID : nil
        let selectedStack = inInbox ? store.highlightedStackID : nil
        // Aynı adla yazan farklı adresler alan adıyla ayrılır: "Semih Aslan · gmail.com"
        let names = sidebar.allPeople.map(\.name)
        let repeated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })

        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SectionTitle(store.splitInbox ? String(localized: "People") : String(localized: "inbox.section", defaultValue: "Inbox", comment: "Bölüm başlığı; klasör adı olan Inbox'tan ayrı"), count: sidebar.allPeople.filter { $0.unreadCount > 0 }.count)
                    if sidebar.allPeople.isEmpty {
                        Text("No one has written yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    ForEach(sidebar.people) { person in
                        PersonChannel(person: person, isSelected: selectedPerson == person.id, showsDomain: repeated.contains(person.name))
                    }
                    if !sidebar.olderPeople.isEmpty {
                        MoreToggle(title: String(localized: "\(sidebar.olderPeople.count) more people"), isExpanded: store.showsOlderPeople) {
                            store.showsOlderPeople.toggle()
                        }
                        if store.showsOlderPeople {
                            ForEach(sidebar.olderPeople) { person in
                                PersonChannel(person: person, isSelected: selectedPerson == person.id, showsDomain: repeated.contains(person.name))
                            }
                        }
                    }

                    if store.splitInbox, !(sidebar.stacks.isEmpty && sidebar.olderStacks.isEmpty) {
                        SectionTitle(String(localized: "Feed"), count: (sidebar.stacks + sidebar.olderStacks).reduce(0) { $0 + $1.unreadCount })
                            .padding(.top, 14)
                        ForEach(sidebar.stacks) { stack in
                            StackChannel(stack: stack, isSelected: selectedStack == stack.id)
                        }
                        if !sidebar.olderStacks.isEmpty {
                            MoreToggle(title: String(localized: "\(sidebar.olderStacks.count) more senders"), isExpanded: store.showsOlderStacks) {
                                store.showsOlderStacks.toggle()
                            }
                            if store.showsOlderStacks {
                                ForEach(sidebar.olderStacks) { stack in
                                    StackChannel(stack: stack, isSelected: selectedStack == stack.id)
                                }
                            }
                        }
                    }

                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.scopeTitle)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(status(now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HeaderButton(symbol: "magnifyingglass", help: String(localized: "Search (/ or ⌘F)")) { store.focusSearch() }
            HeaderButton(symbol: "square.and.pencil", help: String(localized: "New message (C or ⌘N)")) { store.compose() }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func status(now: Date) -> String {
        if let progress = store.overallSyncProgress { return String(localized: "Downloading \(Int(progress * 100))%") }
        if store.syncPhase == .offline { return String(localized: "Offline") }
        return Fmt.syncStatus(store.lastSync, now: now)
    }
}

// MARK: - Satırlar

private struct SectionTitle: View {
    let title: String
    let count: Int

    init(_ title: String, count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Kenar çubuğundaki tıklanabilir satır: seçiliyse vurgu renginde zemin, üzerine gelince hafif gri
private struct ChannelRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        Button {
            NSApplication.resignTextFocus()
            action()
        } label: {
            content
                .padding(.horizontal, 10)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.05 : 0)))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .handCursor()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct PersonChannel: View {
    @Environment(MailStore.self) private var store
    let person: Person
    let isSelected: Bool
    var showsDomain = false

    var body: some View {
        let unread = person.unreadCount
        ChannelRow(isSelected: isSelected, action: { open() }) {
            HStack(spacing: 9) {
                AvatarView(name: person.name, size: 22)
                Text(person.name)
                    .font(.system(size: 13, weight: unread > 0 ? .bold : .regular))
                    .foregroundStyle(unread > 0 || isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
                if showsDomain, let domain = person.contact.address.split(separator: "@").last {
                    Text(domain)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if unread > 0 {
                    UnreadCount(count: unread)
                }
            }
        }
        .contextMenu {
            Button("Move to Feed") { store.moveSender(person.contact, toFeed: true) }
            Button("New message to \(person.contact.firstName)") { store.compose(to: [person.contact]) }
            Divider()
            Button("Archive All") { store.archive(person.threads.map(\.id)) }
        }
    }

    private func open() {
        if store.folder != .inbox || store.isSearching { store.go(scope: store.scope, folder: .inbox) }
        store.select(item: .person(person.id))
    }
}

private struct StackChannel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.isMonochrome) private var isMonochrome
    let stack: SenderStack
    let isSelected: Bool

    var body: some View {
        let unread = stack.unreadCount
        ChannelRow(isSelected: isSelected, action: { open() }) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isMonochrome ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(AvatarView.color(for: stack.name).gradient))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Text(stack.name.first.map { String($0).uppercased(with: Locale.current) } ?? "")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isMonochrome ? Color.primary : .white)
                    }
                Text(stack.name)
                    .font(.system(size: 13, weight: unread > 0 ? .bold : .regular))
                    .foregroundStyle(unread > 0 || isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu { StackMenu(stack: stack) }
    }

    private func open() {
        if store.folder != .inbox || store.isSearching { store.go(scope: store.scope, folder: .inbox) }
        store.select(item: .stack(stack.id))
    }
}

/// Kenar çubuğunun altında sabit klasörler: gelen kutusu, yıldızlı, gönderilen, taslaklar, arşiv, spam, çöp.
/// Gelen kutusu dışındaki bir klasör seçilince kenar çubuğu o klasörün mail listesine döner.
struct FolderBar: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MailboxRole.allCases) { role in
                FolderButton(role: role, isSelected: store.folder == role && !store.isSearching)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(themes.sidebar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FolderButton: View {
    @Environment(MailStore.self) private var store
    let role: MailboxRole
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let badge = store.badge(for: role)
        Button {
            NSApplication.resignTextFocus()
            store.go(scope: store.scope, folder: role)
        } label: {
            Image(systemName: role.symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 32, height: 30)
                .background(isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.06 : 0)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if badge > 0, role != .inbox {
                        Circle().fill(.tint).frame(width: 6, height: 6).offset(x: -4, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(badge > 0 && role != .inbox ? "\(role.title) · \(badge)" : role.title)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

private struct UnreadCount: View {
    @Environment(\.onAccent) private var onAccent
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(onAccent)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(.tint, in: Capsule())
    }
}

private struct MoreToggle: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(isExpanded ? String(localized: "Show less") : title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

/// Başlıktaki yuvarlak simge düğmesi
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(isHovering ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .help(help)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}
