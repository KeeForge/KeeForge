#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacWorkspaceSheetsTests: XCTestCase {
    func testEverySheetEndsOnLockAndAnOldAnswerCannotActAfterUnlock() async throws {
        for kind in 0..<4 {
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
        for kind in 0..<4 {
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

    private func request(_ kind: Int, _ database: DatabaseViewModel, _ state: MacWorkspacePresentation) throws {
        switch kind {
        case 0: state.beginNewGroup(); state.newGroupName = "Unsaved"
        case 1:
            state.beginGroupEdit(groupID: try XCTUnwrap(database.visibleRootGroup?.groups.first).id, in: database)
        case 2: state.pendingMove = .entry(try XCTUnwrap(database.visibleRootGroup?.allEntries.first).id)
        default: state.isShowingDatabaseDetails = true
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
        presenter.start()
        return (presenter, database, state, window)
    }

    private func settle() async { for _ in 0..<8 { await Task { @MainActor in }.value } }
}
#endif
