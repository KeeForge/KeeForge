import XCTest
@testable import KeeForge

/// Covers `MasterKeyChangeViewModel`'s own state/lifecycle logic: submit
/// validation, key-file keep/replace/remove state, the effective values passed
/// to the injected change operation, secret scrubbing, and error-to-message
/// mapping. The rekey flow itself (`DatabaseViewModel.changeMasterKey`) is
/// covered by `DatabaseViewModelTests.swift`.
@MainActor
final class MasterKeyChangeViewModelTests: XCTestCase {
    private struct StubError: Error {}

    private struct CapturedChange: Equatable {
        var password: String?
        var keyFileData: Data?
        var bookmarkData: Data?
        var filename: String?
    }

    private final class ChangeRecorder {
        var captured: CapturedChange?
        var error: Error?
    }

    private func makeViewModel(
        currentKeyFileFilename: String? = nil,
        currentKeyFileBookmarkData: Data? = nil,
        sessionKeyFileData: Data? = nil,
        currentKeyFileLoadResult: (data: Data, filename: String)? = nil,
        recorder: ChangeRecorder = ChangeRecorder()
    ) -> MasterKeyChangeViewModel {
        MasterKeyChangeViewModel(
            currentKeyFileFilename: currentKeyFileFilename,
            currentKeyFileBookmarkData: currentKeyFileBookmarkData,
            sessionKeyFileData: sessionKeyFileData,
            loadCurrentKeyFile: { currentKeyFileLoadResult },
            changeOperation: { password, keyFileData, bookmarkData, filename in
                if let error = recorder.error {
                    throw error
                }
                recorder.captured = CapturedChange(
                    password: password,
                    keyFileData: keyFileData,
                    bookmarkData: bookmarkData,
                    filename: filename
                )
            }
        )
    }

    private func makeTemporaryFileURL(name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Validation

    func testPerformChangeRejectsMismatchedConfirmationWithoutInvokingChange() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.newPassword = "one"
        viewModel.confirmPassword = "two"

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.validationError, "Password confirmation does not match.")
        XCTAssertNil(recorder.captured)
        XCTAssertFalse(viewModel.isWorking)
    }

    func testPerformChangeRejectsEmptyPasswordWithoutAnyKeyFile() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(recorder: recorder)

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            viewModel.validationError,
            DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
        )
        XCTAssertNil(recorder.captured)
    }

    func testValidatePassesWithEmptyPasswordWhenKeepingCurrentKeyFile() throws {
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8)
        )

        XCTAssertTrue(viewModel.validate())
        XCTAssertNil(viewModel.validationError)
    }

    func testValidateRejectsEmptyPasswordAfterRemovingCurrentKeyFile() throws {
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8)
        )
        viewModel.clearKeyFile()

        XCTAssertFalse(viewModel.validate())
        XCTAssertEqual(
            viewModel.validationError,
            DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
        )
    }

    // MARK: - Key-file state

    func testInitialStateKeepsCurrentKeyFileAndShowsItsFilename() throws {
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8)
        )

        XCTAssertEqual(viewModel.keyFileChange, .keepCurrent)
        XCTAssertEqual(viewModel.keyFileSummary, "current.keyx")
        XCTAssertTrue(viewModel.hasEffectiveKeyFile)
    }

    func testSelectKeyFileEntersReplaceStateWithDataBookmarkAndFilename() throws {
        let viewModel = makeViewModel(currentKeyFileFilename: "current.keyx")
        viewModel.validationError = "stale validation error"
        viewModel.changeError = "stale change error"
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))

        try viewModel.selectKeyFile(url: url)

        XCTAssertEqual(viewModel.keyFileChange, .replace)
        XCTAssertEqual(viewModel.pickedKeyFileData, Data("new-key-bytes".utf8))
        XCTAssertNotNil(viewModel.pickedKeyFileBookmarkData)
        XCTAssertEqual(viewModel.pickedKeyFileFilename, "NewKey.keyx")
        XCTAssertEqual(viewModel.keyFileSummary, "NewKey.keyx")
        XCTAssertTrue(viewModel.hasEffectiveKeyFile)
        XCTAssertNil(viewModel.validationError)
        XCTAssertNil(viewModel.changeError)
    }

    func testClearKeyFileWithCurrentAssociationEntersRemoveState() throws {
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8)
        )
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))
        try viewModel.selectKeyFile(url: url)

        viewModel.clearKeyFile()

        XCTAssertEqual(viewModel.keyFileChange, .remove)
        XCTAssertNil(viewModel.pickedKeyFileData)
        XCTAssertNil(viewModel.pickedKeyFileBookmarkData)
        XCTAssertNil(viewModel.pickedKeyFileFilename)
        XCTAssertEqual(viewModel.keyFileSummary, "None")
        XCTAssertFalse(viewModel.hasEffectiveKeyFile)
    }

    func testClearKeyFileWithoutCurrentAssociationStaysKeepCurrent() throws {
        let viewModel = makeViewModel()
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))
        try viewModel.selectKeyFile(url: url)

        viewModel.clearKeyFile()

        XCTAssertEqual(viewModel.keyFileChange, .keepCurrent)
        XCTAssertEqual(viewModel.keyFileSummary, "None")
        XCTAssertFalse(viewModel.hasEffectiveKeyFile)
    }

    // MARK: - performChange effective values

    func testPerformChangePassesPasswordOnlyWhenNoKeyFileInvolved() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            recorder.captured,
            CapturedChange(password: "new password", keyFileData: nil, bookmarkData: nil, filename: nil)
        )
    }

    func testPerformChangeKeepCurrentLoadsCurrentKeyFileBytesAndKeepsAssociation() async throws {
        let recorder = ChangeRecorder()
        let bookmark = Data("bookmark".utf8)
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: bookmark,
            currentKeyFileLoadResult: (data: Data("current-key-bytes".utf8), filename: "current.keyx"),
            recorder: recorder
        )
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            recorder.captured,
            CapturedChange(
                password: "new password",
                keyFileData: Data("current-key-bytes".utf8),
                bookmarkData: bookmark,
                filename: "current.keyx"
            )
        )
    }

    func testPerformChangeKeepCurrentSurfacesErrorWhenCurrentKeyFileCannotBeRead() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8),
            currentKeyFileLoadResult: nil,
            recorder: recorder
        )
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            viewModel.changeError,
            "The current key file could not be read. Select it again or clear it, then try again."
        )
        XCTAssertNil(recorder.captured)
    }

    func testPerformChangeReplacePassesPickedKeyFileValues() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("old-bookmark".utf8),
            recorder: recorder
        )
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))
        try viewModel.selectKeyFile(url: url)

        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        let captured = try XCTUnwrap(recorder.captured)
        XCTAssertNil(captured.password)
        XCTAssertEqual(captured.keyFileData, Data("new-key-bytes".utf8))
        XCTAssertEqual(captured.bookmarkData, viewModel.pickedKeyFileBookmarkData)
        XCTAssertEqual(captured.filename, "NewKey.keyx")
    }

    func testPerformChangeRemovePassesNilKeyFileValues() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(
            currentKeyFileFilename: "current.keyx",
            currentKeyFileBookmarkData: Data("bookmark".utf8),
            recorder: recorder
        )
        viewModel.clearKeyFile()
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            recorder.captured,
            CapturedChange(password: "new password", keyFileData: nil, bookmarkData: nil, filename: nil)
        )
    }

    func testPerformChangeSuccessClearsSecrets() async throws {
        let viewModel = makeViewModel()
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))
        try viewModel.selectKeyFile(url: url)
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(viewModel.newPassword, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertNil(viewModel.pickedKeyFileData, "clearSecrets() must scrub the raw key-file bytes")
        XCTAssertNil(viewModel.changeError)
        XCTAssertFalse(viewModel.isWorking)
    }

    func testPerformChangeFailureKeepsSecretsForRetry() async throws {
        let recorder = ChangeRecorder()
        recorder.error = DatabaseViewModel.RekeyError.conflict
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.newPassword, "new password")
        XCTAssertNotNil(viewModel.changeError)
    }

    // MARK: - Cancellation

    func testPerformChangeRefusesWhenCancelled() async throws {
        let recorder = ChangeRecorder()
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.newPassword = "new-password"
        viewModel.confirmPassword = "new-password"
        viewModel.cancelPendingChange()

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertNil(recorder.captured)
    }

    func testPerformChangeAbortsWhenCancelledDuringKeyFileLoad() async throws {
        let recorder = ChangeRecorder()
        var viewModel: MasterKeyChangeViewModel?
        let created = MasterKeyChangeViewModel(
            currentKeyFileFilename: "vault.key",
            currentKeyFileBookmarkData: Data("bookmark".utf8),
            loadCurrentKeyFile: {
                // The sheet was dismissed while the load was in flight.
                viewModel?.cancelPendingChange()
                return (Data("key-bytes".utf8), "vault.key")
            },
            changeOperation: { password, keyFileData, bookmarkData, filename in
                recorder.captured = CapturedChange(
                    password: password,
                    keyFileData: keyFileData,
                    bookmarkData: bookmarkData,
                    filename: filename
                )
            }
        )
        viewModel = created
        created.newPassword = "new-password"
        created.confirmPassword = "new-password"

        let succeeded = await created.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertNil(recorder.captured, "A change cancelled mid-load must not rekey")
    }

    func testPerformChangeUsesPasswordCapturedBeforeKeyFileLoad() async throws {
        // Dismissal clears the form; the password captured at entry must be
        // what the change uses, never the cleared field.
        let recorder = ChangeRecorder()
        var viewModel: MasterKeyChangeViewModel?
        let created = MasterKeyChangeViewModel(
            currentKeyFileFilename: "vault.key",
            currentKeyFileBookmarkData: Data("bookmark".utf8),
            loadCurrentKeyFile: {
                viewModel?.clearSecrets()
                return (Data("key-bytes".utf8), "vault.key")
            },
            changeOperation: { password, keyFileData, bookmarkData, filename in
                recorder.captured = CapturedChange(
                    password: password,
                    keyFileData: keyFileData,
                    bookmarkData: bookmarkData,
                    filename: filename
                )
            }
        )
        viewModel = created
        created.newPassword = "new-password"
        created.confirmPassword = "new-password"

        let succeeded = await created.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(recorder.captured?.password, "new-password")
    }

    // MARK: - Session key file

    func testKeepCurrentUsesSessionKeyFileWhenNoAssociationExists() async throws {
        let recorder = ChangeRecorder()
        let sessionKeyFile = Data("session-key-bytes".utf8)
        let viewModel = makeViewModel(sessionKeyFileData: sessionKeyFile, recorder: recorder)
        viewModel.newPassword = "new-password"
        viewModel.confirmPassword = "new-password"

        XCTAssertTrue(viewModel.hasEffectiveKeyFile)
        let succeeded = await viewModel.performChange()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            recorder.captured,
            CapturedChange(
                password: "new-password",
                keyFileData: sessionKeyFile,
                bookmarkData: nil,
                filename: nil
            ),
            "A key file picked manually at unlock must survive a password-only change without gaining an association"
        )
    }

    // MARK: - clearSecrets

    func testClearSecretsScrubsPasswordsAndPickedKeyFileBytesOnly() throws {
        let viewModel = makeViewModel()
        viewModel.newPassword = "secret"
        viewModel.confirmPassword = "secret"
        let url = try makeTemporaryFileURL(name: "NewKey.keyx", contents: Data("new-key-bytes".utf8))
        try viewModel.selectKeyFile(url: url)

        viewModel.clearSecrets()

        XCTAssertEqual(viewModel.newPassword, "")
        XCTAssertEqual(viewModel.confirmPassword, "")
        XCTAssertNil(viewModel.pickedKeyFileData)
        // Non-secret key-file metadata is intentionally left alone;
        // clearKeyFile() is the API for that.
        XCTAssertEqual(viewModel.pickedKeyFileFilename, "NewKey.keyx")
        XCTAssertNotNil(viewModel.pickedKeyFileBookmarkData)
    }

    // MARK: - Error mapping

    func testMessageMapsEveryRekeyErrorCaseToItsUserFacingText() throws {
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.sessionUnavailable),
            "The database is locked. Unlock it and try again."
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.databaseIsReadOnly),
            SaveError.databaseIsReadOnly.localizedDescription
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.saveInProgress),
            "Another save is in progress. Wait for it to finish, then try again."
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.unsavedChanges),
            "Save or discard your changes before changing the master key."
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.missingKeyComponent),
            DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.pendingUploadsExist),
            "This database has pending AutoFill changes. Let them finish syncing, then try again."
        )
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: DatabaseViewModel.RekeyError.conflict),
            "The database file changed since it was opened. Reload the database and try again."
        )
    }

    func testMessageFallsBackToLocalizedDescriptionForOtherErrors() throws {
        XCTAssertEqual(
            MasterKeyChangeViewModel.message(for: SaveError.rekeyVerificationFailed),
            SaveError.rekeyVerificationFailed.localizedDescription
        )
    }

    func testPerformChangeSurfacesMappedRekeyErrorMessage() async throws {
        let recorder = ChangeRecorder()
        recorder.error = DatabaseViewModel.RekeyError.unsavedChanges
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.newPassword = "new password"
        viewModel.confirmPassword = "new password"

        let succeeded = await viewModel.performChange()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            viewModel.changeError,
            "Save or discard your changes before changing the master key."
        )
    }
}
