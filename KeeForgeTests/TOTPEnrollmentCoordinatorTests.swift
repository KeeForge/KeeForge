import OneTimeCodes
import XCTest
@testable import KeeForge

@MainActor
final class TOTPEnrollmentCoordinatorTests: XCTestCase {
    func testLockParksTheSameEnrollmentAndStaleDismissalCannotCancelAfterReunlock() throws {
        let owner = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        let firstUnlock = session(owner)
        routing.updateSession(firstUnlock)
        routing.receiveEnrollment(try makeURI(), destination: firstUnlock)
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
        let routing = TOTPEnrollmentCoordinator()
        routing.receiveEnrollment(try makeURI(), destination: nil)
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
        let routing = TOTPEnrollmentCoordinator()
        routing.receiveEnrollment(try makeURI(), destination: nil)
        let oldEnrollment = try XCTUnwrap(routing.pendingEnrollment)
        let unlocked = session(owner)
        routing.updateSession(unlocked)
        let staleRequest = try XCTUnwrap(routing.deferredPresentation?.id)
        routing.receiveEnrollment(try makeURI(account: "second"), destination: unlocked)
        let newEnrollment = try XCTUnwrap(routing.presentedEnrollment)
        routing.completeDeferredPresentation(id: staleRequest)
        routing.cancelEnrollment(id: oldEnrollment.id, session: unlocked)
        XCTAssertEqual(routing.presentedEnrollment?.id, newEnrollment.id)
        XCTAssertNil(routing.pendingEnrollment)
    }

    func testExpiryAtDeferredCompletionDropsSecretAndReportsExpiration() throws {
        let owner = NSObject()
        var now = Date(timeIntervalSince1970: 100)
        let routing = TOTPEnrollmentCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI(), destination: nil)
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
        let routing = TOTPEnrollmentCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI(), destination: nil)
        now = now.addingTimeInterval(PendingTOTPEnrollment.lifetime + 1)
        XCTAssertTrue(routing.discardExpiredEnrollment())
        let expiredRequest = try XCTUnwrap(routing.deferredPresentation?.id)
        routing.updateSession(session(owner))
        routing.receiveEnrollment(try makeURI(account: "new"), destination: session(owner))
        routing.completeDeferredPresentation(id: expiredRequest)
        XCTAssertNil(routing.enrollmentAlert)
        XCTAssertEqual(routing.presentedEnrollment?.uri.accountName, "new")
    }

    func testSessionUnlockDoesNotLoseDeferredExpirationNotice() throws {
        let owner = NSObject()
        var now = Date(timeIntervalSince1970: 100)
        let routing = TOTPEnrollmentCoordinator(now: { now })
        routing.receiveEnrollment(try makeURI(), destination: nil)
        routing.enrollmentAlert = nil
        now = now.addingTimeInterval(PendingTOTPEnrollment.lifetime + 1)
        XCTAssertTrue(routing.discardExpiredEnrollment())
        routing.updateSession(session(owner))
        try completeDeferred(routing)
        XCTAssertEqual(routing.enrollmentAlert, .linkExpired)
        XCTAssertNil(routing.presentedEnrollment)
    }

    func testMissingDestinationParksUntilExplicitSelectionAndNeverUsesAnotherSession() throws {
        let owner = NSObject(), other = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        routing.receiveEnrollment(try makeURI(), destination: nil)
        let enrollment = try XCTUnwrap(routing.pendingEnrollment)
        XCTAssertNil(routing.destinationDatabaseID)
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertFalse(routing.canApplyEnrollment(id: enrollment.id, session: session(other)))
        let chosen = session(owner, databaseID: UUID())
        routing.selectDestination(chosen)
        XCTAssertEqual(routing.destinationDatabaseID, chosen.databaseID)
        try completeDeferred(routing)
        XCTAssertTrue(routing.canApplyEnrollment(id: enrollment.id, session: chosen))
        XCTAssertFalse(routing.canApplyEnrollment(id: enrollment.id, session: session(other)))
    }

    func testBoundDestinationReplacementDiscardsInsteadOfRetargeting() throws {
        let owner = NSObject(), replacement = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        let original = session(owner)
        routing.receiveEnrollment(try makeURI(), destination: original)
        let enrollment = try XCTUnwrap(routing.presentedEnrollment)
        let replaced = session(replacement)
        routing.updateSession(replaced)
        XCTAssertNil(routing.pendingEnrollment)
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertNil(routing.deferredPresentation)
        XCTAssertFalse(routing.canApplyEnrollment(id: enrollment.id, session: replaced))
    }

    func testRetiredDestinationCannotReviveOnReopeningTheSameDatabase() throws {
        let owner = NSObject(), reopened = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        let locked = session(owner, isUnlocked: false)
        routing.receiveEnrollment(try makeURI(), destination: locked)
        let enrollment = try XCTUnwrap(routing.pendingEnrollment)
        routing.updateSession(nil)
        XCTAssertNil(routing.pendingEnrollment)
        routing.updateSession(session(reopened))
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertNil(routing.deferredPresentation)
        XCTAssertFalse(routing.canApplyEnrollment(id: enrollment.id, session: session(reopened)))
    }

    func testDismissedPresentationDoesNotReturnOnLaterUnlock() throws {
        let owner = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        let unlocked = session(owner)
        routing.receiveEnrollment(try makeURI(), destination: unlocked)
        let enrollment = try XCTUnwrap(routing.presentedEnrollment)
        routing.enrollmentDidAppear(id: enrollment.id, session: unlocked)
        routing.cancelEnrollment(id: enrollment.id, session: unlocked)
        routing.updateSession(session(owner, lockCycleID: 1, isUnlocked: false))
        routing.updateSession(session(owner, lockCycleID: 1))
        XCTAssertNil(routing.pendingEnrollment)
        XCTAssertNil(routing.presentedEnrollment)
        XCTAssertNil(routing.deferredPresentation)
    }

    func testLockCycleChangeInvalidatesDeferredCompletionAndApplication() throws {
        let owner = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        routing.receiveEnrollment(try makeURI(), destination: session(owner, isUnlocked: false))
        let enrollment = try XCTUnwrap(routing.pendingEnrollment)
        let original = session(owner)
        routing.updateSession(original)
        let stale = try XCTUnwrap(routing.deferredPresentation?.id)
        routing.updateSession(session(owner, lockCycleID: 1, isUnlocked: false))
        let reopened = session(owner, lockCycleID: 1)
        routing.updateSession(reopened)
        routing.completeDeferredPresentation(id: stale)
        XCTAssertNil(routing.presentedEnrollment)
        try completeDeferred(routing)
        XCTAssertTrue(routing.canApplyEnrollment(id: enrollment.id, session: reopened))
        XCTAssertFalse(routing.canApplyEnrollment(id: enrollment.id, session: original))
    }

    func testDifferentDatabaseIDCannotReuseDestinationIdentity() throws {
        let owner = NSObject()
        let routing = TOTPEnrollmentCoordinator()
        routing.receiveEnrollment(try makeURI(), destination: session(owner))
        routing.updateSession(session(owner, databaseID: UUID()))
        XCTAssertNil(routing.pendingEnrollment)
        XCTAssertNil(routing.presentedEnrollment)
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

}
