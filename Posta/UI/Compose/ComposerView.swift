import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    enum Style { case inline, sheet }

    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @Bindable var draft: Draft
    let style: Style

    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if style == .inline {
                inlineHeader
                    .padding(.bottom, 6)
            }

            if style == .sheet && store.accounts.count > 1 {
                fromRow
                Divider()
            }

            RecipientField(label: "To", contacts: $draft.to, autoFocus: draft.to.isEmpty) {
                if !draft.showCc {
                    Button("Cc") { withAnimation(.snappy(duration: 0.2)) { draft.showCc = true } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Show the Cc field")
                        .handCursor()
                }
            }
            Divider()

            if draft.showCc {
                RecipientField(label: "Cc", contacts: $draft.cc)
                Divider()
            }

            if style == .sheet || draft.mode == .forward {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Subject")
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    TextField("", text: $draft.subject)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                }
                .padding(.vertical, 8)
                Divider()
            }

            RichTextArea(
                text: $draft.body,
                minHeight: style == .inline ? 130 : 260,
                autoFocus: !draft.to.isEmpty
            )
            .padding(.top, 12)

            if !draft.attachments.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(draft.attachments) { attachment in
                        AttachmentCard(attachment: attachment) {
                            withAnimation(.snappy) { draft.attachments.removeAll { $0.id == attachment.id } }
                        }
                    }
                }
                .padding(.top, 10)
            }

            // Sheet'te alt çubuk kaydırılan içeriğin dışında sabit durur
            if style == .inline {
                Divider()
                    .padding(.top, 12)
                ComposerFooter(draft: draft)
                    .padding(.top, 10)
            }
        }
        .padding(style == .inline ? 16 : 0)
        .background {
            if style == .inline {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(themes.elevated)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
            }
        }
        .overlay {
            if style == .inline {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.headline).foregroundStyle(.tint))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            withAnimation(.snappy) { draft.addAttachments(from: urls) }
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
    }

    // MARK: Parçalar

    private var inlineHeader: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach([Draft.Mode.reply, .replyAll, .forward], id: \.self) { mode in
                    Button(mode.title, systemImage: mode.symbol) {
                        if let thread = store.thread(draft.threadID) { store.switchMode(of: draft, to: mode, thread: thread) }
                    }
                }
            } label: {
                Label(draft.mode.title, systemImage: draft.mode.symbol)
                    .font(.callout.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .handCursor()

            Spacer()

            Button {
                store.closeComposer(save: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close and save as draft (Esc)")
            .handCursor()
        }
    }

    private var fromRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("From")
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Picker("From", selection: $draft.accountID) {
                ForEach(store.accounts) { account in
                    Text("\(account.senderName) <\(account.address)>").tag(account.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .handCursor()
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Yazma alanının alt çubuğu: solda ek ve sil, sağda Gönder
struct ComposerFooter: View {
    @Environment(MailStore.self) private var store
    @Bindable var draft: Draft
    @State private var showsFileImporter = false

    var body: some View {
        HStack(spacing: 2) {
            FooterIconButton(symbol: "paperclip", help: String(localized: "Attach file")) { showsFileImporter = true }
            FooterIconButton(symbol: "trash", help: String(localized: "Delete draft")) { store.discardComposer() }
            Spacer()
            Button {
                store.send()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .prominentButton()
            .help("Send (⌘↩)")
            .handCursor()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                withAnimation(.snappy) { draft.addAttachments(from: urls) }
            }
        }
    }
}

private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .background(Color.primary.opacity(isHovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .handCursor()
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Draft {
    /// Seçilen dosyalar uygulama kabına kopyalanır; gönderimde izin sorunu yaşanmaz
    func addAttachments(from urls: [URL]) {
        attachments += urls.compactMap { url in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let folder = LocalDatabase.attachmentsFolder
                .appendingPathComponent("outgoing", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return Attachment(filename: url.lastPathComponent, size: Int64(size), mimeType: mimeType, localURL: destination)
        }
    }
}

/// Yeni mail ve Taslaklar'dan açılan taslaklar için native sheet
struct ComposeSheet: View {
    @Environment(MailStore.self) private var store
    @Environment(ThemeStore.self) private var themes
    @Bindable var draft: Draft

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.savedDraftThreadID == nil ? "New message" : "Draft")
                    .font(.headline)
                Spacer()
                Button {
                    store.dismissComposeSheet()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close and save as draft (Esc)")
                .handCursor()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 4)

            ScrollView {
                ComposerView(draft: draft, style: .sheet)
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }

            Divider()
            ComposerFooter(draft: draft)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 960, minHeight: 480, idealHeight: 620, maxHeight: 900)
        .scrollIndicators(.never)
        .background(themes.surface)
    }
}
