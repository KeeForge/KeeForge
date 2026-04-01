import XCTest
@testable import KeeForge

final class DatabaseListStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
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
