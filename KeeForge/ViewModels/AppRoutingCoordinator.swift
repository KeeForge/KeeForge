import Foundation
import Observation

struct PendingTOTPEnrollment: Identifiable {
    static let lifetime: TimeInterval = 5 * 60

    let id = UUID()
    let uri: OTPAuthURI
    let createdAt: Date

    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(createdAt) > Self.lifetime
    }
}

enum TOTPEnrollmentAlert: String, Identifiable {
    case unsupportedLink
    case invalidLink
    case unlockNeeded
    case linkExpired

    var id: String { rawValue }
}

@MainActor @Observable
final class AppRoutingCoordinator {
    enum IncomingURL: Equatable {
        case database(URL)
        case enrollment(OTPAuthURI)
        case invalidEnrollment(TOTPEnrollmentAlert)
    }

    struct Session: Equatable {
        let identity: ObjectIdentifier
        let lockCycleID: Int
        let isUnlocked: Bool
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

    struct DeferredPresentation: Identifiable {
        enum Content {
            case enrollment(UUID, ObjectIdentifier)
            case alert(TOTPEnrollmentAlert)
        }

        let id = UUID()
        let content: Content
    }

    private(set) var didResolveInitialRoute = false
    var whatsNewRelease: WhatsNewRelease?
    private(set) var pendingEnrollment: PendingTOTPEnrollment?
    private(set) var presentedEnrollment: PendingTOTPEnrollment?
    var enrollmentAlert: TOTPEnrollmentAlert?
    private(set) var deferredPresentation: DeferredPresentation?
    private(set) var databaseTransition: DatabaseTransition?

    private var pendingAutoOpenReference: DatabaseReference?
    private var isLaunchPresentationPending = false
    private var session: Session?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    static func classify(_ url: URL) -> IncomingURL {
        guard OTPAuthURI.isOTPAuthURL(url) else { return .database(url) }
        do {
            return .enrollment(try OTPAuthURI(string: url.absoluteString))
        } catch OTPAuthURIError.unsupportedType {
            return .invalidEnrollment(.unsupportedLink)
        } catch {
            return .invalidEnrollment(.invalidLink)
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
            guard database.lockRequestCancellationID == transition.sourceCancellationID else {
                databaseTransition = nil
                return nil
            }
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
        whatsNewRelease = nil
        defer { pendingAutoOpenReference = nil }
        return pendingAutoOpenReference
    }

    func resumeEnrollmentAfterLaunchPresentation() {
        guard !discardExpiredEnrollment(), pendingEnrollment != nil else { return }
        if session?.isUnlocked == true {
            deferEnrollment()
        } else {
            deferAlert(.unlockNeeded)
        }
    }

    func updateSession(_ newSession: Session?) {
        guard session != newSession else { return }
        session = newSession
        if let deferredPresentation {
            switch deferredPresentation.content {
            case .enrollment:
                self.deferredPresentation = nil
            case .alert(.unlockNeeded) where newSession?.isUnlocked == true:
                self.deferredPresentation = nil
            case .alert:
                break
            }
        }
        if newSession?.isUnlocked == true {
            guard !discardExpiredEnrollment() else { return }
            deferEnrollment()
        } else if let presentedEnrollment {
            pendingEnrollment = presentedEnrollment
            self.presentedEnrollment = nil
        }
    }

    func receiveEnrollment(_ uri: OTPAuthURI) {
        deferredPresentation = nil
        enrollmentAlert = nil
        let enrollment = PendingTOTPEnrollment(uri: uri, createdAt: now())
        pendingEnrollment = nil
        if isLaunchPresentationPending {
            pendingEnrollment = enrollment
        } else if session?.isUnlocked == true {
            presentedEnrollment = enrollment
        } else {
            pendingEnrollment = enrollment
            enrollmentAlert = .unlockNeeded
        }
    }

    func enrollmentDidAppear(id: UUID, session expectedSession: Session) {
        guard session == expectedSession, presentedEnrollment?.id == id else { return }
        if pendingEnrollment?.id == id {
            pendingEnrollment = nil
        }
    }

    func cancelEnrollment(id: UUID, session expectedSession: Session?) {
        guard session == expectedSession, presentedEnrollment?.id == id else { return }
        presentedEnrollment = nil
        if pendingEnrollment?.id == id {
            pendingEnrollment = nil
        }
        deferredPresentation = nil
    }

    @discardableResult
    func discardExpiredEnrollment() -> Bool {
        guard let pendingEnrollment, pendingEnrollment.isExpired(at: now()) else { return false }
        if presentedEnrollment?.id == pendingEnrollment.id {
            presentedEnrollment = nil
        }
        self.pendingEnrollment = nil
        deferAlert(.linkExpired)
        return true
    }

    func completeDeferredPresentation(id: UUID) {
        guard let request = deferredPresentation, request.id == id else { return }
        deferredPresentation = nil
        switch request.content {
        case .enrollment(let enrollmentID, let sessionIdentity):
            guard !isLaunchPresentationPending,
                  session?.identity == sessionIdentity, session?.isUnlocked == true,
                  pendingEnrollment?.id == enrollmentID,
                  !discardExpiredEnrollment() else { return }
            presentedEnrollment = pendingEnrollment
        case .alert(let alert):
            enrollmentAlert = alert
        }
    }

    private func deferEnrollment() {
        guard !isLaunchPresentationPending, let enrollment = pendingEnrollment,
              let session, session.isUnlocked else { return }
        // Retain the parked copy until the presentation confirms it appeared.
        deferredPresentation = DeferredPresentation(content: .enrollment(enrollment.id, session.identity))
    }

    private func deferAlert(_ alert: TOTPEnrollmentAlert) {
        deferredPresentation = DeferredPresentation(content: .alert(alert))
    }
}
