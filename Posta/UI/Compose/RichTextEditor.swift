import SwiftUI
import AppKit

/// Yazma alanındaki biçim komutlarını taşır ve seçimin konumunu yayınlar (kayan biçim çubuğu için).
@Observable
final class RichTextController {
    @ObservationIgnored weak var textView: NSTextView?

    var selectionRect: CGRect?
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var hasLink = false
    var isList = false
    var isEditingLink = false

    private var baseFont: NSFont { .systemFont(ofSize: 13) }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    // MARK: Biçim

    func toggleBold() { toggle(trait: .boldFontMask) }
    func toggleItalic() { toggle(trait: .italicFontMask) }

    private func toggle(trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let manager = NSFontManager.shared
        guard range.length > 0 else {
            let font = textView.typingAttributes[.font] as? NSFont ?? baseFont
            let has = manager.traits(of: font).contains(trait)
            textView.typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            refreshState()
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = value as? NSFont ?? baseFont
            if !manager.traits(of: font).contains(trait) { allHave = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? baseFont
            let converted = allHave ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
        refreshState()
    }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            let current = textView.typingAttributes[.underlineStyle] as? Int ?? 0
            textView.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            refreshState()
            return
        }
        var allHave = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { allHave = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allHave {
            storage.removeAttribute(.underlineStyle, range: range)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
        refreshState()
    }

    var selectedLink: String {
        guard let textView, let storage = textView.textStorage else { return "" }
        let range = textView.selectedRange()
        guard range.length > 0, range.location < storage.length else { return "" }
        let value = storage.attribute(.link, at: range.location, effectiveRange: nil)
        return (value as? URL)?.absoluteString ?? (value as? String) ?? ""
    }

    func setLink(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0, textView.shouldChangeText(in: range, replacementString: nil) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        storage.beginEditing()
        if trimmed.isEmpty {
            storage.removeAttribute(.link, range: range)
        } else {
            let normalized = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed
                : trimmed.contains("@") ? "mailto:\(trimmed)" : "https://\(trimmed)"
            if let url = URL(string: normalized) { storage.addAttribute(.link, value: url, range: range) }
        }
        storage.endEditing()
        textView.didChangeText()
        refreshState()
    }

    func toggleList() {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.string as NSString
        let paragraphRange = string.paragraphRange(for: textView.selectedRange())
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: paragraphRange, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            paragraphs.append(range)
        }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: paragraphRange.location, length: 0)] }
        let allBulleted = paragraphs.allSatisfy { string.substring(with: $0).hasPrefix(Self.bullet) }
        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
        storage.beginEditing()
        for range in paragraphs.reversed() {
            if allBulleted {
                storage.deleteCharacters(in: NSRange(location: range.location, length: Self.bullet.count))
            } else if !string.substring(with: range).hasPrefix(Self.bullet) {
                let attributes = range.location < storage.length ? storage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
                storage.insert(NSAttributedString(string: Self.bullet, attributes: attributes), at: range.location)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        refreshState()
    }

    static let bullet = "•  "

    // MARK: Durum

    func refreshState() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let manager = NSFontManager.shared
        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let font = attributes[.font] as? NSFont ?? baseFont
        isBold = manager.traits(of: font).contains(.boldFontMask)
        isItalic = manager.traits(of: font).contains(.italicFontMask)
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        hasLink = attributes[.link] != nil
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: 0))
        isList = string.substring(with: paragraph).hasPrefix(Self.bullet)
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    @Binding var contentHeight: CGFloat
    let controller: RichTextController
    var autoFocus = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorScrollView {
        let scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = MailTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        textView.textStorage?.setAttributedString(text)

        scrollView.documentView = textView
        scrollView.onWidthChange = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.updateHeight(textView)
        }
        controller.textView = textView

        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            context.coordinator.updateHeight(textView)
            guard autoFocus, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        }
        return scrollView
    }

    func updateNSView(_ scrollView: EditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !context.coordinator.isUpdating, !(textView.textStorage?.isEqual(to: text) ?? true) {
            let selection = textView.selectedRanges
            textView.textStorage?.setAttributedString(text)
            textView.selectedRanges = selection
            context.coordinator.updateHeight(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var isUpdating = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.attributedString()
            isUpdating = false
            updateHeight(textView)
            updateSelection(textView)
        }

        func updateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2)
            if abs(parent.contentHeight - height) > 0.5 {
                parent.contentHeight = height
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateSelection(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !parent.controller.isEditingLink else { return }
            parent.controller.selectionRect = nil
        }

        private func updateSelection(_ textView: NSTextView) {
            let controller = parent.controller
            controller.refreshState()
            let range = textView.selectedRange()
            guard range.length > 0,
                  textView.window?.firstResponder === textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                if !controller.isEditingLink { controller.selectionRect = nil }
                return
            }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            controller.selectionRect = rect
        }

        /// Madde işaretli satırda Return yeni madde açar, boş maddede listeyi bitirir
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let storage = textView.textStorage else { return false }
            let string = storage.string as NSString
            let range = textView.selectedRange()
            let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard line.hasPrefix(RichTextController.bullet) else { return false }
            if line == RichTextController.bullet.trimmingCharacters(in: .whitespaces) || line == RichTextController.bullet {
                let bulletRange = NSRange(location: paragraph.location, length: RichTextController.bullet.count)
                if textView.shouldChangeText(in: bulletRange, replacementString: "") {
                    storage.replaceCharacters(in: bulletRange, with: "")
                    textView.didChangeText()
                }
                return true
            }
            textView.insertText("\n" + RichTextController.bullet, replacementRange: range)
            return true
        }
    }
}

/// Yazma alanı kendi içinde kaymaz; yükseklik içeriğe göre büyür, kaydırma üst görünüme geçer
final class EditorScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}

final class MailTextView: NSTextView {
    /// Yapıştırılan metin biçimsiz gelsin, mail içinde yabancı font ve renk kalmasın
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Kayan biçim çubuğu

struct FormatBar: View {
    @Bindable var controller: RichTextController
    @State private var linkText = ""

    var body: some View {
        HStack(spacing: 2) {
            FormatButton(symbol: "bold", isOn: controller.isBold, help: String(localized: "Bold (⌘B)")) { controller.toggleBold() }
            FormatButton(symbol: "italic", isOn: controller.isItalic, help: String(localized: "Italic (⌘I)")) { controller.toggleItalic() }
            FormatButton(symbol: "underline", isOn: controller.isUnderlined, help: String(localized: "Underline (⌘U)")) { controller.toggleUnderline() }
            Divider().frame(height: 16).padding(.horizontal, 3)
            FormatButton(symbol: "link", isOn: controller.hasLink, help: String(localized: "Link")) {
                linkText = controller.selectedLink
                controller.isEditingLink = true
            }
            .popover(isPresented: $controller.isEditingLink, arrowEdge: .bottom) {
                LinkEditor(text: $linkText) { value in
                    controller.setLink(value)
                    controller.isEditingLink = false
                    if let textView = controller.textView { textView.window?.makeFirstResponder(textView) }
                }
            }
            FormatButton(symbol: "list.bullet", isOn: controller.isList, help: String(localized: "List")) { controller.toggleList() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct FormatButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(isOn ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .handCursor()
    }
}

private struct LinkEditor: View {
    @Binding var text: String
    let onCommit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("https://", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { onCommit(text) }
            Button("Add") { onCommit(text) }
                .keyboardShortcut(.defaultAction)
                .handCursor()
        }
        .padding(10)
        .onAppear { focused = true }
    }
}

/// Editör, yer tutucu ve kayan biçim çubuğu bir arada
struct RichTextArea: View {
    @Binding var text: NSAttributedString
    var placeholder = String(localized: "Write your message…")
    var minHeight: CGFloat = 120
    var autoFocus = false

    @State private var controller = RichTextController()
    @State private var contentHeight: CGFloat = 0

    /// İmza dışında metin yoksa yer tutucu görünür
    private var isBodyEmpty: Bool {
        let content = text.string.components(separatedBy: "-- \n").first ?? text.string
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        RichTextEditor(text: $text, contentHeight: $contentHeight, controller: controller, autoFocus: autoFocus)
            .frame(height: max(minHeight, contentHeight + 18))
            .overlay(alignment: .topLeading) {
                if isBodyEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    if let rect = controller.selectionRect {
                        let barWidth: CGFloat = 170
                        let x = min(max(0, rect.midX - barWidth / 2), max(0, proxy.size.width - barWidth))
                        let y = rect.minY > 40 ? rect.minY - 40 : rect.maxY + 8
                        FormatBar(controller: controller)
                            .fixedSize()
                            .offset(x: x, y: y)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .animation(.snappy(duration: 0.16), value: controller.selectionRect == nil)
            }
    }
}
