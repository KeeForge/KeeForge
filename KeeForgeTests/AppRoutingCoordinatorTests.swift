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
        let routing = AppRoutingCoordinator()
        let destination = reference()

        routing.requestDatabaseTransition(to: .open(destination), from: database)

        XCTAssertFalse(database.isDirty)
        XCTAssertEqual(database.state, .unlocked)
        XCTAssertEqual(database.pendingLockRequest?.reason, .openEditor)
        XCTAssertNil(routing.completeDatabaseTransition(from: database))
        let request = try XCTUnwrap(editor.pendingLockRequest)
        editor.discard(resuming: request) { _ in }

        XCTAssertEqual(database.state, .locked)
        guard case .open(let opened)? = routing.completeDatabaseTransition(from: database) else {
            return XCTFail("Discard should resume the original open request")
        }
        XCTAssertEqual(opened.id, destination.id)
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
        routing.receiveEnrollment(try makeURI())
        let enrollment = try XCTUnwrap(routing.pendingEnrollment)
        XCTAssertNil(routing.enrollmentAlert)
        XCTAssertNil(routing.presentedEnrollment)
        let unlocked = session(owner)
        routing.updateSession(unlocked)
        XCTAssertNil(routing.deferredPresentation, "An unlock must not compete with What's New")
        _ = routing.finishLaunchPresentation()
        routing.resumeEnrollmentAfterLaunchPresentation()
        XCTAssertNil(routing.presentedEnrollment)
        try completeDeferred(routing)
        XCTAssertEqual(routing.presentedEnrollment?.id, enrollment.id)
        XCTAssertEqual(routing.pendingEnrollment?.id, enrollment.id, "Keep the retry until the sheet appears")
        routing.enrollmentDidAppear(id: enrollment.id, session: unlocked)
        XCTAssertNil(routing.pendingEnrollment)
    }

    func testWhatsNewDismissalRequestsUnlockOnlyAfterDeferredPresentation() throws {
        let routing = AppRoutingCoordinator()
        _ = routing.resolveInitialRoute(
            hasActiveSession: false, showsTransitionNotice: false, release: release, autoOpenReference: nil
        )
        routing.receiveEnrollment(try makeURI())
        _ = routing.finishLaunchPresentation()
        routing.resumeEnrollmentAfterLaunchPresentation()
        XCTAssertNil(routing.enrollmentAlert)
        try completeDeferred(routing)
        XCTAssertEqual(routing.enrollmentAlert, .unlockNeeded)
        XCTAssertNotNil(routing.pendingEnrollment)
    }

    func testLockParksTheSameEnrollmentAndStaleDismissalCannotCancelAfterReunlock() throws {
        let owner = NSObject()
        let routing = AppRoutingCoordinator()
        let firstUnlock = session(owner)
        routing.updateSession(firstUnlock)
        routing.receiveEnrollment(try makeURI())
        let enrollment = try XCTUnwrap(routing.presentedEnrollment)
        routing.enrollmentDidAppear(id: enrollment.id, session: firstUnlock)
        routing.updateSession(session(owner, lockCycleID: 1, isUnlocked: false))
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertEqual(routing.pendingEnrollment?.createdAt, enrollment.createdAt)
        let secondUnlock = session(owner, lockCycleID: 1)
        routing.updateSession(secondUnlock)
        try completeDeferred(routing)
        routing.cancelEnrollment(id: enrollment.id, session: firstUnlock)
        XCTAssertEqual(routing.presentedEnrollment?.id, enrollment.id)
        routing.cancelEnrollment(id: enrollment.id, session: secondUnlock)
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertNil(routing.pendingEnrollment)
    }

    func testSessionSwitchInvalidatesDeferredWorkAndOldSheetCallbacks() throws {
        let firstOwner = NSObject()
        let secondOwner = NSObject()
        let routing = AppRoutingCoordinator()
        routing.receiveEnrollment(try makeURI())
        let enrollment = try XCTUnwrap(routing.pendingEnrollment)
        let firstSession = session(firstOwner)
        routing.updateSession(firstSession)
        let staleRequest = try XCTUnwrap(routing.deferredPresentation?.id)
        let secondSession = session(secondOwner)
        routing.updateSession(secondSession)
        routing.completeDeferredPresentation(id: staleRequest)
        XCTAssertNil(routing.presentedEnrollment)
        try completeDeferred(routing)
        routing.enrollmentDidAppear(id: enrollment.id, session: firstSession)
        XCTAssertNotNil(routing.pendingEnrollment)
        routing.cancelEnrollment(id: enrollment.id, session: firstSession)
        XCTAssertNotNil(routing.presentedEnrollment)
        routing.enrollmentDidAppear(id: enrollment.id, session: secondSession)
        XCTAssertNil(routing.pendingEnrollment)
    }

    func testNewEnrollmentInvalidatesOlderDeferredPresentationAndCancellation() throws {
        let owner = NSObject()
        let routing = AppRoutingCoordinator()
        routing.receiveEnrollment(try makeURI())
        let oldEnrollment = try XCTUnwrap(routing.pendingEnrollment)
        let unlocked = session(owner)
        routing.updateSession(unlocked)
        let staleRequest = try XCTUnwrap(routing.deferredPresentation?.id)
        routing.receiveEnrollment(try makeURI(account: "second"))
        let newEnrollment = try XCTUnwrap(routing.presentedEnrollment)
        routing.completeDeferredPresentation(id: staleRequest)
        routing.cancelEnrollment(id: oldEnrollment.id, session: unlocked)
        XCTAssertEqual(routing.presentedEnrollment?.id, newEnrollment.id)
        XCTAssertNil(routing.pendingEnrollment)
    }

    func testExpiryAtDeferredCompletionDropsSecretAndReportsExpiration() throws {
        let owner = NSObject()
        var now = Date(timeIntervalSince1970: 100)
        let routing = AppRoutingCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI())
        routing.enrollmentAlert = nil
        now = now.addingTimeInterval(PendingTOTPEnrollment.lifetime)
        XCTAssertFalse(routing.discardExpiredEnrollment(), "Preserve the existing strict greater-than TTL boundary")
        routing.updateSession(session(owner))
        let promotion = try XCTUnwrap(routing.deferredPresentation?.id)
        now = now.addingTimeInterval(1)
        routing.completeDeferredPresentation(id: promotion)
        XCTAssertNil(routing.pendingEnrollment)
        XCTAssertNil(routing.presentedEnrollment)
        try completeDeferred(routing)
        XCTAssertEqual(routing.enrollmentAlert, .linkExpired)
    }

    func testNewEnrollmentInvalidatesDeferredExpirationAlert() throws {
        let owner = NSObject()
        var now = Date(timeIntervalSince1970: 100)
        let routing = AppRoutingCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI())
        now = now.addingTimeInterval(PendingTOTPEnrollment.lifetime + 1)
        XCTAssertTrue(routing.discardExpiredEnrollment())
        let expiredRequest = try XCTUnwrap(routing.deferredPresentation?.id)
        routing.updateSession(session(owner))
        routing.receiveEnrollment(try makeURI(account: "new"))
        routing.completeDeferredPresentation(id: expiredRequest)
        XCTAssertNil(routing.enrollmentAlert)
        XCTAssertEqual(routing.presentedEnrollment?.uri.accountName, "new")
    }

    func testSessionUnlockDoesNotLoseDeferredExpirationNotice() throws {
        let owner = NSObject()
        var now = Date(timeIntervalSince1970: 100)
        let routing = AppRoutingCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI())
        routing.enrollmentAlert = nil
        now = now.addingTimeInterval(PendingTOTPEnrollment.lifetime + 1)
        XCTAssertTrue(routing.discardExpiredEnrollment())
        routing.updateSession(session(owner))
        try completeDeferred(routing)
        XCTAssertEqual(routing.enrollmentAlert, .linkExpired)
        XCTAssertNil(routing.presentedEnrollment)
    }

    private func completeDeferred(_ routing: AppRoutingCoordinator) throws {
        routing.completeDeferredPresentation(id: try XCTUnwrap(routing.deferredPresentation?.id))
    }

    private func session(_ owner: NSObject, lockCycleID: Int = 0, isUnlocked: Bool = true) -> AppRoutingCoordinator.Session {
        .init(identity: ObjectIdentifier(owner), lockCycleID: lockCycleID, isUnlocked: isUnlocked)
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
