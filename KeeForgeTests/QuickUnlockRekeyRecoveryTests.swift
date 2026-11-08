import CryptoKit
import LocalAuthentication
import XCTest
@testable import KeeForge

final class QuickUnlockRekeyRecoveryTests: XCTestCase {
    private var reference: DatabaseReference!

    override func setUp() {
        super.setUp()
        reference = DatabaseListStore.addCloud(
            provider: "webdav",
            accountId: UUID().uuidString,
            file: CloudFile(id: UUID().uuidString, name: "Recovery.kdbx", path: "/Recovery.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        )
        reference.updateCloudSyncMetadata {
            $0.keyEpoch = UUID()
            $0.localHeadOperationID = UUID()
            $0.requiresTypedUnlock = true
        }
        DatabaseListStore.update(reference)
    }

    override func tearDown() {
        DatabaseListStore.remove(id: reference.id)
        super.tearDown()
    }

    func testRecoveredRekeyRefusesQuickUnlockBeforeAccessingStoredKey() throws {
        try storeKeyOrSkip()
        let context = LAContext()
        context.interactionNotAllowed = true

        XCTAssertThrowsError(try QuickUnlockKeychain.retrieveStoredKey(for: reference, context: context)) {
            XCTAssertTrue(KeychainService.isItemNotFound($0))
        }
        XCTAssertTrue(KeychainService.hasStoredKey(for: reference.id))
    }

    func testStaleReferenceCannotBypassPersistedTypedUnlockRequirement() throws {
        try storeKeyOrSkip()
        var stale = reference!
        stale.updateCloudSyncMetadata { $0.requiresTypedUnlock = nil }
        let context = LAContext()
        context.interactionNotAllowed = true

        XCTAssertThrowsError(try QuickUnlockKeychain.retrieveStoredKey(for: stale, context: context)) {
            XCTAssertTrue(KeychainService.isItemNotFound($0))
        }
        XCTAssertFalse(QuickUnlockKeychain.persist(
            QuickUnlockKeys(storedKey: SymmetricKey(size: .bits256)), for: stale, masterKeyEntered: false
        ))
        XCTAssertEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, true)
    }

    func testTypedEntryForOlderEpochCannotReplaceTheStoredKeyOrClearRequirement() throws {
        try storeKeyOrSkip()
        var stale = reference!
        stale.updateCloudSyncMetadata { $0.keyEpoch = UUID() }

        XCTAssertFalse(QuickUnlockKeychain.persist(
            QuickUnlockKeys(storedKey: SymmetricKey(size: .bits256)), for: stale, masterKeyEntered: true
        ))
        XCTAssertTrue(KeychainService.hasStoredKey(for: reference.id))
        XCTAssertEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, true)
    }

    func testConditionalClearRejectsAnOlderLocalHeadAndPreservesOtherMetadata() {
        var newer = reference!
        newer.updateCloudSyncMetadata {
            $0.localHeadOperationID = UUID()
            $0.lastSyncIssue = .networkUnavailable
        }
        DatabaseListStore.update(newer)

        XCTAssertFalse(DatabaseListStore.clearCloudTypedUnlockRequirement(for: reference))
        XCTAssertEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, true)
        XCTAssertEqual(storedReference.cloudSyncMetadata?.localHeadOperationID, newer.cloudSyncMetadata?.localHeadOperationID)
        XCTAssertEqual(storedReference.cloudSyncMetadata?.lastSyncIssue, .networkUnavailable)
        XCTAssertTrue(DatabaseListStore.clearCloudTypedUnlockRequirement(for: newer))
        XCTAssertNotEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, true)
        XCTAssertEqual(storedReference.cloudSyncMetadata?.lastSyncIssue, .networkUnavailable)
    }

    func testRefusedPersistenceKeepsTypedOnlyState() {
        let previous = SettingsService.quickUnlockPasswordInterval
        defer { SettingsService.quickUnlockPasswordInterval = previous }
        SettingsService.quickUnlockPasswordInterval = .always

        XCTAssertFalse(QuickUnlockKeychain.persist(
            QuickUnlockKeys(storedKey: SymmetricKey(size: .bits256)), for: reference, masterKeyEntered: true
        ))
        XCTAssertEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, true)
        XCTAssertFalse(KeychainService.hasStoredKey(for: reference.id))
    }

    func testRekeyJournalRefusesEvenTypedKeyPersistenceBeforeFlagPublication() throws {
        try stageRekeyBeforeFlagPublication()

        XCTAssertFalse(QuickUnlockKeychain.persist(
            QuickUnlockKeys(storedKey: SymmetricKey(size: .bits256)), for: reference, masterKeyEntered: true
        ))
        XCTAssertFalse(KeychainService.hasStoredKey(for: reference.id))
        XCTAssertTrue(PendingUploadQueue.hasRekeyJournal(for: reference.id))
        XCTAssertEqual(storedReference.cloudSyncMetadata?.requiresTypedUnlock, false)
    }

    func testRekeyJournalRefusesStoredKeyBeforeFlagPublication() throws {
        try stageRekeyBeforeFlagPublication()
        try storeKeyOrSkip()
        let context = LAContext()
        context.interactionNotAllowed = true

        XCTAssertThrowsError(try QuickUnlockKeychain.retrieveStoredKey(for: reference, context: context)) {
            XCTAssertTrue(KeychainService.isItemNotFound($0))
        }
        XCTAssertTrue(PendingUploadQueue.hasRekeyJournal(for: reference.id))
    }

    private func stageRekeyBeforeFlagPublication() throws {
        reference.updateCloudSyncMetadata { $0.requiresTypedUnlock = false }
        DatabaseListStore.update(reference)
        var marker = PendingUploadQueue.Marker(
            databaseId: reference.id, encryptedBytesCacheURL: "cloud-cache/rekey-window.kdbx",
            openTimeSHA512: Data([1]), expectedRev: nil, createdAt: .now, isPayloadFinalized: false
        )
        marker.rekeyContext = PendingUploadQueue.RekeyContext(keyFileBookmarkData: nil, keyFileFilename: nil)
        _ = try PendingUploadQueue.enqueue(marker, notifying: false)
    }

    private var storedReference: DatabaseReference {
        DatabaseListStore.databases.first { $0.id == reference.id } ?? reference
    }

    private func storeKeyOrSkip() throws {
        do {
            try KeychainService.storeCompositeKey(SymmetricKey(size: .bits256), for: reference.id)
        } catch {
            throw XCTSkip("Keychain writes unavailable in this test host: \(error)")
        }
    }
}
