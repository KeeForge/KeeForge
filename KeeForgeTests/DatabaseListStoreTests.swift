@preconcurrency import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    func testAddPersistsDatabaseReference() throws {
        let url = try makeTemporaryFileURL(name: "personal.kdbx")

        let reference = try DatabaseListStore.add(url: url)
        let storedReferences = DatabaseListStore.databases

        XCTAssertEqual(storedReferences.count, 1)
        XCTAssertEqual(storedReferences.first?.id, reference.id)
        XCTAssertEqual(storedReferences.first?.filename, "personal.kdbx")
    }

    func testInitializationCreatesMissingRegistryAndPreservesExistingRegistry() throws {
        guard case .initialized = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected initialization") }
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "initialized.kdbx"))
        let url = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let before = try Data(contentsOf: url)
        guard case .alreadyPresent = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected existing registry") }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(DatabaseListStore.databases.first?.id, reference.id)
    }

    func testInitializationRejectsCorruptRegistryWithoutReplacingIt() throws {
        let url = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        guard case .notPublished = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected rejection") }
        XCTAssertFalse(DatabaseListStore.setNickname("changed", for: UUID()))
        XCTAssertThrowsError(try DatabaseListStore.add(url: makeTemporaryFileURL(name: "corrupt-add.kdbx")))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testInitializationMigratesLegacyReference() throws {
        let original = try makeTemporaryFileURL(name: "legacy-init.kdbx")
        try SharedVaultStore.saveBookmark(for: original)
        guard case .initialized = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected migration") }
        let migrated = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(migrated.filename, original.lastPathComponent)
        XCTAssertEqual(migrated.legacyKeychainFilename, original.lastPathComponent)
        XCTAssertEqual(migrated.bookmarkData, SharedVaultStore.legacyBookmarkData)
    }

    func testInitializationRejectsUnreadableRegistryWithoutReplacingIt() throws {
        let url = AppGroupContainer.url.appendingPathComponent("database-list.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .notPublished = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected rejection") }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testReadOnlyRejectsReferenceObservedBeforeRelink() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "before.kdbx"))
        let replacement = try makeTemporaryFileURL(name: "after.kdbx")
        let relinked = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement))

        XCTAssertFalse(DatabaseListStore.setReadOnly(true, for: original))
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == original.id }))
        XCTAssertEqual(stored.bookmarkData, relinked.bookmarkData)
        XCTAssertFalse(stored.isReadOnly)
        XCTAssertTrue(stored.hasUnverifiedRelink)
    }

    func testHardwarePreferenceRejectsStaleTargetWithoutKeyDeletion() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "hardware-old.kdbx"))
        let replacement = try makeTemporaryFileURL(name: "hardware-new.kdbx")
        _ = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement))
        var deletes = 0
        let desired = HardwareKeyConfiguration(transport: .nfc, slot: .one)
        XCTAssertEqual(DatabaseListStore.setHardwareKey(desired, for: original, deleteKeys: { _, _ in deletes += 1 }), .rejected)
        XCTAssertEqual(deletes, 0)
        XCTAssertTrue(DatabaseListStore.remove(id: original.id))
        XCTAssertEqual(DatabaseListStore.setHardwareKey(desired, for: original, deleteKeys: { _, _ in deletes += 1 }), .rejected)
        XCTAssertEqual(deletes, 0)
    }

    func testHardwarePreferenceReportsKeyEffectWhenRegistryWriteFails() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "hardware-fault.kdbx"))
        var io = DurableFileWriteIO()
        io.synchronizeFile = { _ in throw POSIXError(.EIO) }
        var deletes = 0
        let desired = HardwareKeyConfiguration(transport: .nfc, slot: .one)
        XCTAssertEqual(DatabaseListStore.setHardwareKey(desired, for: reference, io: io, deleteKeys: { _, _ in deletes += 1 }), .keyEffectUnconfirmed)
        XCTAssertEqual(deletes, 1)
        XCTAssertNil(DatabaseListStore.databases.first?.hardwareKey)
    }

    func testHardwarePreferenceReportsVisibleUnconfirmed() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "hardware-visible.kdbx"))
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        var deletes = 0
        let desired = HardwareKeyConfiguration(transport: .nfc, slot: .one)
        XCTAssertEqual(DatabaseListStore.setHardwareKey(desired, for: reference, io: io, deleteKeys: { _, _ in deletes += 1 }), .visibleUnconfirmed)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(DatabaseListStore.databases.first?.hardwareKey, desired)
    }

    func testAutoFillRejectionAndUnconfirmedWriteDoNotQueueRemoval() async throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "autofill-old.kdbx"))
        let replacement = try makeTemporaryFileURL(name: "autofill-new.kdbx")
        let current = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement))
        let removal = expectation(description: "No identity removal")
        removal.isInverted = true
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in removal.fulfill() }
        XCTAssertEqual(DatabaseListStore.setAutoFillEnabled(false, for: original), .rejected)
        var beforeWriteIO = DurableFileWriteIO()
        beforeWriteIO.synchronizeFile = { _ in throw POSIXError(.EIO) }
        XCTAssertEqual(DatabaseListStore.setAutoFillEnabled(false, for: current, io: beforeWriteIO), .notPublished)
        XCTAssertTrue(try XCTUnwrap(DatabaseListStore.databases.first).autoFillEnabled)
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        XCTAssertEqual(DatabaseListStore.setAutoFillEnabled(false, for: current, io: io), .visibleUnconfirmed)
        await fulfillment(of: [removal], timeout: 0.2)
        XCTAssertFalse(try XCTUnwrap(DatabaseListStore.databases.first).autoFillEnabled)
    }

    func testKeyAssociationRejectsStaleObservationAndMissingRow() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "association-old.kdbx"))
        let replacement = try makeTemporaryFileURL(name: "association-new.kdbx")
        let relinked = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement))
        XCTAssertEqual(DatabaseListStore.setKeyFileAssociation(for: original, bookmarkData: Data("key".utf8), filename: "key", masterKeyChangedAt: .now), .rejected)
        XCTAssertEqual(DatabaseListStore.databases.first?.bookmarkData, relinked.bookmarkData)
        XCTAssertTrue(DatabaseListStore.remove(id: original.id))
        XCTAssertNotEqual(DatabaseListStore.setKeyFileAssociation(for: original, bookmarkData: nil, filename: nil, masterKeyChangedAt: .now), .saved)
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testKeyAssociationReportsUnconfirmedPublication() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "association-uncertain.kdbx"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        XCTAssertEqual(DatabaseListStore.setKeyFileAssociation(for: reference, bookmarkData: nil, filename: "key", masterKeyChangedAt: date, io: io), .publishedWithoutConfirmedDurability)
        XCTAssertEqual(DatabaseListStore.databases.first?.lastMasterKeyChangeAt, date)
    }

    func testDocumentsIdentityRejectsStaleObservationAndMissingRow() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "before-identity.kdbx"))
        let replacement = try makeTemporaryFileURL(name: "after-identity.kdbx")
        let relinked = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement))
        XCTAssertFalse(DatabaseListStore.rederiveDocumentsIdentity(for: original, filename: "stale.kdbx", isDocumentsResident: true))
        XCTAssertFalse(DatabaseListStore.rebindBookmarkData(Data("stale".utf8), for: original, toFileAt: replacement))
        XCTAssertEqual(DatabaseListStore.databases.first?.filename, relinked.filename)
        XCTAssertTrue(DatabaseListStore.remove(id: original.id))
        XCTAssertFalse(DatabaseListStore.rederiveDocumentsIdentity(for: original, filename: "stale.kdbx", isDocumentsResident: true))
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testAddCreatedCloudRejectsCorruptRegistry() throws {
        let reference = makeStoredCloudReference(remoteRev: "rev", remoteContentHash: "hash")
        let url = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try DatabaseListStore.addCreatedCloud(reference))
        let file = CloudFile(id: "new", name: "new.kdbx", path: "/new.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        XCTAssertThrowsError(try DatabaseListStore.addCloud(provider: "test", accountId: "account", file: file))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testAddCloudReportsVisibleUnconfirmedWithoutSelectingSuccess() throws {
        guard case .initialized = DatabaseListStore.initializeRegistry() else { return XCTFail("Expected initialization") }
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        let file = CloudFile(id: "uncertain", name: "uncertain.kdbx", path: "/uncertain.kdbx", isFolder: false, modifiedDate: nil, size: nil)
        XCTAssertThrowsError(try DatabaseListStore.addCloud(provider: "test", accountId: "account", file: file, io: io)) { error in
            guard case DatabaseListStore.RegistryWriteError.visibleUnconfirmed = error else { return XCTFail("Expected unconfirmed effect: \(error)") }
        }
        XCTAssertEqual(DatabaseListStore.databases.first?.cloudSyncMetadata?.fileId, file.id)
    }

    func testCloudMetadataCASRejectsRevisionCollisionAndStaleFactors() throws {
        var original = makeStoredCloudReference(remoteRev: "a\u{1F}b", remoteContentHash: "c")
        let observed = try XCTUnwrap(original.cloudSyncMetadata)
        var current = original
        current.updateCloudSyncMetadata { $0.remoteRev = "a"; $0.remoteContentHash = "b\u{1F}c" }
        DatabaseListStore.testUpsert(current)
        if case .mismatch = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: original.id, ifUnchangedFrom: observed, observedReference: original, mutate: { $0.lastSyncedAt = .now }) {} else { XCTFail("Expected revision mismatch") }
        original = current
        let metadata = try XCTUnwrap(original.cloudSyncMetadata)
        current.keyFileFilename = "new-key"
        DatabaseListStore.testUpsert(current)
        if case .mismatch = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: original.id, ifUnchangedFrom: metadata, observedReference: original, mutate: { $0.lastSyncedAt = .now }) {} else { XCTFail("Expected factor mismatch") }
        XCTAssertNil(DatabaseListStore.databases.first?.cloudSyncMetadata?.lastSyncedAt)
    }

    func testCloudMetadataReportsVisibleUnconfirmedPublication() throws {
        let reference = makeStoredCloudReference(remoteRev: "rev", remoteContentHash: "hash")
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        if case .visibleUnconfirmed = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed, observedReference: reference, io: io, mutate: { $0.lastSyncedAt = Date(timeIntervalSince1970: 123) }) {} else { XCTFail("Expected visible-unconfirmed publication") }
        XCTAssertEqual(DatabaseListStore.databases.first?.cloudSyncMetadata?.lastSyncedAt, Date(timeIntervalSince1970: 123))
    }

    func testCloudMetadataNoopDoesNotWriteAndExplicitConfirmationCanFail() throws {
        let reference = makeStoredCloudReference(remoteRev: "rev", remoteContentHash: "hash")
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)
        var io = DurableFileWriteIO()
        io.write = { _, _, _ in XCTFail("No-op must not write"); return -1 }
        if case .published = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed, observedReference: reference, io: io, mutate: { _ in }) {} else { XCTFail("Expected no-op") }
        io.synchronizeFile = { _ in throw POSIXError(.EIO) }
        if case .writeFailed = DatabaseListStore.compareAndUpdateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed, observedReference: reference, confirmUnchanged: true, io: io, mutate: { _ in }) {} else { XCTFail("Expected failed durability confirmation") }
        XCTAssertEqual(DatabaseListStore.databases.first?.cloudSyncMetadata, observed)
    }

    func testAddRejectsSameLocalFileTwice() throws {
        let url = try makeTemporaryFileURL(name: "duplicate.kdbx")
        let firstReference = try DatabaseListStore.add(url: url)

        XCTAssertThrowsError(try DatabaseListStore.add(url: url)) { error in
            guard case let DatabaseListStore.AddDatabaseError.duplicateFile(existingReferenceID, filename) = error else {
                XCTFail("Expected duplicateFile error, got \(error)")
                return
            }
            XCTAssertEqual(existingReferenceID, firstReference.id)
            XCTAssertEqual(filename, firstReference.displayName)
        }
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
    }

    func testRemoveDropsOnlyThatDatabasesMasterPasswordDate() throws {
        let removed = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "removed.kdbx"))
        let kept = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "kept.kdbx"))
        defer { QuickUnlockKeychain.removeMasterKeyEntry(for: kept.id) }
        let typedLongAgo = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)
        QuickUnlockKeychain.recordMasterKeyEntry(for: removed.id, at: typedLongAgo)
        QuickUnlockKeychain.recordMasterKeyEntry(for: kept.id, at: typedLongAgo)

        DatabaseListStore.remove(id: removed.id)

        // A missing date never counts as due, so due-ness shows whether the entry survived.
        XCTAssertFalse(QuickUnlockKeychain.isMasterKeyDue(for: removed.id, interval: .fourteenDays))
        XCTAssertTrue(QuickUnlockKeychain.isMasterKeyDue(for: kept.id, interval: .fourteenDays))
    }

    /// The iPad-on-Mac transition note tells people to do exactly this pair,
    /// so both halves are load-bearing: removal must leave the user's file on
    /// disk, and re-adding it must produce a usable reference. Re-adding
    /// *without* removing first is refused — see
    /// `testAddRejectsSameLocalFileTwice`, which is why the note says to remove.
    func testRemoveThenAddSameFileRestoresReferenceAndKeepsFile() throws {
        let contents = Data("fixture".utf8)
        let url = try makeTemporaryFileURL(name: "transition.kdbx", contents: contents)
        let original = try DatabaseListStore.add(url: url)
        try writeAtomicallyAndDurably(Data("cached".utf8), to: DatabaseListStore.cacheLocation(for: original), directoryAnchor: AppGroupContainer.url)

        DatabaseListStore.remove(id: original.id)

        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Removing a database from the list must never delete the file itself"
        )

        let readded = try DatabaseListStore.add(url: url)

        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(readded.filename, "transition.kdbx")
        XCTAssertNotEqual(readded.id, original.id)
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    func testRefreshingAndRemovingOneSharedCachePreservesTheOther() async throws {
        let identityStore = FakeCredentialIdentityStore()
        identityStore.onMutation = { XCTFail("Empty identities should need no mutation") }
        CredentialIdentityStoreManager.storeProviderOverride = identityStore
        let firstSource = try makeTemporaryFileURL(name: "A.kdbx")
        let first = try DatabaseListStore.add(url: firstSource)
        let secondSource = try makeTemporaryFileURL(name: "B.kdbx")
        let second = try DatabaseListStore.add(url: secondSource)
        let firstBytes = Data("encrypted A".utf8)
        let secondBytes = Data("encrypted B".utf8)
        try firstBytes.write(to: firstSource)
        try secondBytes.write(to: secondSource)
        try DatabaseListStore.cacheDatabaseCopy(firstBytes, for: first.id)
        try DatabaseListStore.cacheDatabaseCopy(secondBytes, for: second.id)
        let secondURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: second.id))

        let refreshed = Data("refreshed encrypted A".utf8)
        try refreshed.write(to: firstSource)
        try DatabaseListStore.cacheDatabaseCopy(refreshed, for: first.id)

        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: first.id))), refreshed)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        DatabaseListStore.remove(id: first.id)
        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: first.id))
        XCTAssertNotNil(DatabaseListStore.cachedDatabaseURL(for: second.id))
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [second.id])
        await CredentialIdentityStoreManager.waitForPendingMutations()
    }

    func testCacheRejectsBytesThatDoNotBelongToTheCurrentSource() throws {
        let bytes = Data("current encrypted source".utf8)
        let url = try makeTemporaryFileURL(name: "exact-source.kdbx", contents: bytes)
        let reference = try DatabaseListStore.add(url: url)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        XCTAssertThrowsError(try DatabaseListStore.cacheDatabaseCopy(Data("foreign ciphertext".utf8), for: reference)) { error in
            XCTAssertEqual(error as? PendingLocalSaveStore.OwnershipError, .targetChanged)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertEqual(DatabaseListStore.databases.first?.id, reference.id)
    }

    func testCacheDatabaseCopyUsesPerDatabaseUUIDPath() throws {
        let url = try makeTemporaryFileURL(name: "work.kdbx", contents: Data("fixture".utf8))
        let reference = try DatabaseListStore.add(url: url)
        let cachedData = Data("cached".utf8)

        try cachedData.write(to: url)
        try DatabaseListStore.cacheDatabaseCopy(cachedData, for: reference.id)

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(cachedURL.lastPathComponent, "\(reference.id.uuidString).kdbx")
        XCTAssertEqual(try Data(contentsOf: cachedURL), cachedData)
    }

    func testUpdatePersistsNicknameQuickLaunchAndKeyFileAssociation() throws {
        let databaseURL = try makeTemporaryFileURL(name: "family.kdbx")
        let keyFileURL = try makeTemporaryFileURL(name: "family.keyx")
        var reference = try DatabaseListStore.add(url: databaseURL)

        reference.nickname = "Shared Family"
        reference.isQuickLaunch = true
        reference.keyFileBookmarkData = try keyFileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        reference.keyFileFilename = keyFileURL.lastPathComponent
        DatabaseListStore.testUpsert(reference)

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(storedReference.displayName, "Shared Family")
        XCTAssertTrue(storedReference.isQuickLaunch)
        XCTAssertEqual(storedReference.keyFileFilename, "family.keyx")
        XCTAssertEqual(DatabaseListStore.quickLaunchDatabase?.id, storedReference.id)
    }

    #if os(macOS)
    func testRefreshStaleLockedKeyFileBookmarkPreservesLegacyAssociation() async throws {
        let url = try makeTemporaryFileURL(name: "original.keyx")
        let movedURL = url.deletingLastPathComponent().appendingPathComponent("moved.keyx")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: movedURL.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "legacy-key.kdbx"))
        let legacyBookmark = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        reference.keyFileBookmarkData = legacyBookmark
        reference.keyFileFilename = url.lastPathComponent
        DatabaseListStore.testUpsert(reference)
        try FileManager.default.moveItem(at: url, to: movedURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: movedURL.path)
        XCTAssertTrue(try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: legacyBookmark)).isStale)

        var renewal: Task<DatabaseListStore.KeyFilePreferenceOutcome, Never>?
        let resolved = try XCTUnwrap(DatabaseListStore.resolveKeyFileURL(for: reference, onRenewal: { renewal = $0 }))
        let completion = try XCTUnwrap(renewal)
        _ = await completion.value
        XCTAssertEqual(try Data(contentsOf: resolved), try Data(contentsOf: movedURL))
        let stored = try XCTUnwrap(DatabaseListStore.databases.first)
        let refreshed = try XCTUnwrap(stored.keyFileBookmarkData)
        XCTAssertNotEqual(refreshed, legacyBookmark)
        XCTAssertFalse(try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: refreshed)).isStale)
        XCTAssertEqual(stored.id, reference.id)
        XCTAssertEqual(stored.bookmarkData, reference.bookmarkData)
    }
    #endif

    func testMoveReordersDatabases() throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))

        DatabaseListStore.move(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [second.id, first.id])
    }

    func testNormalizedKeepsOnlyFirstQuickLaunchDatabase() throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))

        var updatedFirst = first
        updatedFirst.isQuickLaunch = true
        DatabaseListStore.testUpsert(updatedFirst)

        var updatedSecond = second
        updatedSecond.isQuickLaunch = true
        DatabaseListStore.testUpsert(updatedSecond)

        let storedReferences = DatabaseListStore.databases
        XCTAssertTrue(storedReferences.first(where: { $0.id == first.id })?.isQuickLaunch ?? false)
        XCTAssertFalse(storedReferences.first(where: { $0.id == second.id })?.isQuickLaunch ?? true)
        XCTAssertEqual(DatabaseListStore.quickLaunchDatabase?.id, first.id)
    }

    func testRemoveDeletesCachedCopy() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "remove-me.kdbx"))
        try DatabaseListStore.cacheDatabaseCopy(Data(contentsOf: XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: reference))), for: reference.id)
        XCTAssertNotNil(DatabaseListStore.cachedDatabaseURL(for: reference.id))

        DatabaseListStore.remove(id: reference.id)

        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testAddCloudPersistsMetadataAndCachesUsingScopedCloudPath() throws {
        let file = CloudFile(
            id: "/Vaults/personal.kdbx",
            name: "personal.kdbx",
            path: "/Vaults/personal.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 123),
            size: 42
        )

        let reference = try! DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        let metadata = try XCTUnwrap(storedReference.cloudSyncMetadata)

        XCTAssertEqual(storedReference.id, reference.id)
        XCTAssertEqual(metadata.provider, CloudProviderKind.dropbox.rawValue)
        XCTAssertEqual(metadata.accountId, "acct-1")
        XCTAssertEqual(metadata.fileId, file.id)
        XCTAssertEqual(metadata.displayPath, file.path)
        XCTAssertEqual(metadata.remoteModifiedAt, file.modifiedDate)

        let cachedData = Data("cloud-cache".utf8)
        try DatabaseListStore.cacheDatabaseCopy(cachedData, for: reference)

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        XCTAssertTrue(cachedURL.path.contains("/cloud-cache/dropbox-acct-1/"))
        XCTAssertEqual(cachedURL.pathExtension, "kdbx")
        XCTAssertNotEqual(cachedURL.lastPathComponent, file.name)
        XCTAssertEqual(try Data(contentsOf: cachedURL), cachedData)
    }

    func testSetCloudSyncPolicyPersistsWithoutTouchingOtherFields() throws {
        var reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        reference.nickname = "Stored Name"
        DatabaseListStore.testUpsert(reference)

        // A stale copy (no nickname) must not carry its other fields back.
        var staleCopy = reference
        staleCopy.nickname = nil
        DatabaseListStore.setCloudSyncPolicy(.manual, for: staleCopy)

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stored.cloudSyncPolicy, .manual)
        XCTAssertEqual(stored.nickname, "Stored Name")
        XCTAssertEqual(stored.cloudSyncMetadata, reference.cloudSyncMetadata)

        DatabaseListStore.setCloudSyncPolicy(.onOpen, for: reference)
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == reference.id })?.cloudSyncPolicy, .onOpen)
    }

    // MARK: - Cloud sync metadata merge (M13)

    func testUpdateCloudSyncMetadataMergesSyncFieldsWithoutTouchingOtherFields() throws {
        var reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        let observedReference = reference
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        // A rename lands while the refresh is out on the network. The refresh
        // must not carry the pre-rename nickname back over it.
        reference.nickname = "Renamed While Syncing"
        DatabaseListStore.testUpsert(reference)

        let merged = DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed,
            observedReference: observedReference
        ) { metadata in
            metadata.remoteRev = "rev-B"
            metadata.remoteContentHash = "hash-B"
            metadata.lastSyncIssue = nil
        }

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(merged?.id, reference.id)
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteRev, "rev-B")
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteContentHash, "hash-B")
        XCTAssertEqual(stored.nickname, "Renamed While Syncing")
    }

    func testUpdateCloudSyncMetadataSkipsWhenStoredRevisionMovedOnUnderneath() throws {
        var reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        let observedReference = reference
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        // A save (or a pending-upload drain) completes while the refresh is in
        // flight, advancing the revision past what the refresh ever saw.
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-B"
            metadata.remoteContentHash = "hash-B"
        }
        DatabaseListStore.testUpsert(reference)

        let merged = DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed,
            observedReference: observedReference
        ) { metadata in
            metadata.remoteRev = "rev-A"
            metadata.remoteContentHash = "hash-A"
        }

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(
            stored.cloudSyncMetadata?.remoteRev,
            "rev-B",
            "The stale refresh must not roll the saved revision back."
        )
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteContentHash, "hash-B")
        XCTAssertEqual(
            merged?.cloudSyncMetadata?.remoteRev,
            "rev-B",
            "The caller is handed the newer stored state so it can adopt it."
        )
    }

    /// References predating rev tracking carry only a content hash, so the
    /// hash alone has to be able to block a stale merge.
    func testUpdateCloudSyncMetadataSkipsWhenOnlyContentHashMovedOn() throws {
        var reference = makeStoredCloudReference(remoteRev: nil, remoteContentHash: "hash-A")
        let observedReference = reference
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteContentHash = "hash-B"
        }
        DatabaseListStore.testUpsert(reference)

        DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed,
            observedReference: observedReference
        ) { metadata in
            metadata.remoteContentHash = "hash-A"
        }

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteContentHash, "hash-B")
    }

    func testUpdateCloudSyncMetadataReturnsNilForUnknownDatabase() {
        let reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        let observed = reference.cloudSyncMetadata

        DatabaseListStore.remove(id: reference.id)

        let merged = observed.flatMap { observed in
            DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed, observedReference: reference) { metadata in
                metadata.remoteRev = "rev-B"
            }
        }

        XCTAssertNil(merged)
    }

    private func makeStoredCloudReference(
        remoteRev: String?,
        remoteContentHash: String?
    ) -> DatabaseReference {
        var reference = try! DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: CloudFile(
                id: "/Vaults/merge.kdbx",
                name: "merge.kdbx",
                path: "/Vaults/merge.kdbx",
                isFolder: false,
                modifiedDate: Date(timeIntervalSince1970: 100),
                size: 42
            )
        )
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = remoteRev
            metadata.remoteContentHash = remoteContentHash
        }
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    func testAddCloudReturnsExistingReferenceForSameRemoteFile() {
        let file = CloudFile(
            id: "/Vaults/work.kdbx",
            name: "work.kdbx",
            path: "/Vaults/work.kdbx",
            isFolder: false,
            modifiedDate: nil,
            size: nil
        )

        let first = try! DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        let second = try! DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
    }

    func testRemoveDeletesCloudCachedCopy() throws {
        let file = CloudFile(
            id: "/Vaults/remove-me.kdbx",
            name: "remove-me.kdbx",
            path: "/Vaults/remove-me.kdbx",
            isFolder: false,
            modifiedDate: nil,
            size: nil
        )
        let reference = try! DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )

        try DatabaseListStore.cacheDatabaseCopy(Data("cached-cloud".utf8), for: reference)
        XCTAssertNotNil(DatabaseListStore.cachedDatabaseURL(for: reference))

        DatabaseListStore.remove(id: reference.id)

        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: reference))
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testRemoveUnconfirmedCloudUploadKeepsPayloadAndBlocksReaddingItsTarget() async throws {
        let file = CloudFile(id: "uncertain-removal", name: "pending.kdbx", path: "pending.kdbx",
            isFolder: false, modifiedDate: nil, size: nil)
        let provider = CloudProviderKind.webDAV.rawValue
        let reference = try DatabaseListStore.addCloud(provider: provider, accountId: "one", file: file)
        let context = try CloudJournalTestContext(reference: reference)
        var attempt = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        attempt.marker.uploadAttemptID = UUID()
        attempt = try PendingUploadQueue.update(attempt)
        let current = try XCTUnwrap(DatabaseListStore.readDatabasesStrict().first)

        XCTAssertEqual(DatabaseListStore.remove(observed: current), .cloudRecoveryRequired(canKeepRecoveryCopies: true))
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [current.id])
        XCTAssertEqual(DatabaseListStore.remove(observed: current, keepingUnconfirmedCloudUploads: true), .removed)

        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: current))
        let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: current.id).first)
        XCTAssertEqual(retained.marker.detachedFilename, "pending.kdbx")
        XCTAssertEqual(retained.marker.uploadAttemptID, attempt.marker.uploadAttemptID)
        XCTAssertEqual(CloudJournalDecision.state(of: retained.marker), .attempting)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), context.payload)

        let transport = CloudJournalTransport()
        let drainer = PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport)))
        let drain = await drainer.drainAll()
        XCTAssertEqual(drain.skippedDatabaseIDs, [current.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertThrowsError(try DatabaseListStore.addCloud(provider: provider, accountId: "one", file: file)) {
            XCTAssertEqual($0 as? DatabaseListStore.AddDatabaseError, .unresolvedCloudUpload)
        }
        XCTAssertThrowsError(try DatabaseListStore.validateCreatedCloud(
            provider: provider, accountId: "one", fileId: file.id, filename: file.name
        )) {
            XCTAssertEqual($0 as? DatabaseListStore.AddDatabaseError, .unresolvedCloudUpload)
        }
        let other = CloudFile(id: "different-file", name: file.name, path: file.path,
            isFolder: false, modifiedDate: nil, size: nil)
        XCTAssertNoThrow(try DatabaseListStore.addCloud(provider: provider, accountId: "one", file: other))
    }

    func testDetachedDriveUploadBlocksTheSameFileFromAnotherAccount() throws {
        let file = CloudFile(id: "shared-drive-file-id", name: "pending.kdbx", path: "pending.kdbx",
            isFolder: false, modifiedDate: nil, size: nil)
        let provider = CloudProviderKind.googleDrive.rawValue
        let reference = try DatabaseListStore.addCloud(provider: provider, accountId: "one", file: file)
        _ = try CloudJournalTestContext(reference: reference)
        var attempt = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        attempt.marker.uploadAttemptID = UUID()
        _ = try PendingUploadQueue.update(attempt)
        let current = try XCTUnwrap(DatabaseListStore.readDatabasesStrict().first)
        XCTAssertEqual(DatabaseListStore.remove(observed: current, keepingUnconfirmedCloudUploads: true), .removed)

        XCTAssertThrowsError(try DatabaseListStore.addCloud(provider: provider, accountId: "two", file: file)) {
            XCTAssertEqual($0 as? DatabaseListStore.AddDatabaseError, .unresolvedCloudUpload)
        }
    }

    func testRemovalDuringCloudUploadPreservesItsAcknowledgement() async throws {
        let file = CloudFile(id: "live-removal", name: "pending.kdbx", path: "pending.kdbx",
            isFolder: false, modifiedDate: nil, size: nil)
        let reference = try DatabaseListStore.addCloud(provider: CloudProviderKind.webDAV.rawValue,
            accountId: "one", file: file)
        let context = try CloudJournalTestContext(reference: reference)
        let transport = CloudJournalTransport(beforeUpload: {
            let current = try XCTUnwrap(DatabaseListStore.readDatabasesStrict().first)
            XCTAssertEqual(DatabaseListStore.remove(observed: current, keepingUnconfirmedCloudUploads: true), .notPublished)
            let attempt = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertNil(attempt.marker.detachedFilename)
        })

        let result = try await CloudDatabaseSaver.deliver(context.stored, reference: reference,
            environment: context.environment(transport: transport))
        guard case .saved(let updated)? = result else { return XCTFail("Expected the upload acknowledgement to publish") }
        XCTAssertEqual(updated.cloudSyncMetadata?.remoteRev, transport.response.rev)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
        XCTAssertEqual(DatabaseListStore.remove(observed: updated), .removed)
    }

    func testRemoveUnconfirmedCloudUploadRefusesAnUnverifiedRecoveryCopy() throws {
        let file = CloudFile(id: "invalid-removal", name: "pending.kdbx", path: "pending.kdbx",
            isFolder: false, modifiedDate: nil, size: nil)
        let reference = try DatabaseListStore.addCloud(provider: CloudProviderKind.webDAV.rawValue, accountId: "one", file: file)
        let context = try CloudJournalTestContext(reference: reference)
        var attempt = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        attempt.marker.uploadAttemptID = UUID()
        _ = try PendingUploadQueue.update(attempt)
        try Data("different bytes".utf8).write(to: context.payloadURL)
        let current = try XCTUnwrap(DatabaseListStore.readDatabasesStrict().first)

        XCTAssertEqual(DatabaseListStore.remove(observed: current, keepingUnconfirmedCloudUploads: true),
            .cloudRecoveryRequired(canKeepRecoveryCopies: false))
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [current.id])
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
    }

    func testRemoveActiveDatabaseTriggersTargetedRemovalIncludingLegacy() async throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "other.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = first.id

        // Since slice 04, removal never wipes the whole store — it removes
        // exactly the removed database's identities, sweeping legacy
        // bare-UUID identifiers only when the removed database was active.
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Removal must use targeted identity removal, never a whole-store clear")
        }

        let removalExpectation = expectation(description: "Targeted identity removal for the removed database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, first.id)
            XCTAssertTrue(
                includingLegacyIdentifiers,
                "Removing the active database must sweep legacy bare-UUID identifiers"
            )
            removalExpectation.fulfill()
        }

        DatabaseListStore.remove(id: first.id)

        await fulfillment(of: [removalExpectation], timeout: 1)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func testRemovingNonActiveDatabaseTriggersTargetedIdentityRemoval() async throws {
        let active = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "kept.kdbx"))
        let removed = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "dropped.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = active.id

        // Pre-slice-04 "removal gap": removing a non-active database left its
        // published identities behind. Every removal now targeted-removes.
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Removing a non-active database must never clear the whole store")
        }

        let removalExpectation = expectation(description: "Targeted identity removal for the removed database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, removed.id)
            XCTAssertFalse(includingLegacyIdentifiers)
            removalExpectation.fulfill()
        }

        DatabaseListStore.remove(id: removed.id)

        await fulfillment(of: [removalExpectation], timeout: 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, active.id)
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [active.id])
    }

    func testRemovalWorksWithEverythingLocked() async throws {
        // Both references have only ever been added — never unlocked, so no
        // composite key and no KPEntry exists anywhere. Targeted removal must
        // work purely by store enumeration.
        let removed = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "locked-removed.kdbx"))
        let surviving = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "locked-surviving.kdbx"))

        let removedIdentifiers = [
            CredentialRecordIdentifier(databaseID: removed.id, entryID: UUID()).encoded,
            CredentialRecordIdentifier(databaseID: removed.id, entryID: UUID()).encoded,
        ]
        let survivingIdentifier = CredentialRecordIdentifier(databaseID: surviving.id, entryID: UUID()).encoded
        let legacyIdentifier = UUID().uuidString

        let fake = FakeCredentialIdentityStore()
        fake.stored = (removedIdentifiers + [survivingIdentifier, legacyIdentifier]).map { recordIdentifier in
            ASPasswordCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: "example.com", type: .domain),
                user: "user",
                recordIdentifier: recordIdentifier
            )
        }
        let mutationExpectation = expectation(description: "Targeted removal mutates the fake store")
        fake.onMutation = { mutationExpectation.fulfill() }
        CredentialIdentityStoreManager.storeProviderOverride = fake

        DatabaseListStore.remove(id: removed.id)

        await fulfillment(of: [mutationExpectation], timeout: 1)
        fake.onMutation = nil

        // Exactly the removed database's subset goes; the other database's
        // identity survives, and so does the legacy bare-UUID one (the
        // removed database was not the active AutoFill database).
        XCTAssertEqual(fake.calls, ["removeCredentialIdentities"])
        XCTAssertEqual(
            Set(fake.stored.compactMap(\.recordIdentifier)),
            [survivingIdentifier, legacyIdentifier]
        )
    }

    func testSetAutoFillEnabledPersistsAcrossReload() throws {
        let disabled = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "disabled.kdbx"))
        let enabled = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "enabled.kdbx"))

        DatabaseListStore.setAutoFillEnabled(false, for: disabled)

        // `databases` re-decodes database-list.json on every access, so this
        // is also the background→foreground reload guarantee.
        let storedReferences = DatabaseListStore.databases
        XCTAssertEqual(storedReferences.first(where: { $0.id == disabled.id })?.autoFillEnabled, false)
        XCTAssertEqual(storedReferences.first(where: { $0.id == enabled.id })?.autoFillEnabled, true)
        XCTAssertEqual(DatabaseListStore.autoFillEnabledDatabases.map(\.id), [enabled.id])
    }

    func testSetAutoFillDestinationGroupIDPersistsForThatDatabaseOnly() throws {
        let configured = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "configured.kdbx"))
        let other = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "other.kdbx"))
        let groupID = UUID()

        DatabaseListStore.setAutoFillDestinationGroupID(groupID, for: configured)

        let storedReferences = DatabaseListStore.databases
        XCTAssertEqual(storedReferences.first(where: { $0.id == configured.id })?.autoFillDestinationGroupID, groupID)
        XCTAssertNil(storedReferences.first(where: { $0.id == other.id })?.autoFillDestinationGroupID)
    }

    func testActiveAutoFillDatabaseIDSetterRefusesDisabledDatabase() throws {
        let enabled = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "enabled.kdbx"))
        let disabled = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "disabled.kdbx"),
            autoFillEnabled: false
        )
        DatabaseListStore.testUpsert(disabled)
        DatabaseListStore.activeAutoFillDatabaseID = enabled.id

        DatabaseListStore.activeAutoFillDatabaseID = disabled.id

        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, enabled.id)
    }

    func testActiveAutoFillDatabaseIDSetterAllowsUnknownID() throws {
        // References that have not been saved to the registry yet (e.g. the
        // AutoFill extension's save flow before first persist) must be able
        // to claim the pointer.
        let registered = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "registered.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = registered.id
        let unknownID = UUID()

        DatabaseListStore.activeAutoFillDatabaseID = unknownID

        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, unknownID)
    }

    func testMarkDatabaseOpenedOnDisabledDatabaseKeepsPreviousActivePointer() throws {
        let active = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: active.id)
        let disabled = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "disabled.kdbx"),
            autoFillEnabled: false
        )
        DatabaseListStore.testUpsert(disabled)
        let openedDate = Date(timeIntervalSince1970: 2_000)

        DatabaseListStore.markDatabaseOpened(id: disabled.id, at: openedDate)

        let storedDisabled = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == disabled.id }))
        XCTAssertEqual(storedDisabled.lastOpenedAt, openedDate)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, active.id)
    }

    func testDisablingActiveDatabaseTargetedRemovesAndReassignsPointer() async throws {
        let older = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "older.kdbx"))
        let newer = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "newer.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: older.id, at: Date(timeIntervalSince1970: 1_000))
        DatabaseListStore.markDatabaseOpened(id: newer.id, at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, newer.id)

        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Disabling must use targeted identity removal, never a whole-store clear")
        }

        let removalExpectation = expectation(description: "Targeted identity removal for the disabled database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, newer.id)
            XCTAssertTrue(
                includingLegacyIdentifiers,
                "Disabling the active database must sweep legacy bare-UUID identifiers"
            )
            removalExpectation.fulfill()
        }

        DatabaseListStore.setAutoFillEnabled(false, for: newer)

        await fulfillment(of: [removalExpectation], timeout: 1)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, older.id)
    }

    func testDisablingActiveDatabaseWithNoOtherOpenedEnabledDatabaseClearsPointer() async throws {
        let active = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "never-opened.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: active.id)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, active.id)

        let removalExpectation = expectation(description: "Targeted identity removal for the disabled database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, active.id)
            XCTAssertTrue(includingLegacyIdentifiers)
            removalExpectation.fulfill()
        }

        DatabaseListStore.setAutoFillEnabled(false, for: active)

        await fulfillment(of: [removalExpectation], timeout: 1)
        // The only other database has never been opened, so no reassignment
        // target exists.
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func testDisablingInactiveDatabaseRemovesOnlyItsIdentitiesAndKeepsPointer() async throws {
        let active = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        let inactive = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "inactive.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: active.id)

        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Disabling a non-active database must not clear the whole store")
        }

        let removalExpectation = expectation(description: "Targeted identity removal for the inactive database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, inactive.id)
            XCTAssertFalse(
                includingLegacyIdentifiers,
                "Disabling a non-active database must not sweep legacy identifiers"
            )
            removalExpectation.fulfill()
        }

        DatabaseListStore.setAutoFillEnabled(false, for: inactive)

        await fulfillment(of: [removalExpectation], timeout: 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, active.id)
    }

    func testEnablingDisabledDatabaseDoesNotPopulateOrClaimPointer() async throws {
        let active = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        let disabled = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "disabled.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: active.id)

        // Let the disable's own observer task settle before installing the
        // XCTFail observers below, or it would fire into them.
        let disableExpectation = expectation(description: "Disable consequences settle")
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in disableExpectation.fulfill() }
        DatabaseListStore.setAutoFillEnabled(false, for: disabled)
        await fulfillment(of: [disableExpectation], timeout: 1)

        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("Enabling is lazy; identities appear on the database's next unlock")
        }
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Enabling must not clear the identity store")
        }
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in
            XCTFail("Enabling must not trigger targeted identity removal")
        }

        XCTAssertEqual(DatabaseListStore.setAutoFillEnabled(true, for: disabled), .rejected)
        let currentDisabled = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == disabled.id })
        XCTAssertEqual(DatabaseListStore.setAutoFillEnabled(true, for: currentDisabled), .saved)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == disabled.id })?.autoFillEnabled, true)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, active.id)
    }

    func testFallbackAutoFillDatabaseSkipsDisabledLegacyDatabase() throws {
        let reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "legacy.kdbx"),
            legacyKeychainFilename: "legacy.kdbx",
            autoFillEnabled: false
        )
        DatabaseListStore.testUpsert(reference)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)

        XCTAssertNil(DatabaseListStore.activeAutoFillDatabase)

        // Control: the same reference is served by the legacy fallback once
        // enabled, so the nil above comes from the flag gate.
        DatabaseListStore.setAutoFillEnabled(true, for: reference)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabase?.id, reference.id)
    }

    func testSaveSweepClearsPointerWhenFlagFlippedViaGenericUpdate() async throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "bypass.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: reference.id)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)

        // Flipping the flag through the generic `update(_:)` bypasses
        // `setAutoFillEnabled`'s consequences: the save sweep must still
        // clear the now-invalid pointer, but no identity-store cleanup runs —
        // `setAutoFillEnabled` is the designated API for that.
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Generic update must not clear the identity store")
        }
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in
            XCTFail("Generic update must not trigger targeted identity removal")
        }

        var updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        updatedReference.autoFillEnabled = false
        DatabaseListStore.testUpsert(updatedReference)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == reference.id })?.autoFillEnabled, false)
    }

    func testSetAutoFillEnabledOnLockedDatabaseNeedsNoUnlock() async throws {
        // `locked` has only ever been added — never opened or unlocked, so no
        // composite key exists and `lastOpenedAt` is nil. Flag flips are
        // registry-only: disabling it needs no unlock and still runs the full
        // active-pointer consequences.
        let locked = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "locked.kdbx"))
        let opened = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "opened.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: opened.id, at: Date(timeIntervalSince1970: 1_000))
        DatabaseListStore.activeAutoFillDatabaseID = locked.id

        let removalExpectation = expectation(description: "Targeted identity removal for the locked database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, locked.id)
            XCTAssertTrue(includingLegacyIdentifiers)
            removalExpectation.fulfill()
        }

        DatabaseListStore.setAutoFillEnabled(false, for: locked)

        await fulfillment(of: [removalExpectation], timeout: 1)
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == locked.id })?.autoFillEnabled, false)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, opened.id)
    }

    func testDefaultAutoFillDatabaseReturnsEnabledPointerReference() throws {
        let pointed = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "pointed.kdbx"))
        let recent = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "recent.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: pointed.id, at: Date(timeIntervalSince1970: 1_000))
        DatabaseListStore.markDatabaseOpened(id: recent.id, at: Date(timeIntervalSince1970: 2_000))
        DatabaseListStore.activeAutoFillDatabaseID = pointed.id

        // The pointer wins over recency.
        XCTAssertEqual(DatabaseListStore.defaultAutoFillDatabase?.id, pointed.id)
    }

    func testDefaultAutoFillDatabasePrefersLegacyFallbackOverMostRecentlyOpened() throws {
        let legacyReference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "legacy.kdbx"),
            legacyKeychainFilename: "legacy.kdbx"
        )
        DatabaseListStore.testUpsert(legacyReference)
        let opened = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "opened.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: opened.id, at: Date(timeIntervalSince1970: 2_000))
        DatabaseListStore.activeAutoFillDatabaseID = nil

        // The whole `activeAutoFillDatabase` chain — including its legacy
        // keychain-filename fallback — takes precedence; recency is only the
        // final fallback.
        XCTAssertEqual(DatabaseListStore.defaultAutoFillDatabase?.id, legacyReference.id)
    }

    func testDefaultAutoFillDatabaseFallsBackToMostRecentlyOpenedEnabled() throws {
        let older = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "older.kdbx"))
        let newer = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "newer.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: older.id, at: Date(timeIntervalSince1970: 1_000))
        DatabaseListStore.markDatabaseOpened(id: newer.id, at: Date(timeIntervalSince1970: 2_000))
        DatabaseListStore.activeAutoFillDatabaseID = nil

        XCTAssertEqual(DatabaseListStore.defaultAutoFillDatabase?.id, newer.id)

        DatabaseListStore.setAutoFillEnabled(false, for: newer)

        XCTAssertEqual(DatabaseListStore.defaultAutoFillDatabase?.id, older.id)
    }

    func testDefaultAutoFillDatabaseIgnoresNeverOpenedReferences() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "never-opened.kdbx"))
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)

        XCTAssertNil(DatabaseListStore.defaultAutoFillDatabase)
    }

    func testDefaultAutoFillDatabaseNilWithZeroEnabledDatabases() throws {
        XCTAssertNil(DatabaseListStore.defaultAutoFillDatabase)

        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "disabled.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: reference.id)
        DatabaseListStore.setAutoFillEnabled(false, for: reference)

        XCTAssertNil(DatabaseListStore.defaultAutoFillDatabase)
    }

    func testLocateDatabaseFileReturnsAvailableForRegularFile() throws {
        let url = try makeTemporaryFileURL(name: "regular.kdbx")
        let reference = try DatabaseListStore.add(url: url)

        let location = try XCTUnwrap(DatabaseListStore.locateDatabaseFile(for: reference))

        guard case .available(let resolvedURL) = location else {
            XCTFail("Expected .available, got \(location)")
            return
        }
        XCTAssertEqualFilePaths(resolvedURL, url)
        XCTAssertEqualFilePaths(DatabaseListStore.resolveDatabaseURL(for: reference), url)
    }

    func testLocateDatabaseFileReportsTrashedFile() throws {
        let trashedURL = try makeTemporaryFileURL(name: ".Trash/personal.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: trashedURL)

        let location = try XCTUnwrap(DatabaseListStore.locateDatabaseFile(for: reference))

        guard case .inTrash(let resolvedURL) = location else {
            XCTFail("Expected .inTrash, got \(location)")
            return
        }
        XCTAssertTrue(resolvedURL.pathComponents.contains(".Trash"))
        XCTAssertNil(DatabaseListStore.resolveDatabaseURL(for: reference))
    }

    func testLocateDatabaseFileFollowsMoveIntoTrashAndDoesNotRefreshBookmark() throws {
        // Mirrors deleting the database in the Files app: the bookmarked file
        // keeps its identity and moves into ".Trash". Resolution follows the
        // identity there; the result must be classified as trashed instead of
        // silently serving the stale copy, and the (now stale) bookmark must
        // not be re-minted against the trashed location — restoring the file
        // in Files keeps the original bookmark valid.
        //
        // (The Files-app "Replace" flow — a new file taking over the original
        // path — cannot be reproduced on a plain filesystem: without a file
        // provider in the middle, resolution rebinds to the path. On device
        // the bookmark keeps following the old provider item into the trash,
        // which is this same classification path.)
        let originalURL = try makeTemporaryFileURL(name: "deleted.kdbx", contents: Data("old contents".utf8))
        let reference = try DatabaseListStore.add(url: originalURL)

        let fileManager = FileManager.default
        let trashDirectoryURL = originalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Trash", isDirectory: true)
        try fileManager.createDirectory(at: trashDirectoryURL, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: originalURL,
            to: trashDirectoryURL.appendingPathComponent("deleted.kdbx")
        )

        let location = try XCTUnwrap(DatabaseListStore.locateDatabaseFile(for: reference))

        guard case .inTrash(let resolvedURL) = location else {
            XCTFail("Expected .inTrash, got \(location)")
            return
        }
        XCTAssertTrue(resolvedURL.pathComponents.contains(".Trash"))
        XCTAssertNil(DatabaseListStore.resolveDatabaseURL(for: reference))

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(storedReference.bookmarkData, reference.bookmarkData)
    }

    func testConcurrentUpdatesDoNotLoseWrites() async throws {
        // Detached cloud-upload tasks call `update(_:)` off the main actor while
        // main-actor writers mutate the same `database-list.json`. Each
        // mutator's load-modify-save must run atomically, or concurrent updates
        // clobber one another's changes with a stale snapshot.
        let referenceCount = 32
        let references: [DatabaseReference] = (0..<referenceCount).map { index in
            try! DatabaseListStore.addCloud(
                provider: CloudProviderKind.dropbox.rawValue,
                accountId: "acct-1",
                file: CloudFile(
                    id: "/Vaults/concurrent-\(index).kdbx",
                    name: "concurrent-\(index).kdbx",
                    path: "/Vaults/concurrent-\(index).kdbx",
                    isFolder: false,
                    modifiedDate: nil,
                    size: nil
                )
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for reference in references {
                group.addTask {
                    var mutated = reference
                    mutated.nickname = "nick-\(reference.id.uuidString)"
                    DatabaseListStore.testUpsert(mutated)
                }
            }
        }

        let stored = DatabaseListStore.databases
        XCTAssertEqual(stored.count, referenceCount)
        for reference in references {
            let match = stored.first(where: { $0.id == reference.id })
            XCTAssertEqual(match?.nickname, "nick-\(reference.id.uuidString)")
        }
    }

    // MARK: - Documents-resident rebinding

    func testNoRenewResolutionKeepsRegistryCacheAndOwnerUntouchedForBrokenTrashAndMovedBookmarks() throws {
        for mode in ["broken", "trash", "moved"] {
            let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            DatabaseListStore.documentsDirectoryOverride = documents
            defer {
                DatabaseListStore.documentsDirectoryOverride = nil
                try? FileManager.default.removeItem(at: documents)
            }
            let originalURL = documents.appendingPathComponent("resident.kdbx")
            let original = Self.kdbxMagic + Data("original".utf8)
            let replacement = Self.kdbxMagic + Data("replacement".utf8)
            try original.write(to: originalURL)
            var reference = try TestDatabaseSupport.makeReference(for: originalURL)
            reference.isDocumentsResident = true
            let observedURL: URL
            if mode == "trash" {
                let trash = documents.appendingPathComponent(".Trash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                observedURL = trash.appendingPathComponent("resident.kdbx")
                try FileManager.default.moveItem(at: originalURL, to: observedURL)
                try replacement.write(to: originalURL)
                reference.bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: observedURL)
            } else if mode == "moved" {
                observedURL = documents.appendingPathComponent("moved.kdbx")
                try FileManager.default.moveItem(at: originalURL, to: observedURL)
            } else {
                observedURL = originalURL
                reference.bookmarkData = Data("broken-bookmark".utf8)
            }
            DatabaseListStore.testUpsert(reference)
            let cache = DatabaseListStore.cacheLocation(for: reference)
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            let oldCache = Data("unchanged encrypted-cache fixture".utf8)
            try oldCache.write(to: cache, options: .atomicProtected)
            let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
            let owner = AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(reference.id.uuidString)")
            let registryBefore = try Data(contentsOf: registry)
            func ownerSnapshot() throws -> [String: Data]? {
                guard FileManager.default.fileExists(atPath: owner.path) else { return nil }
                return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil)
                    .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            }
            let ownerBefore = try ownerSnapshot()
            var receipt: DatabaseListStore.DatabaseBookmarkRenewal?
            let resolver: (Data) -> (url: URL, isStale: Bool)? = { _ in
                mode == "broken" ? nil : (observedURL, true)
            }
            let result = DatabaseListStore.locateDatabaseFile(for: reference, resolveBookmark: resolver,
                renewBookmark: false, onBookmarkRenewal: { receipt = $0 })
            switch mode {
            case "broken": XCTAssertNil(result)
            case "trash":
                guard case .inTrash(let url)? = result else { XCTFail("Known Trash must not become missing or trigger heal"); continue }
                XCTAssertEqualFilePaths(url, observedURL)
            default:
                guard case .available(let url)? = result else { XCTFail("A resolvable moved target remains readable"); continue }
                XCTAssertEqualFilePaths(url, observedURL)
            }
            XCTAssertNil(receipt)
            XCTAssertEqual(try Data(contentsOf: registry), registryBefore)
            XCTAssertEqual(try Data(contentsOf: cache), oldCache)
            XCTAssertEqual(try ownerSnapshot(), ownerBefore,
                           "No-renew resolution must not change owner locks or records")
            XCTAssertEqual(try Data(contentsOf: observedURL), original)
            if mode == "trash" { XCTAssertEqual(try Data(contentsOf: originalURL), replacement) }

            let normal = DatabaseListStore.locateDatabaseFile(for: reference, resolveBookmark: resolver,
                onBookmarkRenewal: { receipt = $0 })
            guard case .available(let url)? = normal else { XCTFail("The normal path retains supported resolution/heal"); continue }
            let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
            XCTAssertEqual(stored.id, reference.id)
            XCTAssertEqual(stored.lastMasterKeyChangeAt, reference.lastMasterKeyChangeAt)
            XCTAssertEqual(stored.keyFileBookmarkData, reference.keyFileBookmarkData)
            if mode == "moved" {
                XCTAssertEqualFilePaths(url, observedURL)
                XCTAssertNotNil(receipt, "Only the real durable renewal CAS provides a receipt")
                XCTAssertEqual(try Data(contentsOf: cache), oldCache)
            } else {
                XCTAssertEqualFilePaths(url, originalURL)
                XCTAssertNil(receipt, "Shipped heal does not claim a durable renewal receipt")
                XCTAssertNotEqual(stored.bookmarkData, reference.bookmarkData)
                XCTAssertEqual(try Data(contentsOf: cache), mode == "trash" ? replacement : original)
            }
        }
    }

    func testLocateDatabaseFileRebindsDocumentsResidentReferenceWithBrokenBookmark() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        let contents = Self.kdbxMagic + Data("fixture".utf8)
        try contents.write(to: fileURL)
        var reference = try DatabaseListStore.add(url: fileURL)
        XCTAssertTrue(reference.isDocumentsResident)

        reference.bookmarkData = Data("stale-bookmark".utf8)
        DatabaseListStore.testUpsert(reference)
        // Stale the cache so the heal's reseed is observable.
        try writeAtomicallyAndDurably(Data("stale-cache".utf8), to: DatabaseListStore.cacheLocation(for: reference), directoryAnchor: AppGroupContainer.url)

        let location = DatabaseListStore.locateDatabaseFile(for: reference)
        guard case .available(let url) = location else {
            XCTFail("Expected .available, got \(String(describing: location))")
            return
        }
        XCTAssertEqual(url.lastPathComponent, "resident.kdbx")
        XCTAssertEqual(try Data(contentsOf: url), contents)

        // The rebind persisted a fresh, resolvable bookmark on the same id
        // and reseeded the AutoFill shared cache with the file's bytes.
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertNotEqual(stored.bookmarkData, Data("stale-bookmark".utf8))
        XCTAssertNotNil(DatabaseListStore.resolveDatabaseURL(for: stored))
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: cachedURL), contents)
    }

    func testLocateDatabaseFileDoesNotRebindToFileWithoutKDBXMagic() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try (Self.kdbxMagic + Data("fixture".utf8)).write(to: fileURL)
        var reference = try DatabaseListStore.add(url: fileURL)

        reference.bookmarkData = Data("stale-bookmark".utf8)
        DatabaseListStore.testUpsert(reference)
        // A garbage (or mid-copy) file at the path must never be bound.
        try Data("not a database".utf8).write(to: fileURL)

        XCTAssertNil(DatabaseListStore.locateDatabaseFile(for: reference))
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stored.bookmarkData, Data("stale-bookmark".utf8))
    }

    func testLocateDatabaseFileRebindsDocumentsResidentReferenceResolvedIntoTrash() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try (Self.kdbxMagic + Data("original".utf8)).write(to: fileURL)
        var reference = try DatabaseListStore.add(url: fileURL)
        XCTAssertTrue(reference.isDocumentsResident)

        let trashDirectory = documentsDirectory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let trashedURL = trashDirectory.appendingPathComponent("resident.kdbx")
        try FileManager.default.moveItem(at: fileURL, to: trashedURL)
        let replacement = Self.kdbxMagic + Data("replacement".utf8)
        try replacement.write(to: fileURL)
        reference.bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: trashedURL)
        DatabaseListStore.testUpsert(reference)
        let resolvedBeforeLocate = try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: try XCTUnwrap(reference.bookmarkData)))
        XCTAssertEqualFilePaths(resolvedBeforeLocate.url, trashedURL)

        let location = DatabaseListStore.locateDatabaseFile(for: reference)
        guard case .available(let url) = location else {
            XCTFail("Expected .available, got \(String(describing: location))")
            return
        }
        XCTAssertFalse(url.pathComponents.contains(".Trash"))
        XCTAssertEqual(try Data(contentsOf: url), replacement)

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        let reresolvedURL = try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: stored))
        XCTAssertEqual(try Data(contentsOf: reresolvedURL), replacement)
    }

    func testLocateDatabaseFileKeepsInTrashWhenReplacementLacksKDBXMagic() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try (Self.kdbxMagic + Data("original".utf8)).write(to: fileURL)
        var reference = try DatabaseListStore.add(url: fileURL)

        let trashDirectory = documentsDirectory.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let trashedURL = trashDirectory.appendingPathComponent("resident.kdbx")
        try FileManager.default.moveItem(at: fileURL, to: trashedURL)
        try Data("not a database".utf8).write(to: fileURL)
        // Pin the trash-resolved branch: a real post-move resolution may
        // follow either the moved inode or the path, so aim the bookmark at
        // the trashed copy explicitly.
        reference.bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: trashedURL)
        DatabaseListStore.testUpsert(reference)

        // The magic-less file at the path must not be bound; the trashed
        // classification (and the stored bookmark) stay exactly as they were.
        let storedBefore = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        let location = DatabaseListStore.locateDatabaseFile(for: storedBefore)
        guard case .inTrash(let url) = location else {
            XCTFail("Expected .inTrash, got \(String(describing: location))")
            return
        }
        XCTAssertTrue(url.pathComponents.contains(".Trash"))
        let storedAfter = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(storedAfter.bookmarkData, storedBefore.bookmarkData)
    }

    func testAddDoesNotClassifyNestedDocumentsFileAsDocumentsResident() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedDirectory = documentsDirectory.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let nestedURL = nestedDirectory.appendingPathComponent("vault.kdbx")
        try Data("fixture".utf8).write(to: nestedURL)

        // Rebind identity is exactly `Documents/<filename>`, so only direct
        // children may carry the flag; a nested reference must never be able
        // to steal a same-name top-level file.
        let reference = try DatabaseListStore.add(url: nestedURL)
        XCTAssertFalse(reference.isDocumentsResident)
    }

    func testLocateDatabaseFileReturnsNilForNonDocumentsReferenceWithBrokenBookmark() throws {
        let fileURL = try makeTemporaryFileURL(name: "outside.kdbx")
        var reference = try DatabaseListStore.add(url: fileURL)
        XCTAssertFalse(reference.isDocumentsResident)

        reference.bookmarkData = Data("stale-bookmark".utf8)
        DatabaseListStore.testUpsert(reference)

        XCTAssertNil(DatabaseListStore.locateDatabaseFile(for: reference))
    }

    private static let kdbxMagic = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])

    // MARK: - Relink (#53)

    func testRelinkLocalDatabaseKeepsIdentityAndReseedsCache() throws {
        // A File Provider that replaced the item leaves a bookmark that no
        // longer resolves; the user picks the current copy of the file.
        let keyFileURL = try makeTemporaryFileURL(name: "vault.key")
        var reference = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "vault.kdbx"),
            nickname: "Family",
            keyFileURL: keyFileURL,
            autoFillEnabled: false
        )
        reference.bookmarkData = Data("unresolvable-bookmark".utf8)
        DatabaseListStore.testUpsert(reference)
        try writeAtomicallyAndDurably(Data("stale cache".utf8), to: DatabaseListStore.cacheLocation(for: reference), directoryAnchor: AppGroupContainer.url)
        XCTAssertNil(DatabaseListStore.locateDatabaseFile(for: reference))

        let currentBytes = Data("current provider copy".utf8)
        let currentURL = try makeTemporaryFileURL(name: "vault (synced).kdbx", contents: currentBytes)

        let relinked = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: reference, to: currentURL))

        let stored = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(stored, relinked)
        XCTAssertEqual(stored.id, reference.id)
        XCTAssertEqual(stored.nickname, "Family")
        XCTAssertEqual(stored.keyFileBookmarkData, reference.keyFileBookmarkData)
        XCTAssertFalse(stored.autoFillEnabled)
        XCTAssertEqual(stored.filename, "vault (synced).kdbx")
        XCTAssertEqualFilePaths(DatabaseListStore.resolveDatabaseURL(for: stored), currentURL)
        let cacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: cacheURL), currentBytes)
    }

    func testRelinkStaysUnverifiedUntilTheDatabaseOpens() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "vault.kdbx"))
        XCTAssertFalse(reference.hasUnverifiedRelink)

        try DatabaseListStore.relinkLocalDatabase(
            observed: reference,
            to: makeTemporaryFileURL(name: "picked.kdbx")
        )
        XCTAssertEqual(DatabaseListStore.databases.first?.hasUnverifiedRelink, true)

        DatabaseListStore.markDatabaseOpened(id: reference.id, observed: reference)
        XCTAssertEqual(DatabaseListStore.databases.first?.hasUnverifiedRelink, true)
        let relinked = try XCTUnwrap(DatabaseListStore.databases.first)
        DatabaseListStore.markDatabaseOpened(id: reference.id, observed: relinked)
        XCTAssertEqual(DatabaseListStore.databases.first?.hasUnverifiedRelink, false)
    }

    func testRelinkLocalDatabaseRefusesFileInRecentlyDeleted() throws {
        var reference = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: "vault.kdbx"))
        reference.bookmarkData = Data("unresolvable-bookmark".utf8)
        DatabaseListStore.testUpsert(reference)
        let trashedURL = try makeTemporaryFileURL(name: ".Trash/vault.kdbx")

        XCTAssertThrowsError(try DatabaseListStore.relinkLocalDatabase(observed: reference, to: trashedURL)) { error in
            XCTAssertEqual(error as? DatabaseListStore.LocalDatabaseFileError, .databaseInTrash)
        }
        XCTAssertEqual(DatabaseListStore.databases.first?.bookmarkData, reference.bookmarkData)
    }

    func testRelinkLocalDatabaseRefusesFileAnotherReferenceAlreadyUses() throws {
        let otherURL = try makeTemporaryFileURL(name: "other.kdbx")
        let other = try DatabaseListStore.add(url: otherURL)
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "vault.kdbx"))

        XCTAssertThrowsError(try DatabaseListStore.relinkLocalDatabase(observed: reference, to: otherURL)) { error in
            guard case DatabaseListStore.AddDatabaseError.duplicateFile(let existingReferenceID, _) = error else {
                XCTFail("Expected duplicateFile, got \(error)")
                return
            }
            XCTAssertEqual(existingReferenceID, other.id)
        }
        let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertEqual(stored.bookmarkData, reference.bookmarkData)
    }

    func testRelinkLocalDatabaseToItsOwnFileIsAllowed() throws {
        let url = try makeTemporaryFileURL(name: "vault.kdbx")
        let reference = try DatabaseListStore.add(url: url)

        let relinked = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: reference, to: url))

        XCTAssertEqual(relinked.id, reference.id)
        XCTAssertEqualFilePaths(DatabaseListStore.resolveDatabaseURL(for: relinked), url)
    }

    func testRelinkRejectsStaleObservedReference() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "relink-stale.kdbx"))
        let firstURL = try makeTemporaryFileURL(name: "relink-first.kdbx")
        let first = try XCTUnwrap(DatabaseListStore.relinkLocalDatabase(observed: original, to: firstURL))
        let secondURL = try makeTemporaryFileURL(name: "relink-second.kdbx")
        XCTAssertNil(try DatabaseListStore.relinkLocalDatabase(observed: original, to: secondURL))
        XCTAssertEqual(DatabaseListStore.databases.first?.bookmarkData, first.bookmarkData)
    }

    func testRelinkReportsVisibleUnconfirmedWithoutCacheReseed() throws {
        let original = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "relink-uncertain.kdbx", contents: Data("old".utf8)))
        let cache = DatabaseListStore.cacheLocation(for: original)
        let before = try Data(contentsOf: cache)
        let replacement = try makeTemporaryFileURL(name: "relink-new.kdbx", contents: Data("new".utf8))
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        XCTAssertThrowsError(try DatabaseListStore.relinkLocalDatabase(observed: original, to: replacement, io: io)) { error in
            guard case DatabaseListStore.RegistryWriteError.visibleUnconfirmed = error else { return XCTFail("Expected unconfirmed registry: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertTrue(DatabaseListStore.databases.first?.hasUnverifiedRelink == true)
    }

    func testRelinkLocalDatabaseLeavesKeeForgeOnlyDatabaseAndItsCacheAlone() throws {
        // A KeeForge-only database has no bookmark: its cache IS the
        // database, so relinking must never reseed it from another file.
        let appOnlyBytes = Data("app-only database".utf8)
        var reference = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: "app-only.kdbx"))
        reference.bookmarkData = nil
        try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: appOnlyBytes)
        let pickedURL = try makeTemporaryFileURL(name: "picked.kdbx", contents: Data("picked".utf8))

        XCTAssertNil(try DatabaseListStore.relinkLocalDatabase(observed: reference, to: pickedURL))

        let stored = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertNil(stored.bookmarkData)
        XCTAssertEqual(stored.filename, reference.filename)
        let cacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        XCTAssertEqual(try Data(contentsOf: cacheURL), appOnlyBytes)
    }

    func testRegisterExistingBookmarkDoesNotRequireAvailableFile() throws {
        let url = try makeTemporaryFileURL(name: "unavailable-bookmark.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)
        try FileManager.default.removeItem(at: url)
        try DatabaseListStore.addCreatedLocal(reference)
        XCTAssertEqual(DatabaseListStore.databases.first?.id, reference.id)
    }

    func testAppOnlyRegistryPrepublicationFailureRetainsCacheAndRefusesRetry() throws {
        var reference = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: "app-only-fault.kdbx"))
        reference.bookmarkData = nil
        let bytes = Data("encrypted fixture".utf8)
        var io = DurableFileWriteIO()
        io.synchronizeFile = { _ in throw POSIXError(.EIO) }
        XCTAssertThrowsError(try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: bytes, registryIO: io)) { error in
            guard case DatabaseListStore.RegistryWriteError.appOnlyCacheInstalled(let id, let sha, _) = error else { return XCTFail("Expected installed cache: \(error)") }
            XCTAssertEqual(id, reference.id)
            XCTAssertEqual(sha, FileDigest.sha512(bytes))
        }
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
        XCTAssertThrowsError(try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: bytes))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
    }

    func testAppOnlyDuplicateDoesNotPublishCache() throws {
        var first = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: "app-only-duplicate.kdbx"))
        first.bookmarkData = nil
        try DatabaseListStore.addAppOnlyCreatedLocal(first, encryptedBytes: Data("first".utf8))
        var second = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: first.filename))
        second.bookmarkData = nil
        XCTAssertThrowsError(try DatabaseListStore.addAppOnlyCreatedLocal(second, encryptedBytes: Data("second".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DatabaseListStore.cacheLocation(for: second).path))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: first)), Data("first".utf8))
    }

    func testAppOnlyRegistryVisibleUnconfirmedKeepsCacheAndIdentity() throws {
        var reference = try TestDatabaseSupport.makeReference(for: makeTemporaryFileURL(name: "app-only-visible.kdbx"))
        reference.bookmarkData = nil
        let bytes = Data("encrypted fixture".utf8)
        var io = DurableFileWriteIO()
        io.afterPublication = { _ in throw POSIXError(.EIO) }
        XCTAssertThrowsError(try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: bytes, registryIO: io)) { error in
            guard case DatabaseListStore.RegistryWriteError.appOnlyRegistryUnconfirmed(let id, let sha, _) = error else { return XCTFail("Expected visible registry: \(error)") }
            XCTAssertEqual(id, reference.id)
            XCTAssertEqual(sha, FileDigest.sha512(bytes))
        }
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertTrue(DatabaseListStore.databases.contains { $0.id == reference.id })
        XCTAssertThrowsError(try DatabaseListStore.addAppOnlyCreatedLocal(reference, encryptedBytes: bytes))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
    }

    func testRelinkLocalDatabaseIgnoresUnlistedID() throws {
        let pickedURL = try makeTemporaryFileURL(name: "picked.kdbx")

        let absent = try TestDatabaseSupport.makeReference(for: pickedURL)
        XCTAssertNil(try DatabaseListStore.relinkLocalDatabase(observed: absent, to: pickedURL))
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    private func makeTemporaryFileURL(name: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url)
        return url
    }
}
