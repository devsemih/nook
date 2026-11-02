import SwiftUI
import AppKit

/// Okuma alanının altındaki hızlı yanıt. Return yeni satır açar, ⌘↩ gönderir; gönderim 5 saniye geri alınabilir.
/// Ek, biçim ya da alıcı değişikliği gerekirse metin tam yazma alanına taşınır.
struct QuickReplyBar: View {
    @Environment(MailStore.self) private var store
    let thread: MailThread

    @State private var height: CGFloat = 20

    private var target: Contact? { store.quickReplyTarget(for: thread) }
    private var current: String { store.quickReplies[thread.id] ?? "" }
    private var hasText: Bool { !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var text: Binding<String> {
        Binding(
            get: { store.quickReplies[thread.id] ?? "" },
            set: { store.quickReplies[thread.id] = $0.isEmpty ? nil : $0 }
        )
    }

    private var placeholder: String {
        guard let target else { return String(localized: "Write a reply…") }
        return String(localized: "Reply to \(Fmt.dative(target.firstName))…")
    }

    private var hasManyRecipients: Bool {
        guard let last = thread.messages.last(where: { !$0.isDraft }) else { return false }
        return last.to.count + last.cc.count > 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let target {
                AvatarView(name: target.displayName, size: 24)
                    .padding(.bottom, 1)
            }

            GrowingTextView(text: text, height: $height, focusRequest: store.quickReplyFocusRequest)
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if current.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, GrowingTextView.inset)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.bottom, 2)

            buttons
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        // Çubuğun boş kenarlarına tıklamak da yazma alanına odaklar
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { store.quickReplyFocusRequest += 1 }
        .pointerStyle(.horizontalText)
        .animation(.snappy(duration: 0.18), value: hasText)
        .onAppear {
            guard store.pendingQuickReplyFocus == thread.id else { return }
            store.pendingQuickReplyFocus = nil
            store.quickReplyFocusRequest += 1
        }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            if hasText {
                BarButton(symbol: "arrow.up.left.and.arrow.down.right", help: String(localized: "Open in full composer")) {
                    store.expandQuickReply(threadID: thread.id)
                }
                Button {
                    store.sendQuickReply(threadID: thread.id)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Send (⌘↩)")
                .handCursor()
                .transition(.scale.combined(with: .opacity))
            } else {
                if hasManyRecipients {
                    BarButton(symbol: "arrowshape.turn.up.left.2", help: String(localized: "Reply all")) {
                        store.expandQuickReply(threadID: thread.id, mode: .replyAll)
                    }
                }
                BarButton(symbol: "arrowshape.turn.up.right", help: String(localized: "Forward")) {
                    store.expandQuickReply(threadID: thread.id, mode: .forward)
                }
            }
        }
        .frame(minHeight: 24)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .handCursor()
        .onHover { isHovering = $0 }
    }
}

/// İçeriğe göre uzayan düz metin alanı. SwiftUI TextField'da Return gönderir; burada yeni satır açar,
/// ⌘↩ menüdeki Gönder komutuna gider.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusRequest: Int
    var maxHeight: CGFloat = 180

    static let inset: CGFloat = 2

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = AutoSizingTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: Self.inset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.onWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.recalculateHeight()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // En fazla birkaç satır; kaydırma çubuğu göstermeden kayar
        scrollView.hasVerticalScroller = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recalculateHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        // Yalnızca dışarıdan gelen değişiklik yazılır (gönderince temizlenme gibi); yazarken araya girilirse
        // imleç sona atlar ve henüz onaylanmamış harfler (ı, ş…) kaybolur
        if text != coordinator.lastSyncedText, !textView.hasMarkedText() {
            coordinator.lastSyncedText = text
            if textView.string != text {
                textView.string = text
                DispatchQueue.main.async { coordinator.recalculateHeight() }
            }
        }
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: NSTextView?
        var lastFocusRequest: Int
        /// Metin alanının en son bildirdiği değer
        var lastSyncedText: String

        init(_ parent: GrowingTextView) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            lastSyncedText = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            lastSyncedText = textView.string
            parent.text = textView.string
            recalculateHeight()
        }

        func recalculateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = ceil(layout.usedRect(for: container).height + GrowingTextView.inset * 2)
            let height = min(max(content, 20), parent.maxHeight)
            if abs(height - parent.height) > 0.5 { parent.height = height }
        }
    }
}

final class AutoSizingTextView: NSTextView {
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onWidthChange?() }
    }
}
