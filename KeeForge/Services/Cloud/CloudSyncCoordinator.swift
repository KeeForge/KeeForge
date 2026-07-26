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

            // Prefer the metadata the download reported: it describes the
            // bytes now in the cache, not the head from before the transfer
            // (see `CloudProvider.download`). nil means the provider cannot
            // say, so the pre-download reading stands.
            var syncedMetadata = remoteMetadata
            if needsDownload {
                let downloadedMetadata = try await downloadLatestCopy(
                    provider: provider,
                    metadata: metadata,
                    reference: updatedReference,
                    destinationURL: cacheURL,
                    progress: progress
                )
                if let downloadedMetadata {
                    syncedMetadata = downloadedMetadata
                }
            }

            updatedReference.updateCloudSyncMetadata { cloudMetadata in
                cloudMetadata.remoteContentHash = syncedMetadata.contentHash
                cloudMetadata.remoteModifiedAt = syncedMetadata.modifiedDate
                cloudMetadata.remoteRev = syncedMetadata.rev
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
    ) async throws -> CloudFileMetadata? {
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        sweepOrphanedStagingFiles(in: directory)

        let tempURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let downloadedMetadata = try await provider.download(
            accountId: metadata.accountId,
            fileId: metadata.fileId,
            to: tempURL,
            progress: progress
        )

        // Stamped while the bytes are still staged, so the cache path is never
        // briefly unprotected once they land.
        try applyCacheFileProtection(at: tempURL)

        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try replaceCacheItem(at: destinationURL, withItemAt: tempURL, pinnedFileID: nil)
            try applyCacheFileProtection(at: destinationURL)
            return downloadedMetadata
        }

        // The shared cache is the *only* home of an AutoFill save until its
        // pending upload drains. If a marker is still queued for this
        // database, the current cache bytes have not reached the cloud yet,
        // so preserve a recoverable backup before the remote copy replaces
        // them. The drainer's SHA-512 check then surfaces the overwrite as a
        // conflict instead of silently losing the local change.
        //
        // Ordering: pin the superseded bytes FIRST, then list markers — the
        // AutoFill save writes its marker durably before the cache, so pinned
        // unuploaded bytes always have a marker visible here. Do not
        // reintroduce list-then-pin: it superseded fresh bytes marker-unseen.
        // The pin is a hard link, not a rename: a rename empties the cache
        // path for the whole backup write, and a crash there loses the cache.
        // No hard-link support fails the sync-down, the safe direction — the
        // caller falls back to the untouched cached copy.
        let pinnedURL = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try fileManager.linkItem(at: destinationURL, to: pinnedURL)
        defer {
            try? fileManager.removeItem(at: pinnedURL)
        }

        if !PendingUploadQueue.listMarkers(for: reference.id).isEmpty {
            // Deliberately not caught: a failed backup must never cost the
            // local bytes, and throwing here leaves the cache exactly as it
            // was — the caller degrades to the cached copy.
            try backUpCacheBeforePendingOverwrite(at: pinnedURL, reference: reference)
        }

        // Publish only if the cache is still the pinned file: a concurrent
        // AutoFill save between the pin and here holds bytes whose marker this
        // pass never examined, so the sync-down fails rather than clobbering
        // them (see `replaceCacheItem`).
        try replaceCacheItem(
            at: destinationURL,
            withItemAt: tempURL,
            pinnedFileID: fileID(at: pinnedURL)
        )
        try applyCacheFileProtection(at: destinationURL)
        return downloadedMetadata
    }

    /// iOS Data Protection for the shared cache. Applied to the staged copy
    /// before the swap and again after it: `replaceItemAt` carries some
    /// original metadata onto the replacement, but not reliably the protection
    /// class. No-op on macOS, where setting one either fails or leaves the
    /// file unreadable — FileVault covers at-rest encryption there instead.
    private static func applyCacheFileProtection(at url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// Installs `replacementURL` at `destinationURL` as one atomic swap under
    /// a coordinated `.forReplacing` write — the primitive every other cache
    /// writer uses — so readers never observe a partial or missing file.
    ///
    /// Conditional on the destination still being what the caller inspected:
    /// `pinnedFileID` is the identity it pinned, or nil when it found no
    /// cache. A mismatch means a concurrent writer got there first and the
    /// replace is abandoned. The comparison sits inside the coordination
    /// block, and every cache writer coordinates, so nothing slips between
    /// check and swap. Internal for testing.
    static func replaceCacheItem(
        at destinationURL: URL,
        withItemAt replacementURL: URL,
        pinnedFileID: UInt64?
    ) throws {
        let fileManager = FileManager.default
        var coordinatorError: NSError?
        var result: Result<Void, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                guard fileManager.fileExists(atPath: coordinatedURL.path) else {
                    guard pinnedFileID == nil else {
                        // The pinned cache vanished under us.
                        throw CocoaError(.fileNoSuchFile)
                    }
                    try fileManager.moveItem(at: replacementURL, to: coordinatedURL)
                    return
                }

                guard let pinnedFileID, fileID(at: coordinatedURL) == pinnedFileID else {
                    throw CocoaError(.fileWriteFileExists)
                }

                _ = try fileManager.replaceItemAt(
                    coordinatedURL,
                    withItemAt: replacementURL,
                    backupItemName: nil,
                    options: []
                )
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }

        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }

        try result.get()
    }

    /// Best-effort removal of staging leftovers in the shared cache
    /// directory. The staged download and the pin above are UUID-named
    /// siblings of the `<id>.kdbx` caches, normally deleted before the sync
    /// returns; a process death between creating one and its deferred removal
    /// strands it forever. Only entries parked for at least `age` are
    /// removed, so a concurrent sync's live staging files — which exist for
    /// seconds — are never touched. Age comes from the directory entry's
    /// "date added", NOT the inode dates: a pin is a hard link, so its
    /// creation/modification dates belong to the cache file it pinned and can
    /// be arbitrarily old, while the entry's own added date is stamped when
    /// the link is made. Entries with no readable added date are left alone.
    /// Internal for testing.
    static func sweepOrphanedStagingFiles(
        in directory: URL,
        olderThan age: TimeInterval = 3600,
        now: Date = .now
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.addedToDirectoryDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            guard
                let addedAt = try? entry.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate,
                now.timeIntervalSince(addedAt) >= age
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// The inode number backing `url`. A hard link reports the same value as
    /// the file it was made from, which is what lets the pin above recognize
    /// its own bytes. Internal for testing.
    static func fileID(at url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Copies the soon-to-be-overwritten cache bytes (`cacheURL` may be a
    /// pinned hard link) into the database's timestamped backup directory so a
    /// not-yet-uploaded AutoFill save stays recoverable through the restore
    /// UI. Deliberately fallible: callers must NOT overwrite when this throws
    /// — losing the only copy of unuploaded bytes is worse than failing the
    /// cache refresh. The drainer's SHA-512 guard is the second line of
    /// defense against pushing the wrong bytes.
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
    /// badge in the database list): backs the marker's payload bytes up while
    /// they are still the live cache, then discards the markers so the badge
    /// clears. A cache that no longer hashes to the recorded SHA means the
    /// payload is already gone — the overwrite path took its own backup.
    /// Returns the number of markers discarded.
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
                    // Keep the payload recoverable before dropping the marker
                    // that protects it. A failed backup keeps the marker (and
                    // the badge) instead of discarding blind.
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
        // in the cache while this upload was in flight. A queued marker plus a
        // cache differing from `bytes` means unuploaded bytes are about to be
        // reverted, so back them up first. Equal bytes (every drain lands
        // here, marker still queued) have nothing to lose.
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        if !PendingUploadQueue.listMarkers(for: reference.id).isEmpty,
           let currentCacheBytes = try? CoordinatedFileReader.readData(from: cacheURL),
           KDBXCrypto.sha512(currentCacheBytes) != KDBXCrypto.sha512(bytes) {
            try backUpCacheBeforePendingOverwrite(at: cacheURL, reference: reference)
        }

        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)

        var updatedReference = reference
        updatedReference.updateCloudSyncMetadata { cloudMetadata in
            // An upload response can omit rev/hash (OneDrive session
            // completions). Nilling a good recorded value would send every
            // later save into the nil-rev conflict fallback.
            if let contentHash = remoteMetadata.contentHash {
                cloudMetadata.remoteContentHash = contentHash
            }
            cloudMetadata.remoteModifiedAt = remoteMetadata.modifiedDate
            if let rev = remoteMetadata.rev {
                cloudMetadata.remoteRev = rev
            }
            cloudMetadata.lastSyncedAt = .now
            cloudMetadata.lastSyncError = nil
        }
        DatabaseListStore.update(updatedReference)
        return updatedReference
    }
}
