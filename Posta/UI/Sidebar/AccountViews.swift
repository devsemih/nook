import SwiftUI

// MARK: - Hesap simgeleri

/// Tüm hesaplar için üst üste binen renk noktaları, tek hesap için baş harf
struct ScopeBadge: View {
    @Environment(MailStore.self) private var store
    @Environment(\.isMonochrome) private var isMonochrome
    let scope: AccountScope
    var size: CGFloat = 26

    var body: some View {
        switch scope {
        case .all:
            let colors = store.accounts.prefix(3).map { isMonochrome ? Color.primary.opacity(0.25) : $0.color.color }
            ZStack {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(color.gradient)
                        .frame(width: size * 0.56, height: size * 0.56)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(dotOffset(index, count: colors.count))
                }
            }
            .frame(width: size, height: size)
        case .account(let id):
            if let account = store.account(id) {
                AccountBadge(account: account, size: size)
            }
        }
    }

    private func dotOffset(_ index: Int, count: Int) -> CGSize {
        let r = size * 0.2
        switch (count, index) {
        case (1, _): return .zero
        case (2, 0): return CGSize(width: -r * 0.8, height: 0)
        case (2, _): return CGSize(width: r * 0.8, height: 0)
        case (_, 0): return CGSize(width: 0, height: -r * 0.75)
        case (_, 1): return CGSize(width: -r * 0.85, height: r * 0.6)
        default: return CGSize(width: r * 0.85, height: r * 0.6)
        }
    }
}

struct AccountBadge: View {
    @Environment(\.isMonochrome) private var isMonochrome
    let account: Account
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(isMonochrome ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(account.color.color.gradient))
            .frame(width: size, height: size)
            .overlay {
                Text(Contact.initials(for: account.displayName).prefix(1))
                    .font(.system(size: size * 0.46, weight: .semibold, design: isMonochrome ? .default : .rounded))
                    .foregroundStyle(isMonochrome ? Color.primary : .white)
            }
    }
}

// MARK: - Hesap menüsü

struct AccountMenu: View {
    @Environment(MailStore.self) private var store
    let account: Account

    var body: some View {
        Button("Rename…") { store.renamingAccount = account }

        Menu("Color") {
            ForEach(AccountColor.allCases) { color in
                Button {
                    store.updateAccount(account.id) { $0.color = color }
                } label: {
                    Label {
                        Text(color.title)
                    } icon: {
                        Image(nsImage: .dot(color.nsColor))
                    }
                }
            }
        }

        Button("Sign In Again…") { store.reauthAccount = account }

        Divider()

        Button("Remove Account", role: .destructive) { store.removeAccount(account.id) }
    }
}

// MARK: - Hesap sheet'leri

struct RenameAccountSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename account")
                .font(.headline)
            TextField("Display name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text(account.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .handCursor()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .handCursor()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = account.displayName }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateAccount(account.id) { $0.displayName = trimmed }
        dismiss()
    }
}

struct ReauthSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: Account
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
                .frame(width: 60, height: 60)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: 6) {
                Text("Sign in again")
                    .font(.title3.weight(.semibold))
                Text(account.kind == .gmail
                     ? "The app password for \(account.address) is no longer valid. Create a new one on your Google Account's App passwords page and paste it here."
                     : "The app-specific password for \(account.address) is no longer valid. Create a new one at account.apple.com and paste it here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField(account.kind == .icloud ? "xxxx-xxxx-xxxx-xxxx" : "xxxx xxxx xxxx xxxx", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(signIn)

            Button(account.kind == .icloud ? "Open account.apple.com" : "Open the App passwords page") {
                let link = account.kind == .icloud ? "https://account.apple.com/account/manage" : "https://myaccount.google.com/apppasswords"
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.link)
            .font(.callout)
            .handCursor()

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .handCursor()
                Spacer()
                Button(action: signIn) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .prominentButton()
                .keyboardShortcut(.defaultAction)
                .handCursor()
                .disabled(isWorking || !AddAccountSheet.isAppPassword(password))
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func signIn() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let value = AddAccountSheet.normalizedPassword(password, kind: account.kind)
                let username = try await IMAPProvider.testLogin(server: .for(account.kind), address: account.address, password: value)
                try store.updateCredentials(account.id, IMAPCredentials(username: username, password: value))
                dismiss()
            } catch IMAPError.authenticationFailed {
                errorMessage = String(localized: "The password wasn't accepted. Paste the app password you just created.")
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
