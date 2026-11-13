import CryptoKit
import os
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseSessionStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    func testDuplicateOpenReusesSessionByIDWithoutCallingFactoryAgain() throws {
        var creations = 0
        let store = DatabaseSessionStore { reference in
            creations += 1
            return DatabaseViewModel(databaseReference: reference)
        }
        let reference = try makeReference()
        let first = store.open(reference)
        var renamed = reference
        renamed.nickname = "Renamed"

        XCTAssertTrue(store.open(renamed) === first)
        XCTAssertTrue(store.session(for: reference.id) === first)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(store.openSessions.count, 1)
    }

    func testSessionsCoexistInOpeningOrderWithExplicitActiveSelection() throws {
        let store = DatabaseSessionStore()
        let first = store.open(try makeReference())
        XCTAssertNil(store.activeSessionID)
        XCTAssertNil(store.activeSession)
        store.activeSessionID = first.databaseReference.id
        let second = store.open(try makeReference())

        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [first.databaseReference.id, second.databaseReference.id])
        XCTAssertTrue(store.activeSession === first)
        store.open(first.databaseReference)
        XCTAssertTrue(store.openSessions[0] === first)
        XCTAssertTrue(store.openSessions[1] === second)
        store.activeSessionID = second.databaseReference.id
        XCTAssertTrue(store.activeSession === second)
        store.activeSessionID = nil
        XCTAssertNil(store.activeSession)
    }

    func testAdoptionPreservesAnUnlockedSessionAndDoesNotSelectIt() async throws {
        let store = DatabaseSessionStore()
        let session = try await makeUnlockedSession()
        defer { session.lock() }

        XCTAssertTrue(store.adopt(session) === session)
        XCTAssertTrue(store.open(session.databaseReference) === session)
        store.adopt(session)
        XCTAssertEqual(store.openSessions.count, 1)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertNotNil(session.sessionKey)
        XCTAssertNil(store.activeSessionID)
    }

    func testRetiringAnAbsentSessionClearsOnlyItsExplicitSelection() {
        let store = DatabaseSessionStore()
        let id = UUID()
        store.activeSessionID = id
        XCTAssertNil(store.activeSession)

        XCTAssertTrue(store.retire(UUID()))
        XCTAssertEqual(store.activeSessionID, id)
        XCTAssertTrue(store.retire(id))
        XCTAssertNil(store.activeSessionID)
        XCTAssertTrue(store.openSessions.isEmpty)
    }

    func testRetirementLocksRemovesAndClearsActiveSelection() async throws {
        let store = DatabaseSessionStore()
        let session = try await makeUnlockedSession()
        store.adopt(session)
        let id = session.databaseReference.id
        store.activeSessionID = id

        XCTAssertTrue(store.retire(id))

        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(session.sessionKey)
        XCTAssertNil(session.compositeKey)
        XCTAssertNil(session.rootGroup)
        XCTAssertNil(store.session(for: id))
        XCTAssertTrue(store.openSessions.isEmpty)
        XCTAssertNil(store.activeSessionID)
        XCTAssertNil(store.activeSession)
        XCTAssertTrue(store.retire(id))
        let reopened = store.open(session.databaseReference)
        XCTAssertFalse(reopened === session)
        XCTAssertEqual(reopened.state, .locked)
        XCTAssertNil(store.activeSessionID)
    }

    func testRetiringOneSessionLeavesTheOtherUnlockedWithItsSessionKey() async throws {
        let store = DatabaseSessionStore()
        let first = try await makeUnlockedSession()
        let second = try await makeUnlockedSession()
        defer { first.lock(); second.lock() }
        store.adopt(first)
        store.adopt(second)
        store.activeSessionID = second.databaseReference.id
        let secondLockCycle = second.lockCycleID
        let secret = try EncryptedValue.encrypt("Other session", using: XCTUnwrap(second.sessionKey))

        XCTAssertTrue(store.retire(first.databaseReference.id))

        XCTAssertEqual(first.state, .locked)
        XCTAssertNil(first.sessionKey)
        XCTAssertTrue(store.activeSession === second)
        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [second.databaseReference.id])
        XCTAssertEqual(second.state, .unlocked)
        XCTAssertEqual(second.lockCycleID, secondLockCycle)
        XCTAssertNotNil(second.rootGroup)
        XCTAssertEqual(try secret.decrypt(using: XCTUnwrap(second.sessionKey)), "Other session")
        store.open(first.databaseReference)
        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [second.databaseReference.id, first.databaseReference.id])
    }

    func testDeferredEditorLockRetainsSessionAndSelectionUntilRetirementIsRetried() async throws {
        let store = DatabaseSessionStore()
        let session = try await makeUnlockedSession()
        defer { session.lock() }
        store.adopt(session)
        let id = session.databaseReference.id
        store.activeSessionID = id
        let editorID = UUID()
        session.setEditorHasUnsavedChanges(true, editorID: editorID)

        XCTAssertFalse(store.retire(id))
        XCTAssertTrue(store.session(for: id) === session)
        XCTAssertTrue(store.activeSession === session)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertNotNil(session.sessionKey)
        let request = try XCTUnwrap(session.pendingLockRequest)
        XCTAssertEqual(request.reason, .openEditor)
        XCTAssertTrue(request.manuallyTriggered)

        session.setEditorHasUnsavedChanges(false, editorID: editorID)
        session.resumeLockRequest(request)
        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(session.sessionKey)
        XCTAssertTrue(store.session(for: id) === session)
        XCTAssertTrue(store.retire(id))
        XCTAssertNil(store.session(for: id))
        XCTAssertNil(store.activeSessionID)
    }

    func testDeferredDraftRetirementCanBeCancelledWithoutLosingTheSession() async throws {
        let store = DatabaseSessionStore()
        let session = try await makeUnlockedSession()
        defer { session.lock() }
        store.adopt(session)
        let id = session.databaseReference.id
        store.activeSessionID = id
        let root = try XCTUnwrap(session.rootGroup)
        session.draft = try DatabaseDraft(
            rootGroup: root,
            meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
            sessionKey: XCTUnwrap(session.sessionKey)
        ).apply(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: "Unsaved", password: "secret")
        ))

        XCTAssertFalse(store.retire(id))
        XCTAssertEqual(session.pendingLockRequest?.reason, .draft)
        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.sessionKey)
        await session.continueEditingAfterLockRequest()
        XCTAssertNil(session.pendingLockRequest)
        XCTAssertTrue(store.activeSession === session)
        XCTAssertTrue(store.open(session.databaseReference) === session)
        XCTAssertEqual(session.state, .unlocked)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(store.retire(id))
        session.lockRequest(force: true, manuallyTriggered: true)
        XCTAssertTrue(store.retire(id))
        XCTAssertTrue(store.openSessions.isEmpty)
    }

    func testRetiringAnAlreadyLockedSessionDoesNotStartAnotherLockCycle() throws {
        let store = DatabaseSessionStore()
        let session = store.open(try makeReference())
        store.activeSessionID = session.databaseReference.id
        let lockCycle = session.lockCycleID

        XCTAssertTrue(store.retire(session.databaseReference.id))

        XCTAssertEqual(session.lockCycleID, lockCycle)
        XCTAssertTrue(store.openSessions.isEmpty)
        XCTAssertNil(store.activeSessionID)
    }

    func testForcedRetirementDiscardsDirtyDraftAndEditorAndClearsSecrets() async throws {
        let store = DatabaseSessionStore()
        let session = try await makeUnlockedSession()
        defer { session.lock() }
        store.adopt(session)
        let id = session.databaseReference.id
        store.activeSessionID = id
        let root = try XCTUnwrap(session.rootGroup)
        session.draft = try DatabaseDraft(
            rootGroup: root,
            meta: KPMeta(recycleBin: root.recycleBinUUID.map { .group($0) }),
            sessionKey: XCTUnwrap(session.sessionKey)
        ).apply(.createEntry(
            parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: root),
            draft: EntryDraftPayload(title: "Unsaved", password: "secret")
        ))
        session.setEditorHasUnsavedChanges(true, editorID: UUID())
        XCTAssertFalse(store.retire(id))
        XCTAssertNotNil(session.pendingLockRequest)

        XCTAssertTrue(store.retire(id, force: true))

        XCTAssertEqual(session.state, .locked)
        XCTAssertNil(session.sessionKey)
        XCTAssertNil(session.compositeKey)
        XCTAssertNil(session.rootGroup)
        XCTAssertNil(session.draft)
        XCTAssertFalse(session.hasUnsavedEditor)
        XCTAssertNil(session.pendingLockRequest)
        XCTAssertNil(store.session(for: id))
        XCTAssertTrue(store.openSessions.isEmpty)
        XCTAssertNil(store.activeSessionID)
        XCTAssertNil(store.activeSession)
        XCTAssertTrue(store.retire(id, force: true))
    }

    func testForcedRetirementLeavesAnotherSessionAndItsSelectionIntact() async throws {
        let store = DatabaseSessionStore()
        let removed = try await makeUnlockedSession()
        let active = try await makeUnlockedSession()
        defer { removed.lock(); active.lock() }
        store.adopt(removed)
        store.adopt(active)
        store.activeSessionID = active.databaseReference.id
        removed.setEditorHasUnsavedChanges(true, editorID: UUID())
        let activeLockCycle = active.lockCycleID

        XCTAssertTrue(store.retire(removed.databaseReference.id, force: true))
        XCTAssertTrue(store.retire(UUID(), force: true))

        XCTAssertNil(removed.sessionKey)
        XCTAssertTrue(store.activeSession === active)
        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [active.databaseReference.id])
        XCTAssertEqual(active.state, .unlocked)
        XCTAssertEqual(active.lockCycleID, activeLockCycle)
        XCTAssertNotNil(active.sessionKey)
    }

    func testSystemLockReachesEveryOpenSession() async throws {
        let previousLockOnBackground = SettingsService.lockOnBackground
        defer { SettingsService.lockOnBackground = previousLockOnBackground }
        #if os(macOS)
        SettingsService.lockOnBackground = false
        #else
        SettingsService.lockOnBackground = true
        #endif
        let store = DatabaseSessionStore()
        let first = try await makeUnlockedSession()
        let second = try await makeUnlockedSession()
        defer { first.lock(); second.lock() }
        store.adopt(first)
        store.adopt(second)
        store.activeSessionID = second.databaseReference.id

        store.handleAppDidEnterBackground()

        for session in [first, second] {
            XCTAssertEqual(session.state, .locked)
            XCTAssertNil(session.sessionKey)
            XCTAssertNil(session.compositeKey)
        }
        XCTAssertEqual(store.openSessions.count, 2)
        XCTAssertTrue(store.activeSession === second)
    }

    func testActivationReachesEveryOpenSession() async throws {
        let previousTimeout = SettingsService.autoLockTimeout
        defer { SettingsService.autoLockTimeout = previousTimeout }
        SettingsService.autoLockTimeout = .fiveMinutes
        let store = DatabaseSessionStore()
        let first = try await makeUnlockedSession()
        let second = try await makeUnlockedSession()
        defer { first.lock(); second.lock() }
        for session in [first, second] {
            store.adopt(session)
            session.cancelInactivityTimer()
            session.didManuallyLock = true
        }
        store.activeSessionID = second.databaseReference.id

        store.handleAppDidBecomeActive()

        for session in [first, second] {
            XCTAssertEqual(session.state, .unlocked)
            XCTAssertFalse(session.didManuallyLock)
            XCTAssertNotNil(session.inactivityTimer)
            XCTAssertNotNil(session.inactivityDeadline)
        }
    }

    func testUserActivityResetsEveryOpenSessionsInactivityDeadline() async throws {
        let previousTimeout = SettingsService.autoLockTimeout
        defer { SettingsService.autoLockTimeout = previousTimeout }
        SettingsService.autoLockTimeout = .thirtySeconds
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let store = DatabaseSessionStore()
        let first = try await makeUnlockedSession(nowProvider: { clock.withLock { $0 } })
        let second = try await makeUnlockedSession(nowProvider: { clock.withLock { $0 } })
        defer { first.lock(); second.lock() }
        store.adopt(first)
        store.adopt(second)
        store.activeSessionID = second.databaseReference.id
        XCTAssertEqual(first.inactivityDeadline, Date(timeIntervalSince1970: 1_030))
        XCTAssertEqual(second.inactivityDeadline, Date(timeIntervalSince1970: 1_030))
        clock.withLock { $0.addTimeInterval(20) }

        store.resetInactivityTimers()

        XCTAssertEqual(first.inactivityDeadline, Date(timeIntervalSince1970: 1_050))
        XCTAssertEqual(second.inactivityDeadline, Date(timeIntervalSince1970: 1_050))
        XCTAssertNotNil(first.inactivityTimer)
        XCTAssertNotNil(second.inactivityTimer)
    }

    func testDatabaseListRemovalForcesRetirementOfOnlyTheMissingSession() async throws {
        let store = DatabaseSessionStore()
        let removed = try await makeUnlockedSession()
        let retained = try await makeUnlockedSession()
        defer { removed.lock(); retained.lock() }
        store.adopt(removed)
        store.adopt(retained)
        store.activeSessionID = retained.databaseReference.id
        removed.setEditorHasUnsavedChanges(true, editorID: UUID())
        let retainedLockCycle = retained.lockCycleID

        store.retireSessionsMissingFromDatabaseList([retained.databaseReference.id])

        XCTAssertNil(store.session(for: removed.databaseReference.id))
        XCTAssertEqual(removed.state, .locked)
        XCTAssertNil(removed.sessionKey)
        XCTAssertFalse(removed.hasUnsavedEditor)
        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [retained.databaseReference.id])
        XCTAssertTrue(store.activeSession === retained)
        XCTAssertEqual(retained.state, .unlocked)
        XCTAssertEqual(retained.lockCycleID, retainedLockCycle)
        XCTAssertNotNil(retained.sessionKey)
    }

    private func makeReference() throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(
            for: KDBXTestFixture.test.url(in: Bundle(for: Self.self)),
            autoFillEnabled: false
        )
    }

    private func makeUnlockedSession(
        nowProvider: @escaping @Sendable () -> Date = { .now }
    ) async throws -> DatabaseViewModel {
        let session = DatabaseViewModel(
            databaseReference: try makeReference(),
            quickUnlockKeyPersistOperation: { _, _, _ in false },
            storedKeyPresenceCheck: { _ in false },
            nowProvider: nowProvider
        )
        await session.unlock(password: KDBXTestFixture.test.password)
        XCTAssertEqual(session.state, .unlocked)
        _ = try XCTUnwrap(session.sessionKey)
        return session
    }
}
