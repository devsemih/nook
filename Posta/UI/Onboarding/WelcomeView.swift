import SwiftUI

/// İlk açılış: Nook'u tanıtan üç sayfa. Karşılama, nasıl çalıştığı, ilk hesabı bağlama.
/// Logo ve widget'larla aynı dil: siyah, beyaz ve griler; vurguyu ağırlık ve büyüklük taşır.
struct WelcomeView: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes

    @State private var page = 0
    @State private var forward = true

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: WelcomePage()
                case 1: TourPage()
                default: ConnectPage()
                }
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themes.paper)
        .animation(.smooth(duration: 0.35), value: page)
    }

    private var footer: some View {
        HStack {
            Button("Back") { go(page - 1) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(page > 0 ? 1 : 0)
                .disabled(page == 0)
                .handCursor()
                .frame(width: 120, alignment: .leading)

            Spacer()
            PageDots(count: pageCount, current: page)
            Spacer()

            Group {
                if page < pageCount - 1 {
                    Button(page == 0 ? "Get started" : "Continue") { go(page + 1) }
                } else {
                    Button("Add account") { store.showAddAccount = true }
                }
            }
            .prominentButton()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .handCursor()
            .frame(width: 120, alignment: .trailing)
        }
    }

    private func go(_ target: Int) {
        guard (0..<pageCount).contains(target) else { return }
        forward = target > page
        page = target
    }
}

// MARK: - Sayfalar

private struct WelcomePage: View {
    @State private var drawn = false

    var body: some View {
        VStack(spacing: 26) {
            // Kemer kendini çizerek gelir
            ArchLine()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.primary, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .padding(7.5)
                .frame(width: 58, height: 72)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).delay(0.15)) { drawn = true }
                }

            VStack(spacing: 10) {
                Text("Welcome to Nook")
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.9)
                Text("A calm, people-first mail client.")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }

            Text("Mail from people comes first. Everything else waits quietly.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct TourPage: View {
    var body: some View {
        VStack(spacing: 34) {
            VStack(spacing: 8) {
                Text("How Nook works")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.7)
                Text("Your inbox, sorted by who wrote to you.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    FeatureCard(title: "People", text: "Every person who writes to you gets their own channel, right at the top.") {
                        PeopleIllustration()
                    }
                    FeatureCard(title: "Feed", text: "Newsletters, receipts and notifications are grouped by sender and wait in Feed.") {
                        FeedIllustration()
                    }
                }
                GridRow {
                    FeatureCard(title: "Notch", text: "New mail from people appears in your notch. Feed never interrupts you.") {
                        NotchIllustration()
                    }
                    FeatureCard(title: "Private", text: "No servers in between. Mail goes straight from your provider to this Mac.") {
                        PrivateIllustration()
                    }
                }
            }
            .frame(maxWidth: 680)
            // Kartlar içerikleri kadar uzar, sayfayı doldurmaz
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(40)
    }
}

private struct ConnectPage: View {
    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 14) {
                ProviderBadge(symbol: "icloud.fill", title: "iCloud")
                ProviderBadge(symbol: "envelope.fill", title: "Gmail")
            }

            VStack(spacing: 10) {
                Text("Connect your first account")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.7)
                Text("Nook works with iCloud and Gmail. You'll create an app-specific password for Nook, and we'll walk you through it step by step.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            }

            Label("Your mail and passwords stay on this Mac.", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

// MARK: - Parçalar

private struct FeatureCard<Illustration: View>: View {
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder let illustration: Illustration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 14)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// Kişiler: baş harfli üç satır, ilki okunmamış
private struct PeopleIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(["MC", "LP", "SA"].enumerated()), id: \.offset) { index, initials in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .overlay(Text(initials).font(.system(size: 8, weight: .semibold)))
                        .frame(width: 20, height: 20)
                    Capsule()
                        .fill(Color.primary.opacity(index == 0 ? 0.55 : 0.18))
                        .frame(width: index == 0 ? 74 : 58, height: 5)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(.primary)
                        .frame(width: 5, height: 5)
                        .opacity(index == 0 ? 1 : 0)
                }
            }
        }
        .frame(width: 140)
    }
}

/// Akış: gönderici başına üst üste binmiş kartlar
private struct FeedIllustration: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(["N", "B", "S"].enumerated()), id: \.offset) { index, letter in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 22, height: 28)
                        .offset(y: 8)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.11))
                        .frame(width: 26, height: 28)
                        .offset(y: 4)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                        .overlay(Text(letter).font(.system(size: 12, weight: .semibold)))
                        .frame(width: 30, height: 30)
                }
                .frame(height: 40, alignment: .top)
            }
        }
    }
}

/// Çentik: siyah ada, solda kemer, sağda sayı
private struct NotchIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ArchLine()
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .padding(1.3)
                    .frame(width: 10, height: 12)
                Spacer()
                Text(verbatim: "3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .frame(width: 150, height: 26)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
            Spacer()
        }
        .padding(.top, 18)
    }
}

/// Gizlilik: Mac ile sağlayıcı arasında doğrudan bir çizgi
private struct PrivateIllustration: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "macbook")
                .font(.system(size: 26, weight: .light))
            HStack(spacing: 4) {
                ForEach(0..<5) { _ in
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 3)
                }
            }
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: Circle())
            HStack(spacing: 4) {
                ForEach(0..<5) { _ in
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 3, height: 3)
                }
            }
            Image(systemName: "envelope")
                .font(.system(size: 22, weight: .light))
        }
        .foregroundStyle(.primary)
    }
}

private struct ProviderBadge: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(index == current ? 0.85 : 0.18))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
    }
}
