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
    /// Scopes whose in-flight drain must run one more pass before finishing.
    /// A request that coalesces onto a running drain may have been triggered
    /// by an enqueue (Darwin notification) that landed after the running pass
    /// already listed the queue; without this flag that marker would silently
    /// wait for the next scene-active drain.
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
        // but the running drain owes the queue one more pass — this request
        // may be the Darwin notification for a marker enqueued after the
        // running pass listed the queue.
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
        // A request can slip in between the loop's final check and the line
        // above; it already received this outcome without its extra pass, so
        // run that pass in the background rather than swallowing it.
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
        // Recorded payload SHAs that reached the remote head earlier in this
        // pass, per database. A later marker recording the same payload is
        // already satisfied by that upload — pushing it again could only
        // produce a spurious revision conflict — so it is dropped instead.
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

    /// Decides whether a `.conflict` may be resolved by rebasing the marker onto
    /// the reported remote head and force-pushing this device's bytes.
    ///
    /// This is only safe when the remote head's *content* is provably what the
    /// pending payload was derived from — never for a genuine cross-device
    /// change, and never for a head this device produced but the payload does
    /// not descend from. We require three independent facts before rebasing:
    ///
    /// 1. `payloadMatchesRecordedContent` — the bytes we would push are still the
    ///    exact bytes this device saved (the shared cache has not been replaced
    ///    by a sync-down of someone else's copy). A cross-device change that has
    ///    reached this device shows up here as a mismatch and blocks the rebase.
    /// 2. `markerBaseRev == remoteRev` — the payload descends from the content
    ///    at the remote head, so the push is a pure fast-forward. Without this,
    ///    "the head came from this device" is not enough: an app-side save that
    ///    completed while the AutoFill extension held the database open produces
    ///    a same-device head (store rev reconciled, payload SHA intact) that the
    ///    payload does NOT contain — force-pushing would silently drop that
    ///    save. Legacy markers persisted without `baseRev` decode as `nil` and
    ///    never rebase. Equality also stays conservative under providers whose
    ///    revisions drift without content changes (OneDrive cTag): drift makes
    ///    the revs unequal, which declines the rebase.
    /// 3. `currentReferenceExpectedRev == remoteRev` — the local reference has
    ///    already reconciled to this remote head, i.e. the head is one this
    ///    device produced/observed as its own lineage, not an unseen foreign
    ///    revision.
    ///
    /// When any fact is missing we decline and leave the marker conflicted.
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
