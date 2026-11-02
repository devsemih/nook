import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") {
                AppearanceSettings()
            }
            Tab("Notch", systemImage: "menubar.rectangle", value: "notch") {
                NotchSettings()
            }
            Tab("Accounts", systemImage: "at", value: "accounts") {
                AccountsSettings()
            }
            Tab("Shortcuts", systemImage: "keyboard", value: "shortcuts") {
                ScrollView {
                    ShortcutsList()
                        .padding(28)
                }
            }
        }
        .frame(width: 680, height: 520)
        .scrollIndicators(.never)
    }
}

// MARK: - Genel

private struct GeneralSettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage(SettingsKey.readBehavior) private var readBehavior = ReadBehavior.onSelect.rawValue
    @AppStorage(SettingsKey.alwaysLoadRemoteImages) private var alwaysLoadRemote = false
    @AppStorage(SettingsKey.darkMailStyle) private var darkMailStyle = DarkMailStyle.lightCard.rawValue
    @AppStorage(SettingsKey.notificationsEnabled) private var notifications = true
    @State private var systemAllowsNotifications = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Reading") {
                SettingRow("Mark as read") {
                    Picker("Mark as read", selection: $readBehavior) {
                        ForEach(ReadBehavior.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                SettingRow("Messages in dark mode", detail: "For messages with their own colors, like newsletters, notifications, and invoices. Plain-text messages always follow the theme.") {
                    Picker("Messages in dark mode", selection: $darkMailStyle) {
                        ForEach(DarkMailStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                SettingRow("Always load remote images", detail: "When off, tracking pixels can't run. You can show images in any message with one click.") {
                    Toggle("Always load remote images", isOn: $alwaysLoadRemote)
                }
            }

            Section(String(localized: "inbox.section", defaultValue: "Inbox", comment: "Bölüm başlığı; klasör adı olan Inbox'tan ayrı")) {
                SettingRow("People and Feed", detail: "Mail from people stays on top; newsletters, notifications, and invoices are grouped by sender.") {
                    Toggle("People and Feed", isOn: $store.splitInbox)
                }
            }

            Section("Notifications") {
                SettingRow("New mail notifications", detail: "Shows a macOS notification when new mail arrives in your inbox.") {
                    Toggle("New mail notifications", isOn: $notifications)
                }
                .onChange(of: notifications) { _, enabled in
                    if enabled { NotificationService.shared.requestAuthorization() }
                }
                if notifications && !systemAllowsNotifications {
                    LabeledContent {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.odinstudio.posta") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .handCursor()
                    } label: {
                        Label("macOS notifications are turned off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                SettingRow("Open at login", detail: "When you close the window, Nook keeps running in the background and sending notifications. Quitting with ⌘Q stops notifications.") {
                    Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                }
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent("Local cache") {
                    Button("Clear and download again") { store.eraseLocalCache() }
                        .handCursor()
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Accounts and drafts are kept; mail is downloaded again from the server.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            systemAllowsNotifications = await NotificationService.shared.isAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { systemAllowsNotifications = await NotificationService.shared.isAuthorized() }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            store.showToast(String(localized: "Couldn't change the login item setting: \(error.localizedDescription)"), symbol: "exclamationmark.triangle", isError: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Form satırı: başlık ve açıklama solda, denetim sağda. El imleci yalnızca tıklanan denetimin üzerinde çıkar;
/// Toggle ya da Picker'ın kendi etiketi kullanılsaydı tıklanmayan başlık da el imleci gösterirdi.
struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
                .labelsHidden()
                .toggleStyle(FormSwitchStyle())
                .handCursor()
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

/// Form'un kendi satırlarındaki küçük anahtar; etiketi ayrı satıra alınınca onay kutusuna dönmesin
private struct FormSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

// MARK: - Hesaplar

private struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var selection: UUID?
    @State private var showsAddAccount = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 10) {
                            ColorDot(color: account.color.color, size: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                Text(account.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if account.status == .needsReauth {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .handCursor()
                        .tag(account.id)
                    }
                    .onMove { store.moveAccounts(from: $0, to: $1) }
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: 0) {
                    Button {
                        showsAddAccount = true
                    } label: {
                        Image(systemName: "plus").frame(width: 26, height: 22)
                    }
                    .help("Add account")
                    .handCursor()
                    Divider().frame(height: 16)
                    Button {
                        if let selection { store.removeAccount(selection) }
                    } label: {
                        Image(systemName: "minus").frame(width: 26, height: 22)
                    }
                    .help("Remove account")
                    .handCursor()
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 230)

            Divider()

            if let id = selection, store.account(id) != nil {
                AccountDetail(accountID: id)
            } else {
                ContentUnavailableView("Select an account", systemImage: "at", description: Text("Select an account on the left to see its details."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showsAddAccount) { AddAccountSheet() }
        .onAppear { if selection == nil { selection = store.accounts.first?.id } }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = ids.first }
        }
    }
}

private struct AccountDetail: View {
    @Environment(MailStore.self) private var store
    let accountID: UUID

    private func binding<T>(_ keyPath: WritableKeyPath<Account, T>, default value: T) -> Binding<T> {
        Binding(
            get: { store.account(accountID)?[keyPath: keyPath] ?? value },
            set: { newValue in store.updateAccount(accountID) { $0[keyPath: keyPath] = newValue } }
        )
    }

    var body: some View {
        if let account = store.account(accountID) {
            Form {
                Section {
                    LabeledContent("Address", value: account.address)
                    LabeledContent("Type") {
                        Label(account.kind == .gmail ? "Gmail (IMAP, app password)" : "iCloud (IMAP, app-specific password)", systemImage: account.kind.symbol)
                    }
                    LabeledContent("Status") {
                        switch account.status {
                        case .ok: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .syncing: Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                        case .needsReauth:
                            HStack {
                                Label("Sign-in required", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Button("Sign in") { store.reauthAccount = account }
                                    .handCursor()
                            }
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }

                Section {
                    TextField("Display name", text: binding(\.displayName, default: ""))
                    TextField("Sender name", text: binding(\.senderName, default: ""))
                    SettingRow("Color") {
                        Picker("Color", selection: binding(\.color, default: .blue)) {
                            ForEach(AccountColor.allCases) { color in
                                Label {
                                    Text(color.title)
                                } icon: {
                                    Image(nsImage: .dot(color.nsColor))
                                }
                                .tag(color)
                            }
                        }
                    }
                }

                Section("Signature") {
                    TextEditor(text: binding(\.signature, default: ""))
                        .font(.body)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                }

                Section {
                    HStack {
                        Button("Sign in again") { store.reauthAccount = account }
                            .handCursor()
                        Spacer()
                        Button("Remove account", role: .destructive) { store.removeAccount(accountID) }
                            .handCursor()
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
