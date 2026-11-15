#if os(macOS)
import AppKit
import Observation

@MainActor @Observable
final class MacDatabaseWindowRegistry {
    @MainActor
    final class Registration {
        weak var window: NSWindow?
        let databaseID: UUID
        var isRestoring: Bool
        var onUnregister: (() -> Void)?

        init(window: NSWindow, databaseID: UUID, isRestoring: Bool) {
            self.window = window
            self.databaseID = databaseID
            self.isRestoring = isRestoring
        }
    }

    @ObservationIgnored var onRegister: ((NSWindow) -> Void)?

    private let sessionStore: DatabaseSessionStore
    private var registrations: [ObjectIdentifier: Registration] = [:]

    init(sessionStore: DatabaseSessionStore) {
        self.sessionStore = sessionStore
    }

    var registeredWindows: [NSWindow] { registrations.values.compactMap(\.window) }

    @discardableResult
    func register(_ window: NSWindow, databaseID: UUID, isRestoring: Bool = false) -> Registration {
        if let existing = registration(for: window), existing.window === window,
           existing.databaseID == databaseID {
            existing.isRestoring = isRestoring
            return existing
        }
        unregister(window)
        let registration = Registration(window: window, databaseID: databaseID, isRestoring: isRestoring)
        registrations[ObjectIdentifier(window)] = registration
        onRegister?(window)
        return registration
    }

    func unregister(_ window: NSWindow) {
        guard let registration = registrations.removeValue(forKey: ObjectIdentifier(window)) else { return }
        registration.onUnregister?()
        registration.onUnregister = nil
    }

    func registration(for window: NSWindow?) -> Registration? {
        guard let window else { return nil }
        if let registration = registrations[ObjectIdentifier(window)], registration.window === window {
            return registration
        }
        if window is NSPanel, window.sheetParent == nil { return nil }
        return registration(for: window.sheetParent ?? window.parent)
    }

    func session(for window: NSWindow?) -> DatabaseViewModel? {
        registration(for: window).flatMap { sessionStore.session(for: $0.databaseID) }
    }

    /// Automatic unlock may prompt only in the window registered for `session`,
    /// and never while that window is being restored.
    func admitsAutomaticUnlock(for session: DatabaseViewModel, in window: NSWindow?) -> Bool {
        guard let registration = registration(for: window), !registration.isRestoring else { return false }
        return sessionStore.session(for: registration.databaseID) === session
    }

    func isCurrent(_ registration: Registration) -> Bool {
        guard let window = registration.window else { return false }
        return registrations[ObjectIdentifier(window)] === registration
    }
}
#endif
