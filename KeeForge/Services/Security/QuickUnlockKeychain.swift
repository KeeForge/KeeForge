import CryptoKit
import Foundation
import LocalAuthentication

/// What quick unlock reads from, and an unlock writes back to, the Keychain.
/// `storedKey` is the composite key, or the pre-key for a hardware-key
/// database, which never has an `expressKey`.
struct QuickUnlockKeys: Sendable {
    let storedKey: SymmetricKey
    var expressKey: ExpressUnlockKey?
}

/// The quick-unlock rules the app and both AutoFill extensions share.
enum QuickUnlockKeychain {
    /// Reads with the context that released the quick-unlock item. A missing
    /// or unreadable express item only costs the KDF.
    static func retrieve(for reference: DatabaseReference, context: LAContext) throws -> QuickUnlockKeys {
        let storedKey = try retrieveStoredKey(for: reference, context: context)
        guard reference.hardwareKey == nil,
              let payload = try? KeychainService.retrieveExpressUnlockKey(for: reference.id, context: context) else {
            return QuickUnlockKeys(storedKey: storedKey)
        }
        return QuickUnlockKeys(storedKey: storedKey, expressKey: ExpressUnlockKey(serialized: payload))
    }

    static func retrieveStoredKey(for reference: DatabaseReference, context: LAContext) throws -> SymmetricKey {
        do {
            return try KeychainService.retrieveCompositeKey(for: reference.id, context: context)
        } catch {
            guard KeychainService.isItemNotFound(error),
                  let legacyFilename = reference.legacyKeychainFilename else {
                throw error
            }

            return try KeychainService.retrieveLegacyCompositeKey(forFilename: legacyFilename, context: context)
        }
    }

    /// Returns whether the quick-unlock item now holds `keys.storedKey`.
    @discardableResult
    static func persist(_ keys: QuickUnlockKeys, for reference: DatabaseReference) -> Bool {
        // Silently skip when nothing could satisfy the item's access control:
        // no enrolled biometrics (and, on the Mac, no authorized Apple Watch)
        // is the common Mac desktop case. Password unlock stays primary,
        // nothing is stored, no error is surfaced, and there are no retry
        // loops. An existing Mac item is still refreshed; see
        // `KeychainService.shouldStoreQuickUnlockKey`.
        guard KeychainService.shouldStoreQuickUnlockKey(
            for: reference.id,
            legacyFilename: reference.legacyKeychainFilename
        ) else { return false }

        do {
            try KeychainService.storeCompositeKey(keys.storedKey, for: reference.id)

            if let legacyFilename = reference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
                DatabaseListStore.clearLegacyKeychainFilename(for: reference.id)
            }
        } catch {
            return false
        }

        // Written after the quick-unlock key, whose store just removed the
        // previous express item.
        if reference.hardwareKey == nil, let expressKey = keys.expressKey {
            try? KeychainService.storeExpressUnlockKey(expressKey.serialized(), for: reference.id)
        }
        return true
    }

    /// After a save, which rotated the KDF salt so the item no longer opens
    /// the file. It is replaced only while a quick-unlock item exists, which
    /// a user who turned quick unlock off mid-session no longer has.
    static func replaceExpressKey(with key: ExpressUnlockKey?, for reference: DatabaseReference) {
        KeychainService.deleteExpressUnlockKey(for: reference.id)
        guard let key,
              reference.hardwareKey == nil,
              KeychainService.hasStoredKey(for: reference.id) else { return }
        try? KeychainService.storeExpressUnlockKey(key.serialized(), for: reference.id)
    }
}
