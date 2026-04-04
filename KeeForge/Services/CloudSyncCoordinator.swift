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

    var bannerMessage: String? {
        switch status {
        case .current, .downloaded:
            nil
        case .offlineCached:
            "Using the cached copy offline."
        case .disconnectedCached:
            "Using the cached copy. Reconnect this cloud account to refresh."
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
                    destinationURL: cacheURL,
                    progress: progress
                )
            }

            updatedReference.updateCloudSyncMetadata { cloudMetadata in
                cloudMetadata.remoteContentHash = remoteMetadata.contentHash
                cloudMetadata.remoteModifiedAt = remoteMetadata.modifiedDate
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
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destinationURL.path
        )
    }
}
