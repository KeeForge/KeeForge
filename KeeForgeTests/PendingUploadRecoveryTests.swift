import Foundation
import XCTest
@testable import KeeForge

final class PendingUploadRecoveryTests: XCTestCase {
    private let cacheURL = URL(fileURLWithPath: "/recovery-test/cache.kdbx")
    private let newerBackupURL = URL(fileURLWithPath: "/recovery-test/backups/20260924-100000-000000.kdbx")
    private let olderBackupURL = URL(fileURLWithPath: "/recovery-test/backups/20260923-100000-000000.kdbx")

    override func setUpWithError() throws {
        try super.setUpWithError()
        DatabaseListStore.clearAll()
        try PendingUploadQueue.clearAll()
    }

    override func tearDownWithError() throws {
        DatabaseListStore.clearAll()
        try PendingUploadQueue.clearAll()
        try super.tearDownWithError()
    }

    // MARK: - Lookup

    func test_lookUp_onlyUnconflictedMarkers_reportsNoConflicts() {
        let reference = makeReference()
        let payload = Data("payload".utf8)
        let fake = FakeStore(
            markers: [makeStoredMarker(for: reference, payload: payload, isConflicted: false)],
            files: [cacheURL: payload]
        )

        XCTAssertFalse(PendingUploadRecovery.hasConflicts(for: reference, environment: fake.environment))
        guard case .noConflicts = PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment) else {
            return XCTFail("A marker that never conflicted is the drainer's to push, not a merge's")
        }
    }

    func test_lookUp_payloadStillInCache_readsTheCache() throws {
        let reference = makeReference()
        let payload = Data("autofill-payload".utf8)
        let storedMarker = makeStoredMarker(for: reference, payload: payload)
        let fake = FakeStore(markers: [storedMarker], files: [cacheURL: payload])

        let payloads = try recoveredPayloads(PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment))

        XCTAssertEqual(payloads.map(\.data), [payload])
        XCTAssertEqual(payloads.map(\.storedMarker.id), [storedMarker.id])
        XCTAssertEqual(payloads.map(\.location), [.cache])
    }

    func test_lookUp_cacheReplacedByTheCloudCopy_findsTheBackupWithTheRecordedHash() throws {
        let reference = makeReference()
        let payload = Data("autofill-payload".utf8)
        let fake = FakeStore(
            markers: [makeStoredMarker(for: reference, payload: payload)],
            files: [
                cacheURL: Data("cloud-copy".utf8),
                newerBackupURL: Data("unrelated-backup".utf8),
                olderBackupURL: payload,
            ]
        )

        let payloads = try recoveredPayloads(PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment))

        XCTAssertEqual(payloads.map(\.data), [payload])
        XCTAssertEqual(payloads.map(\.location), [.backup(olderBackupURL)], "A refusal must be able to name the backup that holds the change")
    }

    func test_lookUp_payloadNowhereOnDevice_isUnavailable() {
        let reference = makeReference()
        let fake = FakeStore(
            markers: [makeStoredMarker(for: reference, payload: Data("autofill-payload".utf8))],
            files: [cacheURL: Data("cloud-copy".utf8), newerBackupURL: Data("unrelated-backup".utf8)]
        )

        guard case .unavailable = PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment) else {
            return XCTFail("Bytes that do not hash to the marker must never stand in for its payload")
        }
    }

    func test_lookUp_provisionalMarker_doesNotTreatTheBaseBackupAsTheAutoFillPayload() {
        let reference = makeReference()
        let base = Data("pre-autofill-base".utf8)
        var provisional = makeStoredMarker(for: reference, payload: base)
        provisional.marker.isPayloadFinalized = false
        let fake = FakeStore(markers: [provisional], files: [olderBackupURL: base])

        guard case .unavailable = PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment) else {
            return XCTFail("A provisional base hash must never be recovered as the saved AutoFill payload")
        }
    }

    func test_lookUp_changeSavedBeforeAMasterKeyChange_isUnavailableEvenWithItsBytes() {
        var reference = makeReference()
        reference.lastMasterKeyChangeAt = Date(timeIntervalSince1970: 2_000)
        let payload = Data("autofill-payload".utf8)
        let fake = FakeStore(
            markers: [makeStoredMarker(for: reference, payload: payload, createdAt: Date(timeIntervalSince1970: 1_000))],
            files: [cacheURL: payload]
        )

        guard case .unavailable = PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment) else {
            return XCTFail("A payload written under the old master key cannot be merged with the new one")
        }
    }

    func test_lookUp_oneOfTwoConflictsUnavailable_mergesNeither() {
        let reference = makeReference()
        let availablePayload = Data("first-payload".utf8)
        let fake = FakeStore(
            markers: [
                makeStoredMarker(for: reference, payload: availablePayload),
                makeStoredMarker(for: reference, payload: Data("second-payload".utf8)),
            ],
            files: [cacheURL: availablePayload]
        )

        guard case .unavailable = PendingUploadRecovery.lookUpPayloads(for: reference, environment: fake.environment) else {
            return XCTFail("A partial merge would clear some conflicts and strand the rest")
        }
    }

    func test_dropMarkers_dropsOnlyTheGivenMarkers() {
        let reference = makeReference()
        let resolved = makeStoredMarker(for: reference, payload: Data("resolved".utf8))
        let untouched = makeStoredMarker(for: reference, payload: Data("untouched".utf8))
        let fake = FakeStore(markers: [resolved, untouched], files: [:])

        PendingUploadRecovery.dropMarkers([resolved], environment: fake.environment)

        XCTAssertEqual(fake.environment.listMarkers(reference.id).map(\.id), [untouched.id])
    }

    func test_dropMarkers_keepsAMarkerThatChangedAfterLookup() {
        let reference = makeReference()
        let snapshot = makeStoredMarker(for: reference, payload: Data("base".utf8))
        let fake = FakeStore(markers: [snapshot], files: [:])
        var finalized = snapshot
        finalized.marker.openTimeSHA512 = KDBXCrypto.sha512(Data("saved-payload".utf8))
        finalized.marker.isPayloadFinalized = true
        fake.replaceMarker(finalized)

        PendingUploadRecovery.dropMarkers([snapshot], environment: fake.environment)

        XCTAssertEqual(fake.environment.listMarkers(reference.id).map(\.marker), [finalized.marker])
    }

    // MARK: - Live wiring

    /// The situation the feature exists for, through the real queue, cache and
    /// backup locations: opening the database replaced the cache with the
    /// cloud copy and the AutoFill save survives only as a backup.
    func test_live_findsTheAutoFillSaveInTheBackupAfterTheCacheWasReplaced() throws {
        let reference = makeReference()
        DatabaseListStore.update(reference)
        let payload = Data("autofill-payload".utf8)

        let liveCacheURL = DatabaseListStore.cacheLocation(for: reference)
        try FileManager.default.createDirectory(at: liveCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cloud-copy".utf8).write(to: liveCacheURL)
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        try payload.write(to: backupDirectory.appendingPathComponent("20260924-100000-000000.kdbx"))

        let storedMarker = try PendingUploadQueue.enqueue(
            PendingUploadQueue.Marker(
                databaseId: reference.id,
                encryptedBytesCacheURL: PendingUploadQueue.makeRelativeAppGroupPath(for: liveCacheURL),
                openTimeSHA512: KDBXCrypto.sha512(payload),
                expectedRev: "rev-A",
                createdAt: Date(timeIntervalSince1970: 1_000),
                isConflicted: true,
                baseRev: "rev-A"
            ),
            notifying: false
        )

        XCTAssertTrue(PendingUploadRecovery.hasConflicts(for: reference))
        let payloads = try recoveredPayloads(PendingUploadRecovery.lookUpPayloads(for: reference))
        XCTAssertEqual(payloads.map(\.data), [payload])
        guard payloads.count == 1,
              case .backup(let recoveredBackupURL) = payloads[0].location else {
            return XCTFail("Expected the AutoFill save to be recovered from its backup")
        }
        XCTAssertEqualFilePaths(
            recoveredBackupURL,
            backupDirectory.appendingPathComponent("20260924-100000-000000.kdbx")
        )

        PendingUploadRecovery.dropMarkers([storedMarker])

        XCTAssertTrue(PendingUploadQueue.listMarkers(for: reference.id).isEmpty)
        XCTAssertFalse(PendingUploadRecovery.hasConflicts(for: reference))
    }

    // MARK: - Helpers

    private func recoveredPayloads(_ lookup: PendingUploadRecovery.Lookup) throws -> [PendingUploadRecovery.Payload] {
        guard case .recovered(let payloads) = lookup else {
            XCTFail("Expected recovered payloads, got \(lookup)")
            throw UnexpectedLookup()
        }
        return payloads
    }

    private struct UnexpectedLookup: Error {}

    private func makeReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: "rev-A",
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }

    private func makeStoredMarker(
        for reference: DatabaseReference,
        payload: Data,
        isConflicted: Bool = true,
        createdAt: Date = Date(timeIntervalSince1970: 3_000)
    ) -> PendingUploadQueue.StoredMarker {
        let id = UUID()
        return PendingUploadQueue.StoredMarker(
            id: id,
            fileURL: URL(fileURLWithPath: "/recovery-test/queue/\(id.uuidString).json"),
            marker: PendingUploadQueue.Marker(
                databaseId: reference.id,
                encryptedBytesCacheURL: "cache.kdbx",
                openTimeSHA512: KDBXCrypto.sha512(payload),
                expectedRev: "rev-A",
                createdAt: createdAt,
                isConflicted: isConflicted,
                baseRev: "rev-A"
            )
        )
    }

    private final class FakeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var markers: [PendingUploadQueue.StoredMarker]
        private let files: [URL: Data]

        init(markers: [PendingUploadQueue.StoredMarker], files: [URL: Data]) {
            self.markers = markers
            self.files = files
        }

        func replaceMarker(_ marker: PendingUploadQueue.StoredMarker) {
            lock.withLock {
                markers.removeAll { $0.id == marker.id }
                markers.append(marker)
            }
        }

        var environment: PendingUploadRecovery.Environment {
            PendingUploadRecovery.Environment(
                listMarkers: { databaseId in
                    self.lock.withLock { self.markers.filter { $0.marker.databaseId == databaseId } }
                },
                cacheURL: { _ in URL(fileURLWithPath: "/recovery-test/cache.kdbx") },
                backupURLs: { _ in
                    [
                        URL(fileURLWithPath: "/recovery-test/backups/20260924-100000-000000.kdbx"),
                        URL(fileURLWithPath: "/recovery-test/backups/20260923-100000-000000.kdbx"),
                    ]
                },
                readData: { url in
                    guard let data = self.files[url] else { throw CocoaError(.fileReadNoSuchFile) }
                    return data
                },
                dropMarker: { storedMarker in
                    self.lock.withLock {
                        self.markers.removeAll { current in
                            current.id == storedMarker.id && current.marker == storedMarker.marker
                        }
                    }
                }
            )
        }
    }
}
