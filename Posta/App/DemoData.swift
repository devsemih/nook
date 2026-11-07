import AppKit
import SwiftUI

/// Örnek verili mod: README ekran görüntüleri ve hesap bağlamadan denemek için.
/// `-NookDemo YES` ile açılınca veritabanı ve ağ hiç kullanılmaz; gerçek hesaplar ve mailler görünmez.
/// `-NookCapture <klasör>` da verilirse pencere sırayla birkaç duruma getirilip PNG olarak kaydedilir ve uygulama kapanır.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "NookDemo") }
    static var captureFolder: URL? {
        UserDefaults.standard.string(forKey: "NookCapture").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Veri

    static let personal = Account(id: UUID(), kind: .icloud, address: "alex.morgan@icloud.com", displayName: "Personal", senderName: "Alex Morgan", color: .purple)
    static let studio = Account(id: UUID(), kind: .gmail, address: "alex@northwind.studio", displayName: "Studio", senderName: "Alex Morgan", color: .teal)

    static func populate(_ store: MailStore) {
        // `-NookDemoEmpty YES`: hiç hesap yok, karşılama ekranı görünür
        guard !UserDefaults.standard.bool(forKey: "NookDemoEmpty") else { return }
        store.accounts = [personal, studio]
        store.threads = people() + feed()
    }

    private static func ago(_ minutes: Double) -> Date { Date.now.addingTimeInterval(-minutes * 60) }

    private static func html(_ paragraphs: [String]) -> String {
        "<div style=\"font-family: -apple-system; font-size: 14px; line-height: 1.55\">"
            + paragraphs.map { "<p>\($0)</p>" }.joined()
            + "</div>"
    }

    private static func person(
        _ account: Account, _ name: String, _ address: String, _ subject: String,
        _ messages: [(fromMe: Bool, minutes: Double, body: [String])], unread: Bool, attachment: String? = nil
    ) -> MailThread {
        let them = Contact(name: name, address: address)
        let me = account.contact
        let built = messages.enumerated().map { index, item in
            let isLast = index == messages.count - 1
            return Message(
                subject: subject,
                from: item.fromMe ? me : them,
                to: [item.fromMe ? them : me],
                date: ago(item.minutes),
                html: html(item.body),
                isRead: !(unread && isLast && !item.fromMe),
                attachments: isLast ? attachment.map { [Attachment(id: UUID(), filename: $0, size: 2_400_000, mimeType: "application/pdf")] } ?? [] : [],
                automated: false
            )
        }
        return MailThread(accountID: account.id, subject: subject, messages: built, location: .inbox)
    }

    private static func people() -> [MailThread] {
        [
            person(personal, "Maya Chen", "maya.chen@icloud.com", "Dinner on Saturday?", [
                (true, 300, ["Are we still on for this weekend?"]),
                (false, 14, ["Yes! My place at 7. I'm making the lemon pasta you liked.", "Bring Sam if he's around. We'll eat on the balcony if the weather holds."]),
            ], unread: true),
            person(studio, "Leo Park", "leo@parkandco.design", "Launch post draft", [
                (false, 52, ["Hey Alex, the draft for the launch post is attached.", "I kept it short and moved the screenshots up front. Could you take a look at the third section before Thursday?"]),
            ], unread: true, attachment: "Launch post v3.pdf"),
            person(personal, "Sofia Alvarez", "sofia.alvarez@gmail.com", "Photos from Lisbon", [
                (false, 170, ["Finally went through the trip photos. The one from the tram is my favourite.", "I'll share the album tonight, mark the ones you want printed."]),
            ], unread: true),
            person(studio, "Daniel Kim", "daniel@brightline.io", "Re: Contract renewal", [
                (false, 2_900, ["We're happy to renew for another year on the same terms."]),
                (true, 1_500, ["Great, send the paperwork over whenever it's ready."]),
            ], unread: false),
            person(personal, "Priya Nair", "priya.nair@outlook.com", "Book recommendation", [
                (false, 4_300, ["You have to read Piranesi. It's short, strange and wonderful. Tell me what you think."]),
            ], unread: false),
            person(studio, "Jonas Weber", "jonas@weber.dev", "Quick question about the API", [
                (false, 6_100, ["Is the rate limit per key or per account? Want to make sure our importer doesn't trip it."]),
            ], unread: false),
            person(personal, "Mom", "helen.morgan@icloud.com", "Call me when you land", [
                (false, 9_000, ["Safe travels! Call me when you land, even if it's late."]),
            ], unread: false),
        ]
    }

    private static func automated(
        _ account: Account, _ name: String, _ address: String,
        _ items: [(subject: String, minutes: Double, body: String, unread: Bool)]
    ) -> [MailThread] {
        let sender = Contact(name: name, address: address)
        return items.map { item in
            let message = Message(
                subject: item.subject, from: sender, to: [account.contact], date: ago(item.minutes),
                html: html([item.body]), isRead: !item.unread, automated: true
            )
            return MailThread(accountID: account.id, subject: item.subject, messages: [message], location: .inbox)
        }
    }

    private static func feed() -> [MailThread] {
        automated(personal, "The Morning Letter", "hello@morningletter.news", [
            ("Five things worth reading this week", 35, "A slow internet, a fast river and the return of the paper map.", true),
            ("The case for boring technology", 1_480, "Why the most reliable tools are the ones you forget about.", true),
            ("Weekend edition: cities without cars", 4_200, "What happens when a neighbourhood gives the street back.", false),
        ])
        + automated(studio, "Shipyard CI", "builds@shipyard.dev", [
            ("Build passed on main", 20, "All 214 checks passed in 3m 41s.", true),
            ("Build passed on release/1.4", 260, "All 214 checks passed in 3m 52s.", true),
            ("Deploy finished: production", 300, "Version 1.4.0 is live.", false),
            ("Build failed on feature/sync", 1_900, "2 tests failed in SyncEngineTests.", false),
        ])
        + automated(personal, "Parcelpoint", "updates@parcelpoint.com", [
            ("Your order is out for delivery", 95, "Arriving today between 2pm and 5pm.", true),
            ("Your order has shipped", 2_600, "Track your package from the warehouse to your door.", false),
        ])
        + automated(studio, "Cloudly Billing", "billing@cloudly.com", [
            ("Your invoice for October", 2_100, "Your invoice of $24.00 is ready.", true),
            ("Payment received", 2_150, "Thanks, we received your payment.", false),
        ])
        + automated(personal, "Design Digest", "digest@designdigest.co", [
            ("Typography that breathes", 3_000, "Twelve layouts that use whitespace like a material.", false),
            ("Colour, calmly", 13_000, "Building palettes that stay quiet.", false),
        ])
        + automated(personal, "Fernway Airlines", "no-reply@fernway.com", [
            ("Your boarding pass", 9_200, "Flight FW 218, seat 14A. Boarding starts at 08:15.", false),
        ])
    }

    // MARK: Ekran görüntüleri

    /// Pencereyi sırayla birkaç duruma getirip kaydeder. Adımlar arasında arayüzün yerleşmesi için kısa beklemeler var.
    static func runCaptures(store: MailStore, themes: ThemeStore) {
        guard let folder = captureFolder else { return }
        if UserDefaults.standard.string(forKey: "NookCaptureSet") == "video" {
            runVideoCaptures(store: store, themes: themes, folder: folder)
            return
        }
        if UserDefaults.standard.string(forKey: "NookCaptureSet") == "island" {
            runIslandCaptures(store: store, folder: folder)
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let window = store.mainWindow else { return }
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()

            // Tema ayarı gerçek tercihlerle aynı yerde duruyor; çıkarken eski haline döner
            let originalTheme = themes.themeID
            let maya = store.threads.first { $0.subject == "Dinner on Saturday?" }?.id
            let feedKey = store.sidebar.stacks.first { $0.name == "Shipyard CI" }?.id

            for (theme, suffix) in [("paper", "light"), ("ink", "dark")] {
                themes.themeID = theme
                store.select(maya)
                try? await Task.sleep(for: .seconds(1.5))
                capture(window, to: folder.appendingPathComponent("people-\(suffix).png"))

                store.select(item: feedKey.map { .stack($0) })
                try? await Task.sleep(for: .seconds(1.5))
                capture(window, to: folder.appendingPathComponent("feed-\(suffix).png"))
            }

            // Çentik: açık hali
            MailIsland.shared.hover(true)
            try? await Task.sleep(for: .seconds(1.2))
            if let panel = MailIsland.shared.panelWindow {
                capture(panel, to: folder.appendingPathComponent("notch-open.png"))
            }
            MailIsland.shared.hover(false)
            try? await Task.sleep(for: .seconds(0.8))
            themes.themeID = originalTheme
            NSApp.terminate(nil)
        }
    }

    /// Çentik: `-islandOptions` ile seçilen liste açık halde ve ilk satıra tıklanınca açılan pencere
    private static func runIslandCaptures(store: MailStore, folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let window = store.mainWindow else { return }
            let island = MailIsland.shared
            island.click()
            try? await Task.sleep(for: .seconds(1.2))
            if let panel = island.panelWindow {
                capture(panel, to: folder.appendingPathComponent("island-open.png"), scale: 2)
            }
            let options = island.options
            let first = store.islandItems(options.content(splitInbox: store.splitInbox), limit: options.rows).first
            first.map { island.open($0.link) }
            try? await Task.sleep(for: .seconds(1.5))
            capture(window, to: folder.appendingPathComponent("island-target.png"), scale: 2)
            NSApp.terminate(nil)
        }
    }

    /// Tanıtım videosu için: gelen kutusu, Akış'ta bir gönderici ve Ayarlar'ın Çentik sekmesi; açık ve koyu
    /// temada, ekranın ölçeğinden bağımsız olarak 2x
    private static func runVideoCaptures(store: MailStore, themes: ThemeStore, folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let window = store.mainWindow else { return }
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            let originalTheme = themes.themeID
            let maya = store.threads.first { $0.subject == "Dinner on Saturday?" }?.id
            let leo = store.threads.first { $0.subject == "Launch post draft" }?.id
            let feedKey = store.sidebar.stacks.first { $0.name == "Shipyard CI" }?.id

            for (theme, suffix) in [("paper", "light"), ("ink", "dark")] {
                themes.themeID = theme
                store.select(maya)
                try? await Task.sleep(for: .seconds(1.5))
                capture(window, to: folder.appendingPathComponent("main-\(suffix).png"), scale: 2)

                store.select(leo)
                try? await Task.sleep(for: .seconds(1.5))
                capture(window, to: folder.appendingPathComponent("leo-\(suffix).png"), scale: 2)


                store.select(item: feedKey.map { .stack($0) })
                try? await Task.sleep(for: .seconds(1.5))
                capture(window, to: folder.appendingPathComponent("feed-\(suffix).png"), scale: 2)

                // Ayarlar menüdeki gibi açılır, Çentik sekmesinde
                UserDefaults.standard.set("notch", forKey: "settingsTab")
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
                    menu.performActionForItem(at: index)
                }
                try? await Task.sleep(for: .seconds(1.5))
                if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.title == "Notch" }) {
                    capture(settings, to: folder.appendingPathComponent("settings-\(suffix).png"), scale: 2)
                    settings.close()
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
            themes.themeID = originalTheme
            NSApp.terminate(nil)
        }
    }

    /// Pencerenin çerçevesiyle birlikte çizimi; ekran kaydı izni gerekmez
    static func capture(_ window: NSWindow, to url: URL, scale: CGFloat? = nil) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let rect = view.bounds
        let rep: NSBitmapImageRep?
        if let scale {
            // Piksel boyutu nokta boyutunun katı olunca çizim o ölçekte yapılır
            rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
            rep?.size = rect.size
        } else {
            rep = view.bitmapImageRepForCachingDisplay(in: rect)
        }
        guard let rep else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
