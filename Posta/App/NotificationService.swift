import AppKit
import UserNotifications
import os

/// Yeni mail bildirimleri. Bildirime tıklanınca ilgili thread açılır.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    weak var store: MailStore?

    func configure(store: MailStore) {
        self.store = store
        UNUserNotificationCenter.current().delegate = self
    }

    /// Uygulama açılınca istenir; ilk mailde izin penceresi beklenmez
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Log.notifications.info("Bildirim izni: \(granted, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
        }
    }

    /// Ayarlar'da göstermek için: macOS bildirim izni açık mı
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func notify(identifier: UUID, threadID: UUID, sender: String, subject: String, preview: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                Log.notifications.error("Bildirim izni yok, gönderilemedi")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = sender
            content.subtitle = subject
            content.body = preview
            content.sound = .default
            content.userInfo = ["threadID": threadID.uuidString]
            // Aynı konuşmanın bildirimleri Bildirim Merkezi'nde gruplanır
            content.threadIdentifier = threadID.uuidString
            center.add(UNNotificationRequest(identifier: identifier.uuidString, content: content, trigger: nil)) { error in
                if let error { Log.notifications.error("Bildirim eklenemedi: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// "5 yeni mail" — gönderenlerin kısa listesiyle
    func notifySummary(count: Int, senders: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(count) new messages")
            content.body = senders
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo["threadID"] as? String
        await MainActor.run {
            // Pencere kapalıysa yeniden açılır
            MainWindow.open()
            if let raw, let id = UUID(uuidString: raw) {
                NotificationService.shared.store?.reveal(id)
            }
        }
    }
}
