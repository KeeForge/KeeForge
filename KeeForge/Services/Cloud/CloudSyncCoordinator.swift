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
            if !PendingUploadQueue.listMarkers(for: reference.id).isEmpty {
                try backUpCacheBeforePendingOverwrite(at: destinationURL, reference: reference)
            }
            try fileManager.removeItem(at: destinationURL)
        }

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

    /// Copies the soon-to-be-overwritten cache into the database's timestamped
    /// backup directory so a not-yet-uploaded AutoFill save stays recoverable
    /// through the existing restore UI. Best-effort by design: a backup failure
    /// must not block the sync-down, and the drainer's SHA-512 guard is the
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
