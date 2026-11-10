import AuthenticationServices
import CryptoKit
import KDBXKit
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
/// local creation/preparation path; cloud tests inject a provider into the
/// durable creation coordinator to reach success/failure branches — including
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

    #if os(macOS)
    func testSelectLockedKeyFileLoadsDataAndBookmark() throws {
        let url = try makeTemporaryFileURL(name: "locked.keyx", contents: Data("key-bytes".utf8))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)

        let viewModel = DatabaseCreationViewModel()
        try viewModel.selectKeyFile(url: url)

        XCTAssertEqual(viewModel.keyFileData, Data("key-bytes".utf8))
        XCTAssertEqual(viewModel.keyFileFilename, "locked.keyx")
        let bookmark = try XCTUnwrap(viewModel.keyFileBookmarkData)
        XCTAssertNotNil(SecurityScopedBookmarkManager.resolveURL(from: bookmark))
    }
    #endif

    func testValidNameShowsFilenamePreviewWithoutReplacementExplanation() {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Family Vault"

        XCTAssertEqual(viewModel.filenamePreview, "Family Vault.kdbx")
        XCTAssertFalse(viewModel.showsFilenameReplacementExplanation)
    }

    func testReplacedCharactersShowFilenamePreviewAndExplanation() {
        let viewModel = DatabaseCreationViewModel()
        for character in "/:\\?*|\"<>" {
            viewModel.databaseName = "Family\(character)Vault"

            XCTAssertEqual(viewModel.filenamePreview, "Family_Vault.kdbx")
            XCTAssertTrue(viewModel.showsFilenameReplacementExplanation)
        }
    }

    func testTrimmingAloneDoesNotShowReplacementExplanation() {
        let viewModel = DatabaseCreationViewModel()
        for name in ["  Family Vault  ", ".Family Vault.", " \n.Family Vault.\t "] {
            viewModel.databaseName = name

            XCTAssertEqual(viewModel.filenamePreview, "Family Vault.kdbx")
            XCTAssertFalse(viewModel.showsFilenameReplacementExplanation)
        }
    }

    func testPercentNamesShowLiteralPreviewWithoutReplacementExplanation() {
        let viewModel = DatabaseCreationViewModel()
        for name in ["100%", "new%20db 100%"] {
            viewModel.databaseName = name

            XCTAssertEqual(viewModel.filenamePreview, "\(name).kdbx")
            XCTAssertFalse(viewModel.showsFilenameReplacementExplanation)
        }
    }

    func testInvalidNameHasNoFilenamePreviewOrReplacementExplanation() {
        let viewModel = DatabaseCreationViewModel()
        for name in ["", "   ", " .\n. "] {
            viewModel.databaseName = name

            XCTAssertNil(viewModel.filenamePreview)
            XCTAssertFalse(viewModel.showsFilenameReplacementExplanation)
        }
    }

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

    // MARK: - Advanced cipher / KDF preset selection

    func testAdvancedSelectionDefaultsToAES256AndBalancedPreset() {
        let viewModel = DatabaseCreationViewModel()

        XCTAssertEqual(viewModel.cipher, .aes256)
        XCTAssertEqual(viewModel.kdfPreset, .balanced)
    }

    func testChosenCipherAndPresetThreadIntoPreparedDatabase() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "Tuned"
        viewModel.password = "tuned password"
        viewModel.confirmPassword = "tuned password"
        viewModel.cipher = .chacha20
        viewModel.kdfPreset = .strong

        let succeeded = await viewModel.prepareForExport()

        XCTAssertTrue(succeeded)
        let summary = try KDBXFileSummary.inspect(data: viewModel.preparedEncryptedBytes)
        XCTAssertEqual(summary.cipher, .chaCha20)
        XCTAssertEqual(
            summary.keyDerivation,
            .argon2id(
                iterations: 10,
                memoryBytes: 128 << 20,
                parallelism: DatabaseCreationDefaults.argon2idParallelism
            )
        )
    }

    // MARK: - prepareForExport / completeExport lifecycle

    func testPrepareForExportSucceedsClearsSecretsButKeepsKeyFileMetadata() async throws {
        let viewModel = DatabaseCreationViewModel()
        viewModel.databaseName = "new%20db 100%"
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
        XCTAssertEqual(viewModel.suggestedFilename, "new%20db 100%.kdbx")
        XCTAssertEqual(viewModel.preparedFilename, "new%20db 100%.kdbx")
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
        let keyFileData = try KDBXKeyFile.generate()
        let keyFileURL = try makeTemporaryFileURL(name: "Cloud.keyx", contents: keyFileData)
        try viewModel.selectKeyFile(url: keyFileURL)
        let keyFileBookmark = try XCTUnwrap(viewModel.keyFileBookmarkData)

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
        XCTAssertEqual(created.reference.keyFileBookmarkData, keyFileBookmark)
        XCTAssertEqual(created.reference.keyFileFilename, "Cloud.keyx")
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [created.reference.id])
        let cached = try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: created.reference)))
        XCTAssertEqual(FileDigest.sha512(cached), created.openTimeSHA512)
        let parsed = try KDBXParser.parseWithMeta(data: cached, compositeKey: created.compositeKey, sessionKey: created.sessionKey)
        XCTAssertEqual(parsed.rootGroup.groups.first?.name, "Cloud Vault")
        let originalKey = try KDBXCrypto.compositeKey(password: "cloud password", keyFileData: keyFileData)
        _ = try KDBXParser.parseWithMeta(data: cached, compositeKey: originalKey, sessionKey: created.sessionKey)
        XCTAssertThrowsError(try KDBXParser.parseWithMeta(data: cached,
            compositeKey: KDBXCrypto.compositeKey(password: "cloud password"), sessionKey: created.sessionKey))
        let receipt = try XCTUnwrap(PendingUploadQueue.listCreations(includingCompleted: true).first)
        XCTAssertEqual(receipt.phase, .completed)
        XCTAssertEqual(receipt.receipt?.id, created.reference.id)
        XCTAssertEqual(created.reference.cloudSyncMetadata?.localHeadOperationID, receipt.operationID)
        XCTAssertEqual(receipt.payloadSHA512, FileDigest.sha512(cached))
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

    func testDismissedPreparationDropsLatePreparedDatabase() async throws {
        let prepared = try await DatabaseCreationService.prepare(
            request: DatabasePreparationRequest(
                displayName: "Late Vault", password: "password", keyFileData: nil,
                keyFileBookmarkData: nil, keyFileFilename: nil
            )
        )
        let suspension = CreationSuspension<PreparedDatabase>()
        let viewModel = DatabaseCreationViewModel(preparationOperation: { _, _ in
            try await suspension.wait()
        })
        viewModel.databaseName = "Late Vault"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        let preparation = Task { await viewModel.prepareForExport() }
        await fulfillment(of: [suspension.started], timeout: 30)

        viewModel.cancelPendingCreation()
        await suspension.resolve(.success(prepared))
        let succeeded = await preparation.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertNil(viewModel.creationError)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
    }

    func testDismissedPreparationDropsLateError() async {
        let suspension = CreationSuspension<PreparedDatabase>()
        let viewModel = DatabaseCreationViewModel(preparationOperation: { _, _ in
            try await suspension.wait()
        })
        viewModel.databaseName = "Late Vault"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        let preparation = Task { await viewModel.prepareForExport() }
        await fulfillment(of: [suspension.started], timeout: 30)

        viewModel.cancelPendingCreation()
        await suspension.resolve(.failure(DatabaseCreationService.CreationError.generatedFileFailedToReopen))
        let succeeded = await preparation.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertNil(viewModel.creationError)
        XCTAssertFalse(viewModel.isCreating)
    }

    func testDismissedCloudCreationDoesNotReturnLateCommittedDatabase() async {
        let suspension = CreationSuspension<Void>()
        let viewModel = DatabaseCreationViewModel(
            environment: cloudEnvironment { _, _, path, data, _ in
                try await suspension.wait()
                return Self.makeCreatedFile(path: path, data: data)
            }
        )
        viewModel.databaseName = "Late Cloud Vault"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        let creation = Task {
            await viewModel.createInCloud(provider: "dropbox", accountID: "acct-1", folderPath: nil)
        }
        await fulfillment(of: [suspension.started], timeout: 30)

        viewModel.cancelPendingCreation()
        await suspension.resolve(.success(()))
        let created = await creation.value

        XCTAssertNil(created)
        XCTAssertNil(viewModel.creationError)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertEqual(viewModel.password, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        // Dismissal suppresses opening the result; it cannot undo a committed upload.
        XCTAssertEqual(DatabaseListStore.databases.map(\.filename), ["Late Cloud Vault.kdbx"])
    }

    func testDismissedCloudCreationDropsLateError() async {
        let suspension = CreationSuspension<Void>()
        let viewModel = DatabaseCreationViewModel(
            environment: cloudEnvironment { _, _, path, data, _ in
                try await suspension.wait()
                return Self.makeCreatedFile(path: path, data: data)
            }
        )
        viewModel.databaseName = "Late Cloud Vault"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        let creation = Task {
            await viewModel.createInCloud(provider: "dropbox", accountID: "acct-1", folderPath: nil)
        }
        await fulfillment(of: [suspension.started], timeout: 30)

        viewModel.cancelPendingCreation()
        await suspension.resolve(.failure(CloudProviderError.insufficientSpace))
        let created = await creation.value

        XCTAssertNil(created)
        XCTAssertNil(viewModel.creationError)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
    }

    func testDriveDestinationUsesExistingAvailabilityGate() {
        XCTAssertEqual(DatabaseCreationDestinationChoice.googleDrive.cloudProviderKind, .googleDrive)
        XCTAssertEqual(
            DatabaseCreationDestinationChoice.availableChoices.contains(.googleDrive),
            CloudProviderKind.googleDrive.isAvailableOnCurrentPlatform
        )
    }

    func testCloudRetryPinsPreparedIdentityAndBytesUntilFormOrDestinationChanges() async throws {
        let prepared = try await DatabaseCreationService.prepare(request: DatabasePreparationRequest(
            displayName: "Retry Vault", password: "password", keyFileData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil
        ))
        let recorder = CloudCreationWorkflowRecorder()
        let viewModel = DatabaseCreationViewModel(
            preparationOperation: { _, _ in await recorder.prepared(); return prepared },
            cloudCreationOperation: { prepared, destination, _ in
                await recorder.dispatched(prepared, destination: destination)
                throw CloudProviderError.networkUnavailable
            }
        )
        viewModel.databaseName = "Retry Vault"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        for _ in 0..<2 {
            let result = await viewModel.createInCloud(provider: "googledrive", accountID: "permission-A", folderPath: "opaque_parent_ID")
            XCTAssertNil(result)
        }
        var snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.preparations, 1)
        XCTAssertEqual(snapshot.ids, [prepared.id, prepared.id])
        XCTAssertEqual(snapshot.payloads, [prepared.encryptedBytes, prepared.encryptedBytes])
        XCTAssertEqual(snapshot.destinations, Array(repeating: .cloud(provider: "googledrive", accountId: "permission-A", folderPath: "opaque_parent_ID"), count: 2))
        XCTAssertEqual(viewModel.preparedDatabase?.id, prepared.id)

        viewModel.password = "changed password"
        viewModel.confirmPassword = "changed password"
        XCTAssertNil(viewModel.preparedDatabase)
        _ = await viewModel.createInCloud(provider: "googledrive", accountID: "permission-A", folderPath: "opaque_parent_ID")
        _ = await viewModel.createInCloud(provider: "googledrive", accountID: "permission-A", folderPath: nil)
        snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.preparations, 3)
        XCTAssertEqual(snapshot.destinations.last, .cloud(provider: "googledrive", accountId: "permission-A", folderPath: nil))
    }

    func testChangedFormDuringCloudPreparationNeverDispatchesStaleCiphertext() async throws {
        let prepared = try await DatabaseCreationService.prepare(request: DatabasePreparationRequest(
            displayName: "Original", password: "password", keyFileData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil
        ))
        let suspension = CreationSuspension<PreparedDatabase>()
        let recorder = CloudCreationWorkflowRecorder()
        let viewModel = DatabaseCreationViewModel(
            preparationOperation: { _, _ in try await suspension.wait() },
            cloudCreationOperation: { prepared, destination, _ in
                await recorder.dispatched(prepared, destination: destination)
                throw CloudProviderError.networkUnavailable
            }
        )
        viewModel.databaseName = "Original"
        viewModel.password = "password"
        viewModel.confirmPassword = "password"
        let task = Task { await viewModel.createInCloud(provider: "googledrive", accountID: "A", folderPath: nil) }
        await fulfillment(of: [suspension.started], timeout: 30)
        viewModel.databaseName = "Different action"
        await suspension.resolve(.success(prepared))
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(viewModel.preparedDatabase)
        XCTAssertNil(viewModel.creationError)
        let snapshot = await recorder.snapshot()
        XCTAssertTrue(snapshot.ids.isEmpty)
    }

    // MARK: - Helpers

    /// Exercises the production journal, cache and registration with only provider I/O replaced.
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
        environment.createCloudFile = { _, _, _, _, _ in
            XCTFail("Durable creation must not use the legacy creation seam")
            throw CloudProviderError.invalidConfiguration
        }
        environment.durableCreateCloud = { prepared, providerID, accountID, target in
            let provider = ViewModelCreationProvider(id: providerID, accountID: accountID, create: createCloudFile)
            var creation = CloudFileCreationCoordinator.Environment.live
            creation.provider = { id in id == provider.id ? provider : nil }
            creation.queue.postDarwinNotification = { }
            var template = creationTemplate(id: prepared.id)
            template.filename = prepared.filename
            template.addedAt = prepared.addedAt
            template.keyFileBookmarkData = prepared.keyFileBookmarkData
            template.keyFileFilename = prepared.keyFileFilename
            return try await CloudFileCreationCoordinator.create(operationID: prepared.id, ownerDatabaseID: prepared.id,
                provider: providerID, accountID: accountID, target: target, bytes: prepared.encryptedBytes,
                referenceTemplate: template, environment: creation)
        }
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

private actor CreationSuspension<Value: Sendable> {
    nonisolated let started = XCTestExpectation(description: "Creation reached the injected suspension")
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait() async throws -> Value {
        started.fulfill()
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<Value, Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class ViewModelCreationProvider: CloudProvider, Sendable {
    let id: String
    let accountID: String
    let displayName = "Creation test"
    let iconName = "cloud"
    let create: @Sendable (String, String, String, Data, @escaping DatabaseCreationService.CloudProgressHandler) async throws -> CloudCreatedFile
    init(id: String, accountID: String,
         create: @escaping @Sendable (String, String, String, Data, @escaping DatabaseCreationService.CloudProgressHandler) async throws -> CloudCreatedFile) {
        self.id = id; self.accountID = accountID; self.create = create
    }
    @MainActor func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount { throw CloudProviderError.authenticationCancelled }
    func isAuthenticated(accountId: String) -> Bool { accountId == accountID }
    func signOut(accountId: String) { }
    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] { [] }
    func download(accountId: String, fileId: String, to localURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata? { throw CloudProviderError.fileNotFound }
    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata { throw CloudProviderError.fileNotFound }
    func upload(accountId: String, fileId: String, data: Data, expectedRev: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudFileMetadata { throw CloudProviderError.invalidConfiguration }
    func createFile(accountId: String, path: String, data: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> CloudCreatedFile {
        try await create(id, accountId, path, data, progress)
    }
}

private actor CloudCreationWorkflowRecorder {
    private var preparations = 0
    private var ids: [UUID] = []
    private var payloads: [Data] = []
    private var destinations: [DatabaseCreationDestination] = []
    func prepared() { preparations += 1 }
    func dispatched(_ prepared: PreparedDatabase, destination: DatabaseCreationDestination) {
        ids.append(prepared.id)
        payloads.append(prepared.encryptedBytes)
        destinations.append(destination)
    }
    func snapshot() -> (preparations: Int, ids: [UUID], payloads: [Data], destinations: [DatabaseCreationDestination]) {
        (preparations, ids, payloads, destinations)
    }
}
