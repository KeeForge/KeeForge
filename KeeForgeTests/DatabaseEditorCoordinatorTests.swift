import XCTest
@testable import KeeForge

@MainActor
final class DatabaseEditorCoordinatorTests: XCTestCase {
    func testEditorsRegisterIndependentlyAndDeactivateWithoutClearingEachOther() async throws {
        let database = try await makeDatabase()
        let groupID = try XCTUnwrap(database.rootGroup?.id)
        let firstForm = EntryEditViewModel(createIn: groupID)
        let secondForm = GroupEditViewModel(groupID: groupID, name: "Original")
        let first = DatabaseEditorCoordinator(entry: firstForm, database: database)
        let second = DatabaseEditorCoordinator(group: secondForm, database: database)
        first.activate()
        second.activate()
        XCTAssertFalse(database.hasUnsavedEditor)

        firstForm.title = "New entry"
        secondForm.name = "Changed group"
        first.synchronizeUnsavedChanges()
        second.synchronizeUnsavedChanges()
        first.deactivate()
        XCTAssertTrue(database.hasUnsavedEditor)

        second.deactivate()
        XCTAssertFalse(database.hasUnsavedEditor)
        database.lock()
    }

    func testSaveAppliesEntryAndTransfersDirtyOwnershipBeforeCompletion() async throws {
        let database = try await makeDatabase()
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Created by coordinator"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertNotNil(database.rootGroup?.allEntries.first { $0.title == form.title })
        XCTAssertFalse(database.hasUnsavedEditor)
        XCTAssertFalse(database.isDirty)
        XCTAssertFalse(editor.isSubmitting)
        database.lock()
    }

    func testApplyFailureRetainsEditorAndShowsError() async throws {
        let database = try await makeDatabase()
        let form = EntryEditViewModel(createIn: UUID())
        form.title = "Missing destination"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completed = false

        await editor.save { _ in completed = true }

        XCTAssertFalse(completed)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertTrue(database.hasUnsavedEditor)
        XCTAssertFalse(editor.isSubmitting)
        database.lock()
    }

    func testSaveFailureStaysOpenAndTransfersErrorFromDatabase() async throws {
        let database = try await makeDatabase { _, _, _, _, _, _, _ in
            throw DatabaseSaveError.networkUnavailable
        }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Unsaved on disk"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completed = false

        await editor.save { _ in completed = true }

        XCTAssertFalse(completed)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertNil(database.saveError)
        XCTAssertTrue(database.isDirty)
        XCTAssertFalse(database.hasUnsavedEditor)
        database.lock()
    }

    func testGroupConflictWaitsForSuccessfulMergeAndSummaryAcknowledgement() async throws {
        let remoteData = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        let database = try await makeDatabase { _, _, _, _, reconciledHash, _, _ in
            if let reconciledHash { return .saved(newSHA512: reconciledHash) }
            return .conflict(remoteSHA512: KDBXCrypto.sha512(remoteData), remoteData: remoteData)
        }
        let group = try XCTUnwrap(database.rootGroup?.groups.first)
        let form = GroupEditViewModel(editing: group, isHiddenFromAutoFill: false)
        form.name = "Renamed group"
        let editor = DatabaseEditorCoordinator(group: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.save { completions.append($0) }
        editor.completeAfterConflictIfSettled { completions.append($0) }
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNotNil(database.saveConflict)

        try await database.mergeAndSave()
        XCTAssertNil(database.saveConflict)
        XCTAssertNotNil(database.mergeSummaryMessage)
        editor.completeAfterConflictIfSettled { completions.append($0) }
        XCTAssertTrue(completions.isEmpty)

        database.acknowledgeMergeSummary()
        editor.completeAfterConflictIfSettled { completions.append($0) }
        editor.completeAfterConflictIfSettled { completions.append($0) }
        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.group(withID: group.id)?.name, "Renamed group")
        database.lock()
    }

    func testSuccessfulDeleteReportsDeletedAfterWrite() async throws {
        let database = try await makeDatabase()
        let entryID = try XCTUnwrap(database.rootGroup?.allEntries.first?.id)
        let editor = DatabaseEditorCoordinator(
            entry: EntryEditViewModel(mode: .edit(entryID: entryID)), database: database
        )
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.delete(sendToRecycleBin: false) { completions.append($0) }

        XCTAssertEqual(completions, [.deleted])
        XCTAssertNil(database.entry(withID: entryID))
        XCTAssertFalse(database.isDirty)
        database.lock()
    }

    func testDeleteConflictDoesNotReportCompletionAfterSessionLocks() async throws {
        let database = try await makeDatabase { _, _, _, _, _, _, _ in
            .conflict(remoteSHA512: Data([1]), remoteData: Data([2]))
        }
        let entryID = try XCTUnwrap(database.rootGroup?.allEntries.first?.id)
        let editor = DatabaseEditorCoordinator(
            entry: EntryEditViewModel(mode: .edit(entryID: entryID)), database: database
        )
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.delete(sendToRecycleBin: false) { completions.append($0) }
        XCTAssertNotNil(database.saveConflict)
        XCTAssertTrue(completions.isEmpty)
        database.lock()
        editor.completeAfterConflictIfSettled { completions.append($0) }
        XCTAssertTrue(completions.isEmpty)
    }

    func testDiscardAndLockUnregistersBeforeResumingRequest() async throws {
        let database = try await makeDatabase()
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Discard me"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        var completions: [EntryEditCompletion] = []

        editor.discard(resuming: request) { completions.append($0) }

        XCTAssertEqual(completions, [.cancelled])
        XCTAssertFalse(database.hasUnsavedEditor)
        XCTAssertNil(database.pendingLockRequest)
        guard case .locked = database.state else { return XCTFail("Discard should resume the lock") }
    }

    func testSaveAndLockFailureDefersToDraftPrompt() async throws {
        let database = try await makeDatabase { _, _, _, _, _, _, _ in
            throw DatabaseSaveError.networkUnavailable
        }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Keep in draft"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        var completions: [EntryEditCompletion] = []

        await editor.save(resuming: request) { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertTrue(database.isDirty)
        XCTAssertFalse(database.hasUnsavedEditor)
        XCTAssertEqual(database.pendingLockRequest?.reason, .draft)
        XCTAssertNotNil(database.saveError)
        database.lock()
    }

    func testSaveCompletionIsIgnoredAfterEditorDisappears() async throws {
        let action = SaveAction()
        let database = try await makeDatabase { _, _, _, hash, _, _, _ in
            await action.run()
            return .saved(newSHA512: hash)
        }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Save during close"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        action.operation = { editor.deactivate() }
        var completed = false

        await editor.save { _ in completed = true }

        XCTAssertFalse(completed)
        XCTAssertFalse(editor.isSubmitting)
        XCTAssertFalse(database.hasUnsavedEditor)
        database.lock()
    }

    func testSaveCompletionIsIgnoredAfterSessionLocksDuringWrite() async throws {
        let action = SaveAction()
        let database = try await makeDatabase { _, _, _, hash, _, _, _ in
            await action.run()
            return .saved(newSHA512: hash)
        }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Save during lock"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        action.operation = { database.lock() }
        var completed = false

        await editor.save { _ in completed = true }

        XCTAssertFalse(completed)
        XCTAssertFalse(editor.isSubmitting)
        XCTAssertNil(editor.errorMessage)
        guard case .locked = database.state else { return XCTFail("Session should remain locked") }
    }

    @MainActor
    private final class SaveAction {
        var operation: () -> Void = {}
        func run() { operation() }
    }

    private func makeDatabase(
        save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, hash, _, _, _ in
            .saved(newSHA512: hash)
        }
    ) async throws -> DatabaseViewModel {
        let fixture = KDBXTestFixture.test
        let reference = try TestDatabaseSupport.makeReference(
            for: fixture.url(in: Bundle(for: Self.self)), autoFillEnabled: false
        )
        let database = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: save,
            storedKeyPresenceCheck: { _ in false }
        )
        await database.unlock(password: fixture.password)
        _ = try XCTUnwrap(database.rootGroup, "Fixture must unlock before exercising an editor")
        return database
    }

}
