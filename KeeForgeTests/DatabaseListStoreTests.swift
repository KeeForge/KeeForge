@preconcurrency import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        resetCredentialIdentityStoreSeams()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        resetCredentialIdentityStoreSeams()
        try await super.tearDown()
    }

    private func resetCredentialIdentityStoreSeams() {
        CredentialIdentityStoreManager.populateObserver = nil
        CredentialIdentityStoreManager.clearObserver = nil
        CredentialIdentityStoreManager.removeDatabaseObserver = nil
        CredentialIdentityStoreManager.removeIdentityObserver = nil
        CredentialIdentityStoreManager.storeProviderOverride = nil
    }

    func testAddPersistsDatabaseReference() throws {
        let url = try makeTemporaryFileURL(name: "personal.kdbx")

        let reference = try DatabaseListStore.add(url: url)
        let storedReferences = DatabaseListStore.databases

        XCTAssertEqual(storedReferences.count, 1)
        XCTAssertEqual(storedReferences.first?.id, reference.id)
        XCTAssertEqual(storedReferences.first?.filename, "personal.kdbx")
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

    func testCacheDatabaseCopyUsesPerDatabaseUUIDPath() throws {
        let url = try makeTemporaryFileURL(name: "work.kdbx", contents: Data("fixture".utf8))
        let reference = try DatabaseListStore.add(url: url)
        let cachedData = Data("cached".utf8)

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
        DatabaseListStore.update(reference)

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(storedReference.displayName, "Shared Family")
        XCTAssertTrue(storedReference.isQuickLaunch)
        XCTAssertEqual(storedReference.keyFileFilename, "family.keyx")
        XCTAssertEqual(DatabaseListStore.quickLaunchDatabase?.id, storedReference.id)
    }

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
        DatabaseListStore.update(updatedFirst)

        var updatedSecond = second
        updatedSecond.isQuickLaunch = true
        DatabaseListStore.update(updatedSecond)

        let storedReferences = DatabaseListStore.databases
        XCTAssertTrue(storedReferences.first(where: { $0.id == first.id })?.isQuickLaunch ?? false)
        XCTAssertFalse(storedReferences.first(where: { $0.id == second.id })?.isQuickLaunch ?? true)
        XCTAssertEqual(DatabaseListStore.quickLaunchDatabase?.id, first.id)
    }

    func testRemoveDeletesCachedCopy() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "remove-me.kdbx"))
        try DatabaseListStore.cacheDatabaseCopy(Data("cached".utf8), for: reference.id)
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

        let reference = DatabaseListStore.addCloud(
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

    // MARK: - Cloud sync metadata merge (M13)

    func testUpdateCloudSyncMetadataMergesSyncFieldsWithoutTouchingOtherFields() throws {
        var reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        // A rename lands while the refresh is out on the network. The refresh
        // must not carry the pre-rename nickname back over it.
        reference.nickname = "Renamed While Syncing"
        DatabaseListStore.update(reference)

        let merged = DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed
        ) { metadata in
            metadata.remoteRev = "rev-B"
            metadata.remoteContentHash = "hash-B"
            metadata.lastSyncError = nil
        }

        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(merged?.id, reference.id)
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteRev, "rev-B")
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteContentHash, "hash-B")
        XCTAssertEqual(stored.nickname, "Renamed While Syncing")
    }

    func testUpdateCloudSyncMetadataSkipsWhenStoredRevisionMovedOnUnderneath() throws {
        var reference = makeStoredCloudReference(remoteRev: "rev-A", remoteContentHash: "hash-A")
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        // A save (or a pending-upload drain) completes while the refresh is in
        // flight, advancing the revision past what the refresh ever saw.
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-B"
            metadata.remoteContentHash = "hash-B"
        }
        DatabaseListStore.update(reference)

        let merged = DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed
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
        let observed = try XCTUnwrap(reference.cloudSyncMetadata)

        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteContentHash = "hash-B"
        }
        DatabaseListStore.update(reference)

        DatabaseListStore.updateCloudSyncMetadata(
            for: reference.id,
            ifUnchangedFrom: observed
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
            DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed) { metadata in
                metadata.remoteRev = "rev-B"
            }
        }

        XCTAssertNil(merged)
    }

    private func makeStoredCloudReference(
        remoteRev: String?,
        remoteContentHash: String?
    ) -> DatabaseReference {
        var reference = DatabaseListStore.addCloud(
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
        DatabaseListStore.update(reference)
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

        let first = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        let second = DatabaseListStore.addCloud(
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
        let reference = DatabaseListStore.addCloud(
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

    func testRemoveDoesNotClearCredentialStoreWhenRemovingInactiveDatabase() async throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "inactive.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = first.id

        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Credential store should remain populated for the active AutoFill database")
        }

        let removalExpectation = expectation(description: "Targeted identity removal for the inactive database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, second.id)
            XCTAssertFalse(
                includingLegacyIdentifiers,
                "Removing an inactive database must not sweep legacy identifiers"
            )
            removalExpectation.fulfill()
        }

        DatabaseListStore.remove(id: second.id)

        await fulfillment(of: [removalExpectation], timeout: 1)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, first.id)
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

    func testActiveAutoFillDatabaseIDSetterRefusesDisabledDatabase() throws {
        let enabled = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "enabled.kdbx"))
        let disabled = try TestDatabaseSupport.makeReference(
            for: makeTemporaryFileURL(name: "disabled.kdbx"),
            autoFillEnabled: false
        )
        DatabaseListStore.update(disabled)
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
        DatabaseListStore.update(disabled)
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

        DatabaseListStore.setAutoFillEnabled(true, for: disabled)

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
        DatabaseListStore.update(reference)
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
        DatabaseListStore.update(updatedReference)

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
        DatabaseListStore.update(legacyReference)
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
        XCTAssertEqual(resolvedURL.path, url.path)
        XCTAssertEqual(DatabaseListStore.resolveDatabaseURL(for: reference)?.path, url.path)
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
            DatabaseListStore.addCloud(
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
                    DatabaseListStore.update(mutated)
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
