import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum KeychainService {
    private static let service = "com.keevault.app"
    private static let compositeKeyAccount = "compositeKey"
    private static let expressUnlockKeyAccount = "expressUnlockKey"

    /// One quick-unlock item per database. On the native Mac app Touch ID or
    /// an authorized Apple Watch can release it; iPhone and iPad stay
    /// biometric-only. No flag admits the device passcode or the Mac login
    /// password. Must stay in step with `BiometricService.quickUnlockPolicy`.
    static var quickUnlockAccessControlFlags: SecAccessControlCreateFlags {
        #if os(macOS)
        [.biometryCurrentSet, .or, .companion]
        #else
        .biometryCurrentSet
        #endif
    }

    private static func accountKey(for databaseID: UUID) -> String {
        "\(compositeKeyAccount):\(databaseID.uuidString)"
    }

    private static func legacyAccountKey(forFilename filename: String) -> String {
        "\(compositeKeyAccount):\(filename)"
    }

    private static func expressUnlockAccountKey(for databaseID: UUID) -> String {
        "\(expressUnlockKeyAccount):\(databaseID.uuidString)"
    }

    /// Replacing the quick-unlock key also drops the express-unlock item:
    /// that item was derived from the key being replaced.
    static func storeCompositeKey(_ key: SymmetricKey, for databaseID: UUID) throws {
        deleteExpressUnlockKey(for: databaseID)
        let account = accountKey(for: databaseID)
        try storeItem(key, account: account)
    }

    static func retrieveCompositeKey(for databaseID: UUID, context: LAContext) throws -> SymmetricKey {
        let account = accountKey(for: databaseID)
        return try retrieveItem(account: account, context: context)
    }

    static func deleteCompositeKey(for databaseID: UUID) {
        deleteExpressUnlockKey(for: databaseID)
        let account = accountKey(for: databaseID)
        deleteItem(account: account)
    }

    /// Same protection as the quick-unlock item: the payload opens the
    /// database version it was derived for.
    static func storeExpressUnlockKey(_ payload: Data, for databaseID: UUID) throws {
        try storeItem(SymmetricKey(data: payload), account: expressUnlockAccountKey(for: databaseID))
    }

    /// Read with the context that already released the quick-unlock key. It
    /// never prompts: if that context does not satisfy the item, the read
    /// fails and the unlock runs the KDF instead of asking a second time.
    static func retrieveExpressUnlockKey(for databaseID: UUID, context: LAContext) throws -> SymmetricKey {
        context.interactionNotAllowed = true
        return try retrieveItem(account: expressUnlockAccountKey(for: databaseID), context: context)
    }

    static func deleteExpressUnlockKey(for databaseID: UUID) {
        deleteItem(account: expressUnlockAccountKey(for: databaseID))
    }

    static func hasExpressUnlockKey(for databaseID: UUID) -> Bool {
        hasStoredKey(account: expressUnlockAccountKey(for: databaseID))
    }

    static func hasStoredKey(for databaseID: UUID, legacyFilename: String? = nil) -> Bool {
        if hasStoredKey(account: accountKey(for: databaseID)) {
            return true
        }

        guard let legacyFilename else { return false }
        return hasStoredKey(account: legacyAccountKey(forFilename: legacyFilename))
    }

    /// Whether a successful unlock should (re)write the quick-unlock item.
    /// On the Mac an existing item is rewritten even while neither Touch ID
    /// nor the watch can authenticate (lid closed, watch away): adding needs
    /// no authentication, and the master key may have changed on another
    /// device since the item was written.
    static func shouldStoreQuickUnlockKey(for databaseID: UUID, legacyFilename: String?) -> Bool {
        if BiometricService.isQuickUnlockAvailable {
            return true
        }
        #if os(macOS)
        return hasStoredKey(for: databaseID, legacyFilename: legacyFilename)
        #else
        return false
        #endif
    }

    static func retrieveLegacyCompositeKey(forFilename filename: String, context: LAContext) throws -> SymmetricKey {
        try retrieveItem(account: legacyAccountKey(forFilename: filename), context: context)
    }

    static func deleteLegacyCompositeKey(forFilename filename: String) {
        deleteItem(account: legacyAccountKey(forFilename: filename))
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

    private static func storeItem(_ key: SymmetricKey, account: String) throws {
        deleteItem(account: account)

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            quickUnlockAccessControlFlags,
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
            // No kSecAttrAccessGroup: the item lands in the first entitled
            // group, which must stay the one shared with AutoFill.
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
    private static func retrieveItem(account: String, context: LAContext) throws -> SymmetricKey {
        #if os(macOS)
        // The caller's evaluated policy is the only prompt. The Mac item also
        // admits Apple Watch, so a Keychain-raised prompt could offer the
        // watch inside biometric-only AutoFill; fail instead and let the user
        // fall back to the master password.
        context.interactionNotAllowed = true
        #endif
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

    private static func deleteItem(account: String) {
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
