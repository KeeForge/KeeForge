import XCTest
@testable import KeeForge

final class DatabaseReferenceMigrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
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

    func testCloudDatabaseReferenceRoundTripsThroughCodable() throws {
        let reference = DatabaseReference(
            id: UUID(),
            nickname: "Dropbox Vault",
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: "device.keyx",
            isQuickLaunch: false,
            lastOpenedAt: Date(timeIntervalSince1970: 200),
            addedAt: Date(timeIntervalSince1970: 100),
            colorTag: "blue",
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: "abc123",
                    remoteModifiedAt: Date(timeIntervalSince1970: 300),
                    remoteRev: "rev-123",
                    lastSyncedAt: Date(timeIntervalSince1970: 400),
                    lastSyncError: "Offline"
                )
            )
        )

        let data = try JSONEncoder().encode(reference)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)
        let metadata = try XCTUnwrap(decoded.cloudSyncMetadata)

        XCTAssertEqual(decoded.id, reference.id)
        XCTAssertEqual(decoded.nickname, "Dropbox Vault")
        XCTAssertEqual(decoded.keyFileFilename, "device.keyx")
        XCTAssertEqual(metadata.provider, CloudProviderKind.dropbox.rawValue)
        XCTAssertEqual(metadata.accountId, "acct-1")
        XCTAssertEqual(metadata.fileId, "/Vaults/vault.kdbx")
        XCTAssertEqual(metadata.remoteContentHash, "abc123")
        XCTAssertEqual(metadata.remoteRev, "rev-123")
        XCTAssertEqual(metadata.lastSyncError, "Offline")
    }

    func testDecodingLegacyReferenceWithoutSourceDefaultsToLocal() throws {
        let legacy = LegacyDatabaseReferencePayload(
            id: UUID(),
            nickname: "Legacy",
            filename: "legacy.kdbx",
            bookmarkData: Data("bookmark".utf8),
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: true,
            lastOpenedAt: Date(timeIntervalSince1970: 200),
            addedAt: Date(timeIntervalSince1970: 100),
            colorTag: nil,
            legacyKeychainFilename: "legacy.kdbx"
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(DatabaseReference.self, from: data)

        XCTAssertFalse(decoded.isCloudBacked)
        XCTAssertNil(decoded.cloudSyncMetadata)
        XCTAssertEqual(decoded.filename, legacy.filename)
        XCTAssertEqual(decoded.legacyKeychainFilename, legacy.legacyKeychainFilename)
    }

    private struct LegacyDatabaseReferencePayload: Codable {
        let id: UUID
        let nickname: String?
        let filename: String
        let bookmarkData: Data?
        let keyFileBookmarkData: Data?
        let keyFileFilename: String?
        let isQuickLaunch: Bool
        let lastOpenedAt: Date?
        let addedAt: Date
        let colorTag: String?
        let legacyKeychainFilename: String?
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
