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
        let marker = makeMarker(lastSyncError: "Needs attention")

        let encoded = try environment.encodeMarker(marker)
        let decoded = try environment.decodeMarker(encoded)

        XCTAssertEqual(decoded, marker)
    }

    private func makeEnvironment(
        writeMarkerAtomically: (@Sendable (Data, URL) throws -> Void)? = nil
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
            postDarwinNotification: {}
        )
    }

    private func makeMarker(
        databaseId: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        expectedRev: String? = "rev-1",
        lastSyncError: String? = nil
    ) -> PendingUploadQueue.Marker {
        PendingUploadQueue.Marker(
            databaseId: databaseId,
            encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
            openTimeSHA512: Data("open-sha".utf8),
            expectedRev: expectedRev,
            createdAt: createdAt,
            lastSyncError: lastSyncError
        )
    }
}
