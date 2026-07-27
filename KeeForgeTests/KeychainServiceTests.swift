import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import KeeForge

/// `KeychainService` stores composite keys behind a `.biometryCurrentSet`
/// access control (see `storeCompositeKey(_:account:)`), so `SecItemAdd`
/// never needs authentication, but `SecItemCopyMatching` for the actual bytes
/// does. A headless XCTest run has no way to satisfy a Face ID/Touch ID
/// prompt, so tests that retrieve a *stored* key pass an `LAContext` with
/// `interactionNotAllowed = true` and accept either a successful decrypt
/// (round trip) or an auth-required failure that is provably not
/// "item not found" — the meaningful invariant either way. Deleted/absent
/// items always resolve to `errSecItemNotFound` deterministically, since
/// there is nothing to decrypt and no authentication is ever attempted.
final class KeychainServiceTests: XCTestCase {
    private var databaseIDsToClean: [UUID] = []
    private var legacyFilenamesToClean: [String] = []

    override func tearDown() {
        for databaseID in databaseIDsToClean {
            KeychainService.deleteCompositeKey(for: databaseID)
        }
        for filename in legacyFilenamesToClean {
            KeychainService.deleteLegacyCompositeKey(forFilename: filename)
        }
        databaseIDsToClean = []
        legacyFilenamesToClean = []
        super.tearDown()
    }

    // MARK: - isItemNotFound

    func testIsItemNotFoundIsTrueOnlyForRetrieveFailedItemNotFoundStatus() {
        XCTAssertTrue(KeychainService.isItemNotFound(KeychainService.KeychainError.retrieveFailed(errSecItemNotFound)))

        XCTAssertFalse(
            KeychainService.isItemNotFound(KeychainService.KeychainError.retrieveFailed(errSecAuthFailed)),
            "A real auth failure must not be reported as item-not-found"
        )
        XCTAssertFalse(
            KeychainService.isItemNotFound(KeychainService.KeychainError.retrieveFailed(errSecInteractionNotAllowed)),
            "A real interaction-required failure must not be reported as item-not-found"
        )
        XCTAssertFalse(
            KeychainService.isItemNotFound(KeychainService.KeychainError.storeFailed(errSecItemNotFound)),
            "Only .retrieveFailed carries item-not-found semantics, not .storeFailed"
        )
        XCTAssertFalse(
            KeychainService.isItemNotFound(KeychainService.KeychainError.accessControlFailed),
            ".accessControlFailed is never item-not-found"
        )
        XCTAssertFalse(
            KeychainService.isItemNotFound(CocoaError(.fileNoSuchFile)),
            "Errors that are not a KeychainError must never be misreported as item-not-found"
        )
    }

    // MARK: - Store / delete / hasStoredKey (no biometric interaction required)

    func testStoreCompositeKeyOverwritesExistingItemWithoutDuplicateItemError() throws {
        let databaseID = trackedDatabaseID()

        try requireStore(Data("first-key".utf8), for: databaseID)
        // storeCompositeKey deletes any existing item before adding the new
        // one, so a second store for the same account must not throw
        // errSecDuplicateItem the way a bare SecItemAdd would.
        XCTAssertNoThrow(try KeychainService.storeCompositeKey(Data("second-key".utf8), for: databaseID))
        XCTAssertTrue(KeychainService.hasStoredKey(for: databaseID))
    }

    func testHasStoredKeyReflectsStoreAndDeleteForADatabaseID() throws {
        let databaseID = trackedDatabaseID()

        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID))

        try requireStore(Data("some-composite-key".utf8), for: databaseID)
        XCTAssertTrue(KeychainService.hasStoredKey(for: databaseID))

        KeychainService.deleteCompositeKey(for: databaseID)
        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID))
    }

    func testDeleteCompositeKeyThenRetrieveThrowsItemNotFound() throws {
        let databaseID = trackedDatabaseID()
        try requireStore(Data("to-delete".utf8), for: databaseID)

        KeychainService.deleteCompositeKey(for: databaseID)

        let context = LAContext()
        context.interactionNotAllowed = true
        XCTAssertThrowsError(try KeychainService.retrieveCompositeKey(for: databaseID, context: context)) { error in
            XCTAssertTrue(KeychainService.isItemNotFound(error))
        }
    }

    func testRetrieveCompositeKeyForNeverStoredDatabaseIDThrowsItemNotFound() {
        let context = LAContext()
        context.interactionNotAllowed = true
        XCTAssertThrowsError(try KeychainService.retrieveCompositeKey(for: UUID(), context: context)) { error in
            XCTAssertTrue(KeychainService.isItemNotFound(error))
        }
    }

    // MARK: - Store then retrieve (biometric-gated; environment-dependent)

    func testStoreThenRetrieveRoundTripsWhenNonInteractiveAuthSucceedsOrElseFailsWithAnAuthError() throws {
        let databaseID = trackedDatabaseID()
        let keyData = Data("composite-key-bytes".utf8)
        try requireStore(keyData, for: databaseID)

        let context = LAContext()
        context.interactionNotAllowed = true

        do {
            let retrieved = try KeychainService.retrieveCompositeKey(for: databaseID, context: context)
            XCTAssertEqual(retrieved, keyData, "A successful retrieve must return exactly the stored bytes")
        } catch {
            // The item is protected by .biometryCurrentSet, so a headless
            // simulator/CI host without enrolled (or matchable) biometrics
            // cannot decrypt it non-interactively. That is not the same as
            // the item being absent: isItemNotFound must be false here,
            // because the item genuinely exists (it was just stored above).
            XCTAssertFalse(
                KeychainService.isItemNotFound(error),
                "A key that was just stored must never appear as item-not-found, even when auth cannot complete"
            )
        }
    }

    // MARK: - Legacy filename-keyed accounts (pre-migration compatibility)

    // KeychainService has no public writer for the legacy account, so these
    // tests seed it directly with the same service/account-key shape the
    // service uses internally, minus the biometric access control — which
    // keeps retrieval deterministic here.
    private static let legacyKeychainService = "com.keevault.app"

    private func legacyAccountKey(forFilename filename: String) -> String {
        "compositeKey:\(filename)"
    }

    private func seedLegacyItem(_ data: Data, forFilename filename: String) throws {
        let account = legacyAccountKey(forFilename: filename)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XCTSkip("Keychain writes are unavailable in the current test host (status \(status)).")
        }
    }

    func testHasLegacyStoredKeyAndRetrieveLegacyCompositeKeyRoundTrip() throws {
        let filename = trackedLegacyFilename()
        let keyData = Data("legacy-composite-key".utf8)

        XCTAssertFalse(KeychainService.hasLegacyStoredKey(forFilename: filename))

        try seedLegacyItem(keyData, forFilename: filename)

        XCTAssertTrue(KeychainService.hasLegacyStoredKey(forFilename: filename))
        let context = LAContext()
        context.interactionNotAllowed = true
        let retrieved = try KeychainService.retrieveLegacyCompositeKey(forFilename: filename, context: context)
        XCTAssertEqual(retrieved, keyData)
    }

    func testDeleteLegacyCompositeKeyRemovesTheLegacyItemOnly() throws {
        let filename = trackedLegacyFilename()
        try seedLegacyItem(Data("legacy-to-delete".utf8), forFilename: filename)
        XCTAssertTrue(KeychainService.hasLegacyStoredKey(forFilename: filename))

        KeychainService.deleteLegacyCompositeKey(forFilename: filename)

        XCTAssertFalse(KeychainService.hasLegacyStoredKey(forFilename: filename))
        let context = LAContext()
        context.interactionNotAllowed = true
        XCTAssertThrowsError(
            try KeychainService.retrieveLegacyCompositeKey(forFilename: filename, context: context)
        ) { error in
            XCTAssertTrue(KeychainService.isItemNotFound(error))
        }
    }

    func testHasStoredKeyFallsBackToLegacyFilenameOnlyWhenThePrimaryAccountIsEmpty() throws {
        let databaseID = trackedDatabaseID()
        let filename = trackedLegacyFilename()

        // Neither the primary (UUID) nor legacy (filename) account has
        // anything stored yet.
        XCTAssertFalse(KeychainService.hasStoredKey(for: databaseID, legacyFilename: filename))

        // Only the legacy account has a key: the fallback must find it.
        try seedLegacyItem(Data("legacy-fallback".utf8), forFilename: filename)
        XCTAssertTrue(KeychainService.hasStoredKey(for: databaseID, legacyFilename: filename))

        // Once the primary (migrated) account also has a key, the combined
        // check still reports true (primary alone is sufficient).
        try requireStore(Data("migrated-key".utf8), for: databaseID)
        KeychainService.deleteLegacyCompositeKey(forFilename: filename)
        XCTAssertTrue(
            KeychainService.hasStoredKey(for: databaseID, legacyFilename: filename),
            "Once migrated, the primary account alone must satisfy the combined check"
        )
    }

    func testHasStoredKeyWithoutLegacyFilenameIgnoresAnyLegacyItem() throws {
        let databaseID = trackedDatabaseID()
        let filename = trackedLegacyFilename()
        try seedLegacyItem(Data("legacy-only".utf8), forFilename: filename)

        XCTAssertFalse(
            KeychainService.hasStoredKey(for: databaseID, legacyFilename: nil),
            "Without a legacyFilename to fall back to, an unrelated legacy item must not count"
        )
    }

    // MARK: - Helpers

    private func trackedDatabaseID() -> UUID {
        let id = UUID()
        databaseIDsToClean.append(id)
        return id
    }

    private func trackedLegacyFilename() -> String {
        let filename = "legacy-\(UUID().uuidString).kdbx"
        legacyFilenamesToClean.append(filename)
        return filename
    }

    private func requireStore(_ key: Data, for databaseID: UUID) throws {
        do {
            try KeychainService.storeCompositeKey(key, for: databaseID)
        } catch {
            throw XCTSkip("Keychain writes are unavailable in the current test host: \(error)")
        }
    }
}
