import Foundation
import Observation
import OneTimeCodes

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
final class TOTPEnrollmentCoordinator {
    enum LinkResult: Equatable {
        case enrollment(OTPAuthURI)
        case invalid(TOTPEnrollmentAlert)
    }

    static func parseLink(_ url: URL) -> LinkResult? {
        guard OTPAuthURI.isOTPAuthURL(url) else { return nil }
        do {
            return .enrollment(try OTPAuthURI(string: url.absoluteString))
        } catch OTPAuthURIError.unsupportedType {
            return .invalid(.unsupportedLink)
        } catch {
            return .invalid(.invalidLink)
        }
    }

    struct Session: Equatable {
        let databaseID: UUID
        let identity: ObjectIdentifier
        let lockCycleID: Int
        let isUnlocked: Bool
    }

    struct DeferredPresentation: Identifiable {
        enum Content {
            case enrollment(UUID, Session)
            case alert(TOTPEnrollmentAlert)
        }

        let id = UUID()
        let content: Content
    }

    private(set) var pendingEnrollment: PendingTOTPEnrollment?
    private(set) var presentedEnrollment: PendingTOTPEnrollment?
    var enrollmentAlert: TOTPEnrollmentAlert?
    private(set) var deferredPresentation: DeferredPresentation?
    private(set) var destination: Session?
    var destinationDatabaseID: UUID? { destination?.databaseID }
    var isLaunchPresentationPending = false
    private var session: Session?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func resumeEnrollmentAfterLaunchPresentation() {
        guard !discardExpiredEnrollment(), pendingEnrollment != nil else { return }
        if session?.isUnlocked == true {
            deferEnrollment()
        } else {
            deferAlert(.unlockNeeded)
        }
    }

    // Supply the destination's session-store lookup, never the focused window's session.
    func updateSession(_ newSession: Session?) {
        guard session != newSession else { return }
        if let destination, newSession?.databaseID != destination.databaseID || newSession?.identity != destination.identity {
            discardEnrollment()
        }
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

    func receiveEnrollment(_ uri: OTPAuthURI, destination: Session?) {
        session = destination
        self.destination = destination
        presentedEnrollment = nil
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

    func selectDestination(_ destination: Session) {
        guard self.destination == nil, pendingEnrollment != nil, !discardExpiredEnrollment() else { return }
        self.destination = destination
        updateSession(destination)
    }

    func enrollmentDidAppear(id: UUID, session expectedSession: Session) {
        guard session == expectedSession, presentedEnrollment?.id == id else { return }
        destination = expectedSession
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
        case .enrollment(let enrollmentID, let expectedSession):
            guard !isLaunchPresentationPending,
                  session == expectedSession, session?.isUnlocked == true,
                  pendingEnrollment?.id == enrollmentID,
                  !discardExpiredEnrollment() else { return }
            presentedEnrollment = pendingEnrollment
        case .alert(let alert):
            enrollmentAlert = alert
        }
    }

    func canApplyEnrollment(id: UUID, session expectedSession: Session) -> Bool {
        session == expectedSession && expectedSession.isUnlocked && presentedEnrollment?.id == id
            && (destination == nil || (destination?.databaseID == expectedSession.databaseID
                && destination?.identity == expectedSession.identity))
    }

    func discardEnrollment() {
        pendingEnrollment = nil
        presentedEnrollment = nil
        deferredPresentation = nil
        destination = nil
    }

    private func deferEnrollment() {
        guard !isLaunchPresentationPending, let enrollment = pendingEnrollment,
              let session, session.isUnlocked else { return }
        // Retain the parked copy until the presentation confirms it appeared.
        deferredPresentation = DeferredPresentation(content: .enrollment(enrollment.id, session))
    }

    private func deferAlert(_ alert: TOTPEnrollmentAlert) {
        deferredPresentation = DeferredPresentation(content: .alert(alert))
    }
}
