import Foundation
import Observation

@MainActor @Observable
final class DatabaseSessionStore {
    private var sessionsByID: [UUID: DatabaseViewModel] = [:]
    private var openingOrder: [UUID] = []
    var activeSessionID: UUID?

    @ObservationIgnored private let makeSession: @MainActor (DatabaseReference) -> DatabaseViewModel

    init(
        makeSession: @escaping @MainActor (DatabaseReference) -> DatabaseViewModel = {
            DatabaseViewModel(databaseReference: $0)
        }
    ) {
        self.makeSession = makeSession
    }

    var activeSession: DatabaseViewModel? {
        activeSessionID.flatMap { sessionsByID[$0] }
    }

    var openSessions: [DatabaseViewModel] {
        openingOrder.compactMap { sessionsByID[$0] }
    }

    func session(for id: UUID) -> DatabaseViewModel? {
        sessionsByID[id]
    }

    @discardableResult
    func open(_ reference: DatabaseReference) -> DatabaseViewModel {
        if let session = sessionsByID[reference.id] { return session }
        return adopt(makeSession(reference))
    }

    // Adoption must not replace a different live session for the same database.
    @discardableResult
    func adopt(_ session: DatabaseViewModel) -> DatabaseViewModel {
        let id = session.databaseReference.id
        precondition(sessionsByID[id] == nil || sessionsByID[id] === session)
        if sessionsByID[id] == nil {
            sessionsByID[id] = session
            openingOrder.append(id)
        }
        return session
    }

    // A deferred lock retains the session and selection; retry retirement after the lock completes.
    @discardableResult
    func retire(_ id: UUID) -> Bool {
        if let session = sessionsByID[id] {
            session.lockForDatabaseTransition()
            guard session.state == .locked else { return false }
        }
        sessionsByID.removeValue(forKey: id)
        openingOrder.removeAll { $0 == id }
        if activeSessionID == id {
            activeSessionID = nil
        }
        return true
    }
}
