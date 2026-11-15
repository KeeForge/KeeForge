#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceSheetsTests: XCTestCase {
    func testEverySheetEndsOnLockAndAnOldAnswerCannotActAfterUnlock() async throws {
        for kind in 0..<5 {
            let (presenter, database, state, _) = try await makePresenter()
            try request(kind, database, state)
            await settle()
            let shell = try XCTUnwrap(presenter.sheet)
            XCTAssertTrue(shell.isPresented)
            database.lockRequest(force: true)
            await settle()
            XCTAssertNil(presenter.sheet)
            XCTAssertFalse(shell.isPresented)
            XCTAssertNil(state.groupEditor)
            XCTAssertNil(state.pendingMove)
            XCTAssertFalse(state.passwordImport)
            XCTAssertFalse(state.isShowingDatabaseDetails)
            XCTAssertFalse(state.isShowingNewGroupSheet)
            XCTAssertEqual(state.newGroupName, "")
            await database.unlock(password: "testpassword123")
            state.beginNewGroup()
            await settle()
            let next = try XCTUnwrap(presenter.sheet)
            shell.performDefault()
            shell.performCancel()
            await settle()
            XCTAssertTrue(presenter.sheet === next)
            XCTAssertFalse(database.isDirty)
            presenter.invalidate()
            database.lockRequest(force: true)
        }
    }

    func testEndClearsStateAndQueuedSheetFollows() async throws {
        let (presenter, database, state, _) = try await makePresenter()
        defer { presenter.invalidate(); database.lockRequest(force: true) }
        state.beginNewGroup()
        state.isShowingDatabaseDetails = true
        await settle()
        let first = try XCTUnwrap(presenter.sheet)
        first.end()
        await settle()
        XCTAssertFalse(state.isShowingNewGroupSheet)
        XCTAssertNotNil(presenter.sheet)
        XCTAssertFalse(presenter.sheet === first)
        presenter.sheet?.end()
        await settle()
        XCTAssertFalse(state.isShowingDatabaseDetails)
        XCTAssertNil(presenter.sheet)
    }

    func testInvalidationCancelsEverySheetAndLockedWindowRejectsNewRequests() async throws {
        for kind in 0..<5 {
            let (presenter, database, state, _) = try await makePresenter()
            try request(kind, database, state)
            await settle()
            let shell = try XCTUnwrap(presenter.sheet)
            presenter.invalidate()
            XCTAssertFalse(shell.isPresented)
            XCTAssertNil(presenter.sheet)
            XCTAssertFalse(state.isShowingNewGroupSheet)
            XCTAssertNil(state.groupEditor)
            XCTAssertNil(state.pendingMove)
            XCTAssertFalse(state.passwordImport)
            XCTAssertFalse(state.isShowingDatabaseDetails)
            database.lockRequest(force: true)
        }
        let (presenter, database, state, _) = try await makePresenter()
        database.lockRequest(force: true)
        await settle()
        state.beginNewGroup()
        await settle()
        XCTAssertNil(presenter.sheet)
        XCTAssertFalse(state.isShowingNewGroupSheet)
        presenter.invalidate()
    }

    func testLockEndsSheetWithoutCancellingAnInFlightSave() async throws {
        let gate = SaveGate()
        let (presenter, database, state, _) = try await makePresenter(save: { _, _, _, _, _, _, _ in
            await gate.signalStarted()
            await gate.waitUntilOpen()
            return .saved(newSHA512: Data([1]))
        })
        try database.createGroup(named: "Saved", in: try XCTUnwrap(database.visibleRootGroupID))
        let save = Task { await database.saveHandlingError() }
        await gate.waitUntilStarted()
        state.isShowingDatabaseDetails = true
        await settle()
        let shell = try XCTUnwrap(presenter.sheet)
        XCTAssertTrue(shell.isBusy)
        database.lockRequest(force: true)
        await settle()
        XCTAssertFalse(shell.isPresented)
        XCTAssertTrue(database.isSaving)
        await gate.open()
        await save.value
        XCTAssertFalse(database.isSaving)
        presenter.invalidate()
    }

    func testGroupParentPickerStacksAndChangesOnlyTheFormThenLockClearsBoth() async throws {
        let (presenter, database, state, _) = try await makePresenter()
        let root = try XCTUnwrap(database.visibleRootGroup)
        let group = try XCTUnwrap(root.groups.first)
        state.beginGroupEdit(groupID: group.id, in: database)
        await settle()
        let editorSheet = try XCTUnwrap(presenter.sheet)
        presenter.chooseGroupParent()
        let child = try XCTUnwrap(presenter.childSheet)
        let picker = try XCTUnwrap(child.bodyController as? MacGroupPickerSheet)
        let destination = try XCTUnwrap(picker.model.rows.first { $0.isSelectable })
        picker.model.selection = destination.id
        child.canConfirm = picker.model.canConfirm
        child.performDefault()
        await settle()
        XCTAssertTrue(presenter.sheet === editorSheet)
        XCTAssertNil(presenter.childSheet)
        XCTAssertEqual(state.groupEditor?.parentGroupID, destination.id)
        XCTAssertFalse(database.isDirty)
        presenter.chooseGroupParent()
        let repick = try XCTUnwrap(presenter.childSheet)
        let repicker = try XCTUnwrap(repick.bodyController as? MacGroupPickerSheet)
        XCTAssertTrue(repicker.model.rows.first { $0.id == destination.id }?.isCurrent == true)
        repick.performCancel()
        await settle()
        XCTAssertEqual(state.groupEditor?.parentGroupID, destination.id)
        presenter.chooseGroupIcon()
        let icon = try XCTUnwrap(presenter.childSheet)
        database.lockRequest(force: true)
        await settle()
        XCTAssertNil(presenter.childSheet)
        XCTAssertFalse(icon.isPresented)
        XCTAssertFalse(editorSheet.isPresented)
        XCTAssertNil(state.groupEditor)
        XCTAssertFalse(database.hasUnsavedEditor)
        presenter.invalidate()
    }

    func testEntryIconCancelAndLockClearRequestWithoutWriting() async throws {
        let (presenter, database, state, _) = try await makePresenter()
        defer { presenter.invalidate(); database.lockRequest(force: true) }
        let entry = try XCTUnwrap(database.visibleRootGroup?.allEntries.first)
        state.entryIconID = entry.id
        await settle()
        let shell = try XCTUnwrap(presenter.sheet)
        XCTAssertEqual(shell.defaultButton.accessibilityIdentifier(), "icon-picker.use")
        shell.performCancel()
        await settle()
        XCTAssertNil(state.entryIconID)
        XCTAssertFalse(database.isDirty)
        state.entryIconID = entry.id
        await settle()
        let lockedSheet = try XCTUnwrap(presenter.sheet)
        database.lockRequest(force: true)
        await settle()
        XCTAssertFalse(lockedSheet.isPresented)
        XCTAssertNil(state.entryIconID)
    }

    func testLockWithCleanGroupAndOpenPickerEndsBothWithoutAWrite() async throws {
        let (presenter, database, state, _) = try await makePresenter()
        let group = try XCTUnwrap(database.visibleRootGroup?.groups.first)
        state.beginGroupEdit(groupID: group.id, in: database)
        await settle()
        let editor = try XCTUnwrap(presenter.sheet)
        presenter.chooseGroupIcon()
        let child = try XCTUnwrap(presenter.childSheet)
        XCTAssertTrue(database.hasUnsavedEditor)
        database.lockRequest(manuallyTriggered: false)
        await settle()
        XCTAssertEqual(database.state, .locked)
        XCTAssertFalse(editor.isPresented)
        XCTAssertFalse(child.isPresented)
        XCTAssertNil(state.groupEditor)
        XCTAssertFalse(database.hasUnsavedEditor)
        presenter.invalidate()
    }

    func testDirtyGroupLockUsesNativePromptAndDiscardLocksWithoutSaving() async throws {
        let (presenter, database, state, _) = try await makePresenter()
        let group = try XCTUnwrap(database.visibleRootGroup?.groups.first)
        var answer: (@MainActor (NSApplication.ModalResponse) -> Void)?
        presenter.groupLockPrompt.present = { _, _, response in answer = response }
        state.beginGroupEdit(groupID: group.id, in: database)
        await settle()
        let form = try XCTUnwrap(state.groupEditor)
        form.name = "Unsaved group"
        presenter.chooseGroupIcon()
        database.lockRequest(manuallyTriggered: true)
        await settle()
        XCTAssertNil(presenter.childSheet)
        let alert = try XCTUnwrap(presenter.groupLockPrompt.alert)
        XCTAssertEqual(alert.messageText, String(localized: "Save your changes before locking?"))
        XCTAssertEqual(alert.buttons.map(\.title), [String(localized: "Save and Lock"), String(localized: "Discard and Lock"), String(localized: "Keep Editing")])
        XCTAssertTrue(alert.buttons[0].isEnabled)
        answer?(.alertSecondButtonReturn)
        await settle()
        XCTAssertEqual(database.state, .locked)
        XCTAssertNil(state.groupEditor)
        XCTAssertNil(presenter.groupLockPrompt.alert)
        XCTAssertFalse(database.hasUnsavedEditor)
        presenter.invalidate()
    }

    private func request(_ kind: Int, _ database: DatabaseViewModel, _ state: MacWorkspacePresentation) throws {
        switch kind {
        case 0: state.beginNewGroup(); state.newGroupName = "Unsaved"
        case 1:
            state.beginGroupEdit(groupID: try XCTUnwrap(database.visibleRootGroup?.groups.first).id, in: database)
        case 2: state.pendingMove = .entry(try XCTUnwrap(database.visibleRootGroup?.allEntries.first).id)
        case 3: state.isShowingDatabaseDetails = true
        default: state.passwordImport = true
        }
    }

    private func makePresenter(save: @escaping DatabaseViewModel.LocalSaveOperation = { _, _, _, _, _, _, _ in
        throw SaveError.saveContextUnavailable
    }) async throws -> (MacWorkspaceSheets, DatabaseViewModel, MacWorkspacePresentation, NSWindow) {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let database = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false),
            localSaveOperation: save, quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await database.unlock(password: "testpassword123")
        let state = MacWorkspacePresentation()
        let window = NSWindow()
        let presenter = MacWorkspaceSheets(session: database, presentation: state) { window }
        presenter.present = { shell, parent, completion in
            shell.presentWindow = { _, _, _ in }
            shell.begin(on: parent, completion: completion)
        }
        presenter.groupLockPrompt.present = { _, _, _ in }
        presenter.start()
        return (presenter, database, state, window)
    }

    private func settle() async { for _ in 0..<8 { await Task { @MainActor in }.value } }
}
#endif
