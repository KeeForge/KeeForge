import XCTest
@testable import KeeForge

final class SyncedFolderDetectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        super.tearDown()
    }

    func testDetectICloudDriveURLReturnsICloudDrive() async throws {
        let url = try makeTemporaryFileURL(name: "icloud.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                isUbiquitousItem: true,
                providerIdentifier: nil
            )
        )

        XCTAssertEqual(result, .iCloudDrive)
    }

    func testDetectDropboxFileProviderDomainReturnsDropbox() async throws {
        let url = try makeTemporaryFileURL(name: "dropbox.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                providerIdentifier: "com.dropbox.Dropbox.FileProvider"
            )
        )

        XCTAssertEqual(result, .dropbox)
    }

    func testDetectGoogleDriveFileProviderDomainReturnsGoogleDrive() async throws {
        let url = try makeTemporaryFileURL(name: "google-drive.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                providerIdentifier: "com.google.Drive.FileProviderExtension"
            )
        )

        XCTAssertEqual(result, .googleDrive)
    }

    func testDetectOneDriveFileProviderDomainReturnsOneDrive() async throws {
        let url = try makeTemporaryFileURL(name: "onedrive.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                providerIdentifier: "com.microsoft.skydrive.OneDriveFileProvider"
            )
        )

        XCTAssertEqual(result, .oneDrive)
    }

    func testDetectBoxFileProviderDomainReturnsBox() async throws {
        let url = try makeTemporaryFileURL(name: "box.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                providerIdentifier: "com.box.BoxFileProvider"
            )
        )

        XCTAssertEqual(result, .box)
    }

    func testDetectUnknownDomainReturnsUnknownThirdPartyWithDomainIdentifier() async throws {
        let url = try makeTemporaryFileURL(name: "unknown.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(
                url: url,
                providerIdentifier: "com.example.SyncProvider"
            )
        )

        XCTAssertEqual(
            result,
            .unknownThirdParty(domainIdentifier: "com.example.SyncProvider")
        )
    }

    func testDetectAppGroupContainerURLReturnsNotSynced() async throws {
        let url = SharedVaultStore.databaseCacheDirectory.appendingPathComponent("local.kdbx")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("fixture".utf8).write(to: url, options: .atomic)

        let reference = try TestDatabaseSupport.makeReference(for: url)
        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(url: url, providerIdentifier: nil)
        )

        XCTAssertEqual(result, .notSynced)
    }

    func testDetectSecurityScopedURLOutsideKnownProvidersReturnsNotSynced() async throws {
        let url = try makeTemporaryFileURL(name: "device-storage.kdbx")
        let reference = try TestDatabaseSupport.makeReference(for: url)

        let result = await SyncedFolderDetector.detect(
            reference: reference,
            environment: makeEnvironment(url: url, providerIdentifier: nil)
        )

        XCTAssertEqual(result, .notSynced)
    }

    private func makeEnvironment(
        url: URL,
        isUbiquitousItem: Bool = false,
        providerIdentifier: String?
    ) -> SyncedFolderDetector.Environment {
        SyncedFolderDetector.Environment(
            resolveLocation: { _ in
                SyncedFolderDetector.ResolvedLocation(url: url, usesSecurityScope: false)
            },
            isUbiquitousItem: { _ in
                isUbiquitousItem
            },
            providerIdentifier: { _ in
                providerIdentifier
            }
        )
    }

    private func makeTemporaryFileURL(name: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url, options: .atomic)
        return url
    }
}
