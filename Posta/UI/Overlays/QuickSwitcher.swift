import SwiftUI

/// ⌘K, arama ikonu, / ve ⌘F ile açılan tek palet: üstte hesap ve klasörler, yazınca altta mail sonuçları
struct CommandPalette: View {
    @Environment(MailStore.self) private var store
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct NavItem {
        enum Icon { case symbol(String), account(Account), all }
        let id: String
        let title: String
        let subtitle: String
        let icon: Icon
        let action: () -> Void
    }

    private enum Entry: Identifiable {
        case nav(NavItem)
        case mail(MailThread)
        case showAll(String)

        var id: String {
            switch self {
            case .nav(let item): "nav-\(item.id)"
            case .mail(let thread): "mail-\(thread.id)"
            case .showAll: "show-all"
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var navItems: [NavItem] {
        var result: [NavItem] = [
            NavItem(id: "all", title: String(localized: "All accounts"), subtitle: "⌘0", icon: .all) {
                store.go(scope: .all, folder: .inbox)
            },
        ]
        for (index, account) in store.accounts.enumerated() {
            result.append(NavItem(id: "acc-\(account.id)", title: account.displayName, subtitle: index < 9 ? "⌘\(index + 1)" : "", icon: .account(account)) {
                store.go(scope: .account(account.id), folder: .inbox)
            })
        }
        for role in MailboxRole.allCases {
            result.append(NavItem(id: "box-\(role.rawValue)", title: role.title, subtitle: store.scopeTitle, icon: .symbol(role.symbol)) {
                store.go(scope: store.scope, folder: role)
            })
        }
        let query = trimmedQuery
        guard !query.isEmpty else { return result }
        let lowered = query.lowercased(with: Fmt.locale)
        return result
            .filter { $0.title.localizedStandardContains(query) }
            .sorted { lhs, rhs in
                lhs.title.lowercased(with: Fmt.locale).hasPrefix(lowered) && !rhs.title.lowercased(with: Fmt.locale).hasPrefix(lowered)
            }
            .prefix(4)
            .map { $0 }
    }

    private var sections: (nav: [Entry], mail: [Entry]) {
        let nav = navItems.map(Entry.nav)
        let mails = store.searchResults(for: trimmedQuery)
        var mailEntries = mails.map(Entry.mail)
        if !mails.isEmpty { mailEntries.append(.showAll(trimmedQuery)) }
        return (nav, mailEntries)
    }

    var body: some View {
        let sections = self.sections
        let entries = sections.nav + sections.mail

        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Search mail or go somewhere", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { run(entries) }
                        .onKeyPress(.downArrow) {
                            highlighted = min(highlighted + 1, max(entries.count - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                        .handCursor()
                    }
                    KeyCap(key: "esc")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if !sections.nav.isEmpty {
                                header("Go")
                                ForEach(Array(sections.nav.enumerated()), id: \.element.id) { index, entry in
                                    entryView(entry, index: index)
                                }
                            }

                            if trimmedQuery.isEmpty {
                                Text("Start typing to search mail: people, subjects, content, or attachment names.")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            } else if sections.mail.isEmpty {
                                Text("No mail found for “\(trimmedQuery)”")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            } else {
                                header("Mail")
                                ForEach(Array(sections.mail.enumerated()), id: \.element.id) { offset, entry in
                                    entryView(entry, index: sections.nav.count + offset)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .frame(height: estimatedHeight(sections))
                    .onChange(of: highlighted) { _, value in
                        guard entries.indices.contains(value) else { return }
                        proxy.scrollTo(entries[value].id)
                    }
                }
            }
            .frame(width: 600)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
            .padding(.top, 64)
        }
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    // MARK: Satırlar

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func entryView(_ entry: Entry, index: Int) -> some View {
        Group {
            switch entry {
            case .nav(let item): navRow(item)
            case .mail(let thread): mailRow(thread)
            case .showAll(let text):
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    Text("Show all results for “\(text)” in the list")
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(index == highlighted ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .id(entry.id)
        .onTapGesture { perform(entry) }
        .handCursor()
        .onHover { if $0 { highlighted = index } }
    }

    private func navRow(_ item: NavItem) -> some View {
        HStack(spacing: 12) {
            Group {
                switch item.icon {
                case .symbol(let name):
                    Image(systemName: name).foregroundStyle(.secondary)
                case .account(let account):
                    AccountBadge(account: account, size: 20)
                case .all:
                    ScopeBadge(scope: .all, size: 22)
                }
            }
            .frame(width: 26)
            Text(item.title)
            Spacer()
            Text(item.subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func mailRow(_ thread: MailThread) -> some View {
        let contact = store.avatarContact(for: thread)
        return HStack(alignment: .top, spacing: 12) {
            AvatarView(name: contact.displayName, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if store.accounts.count > 1, let account = store.account(thread.accountID) {
                        ColorDot(color: account.color.color, size: 6)
                    }
                    Text(store.senderSummary(for: thread))
                        .font(.system(size: 13, weight: thread.isUnread ? .bold : .semibold))
                        .lineLimit(1)
                    if thread.location != .inbox {
                        Text(store.homeFolder(of: thread).title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 6)
                    Text(Fmt.listDate(thread.lastDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(thread.displaySubject)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(thread.lastMessage?.previewLine ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func estimatedHeight(_ sections: (nav: [Entry], mail: [Entry])) -> CGFloat {
        var height: CGFloat = 12
        if !sections.nav.isEmpty { height += 26 + CGFloat(sections.nav.count) * 36 }
        if trimmedQuery.isEmpty || sections.mail.isEmpty {
            height += 40
        } else {
            let mails = sections.mail.filter { if case .mail = $0 { true } else { false } }.count
            height += 26 + CGFloat(mails) * 62 + 36
        }
        return min(460, height)
    }

    // MARK: Eylemler

    private func run(_ entries: [Entry]) {
        guard entries.indices.contains(highlighted) else { return }
        perform(entries[highlighted])
    }

    private func perform(_ entry: Entry) {
        switch entry {
        case .nav(let item): item.action()
        case .mail(let thread): store.reveal(thread.id)
        case .showAll(let text): store.searchText = text
        }
        close()
    }

    private func close() {
        store.showQuickSwitcher = false
    }
}
