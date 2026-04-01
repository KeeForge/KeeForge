import XCTest
@testable import KeeForge

final class DatabaseReferenceMigrationTests: XCTestCase {
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

    func testMigrationFromSharedVaultStoreCreatesSingleReferenceAndCopiesLegacyCache() throws {
        let sourceData = Data("legacy-cache".utf8)
        let url = try makeTemporaryFileURL(name: "legacy.kdbx", contents: sourceData)

        try SharedVaultStore.saveBookmark(for: url)
        try SharedVaultStore.cacheDatabaseCopy(sourceData, sourceURL: url)

        let migratedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        let migratedCacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: migratedReference.id))

        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(migratedReference.filename, "legacy.kdbx")
        XCTAssertTrue(migratedReference.isQuickLaunch)
        XCTAssertEqual(migratedReference.legacyKeychainFilename, "legacy.kdbx")
        XCTAssertEqual(try Data(contentsOf: migratedCacheURL), sourceData)
    }

    func testMigrationIsIdempotentAcrossRepeatedReads() throws {
        let url = try makeTemporaryFileURL(name: "stable.kdbx")

        try SharedVaultStore.saveBookmark(for: url)

        let firstRead = try XCTUnwrap(DatabaseListStore.databases.first)
        let secondRead = try XCTUnwrap(DatabaseListStore.databases.first)

        XCTAssertEqual(DatabaseListStore.databases.count, 1)
        XCTAssertEqual(firstRead.id, secondRead.id)
    }

    func testActiveAutoFillDatabaseFallsBackToMigratedDatabaseWhenUnset() throws {
        let url = try makeTemporaryFileURL(name: "autofill.kdbx")
        try SharedVaultStore.saveBookmark(for: url)

        let migratedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        DatabaseListStore.activeAutoFillDatabaseID = nil

        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabase?.id, migratedReference.id)
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
