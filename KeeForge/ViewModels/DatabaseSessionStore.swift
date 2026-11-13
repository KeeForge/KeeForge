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

    func handleAppDidBecomeActive() {
        for session in openSessions {
            session.didManuallyLock = false
            session.handleSceneDidBecomeActive()
            session.refreshSharedDatabaseCacheIfPossible()
        }
    }

    func handleAppDidEnterBackground() {
        for session in openSessions {
            session.handleSceneDidEnterBackground()
        }
    }

    func resetInactivityTimers() {
        // Activity has no window identity yet, so it resets every session's timer.
        for session in openSessions {
            session.resetInactivityTimer()
        }
    }

    func refreshCredentials() {
        for session in openSessions {
            session.populateCredentialStoreIfUnlocked()
        }
    }

    func setSortOrder(_ order: DatabaseViewModel.SortOrder) {
        for session in openSessions {
            session.sortOrder = order
        }
    }

    func setSortAscending(_ ascending: Bool) {
        for session in openSessions {
            session.sortAscending = ascending
        }
    }

    func retireSessionsMissingFromDatabaseList(_ databaseIDs: [UUID]) {
        let retainedIDs = Set(databaseIDs)
        for id in openingOrder where !retainedIDs.contains(id) {
            retire(id, force: true)
        }
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

    // A deferred lock retains the session and selection; force discards unsaved work.
    @discardableResult
    func retire(_ id: UUID, force: Bool = false) -> Bool {
        if let session = sessionsByID[id], session.state != .locked {
            if force {
                session.lock()
            } else {
                session.lockForDatabaseTransition()
            }
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
