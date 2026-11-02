import SwiftUI

// MARK: - Avatar

struct AvatarView: View {
    @Environment(\.isMonochrome) private var isMonochrome
    let name: String
    var size: CGFloat = 34

    /// Aynı isim her yerde aynı renkte görünür (widget'larda da)
    static func color(for name: String) -> Color {
        Monogram.color(for: name)
    }

    var body: some View {
        Circle()
            .fill(isMonochrome ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Self.color(for: name).gradient))
            .overlay {
                if isMonochrome {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .overlay {
                Text(Contact.initials(for: name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: isMonochrome ? .default : .rounded))
                    .foregroundStyle(isMonochrome ? Color.primary : .white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Gönderici yığını

/// Akış'taki göndericinin kare simgesi; birden fazla maili varsa arkasında kartlar görünür
struct SenderTile: View {
    @Environment(\.isMonochrome) private var isMonochrome
    let name: String
    var count = 1
    var size: CGFloat = 30

    private var initial: String {
        let letter = name.first { $0.isLetter || $0.isNumber }.map(String.init) ?? "?"
        return letter.uppercased(with: Locale.current)
    }

    var body: some View {
        let color = isMonochrome ? Color.primary.opacity(0.4) : AvatarView.color(for: name)
        let radius = size * 0.28
        ZStack(alignment: .top) {
            if count > 2 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.22))
                    .frame(width: size * 0.64, height: size)
                    .offset(y: size * 0.26)
            }
            if count > 1 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.45))
                    .frame(width: size * 0.82, height: size)
                    .offset(y: size * 0.13)
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isMonochrome ? AnyShapeStyle(MonochromeFill()) : AnyShapeStyle(color.gradient))
                .overlay {
                    if isMonochrome {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                }
                .overlay {
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .semibold, design: isMonochrome ? .default : .rounded))
                        .foregroundStyle(isMonochrome ? Color.primary : .white)
                }
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size * 1.26, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// Siyah-beyaz temada simgelerin zemini: arkasındaki kartlar yarı saydam olduğu için önündeki opak olmalı
private struct MonochromeFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.93)
    }
}

// MARK: - Renk noktası

struct ColorDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

extension NSImage {
    /// Menülerde renkli nokta göstermek için şablon olmayan görsel
    static func dot(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Akış düzeni (çipler için)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// Son öğe (metin alanı) satırın kalanını doldurur
    var minLastWidth: CGFloat = 120

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 600, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 600, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Item { var index: Int; var x: CGFloat; var size: CGSize }
    private struct Row { var y: CGFloat; var height: CGFloat; var items: [Item] }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0
        for index in subviews.indices {
            let isLast = index == subviews.count - 1
            var size = subviews[index].sizeThatFits(.unspecified)
            if isLast { size.width = minLastWidth }
            if x > 0, x + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing, height: 0, items: [])
                x = 0
            }
            if isLast { size.width = max(minLastWidth, width - x) }
            size.width = min(size.width, width)
            current.items.append(Item(index: index, x: x, size: size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        rows.append(current)
        return rows
    }
}

// MARK: - Tuş görünümü

struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - El imleci

extension View {
    /// Tıklanabilir öğelerde el imleci; devre dışıyken normal ok
    func handCursor() -> some View {
        modifier(HandCursor())
    }
}

private struct HandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : nil)
    }
}

extension View {
    /// Asıl eylem düğmesi. Siyah-beyaz temada vurgu koyuda beyaz olduğundan sistem düğmesi beyaz üstüne beyaz
    /// yazardı; orada yazı rengini temadan alan kendi düğmemiz çizilir.
    func prominentButton() -> some View {
        modifier(ProminentButton())
    }
}

private struct ProminentButton: ViewModifier {
    @Environment(\.isMonochrome) private var isMonochrome

    func body(content: Content) -> some View {
        if isMonochrome {
            content.buttonStyle(MonochromeProminentStyle())
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct MonochromeProminentStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.onAccent) private var onAccent
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: controlSize == .large ? 14 : 13, weight: .semibold))
            .foregroundStyle(onAccent)
            .padding(.horizontal, controlSize == .large ? 16 : 12)
            .frame(minHeight: controlSize == .large ? 32 : 26)
            .background(.tint, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Pencere erişimi

/// Görünümün pencere içindeki yerini AppKit'ten, istendiği anda okur. NavigationSplitView sütunları ayrı
/// AppKit görünümlerinde barındırıldığı için SwiftUI'ın koordinat alanları sütunlar arasında güvenilir değil.
@MainActor
final class FrameProbe {
    fileprivate weak var view: NSView?

    /// Pencere içeriğine göre, sol üst köşe başlangıç
    var frameInWindow: CGRect? {
        guard let view, let root = view.window?.contentView else { return nil }
        let rect = root.convert(view.bounds, from: view)
        guard !root.isFlipped else { return rect }
        return CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct FrameProbeView: NSViewRepresentable {
    let probe: FrameProbe

    func makeNSView(context: Context) -> NSView {
        let view = TransparentView()
        probe.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        probe.view = nsView
    }

    /// Tıklamaları ve imleci altındaki SwiftUI görünümüne bırakır
    private final class TransparentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSApplication {
    /// Tıklanan satır gibi yerlerde yazma alanından odağı al, tek tuşlu kısayollar çalışsın
    @MainActor static func resignTextFocus() {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder as? NSTextView, responder.isFieldEditor else { return }
        window.makeFirstResponder(nil)
    }
}
