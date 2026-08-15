import XCTest
@testable import KeeForge

@MainActor
final class DatabaseExportServiceTests: XCTestCase {
    private var scratchDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        DatabaseListStore.documentsDirectoryOverride = nil
        DatabaseListStore.clearAll()
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
        try await super.tearDown()
    }

    private static let kdbxMagic = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5])
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let fixedDate = Date(timeIntervalSince1970: 1_723_642_530) // 2024-08-14 13:35:30 UTC

    private func makeCloudReference(name: String = "personal.kdbx") -> DatabaseReference {
        DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-export",
            file: CloudFile(
                id: "/Vaults/\(name)",
                name: name,
                path: "/Vaults/\(name)",
                isFolder: false,
                modifiedDate: nil,
                size: nil
            )
        )
    }

    private func makeLocalReference(filename: String, contents: Data) throws -> DatabaseReference {
        let url = scratchDirectory.appendingPathComponent(filename)
        try contents.write(to: url)
        return DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename,
            bookmarkData: try SecurityScopedBookmarkManager.makeBookmarkData(for: url),
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )
    }

    // MARK: - Current copy

    func testExportCurrentCopyReturnsCachedBytesForCloudReference() async throws {
        let reference = makeCloudReference()
        let cached = Self.kdbxMagic + Data("cloud-cache-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(cached, for: reference)

        let payload = try await DatabaseExportService.exportCurrentCopy(
            for: reference,
            now: Self.fixedDate,
            timeZone: Self.utc
        )

        XCTAssertEqual(payload.data, cached)
        XCTAssertEqual(payload.suggestedFilename, "personal (KeeForge copy 2024-08-14 133530).kdbx")
    }

    func testExportCurrentCopyReturnsFileBytesForLocalReference() async throws {
        let contents = Self.kdbxMagic + Data("local-file-bytes".utf8)
        let reference = try makeLocalReference(filename: "work.kdbx", contents: contents)

        let payload = try await DatabaseExportService.exportCurrentCopy(
            for: reference,
            now: Self.fixedDate,
            timeZone: Self.utc
        )

        XCTAssertEqual(payload.data, contents)
        XCTAssertEqual(payload.suggestedFilename, "work (KeeForge copy 2024-08-14 133530).kdbx")
    }

    func testExportCurrentCopyReturnsFileBytesForDocumentsResidentReference() async throws {
        let documentsDirectory = scratchDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory

        let contents = Self.kdbxMagic + Data("documents-bytes".utf8)
        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try contents.write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)
        XCTAssertTrue(reference.isDocumentsResident)

        let payload = try await DatabaseExportService.exportCurrentCopy(for: reference)

        XCTAssertEqual(payload.data, contents)
        XCTAssertTrue(payload.suggestedFilename.hasPrefix("resident (KeeForge copy "))
        XCTAssertTrue(payload.suggestedFilename.hasSuffix(").kdbx"))
    }

    func testExportCurrentCopyThrowsWhenCloudCacheMissing() async {
        let reference = makeCloudReference(name: "uncached.kdbx")

        do {
            _ = try await DatabaseExportService.exportCurrentCopy(for: reference)
            XCTFail("Expected cloudCacheMissing")
        } catch let error as DatabaseExportError {
            XCTAssertEqual(error, .cloudCacheMissing)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testExportCurrentCopyThrowsWhenLocalFileUnavailable() async {
        let reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "missing.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )

        do {
            _ = try await DatabaseExportService.exportCurrentCopy(for: reference)
            XCTFail("Expected localFileUnavailable")
        } catch let error as DatabaseExportError {
            XCTAssertEqual(error, .localFileUnavailable)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Backups

    func testBackupDateParsesSaverFilenameInUTC() throws {
        let date = try XCTUnwrap(DatabaseExportService.backupDate(fromFilename: "20240814-133530-000250.kdbx"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_723_642_530.000250, accuracy: 0.000_001)
    }

    func testBackupDateRejectsMalformedFilenames() {
        for filename in [
            "20240814-133530.kdbx",
            "20240814-133530-000250.bak",
            "2024081-133530-000250.kdbx",
            "20241314-133530-000250.kdbx",
            "20240814-253530-000250.kdbx",
            "abcdefgh-133530-000250.kdbx",
            "conflict-copy.kdbx",
            "",
        ] {
            XCTAssertNil(DatabaseExportService.backupDate(fromFilename: filename), filename)
        }
    }

    func testBackupsListsNewestFirstWithParsedDates() throws {
        let reference = makeCloudReference(name: "backed.kdbx")
        let directory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [
            "20240101-000000-000000.kdbx",
            "20240814-133530-000250.kdbx",
            "20240601-120000-000000.kdbx",
            "not-a-backup.kdbx",
            "ignored.txt",
        ] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }

        let backups = DatabaseExportService.backups(for: reference)

        XCTAssertEqual(
            backups.map(\.url.lastPathComponent),
            [
                "not-a-backup.kdbx",
                "20240814-133530-000250.kdbx",
                "20240601-120000-000000.kdbx",
                "20240101-000000-000000.kdbx",
            ]
        )
        XCTAssertNil(backups[0].createdAt)
        XCTAssertEqual(backups[1].createdAt?.timeIntervalSince1970 ?? 0, 1_723_642_530.000250, accuracy: 0.000_001)
        XCTAssertEqual(backups.map(\.id), backups.map(\.url))
    }

    func testBackupsIsEmptyWithoutBackupDirectory() {
        let reference = makeCloudReference(name: "fresh.kdbx")
        XCTAssertEqual(DatabaseExportService.backups(for: reference), [])
    }

    func testExportBackupReturnsBackupBytesWithSuggestedFilename() async throws {
        let reference = makeCloudReference(name: "backed.kdbx")
        let directory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = Self.kdbxMagic + Data("backup-bytes".utf8)
        try contents.write(to: directory.appendingPathComponent("20240814-133530-000250.kdbx"))

        let backup = try XCTUnwrap(DatabaseExportService.backups(for: reference).first)
        let payload = try await DatabaseExportService.exportBackup(backup, for: reference, timeZone: Self.utc)

        XCTAssertEqual(payload.data, contents)
        XCTAssertEqual(payload.suggestedFilename, "backed (backup 2024-08-14 133530).kdbx")
    }

    func testExportBackupThrowsWhenBackupIsGone() async {
        let reference = makeCloudReference(name: "backed.kdbx")
        let backup = DatabaseExportService.Backup(
            url: scratchDirectory.appendingPathComponent("20240814-133530-000250.kdbx"),
            createdAt: Self.fixedDate
        )

        do {
            _ = try await DatabaseExportService.exportBackup(backup, for: reference)
            XCTFail("Expected backupMissing")
        } catch let error as DatabaseExportError {
            XCTAssertEqual(error, .backupMissing)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Filename helpers

    func testCurrentCopyFilenameUsesLocalTimeZoneAndStripsExtension() {
        let reference = makeCloudReference(name: "Family Vault.KDBX")
        let berlin = TimeZone(identifier: "Europe/Berlin")!

        XCTAssertEqual(
            DatabaseExportService.currentCopyFilename(for: reference, date: Self.fixedDate, timeZone: berlin),
            "Family Vault (KeeForge copy 2024-08-14 153530).kdbx"
        )
        XCTAssertEqual(
            DatabaseExportService.currentCopyFilename(for: reference, date: Self.fixedDate, timeZone: Self.utc),
            "Family Vault (KeeForge copy 2024-08-14 133530).kdbx"
        )
    }

    func testCurrentCopyFilenameKeepsNameWithoutKdbxExtension() {
        let reference = makeCloudReference(name: "vault")

        XCTAssertEqual(
            DatabaseExportService.currentCopyFilename(for: reference, date: Self.fixedDate, timeZone: Self.utc),
            "vault (KeeForge copy 2024-08-14 133530).kdbx"
        )
    }

    func testBackupFilenameUsesBackupCreationDate() {
        let reference = makeCloudReference(name: "personal.kdbx")
        let backup = DatabaseExportService.Backup(
            url: URL(fileURLWithPath: "/backups/20240814-133530-000250.kdbx"),
            createdAt: Self.fixedDate
        )
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        XCTAssertEqual(
            DatabaseExportService.backupFilename(for: reference, backup: backup, timeZone: tokyo),
            "personal (backup 2024-08-14 223530).kdbx"
        )
    }

    func testBackupFilenameFallsBackToRawStemWhenDateUnknown() {
        let reference = makeCloudReference(name: "personal.kdbx")
        let backup = DatabaseExportService.Backup(
            url: URL(fileURLWithPath: "/backups/odd-name.kdbx"),
            createdAt: nil
        )

        XCTAssertEqual(
            DatabaseExportService.backupFilename(for: reference, backup: backup, timeZone: Self.utc),
            "personal (backup odd-name).kdbx"
        )
    }
}
