import AppKit
import SwiftUI

/// Çentikte yaşayan küçük ada. Dinlenirken çentiğin kendisidir; insanlardan okunmamış mail varsa iki yanına
/// yazanın yüzü ve sayı çıkar. Yeni mail gelince birkaç saniyeliğine açılıp kimden geldiğini gösterir,
/// fareyle üzerine gelince son konuşmaları ve Akış'ı açar. Posta'nın penceresi kapalıyken de yaşar.
@Observable
final class MailIsland {
    static let shared = MailIsland()

    enum Mode: Equatable {
        case rest
        case peek(Peek)
        /// Gelen maildeki doğrulama kodu, kopyalama düğmesiyle
        case code(Code)
        case open
    }

    struct Code: Equatable {
        var threadID: UUID
        var sender: String
        var code: String
    }

    struct Peek: Equatable {
        var threadID: UUID
        var sender: String
        var subject: String
        /// Aynı anda gelen diğer mailler
        var others: Int
    }

    private(set) var mode: Mode = .rest
    /// Dinlenirken gösterecek bir şey yoksa ada çentiğin içine çekilir
    private(set) var isCompact = false
    /// Çentiğin boyutu; çentiksiz ekranda genişlik sıfır
    private(set) var notch = CGSize(width: 0, height: 32)

    @ObservationIgnored private var panel: NSPanel?
    /// Örnek veri modunda ekran görüntüsü almak için
    var panelWindow: NSWindow? { panel }
    @ObservationIgnored private weak var store: MailStore?
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.showsIsland) as? Bool ?? true
    }

    var options: IslandOptions { .current }

    func start(store: MailStore) {
        guard self.store == nil else { return }
        self.store = store
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Menü çubuğunun da üstünde, tüm masaüstlerinde ve tam ekran uygulamaların yanında
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        let host = NSHostingView(rootView: IslandView(island: self).environment(store))
        // Pencere boyutunu ada belirler. SwiftUI görünümü doğrudan pencerenin içeriği olursa pencerenin
        // en küçük/en büyük boyutunu da yönetmeye çalışıyor, yerleşim döngüye girip çöküyor; düz bir kabın içine konur.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        let container = NSView()
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds
        self.panel = panel
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        update()
    }

    /// Ayar değişince çağrılır
    func update() {
        guard let panel else { return }
        if isEnabled {
            layout()
            panel.orderFrontRegardless()
        } else {
            mode = .rest
            panel.orderOut(nil)
        }
    }

    // MARK: Durumlar

    /// İnsanlardan yeni mail geldi: ada birkaç saniyeliğine açılır
    func announce(_ peek: Peek) {
        let options = options
        guard isEnabled, options.announces, mode != .open else { return }
        set(.peek(peek))
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(options.peekSeconds))
            guard !Task.isCancelled, let self, case .peek = self.mode else { return }
            self.set(.rest)
        }
    }

    /// Doğrulama kodu geldi: Akış'tan gelse de gösterilir, kopyalanana ya da süre dolana kadar açık kalır
    func announce(code: Code) {
        guard isEnabled, options.showsCodes, mode != .open else { return }
        set(.code(code))
        scheduleCodeEnd(after: 20)
    }

    /// Kod kopyalandı: "Kopyalandı" bir an görünür, sonra ada kapanır
    func copied() {
        scheduleCodeEnd(after: 1.4)
    }

    private func scheduleCodeEnd(after seconds: Double) {
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, case .code = self.mode else { return }
            self.set(.rest)
        }
    }

    func hover(_ inside: Bool) {
        closeTask?.cancel()
        if case .code = mode {
            // Kod okunurken kapanmasın; fare çıkınca birkaç saniye daha durur
            if inside { peekTask?.cancel() } else { scheduleCodeEnd(after: 4) }
            return
        }
        if inside {
            guard options.trigger == .hover else { return }
            peekTask?.cancel()
            if mode != .open { set(.open) }
        } else if mode == .open {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                self?.set(.rest)
            }
        }
    }

    /// Tıklayınca açılma seçiliyse; fareyle açılmada da tıklamak açar
    func click() {
        guard mode != .open else { return }
        peekTask?.cancel()
        set(.open)
    }

    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        set(mode, compact: compact)
    }

    /// Adadan Posta'ya: konuşma, gelen kutusu ya da yeni mail
    func open(_ link: PostaLink) {
        MainWindow.open()
        store?.open(link)
        set(.rest)
    }

    private func set(_ new: Mode, compact: Bool? = nil) {
        let compact = compact ?? isCompact
        let old = size(for: mode)
        let target = Self.size(for: new, notch: notch, options: options, compact: compact, feed: showsFeedLine)
        // Pencere önce iki boyutu da kapsayacak kadar büyür, animasyon bitince yeni boyuta iner; yoksa içerik kırpılır
        resize(to: CGSize(width: max(old.width, target.width), height: max(old.height, target.height)))
        withAnimation(Self.spring) {
            mode = new
            isCompact = compact
        }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.mode == new, self.isCompact == compact else { return }
            self.resize(for: new)
        }
    }

    // MARK: Yerleşim

    func size(for mode: Mode) -> CGSize {
        Self.size(for: mode, notch: notch, options: options, compact: isCompact, feed: showsFeedLine)
    }

    private var showsFeedLine: Bool { options.showsFeed && (store?.splitInbox ?? true) }

    /// Adanın her durumdaki boyutu; pencere bundan biraz geniştir, gölge sığsın
    static func size(for mode: Mode, notch: CGSize, options: IslandOptions, compact: Bool, feed: Bool) -> CGSize {
        switch mode {
        case .rest where compact:
            return CGSize(width: max(notch.width, 120) + 2 * IslandView.ear, height: notch.height)
        case .rest:
            return CGSize(width: max(notch.width, 200) + 2 * IslandView.ear + 2 * IslandView.side, height: notch.height)
        case .peek, .code:
            return CGSize(width: 420, height: notch.height + 72)
        case .open:
            // Başlık, satırlar (her biri 42), Akış satırı ve alt boşluk
            let content = 10 + 28 + 12 + CGFloat(options.rows) * 42 + (feed ? 38 : 0) + 14 + 20
            return CGSize(width: 460, height: notch.height + content)
        }
    }

    private func layout() {
        guard let screen = Self.screen else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            notch = CGSize(width: 0, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
        }
        resize(for: mode)
    }

    private func resize(for mode: Mode) {
        resize(to: size(for: mode))
    }

    private func resize(to size: CGSize) {
        guard let panel, let screen = Self.screen else { return }
        let width = size.width + 40
        let height = size.height + 30
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
    }

    /// Çentikli ekran varsa o, yoksa ana ekran
    private static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

// MARK: - Görünüm

/// Çentikteki canlı ada: verileri ve seçenekleri okur, çizimi `IslandSurface`a bırakır
struct IslandView: View {
    @Environment(MailStore.self) private var store
    @AppStorage(SettingsKey.islandOptions) private var options = IslandOptions()
    let island: MailIsland

    /// Çentiğin üst köşelerindeki içe kıvrık kulak ve dinlenirken iki yandaki göstergelerin genişliği
    static let ear: CGFloat = 8
    static let side: CGFloat = 40

    var body: some View {
        let summary = store.widgetSnapshot(accent: nil)
        let syncing = store.syncPhase == .syncing || store.overallSyncProgress != nil
        let compact = IslandSurface.isCompact(summary: summary, options: options)

        VStack(spacing: 0) {
            IslandSurface(
                mode: island.mode,
                size: island.size(for: island.mode),
                notch: island.notch.height,
                summary: summary,
                options: options,
                isSyncing: syncing,
                open: { island.open($0) },
                tap: { island.click() },
                copied: { island.copied() }
            )
            .onHover { island.hover($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { island.setCompact(compact) }
        .onChange(of: compact) { _, value in island.setCompact(value) }
        .onChange(of: options) { island.update() }
    }
}

/// Logo gibi yalnızca siyah ve beyaz: siyah çentik, beyaz kemer, beyaz yazı. Renk yok;
/// yeniyi parlaklık ve ağırlık anlatır. Ayarlardaki önizleme de bunu çizer.
struct IslandSurface: View {
    let mode: MailIsland.Mode
    let size: CGSize
    let notch: CGFloat
    let summary: WidgetSnapshot
    let options: IslandOptions
    var isSyncing = false
    let open: (PostaLink) -> Void
    let tap: () -> Void
    var copied: () -> Void = {}

    /// İnsanlardan gelen okunmamışlar; seçilirse Akış da eklenir
    static func badge(summary: WidgetSnapshot, options: IslandOptions) -> Int {
        summary.accounts.reduce(0) { $0 + $1.people + (options.badge == .everything ? $1.feed : 0) }
    }

    /// İki yanda da gösterilecek bir şey kalmadıysa
    static func isCompact(summary: WidgetSnapshot, options: IslandOptions) -> Bool {
        let badge = badge(summary: summary, options: options)
        let showsLeading = options.leading != .hidden && !(options.hidesWhenRead && badge == 0)
        let showsBadge = options.badge != .hidden && badge > 0
        return !showsLeading && !showsBadge
    }

    var body: some View {
        let people = summary.accounts.reduce(0) { $0 + $1.people }

        ZStack(alignment: .top) {
            switch mode {
            case .rest:
                rest
                    .contentShape(Rectangle())
                    .onTapGesture(perform: tap)
            case .peek(let peek):
                PeekContent(peek: peek, notch: notch, showsSubject: options.showsSubject, open: open)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            case .code(let code):
                CodeContent(code: code, notch: notch, copied: copied)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            case .open:
                OpenContent(summary: summary, count: people, notch: notch, options: options, open: open)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding(.horizontal, IslandView.ear)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .background(.black, in: NotchShape(ear: IslandView.ear, radius: mode == .rest ? 10 : 26))
        .shadow(color: .black.opacity(mode == .rest ? 0 : 0.4), radius: 18, y: 8)
        .contentShape(NotchShape(ear: IslandView.ear, radius: 26))
        .environment(\.colorScheme, .dark)
    }

    /// Dinlenirken: solda kemer ya da son yazanın baş harfleri, sağda yeni sayısı. Her şey okunmuşsa
    /// kemer söner, eşitlenirken yavaşça nefes alır.
    private var rest: some View {
        let badge = Self.badge(summary: summary, options: options)
        let showsLeading = options.leading != .hidden && !(options.hidesWhenRead && badge == 0)
        let latest = summary.people.filter(\.isUnread).max { $0.date < $1.date }

        return HStack {
            if showsLeading {
                if options.leading == .sender, let latest {
                    IslandAvatar(name: latest.sender, size: min(20, notch - 8))
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    IslandMark(size: 13, isSyncing: isSyncing)
                        .opacity(badge > 0 || isSyncing ? 1 : 0.45)
                }
            }
            Spacer()
            if options.badge != .hidden, badge > 0 {
                Text(badge, format: .number)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(badge)))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: notch)
        .animation(MailIsland.spring, value: badge)
    }
}

/// Logodaki kemer, çentiğe göre küçültülmüş
private struct IslandMark: View {
    var size: CGFloat
    var isSyncing = false

    var body: some View {
        let line = size * 0.22
        ArchLine()
            .stroke(.white, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .padding(line / 2)
            .frame(width: size * 0.8, height: size)
            .phaseAnimator([1.0, 0.35], trigger: isSyncing) { mark, phase in
                mark.opacity(isSyncing ? phase : 1)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
            .accessibilityHidden(true)
    }
}

/// Yeni mail: kimden geldiği ve konusu, yanında beyaz bir Aç
private struct PeekContent: View {
    let peek: MailIsland.Peek
    let notch: CGFloat
    var showsSubject = true
    let open: (PostaLink) -> Void

    var body: some View {
        HStack(spacing: 12) {
            IslandAvatar(name: peek.sender, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peek.sender)
                        .font(.system(size: 14, weight: .semibold))
                    if peek.others > 0 {
                        Text("+\(peek.others)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Text(showsSubject ? peek.subject : String(localized: "New message"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                open(.thread(peek.threadID))
            } label: {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 15)
                    .frame(height: 28)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .padding(.horizontal, 16)
        .padding(.top, notch + 10)
        .foregroundStyle(.white)
    }
}

/// Doğrulama kodu: kimden geldiği, iri ve aralıklı rakamlar, yanında beyaz bir Kopyala
private struct CodeContent: View {
    let code: MailIsland.Code
    let notch: CGFloat
    let copied: () -> Void
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(code.sender)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Text(verbatim: code.code)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .tracking(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.code, forType: .string)
                withAnimation(.snappy(duration: 0.2)) { isCopied = true }
                copied()
            } label: {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 15)
                    .frame(height: 30)
                    .background(.white, in: Capsule())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .handCursor()
        }
        .padding(.horizontal, 20)
        .padding(.top, notch + 8)
        .foregroundStyle(.white)
    }
}

/// Fareyle üzerine gelince: son konuşmalar, Akış ve kısayollar
private struct OpenContent: View {
    let summary: WidgetSnapshot
    let count: Int
    let notch: CGFloat
    let options: IslandOptions
    let open: (PostaLink) -> Void

    var body: some View {
        let rows = summary.people
            .sorted { ($0.isUnread ? 1 : 0, $0.date) > ($1.isUnread ? 1 : 0, $1.date) }
            .prefix(options.rows)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                IslandMark(size: 15)
                Text(count > 0 ? "\(count) new conversations" : "All read")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                Spacer(minLength: 8)
                if options.showsActions {
                    IslandIconButton(symbol: "square.and.pencil", help: String(localized: "New message")) { open(.compose(account: nil)) }
                    IslandIconButton(symbol: "arrow.up.forward", help: String(localized: "Open Nook")) { open(.inbox(account: nil)) }
                }
            }
            .frame(minHeight: 28)

            VStack(spacing: 0) {
                ForEach(Array(rows)) { conversation in
                    IslandRow(conversation: conversation) { open(.thread(conversation.id)) }
                }
                if rows.isEmpty {
                    Text("No mail from people yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(.horizontal, -8)

            if summary.splitInbox && options.showsFeed {
                FeedLine(summary: summary) { open(.inbox(account: nil)) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, notch + 10)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

/// Akış tek satırda: kaç yeni var ve en çok kim yazdı
private struct FeedLine: View {
    let summary: WidgetSnapshot
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let feed = summary.accounts.reduce(0) { $0 + $1.feed }
        let top = summary.feed.filter { $0.unread > 0 }.max { $0.unread < $1.unread }
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Feed")
                    .font(.system(size: 12, weight: .semibold))
                Text(feed > 0 ? "\(feed) new" : "nothing new")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                if let top {
                    Text("· mostly \(top.name)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovering ? 0.8 : 0.35))
            }
            .padding(.top, 11)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

private struct IslandRow: View {
    let conversation: WidgetSnapshot.Conversation
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IslandAvatar(name: conversation.sender, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.sender)
                        .font(.system(size: 13, weight: conversation.isUnread ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(conversation.isUnread ? 1 : 0.7))
                    Text(conversation.subject)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 7) {
                    Text(Fmt.listDate(conversation.date))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(conversation.isUnread ? 0.8 : 0.35))
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .opacity(conversation.isUnread ? 1 : 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

/// Renksiz baş harfler; widget'lardaki gibi ince bir halka
private struct IslandAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(.white.opacity(0.1))
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .overlay {
                Text(Monogram.initials(for: name))
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

private struct IslandIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isHovering ? 0.16 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

/// Çentik biçimi: üst köşeleri ekranın kenarına içe kıvrılarak bağlanır, alt köşeleri yuvarlak
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, (rect.width - 2 * ear) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
