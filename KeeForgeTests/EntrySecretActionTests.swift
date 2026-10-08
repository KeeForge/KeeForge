import XCTest
@testable import KeeForge

@MainActor
final class EntrySecretActionTests: XCTestCase {
    func testDisclosesOnlyAfterAuthenticationCompletes() async throws {
        let action = EntrySecretAction()
        let authentication = SuspendedAuthentication()
        var disclosures = 0
        let task = try XCTUnwrap(action.perform(
            authenticate: authentication.authenticate,
            isCurrent: { true },
            disclose: { disclosures += 1 }
        ))
        await authentication.waitUntilRequested()
        XCTAssertEqual(disclosures, 0)
        XCTAssertTrue(action.isAuthenticating)

        authentication.complete()
        await task.value

        XCTAssertEqual(disclosures, 1)
        XCTAssertFalse(action.isAuthenticating)
    }

    func testInvalidationRejectsPromptThatSucceedsAfterCancellation() async throws {
        let action = EntrySecretAction()
        let authentication = SuspendedAuthentication()
        var disclosures = 0
        let task = try XCTUnwrap(action.perform(
            authenticate: authentication.authenticate,
            isCurrent: { true },
            disclose: { disclosures += 1 }
        ))
        await authentication.waitUntilRequested()

        action.invalidate()
        authentication.complete()
        await task.value

        XCTAssertEqual(disclosures, 0)
        XCTAssertFalse(action.isAuthenticating)
    }

    func testChangedSourceRejectsCompletionBeforeViewInvalidation() async throws {
        let action = EntrySecretAction()
        let authentication = SuspendedAuthentication()
        var revision = 1
        var disclosures = 0
        let task = try XCTUnwrap(action.perform(
            authenticate: authentication.authenticate,
            isCurrent: { revision == 1 },
            disclose: { disclosures += 1 }
        ))
        await authentication.waitUntilRequested()

        revision = 2
        authentication.complete()
        await task.value

        XCTAssertEqual(disclosures, 0)
        XCTAssertFalse(action.isAuthenticating)
    }

    func testDeferredLockRejectsPendingGateDisclosureAndAllowsAFreshRequest() async throws {
        let authentication = SuspendedAuthentication()
        let gate = SecretAccessGate(
            gracePeriod: { .fiveMinutes },
            isAuthenticationAvailable: { true },
            prompt: { _ in await authentication.authenticate() }
        )
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(
            databaseReference: try TestDatabaseSupport.makeReference(for: url),
            secretAccess: gate
        )
        await session.unlock(password: "testpassword123")
        defer { session.lockRequest(force: true) }
        gate.invalidate()
        let isCurrent = EntrySecretAction.currentSession(session)
        let action = EntrySecretAction()
        var disclosures = 0
        let task = try XCTUnwrap(action.perform(
            authenticate: { try await gate.authenticate(reason: "Copy password") },
            isCurrent: isCurrent,
            disclose: { disclosures += 1 }
        ))
        await authentication.waitUntilRequested()

        session.setEditorHasUnsavedChanges(true, editorID: UUID())
        session.lockRequest()
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertNotNil(session.pendingLockRequest)
        XCTAssertTrue(isCurrent(), "The unchanged session must not mask the gate's rejection")
        authentication.complete()
        await task.value

        XCTAssertEqual(disclosures, 0)
        XCTAssertFalse(action.isAuthenticating)
        XCTAssertTrue(gate.requiresAuthentication)
        let retry = try XCTUnwrap(action.perform(
            authenticate: { try await gate.authenticate(reason: "Copy password") },
            isCurrent: isCurrent,
            disclose: { disclosures += 1 }
        ))
        await authentication.waitUntilRequested()
        authentication.complete()
        await retry.value

        XCTAssertEqual(disclosures, 1)
        XCTAssertFalse(action.isAuthenticating)
        XCTAssertFalse(gate.requiresAuthentication)
    }

    func testOldCompletionDoesNotFinishReplacementAuthentication() async throws {
        let action = EntrySecretAction()
        let first = SuspendedAuthentication()
        let second = SuspendedAuthentication()
        var disclosures: [Int] = []
        let firstTask = try XCTUnwrap(action.perform(
            authenticate: first.authenticate,
            isCurrent: { true },
            disclose: { disclosures.append(1) }
        ))
        await first.waitUntilRequested()
        action.invalidate()
        let secondTask = try XCTUnwrap(action.perform(
            authenticate: second.authenticate,
            isCurrent: { true },
            disclose: { disclosures.append(2) }
        ))
        await second.waitUntilRequested()

        first.complete()
        await firstTask.value
        XCTAssertTrue(action.isAuthenticating)
        XCTAssertTrue(disclosures.isEmpty)
        second.complete()
        await secondTask.value

        XCTAssertEqual(disclosures, [2])
        XCTAssertFalse(action.isAuthenticating)
    }

    func testFailedAuthenticationAllowsFreshRequest() async throws {
        let action = EntrySecretAction()
        var disclosures = 0
        let failed = try XCTUnwrap(action.perform(
            authenticate: { throw AuthenticationError.rejected },
            isCurrent: { true },
            disclose: { disclosures += 1 }
        ))
        await failed.value
        XCTAssertEqual(disclosures, 0)
        let retry = try XCTUnwrap(action.perform(
            authenticate: {},
            isCurrent: { true },
            disclose: { disclosures += 1 }
        ))
        await retry.value

        XCTAssertEqual(disclosures, 1)
        XCTAssertFalse(action.isAuthenticating)
    }

    func testDuplicateRequestDoesNotStartAnotherAuthentication() async throws {
        let action = EntrySecretAction()
        let authentication = SuspendedAuthentication()
        let task = try XCTUnwrap(action.perform(
            authenticate: authentication.authenticate,
            isCurrent: { true },
            disclose: {}
        ))
        await authentication.waitUntilRequested()

        XCTAssertNil(action.perform(
            authenticate: { XCTFail("A duplicate request must not prompt") },
            isCurrent: { true },
            disclose: { XCTFail("A duplicate request must not disclose") }
        ))
        authentication.complete()
        await task.value
    }

    func testSessionSnapshotRejectsSelectionChangeLockAndReunlock() async throws {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url))
        await session.unlock(password: "testpassword123")
        defer { session.lockRequest(force: true) }
        let current = EntrySecretAction.currentSession(session)
        XCTAssertTrue(current())

        session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first?.id)
        XCTAssertFalse(current())
        let beforeLock = EntrySecretAction.currentSession(session)
        XCTAssertTrue(beforeLock())
        session.lockRequest(force: true)
        XCTAssertFalse(beforeLock())
        await session.unlock(password: "testpassword123")

        XCTAssertFalse(beforeLock())
        XCTAssertTrue(EntrySecretAction.currentSession(session)())
    }

    func testSessionSnapshotRejectsNavigationAndSameEntryPasswordEdit() async throws {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url))
        await session.unlock(password: "testpassword123")
        defer { session.lockRequest(force: true) }
        let entry = try XCTUnwrap(session.rootGroup?.allEntries.first)
        let beforeNavigation = EntrySecretAction.currentSession(session)

        session.workspace.navigationPath.append(.entry(entry.id))
        XCTAssertFalse(beforeNavigation())
        let beforeEdit = EntrySecretAction.currentSession(session)
        let form = EntryEditViewModel(editing: entry, sessionKey: try XCTUnwrap(session.sessionKey))
        form.password = "replacement password"
        try session.applyEntryEdit(.updateEntry(entryID: entry.id, draft: form.entryDraftPayload))

        XCTAssertFalse(beforeEdit())
        XCTAssertTrue(EntrySecretAction.currentSession(session)())
    }

    #if os(macOS)
    func testMacPasswordCommandCopiesOnlyAfterAuthenticationForCurrentSelection() async throws {
        let session = try await makeCommandSession()
        defer { session.lockRequest(force: true) }
        let entry = try XCTUnwrap(session.entry(withID: try XCTUnwrap(session.workspace.selectedEntryID)))
        let expected = session.resolvedPassword(for: entry)
        let action = EntrySecretAction()
        let authentication = SuspendedAuthentication()
        var copied: [String] = []
        let task = try XCTUnwrap(KeeForgeCommands.copySelectedEntryPassword(
            in: session,
            action: action,
            activeSession: { session },
            authenticate: authentication.authenticate,
            copy: { copied.append($0) }
        ))
        await authentication.waitUntilRequested()
        XCTAssertTrue(copied.isEmpty)

        authentication.complete()
        await task.value

        XCTAssertEqual(copied, [expected])
    }

    func testMacPasswordCommandRejectsChangedSelectionDraftLockCycleAndActiveSession() async throws {
        for change in CommandChange.allCases {
            let session = try await makeCommandSession()
            defer { session.lockRequest(force: true) }
            var activeSession: DatabaseViewModel? = session
            let action = EntrySecretAction()
            let authentication = SuspendedAuthentication()
            var copied: [String] = []
            let task = try XCTUnwrap(KeeForgeCommands.copySelectedEntryPassword(
                in: session,
                action: action,
                activeSession: { activeSession },
                authenticate: authentication.authenticate,
                copy: { copied.append($0) }
            ))
            await authentication.waitUntilRequested()

            switch change {
            case .selection:
                session.workspace.selectedEntryID = nil
            case .draft:
                let entryID = try XCTUnwrap(session.workspace.selectedEntryID)
                let entry = try XCTUnwrap(session.entry(withID: entryID))
                let form = EntryEditViewModel(editing: entry, sessionKey: try XCTUnwrap(session.sessionKey))
                form.password = "replacement password"
                try session.applyEntryEdit(.updateEntry(entryID: entryID, draft: form.entryDraftPayload))
            case .lockCycle:
                let entryID = session.workspace.selectedEntryID
                session.lockRequest(force: true)
                await session.unlock(password: "testpassword123")
                session.workspace.selectedEntryID = entryID
            case .activeSession:
                activeSession = DatabaseViewModel(databaseReference: session.databaseReference)
            }
            authentication.complete()
            await task.value

            XCTAssertTrue(copied.isEmpty, "A changed \(change) must not disclose the selected password")
            XCTAssertFalse(action.isAuthenticating)
        }
    }

    private func makeCommandSession() async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let session = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url))
        await session.unlock(password: "testpassword123")
        session.workspace.selectedEntryID = try XCTUnwrap(session.rootGroup?.allEntries.first { $0.hasPassword }).id
        return session
    }

    private enum CommandChange: CaseIterable {
        case selection, draft, lockCycle, activeSession
    }
    #endif

    private enum AuthenticationError: Error {
        case rejected
    }

    @MainActor
    private final class SuspendedAuthentication {
        private var completion: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func authenticate() async {
            await withCheckedContinuation { continuation in
                completion = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilRequested() async {
            guard completion == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func complete() {
            completion?.resume()
            completion = nil
        }
    }
}
