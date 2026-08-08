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

        let outcome = await task.value
        // A same-scope request only registers a new task once this entry is
        // cleared, so the stored task is still ours to remove here.
        inFlightDrains[scope] = nil
        // A request slipping in between the loop's final check and the line
        // above already got this outcome without its extra pass; run it in the
        // background rather than swallowing it.
        if rerunRequestedScopes.contains(scope) {
            Task { @MainActor in
                _ = await self.drain(databaseId: databaseId)
            }
        }
        return outcome
    }

    private static func drainOffMain(
        databaseId: UUID?,
        environment: Environment
    ) async -> DrainOutcome {
        var outcome = DrainOutcome()
        // Payload SHAs already pushed to the remote head in this pass, per
        // database. A later marker recording the same payload is dropped:
        // re-pushing it could only raise a spurious revision conflict.
        var uploadedPayloadSHAs: [UUID: Set<Data>] = [:]

        for var storedMarker in environment.listMarkers(databaseId) {
            guard var reference = environment.resolveReference(storedMarker.marker.databaseId) else {
                outcome.skippedDatabaseIDs.insert(storedMarker.marker.databaseId)
                continue
            }

            guard reference.isCloudBacked else {
                outcome.skippedDatabaseIDs.insert(reference.id)
                continue
            }

            // A marker enqueued while a master-key change was uploading holds
            // ciphertext under the old key; pushing it would revert the rekey
            // on the remote (rev-less providers) or strand an undecryptable
            // payload (rev-tracking ones). Surface it as a conflict instead.
            if let rekeyedAt = reference.lastMasterKeyChangeAt,
               storedMarker.marker.createdAt < rekeyedAt {
                storedMarker.marker.lastSyncError = environment.conflictMessage(nil)
                _ = try? environment.updateMarker(storedMarker)
                outcome.conflictDatabaseIDs.insert(reference.id)
                continue
            }

            if uploadedPayloadSHAs[reference.id]?.contains(storedMarker.marker.openTimeSHA512) == true {
                try? environment.dropMarker(storedMarker)
                outcome.drainedDatabaseIDs.insert(reference.id)
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

            // A mismatch means a sync-down overwrote the shared cache since
            // enqueue. Pushing those bytes and dropping the marker as "saved"
            // would upload the wrong content over the user's real change, so
            // surface it as a conflict instead.
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
                        uploadedPayloadSHAs[reference.id, default: []].insert(storedMarker.marker.openTimeSHA512)
                        didCompleteMarker = true
                    case .conflict(let remoteRev):
                        if attempt == 0,
                           let remoteRev,
                           shouldRebaseOntoRemoteHead(
                               markerExpectedRev: storedMarker.marker.expectedRev,
                               markerBaseRev: storedMarker.marker.baseRev,
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

    /// Whether a `.conflict` may be rebased onto the reported remote head and
    /// force-pushed. Requires all three, else the marker stays conflicted:
    /// 1. `payloadMatchesRecordedContent` — the cache still holds our bytes;
    ///    a synced-down cross-device change appears here as a mismatch.
    /// 2. `markerBaseRev == remoteRev` — the payload descends from the head.
    ///    Without it an app save that landed while AutoFill held the database
    ///    open is silently dropped. Legacy markers decode nil and never rebase;
    ///    rev drift without content change (OneDrive cTag) also declines.
    /// 3. `currentReferenceExpectedRev == remoteRev` — this head is already
    ///    reconciled locally, not an unseen foreign revision.
    private static func shouldRebaseOntoRemoteHead(
        markerExpectedRev: String?,
        markerBaseRev: String?,
        remoteRev: String,
        currentReferenceExpectedRev: String?,
        payloadMatchesRecordedContent: Bool
    ) -> Bool {
        guard payloadMatchesRecordedContent else { return false }
        guard markerExpectedRev != remoteRev else { return false }
        guard let markerBaseRev, markerBaseRev == remoteRev else { return false }
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
