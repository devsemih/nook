import SwiftUI

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var railTooltip = RailTooltip()

    var body: some View {
        @Bindable var store = store

        Group {
            if store.accounts.isEmpty {
                WelcomeView()
            } else {
                MainSplitView()
            }
        }
        .environment(railTooltip)
        // Kaydırma çubukları hiçbir yerde görünmez; içerik yine kayar
        .scrollIndicators(.never)
        .overlay { RailTooltipLayer(tooltip: railTooltip) }
        .containerBackground(themes.canvas, for: .window)
        .background(WindowAccessor { window in store.mainWindow = window })
        .overlay(alignment: .bottom) { ToastHost() }
        .overlay {
            if store.showQuickSwitcher {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.showQuickSwitcher)
        .sheet(item: composeSheet) { ComposeSheet(draft: $0) }
        .sheet(isPresented: $store.showAddAccount) { AddAccountSheet() }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsSheet() }
        .sheet(item: $store.renamingAccount) { RenameAccountSheet(account: $0) }
        .sheet(item: $store.reauthAccount) { ReauthSheet(account: $0) }
        .onAppear {
            MainWindow.opener = { [openWindow] in openWindow(id: "main") }
            store.undoManager = undoManager
            KeyboardRouter.shared.install(store: store)
            NSApp.dockTile.badgeLabel = badgeText
        }
        .onChange(of: undoManager) { store.undoManager = undoManager }
        .onChange(of: store.totalUnread) { NSApp.dockTile.badgeLabel = badgeText }
        .onChange(of: scenePhase) { if scenePhase == .active { store.refresh() } }
    }

    private var composeSheet: Binding<Draft?> {
        Binding(
            get: { store.composer?.presentation == .sheet ? store.composer : nil },
            set: { if $0 == nil { store.dismissComposeSheet() } }
        )
    }

    private var badgeText: String? {
        store.totalUnread > 0 ? "\(store.totalUnread)" : nil
    }
}

/// Discord ve Slack gibi: en solda hesap şeridi, yanında kişiler ve kanallar, sağda sohbet.
/// Gelen kutusu dışındaki klasörlerde ve aramada araya klasik mail listesi girer.
/// Şeridin rengi pencerenin çerçevesi olur; içerik bu çerçevenin üstünde köşeleri yuvarlak bir panel gibi durur.
private struct MainSplitView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    /// Panelin çerçeveden uzaklığı ve köşesi
    static let inset: CGFloat = 8
    static let radius: CGFloat = 14

    var body: some View {
        let showsList = store.folder != .inbox || store.isSearching
        let panel = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        HStack(spacing: 0) {
            AccountRail()
                // Pencere düğmeleri şeridin üstünde durur
                .padding(.top, 40)
                .frame(width: 76)
                .frame(maxHeight: .infinity)
            HStack(spacing: 0) {
                // Gelen kutusunda kişiler ve kanallar; başka bir klasörde ya da aramada aynı yerde mail listesi
                VStack(spacing: 0) {
                    Group {
                        if showsList {
                            MessageListView()
                        } else {
                            ChannelSidebar()
                        }
                    }
                    .frame(maxHeight: .infinity)
                    FolderBar()
                }
                .frame(width: 300)
                .background(themes.sidebar)
                Divider()
                DetailView()
            }
            .clipShape(panel)
            .overlay(panel.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .padding([.top, .bottom, .trailing], Self.inset)
        }
        .background(themes.rail)
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.25), value: showsList)
    }
}

private struct ToastHost: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ZStack {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 20)
        .animation(.snappy(duration: 0.25), value: store.toast)
    }
}

struct ToastView: View {
    @Environment(MailStore.self) private var store
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = toast.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(toast.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Text(toast.message)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if toast.undoable {
                Divider().frame(height: 14)
                Button("Undo") { store.undo() }
                    .buttonStyle(.borderless)
                    .handCursor()
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .onHover { hovering in
            // Fare üzerindeyken kaybolmasın diye yeniden zamanla
            if !hovering, store.toast?.id == toast.id {
                store.showToast(toast.message, symbol: toast.symbol, undoable: toast.undoable, isError: toast.isError)
            }
        }
    }
}
