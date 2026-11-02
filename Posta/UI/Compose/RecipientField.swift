import SwiftUI

/// Kime ve Bilgi alanları: silinebilir çipler, otomatik tamamlama
struct RecipientField<Trailing: View>: View {
    @Environment(MailStore.self) private var store
    let label: LocalizedStringKey
    @Binding var contacts: [Contact]
    var autoFocus = false
    @ViewBuilder var trailing: () -> Trailing

    @State private var input = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var suggestions: [Contact] {
        focused ? store.contactSuggestions(for: input, excluding: contacts) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(contacts) { contact in
                        RecipientChip(contact: contact) {
                            contacts.removeAll { $0.id == contact.id }
                        }
                    }
                    TextField("", text: $input)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { commit(preferSuggestion: true) }
                        .onKeyPress(.delete) {
                            guard input.isEmpty, !contacts.isEmpty else { return .ignored }
                            contacts.removeLast()
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlighted = min(highlighted + 1, suggestions.count - 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            guard !input.isEmpty else { return .ignored }
                            commit(preferSuggestion: true)
                            return .ignored
                        }
                }
                .padding(.vertical, 1)

                trailing()
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            // Satırın her yeri yazma alanına odaklar; çip ve düğmeler kendi imlecini gösterir
            .pointerStyle(.horizontalText)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, contact in
                        Button {
                            add(contact)
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(name: contact.displayName, size: 20)
                                Text(contact.displayName)
                                    .foregroundStyle(.primary)
                                Text(contact.address)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(index == highlighted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .handCursor()
                    }
                }
                .padding(.leading, 50)
                .padding(.bottom, 6)
            }
        }
        .onChange(of: input) { _, value in
            highlighted = 0
            if let last = value.last, [",", ";", "\n"].contains(last) {
                input = String(value.dropLast())
                commit(preferSuggestion: last == "\n")
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit(preferSuggestion: false) }
        }
        .onAppear {
            if autoFocus { DispatchQueue.main.async { focused = true } }
        }
    }

    private func commit(preferSuggestion: Bool) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if preferSuggestion, !suggestions.isEmpty, !trimmed.contains("@") || !Contact(name: "", address: trimmed).isValid {
            add(suggestions[min(highlighted, suggestions.count - 1)])
            return
        }
        guard !trimmed.isEmpty else { return }
        add(parse(trimmed))
    }

    private func add(_ contact: Contact) {
        if !contacts.contains(where: { $0.id == contact.id }) {
            contacts.append(contact)
        }
        input = ""
        highlighted = 0
    }

    /// "Ad Soyad <adres>" veya düz adres
    private func parse(_ text: String) -> Contact {
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let name = text[..<open].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            let address = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return Contact(name: name, address: address)
        }
        return Contact(name: "", address: text)
    }
}

extension RecipientField where Trailing == EmptyView {
    init(label: LocalizedStringKey, contacts: Binding<[Contact]>, autoFocus: Bool = false) {
        self.init(label: label, contacts: contacts, autoFocus: autoFocus) { EmptyView() }
    }
}

private struct RecipientChip: View {
    let contact: Contact
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(contact.displayName)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(isHovering ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .handCursor()
        }
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .foregroundStyle(contact.isValid ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
        .background(
            contact.isValid ? AnyShapeStyle(.tint.opacity(isHovering ? 0.2 : 0.13)) : AnyShapeStyle(Color.red.opacity(isHovering ? 0.2 : 0.13)),
            in: Capsule()
        )
        .onHover { isHovering = $0 }
        .help(contact.isValid ? contact.address : String(localized: "\(contact.address) isn't a valid address"))
    }
}
