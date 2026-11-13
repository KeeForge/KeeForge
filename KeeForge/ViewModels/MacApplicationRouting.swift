#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacApplicationRouting {
    enum OpenRequest: Equatable {
        case database(UUID)
        case file(URL, databaseID: UUID)

        var databaseID: UUID {
            switch self {
            case .database(let id), .file(_, let id): id
            }
        }
    }

    enum LaunchPresentation: Equatable {
        case transitionNotice
        case whatsNew
    }

    enum Effect: Equatable {
        case present(LaunchPresentation)
        case open(OpenRequest)
        case front(UUID)
        case showLauncher
        case bindEnrollment(UUID)
        case askEnrollmentDestination
    }

    private(set) var launchPresentation: LaunchPresentation?
    private(set) var enrollmentDestination: UUID?
    var canAuthenticate: Bool { isReady && didBeginStartup && launchPresentation == nil }
    private var isReady = false
    private var didBeginStartup = false
    private var remainingPresentations: [LaunchPresentation] = []
    private var queuedEffects: [Effect] = []
    private var queuedDatabaseIDs: Set<UUID> = []
    private var automaticOpen: UUID?

    func beginStartup(transitionNotice: Bool, whatsNew: Bool, automaticOpen: UUID?) -> [Effect] {
        guard !didBeginStartup else { return [] }
        didBeginStartup = true
        self.automaticOpen = queuedEffects.isEmpty ? automaticOpen : nil
        remainingPresentations = (transitionNotice ? [.transitionNotice] : []) + (whatsNew ? [.whatsNew] : [])
        return advanceStartup()
    }

    func finishLaunchPresentation(_ presentation: LaunchPresentation, openDatabaseIDs: Set<UUID> = []) -> [Effect] {
        guard launchPresentation == presentation else { return [] }
        launchPresentation = nil
        return advanceStartup(openDatabaseIDs: openDatabaseIDs)
    }

    func becomeReady(openDatabaseIDs: Set<UUID> = []) -> [Effect] {
        isReady = true
        return drain(openDatabaseIDs: openDatabaseIDs)
    }

    // The adapter resolves file identity through the database list before requesting an open.
    func requestOpen(_ request: OpenRequest, openDatabaseIDs: Set<UUID>) -> [Effect] {
        automaticOpen = nil
        let id = request.databaseID
        let effect: Effect = openDatabaseIDs.contains(id) || queuedDatabaseIDs.contains(id) ? .front(id) : .open(request)
        guard canAuthenticate else {
            queuedEffects.append(effect)
            queuedDatabaseIDs.insert(id)
            return []
        }
        return [effect]
    }

    func receiveEnrollment(targetDatabaseID: UUID?) -> [Effect] {
        enrollmentDestination = targetDatabaseID
        if let targetDatabaseID { return [.bindEnrollment(targetDatabaseID)] }
        return [.showLauncher, .askEnrollmentDestination]
    }

    func chooseEnrollmentDestination(_ databaseID: UUID) -> [Effect] {
        enrollmentDestination = databaseID
        return [.bindEnrollment(databaseID)]
    }

    func ensureVisibleWindow(hasVisibleWindows: Bool) -> [Effect] {
        hasVisibleWindows ? [] : [.showLauncher]
    }

    func dockReopen(hasVisibleWindows: Bool) -> [Effect] {
        ensureVisibleWindow(hasVisibleWindows: hasVisibleWindows)
    }

    private func advanceStartup(openDatabaseIDs: Set<UUID> = []) -> [Effect] {
        if !remainingPresentations.isEmpty {
            let presentation = remainingPresentations.removeFirst()
            launchPresentation = presentation
            return [.showLauncher, .present(presentation)]
        }
        return drain(openDatabaseIDs: openDatabaseIDs)
    }

    private func drain(openDatabaseIDs: Set<UUID>) -> [Effect] {
        guard canAuthenticate else { return [] }
        var effects = queuedEffects.map { effect in
            if case .open(let request) = effect, openDatabaseIDs.contains(request.databaseID) {
                return Effect.front(request.databaseID)
            }
            return effect
        }
        queuedEffects.removeAll()
        queuedDatabaseIDs.removeAll()
        if let automaticOpen {
            effects.append(openDatabaseIDs.contains(automaticOpen) ? .front(automaticOpen) : .open(.database(automaticOpen)))
            self.automaticOpen = nil
        }
        return effects
    }
}
#endif
