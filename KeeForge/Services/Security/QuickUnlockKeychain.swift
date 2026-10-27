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
    /// or unreadable express item only costs the KDF. The context is spent
    /// afterwards, so it cannot release either item again without a prompt.
    static func retrieve(for reference: DatabaseReference, context: LAContext) throws -> QuickUnlockKeys {
        defer { context.invalidate() }
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
    /// `masterKeyEntered` restarts the password interval; a quick unlock only
    /// starts it for an item stored before the interval existed.
    @discardableResult
    static func persist(_ keys: QuickUnlockKeys, for reference: DatabaseReference, masterKeyEntered: Bool) -> Bool {
        guard SettingsService.quickUnlockPasswordInterval != .always else {
            expireIfDue(reference)
            return false
        }
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

        recordMasterKeyEntry(for: reference.id, replacingExisting: masterKeyEntered)
        // Written after the quick-unlock key, whose store just removed the
        // previous express item.
        if reference.hardwareKey == nil, let expressKey = keys.expressKey {
            try? KeychainService.storeExpressUnlockKey(expressKey.serialized(), for: reference.id)
        }
        return true
    }

    // MARK: - Password interval

    private static let masterKeyEntriesKey = "KeeForge.quickUnlockMasterKeyEntries"

    static func recordMasterKeyEntry(
        for databaseID: UUID,
        replacingExisting: Bool = true,
        at date: Date = .now,
        in defaults: UserDefaults = AppGroupContainer.defaults
    ) {
        var entries = defaults.dictionary(forKey: masterKeyEntriesKey) ?? [:]
        guard replacingExisting || entries[databaseID.uuidString] == nil else { return }
        entries[databaseID.uuidString] = date
        defaults.set(entries, forKey: masterKeyEntriesKey)
    }

    /// A clock set back past the interval counts as due too, so moving the
    /// date cannot keep quick unlock alive.
    static func isMasterKeyDue(
        for databaseID: UUID,
        interval: SettingsService.QuickUnlockPasswordInterval = SettingsService.quickUnlockPasswordInterval,
        now: Date = .now,
        in defaults: UserDefaults = AppGroupContainer.defaults
    ) -> Bool {
        if interval == .always { return true }
        guard let duration = interval.duration,
              let enteredAt = defaults.dictionary(forKey: masterKeyEntriesKey)?[databaseID.uuidString] as? Date else {
            return false
        }
        return abs(now.timeIntervalSince(enteredAt)) >= duration
    }

    /// Deletes both items once the master key is due, so a cached key does
    /// not outlive the interval on disk. Returns whether it did.
    @discardableResult
    static func expireIfDue(_ reference: DatabaseReference) -> Bool {
        guard isMasterKeyDue(for: reference.id) else { return false }
        KeychainService.deleteCompositeKey(for: reference.id)
        if let legacyFilename = reference.legacyKeychainFilename {
            KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
        }
        return true
    }

    /// After the interval was shortened or set to `.always`, so saved keys
    /// that are now due go at once rather than at their next use.
    static func expireDueKeys() {
        for reference in DatabaseListStore.databases {
            expireIfDue(reference)
        }
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
