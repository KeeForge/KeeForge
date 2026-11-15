import Foundation
import Observation
import OneTimeCodes

@MainActor @Observable
final class AppRoutingCoordinator {
    enum IncomingURL: Equatable {
        case database(URL)
        case enrollment(OTPAuthURI)
        case invalidEnrollment(TOTPEnrollmentAlert)
    }

    enum DatabaseDestination {
        case open(DatabaseReference)
        case close
    }

    struct DatabaseTransition: Identifiable {
        let id = UUID()
        let destination: DatabaseDestination
        let sourceIdentity: ObjectIdentifier?
        let sourceLockCycle: Int?
        let sourceCancellationID: Int?
    }

    struct DatabaseTransitionState: Equatable {
        let identity: ObjectIdentifier
        let lockCycleID: Int
        let cancellationID: Int

        @MainActor init(_ database: DatabaseViewModel) {
            identity = ObjectIdentifier(database)
            lockCycleID = database.lockCycleID
            cancellationID = database.lockRequestCancellationID
        }
    }

    private(set) var didResolveInitialRoute = false
    var whatsNewRelease: WhatsNewRelease?
    let enrollment: TOTPEnrollmentCoordinator
    private(set) var databaseTransition: DatabaseTransition?

    private var pendingAutoOpenReference: DatabaseReference?
    private var isLaunchPresentationPending = false

    init() {
        enrollment = TOTPEnrollmentCoordinator()
    }

    static func classify(_ url: URL) -> IncomingURL {
        switch TOTPEnrollmentCoordinator.parseLink(url) {
        case .enrollment(let uri): .enrollment(uri)
        case .invalid(let alert): .invalidEnrollment(alert)
        case nil: .database(url)
        }
    }

    func resolveInitialRoute(
        hasActiveSession: Bool,
        showsTransitionNotice: Bool,
        release: WhatsNewRelease?,
        autoOpenReference: DatabaseReference?
    ) -> DatabaseReference? {
        guard !didResolveInitialRoute else { return nil }
        didResolveInitialRoute = true
        guard !hasActiveSession, !showsTransitionNotice else { return nil }
        if let release {
            whatsNewRelease = release
            isLaunchPresentationPending = true
            enrollment.isLaunchPresentationPending = true
            pendingAutoOpenReference = autoOpenReference
            return nil
        }
        return autoOpenReference
    }

    func requestDatabase(_ reference: DatabaseReference) -> DatabaseReference? {
        guard !isLaunchPresentationPending else {
            pendingAutoOpenReference = reference
            return nil
        }
        return reference
    }

    func requestDatabaseTransition(to destination: DatabaseDestination, from database: DatabaseViewModel?) {
        if case .open(let reference) = destination, reference.id == database?.databaseReference.id {
            return
        }
        databaseTransition = DatabaseTransition(
            destination: destination,
            sourceIdentity: database.map { ObjectIdentifier($0) },
            sourceLockCycle: database?.lockCycleID,
            sourceCancellationID: database?.lockRequestCancellationID
        )
        database?.lockForDatabaseTransition()
    }

    func completeDatabaseTransition(from database: DatabaseViewModel?) -> DatabaseDestination? {
        guard let transition = databaseTransition else { return nil }
        guard transition.sourceIdentity == database.map({ ObjectIdentifier($0) }) else {
            databaseTransition = nil
            return nil
        }
        if let database {
            // Keep Editing cancelled the source's lock, so the destination is dropped.
            guard database.lockRequestCancellationID == transition.sourceCancellationID else {
                databaseTransition = nil
                return nil
            }
            // The source has not locked yet (an editor or draft prompt is up): keep waiting.
            guard database.lockCycleID != transition.sourceLockCycle else { return nil }
            guard database.state == .locked else {
                databaseTransition = nil
                return nil
            }
        }
        databaseTransition = nil
        return transition.destination
    }

    func finishLaunchPresentation() -> DatabaseReference? {
        isLaunchPresentationPending = false
        enrollment.isLaunchPresentationPending = false
        whatsNewRelease = nil
        defer { pendingAutoOpenReference = nil }
        return pendingAutoOpenReference
    }

}
