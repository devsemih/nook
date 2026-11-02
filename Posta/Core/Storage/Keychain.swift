import Foundation
import Security

/// Şifre ve token'lar yalnızca Keychain'de durur; diske düz metin yazılmaz, loglanmaz.
nonisolated enum Keychain {
    private static let service = "com.odinstudio.posta"

    enum Item {
        case imapPassword(UUID)
        case googleTokens(UUID)

        var account: String {
            switch self {
            case .imapPassword(let id): "\(id.uuidString).imap"
            case .googleTokens(let id): "\(id.uuidString).google"
            }
        }
    }

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    static func set(_ data: Data, for item: Item) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            insert[kSecAttrLabel as String] = "Nook"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func data(for item: Item) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setString(_ value: String, for item: Item) throws {
        try set(Data(value.utf8), for: item)
    }

    static func string(for item: Item) -> String? {
        data(for: item).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setCodable<T: Encodable>(_ value: T, for item: Item) throws {
        try set(JSONEncoder().encode(value), for: item)
    }

    static func codable<T: Decodable>(_ type: T.Type, for item: Item) -> T? {
        data(for: item).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func deleteAll(for accountID: UUID) {
        delete(.imapPassword(accountID))
        delete(.googleTokens(accountID))
    }
}
