import AppKit
import os

/// Pencere kapanınca Posta Dock'ta çalışmaya devam eder; senkron ve bildirimler sürer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Pencere ilk açılınca bağlanır; Posta bir widget bağlantısıyla açıldıysa bekleyen bağlantı o an uygulanır
    weak var store: MailStore? {
        didSet { openPendingLinks() }
    }
    private var pendingLinks: [PostaLink] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Kenar çubuğu ince hesap şeridine dönüştü; macOS'un hatırladığı eski sütun genişlikleri bir kez unutulur
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "layoutVersion") < 2 else { return }
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.localizedCaseInsensitiveContains("split") }
        for key in keys { defaults.removeObject(forKey: key) }
        Log.app.info("Eski sütun düzeni sıfırlandı: \(keys.joined(separator: ", "), privacy: .public)")
        defaults.set(2, forKey: "layoutVersion")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock ikonuna tıklanınca kapalı ana pencere yeniden açılır
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.open() }
        return true
    }

    /// Widget'a tıklanınca: posta://thread/…, posta://inbox, posta://compose
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingLinks += urls.compactMap(PostaLink.init(url:))
        MainWindow.open()
        openPendingLinks()
    }

    private func openPendingLinks() {
        guard let store, !pendingLinks.isEmpty else { return }
        for link in pendingLinks { store.open(link) }
        pendingLinks.removeAll()
    }
}

/// SwiftUI'ın pencere açma eylemi; ilk açılışta ContentView tarafından kaydedilir
enum MainWindow {
    static var opener: (() -> Void)?

    static func open() {
        NSApp.activate()
        opener?()
    }
}
