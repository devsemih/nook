import SwiftUI

/// Menü çubuğu. Cmd'li kısayollar burada tanımlı; tek tuşlu kısayollar KeyboardRouter'da.
struct PostaCommands: Commands {
    let store: MailStore

    private var selection: [UUID] { store.actionTargets }
    private var hasSelection: Bool { !selection.isEmpty && store.selectedThread?.location != .drafts }
    private var hasThread: Bool { store.selectedThread.map { $0.location != .drafts } ?? false }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.compose() }
                .keyboardShortcut("n")
                .disabled(store.accounts.isEmpty)
            Button("Add Account…") { store.showAddAccount = true }
        }

        CommandGroup(replacing: .textEditing) {
            Button("Search") { store.focusSearch() }
                .keyboardShortcut("f")
                .disabled(store.accounts.isEmpty)
        }

        TextFormattingCommands()

        CommandMenu("Message") {
            Button("Reply") { store.startReply() }
                .keyboardShortcut("r")
                .disabled(!hasThread)
            Button("Reply All") { store.reply(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasThread)
            Button("Forward") { store.reply(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!hasThread)
            Button("Send") { store.sendCurrent() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.canSend)

            Divider()

            Button("Archive  (E)") { store.archive(selection) }
                .disabled(!hasSelection)
            Button("Move to Trash  (⌫)") { store.trash(selection) }
                .disabled(selection.isEmpty)
            Button(store.selectedThread?.isUnread == true ? "Mark as Read  (U)" : "Mark as Unread  (U)") {
                store.toggleRead(selection)
            }
            .disabled(!hasSelection)
            Button(store.selectedThread?.isStarred == true ? "Unstar  (S)" : "Star  (S)") {
                if let id = store.selectedThreadID { store.toggleStar([id]) }
            }
            .disabled(!hasThread)

            Menu("Move to") {
                Button("Inbox") { store.move(selection, to: .inbox) }
                Button("Archive") { store.move(selection, to: .archive) }
                Button("Spam") { store.move(selection, to: .spam) }
                Button("Trash") { store.move(selection, to: .trash) }
            }
            .disabled(!hasSelection)
        }

        CommandMenu("Go") {
            Button("All Accounts") { store.scope = .all }
                .keyboardShortcut("0")
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.displayName) { store.selectAccount(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }

            Divider()

            ForEach(Array(MailboxRole.allCases.enumerated()), id: \.element) { index, role in
                Button(role.title) { store.go(scope: store.scope, folder: role) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }

            Divider()

            Button("Quick Switcher…") { store.showQuickSwitcher = true }
                .keyboardShortcut("k")
                .disabled(store.accounts.isEmpty)
            Button(store.unreadOnly ? "Show All Mail  (⇧U)" : "Unread Only  (⇧U)") { store.toggleUnreadOnly() }
            Button("Next Message  (J)") { store.selectNext() }
            Button("Previous Message  (K)") { store.selectPrevious() }

            Divider()

            Button("Sync Now") { store.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts  (?)") { store.showShortcuts = true }
        }
    }
}
