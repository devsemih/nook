import Foundation
import os

/// Disk kullanımını sınırlı tutar: artık hiçbir maile ait olmayan ek dosyalarını siler.
/// Mailler zaten senkron penceresiyle (son 90 gün, klasör başına sınır) sınırlıdır.
nonisolated enum StorageMaintenance {
    /// referencedFolders: hâlâ bir mesajın ya da taslağın kullandığı ek klasörleri
    static func cleanAttachments(keeping referencedFolders: Set<String>) {
        let fileManager = FileManager.default
        let root = LocalDatabase.attachmentsFolder
        // Bu sırada indirilmekte olan eklere dokunulmaz
        let cutoff = Date.now.addingTimeInterval(-15 * 60)

        func isRecent(_ url: URL) -> Bool {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return modified > cutoff
        }

        var removed = 0
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            if folder.lastPathComponent == "outgoing" {
                let drafts = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for draft in drafts where !referencedFolders.contains(draft.standardizedFileURL.path) && !isRecent(draft) {
                    try? fileManager.removeItem(at: draft)
                    removed += 1
                }
            } else if !referencedFolders.contains(folder.standardizedFileURL.path) && !isRecent(folder) {
                try? fileManager.removeItem(at: folder)
                removed += 1
            }
        }
        if removed > 0 {
            Log.sync.info("Temizlik: \(removed, privacy: .public) kullanılmayan ek klasörü silindi")
        }
    }
}
