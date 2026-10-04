import Foundation
import XCTest
@testable import KeeForge

final class PendingUploadQueueTests: XCTestCase {
    private var containerURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingUploadQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerURL)
        containerURL = nil
        try super.tearDownWithError()
    }

    func test_enqueue_failedMarkerWriteDoesNotNotify() throws {
        let notificationCounter = Counter()
        let environment = makeEnvironment(
            writeMarkerAtomically: { _, _ in throw CocoaError(.fileWriteUnknown) },
            onDarwinNotification: { notificationCounter.increment() }
        )
        let marker = makeMarker()

        XCTAssertThrowsError(try PendingUploadQueue.enqueue(marker, environment: environment)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: marker.databaseId, environment: environment).isEmpty)
        XCTAssertEqual(notificationCounter.value, 0)
    }

    func test_liveMarkerWriter_failedRenamePreservesDestinationAndCleansStagingFile() throws {
        let destination = containerURL.appendingPathComponent("occupied.json", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("existing-data")
        let originalData = Data("must survive".utf8)
        try originalData.write(to: sentinel)

        XCTAssertThrowsError(
            try PendingUploadQueue.Environment.live.writeMarkerAtomically(Data("new-marker".utf8), destination)
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), originalData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: containerURL.path), ["occupied.json"])
    }

    func test_listMarkers_returnsAllForGivenDatabase() throws {
        let environment = makeEnvironment()
        let databaseA = UUID()
        let databaseB = UUID()

        _ = try PendingUploadQueue.enqueue(makeMarker(databaseId: databaseA, createdAt: Date(timeIntervalSince1970: 10)), environment: environment)
        _ = try PendingUploadQueue.enqueue(makeMarker(databaseId: databaseA, createdAt: Date(timeIntervalSince1970: 20)), environment: environment)
        _ = try PendingUploadQueue.enqueue(makeMarker(databaseId: databaseA, createdAt: Date(timeIntervalSince1970: 30)), environment: environment)
        _ = try PendingUploadQueue.enqueue(makeMarker(databaseId: databaseB, createdAt: Date(timeIntervalSince1970: 40)), environment: environment)

        XCTAssertEqual(PendingUploadQueue.listMarkers(for: databaseA, environment: environment).count, 3)
        XCTAssertEqual(PendingUploadQueue.listMarkers(for: databaseB, environment: environment).count, 1)
        XCTAssertEqual(PendingUploadQueue.listMarkers(environment: environment).count, 4)
    }

    func test_drop_removesMarker_fromDisk() throws {
        let environment = makeEnvironment()
        let storedMarker = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)

        try PendingUploadQueue.drop(storedMarker, environment: environment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMarker.fileURL.path))
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: storedMarker.marker.databaseId, environment: environment).isEmpty)
    }

    func test_dropIfUnchanged_preservesAMarkerFinalizedAfterTheSnapshot() throws {
        let environment = makeEnvironment()
        var provisional = makeMarker()
        provisional.isPayloadFinalized = false
        let snapshot = try PendingUploadQueue.enqueue(provisional, environment: environment)

        var finalized = snapshot
        finalized.marker.openTimeSHA512 = Data("saved-payload-sha".utf8)
        finalized.marker.isPayloadFinalized = true
        finalized = try PendingUploadQueue.update(finalized, environment: environment)

        XCTAssertFalse(try PendingUploadQueue.dropIfUnchanged(snapshot, environment: environment))
        XCTAssertEqual(
            PendingUploadQueue.listMarkers(for: snapshot.marker.databaseId, environment: environment).first?.marker,
            finalized.marker
        )
        XCTAssertTrue(try PendingUploadQueue.dropIfUnchanged(finalized, environment: environment))
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: snapshot.marker.databaseId, environment: environment).isEmpty)
    }

    func test_update_rejectsAStaleGenerationInsteadOfOverwritingNewerMarkerData() throws {
        let environment = makeEnvironment()
        let original = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)
        var firstUpdate = original
        firstUpdate.marker.isConflicted = true
        let current = try PendingUploadQueue.update(firstUpdate, environment: environment)

        var staleUpdate = original
        staleUpdate.marker.openTimeSHA512 = Data("different-payload".utf8)
        XCTAssertThrowsError(try PendingUploadQueue.update(staleUpdate, environment: environment)) { error in
            XCTAssertEqual(error as? PendingUploadQueue.UpdateError, .markerChanged)
        }
        XCTAssertEqual(
            PendingUploadQueue.listMarkers(for: original.marker.databaseId, environment: environment).first?.marker,
            current.marker
        )
    }

    /// The drainer can run between the AutoFill cache write and finalization:
    /// it sees the new cache against the provisional base hash and flags the
    /// marker conflicted, bumping its generation. Finalization must still land
    /// on that marker — a generation-checked `update` failed here and left the
    /// provisional marker behind, which blocks every later recovery lookup.
    func test_finalize_afterADrainerFlaggedTheProvisionalMarker_finalizesThatMarker() throws {
        let environment = makeEnvironment()
        var provisional = makeMarker(openTimeSHA512: Data("base-sha".utf8))
        provisional.isPayloadFinalized = false
        let extensionSnapshot = try PendingUploadQueue.enqueue(provisional, environment: environment)

        var drainerSnapshot = extensionSnapshot
        drainerSnapshot.marker.isConflicted = true
        drainerSnapshot.marker.expectedRev = "rev-2"
        _ = try PendingUploadQueue.update(drainerSnapshot, environment: environment)

        var saved = extensionSnapshot
        saved.marker.openTimeSHA512 = Data("payload-sha".utf8)
        saved.marker.isPayloadFinalized = true
        XCTAssertThrowsError(try PendingUploadQueue.update(saved, environment: environment)) { error in
            XCTAssertEqual(error as? PendingUploadQueue.UpdateError, .markerChanged)
        }
        let finalized = try PendingUploadQueue.finalize(saved, environment: environment)

        let markers = PendingUploadQueue.listMarkers(for: provisional.databaseId, environment: environment)
        XCTAssertEqual(markers.map(\.id), [extensionSnapshot.id])
        XCTAssertEqual(markers.first?.marker, finalized.marker)
        XCTAssertEqual(finalized.marker.openTimeSHA512, Data("payload-sha".utf8))
        XCTAssertEqual(finalized.marker.isPayloadFinalized, true)
        XCTAssertFalse(finalized.marker.isConflicted)
        XCTAssertEqual(finalized.marker.expectedRev, "rev-2", "The drainer's rebase must survive finalization")
        XCTAssertEqual(finalized.marker.generation, 2)
    }

    func test_finalize_afterDrop_throwsInsteadOfRecreatingTheMarker() throws {
        let environment = makeEnvironment()
        var provisional = makeMarker()
        provisional.isPayloadFinalized = false
        let storedMarker = try PendingUploadQueue.enqueue(provisional, environment: environment)
        XCTAssertTrue(try PendingUploadQueue.dropIfUnchanged(storedMarker, environment: environment))

        XCTAssertThrowsError(try PendingUploadQueue.finalize(storedMarker, environment: environment)) { error in
            XCTAssertEqual(error as? PendingUploadQueue.UpdateError, .markerNoLongerExists)
        }
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: provisional.databaseId, environment: environment).isEmpty)
    }

    func test_markerLocks_leaveOneLockFilePerDatabaseAfterMarkersAreDropped() throws {
        let environment = makeEnvironment()
        let databaseId = UUID()
        var storedMarkers = try (0..<3).map { _ in
            try PendingUploadQueue.enqueue(makeMarker(databaseId: databaseId), environment: environment)
        }
        storedMarkers[0] = try PendingUploadQueue.markConflicted(storedMarkers[0], environment: environment)

        for storedMarker in storedMarkers {
            XCTAssertTrue(try PendingUploadQueue.dropIfUnchanged(storedMarker, environment: environment))
        }

        let directoryURL = storedMarkers[0].fileURL.deletingLastPathComponent()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
            [PendingUploadQueue.markerLockFileName]
        )
    }

    func test_update_afterDrop_doesNotResurrectMarker() throws {
        // Models a concurrent drain that already dropped the marker: a late
        // `update`/`markConflicted` must fail rather than recreate the file and
        // leave a phantom pending upload behind.
        let environment = makeEnvironment()
        let storedMarker = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)

        try PendingUploadQueue.drop(storedMarker, environment: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMarker.fileURL.path))

        var stale = storedMarker
        stale.marker.isConflicted = true

        XCTAssertThrowsError(try PendingUploadQueue.update(stale, environment: environment)) { error in
            XCTAssertEqual(error as? PendingUploadQueue.UpdateError, .markerNoLongerExists)
        }
        XCTAssertThrowsError(
            try PendingUploadQueue.markConflicted(stale, environment: environment)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMarker.fileURL.path))
        XCTAssertTrue(
            PendingUploadQueue.listMarkers(for: storedMarker.marker.databaseId, environment: environment).isEmpty
        )
    }

    func test_markConflicted_persistsAcrossRestart() throws {
        let environment = makeEnvironment()
        let storedMarker = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)

        _ = try PendingUploadQueue.markConflicted(storedMarker, environment: environment)

        let reloadedMarker = try XCTUnwrap(
            PendingUploadQueue.listMarkers(for: storedMarker.marker.databaseId, environment: environment).first
        )
        XCTAssertTrue(reloadedMarker.marker.isConflicted)
    }

    func test_markerCodableRoundTrip() throws {
        let environment = makeEnvironment()
        let marker = makeMarker(isConflicted: true, baseRev: "rev-1")

        let encoded = try environment.encodeMarker(marker)
        let decoded = try environment.decodeMarker(encoded)

        XCTAssertEqual(decoded, marker)
        XCTAssertEqual(decoded.baseRev, "rev-1")
    }

    func test_markerDecodesLegacyJSONWithoutBaseRevOrIsConflicted() throws {
        // Markers persisted before `baseRev` and `isConflicted` existed must
        // keep decoding. `baseRev` decodes as nil (the drainer never
        // auto-rebases those), and the retired `lastSyncError` string is
        // ignored, leaving `isConflicted` false so the next drain re-derives
        // the verdict from its own gates.
        let databaseId = UUID()
        let legacyJSON = """
        {
          "databaseId" : "\(databaseId.uuidString)",
          "encryptedBytesCacheURL" : "cloud-cache/\(databaseId.uuidString).kdbx",
          "openTimeSHA512" : "\(Data("open-sha".utf8).base64EncodedString())",
          "expectedRev" : "rev-1",
          "createdAt" : 1000,
          "lastSyncError" : "Needs attention"
        }
        """

        let decoded = try JSONDecoder().decode(
            PendingUploadQueue.Marker.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.databaseId, databaseId)
        XCTAssertEqual(decoded.openTimeSHA512, Data("open-sha".utf8))
        XCTAssertEqual(decoded.expectedRev, "rev-1")
        XCTAssertFalse(decoded.isConflicted)
        XCTAssertNil(decoded.baseRev)
        XCTAssertNil(decoded.isPayloadFinalized, "v1.16.0 wrote provisional markers in this shape too")
        XCTAssertEqual(decoded.generation, 0)
        let reencoded = try JSONSerialization.jsonObject(with: makeEnvironment().encodeMarker(decoded)) as? [String: Any]
        XCTAssertNil(reencoded?["isPayloadFinalized"], "Re-persisting must not turn an unproven marker into a finalized one")
    }

    func test_enqueue_withoutNotifying_postsNoDarwinNotification_untilExplicitPost() throws {
        let notificationCounter = Counter()
        let environment = makeEnvironment(onDarwinNotification: { notificationCounter.increment() })

        _ = try PendingUploadQueue.enqueue(makeMarker(), notifying: false, environment: environment)
        XCTAssertEqual(notificationCounter.value, 0)

        PendingUploadQueue.postEnqueuedNotification(environment: environment)
        XCTAssertEqual(notificationCounter.value, 1)

        _ = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)
        XCTAssertEqual(notificationCounter.value, 2)
    }

    func test_dropMarkersWithPayloadSHA_dropsFinalizedMatchesIncludingConflicted_keepsOthersExcludedAndUnproven() throws {
        let environment = makeEnvironment()
        let databaseId = UUID()
        let supersededSHA = Data("base-sha".utf8)

        let superseded = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: databaseId, createdAt: Date(timeIntervalSince1970: 10), openTimeSHA512: supersededSHA),
            environment: environment
        )
        // A conflicted marker with the same recorded payload is equally
        // superseded — the SHA equality is the proof the conflict was spurious.
        let conflicted = try PendingUploadQueue.enqueue(
            makeMarker(
                databaseId: databaseId,
                createdAt: Date(timeIntervalSince1970: 20),
                isConflicted: true,
                openTimeSHA512: supersededSHA
            ),
            environment: environment
        )
        let differentPayload = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: databaseId, createdAt: Date(timeIntervalSince1970: 30), openTimeSHA512: Data("other-sha".utf8)),
            environment: environment
        )
        let newMarker = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: databaseId, createdAt: Date(timeIntervalSince1970: 40), openTimeSHA512: supersededSHA),
            environment: environment
        )
        let otherDatabase = try PendingUploadQueue.enqueue(
            makeMarker(createdAt: Date(timeIntervalSince1970: 50), openTimeSHA512: supersededSHA),
            environment: environment
        )
        // An unproven marker's hash may be the base its AutoFill save started
        // from; a save on that base does not contain the change.
        var provisionalMarker = makeMarker(databaseId: databaseId, createdAt: Date(timeIntervalSince1970: 60), isConflicted: true, openTimeSHA512: supersededSHA)
        provisionalMarker.isPayloadFinalized = false
        let provisional = try PendingUploadQueue.enqueue(provisionalMarker, environment: environment)
        var legacyMarker = makeMarker(databaseId: databaseId, createdAt: Date(timeIntervalSince1970: 70), isConflicted: true, openTimeSHA512: supersededSHA)
        legacyMarker.isPayloadFinalized = nil
        let legacy = try PendingUploadQueue.enqueue(legacyMarker, environment: environment)

        PendingUploadQueue.dropMarkers(
            withPayloadSHA512: supersededSHA,
            for: databaseId,
            excluding: newMarker.id,
            environment: environment
        )

        let remainingIDs = Set(PendingUploadQueue.listMarkers(environment: environment).map(\.id))
        XCTAssertFalse(remainingIDs.contains(superseded.id))
        XCTAssertFalse(remainingIDs.contains(conflicted.id))
        XCTAssertTrue(remainingIDs.contains(differentPayload.id))
        XCTAssertTrue(remainingIDs.contains(newMarker.id))
        XCTAssertTrue(remainingIDs.contains(otherDatabase.id))
        XCTAssertTrue(remainingIDs.contains(provisional.id))
        XCTAssertTrue(remainingIDs.contains(legacy.id))
    }

    private func makeEnvironment(
        writeMarkerAtomically: (@Sendable (Data, URL) throws -> Void)? = nil,
        onDarwinNotification: (@Sendable () -> Void)? = nil
    ) -> PendingUploadQueue.Environment {
        let containerURL = self.containerURL!
        return PendingUploadQueue.Environment(
            appGroupContainerURL: { containerURL },
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            listDirectory: { url in
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            },
            readData: { url in
                try Data(contentsOf: url)
            },
            removeItem: { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            },
            encodeMarker: { marker in
                try JSONEncoder().encode(marker)
            },
            decodeMarker: { data in
                try JSONDecoder().decode(PendingUploadQueue.Marker.self, from: data)
            },
            writeMarkerAtomically: writeMarkerAtomically ?? { data, url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            },
            postDarwinNotification: onDarwinNotification ?? {}
        )
    }

    private func makeMarker(
        databaseId: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        expectedRev: String? = "rev-1",
        isConflicted: Bool = false,
        openTimeSHA512: Data = Data("open-sha".utf8),
        baseRev: String? = nil
    ) -> PendingUploadQueue.Marker {
        PendingUploadQueue.Marker(
            databaseId: databaseId,
            encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
            openTimeSHA512: openTimeSHA512,
            expectedRev: expectedRev,
            createdAt: createdAt,
            isConflicted: isConflicted,
            baseRev: baseRev
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }
    }
}
