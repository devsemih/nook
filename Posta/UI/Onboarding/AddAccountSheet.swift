import SwiftUI

/// Her adımda tek iş ve tek ana buton. Hata olursa aynı adımda kalınır.
/// iCloud ve Gmail aynı yolu izler: uygulamaya özel şifre ile IMAP/SMTP.
struct AddAccountSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Step: Hashable { case provider, credentials, details }

    @State private var step: Step = .provider
    @State private var kind: AccountKind = .icloud

    @State private var addressInput = ""
    @State private var passwordInput = ""
    @State private var isTesting = false
    @State private var credentials: IMAPCredentials?

    @State private var errorMessage: String?
    @State private var address = ""
    @State private var senderName = ""
    @State private var displayName = ""
    @State private var color: AccountColor = .blue

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .provider: providerStep
                case .credentials: credentialsStep
                case .details: detailsStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 500)
        .animation(.smooth(duration: 0.28), value: step)
        .animation(.snappy(duration: 0.2), value: errorMessage)
    }

    // MARK: - Adımlar

    private var providerStep: some View {
        VStack(spacing: 20) {
            StepHeader(symbol: "at", title: "Add account", subtitle: "Which account do you want to connect?")

            VStack(spacing: 10) {
                ProviderCard(symbol: "icloud.fill", tint: .blue, title: "iCloud", subtitle: "With an app-specific password") {
                    choose(.icloud)
                }
                ProviderCard(symbol: "envelope.fill", tint: .red, title: "Gmail", subtitle: "With an app password") {
                    choose(.gmail)
                }
            }
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if kind == .icloud {
                StepHeader(symbol: "key.fill", title: "Connect your iCloud account",
                           subtitle: "iCloud Mail needs an app-specific password, not your Apple Account password.")
                VStack(alignment: .leading, spacing: 11) {
                    SetupStep(number: 1, text: "Open account.apple.com.", link: "https://account.apple.com/account/manage")
                    SetupStep(number: 2, text: "Create a new password under **Sign-In and Security** › **App-Specific Passwords**.", link: nil)
                    SetupStep(number: 3, text: "Paste your address and the password below.", link: nil)
                }
                .font(.callout)
            } else {
                StepHeader(symbol: "key.fill", title: "Connect your Gmail account",
                           subtitle: "You need a 16-letter app password created for Nook, not your regular Google password.")
                VStack(alignment: .leading, spacing: 11) {
                    SetupStep(number: 1, text: "**2-Step Verification** must be turned on for your Google Account.", link: "https://myaccount.google.com/signinoptions/twosv")
                    SetupStep(number: 2, text: "Create a new password named “Nook” on the **App passwords** page.", link: "https://myaccount.google.com/apppasswords")
                    SetupStep(number: 3, text: "Paste your Gmail address and the password below.", link: nil)
                }
                .font(.callout)
            }

            VStack(spacing: 8) {
                TextField(kind == .icloud ? "iCloud address (e.g. name@icloud.com)" : "Gmail address (e.g. name@gmail.com)", text: $addressInput)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                SecureField(kind == .icloud ? "xxxx-xxxx-xxxx-xxxx" : "xxxx xxxx xxxx xxxx", text: $passwordInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(testConnection)
            }
            .disabled(isTesting)
            .onChange(of: passwordInput) { _, value in
                errorMessage = nil
                // Şifre yapıştırılınca bağlantı hemen denenir
                if Self.isAppPassword(value), !addressInput.isEmpty { testConnection() }
            }

            if isTesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Testing connection…")
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            ErrorText(message: errorMessage)
        }
    }

    private var detailsStep: some View {
        VStack(spacing: 20) {
            StepHeader(symbol: "checkmark.circle.fill", title: "Account connected", subtitle: "Finally, give this account a name and color. You can change them later.")

            HStack(spacing: 12) {
                ColorDot(color: color.color, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.isEmpty ? kind.title : displayName)
                        .font(.headline)
                    Text(address)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Form {
                TextField("Display name", text: $displayName)
                TextField("Sender name", text: $senderName)
                LabeledContent("Color") {
                    HStack(spacing: 7) {
                        ForEach(AccountColor.allCases) { option in
                            Button {
                                color = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        if option == color {
                                            Circle().strokeBorder(.white, lineWidth: 2).padding(2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(option.title)
                            .handCursor()
                            .accessibilityLabel(option.title)
                        }
                    }
                }
            }
            .formStyle(.columns)
        }
    }

    // MARK: - Alt çubuk

    private var footer: some View {
        HStack {
            switch step {
            case .provider:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .handCursor()
            case .credentials:
                Button {
                    errorMessage = nil
                    step = .provider
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                .handCursor()
                .disabled(isTesting)
            case .details:
                EmptyView()
            }

            Spacer()

            switch step {
            case .provider:
                EmptyView()
            case .credentials:
                Button("Connect", action: testConnection)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
                    .handCursor()
                    .disabled(isTesting || addressInput.isEmpty || passwordInput.isEmpty)
            case .details:
                Button("Done", action: finish)
                    .prominentButton()
                    .keyboardShortcut(.defaultAction)
                    .handCursor()
            }
        }
    }

    // MARK: - Mantık

    private func choose(_ kind: AccountKind) {
        if self.kind != kind {
            addressInput = ""
            passwordInput = ""
        }
        self.kind = kind
        errorMessage = nil
        step = .credentials
    }

    private func testConnection() {
        let address = addressInput.trimmingCharacters(in: .whitespaces).lowercased()
        let password = Self.normalizedPassword(passwordInput, kind: kind)
        errorMessage = nil

        guard Contact(name: "", address: address).isValid else {
            errorMessage = kind == .icloud ? String(localized: "Enter a valid iCloud address, for example name@icloud.com.") : String(localized: "Enter a valid Gmail address, for example name@gmail.com.")
            return
        }
        guard !store.accounts.contains(where: { $0.address.lowercased() == address }) else {
            errorMessage = String(localized: "This account has already been added.")
            return
        }
        guard Self.isAppPassword(password) else {
            errorMessage = kind == .icloud
                ? String(localized: "An app-specific password has 16 letters (xxxx-xxxx-xxxx-xxxx). Paste the password you created, not your Apple Account password.")
                : String(localized: "An app password has 16 letters (xxxx xxxx xxxx xxxx). Paste the password you created, not your Google password.")
            return
        }
        guard !isTesting else { return }
        isTesting = true
        let kind = self.kind
        Task {
            defer { isTesting = false }
            do {
                let username = try await IMAPProvider.testLogin(server: .for(kind), address: address, password: password)
                credentials = IMAPCredentials(username: username, password: password)
                prepareDetails(address: address)
            } catch IMAPError.authenticationFailed {
                errorMessage = kind == .icloud
                    ? String(localized: "The password wasn't accepted. Use the app-specific password you created at account.apple.com, not your Apple Account password. This password can't be created if two-factor authentication is off.")
                    : String(localized: "The password wasn't accepted. Use an app password, not your regular Google password. If the App passwords page won't open, turn on 2-Step Verification first. On work accounts, an administrator may have turned this feature off.")
            } catch let error where error is URLError || error is ConnectionError {
                errorMessage = String(localized: "Couldn't connect to \(IMAPServer.for(kind).imapHost). Check your internet connection and try again.")
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func prepareDetails(address: String) {
        self.address = address
        let fullName = NSFullUserName()
        senderName = fullName.isEmpty ? address : fullName
        displayName = kind == .icloud ? "iCloud" : (address.components(separatedBy: "@").first ?? "Gmail")
        let used = Set(store.accounts.map(\.color))
        color = AccountColor.allCases.first { !used.contains($0) } ?? .blue
        step = .details
    }

    private func finish() {
        guard let credentials else {
            errorMessage = String(localized: "Sign-in details are missing. Please start over.")
            step = .credentials
            return
        }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let sender = senderName.trimmingCharacters(in: .whitespaces)
        store.addAccount(
            kind: kind,
            address: address,
            senderName: sender.isEmpty ? address : sender,
            displayName: name.isEmpty ? kind.title : name,
            color: color,
            credentials: credentials
        )
        dismiss()
    }

    /// Gmail şifreyi boşluklu gösterir ("abcd efgh ijkl mnop"); boşluklar atılır
    static func normalizedPassword(_ text: String, kind: AccountKind) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .gmail ? trimmed.replacingOccurrences(of: " ", with: "") : trimmed
    }

    static func isAppPassword(_ text: String) -> Bool {
        let letters = text.filter { $0 != "-" && $0 != " " }
        return letters.count == 16 && letters.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

// MARK: - Parçalar

private struct StepHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .glassEffect(.regular, in: .circle)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProviderCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

private struct NumberedStep<Content: View>: View {
    let number: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
                .background(.tint.opacity(0.14), in: Circle())
            content()
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let text: LocalizedStringKey
    let link: String?
    var copy: String?

    var body: some View {
        NumberedStep(number: number) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let copy {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy bundle ID")
                    .handCursor()
                }
                if let link, let url = URL(string: link) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                    .controlSize(.small)
                    .handCursor()
                }
            }
        }
    }
}

private struct ErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
