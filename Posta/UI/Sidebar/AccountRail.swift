import SwiftUI

/// Discord'daki sunucu şeridi gibi: solda ince bir şerit, her hesap bir simge.
/// İnsanlardan gelen okunmamış mailler kırmızı rozetle sayılır; yalnızca Akış'ta yeni bir şey varsa
/// simgenin solunda küçük bir çizgi belirir. Klasörler liste başlığındaki menüde.
struct AccountRail: View {
    @Environment(MailStore.self) private var store
    @Environment(\.isMonochrome) private var isMonochrome
    @Environment(\.onAccent) private var onAccent
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if store.accounts.count > 1 {
                        allItem
                        Capsule()
                            .fill(.separator)
                            .frame(width: 28, height: 2)
                            .padding(.vertical, 2)
                    }
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        accountItem(account, index: index)
                    }
                    addItem
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)

            VStack(spacing: 4) {
                SyncIndicator()
                RailIconButton(id: "settings", title: String(localized: "Settings"), shortcut: "⌘,", action: { openSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Öğeler

    private var allItem: some View {
        let unread = store.unreadSplit(in: .all)
        return RailItem(
            id: "all",
            title: String(localized: "All accounts"),
            shortcut: "⌘0",
            detail: [String(localized: "Unified inbox"), summary(unread)].compactMap { $0 },
            isSelected: store.scope == .all,
            badge: badge(for: unread),
            hasUnread: unread.total > 0,
            action: { select(.all) }
        ) { active in
            ZStack {
                Rectangle().fill(active ? AnyShapeStyle(.tint.opacity(isMonochrome ? 0.14 : 0.28)) : AnyShapeStyle(Color.primary.opacity(0.08)))
                if isMonochrome {
                    // Siyah-beyaz temada tüm hesaplar Nook'un kemeriyle gösterilir
                    ArchLine()
                        .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .padding(2)
                        .frame(width: 16, height: 19)
                } else {
                    ScopeBadge(scope: .all, size: 30)
                }
            }
        }
    }

    private func accountItem(_ account: Account, index: Int) -> some View {
        let unread = store.unreadSplit(in: .account(account.id))
        let progress = store.syncProgress[account.id].flatMap { $0.isComplete ? nil : $0.fraction }
        return RailItem(
            id: account.id.uuidString,
            title: account.displayName,
            shortcut: index < 9 ? "⌘\(index + 1)" : nil,
            detail: [account.address, status(of: account, unread: unread, progress: progress)].compactMap { $0 },
            isSelected: store.scope == .account(account.id),
            badge: badge(for: account, unread: unread),
            hasUnread: unread.total > 0,
            progress: progress,
            action: {
                if account.status == .needsReauth { store.reauthAccount = account }
                select(.account(account.id))
            }
        ) { _ in
            ZStack {
                Rectangle().fill(isMonochrome ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(account.color.color.gradient))
                Text(Contact.initials(for: account.displayName))
                    .font(.system(size: 16, weight: .semibold, design: isMonochrome ? .default : .rounded))
                    .foregroundStyle(isMonochrome ? Color.primary : .white)
            }
        }
        .contextMenu { AccountMenu(account: account) }
    }

    private var addItem: some View {
        RailItem(id: "add", title: String(localized: "Add account"), isSelected: false, showsPill: false, action: { store.showAddAccount = true }) { active in
            ZStack {
                Rectangle().fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.08)))
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(onAccent) : AnyShapeStyle(.tint))
            }
        }
    }

    /// Seçili hesaba yeniden tıklamak gelen kutusuna döndürür
    private func select(_ scope: AccountScope) {
        NSApplication.resignTextFocus()
        if store.scope == scope {
            store.go(scope: scope, folder: .inbox)
        } else {
            store.scope = scope
        }
    }

    // MARK: Rozet ve açıklama

    private func badge(for unread: MailStore.UnreadSplit) -> RailBadge? {
        let count = store.splitInbox ? unread.people : unread.total
        return count > 0 ? .count(count) : nil
    }

    private func badge(for account: Account, unread: MailStore.UnreadSplit) -> RailBadge? {
        switch account.status {
        case .needsReauth: .warning
        case .failed: .error
        case .ok, .syncing: badge(for: unread)
        }
    }

    private func status(of account: Account, unread: MailStore.UnreadSplit, progress: Double?) -> String? {
        switch account.status {
        case .needsReauth: return String(localized: "Sign-in required")
        case .failed(let message): return String(localized: "Couldn't sync: \(message)")
        case .ok, .syncing: break
        }
        if let progress { return String(localized: "Downloading \(Int(progress * 100))%") }
        return summary(unread)
    }

    private func summary(_ unread: MailStore.UnreadSplit) -> String? {
        guard store.splitInbox else { return unread.total > 0 ? String(localized: "\(unread.total) unread") : nil }
        var parts: [String] = []
        if unread.people > 0 { parts.append(String(localized: "\(unread.people) new conversations")) }
        if unread.feed > 0 { parts.append(String(localized: "\(unread.feed) new in Feed")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Şerit öğesi

enum RailBadge: Equatable {
    case count(Int)
    case warning
    case error

    var width: CGFloat {
        switch self {
        case .count(let value): value < 10 ? 16 : value < 100 ? 22 : 28
        case .warning, .error: 16
        }
    }
}

/// Discord'daki gibi: simge daireyken üstüne gelince ve seçilince yuvarlak köşeli kareye döner,
/// soldaki çizgi okunmamış (kısa), üzerinde (orta) ve seçili (uzun) durumlarını gösterir.
private struct RailItem<Icon: View>: View {
    @Environment(RailTooltip.self) private var tooltip
    let id: String
    let title: String
    var shortcut: String?
    var detail: [String] = []
    let isSelected: Bool
    var badge: RailBadge?
    var hasUnread = false
    var progress: Double?
    var showsPill = true
    let action: () -> Void
    @ViewBuilder var icon: (_ active: Bool) -> Icon

    @State private var isHovering = false
    @State private var probe = FrameProbe()

    private let size: CGFloat = 44

    private var accessibilityText: String {
        var parts = [title] + detail.prefix(1)
        if case .count(let value) = badge { parts.append(String(localized: "\(value) new")) }
        return parts.joined(separator: ", ")
    }

    private var pillHeight: CGFloat {
        if isSelected { return 36 }
        if isHovering { return 20 }
        return hasUnread ? 8 : 0
    }

    var body: some View {
        let active = isSelected || isHovering
        let shape = RoundedRectangle(cornerRadius: active ? 14 : size / 2, style: .continuous)
        ZStack(alignment: .leading) {
            if showsPill {
                Capsule()
                    .fill(.primary)
                    .frame(width: 8, height: max(pillHeight, 8))
                    .opacity(pillHeight > 0 ? 1 : 0)
                    .offset(x: -4)
                    .accessibilityHidden(true)
            }

            Button(action: action) {
                icon(active)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    .mask { BadgeCutout(badge: badge) }
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            RailBadgeView(badge: badge)
                                .offset(x: 4, y: 4)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay {
                        if let progress {
                            Circle()
                                .trim(from: 0, to: max(progress, 0.03))
                                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(-4)
                        }
                    }
                    .contentShape(shape)
                    .background(FrameProbeView(probe: probe))
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering { showTooltip() } else { tooltip.hide(id: id) }
                    }
                    .onChange(of: detail) { if isHovering { showTooltip() } }
                    .onDisappear { tooltip.hide(id: id) }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .handCursor()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .frame(maxWidth: .infinity)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: pillHeight)
        .animation(.snappy(duration: 0.2), value: badge)
    }

    private func showTooltip() {
        tooltip.show(RailTooltip.Item(id: id, title: title, shortcut: shortcut, detail: detail), at: probe)
    }
}

/// Rozetin arkasında simgeden oyulan boşluk; rozet şeridin zeminine oturur
private struct BadgeCutout: View {
    let badge: RailBadge?

    var body: some View {
        Rectangle()
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Capsule()
                        .frame(width: badge.width + 6, height: 22)
                        .offset(x: 7, y: 7)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}

private struct RailBadgeView: View {
    @Environment(\.isMonochrome) private var isMonochrome
    @Environment(\.onAccent) private var onAccent
    let badge: RailBadge

    var body: some View {
        Group {
            switch badge {
            case .count(let value):
                Text(value > 99 ? "99+" : "\(value)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            case .warning, .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .heavy))
            }
        }
        .foregroundStyle(countStyle ? onAccent : .white)
        .frame(width: badge.width, height: 16)
        .background(countStyle ? AnyShapeStyle(.tint) : AnyShapeStyle(badge == .warning ? Color.orange : Color.red), in: Capsule())
    }

    /// Siyah-beyaz temada okunmamış sayısı da renksiz; uyarılar kırmızı ve turuncu kalır
    private var countStyle: Bool {
        if case .count = badge { return isMonochrome }
        return false
    }
}

/// Şeridin altındaki küçük düğmeler (eşitleme durumu, ayarlar). Eylemi olmayan yalnızca bilgi gösterir:
/// tıklanmaz, üzerine gelince zemini belirmez ve el imleci çıkmaz.
private struct RailIconButton<Label: View>: View {
    @Environment(RailTooltip.self) private var tooltip
    let id: String
    let title: String
    var shortcut: String?
    var detail: [String] = []
    var action: (() -> Void)?
    @ViewBuilder var label: () -> Label

    @State private var isHovering = false
    @State private var probe = FrameProbe()

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .handCursor()
                .accessibilityLabel(title)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(([title] + detail.prefix(1)).joined(separator: ", "))
        }
    }

    private var content: some View {
        label()
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(action != nil && isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .background(FrameProbeView(probe: probe))
            .onHover { hovering in
                isHovering = hovering
                if hovering { showTooltip() } else { tooltip.hide(id: id) }
            }
            // İndirme yüzdesi gibi değişen bilgi, fare üzerindeyken de güncel kalır
            .onChange(of: [title] + detail) { if isHovering { showTooltip() } }
            .onDisappear { tooltip.hide(id: id) }
    }

    private func showTooltip() {
        tooltip.show(RailTooltip.Item(id: id, title: title, shortcut: shortcut, detail: detail), at: probe)
    }
}

/// Eşitleme: indirirken yüzde halkası, sorun varsa uyarı, boştayken "şimdi eşitle"
private struct SyncIndicator: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let account = store.accountsNeedingReauth.first {
            RailIconButton(id: "sync", title: String(localized: "Sign-in required"), detail: [account.address], action: { store.reauthAccount = account }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else if let account = store.accountsWithErrors.first, case .failed(let message) = account.status {
            RailIconButton(id: "sync", title: String(localized: "Couldn't sync"), detail: [account.address, message], action: { store.refresh() }) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else if store.syncPhase == .offline {
            RailIconButton(id: "sync", title: String(localized: "Offline"), detail: [String(localized: "Changes will sync when you're back online")]) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.orange)
            }
        } else if let progress = store.overallSyncProgress {
            let accounts = store.downloadingAccountCount
            RailIconButton(
                id: "sync",
                title: String(localized: "Downloading \(Int(progress * 100))%"),
                detail: [accounts > 1 ? String(localized: "Fetching new mail for \(accounts) accounts") : String(localized: "Fetching new mail")]
            ) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.03))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .animation(.smooth, value: progress)
            }
        } else if store.syncPhase == .syncing {
            RailIconButton(id: "sync", title: String(localized: "Syncing…")) {
                ProgressView().controlSize(.small)
            }
        } else {
            RailIconButton(id: "sync", title: Fmt.syncStatus(store.lastSync, now: now), shortcut: "⌥⌘R", detail: [String(localized: "Click to sync now")], action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Ad etiketi

/// Şeritteki simgenin üstüne gelince sağında beklemeden beliren ad etiketi.
/// Pencerenin en üst katmanında çizilir; böylece şeridin dışına, listenin üstüne taşabilir.
@Observable
final class RailTooltip {
    struct Item: Equatable {
        var id: String
        var title: String
        var shortcut: String?
        var detail: [String]
        /// Simgenin pencere içindeki yeri; üzerine gelindiği anda ölçülür
        var frame: CGRect = .zero
    }

    private(set) var item: Item?

    func show(_ item: Item, at probe: FrameProbe) {
        guard let frame = probe.frameInWindow else { return }
        var item = item
        item.frame = frame
        self.item = item
    }

    func hide(id: String) {
        if item?.id == id { item = nil }
    }
}

struct RailTooltipLayer: View {
    let tooltip: RailTooltip
    @State private var probe = FrameProbe()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = tooltip.item {
                // Simgenin pencere içindeki yeri bu katmanın kendi koordinatlarına çevrilir
                let origin = probe.frameInWindow?.origin ?? .zero
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                        if let shortcut = item.shortcut {
                            Text(shortcut)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(item.detail, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 11))
                .fixedSize()
                // Sıfır boyutlu çerçeve: etiketin sol kenarı ve dikey ortası tam bu noktaya oturur
                .frame(width: 0, height: 0, alignment: .leading)
                .offset(x: item.frame.maxX - origin.x + 14, y: item.frame.midY - origin.y)
                .id(item.id)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .leading)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FrameProbeView(probe: probe))
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: tooltip.item?.id)
    }
}
