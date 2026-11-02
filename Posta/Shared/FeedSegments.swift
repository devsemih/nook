import SwiftUI
import WidgetKit

/// Akış'taki yenilerin bir göndericiye düşen payı; widget'lar ve menü çubuğu aynı dağılımı gösterir
struct FeedSegment: Identifiable {
    let name: String
    let count: Int
    let color: Color

    var id: String { name }
}

extension WidgetSnapshot {
    /// En çok yazan dört gönderici ve geri kalanı; hesap verilirse yalnızca o hesap
    func feedSegments(account: UUID?) -> [FeedSegment] {
        let total = accounts
            .filter { account == nil || $0.id == account }
            .reduce(0) { $0 + $1.feed }
        let top = feed
            .filter { sender in sender.unread > 0 && (account.map { sender.accountIDs.contains($0) } ?? true) }
            .sorted { $0.unread > $1.unread }
            .prefix(4)
        var segments = top.map { FeedSegment(name: $0.name, count: $0.unread, color: Monogram.color(for: $0.name)) }
        let rest = total - top.reduce(0) { $0 + $1.unread }
        if rest > 0 { segments.append(FeedSegment(name: String(localized: "Others"), count: rest, color: .gray)) }
        return segments
    }
}

/// Akış'ın göndericilere dağılımı: her gönderici kendi renginde bir dilim
struct SegmentBar: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let segments: [FeedSegment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let total = segments.reduce(0) { $0 + $1.count }
            if total == 0 {
                Capsule().fill(.quaternary)
            } else {
                // Her dilime önce bir yükseklik kadar yer, kalanı sayıya göre; küçük dilimler de görünür
                let gaps = CGFloat(segments.count - 1) * 2
                let free = max(0, proxy.size.width - gaps - CGFloat(segments.count) * height)
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        Capsule()
                            .fill(fill(segment, index: index))
                            .frame(width: height + free * CGFloat(segment.count) / CGFloat(total))
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func fill(_ segment: FeedSegment, index: Int) -> AnyShapeStyle {
        renderingMode == .fullColor ? AnyShapeStyle(segment.color) : AnyShapeStyle(.primary.opacity(max(0.25, 1 - Double(index) * 0.2)))
    }
}
