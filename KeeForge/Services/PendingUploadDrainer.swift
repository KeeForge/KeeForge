import CoreFoundation
import Foundation

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
    }

    struct Environment: Sendable {
        var beginBackgroundTask: @MainActor @Sendable (String) -> LocalDatabaseSaver.BackgroundTaskHandle
        var endBackgroundTask: @MainActor @Sendable (LocalDatabaseSaver.BackgroundTaskHandle) -> Void
        var listMarkers: @Sendable (UUID?) -> [PendingUploadQueue.StoredMarker]
        var dropMarker: @Sendable (PendingUploadQueue.StoredMarker) throws -> Void
        var updateMarker: @Sendable (PendingUploadQueue.StoredMarker) throws -> PendingUploadQueue.StoredMarker
        var resolveReference: @Sendable (UUID) -> DatabaseReference?
        var readBytes: @Sendable (String) throws -> Data
        var pushPendingUpload: @Sendable (DatabaseReference, Data, String?) async throws -> CloudDatabaseSaver.PendingUploadPushResult
        var conflictMessage: @Sendable (String?) -> String

        static let live = Environment(
            beginBackgroundTask: LocalDatabaseSaver.Environment.live.beginBackgroundTask,
            endBackgroundTask: LocalDatabaseSaver.Environment.live.endBackgroundTask,
            listMarkers: { databaseId in
                PendingUploadQueue.listMarkers(for: databaseId)
            },
            dropMarker: { marker in
                try PendingUploadQueue.drop(marker)
            },
            updateMarker: { marker in
                try PendingUploadQueue.update(marker)
            },
            resolveReference: { databaseId in
                DatabaseListStore.databases.first(where: { $0.id == databaseId })
            },
            readBytes: { relativePath in
                try Data(contentsOf: PendingUploadQueue.resolveAppGroupURL(for: relativePath))
            },
            pushPendingUpload: { reference, data, expectedRev in
                try await CloudDatabaseSaver.pushPendingUpload(
                    reference: reference,
                    encryptedBytes: data,
                    expectedRev: expectedRev
                )
            },
            conflictMessage: { remoteRev in
                CloudProviderError.conflict(remoteRev: remoteRev).localizedDescription
            }
        )
    }

    private let environment: Environment
    private var darwinObserver: PendingUploadDarwinObserver?

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
        let environment = self.environment
        let backgroundTaskHandle = environment.beginBackgroundTask("PendingUploadDraining")
        defer {
            Task { @MainActor in
                environment.endBackgroundTask(backgroundTaskHandle)
            }
        }

        return await Task.detached(priority: .utility) {
            await Self.drainOffMain(
                databaseId: databaseId,
                environment: environment
            )
        }.value
    }

    private static func drainOffMain(
        databaseId: UUID?,
        environment: Environment
    ) async -> DrainOutcome {
        var outcome = DrainOutcome()

        for var storedMarker in environment.listMarkers(databaseId) {
            guard var reference = environment.resolveReference(storedMarker.marker.databaseId) else {
                outcome.skippedDatabaseIDs.insert(storedMarker.marker.databaseId)
                continue
            }

            guard reference.isCloudBacked else {
                outcome.skippedDatabaseIDs.insert(reference.id)
                continue
            }

            let encryptedBytes: Data
            do {
                encryptedBytes = try environment.readBytes(storedMarker.marker.encryptedBytesCacheURL)
            } catch {
                outcome.userIssue = UserIssue(
                    databaseId: reference.id,
                    kind: .message,
                    message: error.localizedDescription
                )
                continue
            }

            var didCompleteMarker = false
            for attempt in 0..<2 {
                do {
                    let pushResult = try await environment.pushPendingUpload(
                        reference,
                        encryptedBytes,
                        storedMarker.marker.expectedRev
                    )

                    switch pushResult {
                    case .saved(let updatedReference):
                        try environment.dropMarker(storedMarker)
                        outcome.drainedDatabaseIDs.insert(updatedReference.id)
                        didCompleteMarker = true
                    case .conflict(let remoteRev):
                        if attempt == 0,
                           let remoteRev,
                           shouldRetryConflict(
                               markerExpectedRev: storedMarker.marker.expectedRev,
                               remoteRev: remoteRev,
                               currentReferenceExpectedRev: reference.expectedCloudRevision
                           ) {
                            storedMarker.marker.expectedRev = remoteRev
                            storedMarker.marker.lastSyncError = nil
                            storedMarker = try environment.updateMarker(storedMarker)
                            reference = environment.resolveReference(reference.id) ?? reference
                            continue
                        }

                        storedMarker.marker.lastSyncError = environment.conflictMessage(remoteRev)
                        _ = try? environment.updateMarker(storedMarker)
                        outcome.conflictDatabaseIDs.insert(reference.id)
                        didCompleteMarker = true
                    }
                } catch let error as CloudProviderError {
                    outcome.userIssue = UserIssue(
                        databaseId: reference.id,
                        kind: issueKind(for: error),
                        message: error.localizedDescription
                    )
                    didCompleteMarker = true
                } catch {
                    outcome.userIssue = UserIssue(
                        databaseId: reference.id,
                        kind: .message,
                        message: error.localizedDescription
                    )
                    didCompleteMarker = true
                }

                if didCompleteMarker {
                    break
                }
            }
        }

        return outcome
    }

    private static func shouldRetryConflict(
        markerExpectedRev: String?,
        remoteRev: String,
        currentReferenceExpectedRev: String?
    ) -> Bool {
        guard markerExpectedRev != remoteRev else { return false }
        return currentReferenceExpectedRev == remoteRev
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
