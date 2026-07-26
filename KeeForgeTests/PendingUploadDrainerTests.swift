import Foundation
import XCTest
@testable import KeeForge

@MainActor
final class PendingUploadDrainerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func test_drain_happyPath_uploadsAndDropsMarker() async {
        let reference = makeCloudReference()
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, bytes, expectedRev in
                    recorder.pushedExpectedRevisions.append(expectedRev)
                    recorder.pushedBytes.append(bytes)
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(outcome.drainedDatabaseIDs, [reference.id])
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
        XCTAssertEqual(recorder.droppedMarkerIDs, [storedMarker.id])
        XCTAssertEqual(recorder.pushedExpectedRevisions, [reference.expectedCloudRevision])
        XCTAssertEqual(recorder.pushedBytes, [Data("encrypted-bytes".utf8)])
    }

    func test_drain_conflict_marksConflicted_keepsMarker() async {
        let reference = makeCloudReference(rev: "rev-1")
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: "rev-1")
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, _ in
                    .conflict(remoteRev: "rev-2")
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertEqual(recorder.updatedMarkers.count, 1)
        XCTAssertEqual(recorder.updatedMarkers.first?.marker.lastSyncError, CloudProviderError.conflict(remoteRev: "rev-2").localizedDescription)
    }

    func test_drain_payloadShaMismatch_marksConflicted_doesNotPush() async {
        // The shared cache was overwritten after the AutoFill save, so the bytes
        // no longer hash to the SHA-512 recorded on the marker. They must never
        // be pushed (that would upload the wrong content and drop the marker as
        // saved); the marker is surfaced as a conflict instead.
        let reference = makeCloudReference(rev: "rev-1")
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: "rev-1")
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                sha512: { _ in Data("clobbered-sha".utf8) },
                pushPendingUpload: { _, _, _ in
                    XCTFail("Clobbered payload must never be pushed")
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertEqual(recorder.updatedMarkers.count, 1)
        XCTAssertEqual(
            recorder.updatedMarkers.first?.marker.lastSyncError,
            CloudProviderError.conflict(remoteRev: nil).localizedDescription
        )
    }

    func test_drain_crossDeviceConflict_isNotAutoRebased() async {
        // A sync-down replaced the cache with another device's copy, so the
        // payload no longer matches the recorded SHA-512, even though the
        // reference has already reconciled to that remote head (rev-2). The old
        // rebase heuristic keyed only on `expectedCloudRevision == remoteRev`
        // and would have force-pushed this device's stale bytes over the
        // cross-device change. It must now be left conflicted for the user.
        let reference = makeCloudReference(rev: "rev-2")
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: "rev-1")
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                sha512: { _ in Data("foreign-copy-sha".utf8) },
                pushPendingUpload: { _, _, _ in
                    XCTFail("A cross-device conflict must not be force-pushed")
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertEqual(recorder.pushedExpectedRevisions, [])
    }

    func test_drain_offline_keepsMarkerUnchanged() async {
        let reference = makeCloudReference()
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, _ in
                    throw CloudProviderError.networkUnavailable
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.userIssue?.kind, .message)
        XCTAssertEqual(outcome.userIssue?.message, CloudProviderError.networkUnavailable.localizedDescription)
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertTrue(recorder.updatedMarkers.isEmpty)
    }

    func test_drain_writeScopeRequired_surfacesAlertViaList() async {
        let file = CloudFile(
            id: "/Vaults/personal.kdbx",
            name: "personal.kdbx",
            path: "/Vaults/personal.kdbx",
            isFolder: false,
            modifiedDate: nil,
            size: nil
        )
        let reference = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                pushPendingUpload: { _, _, _ in
                    throw CloudProviderError.writeScopeRequired
                }
            )
        )
        let viewModel = DatabaseListViewModel(pendingUploadDrainer: drainer)

        await viewModel.pushPendingChanges(for: reference)

        XCTAssertEqual(viewModel.pendingUploadAlert?.databaseId, reference.id)
        XCTAssertEqual(viewModel.pendingUploadAlert?.kind, .writeScopeRequired)
        XCTAssertEqual(viewModel.pendingUploadAlert?.message, CloudProviderError.writeScopeRequired.localizedDescription)
    }

    func test_drain_skipsLocalSourceMarkers() async {
        let reference = makeLocalReference()
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: nil)
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, _ in
                    XCTFail("Local markers should not be pushed")
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(outcome.skippedDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertTrue(recorder.updatedMarkers.isEmpty)
    }

    func test_drain_rebasesOnlyWhenPayloadDerivesFromRemoteHead() async {
        // The one situation the auto-rebase remains for: the marker's recorded
        // base revision equals the reported remote head, so pushing is a pure
        // fast-forward of content this payload was derived from. The push CAS
        // (expectedRev) is stale from an earlier attempt and gets rebased.
        let referenceStore = ReferenceStore(makeCloudReference(rev: "rev-2"))
        let storedMarker = makeStoredMarker(
            databaseId: referenceStore.reference.id,
            expectedRev: "rev-1",
            baseRev: "rev-2"
        )
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                referenceResolver: { _ in referenceStore.reference },
                recorder: recorder,
                pushPendingUpload: { _, _, expectedRev in
                    recorder.pushedExpectedRevisions.append(expectedRev)
                    if recorder.pushedExpectedRevisions.count == 1 {
                        return .conflict(remoteRev: "rev-2")
                    }

                    referenceStore.reference.updateCloudSyncMetadata { metadata in
                        metadata.remoteRev = "rev-3"
                    }
                    return .saved(updatedReference: referenceStore.reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(recorder.pushedExpectedRevisions, ["rev-1", "rev-2"])
        XCTAssertEqual(recorder.updatedMarkers.count, 1)
        XCTAssertEqual(recorder.updatedMarkers.first?.marker.expectedRev, "rev-2")
        XCTAssertEqual(outcome.drainedDatabaseIDs, [referenceStore.reference.id])
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
    }

    func test_drain_appSaveCompletedDuringAutoFillSession_isNotForcePushed() async {
        // Regression: an app save lands (rev-A → rev-B) after AutoFill opened
        // the cache at rev-A, so the marker's payload SHA and the store's
        // revision both still satisfy the old rebase conditions. Only
        // baseRev (rev-A) != head (rev-B) blocks the force-push that would
        // erase the app's save.
        let reference = makeCloudReference(rev: "rev-B")
        let storedMarker = makeStoredMarker(
            databaseId: reference.id,
            expectedRev: "rev-A",
            baseRev: "rev-A"
        )
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, expectedRev in
                    recorder.pushedExpectedRevisions.append(expectedRev)
                    if expectedRev == "rev-A" {
                        return .conflict(remoteRev: "rev-B")
                    }
                    XCTFail("Stale AutoFill bytes must not be force-pushed over the app's save")
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(recorder.pushedExpectedRevisions, ["rev-A"])
        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
        XCTAssertEqual(
            recorder.updatedMarkers.first?.marker.lastSyncError,
            CloudProviderError.conflict(remoteRev: "rev-B").localizedDescription
        )
    }

    func test_drain_legacyMarkerWithoutBaseRev_isNeverAutoRebased() async {
        // A marker persisted before `baseRev` existed decodes with the field
        // nil. Even when every legacy rebase condition holds (payload intact,
        // store reconciled to the remote head), the missing base revision must
        // be treated conservatively: surface the conflict, never force-push.
        let reference = makeCloudReference(rev: "rev-2")
        let storedMarker = makeStoredMarker(
            databaseId: reference.id,
            expectedRev: "rev-1",
            baseRev: .some(nil)
        )
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, expectedRev in
                    recorder.pushedExpectedRevisions.append(expectedRev)
                    return .conflict(remoteRev: "rev-2")
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(recorder.pushedExpectedRevisions, ["rev-1"])
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(recorder.droppedMarkerIDs.isEmpty)
    }

    func test_drain_dropsFollowUpMarkerWhosePayloadAlreadyUploadedThisPass() async {
        // Two markers recording the same payload SHA (a crash-window artifact
        // of the two-phase enqueue): once the first upload puts that content at
        // the remote head, the second marker is satisfied — it must be dropped
        // rather than re-pushed into a spurious revision conflict.
        let reference = makeCloudReference()
        let firstMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let secondMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [firstMarker, secondMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, bytes, expectedRev in
                    recorder.pushedExpectedRevisions.append(expectedRev)
                    recorder.pushedBytes.append(bytes)
                    return .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(recorder.pushedExpectedRevisions.count, 1)
        XCTAssertEqual(recorder.droppedMarkerIDs, [firstMarker.id, secondMarker.id])
        XCTAssertEqual(outcome.drainedDatabaseIDs, [reference.id])
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
    }

    func test_drain_requestDuringInFlightDrain_runsAdditionalPass() async {
        // L3 regression: a marker enqueued while a drain pass is running posts
        // a Darwin notification whose drain request coalesces onto the running
        // task. That request must not be swallowed — the running drain owes
        // the queue one more pass.
        let reference = makeCloudReference()
        let firstMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let midDrainMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let recorder = Recorder()
        let listCallCounter = Counter()
        let firstPushStarted = AsyncSignal()
        let resumeFirstPush = AsyncSignal()

        var environment = makeEnvironment(
            markers: [],
            reference: reference,
            recorder: recorder,
            pushPendingUpload: { _, _, expectedRev in
                recorder.pushedExpectedRevisions.append(expectedRev)
                if recorder.pushedExpectedRevisions.count == 1 {
                    firstPushStarted.signal()
                    await resumeFirstPush.wait()
                }
                return .saved(updatedReference: reference)
            }
        )
        environment.listMarkers = { _ in
            switch listCallCounter.incrementAndGet() {
            case 1: [firstMarker]
            case 2: [midDrainMarker]
            default: []
            }
        }
        let drainer = PendingUploadDrainer(environment: environment)

        let firstDrain = Task { await drainer.drainAll() }
        await firstPushStarted.wait()

        // Coalesces onto the in-flight drain. Yield so the coalescing task
        // reaches its first suspension point — which is past the rerun-request
        // registration — before the blocked first push is released.
        let coalescedDrain = Task { await drainer.drainAll() }
        for _ in 0..<5 {
            await Task.yield()
        }
        resumeFirstPush.signal()

        let outcome = await firstDrain.value
        _ = await coalescedDrain.value

        XCTAssertEqual(listCallCounter.value, 2)
        XCTAssertEqual(recorder.droppedMarkerIDs, [firstMarker.id, midDrainMarker.id])
        XCTAssertEqual(recorder.pushedExpectedRevisions.count, 2)
        XCTAssertEqual(outcome.drainedDatabaseIDs, [reference.id])
    }

    func test_drain_ignoresReadOnlyFlagForExistingPendingMarkers() async {
        let reference = makeCloudReference(isReadOnly: true)
        let storedMarker = makeStoredMarker(databaseId: reference.id, expectedRev: reference.expectedCloudRevision)
        let recorder = Recorder()
        let drainer = PendingUploadDrainer(
            environment: makeEnvironment(
                markers: [storedMarker],
                reference: reference,
                recorder: recorder,
                pushPendingUpload: { _, _, _ in
                    .saved(updatedReference: reference)
                }
            )
        )

        let outcome = await drainer.drainAll()

        XCTAssertEqual(outcome.drainedDatabaseIDs, [reference.id])
        XCTAssertEqual(recorder.droppedMarkerIDs, [storedMarker.id])
    }

    private func makeEnvironment(
        markers: [PendingUploadQueue.StoredMarker],
        reference: DatabaseReference? = nil,
        referenceResolver: (@Sendable (UUID) -> DatabaseReference?)? = nil,
        recorder: Recorder = Recorder(),
        readBytes: (@Sendable (String) throws -> Data)? = nil,
        sha512: (@Sendable (Data) -> Data)? = nil,
        pushPendingUpload: @escaping @Sendable (DatabaseReference, Data, String?) async throws -> CloudDatabaseSaver.PendingUploadPushResult
    ) -> PendingUploadDrainer.Environment {
        PendingUploadDrainer.Environment(
            beginBackgroundTask: { _ in .invalid },
            endBackgroundTask: { _ in },
            listMarkers: { _ in markers },
            dropMarker: { marker in
                recorder.droppedMarkerIDs.append(marker.id)
            },
            updateMarker: { marker in
                recorder.updatedMarkers.append(marker)
                return marker
            },
            resolveReference: { databaseId in
                if let referenceResolver {
                    return referenceResolver(databaseId)
                }
                guard let reference, reference.id == databaseId else { return nil }
                return reference
            },
            readBytes: readBytes ?? { _ in
                Data("encrypted-bytes".utf8)
            },
            // Default matches `makeStoredMarker`'s `openTimeSHA512` so the
            // payload-integrity guard treats the cached bytes as unchanged.
            sha512: sha512 ?? { _ in Data("open-sha".utf8) },
            pushPendingUpload: pushPendingUpload,
            conflictMessage: { remoteRev in
                CloudProviderError.conflict(remoteRev: remoteRev).localizedDescription
            }
        )
    }

    /// `baseRev` defaults to `expectedRev`, matching what the AutoFill enqueue
    /// records (both start as the reference revision the extension opened
    /// from). Pass `baseRev:` explicitly to model rebased or legacy markers.
    private func makeStoredMarker(
        databaseId: UUID,
        expectedRev: String?,
        baseRev: String?? = nil
    ) -> PendingUploadQueue.StoredMarker {
        PendingUploadQueue.StoredMarker(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).json"),
            marker: PendingUploadQueue.Marker(
                databaseId: databaseId,
                encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
                openTimeSHA512: Data("open-sha".utf8),
                expectedRev: expectedRev,
                createdAt: Date(timeIntervalSince1970: 1_000),
                lastSyncError: nil,
                baseRev: baseRev ?? expectedRev
            )
        )
    }

    private func makeCloudReference(
        id: UUID = UUID(),
        rev: String? = "rev-1",
        isReadOnly: Bool = false
    ) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "cloud.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: isReadOnly,
            editsAcknowledgedAt: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/cloud.kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: rev,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }

    private func makeLocalReference(id: UUID = UUID()) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "local.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil
        )
    }

    private final class Recorder: @unchecked Sendable {
        var droppedMarkerIDs: [UUID] = []
        var updatedMarkers: [PendingUploadQueue.StoredMarker] = []
        var pushedExpectedRevisions: [String?] = []
        var pushedBytes: [Data] = []
    }

    private final class ReferenceStore: @unchecked Sendable {
        var reference: DatabaseReference

        init(_ reference: DatabaseReference) {
            self.reference = reference
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func incrementAndGet() -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage += 1
            return storage
        }
    }

    /// One-shot signal usable across isolation domains: `wait()` suspends
    /// until `signal()` has been called (immediately resuming if it already
    /// was).
    private final class AsyncSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignaled = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func signal() {
            lock.lock()
            isSignaled = true
            let pending = continuations
            continuations = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isSignaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
