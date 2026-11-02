import SwiftUI

struct ShortcutGroup: Identifiable {
    let title: String
    let items: [(keys: [String], title: String)]
    var id: String { title }

    static let all: [ShortcutGroup] = [
        ShortcutGroup(title: String(localized: "Navigation"), items: [
            (["J", "↓"], String(localized: "Next message")),
            (["K", "↑"], String(localized: "Previous message")),
            (["↩"], String(localized: "Open message")),
            (["Esc"], String(localized: "Close reply, back to list")),
            (["⌘0"], String(localized: "All accounts")),
            (["⌘1…9"], String(localized: "Switch to account by position")),
            (["⌥⌘1…7"], String(localized: "Go to folder")),
            (["⌘K"], String(localized: "Quick switcher: account or folder")),
            (["/", "⌘F"], String(localized: "Go to search")),
        ]),
        ShortcutGroup(title: String(localized: "Actions"), items: [
            (["E"], String(localized: "archive.action", defaultValue: "Archive", comment: "Arşivleme eylemi; klasör adı olan Archive'dan ayrı")),
            (["⌫", "#"], String(localized: "Move to trash")),
            (["U"], String(localized: "Read / unread")),
            (["S"], String(localized: "Star")),
            (["⇧U"], String(localized: "Unread only")),
            (["⌘Z"], String(localized: "Undo last action")),
        ]),
        ShortcutGroup(title: String(localized: "Writing"), items: [
            (["C", "⌘N"], String(localized: "New message")),
            (["R", "⌘R"], String(localized: "Quick reply")),
            (["A", "⇧⌘R"], String(localized: "Reply all")),
            (["F", "⇧⌘F"], String(localized: "Forward")),
            (["⌘↩"], String(localized: "Send")),
            (["⌘B", "⌘I", "⌘U"], String(localized: "Bold, italic, underline")),
        ]),
        ShortcutGroup(title: String(localized: "General"), items: [
            (["⌘,"], String(localized: "Settings")),
            (["?"], String(localized: "Show this list")),
        ]),
    ]
}

struct ShortcutsList: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 22) {
            GridRow(alignment: .top) {
                column(ShortcutGroup.all[0])
                column(ShortcutGroup.all[2])
            }
            GridRow(alignment: .top) {
                column(ShortcutGroup.all[1])
                column(ShortcutGroup.all[3])
            }
        }
    }

    private func column(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title)
                .font(.headline)
                .padding(.bottom, 2)
            ForEach(group.items, id: \.title) { item in
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach(item.keys, id: \.self) { KeyCap(key: $0) }
                    }
                    .frame(width: 110, alignment: .leading)
                    Text(item.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 290, alignment: .leading)
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Single-key shortcuts work outside the text field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ShortcutsList()
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .handCursor()
            }
        }
        .padding(28)
    }
}
