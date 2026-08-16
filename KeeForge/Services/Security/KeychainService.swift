import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum KeychainService {
    private static let service = "com.keevault.app"
    private static let compositeKeyAccount = "compositeKey"

    private static func accountKey(for databaseID: UUID) -> String {
        "\(compositeKeyAccount):\(databaseID.uuidString)"
    }

    private static func legacyAccountKey(forFilename filename: String) -> String {
        "\(compositeKeyAccount):\(filename)"
    }

    static func storeCompositeKey(_ key: SymmetricKey, for databaseID: UUID) throws {
        let account = accountKey(for: databaseID)
        try storeCompositeKey(key, account: account)
    }

    static func retrieveCompositeKey(for databaseID: UUID, context: LAContext) throws -> SymmetricKey {
        let account = accountKey(for: databaseID)
        return try retrieveCompositeKey(account: account, context: context)
    }

    static func deleteCompositeKey(for databaseID: UUID) {
        let account = accountKey(for: databaseID)
        deleteCompositeKey(account: account)
    }

    static func hasStoredKey(for databaseID: UUID, legacyFilename: String? = nil) -> Bool {
        if hasStoredKey(account: accountKey(for: databaseID)) {
            return true
        }

        guard let legacyFilename else { return false }
        return hasStoredKey(account: legacyAccountKey(forFilename: legacyFilename))
    }

    static func retrieveLegacyCompositeKey(forFilename filename: String, context: LAContext) throws -> SymmetricKey {
        try retrieveCompositeKey(account: legacyAccountKey(forFilename: filename), context: context)
    }

    static func deleteLegacyCompositeKey(forFilename filename: String) {
        deleteCompositeKey(account: legacyAccountKey(forFilename: filename))
    }

    static func hasLegacyStoredKey(forFilename filename: String) -> Bool {
        hasStoredKey(account: legacyAccountKey(forFilename: filename))
    }

    static func isItemNotFound(_ error: Error) -> Bool {
        guard let keychainError = error as? KeychainError,
              case .retrieveFailed(errSecItemNotFound) = keychainError else {
            return false
        }
        return true
    }

    private static func storeCompositeKey(_ key: SymmetricKey, account: String) throws {
        deleteCompositeKey(account: account)

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            throw KeychainError.accessControlFailed
        }

        // Security's own copies of the key are out of reach; this buffer is zeroed
        // once the query dictionary and its bridged copies release it.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: SecureWipe.wipingData(copying: key),
            kSecAttrAccessControl as String: accessControl,
            // Required on macOS to use the iOS-style data-protection keychain
            // instead of the legacy file keychain; harmless no-op on iOS.
            kSecUseDataProtectionKeychain as String: true,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    // The bytes CFData hands back are Security-framework owned and cannot be reliably wiped.
    private static func retrieveCompositeKey(account: String, context: LAContext) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        return SymmetricKey(data: data)
    }

    private static func deleteCompositeKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func hasStoredKey(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // Item exists if we get success, or if auth is needed (interaction not allowed / auth failed)
        let exists = status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
        #if DEBUG
        if !exists && status != errSecItemNotFound {
            print("[KeychainService] hasStoredKey unexpected status: \(status)")
        }
        #endif
        return exists
    }

    enum KeychainError: Error, LocalizedError {
        case accessControlFailed
        case storeFailed(OSStatus)
        case retrieveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .accessControlFailed: String(localized: "Failed to create biometric access control")
            case .storeFailed(let s): String(localized: "Keychain store failed (status \(s))")
            case .retrieveFailed(let s): String(localized: "Keychain retrieve failed (status \(s))")
            }
        }
    }
}
