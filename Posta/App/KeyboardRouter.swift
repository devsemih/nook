import AppKit

/// Tek tuşlu kısayollar (j, k, e, u, s…). Yazma alanı odaktayken devre dışı kalır.
/// Cmd'li kısayollar menü çubuğundaki Commands üzerinden çalışır.
final class KeyboardRouter {
    static let shared = KeyboardRouter()

    private var monitor: Any?
    private weak var store: MailStore?

    func install(store: MailStore) {
        self.store = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let escape: UInt16 = 53
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// true dönerse olay tüketilir
    private func handle(_ event: NSEvent) -> Bool {
        guard let store, let window = event.window, window === store.mainWindow,
              window.attachedSheet == nil, !store.accounts.isEmpty else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.characters ?? ""
        let isEditing = (window.firstResponder as? NSTextView)?.isEditable == true

        if event.keyCode == KeyCode.escape, modifiers.isEmpty {
            if store.showQuickSwitcher {
                store.showQuickSwitcher = false
                return true
            }
            if store.composer != nil {
                store.closeComposer(save: true)
                window.makeFirstResponder(nil)
                return true
            }
            if isEditing, store.isSearching { return false }
            if isEditing {
                window.makeFirstResponder(nil)
                return true
            }
            return false
        }

        guard !isEditing, !store.showQuickSwitcher else { return false }
        // Türkçe klavyede # için Option gerekebiliyor
        guard modifiers.isEmpty || (characters == "#" && modifiers == .option) else { return false }

        // Akış'ta yığın seçiliyse eylemler göndericinin tüm maillerine uygulanır
        let selected = store.actionTargets

        switch event.keyCode {
        case KeyCode.down: store.selectNext(); return true
        case KeyCode.up: store.selectPrevious(); return true
        case KeyCode.returnKey, KeyCode.enter: store.openSelected(); return true
        case KeyCode.delete, KeyCode.forwardDelete:
            guard !selected.isEmpty else { return false }
            store.trash(selected)
            return true
        default: break
        }

        switch characters {
        case "j": store.selectNext()
        case "k": store.selectPrevious()
        case "e": if !selected.isEmpty { store.archive(selected) }
        case "#": if !selected.isEmpty { store.trash(selected) }
        case "u": if !selected.isEmpty { store.toggleRead(selected) }
        case "s": if let id = store.selectedThreadID { store.toggleStar([id]) }
        case "U": store.toggleUnreadOnly()
        case "c": store.compose()
        case "r": store.startReply()
        case "a": store.reply(.replyAll)
        case "f": store.reply(.forward)
        case "/": store.focusSearch()
        case "?": store.showShortcuts = true
        default: return false
        }
        return true
    }
}
