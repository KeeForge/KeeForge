import AuthenticationServices
import Foundation
import XCTest
@testable import KeeForge

final class CloudSyncCoordinatorTests: XCTestCase {
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

    // MARK: - Download-reported revision (L1)

    func testSyncRecordsRevisionReportedByTheDownloadItself() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "hash-before-download",
                size: 128,
                rev: "rev-before-download"
            )
        )
        // Someone else writes between the metadata probe and the transfer, so
        // the bytes that arrive belong to a later revision than the one the
        // probe reported. Recording the probe's revision would file these
        // bytes under a revision they never had.
        provider.downloadedMetadata = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 300),
            contentHash: "hash-of-downloaded-bytes",
            size: 256,
            rev: "rev-of-downloaded-bytes"
        )
        provider.downloadedData = Data("bytes-from-a-later-revision".utf8)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteRev, "rev-of-downloaded-bytes")
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteContentHash, "hash-of-downloaded-bytes")
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.remoteModifiedAt,
            Date(timeIntervalSince1970: 300)
        )
    }

    func testSyncKeepsPreDownloadMetadataWhenTheTransportCannotReportIt() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128,
                rev: "rev-B"
            )
        )
        provider.downloadedMetadata = nil
        provider.downloadedData = Data("fresh-cloud-copy".utf8)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteRev, "rev-B")
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteContentHash, "new-hash")
    }

    // MARK: - Cache replacement (M12)

    /// The coordinated replace stages the bytes beside the cache and pins the
    /// superseded copy with a hard link, so both have to be cleaned up. The
    /// crash-window property the replace exists for is structural and not
    /// observable from a test; this pins the parts that are.
    func testSyncReplacingAnExistingCacheLandsNewBytesAndLeavesNoStrayFiles() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("stale-cache".utf8), for: reference)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.data, Data("fresh-cloud-copy".utf8))
        XCTAssertEqual(try Data(contentsOf: cacheURL), Data("fresh-cloud-copy".utf8))
        let strays = try FileManager.default.contentsOfDirectory(
            atPath: cacheURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(strays, [cacheURL.lastPathComponent], "The pin and the staged download must both be cleaned up.")
    }

    // MARK: - Coordinated cache replace (M12, direct)

    // `replaceCacheItem` is the conditional swap the whole M12 race defense
    // hangs on: publish the downloaded bytes only if the cache is still the
    // exact file (inode) the caller pinned. These exercise it directly, one
    // per cell of the pinned × destination-state matrix.

    func testReplaceCacheItemSwapsBytesWhenDestinationStillMatchesThePin() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("cache.kdbx", isDirectory: false)
        try Data("superseded-cache".utf8).write(to: destination)
        let pin = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.linkItem(at: destination, to: pin)
        let replacement = directory.appendingPathComponent("staged-download", isDirectory: false)
        try Data("downloaded-bytes".utf8).write(to: replacement)

        try CloudSyncCoordinator.replaceCacheItem(
            at: destination,
            withItemAt: replacement,
            pinnedFileID: XCTUnwrap(CloudSyncCoordinator.fileID(at: pin))
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded-bytes".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: replacement.path),
            "The swap must consume the staged copy."
        )
        XCTAssertEqual(
            try Data(contentsOf: pin),
            Data("superseded-cache".utf8),
            "The pin must keep holding the superseded bytes it hard-linked."
        )
    }

    func testReplaceCacheItemRefusesWhenDestinationWasSwappedAfterPinning() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("cache.kdbx", isDirectory: false)
        try Data("pinned-cache".utf8).write(to: destination)
        let pin = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.linkItem(at: destination, to: pin)
        let pinnedFileID = try XCTUnwrap(CloudSyncCoordinator.fileID(at: pin))

        // A concurrent writer (an AutoFill save) replaces the cache between
        // the pin and the publish. The still-live pin keeps the pinned inode
        // allocated, so the new file cannot be assigned its identity.
        try FileManager.default.removeItem(at: destination)
        try Data("concurrent-autofill-save".utf8).write(to: destination)

        let replacement = directory.appendingPathComponent("staged-download", isDirectory: false)
        try Data("downloaded-bytes".utf8).write(to: replacement)

        XCTAssertThrowsError(
            try CloudSyncCoordinator.replaceCacheItem(
                at: destination,
                withItemAt: replacement,
                pinnedFileID: pinnedFileID
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("concurrent-autofill-save".utf8),
            "The concurrent writer's bytes must survive the refused replace."
        )
        XCTAssertEqual(
            try Data(contentsOf: replacement),
            Data("downloaded-bytes".utf8),
            "A refused replace leaves the staged copy for the caller's deferred cleanup."
        )
    }

    func testReplaceCacheItemInstallsIntoMissingDestinationWhenNothingWasPinned() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("cache.kdbx", isDirectory: false)
        let replacement = directory.appendingPathComponent("staged-download", isDirectory: false)
        try Data("first-download".utf8).write(to: replacement)

        try CloudSyncCoordinator.replaceCacheItem(
            at: destination,
            withItemAt: replacement,
            pinnedFileID: nil
        )

        XCTAssertEqual(try Data(contentsOf: destination), Data("first-download".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testReplaceCacheItemRefusesWhenPinnedDestinationVanished() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("cache.kdbx", isDirectory: false)
        try Data("pinned-cache".utf8).write(to: destination)
        let pin = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.linkItem(at: destination, to: pin)
        let pinnedFileID = try XCTUnwrap(CloudSyncCoordinator.fileID(at: pin))

        // A concurrent writer deleted the cache outright after the pin.
        try FileManager.default.removeItem(at: destination)

        let replacement = directory.appendingPathComponent("staged-download", isDirectory: false)
        try Data("downloaded-bytes".utf8).write(to: replacement)

        XCTAssertThrowsError(
            try CloudSyncCoordinator.replaceCacheItem(
                at: destination,
                withItemAt: replacement,
                pinnedFileID: pinnedFileID
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "The refused replace must not install anything at the vanished destination."
        )
        XCTAssertEqual(try Data(contentsOf: replacement), Data("downloaded-bytes".utf8))
    }

    func testReplaceCacheItemRefusesWhenDestinationAppearedAfterPinningFoundNone() throws {
        let directory = try makeScratchDirectory()
        let destination = directory.appendingPathComponent("cache.kdbx", isDirectory: false)
        // The caller found no cache to pin, but a concurrent writer created
        // one before the publish.
        try Data("concurrent-first-write".utf8).write(to: destination)
        let replacement = directory.appendingPathComponent("staged-download", isDirectory: false)
        try Data("downloaded-bytes".utf8).write(to: replacement)

        XCTAssertThrowsError(
            try CloudSyncCoordinator.replaceCacheItem(
                at: destination,
                withItemAt: replacement,
                pinnedFileID: nil
            )
        ) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("concurrent-first-write".utf8))
    }

    // MARK: - Orphaned staging sweep

    func testSweepRemovesParkedStagingFilesAndKeepsCaches() throws {
        let directory = try makeScratchDirectory()
        let orphanedDownload = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("dead-staged-download".utf8).write(to: orphanedDownload)
        let cache = directory.appendingPathComponent("\(UUID().uuidString).kdbx", isDirectory: false)
        try Data("live-cache".utf8).write(to: cache)
        let orphanedPin = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.linkItem(at: cache, to: orphanedPin)

        // The entries are seconds old; a `now` two hours out ages them past
        // the parked threshold.
        CloudSyncCoordinator.sweepOrphanedStagingFiles(
            in: directory,
            now: Date().addingTimeInterval(7200)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedDownload.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanedPin.path))
        XCTAssertEqual(
            try Data(contentsOf: cache),
            Data("live-cache".utf8),
            "Only UUID-named staging entries are swept; the .kdbx caches stay."
        )
    }

    func testSweepLeavesFreshStagingFilesForTheirRunningSync() throws {
        let directory = try makeScratchDirectory()
        let inFlightDownload = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data("in-flight-download".utf8).write(to: inFlightDownload)

        CloudSyncCoordinator.sweepOrphanedStagingFiles(in: directory)

        XCTAssertEqual(try Data(contentsOf: inFlightDownload), Data("in-flight-download".utf8))
    }

    func testSweepJudgesPinAgeByDirectoryEntryNotByPinnedInodeDates() throws {
        // A pin is a hard link, so its inode-level creation/modification
        // dates are those of the cache file it pinned — arbitrarily old the
        // moment the link is made. A sweep keyed on those dates would delete
        // a live pin out from under a running sync; the directory entry's own
        // "date added" must decide instead.
        let directory = try makeScratchDirectory()
        let cache = directory.appendingPathComponent("\(UUID().uuidString).kdbx", isDirectory: false)
        try Data("old-cache".utf8).write(to: cache)
        try FileManager.default.setAttributes(
            [
                .creationDate: Date(timeIntervalSince1970: 1_000),
                .modificationDate: Date(timeIntervalSince1970: 1_000),
            ],
            ofItemAtPath: cache.path
        )
        let freshPin = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.linkItem(at: cache, to: freshPin)

        CloudSyncCoordinator.sweepOrphanedStagingFiles(in: directory)

        XCTAssertEqual(
            try Data(contentsOf: freshPin),
            Data("old-cache".utf8),
            "A just-made pin to an old cache file must survive the sweep."
        )
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-sync-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func testSyncDownloadsFreshCopyWhenRemoteMetadataChanges() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)
        let progressRecorder = ProgressRecorder()

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider },
            progress: { progressRecorder.append($0) }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(resolution.data, Data("fresh-cloud-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertEqual(progressRecorder.values, [1])
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertEqual(resolution.reference.cloudSyncMetadata?.remoteContentHash, "new-hash")
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))),
            Data("fresh-cloud-copy".utf8)
        )
    }

    func testSyncDownloadBacksUpCacheWhenPendingUploadMarkerExists() async throws {
        // M2: the shared cache is the only home of an AutoFill save until its
        // pending upload drains. A sync-down that replaces the cache while a
        // marker is queued must first write a timestamped backup of the bytes
        // being replaced.
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let pendingBytes = Data("unuploaded-autofill-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(pendingBytes, for: reference)
        _ = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: reference.id, openTimeSHA512: KDBXCrypto.sha512(pendingBytes))
        )

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            Data("fresh-cloud-copy".utf8)
        )
        XCTAssertEqual(backupContents(for: reference), [pendingBytes])
    }

    func testSyncDownloadWithoutPendingMarkerWritesNoBackup() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("already-synced-bytes".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: Date(timeIntervalSince1970: 200),
                contentHash: "new-hash",
                size: 128
            )
        )
        provider.downloadedData = Data("fresh-cloud-copy".utf8)

        _ = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(backupContents(for: reference), [])
    }

    func testApplyUploadedBytesBacksUpDivergentCacheWhenPendingUploadMarkerExists() throws {
        // M2: an AutoFill save can land in the cache while an app-side upload
        // is in flight; the post-upload cache refresh must not silently revert
        // it. With a marker queued and the cache differing from the uploaded
        // bytes, a backup of the cache must be written before the overwrite.
        let reference = makeCloudReference(remoteContentHash: nil, remoteModifiedAt: nil)
        let autoFillBytes = Data("interleaved-autofill-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(autoFillBytes, for: reference)
        _ = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: reference.id, openTimeSHA512: KDBXCrypto.sha512(autoFillBytes))
        )

        let uploadedBytes = Data("app-save-uploaded-bytes".utf8)
        _ = try CloudSyncCoordinator.applyUploadedBytesAfterSave(
            reference: reference,
            bytes: uploadedBytes,
            remoteMetadata: CloudFileMetadata(modifiedDate: .now, contentHash: "uploaded", size: 64)
        )

        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            uploadedBytes
        )
        XCTAssertEqual(backupContents(for: reference), [autoFillBytes])
    }

    func testApplyUploadedBytesSkipsBackupWhenCacheAlreadyHoldsUploadedBytes() throws {
        // The drain path lands here with its own marker still queued (it is
        // dropped by the drainer afterwards) and the cache already holding the
        // pushed bytes — nothing can be lost, so no backup noise.
        let reference = makeCloudReference(remoteContentHash: nil, remoteModifiedAt: nil)
        let uploadedBytes = Data("drained-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(uploadedBytes, for: reference)
        _ = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: reference.id, openTimeSHA512: KDBXCrypto.sha512(uploadedBytes))
        )

        _ = try CloudSyncCoordinator.applyUploadedBytesAfterSave(
            reference: reference,
            bytes: uploadedBytes,
            remoteMetadata: CloudFileMetadata(modifiedDate: .now, contentHash: "uploaded", size: 64)
        )

        XCTAssertEqual(backupContents(for: reference), [])
    }

    func testApplyUploadedBytesKeepsRecordedRevAndHashWhenResponseOmitsThem() throws {
        // An upload response can omit rev/hash (OneDrive session completions).
        // Overwriting the recorded values with nil would push every later save
        // into the nil-rev conflict fallback — the recorded values must win.
        var reference = makeCloudReference(remoteContentHash: "hash-A", remoteModifiedAt: nil)
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-A"
        }
        let uploadedBytes = Data("uploaded-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(uploadedBytes, for: reference)

        let updated = try CloudSyncCoordinator.applyUploadedBytesAfterSave(
            reference: reference,
            bytes: uploadedBytes,
            remoteMetadata: CloudFileMetadata(modifiedDate: .now, contentHash: nil, size: 64, rev: nil)
        )

        XCTAssertEqual(updated.cloudSyncMetadata?.remoteRev, "rev-A")
        XCTAssertEqual(updated.cloudSyncMetadata?.remoteContentHash, "hash-A")
    }

    func testDiscardConflictedPendingUploadsBacksUpLivePayloadAndDropsOnlyConflictedMarkers() async throws {
        // M3 resolution affordance: discarding backs up the marker's payload
        // bytes when they are still the live cache, drops conflicted markers,
        // and leaves un-conflicted ones (which can still drain) untouched.
        let reference = makeCloudReference(remoteContentHash: nil, remoteModifiedAt: nil)
        let strandedBytes = Data("stranded-conflict-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(strandedBytes, for: reference)
        _ = try PendingUploadQueue.enqueue(
            makeMarker(
                databaseId: reference.id,
                openTimeSHA512: KDBXCrypto.sha512(strandedBytes),
                lastSyncError: "conflict"
            )
        )
        let healthyMarker = try PendingUploadQueue.enqueue(
            makeMarker(databaseId: reference.id, openTimeSHA512: Data("other-sha".utf8))
        )

        let discardedCount = await CloudSyncCoordinator.discardConflictedPendingUploads(for: reference)

        XCTAssertEqual(discardedCount, 1)
        XCTAssertEqual(backupContents(for: reference), [strandedBytes])
        let remaining = PendingUploadQueue.listMarkers(for: reference.id)
        XCTAssertEqual(remaining.map(\.id), [healthyMarker.id])
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            strandedBytes
        )
    }

    func testDiscardConflictedPendingUploadsWithoutLivePayloadDropsMarkerWithoutBackup() async throws {
        // When the cache no longer hashes to the marker's recorded payload,
        // those bytes are already gone (the overwrite path took its own
        // backup); discarding just clears the marker.
        let reference = makeCloudReference(remoteContentHash: nil, remoteModifiedAt: nil)
        try DatabaseListStore.cacheDatabaseCopy(Data("current-cache-bytes".utf8), for: reference)
        _ = try PendingUploadQueue.enqueue(
            makeMarker(
                databaseId: reference.id,
                openTimeSHA512: Data("vanished-payload-sha".utf8),
                lastSyncError: "conflict"
            )
        )

        let discardedCount = await CloudSyncCoordinator.discardConflictedPendingUploads(for: reference)

        XCTAssertEqual(discardedCount, 1)
        XCTAssertEqual(backupContents(for: reference), [])
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: reference.id).isEmpty)
    }

    private func makeMarker(
        databaseId: UUID,
        openTimeSHA512: Data,
        lastSyncError: String? = nil
    ) -> PendingUploadQueue.Marker {
        PendingUploadQueue.Marker(
            databaseId: databaseId,
            encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
            openTimeSHA512: openTimeSHA512,
            expectedRev: "rev-1",
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastSyncError: lastSyncError,
            baseRev: "rev-1"
        )
    }

    private func backupContents(for reference: DatabaseReference) -> [Data] {
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return fileURLs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
    }

    func testSyncReturnsCurrentWhenRemoteMetadataMatchesCachedCopy() async throws {
        let modifiedDate = Date(timeIntervalSince1970: 200)
        let reference = makeCloudReference(
            remoteContentHash: "same-hash",
            remoteModifiedAt: modifiedDate
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-current-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(
                modifiedDate: modifiedDate,
                contentHash: "same-hash",
                size: 128
            )
        )

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .current)
        XCTAssertEqual(resolution.data, Data("cached-current-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
        XCTAssertNotNil(resolution.reference.cloudSyncMetadata?.lastSyncedAt)
    }

    func testSyncFallsBackToCachedCopyWhenOffline() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-offline-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.networkUnavailable)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .offlineCached)
        XCTAssertEqual(resolution.data, Data("cached-offline-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, CloudSyncResolution.offlineCachedBannerMessage)
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.networkUnavailable.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenProviderIsUnavailable() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-disconnected-copy".utf8), for: reference)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in nil }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-disconnected-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, CloudSyncResolution.disconnectedCachedBannerMessage)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesDisconnectedCachedWhenAccountIsSignedOut() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-signed-out-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.authenticated = false

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .disconnectedCached)
        XCTAssertEqual(resolution.data, Data("cached-signed-out-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 0)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.notAuthenticated.errorDescription
        )
    }

    func testSyncUsesCachedCopyWithErrorForNonOfflineFailures() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-error-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(
            resolution.status,
            .cachedWithError(CloudProviderError.fileNotFound.localizedDescription)
        )
        XCTAssertEqual(resolution.data, Data("cached-error-copy".utf8))
        XCTAssertEqual(
            resolution.bannerMessage,
            CloudProviderError.fileNotFound.localizedDescription
        )
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.fileNotFound.localizedDescription
        )
    }

    func testSyncThrowsWhenCachedFallbackIsDisabled() async {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try? DatabaseListStore.cacheDatabaseCopy(Data("cached-but-disabled".utf8), for: reference)
        let provider = MockCloudProvider()
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        do {
            _ = try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                allowCachedFallback: false,
                providerResolver: { _ in provider }
            )
            XCTFail("Expected sync to throw when cached fallback is disabled.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Open-time probe deadline (#95)

    func testSyncOpensCachedCopyOfflineWhenProbeMissesDeadline() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "cached-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-black-hole-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataDelay = .seconds(60)
        provider.metadataResult = .success(
            CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 200), contentHash: "newer-hash", size: 128)
        )

        let startedAt = Date()
        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            probeDeadline: 0.2,
            providerResolver: { _ in provider }
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertEqual(resolution.status, .offlineCached)
        XCTAssertEqual(resolution.data, Data("cached-black-hole-copy".utf8))
        XCTAssertEqual(resolution.bannerMessage, CloudSyncResolution.offlineCachedBannerMessage)
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertTrue(provider.metadataProbeCancelled)
        XCTAssertEqual(provider.downloadCallCount, 0)
        XCTAssertEqual(
            resolution.reference.cloudSyncMetadata?.lastSyncError,
            CloudProviderError.networkUnavailable.errorDescription
        )
    }

    func testSyncWaitsOutSlowProbeWhenNoCacheExists() async {
        let reference = makeCloudReference(
            remoteContentHash: nil,
            remoteModifiedAt: nil
        )
        // The cache path depends only on provider/account/fileId, so a copy
        // written by another test would otherwise stand in here.
        try? FileManager.default.removeItem(at: DatabaseListStore.cacheLocation(for: reference))
        let provider = MockCloudProvider()
        provider.metadataDelay = .milliseconds(500)
        provider.metadataResult = .failure(CloudProviderError.fileNotFound)

        do {
            _ = try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                probeDeadline: 0.1,
                providerResolver: { _ in provider }
            )
            XCTFail("Expected sync to throw when there is no cache to fall back to.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertFalse(provider.metadataProbeCancelled)
    }

    func testSyncWaitsOutSlowProbeWhenCachedFallbackIsDisabled() async throws {
        let modifiedDate = Date(timeIntervalSince1970: 200)
        let reference = makeCloudReference(
            remoteContentHash: "same-hash",
            remoteModifiedAt: modifiedDate
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("cached-current-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataDelay = .milliseconds(500)
        provider.metadataResult = .success(
            CloudFileMetadata(modifiedDate: modifiedDate, contentHash: "same-hash", size: 128)
        )

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            allowCachedFallback: false,
            probeDeadline: 0.1,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .current)
        XCTAssertFalse(provider.metadataProbeCancelled)
    }

    func testSyncDeadlineCoversOnlyTheProbeNotTheDownload() async throws {
        let reference = makeCloudReference(
            remoteContentHash: "old-hash",
            remoteModifiedAt: Date(timeIntervalSince1970: 100)
        )
        try DatabaseListStore.cacheDatabaseCopy(Data("stale-copy".utf8), for: reference)

        let provider = MockCloudProvider()
        provider.metadataResult = .success(
            CloudFileMetadata(modifiedDate: Date(timeIntervalSince1970: 200), contentHash: "new-hash", size: 128)
        )
        provider.downloadDelay = .milliseconds(400)
        provider.downloadedData = Data("fresh-copy".utf8)

        let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
            reference: reference,
            probeDeadline: 0.1,
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(resolution.status, .downloaded)
        XCTAssertEqual(resolution.data, Data("fresh-copy".utf8))
        XCTAssertEqual(provider.metadataCallCount, 1)
        XCTAssertEqual(provider.downloadCallCount, 1)
        XCTAssertNil(resolution.reference.cloudSyncMetadata?.lastSyncError)
    }

    private func makeCloudReference(
        remoteContentHash: String?,
        remoteModifiedAt: Date?
    ) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: remoteContentHash,
                    remoteModifiedAt: remoteModifiedAt,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }
}

private final class MockCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    var authenticated = true
    var metadataResult: Result<CloudFileMetadata, Error> = .failure(CloudProviderError.fileNotFound)
    /// How long `getMetadata` sleeps before answering; models a slow or
    /// black-holed server. Cancellation cuts the sleep short.
    var metadataDelay: Duration = .zero
    var downloadDelay: Duration = .zero
    var downloadedData = Data()
    /// What `download` reports about the bytes it wrote. Nil models a
    /// transport that cannot say (OneDrive), where the caller must keep the
    /// pre-download reading.
    var downloadedMetadata: CloudFileMetadata?
    private(set) var metadataCallCount = 0
    private(set) var metadataProbeCancelled = false
    private(set) var downloadCallCount = 0
    private(set) var uploadCallCount = 0

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        XCTFail("authenticate(from:) should not be called in CloudSyncCoordinatorTests")
        throw CloudProviderError.authenticationCancelled
    }

    func isAuthenticated(accountId: String) -> Bool {
        authenticated
    }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] {
        XCTFail("listFiles(accountId:path:query:) should not be called in CloudSyncCoordinatorTests")
        return []
    }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        downloadCallCount += 1
        if downloadDelay > .zero {
            try await Task.sleep(for: downloadDelay)
        }
        try downloadedData.write(to: localURL)
        progress(1)
        return downloadedMetadata
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        metadataCallCount += 1
        if metadataDelay > .zero {
            do {
                try await Task.sleep(for: metadataDelay)
            } catch is CancellationError {
                metadataProbeCancelled = true
                throw CancellationError()
            }
        }
        return try metadataResult.get()
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        uploadCallCount += 1
        progress(1)
        return CloudFileMetadata(
            modifiedDate: Date(),
            contentHash: nil,
            size: Int64(data.count),
            rev: expectedRev
        )
    }
}

/// Lets a test hold a save at the point where it has started but not landed —
/// the window the macOS ⌘S command and a lock can both fall into.
actor SaveGate {
    private var hasStarted = false
    private var isOpen = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard hasStarted == false else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilOpen() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
}

actor SaveCallCounter {
    private(set) var value = 0

    /// Returns the ordinal of this call, so a caller can behave differently on
    /// the first one.
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// Records how a conflict copy reaches the provider. `upload` is the overwrite
/// route the copy must never take, so it fails the test outright.
final class ConflictCopyCloudProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    /// Paths a prior conflict copy already occupies; create-only rejects them.
    var pathsRejectedAsExisting: Set<String> = []
    var createFailure: CloudProviderError?
    private(set) var createdPaths: [String] = []
    private(set) var uploadCallCount = 0

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        XCTFail("authenticate(from:) should not be called for a conflict copy")
        throw CloudProviderError.authenticationCancelled
    }

    func isAuthenticated(accountId: String) -> Bool { true }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?) async throws -> [CloudFile] { [] }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? { nil }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        CloudFileMetadata(modifiedDate: Date(), contentHash: nil, size: 0)
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        uploadCallCount += 1
        XCTFail("A conflict copy must never take the overwriting upload route.")
        return CloudFileMetadata(modifiedDate: Date(), contentHash: nil, size: Int64(data.count))
    }

    func createFile(
        accountId: String,
        path: String,
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudCreatedFile {
        createdPaths.append(path)

        if let createFailure {
            throw createFailure
        }
        if pathsRejectedAsExisting.contains(path) {
            throw CloudProviderError.conflict(remoteRev: nil)
        }

        progress(1)
        return CloudCreatedFile(
            file: CloudFile(
                id: path,
                name: (path as NSString).lastPathComponent,
                path: path,
                isFolder: false,
                modifiedDate: Date(),
                size: Int64(data.count)
            ),
            metadata: CloudFileMetadata(modifiedDate: Date(), contentHash: nil, size: Int64(data.count))
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

