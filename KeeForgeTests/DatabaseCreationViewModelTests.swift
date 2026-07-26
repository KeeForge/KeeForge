import XCTest
@testable import KeeForge

/// Covers `DatabaseCreationViewModel`'s own state/lifecycle logic. Scenarios
/// belonging to `DatabaseCreationService` itself (filename sanitation, KDF
/// defaults, cloud upload/duplicate handling, etc.) live in
/// `DatabaseCreationServiceTests.swift` and are intentionally not repeated
/// here.
///
/// The view model threads a constructor-injected
/// `DatabaseCreationService.Environment` (default `.live`) into every service
/// call. Most tests use the default and exercise the real (network-free)
/// local creation/preparation path; the cloud-creation tests inject a fake
/// `createCloudFile` to reach the upload success/failure branches — including
/// `cloudCreationMessage(for:)`'s `.conflict` formatting — deterministically.
@MainActor
final class DatabaseCreationViewModelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    // MARK: - selectKeyFile / clearKeyFile

    func testSelectKeyFileLoadsDataBookmarkAndFilenameAndClearsDisplayedErrors() throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.validationError = "stale validation error"
        viewModel.creationError = "stale creation error"
        let keyFileURL = try makeTemporaryFileURL(name: "MyKey.keyx", contents: Data("key-bytes".utf8))

        try viewModel.selectKeyFile(url: keyFileURL)

        XCTAssertEqual(viewModel.keyFileData, Data("key-bytes".utf8))
        XCTAssertEqual(viewModel.keyFileFilename, "MyKey.keyx")
        XCTAssertNotNil(viewModel.keyFileBookmarkData)
        XCTAssertEqual(viewModel.keyFileSummary, "MyKey.keyx")
        XCTAssertNil(viewModel.validationError)
        XCTAssertNil(viewModel.creationError)
    }

    func testClearKeyFileResetsAllKeyFileStateAndDisplayedErrors() throws {
        let viewModel = DatabaseCreationViewModel()
        let keyFileURL = try makeTemporaryFileURL(name: "MyKey.keyx", contents: Data("key-bytes".utf8))
        try viewModel.selectKeyFile(url: keyFileURL)
        viewModel.validationError = "stale validation error"
        viewModel.creationError = "stale creation error"

        viewModel.clearKeyFile()

        XCTAssertNil(viewModel.keyFileData)
        XCTAssertNil(viewModel.keyFileBookmarkData)
        XCTAssertNil(viewModel.keyFileFilename)
        XCTAssertEqual(viewModel.keyFileSummary, "None")
        XCTAssertNil(viewModel.validationError)
        XCTAssertNil(viewModel.creationError)
    }

    // MARK: - prepareForExport / completeExport lifecycle

    func testPrepareForExportSucceedsClearsSecretsButKeepsKeyFileMetadata() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Personal"
        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "correct horse battery staple"
        let keyFileURL = try makeTemporaryFileURL(name: "MyKey.keyx", contents: Data("key-bytes".utf8))
        try viewModel.selectKeyFile(url: keyFileURL)

        let succeeded = await viewModel.prepareForExport()

        XCTAssertTrue(succeeded)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertNil(viewModel.creationError)
        XCTAssertNil(viewModel.validationError)
        XCTAssertNotNil(viewModel.preparedDatabase)
        XCTAssertEqual(viewModel.preparedFilename, "Personal.kdbx")
        XCTAssertFalse(viewModel.preparedEncryptedBytes.isEmpty)
        // clearSecrets() runs on success: password/confirmPassword/keyFileData
        // clear, but keyFileFilename/keyFileBookmarkData are untouched — they
        // are not secrets and completeExport still needs them via
        // preparedDatabase.
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertNil(viewModel.keyFileData)
        XCTAssertEqual(viewModel.keyFileFilename, "MyKey.keyx")
    }

    func testPrepareForExportFailsValidationAndSurfacesErrorWithoutPreparingADatabase() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Personal"
        viewModel.password = "one"
        viewModel.confirmPassword = "two"

        let succeeded = await viewModel.prepareForExport()

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertEqual(viewModel.validationError, "Password confirmation does not match.")
        XCTAssertFalse(viewModel.isCreating)
    }

    func testPrepareForExportRejectsMissingNameSecretAndKeyFile() async throws {
        let viewModel = DatabaseCreationViewModel()
        // No databaseName, no password, no key file: fails DatabaseCreationService.normalizedFilename first.
        let succeeded = await viewModel.prepareForExport()

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertNotNil(viewModel.validationError)
    }

    func testCompleteExportRegistersLocalDatabaseAndClearsPreparedDatabase() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Exported"
        viewModel.password = "export password"
        viewModel.confirmPassword = "export password"
        _ = await viewModel.prepareForExport()
        XCTAssertNotNil(viewModel.preparedDatabase)
        let destinationURL = try makeTemporaryFileURL(name: "Exported.kdbx", contents: Data())

        let created = try viewModel.completeExport(to: destinationURL)

        XCTAssertEqual(created.reference.filename, "Exported.kdbx")
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [created.reference.id])
    }

    func testCompleteExportWithoutAPreparedDatabaseThrowsDestinationUnavailable() throws {
        let viewModel = DatabaseCreationViewModel()
        let destinationURL = try makeTemporaryFileURL(name: "Nothing.kdbx", contents: Data())

        XCTAssertThrowsError(try viewModel.completeExport(to: destinationURL)) { error in
            XCTAssertEqual(error as? DatabaseCreationService.CreationError, .destinationUnavailable)
        }
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    // MARK: - createInCloud error surfacing / cloudCreationMessage(for:) formatting

    func testCreateInCloudSurfacesGenericErrorMessageWhenProviderIsUnavailable() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Cloud Vault"
        viewModel.password = "cloud password"
        viewModel.confirmPassword = "cloud password"

        // "not-a-real-provider" is not a CloudProviderKind rawValue, so
        // CloudProviderRegistry.provider(for:) returns nil and the live
        // environment throws CloudProviderError.notAuthenticated
        // deterministically, with no network access — this keeps one test on
        // the default `.live` environment path the app actually runs.
        let created = await viewModel.createInCloud(provider: "not-a-real-provider", accountID: "acct-1", folderPath: nil)

        XCTAssertNil(created)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertEqual(viewModel.creationError, CloudProviderError.notAuthenticated.localizedDescription)
    }

    func testCreateInCloudFormatsConflictErrorAsFriendlyDuplicateMessage() async throws {
        let viewModel = DatabaseCreationViewModel(
            environment: cloudEnvironment { _, _, _, _, _ in
                throw CloudProviderError.conflict(remoteRev: "rev-existing")
            }
        )
        viewModel.databaseName = "Cloud Vault"
        viewModel.password = "cloud password"
        viewModel.confirmPassword = "cloud password"

        let created = await viewModel.createInCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountID: "acct-1",
            folderPath: nil
        )

        XCTAssertNil(created)
        XCTAssertFalse(viewModel.isCreating)
        // cloudCreationMessage(for:) special-cases .conflict: during creation a
        // remote-rev conflict means the name is already taken, so the save-flow
        // "reload before saving" wording would mislead here.
        XCTAssertEqual(
            viewModel.creationError,
            "A database with this name already exists in this cloud folder."
        )
        // On failure secrets stay put so the user can retry without retyping.
        XCTAssertEqual(viewModel.password, "cloud password")
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testCreateInCloudSurfacesGenericDescriptionForNonConflictUploadFailure() async throws {
        let viewModel = DatabaseCreationViewModel(
            environment: cloudEnvironment { _, _, _, _, _ in
                throw CloudProviderError.insufficientSpace
            }
        )
        viewModel.databaseName = "Cloud Vault"
        viewModel.password = "cloud password"
        viewModel.confirmPassword = "cloud password"

        let created = await viewModel.createInCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountID: "acct-1",
            folderPath: nil
        )

        XCTAssertNil(created)
        XCTAssertEqual(viewModel.creationError, CloudProviderError.insufficientSpace.localizedDescription)
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testCreateInCloudSucceedsClearsSecretsAndRegistersCloudDatabase() async throws {
        let viewModel = DatabaseCreationViewModel(
            environment: cloudEnvironment { _, _, path, data, progress in
                progress(1)
                return Self.makeCreatedFile(path: path, data: data)
            }
        )
        viewModel.databaseName = "Cloud Vault"
        viewModel.password = "cloud password"
        viewModel.confirmPassword = "cloud password"

        let result = await viewModel.createInCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountID: "acct-1",
            folderPath: "/Vaults"
        )
        let created = try XCTUnwrap(result)

        XCTAssertNil(viewModel.creationError)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertEqual(created.reference.filename, "Cloud Vault.kdbx")
        XCTAssertEqual(created.reference.cloudSyncMetadata?.fileId, "/Vaults/Cloud Vault.kdbx")
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertNil(viewModel.keyFileData)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [created.reference.id])
    }

    func testCreateInCloudReturnsNilWithoutSurfacingACreationErrorWhenValidationFails() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "" // invalid name -> normalizedFilename throws before any service call

        let created = await viewModel.createInCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountID: "acct-1",
            folderPath: nil
        )

        XCTAssertNil(created)
        XCTAssertNotNil(viewModel.validationError)
        XCTAssertNil(viewModel.creationError, "A validation failure must not also populate the creation-error slot")
    }

    // MARK: - clearSecrets / clearPreparedDatabase

    func testClearSecretsClearsPasswordConfirmPasswordAndKeyFileDataOnly() throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.password = "secret"
        viewModel.confirmPassword = "secret"
        let keyFileURL = try makeTemporaryFileURL(name: "MyKey.keyx", contents: Data("key-bytes".utf8))
        try viewModel.selectKeyFile(url: keyFileURL)

        viewModel.clearSecrets()

        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertNil(viewModel.keyFileData, "clearSecrets() must scrub the raw key-file bytes")
        // Non-secret key-file metadata (filename/bookmark) is intentionally
        // left alone by clearSecrets(); clearKeyFile() is the API for that.
        XCTAssertEqual(viewModel.keyFileFilename, "MyKey.keyx")
        XCTAssertNotNil(viewModel.keyFileBookmarkData)
    }

    func testClearPreparedDatabaseOnlyClearsThePreparedDatabase() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Personal"
        viewModel.password = "correct horse battery staple"
        viewModel.confirmPassword = "correct horse battery staple"
        _ = await viewModel.prepareForExport()
        XCTAssertNotNil(viewModel.preparedDatabase)
        let filenameBeforeClear = viewModel.preparedFilename

        viewModel.clearPreparedDatabase()

        XCTAssertNil(viewModel.preparedDatabase)
        // suggestedFilename (derived from databaseName) still stands in once
        // preparedDatabase is gone, so preparedFilename keeps returning the
        // same name rather than going empty.
        XCTAssertEqual(viewModel.preparedFilename, filenameBeforeClear)
    }

    // MARK: - Helpers

    /// A `.live` environment with only `createCloudFile` swapped for the given
    /// fake (plus fixed clock/UUID and no-op background tasks), so cloud tests
    /// still run the real DatabaseListStore validation/registration closures.
    private func cloudEnvironment(
        createCloudFile: @escaping @Sendable (
            String, String, String, Data, @escaping DatabaseCreationService.CloudProgressHandler
        ) async throws -> CloudCreatedFile
    ) -> DatabaseCreationService.Environment {
        var environment = DatabaseCreationService.Environment.live
        environment.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        environment.id = { UUID() }
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.createCloudFile = createCloudFile
        return environment
    }

    private nonisolated static func makeCreatedFile(path: String, data: Data) -> CloudCreatedFile {
        CloudCreatedFile(
            file: CloudFile(
                id: path,
                name: (path as NSString).lastPathComponent,
                path: path,
                isFolder: false,
                modifiedDate: Date(timeIntervalSince1970: 1_700_000_001),
                size: Int64(data.count)
            ),
            metadata: CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 1_700_000_001),
                contentHash: "created-hash",
                size: Int64(data.count),
                rev: "rev-created"
            )
        )
    }

    private func makeTemporaryFileURL(name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, options: .atomic)
        return url
    }
}
