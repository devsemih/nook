import Foundation
import GRDB

/// Yerel SQLite veritabanı. Arayüz için tek doğru kaynak budur; uygulama açılınca buradan anında yüklenir.
/// DatabaseQueue iş parçacığı güvenlidir; bakım işleri arka planda çalışabilir
nonisolated final class LocalDatabase: Sendable {
    private let queue: DatabaseQueue

    static func openDefault() throws -> LocalDatabase {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Posta", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try LocalDatabase(path: folder.appendingPathComponent("posta.sqlite").path)
    }

    nonisolated static var attachmentsFolder: URL {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Posta/Attachments", isDirectory: true) ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "posta"
        queue = try DatabaseQueue(path: path, configuration: configuration)
        try migrator.migrate(queue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("payload", .blob).notNull()
                t.column("syncState", .blob)
            }
            try db.create(table: "thread") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull().indexed()
                t.column("remoteID", .text).indexed()
                t.column("location", .text).notNull()
                t.column("lastDate", .datetime).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(table: "draft") { t in
                t.primaryKey("threadID", .text)
                t.column("payload", .blob).notNull()
            }
        }
        return migrator
    }

    // MARK: Yükleme

    struct Snapshot {
        var accounts: [Account]
        var threads: [MailThread]
        var drafts: [UUID: StoredDraft]
        var syncStates: [UUID: Data]
    }

    func load() throws -> Snapshot {
        try queue.read { db in
            let decoder = JSONDecoder()
            var accounts: [Account] = []
            var syncStates: [UUID: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, payload, syncState FROM account ORDER BY position") {
                guard var account = try? decoder.decode(Account.self, from: row["payload"] as Data) else { continue }
                account.status = .ok
                accounts.append(account)
                if let state = row["syncState"] as Data? { syncStates[account.id] = state }
            }
            let threads = try Row.fetchAll(db, sql: "SELECT payload FROM thread").compactMap { row in
                try? decoder.decode(MailThread.self, from: row["payload"] as Data)
            }
            var drafts: [UUID: StoredDraft] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT threadID, payload FROM draft") {
                if let id = UUID(uuidString: row["threadID"]), let draft = try? decoder.decode(StoredDraft.self, from: row["payload"] as Data) {
                    drafts[id] = draft
                }
            }
            return Snapshot(accounts: accounts, threads: threads, drafts: drafts, syncStates: syncStates)
        }
    }

    // MARK: Yazma

    func saveAccounts(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        try queue.write { db in
            let ids = accounts.map(\.id.uuidString)
            if ids.isEmpty {
                try db.execute(sql: "DELETE FROM account")
            } else {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM account WHERE id NOT IN (\(placeholders))", arguments: StatementArguments(ids))
            }
            for (index, account) in accounts.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO account (id, position, payload) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET position = excluded.position, payload = excluded.payload
                    """,
                    arguments: [account.id.uuidString, index, try encoder.encode(account)]
                )
            }
        }
    }

    func saveSyncState(_ data: Data?, for accountID: UUID) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE account SET syncState = ? WHERE id = ?", arguments: [data, accountID.uuidString])
        }
    }

    func apply(upserts: [MailThread], deletions: [UUID]) throws {
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        let encoder = JSONEncoder()
        try queue.write { db in
            for id in deletions {
                try db.execute(sql: "DELETE FROM thread WHERE id = ?", arguments: [id.uuidString])
            }
            for thread in upserts {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO thread (id, accountID, remoteID, location, lastDate, payload) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [thread.id.uuidString, thread.accountID.uuidString, thread.remoteID, thread.location.rawValue, thread.lastDate, try encoder.encode(thread)]
                )
            }
        }
    }

    func saveDrafts(_ drafts: [UUID: StoredDraft]) throws {
        let encoder = JSONEncoder()
        try queue.write { db in
            try db.execute(sql: "DELETE FROM draft")
            for (id, draft) in drafts {
                try db.execute(sql: "INSERT INTO draft (threadID, payload) VALUES (?, ?)", arguments: [id.uuidString, try encoder.encode(draft)])
            }
        }
    }

    func deleteAccountData(_ accountID: UUID) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM thread WHERE accountID = ?", arguments: [accountID.uuidString])
        }
    }

    /// Silinen kayıtların boşalttığı alanı geri verir; haftada bir yeter
    func compactIfNeeded() {
        let key = "lastDatabaseVacuum"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 7 * 24 * 3600 else { return }
        try? queue.vacuum()
        UserDefaults.standard.set(Date.now, forKey: key)
    }

    func eraseAll() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM thread")
            try db.execute(sql: "DELETE FROM draft")
            try db.execute(sql: "UPDATE account SET syncState = NULL")
        }
    }
}

/// Taslak gövdesi biçimiyle (RTF) saklanır
nonisolated struct StoredDraft: Codable, Sendable {
    var mode: String
    var replyToThreadID: UUID?
    var rtf: Data
}
