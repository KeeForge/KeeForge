import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        CredentialIdentityStoreManager.clearObserver = nil
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        CredentialIdentityStoreManager.clearObserver = nil
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

    func testRemoveClearsCredentialStoreWhenRemovingActiveAutoFillDatabase() async throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "other.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = first.id

        let clearExpectation = expectation(description: "Credential store cleared")
        CredentialIdentityStoreManager.clearObserver = {
            clearExpectation.fulfill()
        }

        DatabaseListStore.remove(id: first.id)

        await fulfillment(of: [clearExpectation], timeout: 1)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func testRemoveDoesNotClearCredentialStoreWhenRemovingInactiveDatabase() async throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "inactive.kdbx"))
        DatabaseListStore.activeAutoFillDatabaseID = first.id

        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Credential store should remain populated for the active AutoFill database")
        }

        DatabaseListStore.remove(id: second.id)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, first.id)
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
