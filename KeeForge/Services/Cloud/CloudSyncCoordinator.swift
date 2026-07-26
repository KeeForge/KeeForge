import Foundation

struct CloudSyncResolution: Sendable {
    enum Status: Equatable, Sendable {
        case current
        case downloaded
        case offlineCached
        case disconnectedCached
        case cachedWithError(String)
    }

    let reference: DatabaseReference
    let localURL: URL
    let data: Data
    let status: Status

    /// Shared with tests so banner assertions stay locale-agnostic.
    static let offlineCachedBannerMessage = String(localized: "Using the cached copy offline.")
    /// Shared with tests so banner assertions stay locale-agnostic.
    static let disconnectedCachedBannerMessage = String(localized: "Using the cached copy. Reconnect this cloud account to refresh.")

    var bannerMessage: String? {
        switch status {
        case .current, .downloaded:
            nil
        case .offlineCached:
            Self.offlineCachedBannerMessage
        case .disconnectedCached:
            Self.disconnectedCachedBannerMessage
        case .cachedWithError(let message):
            message
        }
    }
}

enum CloudSyncCoordinator {
    static func syncIfNeededForOpen(
        reference: DatabaseReference,
        allowCachedFallback: Bool = true,
        providerResolver: (String) -> CloudProvider? = CloudProviderRegistry.provider(for:),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> CloudSyncResolution {
        guard let metadata = reference.cloudSyncMetadata else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        var updatedReference = reference

        guard let provider = providerResolver(metadata.provider) else {
            return try fallbackResolutionIfPossible(
                reference: updatedReference,
                cacheURL: cacheURL,
                cacheExists: cacheExists,
                allowCachedFallback: allowCachedFallback,
                status: .disconnectedCached,
                error: CloudProviderError.notAuthenticated
            )
        }

        guard provider.isAuthenticated(accountId: metadata.accountId) else {
            return try fallbackResolutionIfPossible(
                reference: updatedReference,
                cacheURL: cacheURL,
                cacheExists: cacheExists,
                allowCachedFallback: allowCachedFallback,
                status: .disconnectedCached,
                error: CloudProviderError.notAuthenticated
            )
        }

        do {
            let remoteMetadata = try await provider.getMetadata(accountId: metadata.accountId, fileId: metadata.fileId)
            let needsDownload = remoteMetadata.requiresDownload(comparedTo: metadata, cacheExists: cacheExists)

            if needsDownload {
                try await downloadLatestCopy(
                    provider: provider,
                    metadata: metadata,
                    reference: updatedReference,
                    destinationURL: cacheURL,
                    progress: progress
                )
            }

            updatedReference.updateCloudSyncMetadata { cloudMetadata in
                cloudMetadata.remoteContentHash = remoteMetadata.contentHash
                cloudMetadata.remoteModifiedAt = remoteMetadata.modifiedDate
                cloudMetadata.remoteRev = remoteMetadata.rev
                cloudMetadata.lastSyncedAt = .now
                cloudMetadata.lastSyncError = nil
            }

            let data = try CoordinatedFileReader.readData(from: cacheURL)
            return CloudSyncResolution(
                reference: updatedReference,
                localURL: cacheURL,
                data: data,
                status: needsDownload ? .downloaded : .current
            )
        } catch {
            return try fallbackResolutionIfPossible(
                reference: updatedReference,
                cacheURL: cacheURL,
                cacheExists: cacheExists,
                allowCachedFallback: allowCachedFallback,
                status: CloudProviderError.isLikelyOffline(error) ? .offlineCached : .cachedWithError(CloudProviderError.message(for: error)),
                error: error
            )
        }
    }

    private static func fallbackResolutionIfPossible(
        reference: DatabaseReference,
        cacheURL: URL,
        cacheExists: Bool,
        allowCachedFallback: Bool,
        status: CloudSyncResolution.Status,
        error: Error
    ) throws -> CloudSyncResolution {
        var updatedReference = reference
        updatedReference.updateCloudSyncMetadata { cloudMetadata in
            cloudMetadata.lastSyncError = CloudProviderError.message(for: error)
        }

        guard allowCachedFallback, cacheExists else {
            throw error
        }

        let data = try CoordinatedFileReader.readData(from: cacheURL)
        return CloudSyncResolution(reference: updatedReference, localURL: cacheURL, data: data, status: status)
    }

    private static func downloadLatestCopy(
        provider: CloudProvider,
        metadata: CloudSyncMetadata,
        reference: DatabaseReference,
        destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let tempURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        try await provider.download(
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            to: tempURL,
            progress: progress
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            // The shared cache is the *only* home of an AutoFill save until its
            // pending upload drains. If a marker is still queued for this
            // database, the current cache bytes have not reached the cloud yet,
            // so preserve a recoverable backup before the remote copy replaces
            // them. The drainer's SHA-512 check then surfaces the overwrite as a
            // conflict instead of silently losing the local change.
            //
            // Ordering: rename the cache aside FIRST, then list markers. The
            // rename atomically pins which bytes are being replaced, and the
            // AutoFill save path enqueues its marker durably before writing
            // the cache — so any unuploaded bytes captured by the rename are
            // guaranteed to have their marker visible to this check. (Listing
            // before removal, as this code once did, left a window where
            // freshly written AutoFill bytes were removed with their marker
            // unseen.)
            let asideURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            try fileManager.moveItem(at: destinationURL, to: asideURL)
            do {
                if !PendingUploadQueue.listMarkers(for: reference.id).isEmpty {
                    try backUpCacheBeforePendingOverwrite(at: asideURL, reference: reference)
                }
                try fileManager.removeItem(at: asideURL)
            } catch {
                // A failed backup must never cost the local bytes: put the
                // cache back and fail the sync-down; the caller falls back to
                // the cached copy.
                try? fileManager.moveItem(at: asideURL, to: destinationURL)
                try? fileManager.removeItem(at: asideURL)
                throw error
            }
        }

        // If a concurrent AutoFill save recreated the cache after the rename
        // above, this move fails and the sync-down falls back to the cached
        // copy — which then holds the freshest local bytes. Preferable to
        // clobbering a save whose marker this pass never examined.
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        #if os(iOS)
        // iOS Data Protection; on macOS setting a protection class either
        // fails or leaves the file unreadable — FileVault covers at-rest
        // encryption there instead (see Data.WritingOptions.atomicProtected).
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destinationURL.path
        )
        #endif
    }

    /// Copies the soon-to-be-overwritten cache bytes (passed as `cacheURL`,
    /// which may be a renamed-aside copy) into the database's timestamped
    /// backup directory so a not-yet-uploaded AutoFill save stays recoverable
    /// through the existing restore UI. Deliberately fallible: when the backup
    /// cannot be written, the caller must NOT proceed with the overwrite —
    /// losing the only copy of unuploaded bytes is strictly worse than failing
    /// the cache refresh, which callers degrade from gracefully (sync-down
    /// falls back to the cached copy). The drainer's SHA-512 guard remains the
    /// second line of defense against pushing the wrong bytes.
    private static func backUpCacheBeforePendingOverwrite(
        at cacheURL: URL,
        reference: DatabaseReference
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path) else { return }

        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: nil)

        let backupURL = backupDirectory.appendingPathComponent(
            pendingOverwriteBackupFilename(for: .now),
            isDirectory: false
        )
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: cacheURL, to: backupURL)
    }

    /// Matches the `yyyyMMdd-HHmmss-uuuuuu.kdbx` shape used by the local and
    /// cloud savers so these backups sort correctly alongside them in the
    /// restore list.
    private static func pendingOverwriteBackupFilename(for date: Date) -> String {
        let utcCalendar = Calendar(identifier: .gregorian)
        let utcTimeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = utcCalendar.dateComponents(in: utcTimeZone, from: date)
        let microseconds = (components.nanosecond ?? 0) / 1_000

        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%06d.kdbx",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            microseconds
        )
    }

    /// User-invoked resolution for a conflicted pending upload (the orange
    /// badge in the database list): discards the conflicted markers so the
    /// badge clears, after writing a timestamped backup of the marker's
    /// payload bytes when those bytes still exist in the shared cache. When
    /// the cache no longer hashes to the marker's recorded SHA the payload is
    /// already gone (that is what made the marker conflict), so there is
    /// nothing left to back up — the earlier overwrite path took its own
    /// pre-overwrite backup. Returns the number of markers discarded.
    static func discardConflictedPendingUploads(for reference: DatabaseReference) async -> Int {
        await Task.detached(priority: .utility) {
            let conflictedMarkers = PendingUploadQueue.listMarkers(for: reference.id)
                .filter { $0.marker.lastSyncError != nil }
            guard conflictedMarkers.isEmpty == false else { return 0 }

            let cacheURL = DatabaseListStore.cacheLocation(for: reference)
            let cacheSHA512 = (try? CoordinatedFileReader.readData(from: cacheURL))
                .map(KDBXCrypto.sha512)

            var discardedCount = 0
            for storedMarker in conflictedMarkers {
                if let cacheSHA512, cacheSHA512 == storedMarker.marker.openTimeSHA512 {
                    // Payload bytes are still the live cache; keep them
                    // recoverable through the restore UI before dropping the
                    // marker that protects them. A failed backup keeps the
                    // marker (and the badge) instead of discarding blind.
                    do {
                        try backUpCacheBeforePendingOverwrite(at: cacheURL, reference: reference)
                    } catch {
                        continue
                    }
                }
                if (try? PendingUploadQueue.drop(storedMarker)) != nil {
                    discardedCount += 1
                }
            }
            return discardedCount
        }.value
    }

    static func pushAfterSave(
        reference: DatabaseReference,
        bytes: Data,
        expectedRev: String?,
        providerResolver: (String) -> CloudProvider? = CloudProviderRegistry.provider(for:),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> DatabaseReference {
        guard let metadata = reference.cloudSyncMetadata else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        guard let provider = providerResolver(metadata.provider) else {
            throw CloudProviderError.notAuthenticated
        }

        let uploadedMetadata = try await provider.upload(
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            data: bytes,
            expectedRev: expectedRev,
            progress: progress
        )

        return try applyUploadedBytesAfterSave(
            reference: reference,
            bytes: bytes,
            remoteMetadata: uploadedMetadata
        )
    }

    static func applyUploadedBytesAfterSave(
        reference: DatabaseReference,
        bytes: Data,
        remoteMetadata: CloudFileMetadata
    ) throws -> DatabaseReference {
        // Same protection as `downloadLatestCopy`: an AutoFill save can land
        // in the cache while this upload was in flight, and its marker is on
        // disk before its bytes are (see `AutoFillSaveCoordinator`). If a
        // marker is queued and the cache differs from the bytes about to be
        // written, back the cache up before replacing it — the marker then
        // surfaces the overwrite as a conflict with the bytes recoverable,
        // instead of the refresh silently reverting the AutoFill save. When
        // the cache already equals `bytes` (every drain lands here, with its
        // own marker still queued until the caller drops it) there is nothing
        // to lose, so no backup is taken.
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        if !PendingUploadQueue.listMarkers(for: reference.id).isEmpty,
           let currentCacheBytes = try? CoordinatedFileReader.readData(from: cacheURL),
           KDBXCrypto.sha512(currentCacheBytes) != KDBXCrypto.sha512(bytes) {
            try backUpCacheBeforePendingOverwrite(at: cacheURL, reference: reference)
        }

        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)

        var updatedReference = reference
        updatedReference.updateCloudSyncMetadata { cloudMetadata in
            cloudMetadata.remoteContentHash = remoteMetadata.contentHash
            cloudMetadata.remoteModifiedAt = remoteMetadata.modifiedDate
            cloudMetadata.remoteRev = remoteMetadata.rev
            cloudMetadata.lastSyncedAt = .now
            cloudMetadata.lastSyncError = nil
        }
        DatabaseListStore.update(updatedReference)
        return updatedReference
    }
}
