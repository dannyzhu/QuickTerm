import CryptoKit
import Foundation
import Security

/// Where the content key for encrypted restore files lives. A protocol so tests can use an
/// in-memory key and never touch the real keychain.
protocol RestoreKeyStore {
    /// The 256-bit key, or nil when none exists and `createIfMissing` is false. Reading must not
    /// create a key: a launch that finds encrypted files but no key should drop them, not mint a
    /// key that can never open them.
    func key(createIfMissing: Bool) throws -> SymmetricKey?
}

/// The key as a generic keychain password: 32 random bytes, created on first encrypted write.
struct KeychainRestoreKeyStore: RestoreKeyStore {
    static let service = "dev.danny.quickterm.restore"
    static let account = "content-key"

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "keychain error \(status)" }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func key(createIfMissing: Bool) throws -> SymmetricKey? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        guard createIfMissing else { return nil }

        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        if status == errSecSuccess {
            // A stored value of the wrong size is unusable; replace it.
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError(status: update) }
            return fresh
        }
        var add = query
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return fresh
    }
}
