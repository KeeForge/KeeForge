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
