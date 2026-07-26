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

    func test_enqueue_writesMarkerAtomically() throws {
        let environment = makeEnvironment { data, url in
            let tempURL = url.deletingLastPathComponent().appendingPathComponent(".partial-write.tmp", isDirectory: false)
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.removeItem(at: tempURL)
            throw CocoaError(.fileWriteUnknown)
        }
        let marker = makeMarker()

        XCTAssertThrowsError(try PendingUploadQueue.enqueue(marker, environment: environment))
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: marker.databaseId, environment: environment).isEmpty)
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

    func test_update_afterDrop_doesNotResurrectMarker() throws {
        // Models a concurrent drain that already dropped the marker: a late
        // `update`/`markConflicted` must fail rather than recreate the file and
        // leave a phantom pending upload behind.
        let environment = makeEnvironment()
        let storedMarker = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)

        try PendingUploadQueue.drop(storedMarker, environment: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMarker.fileURL.path))

        var stale = storedMarker
        stale.marker.lastSyncError = "late conflict"

        XCTAssertThrowsError(try PendingUploadQueue.update(stale, environment: environment)) { error in
            XCTAssertEqual(error as? PendingUploadQueue.UpdateError, .markerNoLongerExists)
        }
        XCTAssertThrowsError(
            try PendingUploadQueue.markConflicted(stale, message: "late", environment: environment)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: storedMarker.fileURL.path))
        XCTAssertTrue(
            PendingUploadQueue.listMarkers(for: storedMarker.marker.databaseId, environment: environment).isEmpty
        )
    }

    func test_markConflicted_persistsAcrossRestart() throws {
        let environment = makeEnvironment()
        let storedMarker = try PendingUploadQueue.enqueue(makeMarker(), environment: environment)

        _ = try PendingUploadQueue.markConflicted(
            storedMarker,
            message: "Dropbox conflict",
            environment: environment
        )

        let reloadedMarker = try XCTUnwrap(
            PendingUploadQueue.listMarkers(for: storedMarker.marker.databaseId, environment: environment).first
        )
        XCTAssertEqual(reloadedMarker.marker.lastSyncError, "Dropbox conflict")
    }

    func test_markerCodableRoundTrip() throws {
        let environment = makeEnvironment()
        let marker = makeMarker(lastSyncError: "Needs attention", baseRev: "rev-1")

        let encoded = try environment.encodeMarker(marker)
        let decoded = try environment.decodeMarker(encoded)

        XCTAssertEqual(decoded, marker)
        XCTAssertEqual(decoded.baseRev, "rev-1")
    }

    func test_markerDecodesLegacyJSONWithoutBaseRev() throws {
        // Markers persisted before the `baseRev` field existed must keep
        // decoding, and the missing field must decode as nil — which the
        // drainer treats as "never auto-rebase".
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
        XCTAssertEqual(decoded.lastSyncError, "Needs attention")
        XCTAssertNil(decoded.baseRev)
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

    func test_dropMarkersWithPayloadSHA_dropsMatchesIncludingConflicted_keepsOthersAndExcluded() throws {
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
                lastSyncError: "conflict",
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
        lastSyncError: String? = nil,
        openTimeSHA512: Data = Data("open-sha".utf8),
        baseRev: String? = nil
    ) -> PendingUploadQueue.Marker {
        PendingUploadQueue.Marker(
            databaseId: databaseId,
            encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
            openTimeSHA512: openTimeSHA512,
            expectedRev: expectedRev,
            createdAt: createdAt,
            lastSyncError: lastSyncError,
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
