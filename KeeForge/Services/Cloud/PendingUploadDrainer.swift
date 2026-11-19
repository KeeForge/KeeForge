import CoreFoundation
import Foundation
import KDBXKit

@MainActor
final class PendingUploadDrainer {
    struct UserIssue: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case writeScopeRequired
            case notAuthenticated
            case message
        }

        let databaseId: UUID
        let kind: Kind
        let message: String
    }

    struct DrainOutcome: Sendable, Equatable {
        var drainedDatabaseIDs: Set<UUID> = []
        var conflictDatabaseIDs: Set<UUID> = []
        var skippedDatabaseIDs: Set<UUID> = []
        var userIssue: UserIssue?

        mutating func merge(_ other: DrainOutcome) {
            drainedDatabaseIDs.formUnion(other.drainedDatabaseIDs)
            conflictDatabaseIDs.formUnion(other.conflictDatabaseIDs)
            skippedDatabaseIDs.formUnion(other.skippedDatabaseIDs)
            if let issue = other.userIssue {
                userIssue = issue
            }
        }
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> LocalDatabaseSaver.BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (LocalDatabaseSaver.BackgroundTaskHandle) -> Void
        var listMarkers: @Sendable (UUID?) -> [PendingUploadQueue.StoredMarker]
        var resolveReference: @Sendable (UUID) -> DatabaseReference?

        var deliverMarker: @Sendable (PendingUploadQueue.StoredMarker, DatabaseReference) async throws -> CloudDatabaseSaver.PendingUploadPushResult?

        static let live = Environment(
            beginBackgroundTask: LocalDatabaseSaver.Environment.live.beginBackgroundTask,
            endBackgroundTask: LocalDatabaseSaver.Environment.live.endBackgroundTask,
            listMarkers: { databaseId in
                PendingUploadQueue.listMarkers(for: databaseId)
            },
            resolveReference: { databaseId in
                DatabaseListStore.databases.first(where: { $0.id == databaseId })
            },
            deliverMarker: { stored, reference in
                try await CloudDatabaseSaver.deliver(stored, reference: reference)
            }
        )
    }

    private enum DrainScope: Hashable {
        case all
        case database(UUID)

        init(databaseId: UUID?) {
            self = databaseId.map(DrainScope.database) ?? .all
        }
    }

    private let environment: Environment
    private var darwinObserver: PendingUploadDarwinObserver?
    /// In-flight drains keyed by scope so a second request for the same scope
    /// awaits the first instead of racing it.
    private var inFlightDrains: [DrainScope: Task<DrainOutcome, Never>] = [:]
    /// Scopes whose in-flight drain owes the queue one more pass: a coalesced
    /// request may be the enqueue notification for a marker that landed after
    /// the running pass listed the queue, which would otherwise wait for the
    /// next scene-active drain.
    private var rerunRequestedScopes: Set<DrainScope> = []
    /// Tail of the serialized drain chain: every new drain awaits this before it
    /// touches the queue, so scene-active drains, the Darwin enqueue
    /// notification, and explicit pushes never process the same markers
    /// concurrently.
    private var drainChainTail: Task<Void, Never>?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func startObserving(onEnqueued: @escaping @MainActor () -> Void) {
        guard darwinObserver == nil else { return }
        darwinObserver = PendingUploadDarwinObserver(onEnqueued: onEnqueued)
    }

    func stopObserving() {
        darwinObserver = nil
    }

    func drainAll() async -> DrainOutcome {
        await drain(databaseId: nil)
    }

    func drain(databaseId: UUID?) async -> DrainOutcome {
        let scope = DrainScope(databaseId: databaseId)

        // Coalesce: an identical in-flight scope is shared rather than re-run,
        // and owes one more pass (see `rerunRequestedScopes`).
        if let existing = inFlightDrains[scope] {
            rerunRequestedScopes.insert(scope)
            return await existing.value
        }

        let environment = self.environment
        let predecessor = drainChainTail

        let task = Task { @MainActor in
            let backgroundTaskHandle = environment.beginBackgroundTask("PendingUploadDraining")
            defer {
                Task { @MainActor in
                    environment.endBackgroundTask(backgroundTaskHandle)
                }
            }

            // Serialize behind any drain already running before reading markers.
            _ = await predecessor?.value

            var outcome = DrainOutcome()
            repeat {
                self.rerunRequestedScopes.remove(scope)
                let passOutcome = await Task.detached(priority: .utility) {
                    await Self.drainOffMain(
                        databaseId: databaseId,
                        environment: environment
                    )
                }.value
                outcome.merge(passOutcome)
            } while self.rerunRequestedScopes.contains(scope)
            return outcome
        }

        inFlightDrains[scope] = task
        drainChainTail = Task { @MainActor in _ = await task.value }

        var outcome = await task.value
        // A same-scope request only registers a new task once this entry is
        // cleared, so the stored task is still ours to remove here.
        inFlightDrains[scope] = nil
        if rerunRequestedScopes.contains(scope) {
            outcome.merge(await drain(databaseId: databaseId))
        }
        return outcome
    }

    private static func drainOffMain(
        databaseId: UUID?,
        environment: Environment
    ) async -> DrainOutcome {
        var outcome = DrainOutcome()
        for storedMarker in environment.listMarkers(databaseId) {
            guard let reference = environment.resolveReference(storedMarker.marker.databaseId) else {
                outcome.skippedDatabaseIDs.insert(storedMarker.marker.databaseId)
                continue
            }

            guard reference.isCloudBacked else {
                outcome.skippedDatabaseIDs.insert(reference.id)
                continue
            }

            guard let current = environment.listMarkers(reference.id).first(where: { $0.id == storedMarker.id }) else { continue }
            do {
                if let result = try await environment.deliverMarker(current, reference) {
                    switch result {
                    case .saved: outcome.drainedDatabaseIDs.insert(reference.id)
                    case .retained: outcome.skippedDatabaseIDs.insert(reference.id)
                    case .conflict: outcome.conflictDatabaseIDs.insert(reference.id)
                    }
                } else { outcome.skippedDatabaseIDs.insert(reference.id) }
            } catch {
                outcome.userIssue = UserIssue(databaseId: reference.id, kind: ((error as? CloudUploadFailure)?.underlying ?? (error as? CloudProviderError)).map(issueKind) ?? .message, message: error.localizedDescription)
            }
        }

        return outcome
    }

    private static func issueKind(for error: CloudProviderError) -> UserIssue.Kind {
        switch error {
        case .writeScopeRequired:
            .writeScopeRequired
        case .notAuthenticated:
            .notAuthenticated
        default:
            .message
        }
    }
}

private final class PendingUploadDarwinObserver {
    let onEnqueued: @MainActor () -> Void

    init(onEnqueued: @escaping @MainActor () -> Void) {
        self.onEnqueued = onEnqueued

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            pendingUploadDarwinNotificationCallback,
            PendingUploadQueue.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
    }
}

private func pendingUploadDarwinNotificationCallback(
    _: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    guard let observer else { return }
    let onEnqueued = Unmanaged<PendingUploadDarwinObserver>
        .fromOpaque(observer)
        .takeUnretainedValue()
        .onEnqueued
    Task { @MainActor in
        onEnqueued()
    }
}
