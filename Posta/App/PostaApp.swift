import SwiftUI

@main
struct PostaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MailStore
    @State private var themes = ThemeStore()
    private let engine: SyncEngine

    init() {
        let database: LocalDatabase?
        if DemoData.isEnabled {
            // Örnek veri: gerçek veritabanına dokunulmaz, ağa çıkılmaz
            database = nil
        } else {
            do {
                database = try LocalDatabase.openDefault()
            } catch {
                NSLog("Posta: veritabanı açılamadı: %@", String(describing: error))
                database = nil
            }
        }
        let store = MailStore(database: database)
        let engine = SyncEngine(store: store, database: database, syncStates: store.loadedSyncStates)
        if DemoData.isEnabled {
            DemoData.populate(store)
        } else {
            store.engine = engine
        }
        _store = State(initialValue: store)
        self.engine = engine
    }

    var body: some Scene {
        Window("Nook", id: "main") {
            ContentView()
                .environment(store)
                .theme(themes)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear {
                    NotificationService.shared.configure(store: store)
                    RemoteContentBlocker.prepare()
                    themes.apply()
                    if DemoData.isEnabled {
                        MailIsland.shared.start(store: store)
                        DemoData.runCaptures(store: store, themes: themes)
                    } else {
                        engine.start()
                        WidgetPublisher.shared.start(store: store, themes: themes)
                        MailIsland.shared.start(store: store)
                    }
                    appDelegate.store = store
                }
        }
        .defaultSize(width: 1360, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { PostaCommands(store: store) }

        Settings {
            SettingsView()
                // Ayarlar çoğunlukla anahtarlardan oluşuyor; siyah-beyaz temada koyu gri
                .tint(themes.controlTint)
                .environment(store)
                .theme(themes)
        }
    }
}
