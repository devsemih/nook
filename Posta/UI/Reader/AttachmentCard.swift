import SwiftUI
import UniformTypeIdentifiers

struct AttachmentCard: View {
    let attachment: Attachment
    var onRemove: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            AttachmentThumbnail(attachment: attachment)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.kind.title) · \(Fmt.fileSize(attachment.size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
                .handCursor()
            } else if isHovering {
                Button {
                    AttachmentFiles.save(attachment)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save…")
                .handCursor()
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(isHovering ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .onTapGesture { if onRemove == nil { AttachmentFiles.open(attachment) } }
        .pointerStyle(onRemove == nil ? .link : nil)
        .contextMenu {
            if onRemove == nil {
                Button("Open") { AttachmentFiles.open(attachment) }
                Button("Save…") { AttachmentFiles.save(attachment) }
            } else {
                Button("Remove", role: .destructive) { onRemove?() }
            }
        }
        .help(onRemove == nil ? String(localized: "Click to open") : attachment.filename)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 38

    var body: some View {
        let kind = attachment.kind
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(kind.tint.opacity(0.15))
            .overlay {
                if kind == .image {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.teal.opacity(0.7), .indigo.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.9)))
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: size * 0.38))
                        Text((attachment.filename as NSString).pathExtension.uppercased())
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(kind.tint)
                }
            }
            .frame(width: size, height: size)
    }
}

/// İndirilmiş ekleri açar ve kaydeder
enum AttachmentFiles {
    static func open(_ attachment: Attachment) {
        guard let url = attachment.localURL, FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func save(_ attachment: Attachment) {
        guard let source = attachment.localURL else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }

    static func saveAll(_ attachments: [Attachment]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for attachment in attachments {
            guard let source = attachment.localURL else { continue }
            let destination = folder.appendingPathComponent(attachment.filename)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }
}
