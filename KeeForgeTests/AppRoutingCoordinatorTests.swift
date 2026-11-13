import OneTimeCodes
import XCTest
@testable import KeeForge

@MainActor
final class AppRoutingCoordinatorTests: XCTestCase {
    private let release = WhatsNewRelease(version: "1.0", features: [])

    func testIncomingURLClassificationKeepsInvalidEnrollmentOutOfFileImport() throws {
        let file = URL(fileURLWithPath: "/tmp/vault.kdbx")
        XCTAssertEqual(AppRoutingCoordinator.classify(file), .database(file))
        XCTAssertEqual(
            AppRoutingCoordinator.classify(try XCTUnwrap(URL(string: "otpauth://hotp/test?secret=JBSWY3DPEHPK3PXP"))),
            .invalidEnrollment(.unsupportedLink)
        )
        XCTAssertEqual(
            AppRoutingCoordinator.classify(try XCTUnwrap(URL(string: "otpauth://totp/test"))),
            .invalidEnrollment(.invalidLink)
        )
        let uri = try makeURI()
        XCTAssertEqual(AppRoutingCoordinator.classify(try XCTUnwrap(URL(string: uri.rawURI))), .enrollment(uri))
    }

    func testWhatsNewDefersQuickLaunchAndExplicitDatabaseTakesPrecedence() {
        let routing = AppRoutingCoordinator()
        let quickLaunch = reference()
        let explicit = reference()
        XCTAssertNil(routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: release, autoOpenReference: quickLaunch
        ))
        XCTAssertTrue(routing.didResolveInitialRoute)
        XCTAssertEqual(routing.whatsNewRelease?.id, release.id)
        XCTAssertNil(routing.requestDatabase(explicit))
        routing.whatsNewRelease = nil
        XCTAssertNil(routing.requestDatabase(explicit), "Wait for dismissal to complete, not just the sheet binding")
        XCTAssertEqual(routing.finishLaunchPresentation()?.id, explicit.id)
        XCTAssertNil(routing.finishLaunchPresentation())
    }

    func testInitialRouteRunsOnceAndTransitionNoticeSuppressesLaunchPresentations() {
        let routing = AppRoutingCoordinator()
        XCTAssertNil(routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: true, release: release, autoOpenReference: reference()
        ))
        XCTAssertNil(routing.whatsNewRelease)
        XCTAssertNil(routing.finishLaunchPresentation())
        XCTAssertNil(routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: nil, autoOpenReference: reference()
        ))
    }

    func testInitialRoutePreservesExistingSessionAndOpensQuickLaunchWithoutRelease() {
        let routing = AppRoutingCoordinator()
        let database = reference()
        XCTAssertNil(routing.resolveInitialRoute(
            hasActiveSession: true, showsTransitionNotice: false, release: release, autoOpenReference: database
        ))
        XCTAssertNil(routing.whatsNewRelease)
        let freshRouting = AppRoutingCoordinator()
        XCTAssertEqual(freshRouting.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: nil, autoOpenReference: database
        )?.id, database.id)
    }

    func testDatabaseTransitionWithoutASessionOpensItsRequestedDestination() {
        let routing = AppRoutingCoordinator()
        let destination = reference()

        routing.requestDatabaseTransition(to: .open(destination), from: nil)

        guard case .open(let opened)? = routing.completeDatabaseTransition(from: nil) else {
            return XCTFail("Expected the requested database")
        }
        XCTAssertEqual(opened.id, destination.id)
        XCTAssertNil(routing.databaseTransition)
    }

    func testAlreadyLockedSessionCompletesDatabaseTransition() {
        let database = DatabaseViewModel(databaseReference: reference())
        let routing = AppRoutingCoordinator()
        let destination = reference()

        routing.requestDatabaseTransition(to: .open(destination), from: database)

        XCTAssertEqual(database.state, .locked)
        guard case .open(let opened)? = routing.completeDatabaseTransition(from: database) else {
            return XCTFail("An already locked source should allow the selected destination")
        }
        XCTAssertEqual(opened.id, destination.id)
    }

    func testOpenDatabaseWaitsForDirtyEditorDiscardBeforeReplacingTheSession() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Unsaved editor"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        let store = DatabaseSessionStore()
        store.adopt(database)
        store.activeSessionID = database.databaseReference.id
        let routing = AppRoutingCoordinator()
        let destination = reference()

        routing.requestDatabaseTransition(to: .open(destination), from: store.activeSession)

        XCTAssertFalse(database.isDirty)
        XCTAssertEqual(database.state, .unlocked)
        XCTAssertEqual(database.pendingLockRequest?.reason, .openEditor)
        XCTAssertNil(routing.completeDatabaseTransition(from: store.activeSession))
        XCTAssertTrue(store.activeSession === database)
        XCTAssertEqual(store.openSessions.count, 1)
        XCTAssertNotNil(database.sessionKey)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        editor.discard(resuming: request) { _ in }

        XCTAssertEqual(database.state, .locked)
        guard case .open(let opened)? = routing.completeDatabaseTransition(from: store.activeSession) else {
            return XCTFail("Discard should resume the original open request")
        }
        XCTAssertEqual(opened.id, destination.id)
        let lockCycle = database.lockCycleID
        XCTAssertTrue(store.retire(database.databaseReference.id))
        let replacement = store.open(opened)
        store.activeSessionID = replacement.databaseReference.id

        XCTAssertEqual(database.lockCycleID, lockCycle)
        XCTAssertNil(database.sessionKey)
        XCTAssertNil(database.compositeKey)
        XCTAssertNil(database.rootGroup)
        XCTAssertNil(store.session(for: database.databaseReference.id))
        XCTAssertTrue(store.activeSession === replacement)
        XCTAssertEqual(store.openSessions.map(\.databaseReference.id), [destination.id])
        XCTAssertEqual(replacement.state, .locked)
    }

    func testCloseDatabaseWaitsForDirtyEditorSaveBeforeClosingTheSession() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Saved before closing"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        let routing = AppRoutingCoordinator()

        routing.requestDatabaseTransition(to: .close, from: database)
        XCTAssertNil(routing.completeDatabaseTransition(from: database))
        let request = try XCTUnwrap(editor.pendingLockRequest)
        await editor.save(resuming: request) { _ in }

        XCTAssertEqual(database.state, .locked)
        guard case .close? = routing.completeDatabaseTransition(from: database) else {
            return XCTFail("Save should resume the original close request")
        }
    }

    func testKeepEditingCancelsDatabaseTransitionAndLaterLockCannotReviveIt() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        let editorID = UUID()
        database.setEditorHasUnsavedChanges(true, editorID: editorID)
        let routing = AppRoutingCoordinator()
        routing.requestDatabaseTransition(to: .open(reference()), from: database)
        XCTAssertNil(routing.completeDatabaseTransition(from: database))

        await database.continueEditingAfterLockRequest()

        XCTAssertNil(routing.completeDatabaseTransition(from: database))
        XCTAssertNil(routing.databaseTransition)
        XCTAssertEqual(database.state, .unlocked)
        XCTAssertTrue(database.hasUnsavedEditor)
        database.lock()
        XCTAssertNil(routing.completeDatabaseTransition(from: database))
    }

    func testFailedSaveKeepsDatabaseTransitionPendingUntilTheDraftRetryLocks() async throws {
        let attempts = TransitionSaveAttempts()
        let routing = AppRoutingCoordinator()
        let probe = TransitionSaveProbe(routing: routing)
        let database = try await makeDatabase { _, _, _, hash, _, _, _ in
            await probe.checkTransitionDuringSave()
            return try await attempts.save(hash: hash)
        }
        defer { database.lock() }
        probe.database = database
        let form = EntryEditViewModel(createIn: try XCTUnwrap(database.rootGroup?.id))
        form.title = "Retry before opening"
        let editor = DatabaseEditorCoordinator(entry: form, database: database)
        editor.activate()
        let destination = reference()

        routing.requestDatabaseTransition(to: .open(destination), from: database)
        let request = try XCTUnwrap(editor.pendingLockRequest)
        await editor.save(resuming: request) { _ in }

        XCTAssertEqual(database.pendingLockRequest?.reason, .draft)
        XCTAssertTrue(database.isDirty)
        XCTAssertNil(routing.completeDatabaseTransition(from: database))

        await database.saveAndLockAfterLockRequest()

        guard case .open(let opened)? = routing.completeDatabaseTransition(from: database) else {
            return XCTFail("Retry should retain the original open destination")
        }
        XCTAssertEqual(opened.id, destination.id)
        let saveCount = await attempts.count
        XCTAssertEqual(saveCount, 2)
        XCTAssertTrue(probe.sawSavingWithoutLockRequest)
    }

    func testKeepEditingThenAnIndependentLockCannotCompleteTheCancelledDestination() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        database.setEditorHasUnsavedChanges(true, editorID: UUID())
        let routing = AppRoutingCoordinator()
        routing.requestDatabaseTransition(to: .open(reference()), from: database)

        await database.continueEditingAfterLockRequest()
        database.lock()

        XCTAssertNil(routing.completeDatabaseTransition(from: database))
        XCTAssertNil(routing.databaseTransition)
    }

    func testDatabaseTransitionFromAReplacedSessionCannotAffectTheNewSession() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        database.setEditorHasUnsavedChanges(true, editorID: UUID())
        let routing = AppRoutingCoordinator()
        routing.requestDatabaseTransition(to: .close, from: database)

        let replacement = DatabaseViewModel(databaseReference: reference())
        XCTAssertNil(routing.completeDatabaseTransition(from: replacement))
        XCTAssertNil(routing.databaseTransition)
        database.lock()
        XCTAssertNil(routing.completeDatabaseTransition(from: database))
    }

    func testOpeningTheActiveDatabaseKeepsItsDirtyEditorAndSession() async throws {
        let database = try await makeDatabase()
        defer { database.lock() }
        database.setEditorHasUnsavedChanges(true, editorID: UUID())
        let routing = AppRoutingCoordinator()

        routing.requestDatabaseTransition(to: .open(database.databaseReference), from: database)

        XCTAssertNil(routing.databaseTransition)
        XCTAssertNil(database.pendingLockRequest)
        XCTAssertEqual(database.state, .unlocked)
        XCTAssertTrue(database.hasUnsavedEditor)
    }

    func testEnrollmentWaitsForWhatsNewThenUnlockAndAppearance() throws {
        let owner = NSObject()
        let routing = AppRoutingCoordinator()
        _ = routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: release, autoOpenReference: nil
        )
        routing.enrollment.receiveEnrollment(try makeURI(), destination: nil)
        let enrollment = try XCTUnwrap(routing.enrollment.pendingEnrollment)
        XCTAssertNil(routing.enrollment.enrollmentAlert)
        XCTAssertNil(routing.enrollment.presentedEnrollment)
        let unlocked = session(owner)
        routing.enrollment.updateSession(unlocked)
        XCTAssertNil(routing.enrollment.deferredPresentation, "An unlock must not compete with What's New")
        _ = routing.finishLaunchPresentation()
        routing.enrollment.resumeEnrollmentAfterLaunchPresentation()
        XCTAssertNil(routing.enrollment.presentedEnrollment)
        try completeDeferred(routing.enrollment)
        XCTAssertEqual(routing.enrollment.presentedEnrollment?.id, enrollment.id)
        XCTAssertEqual(routing.enrollment.pendingEnrollment?.id, enrollment.id, "Keep the retry until the sheet appears")
        routing.enrollment.enrollmentDidAppear(id: enrollment.id, session: unlocked)
        XCTAssertNil(routing.enrollment.pendingEnrollment)
    }

    func testWhatsNewDismissalRequestsUnlockOnlyAfterDeferredPresentation() throws {
        let routing = AppRoutingCoordinator()
        _ = routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: release, autoOpenReference: nil
        )
        routing.enrollment.receiveEnrollment(try makeURI(), destination: nil)
        _ = routing.finishLaunchPresentation()
        routing.enrollment.resumeEnrollmentAfterLaunchPresentation()
        XCTAssertNil(routing.enrollment.enrollmentAlert)
        try completeDeferred(routing.enrollment)
        XCTAssertEqual(routing.enrollment.enrollmentAlert, .unlockNeeded)
        XCTAssertNotNil(routing.enrollment.pendingEnrollment)
    }

    private func completeDeferred(_ routing: TOTPEnrollmentCoordinator) throws {
        routing.completeDeferredPresentation(id: try XCTUnwrap(routing.deferredPresentation?.id))
    }

    private func session(_ owner: NSObject, databaseID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, lockCycleID: Int = 0, isUnlocked: Bool = true) -> TOTPEnrollmentCoordinator.Session {
        .init(databaseID: databaseID, identity: ObjectIdentifier(owner), lockCycleID: lockCycleID, isUnlocked: isUnlocked)
    }

    private func makeURI(account: String = "test") throws -> OTPAuthURI {
        try OTPAuthURI(string: "otpauth://totp/\(account)?secret=JBSWY3DPEHPK3PXP")
    }

    private func reference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(), nickname: nil, filename: "vault.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: Date(), colorTag: nil, legacyKeychainFilename: nil
        )
    }

    private actor TransitionSaveAttempts {
        private(set) var count = 0

        func save(hash: Data) throws -> SaveResult {
            count += 1
            if count == 1 { throw DatabaseSaveError.networkUnavailable }
            return .saved(newSHA512: hash)
        }
    }

    @MainActor
    private final class TransitionSaveProbe {
        let routing: AppRoutingCoordinator
        weak var database: DatabaseViewModel?
        var sawSavingWithoutLockRequest = false

        init(routing: AppRoutingCoordinator) {
            self.routing = routing
        }

        func checkTransitionDuringSave() {
            guard let database else { return XCTFail("Expected the source session during save") }
            XCTAssertTrue(database.isSaving)
            if database.pendingLockRequest == nil {
                sawSavingWithoutLockRequest = true
            }
            XCTAssertNil(routing.completeDatabaseTransition(from: database))
            XCTAssertNotNil(routing.databaseTransition)
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
        _ = try XCTUnwrap(database.rootGroup, "Fixture must unlock before testing a session transition")
        return database
    }
}
