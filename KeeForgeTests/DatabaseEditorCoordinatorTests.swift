import XCTest
@testable import KeeForge

@MainActor
final class DatabaseEditorCoordinatorTests: XCTestCase {
    func testInvalidNotesKeepFormOpenAndCorrectionCreatesOnlyOneEntry() async throws {
        let database = try await makeDatabase()
        let root = try XCTUnwrap(database.rootGroup)
        let initialCount = root.allEntries.count
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Correctable Notes"
        form.notes = "Example heading\u{0}\r\nExample body"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.save { completions.append($0) }

        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(editor.errorMessage?.contains("U+0000") == true)
        XCTAssertEqual(form.notes, "Example heading\u{0}\r\nExample body")
        XCTAssertTrue(database.hasUnsavedEditor)
        XCTAssertNil(database.draft)
        XCTAssertEqual(database.rootGroup?.allEntries.count, initialCount)

        form.notes = "Example heading\nExample body"
        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertFalse(database.isDirty)
        XCTAssertEqual(database.rootGroup?.allEntries.count, initialCount + 1)
        let entry = try XCTUnwrap(database.rootGroup?.allEntries.first { $0.title == form.title })
        XCTAssertEqual(entry.notes, form.notes)
        XCTAssertTrue(entry.history.isEmpty)
        database.lock()
    }

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
        XCTAssertTrue(database.hasUnsavedEditor)
        database.lock()
    }

    func testFailedCreateThenFurtherEditsSaveTheLatestFieldsBeforeLocking() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Staged create before failure"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("First write should fail") }
        XCTAssertTrue(database.hasUnsavedEditor)

        form.title = "Latest create before lock"
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        XCTAssertEqual(request.reason, .openEditor)
        var completions: [EntryEditCompletion] = []
        await editor.save(resuming: request) { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.state, .locked)
        let titles = await attempts.writtenTitles
        XCTAssertEqual(titles.filter { $0 == form.title }.count, 1)
        XCTAssertFalse(titles.contains("Staged create before failure"))
    }

    func testFailedEntryUpdateThenFurtherEditsSaveTheLatestFieldsBeforeLocking() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let form = EntryEditViewModel(
            editing: try XCTUnwrap(database.rootGroup?.allEntries.first),
            sessionKey: try XCTUnwrap(database.sessionKey)
        )
        form.title = "Staged update before failure"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("First write should fail") }
        XCTAssertTrue(database.hasUnsavedEditor)

        form.title = "Latest update before lock"
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        var completions: [EntryEditCompletion] = []
        await editor.save(resuming: request) { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.state, .locked)
        let titles = await attempts.writtenTitles
        XCTAssertTrue(titles.contains(form.title))
        XCTAssertFalse(titles.contains("Staged update before failure"))
    }

    func testFailedGroupUpdateThenFurtherEditsSaveTheLatestFieldsBeforeLocking() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let form = GroupEditViewModel(
            editing: try XCTUnwrap(database.rootGroup?.groups.first), isHiddenFromAutoFill: false
        )
        form.name = "Staged group before failure"
        let editor = DatabaseEditorCoordinator(group: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("First write should fail") }
        XCTAssertTrue(database.hasUnsavedEditor)

        form.name = "Latest group before lock"
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        var completions: [EntryEditCompletion] = []
        await editor.save(resuming: request) { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.state, .locked)
        let names = await attempts.writtenGroupNames
        XCTAssertTrue(names.contains(form.name))
        XCTAssertFalse(names.contains("Staged group before failure"))
    }

    func testCreateConflictKeepsTheOpenEditorRegisteredForFurtherEditsAndLock() async throws {
        let attempts = SaveAttempts(conflicts: true)
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Staged conflict"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("Conflict must hold completion") }
        XCTAssertTrue(database.hasUnsavedEditor)

        form.title = "Latest fields after conflict"
        database.lockRequest(manuallyTriggered: true)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        await editor.save(resuming: request) { _ in }

        XCTAssertEqual(database.state, .locked)
        let titles = await attempts.writtenTitles
        XCTAssertTrue(titles.contains(form.title))
        XCTAssertFalse(titles.contains("Staged conflict"))
    }

    func testCreateRetryAfterWriteFailureKeepsOneEntryAndDoesNotAddHistory() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let originalCount = try XCTUnwrap(database.rootGroup).allEntries.count
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Retry unchanged creation"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.save { completions.append($0) }
        let staged = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title })
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNotNil(editor.errorMessage)

        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.rootGroup?.allEntries.count, originalCount + 1)
        XCTAssertEqual(database.entry(withID: staged.id)?.title, form.title)
        XCTAssertTrue(try XCTUnwrap(database.entry(withID: staged.id)).history.isEmpty)
        let editCounts = await attempts.editCounts
        XCTAssertEqual(editCounts, [1, 1])
        XCTAssertNil(editor.errorMessage)
        XCTAssertFalse(database.isDirty)
    }

    func testCreateRetryUpdatesFieldsDestinationAndRemovedAttachmentsOnTheSameEntry() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let destination = try XCTUnwrap(root.groups.first)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "First attempt"
        form.password = "first-password"
        form.addAttachment(named: "remove.txt", data: Data("temporary".utf8))
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []

        await editor.save { completions.append($0) }
        let entryID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)
        form.title = "Edited retry"
        form.password = "retry-password"
        form.username = "retry-user"
        form.pendingTagText = "retry-tag"
        form.removeAttachment(id: try XCTUnwrap(form.attachments.first?.id))
        form.setCreateDestination(to: destination.id, inheritedTags: [])
        await editor.save { completions.append($0) }

        let entry = try XCTUnwrap(database.entry(withID: entryID))
        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
        XCTAssertTrue(try XCTUnwrap(database.group(withID: destination.id)).entries.contains { $0.id == entryID })
        XCTAssertEqual(entry.title, "Edited retry")
        XCTAssertEqual(entry.username, "retry-user")
        XCTAssertEqual(entry.tags, ["retry-tag"])
        XCTAssertEqual(try entry.password.decrypt(using: XCTUnwrap(database.sessionKey)), "retry-password")
        XCTAssertTrue(entry.attachments.isEmpty)
    }

    func testCreateRetryStagesFreshEntryAfterItsDraftWasDiscarded() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Discarded staging"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("First write should fail") }
        let discardedID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)

        database.discardDraft()
        form.title = "Fresh retry"
        var completions: [EntryEditCompletion] = []
        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertNil(database.entry(withID: discardedID))
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
        XCTAssertNotNil(database.rootGroup?.allEntries.first { $0.title == form.title })
    }

    func testCreateConflictRetryKeepsTheStagedIdentity() async throws {
        let attempts = SaveAttempts(conflicts: true)
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Conflicted creation"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        var completions: [EntryEditCompletion] = []
        await editor.save { completions.append($0) }
        let entryID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)
        XCTAssertNotNil(database.saveConflict)
        XCTAssertTrue(completions.isEmpty)

        form.title = "Retry after conflict"
        await editor.save { completions.append($0) }
        editor.completeAfterConflictIfSettled { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertNil(database.saveConflict)
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
        XCTAssertEqual(database.entry(withID: entryID)?.title, form.title)
    }

    func testCreateRetryAfterConflictReloadReplacesTheDiscardedIdentity() async throws {
        let attempts = SaveAttempts(conflicts: true)
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Reloaded creation"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("Conflict must hold completion") }
        let discardedID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)

        try await database.reloadDiscardingDraft()
        XCTAssertNil(database.entry(withID: discardedID))
        form.title = "Created after reload"
        var completions: [EntryEditCompletion] = []
        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertNil(database.entry(withID: discardedID))
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
        XCTAssertNotNil(database.rootGroup?.allEntries.first { $0.title == form.title })
    }

    func testCreateRetryRefusesVanishedDestinationWithoutLosingItsStagedEntry() async throws {
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Keep staged identity"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("First write should fail") }
        let stagedID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)
        form.setCreateDestination(to: UUID(), inheritedTags: [])

        await editor.save { _ in XCTFail("Missing destination must not complete") }

        XCTAssertNotNil(editor.errorMessage)
        XCTAssertNotNil(database.entry(withID: stagedID))
        XCTAssertEqual(database.draft?.pendingEdits.count, 1)
        let editCounts = await attempts.editCounts
        XCTAssertEqual(editCounts, [1])
        form.setCreateDestination(to: root.id, inheritedTags: [])
        await editor.save { _ in }
        XCTAssertEqual(database.entry(withID: stagedID)?.title, form.title)
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
    }

    func testDiscardAfterCreateWriteFailureLeavesTheDatabaseDraftAndStopsEditorRetries() async throws {
        let database = try await makeDatabase { _, _, _, _, _, _, _ in
            throw DatabaseSaveError.networkUnavailable
        }
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Database owns the failed write"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("Write should fail") }
        let stagedID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)
        var completions: [EntryEditCompletion] = []

        editor.discard { completions.append($0) }
        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.cancelled])
        XCTAssertTrue(database.isDirty)
        XCTAssertNotNil(database.entry(withID: stagedID))
        XCTAssertEqual(database.draft?.pendingEdits.count, 1)
        XCTAssertFalse(database.hasUnsavedEditor)
    }

    func testReactivatedEditorRetriesTheSameCreationAndIgnoresPriorLifetimeCompletion() async throws {
        let action = SaveAction()
        let attempts = SaveAttempts()
        let database = try await makeDatabase { draft, _, _, hash, _, _, _ in
            await action.run()
            return try await attempts.save(draft: draft, hash: hash)
        }
        defer { database.lock() }
        let root = try XCTUnwrap(database.rootGroup)
        let form = EntryEditViewModel(createIn: root.id)
        form.title = "Reactivated creation"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        action.operation = {
            editor.deactivate()
            editor.activate()
        }
        var completions: [EntryEditCompletion] = []
        await editor.save { completions.append($0) }
        let stagedID = try XCTUnwrap(database.currentRootGroup?.allEntries.first { $0.title == form.title }?.id)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNil(editor.errorMessage)

        action.operation = {}
        await editor.save { completions.append($0) }

        XCTAssertEqual(completions, [.saved])
        XCTAssertEqual(database.rootGroup?.allEntries.count, root.allEntries.count + 1)
        XCTAssertEqual(database.entry(withID: stagedID)?.title, form.title)
    }

    func testOldActiveEditorCannotStageItsCreationAfterSessionLocksAndUnlocks() async throws {
        let database = try await makeDatabase { _, _, _, _, _, _, _ in
            throw DatabaseSaveError.networkUnavailable
        }
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Stale creation"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        await editor.save { _ in XCTFail("Write should fail") }
        database.lock()
        await database.unlock(password: KDBXTestFixture.test.password)

        await editor.save { _ in XCTFail("Old editor must not complete in another session") }

        XCTAssertFalse(database.isDirty)
        XCTAssertNil(database.currentRootGroup?.allEntries.first { $0.title == form.title })
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

    private actor SaveAttempts {
        let conflicts: Bool
        private(set) var editCounts: [Int] = []
        private(set) var writtenTitles: [String] = []
        private(set) var writtenGroupNames: [String] = []

        init(conflicts: Bool = false) { self.conflicts = conflicts }

        func save(draft: DatabaseDraft, hash: Data) throws -> SaveResult {
            editCounts.append(draft.pendingEdits.count)
            if editCounts.count == 1 {
                if conflicts { return .conflict(remoteSHA512: Data([1]), remoteData: Data([2])) }
                throw DatabaseSaveError.networkUnavailable
            }
            writtenTitles = draft.rootGroup.allEntries.map(\.title)
            writtenGroupNames = draft.rootGroup.groups.map(\.name)
            return .saved(newSHA512: hash)
        }
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
