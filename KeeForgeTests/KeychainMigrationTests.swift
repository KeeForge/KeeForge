import XCTest
@testable import KeeForge

final class KeychainMigrationTests: XCTestCase {
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

    func testMigratedReferenceKeepsLegacyKeychainFilenameUntilLazyMigrationCompletes() throws {
        let url = try makeTemporaryFileURL(name: "legacy-keychain.kdbx")
        try SharedVaultStore.saveBookmark(for: url)

        let migratedReference = try XCTUnwrap(DatabaseListStore.databases.first)

        XCTAssertEqual(migratedReference.legacyKeychainFilename, "legacy-keychain.kdbx")
    }

    func testClearLegacyKeychainFilenamePreservesDatabaseIdentity() throws {
        let url = try makeTemporaryFileURL(name: "clear-legacy.kdbx")
        try SharedVaultStore.saveBookmark(for: url)

        let migratedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        DatabaseListStore.clearLegacyKeychainFilename(for: migratedReference.id)

        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first)
        XCTAssertEqual(updatedReference.id, migratedReference.id)
        XCTAssertNil(updatedReference.legacyKeychainFilename)
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
