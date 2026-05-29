import Foundation
import Security

/// Stores server passwords as generic-password Keychain items, keyed by server UUID.
/// Fail-loud: unexpected OSStatus values throw (per project rule, no silent catches).
enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

struct KeychainService {
    /// Fixed, bundle-scoped service string for all server-password items.
    private static let service = "io.github.AllMelody.chat.serverPassword"

    /// Upsert: update existing item, or add if absent.
    func save(password: String, for id: UUID) throws {
        let account = id.uuidString
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Returns the stored password, or nil if none exists.
    func password(for id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Deletes the stored password; a missing item is treated as success.
    func delete(for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
