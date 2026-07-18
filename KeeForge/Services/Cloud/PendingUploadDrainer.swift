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
        var sha512: @Sendable (Data) -> Data
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
            sha512: { data in
                KDBXCrypto.sha512(data)
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

        // Coalesce: an identical in-flight scope is shared rather than re-run.
        if let existing = inFlightDrains[scope] {
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

            return await Task.detached(priority: .utility) {
                await Self.drainOffMain(
                    databaseId: databaseId,
                    environment: environment
                )
            }.value
        }

        inFlightDrains[scope] = task
        drainChainTail = Task { @MainActor in _ = await task.value }

        let outcome = await task.value
        // A same-scope request only registers a new task once this entry is
        // cleared, so the stored task is still ours to remove here.
        inFlightDrains[scope] = nil
        return outcome
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

            // The bytes we are about to push must still be exactly what this
            // device saved at enqueue time. If a sync-down (or anything else)
            // has since overwritten the shared cache, the SHA-512 recorded on
            // the marker no longer matches. Pushing the clobbered bytes — and
            // then dropping the marker as "saved" — would silently upload the
            // wrong content over the user's real change, so treat any mismatch
            // as a conflict for the user to resolve instead.
            let payloadMatchesRecordedContent =
                environment.sha512(encryptedBytes) == storedMarker.marker.openTimeSHA512
            guard payloadMatchesRecordedContent else {
                storedMarker.marker.lastSyncError = environment.conflictMessage(nil)
                _ = try? environment.updateMarker(storedMarker)
                outcome.conflictDatabaseIDs.insert(reference.id)
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
                           shouldRebaseOntoRemoteHead(
                               markerExpectedRev: storedMarker.marker.expectedRev,
                               remoteRev: remoteRev,
                               currentReferenceExpectedRev: reference.expectedCloudRevision,
                               payloadMatchesRecordedContent: payloadMatchesRecordedContent
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

    /// Decides whether a `.conflict` may be resolved by rebasing the marker onto
    /// the reported remote head and force-pushing this device's bytes.
    ///
    /// This is only safe when the conflict was caused by *this* device's own
    /// earlier pending upload — never for a genuine cross-device change, which
    /// must be surfaced to the user rather than overwritten. We require two
    /// independent facts before rebasing:
    ///
    /// 1. `payloadMatchesRecordedContent` — the bytes we would push are still the
    ///    exact bytes this device saved (the shared cache has not been replaced
    ///    by a sync-down of someone else's copy). A cross-device change that has
    ///    reached this device shows up here as a mismatch and blocks the rebase.
    /// 2. `currentReferenceExpectedRev == remoteRev` — the local reference has
    ///    already reconciled to this remote head, i.e. the head is one this
    ///    device produced/observed as its own lineage, not an unseen foreign
    ///    revision.
    ///
    /// When either fact is missing we decline and leave the marker conflicted.
    private static func shouldRebaseOntoRemoteHead(
        markerExpectedRev: String?,
        remoteRev: String,
        currentReferenceExpectedRev: String?,
        payloadMatchesRecordedContent: Bool
    ) -> Bool {
        guard payloadMatchesRecordedContent else { return false }
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
