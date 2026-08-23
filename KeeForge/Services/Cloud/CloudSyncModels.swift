import Foundation

enum CloudProviderKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case dropbox = "dropbox"
    case oneDrive = "onedrive"
    case webDAV = "webdav"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dropbox:
            "Dropbox"
        case .oneDrive:
            "OneDrive"
        case .webDAV:
            "WebDAV"
        }
    }

    var iconName: String {
        switch self {
        case .dropbox:
            "shippingbox.fill"
        case .oneDrive:
            "cloud.fill"
        case .webDAV:
            "server.rack"
        }
    }

    /// Providers that are connected through an in-app server/username/password
    /// form rather than a hosted OAuth flow. Only WebDAV uses this path today.
    var usesManualConnectionForm: Bool {
        switch self {
        case .webDAV:
            true
        case .dropbox, .oneDrive:
            false
        }
    }

    /// Whether this provider should be offered in the app's UI on the current
    /// platform. This is the single choke point that gates which cloud
    /// providers appear in the Add/Import Database menus and the New Database
    /// destination picker. It does not touch `provider(for:)` resolution, so
    /// already-connected databases continue to open and sync.
    ///
    /// macOS ships WebDAV only for its first release. The Dropbox and OneDrive
    /// macOS OAuth paths (slice 03) are implemented and unit-tested but have
    /// never been validated end-to-end on a Mac, so they stay out of the macOS
    /// UI rather than shipping unproven; re-enabling them is a decision for a
    /// later release, not an oversight. iOS is unaffected — all providers
    /// remain visible there.
    var isAvailableOnCurrentPlatform: Bool {
        #if os(macOS)
        switch self {
        case .webDAV:
            return true
        case .dropbox, .oneDrive:
            return false
        }
        #else
        return true
        #endif
    }
}

struct CloudAccount: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let provider: String

    var providerKind: CloudProviderKind? {
        CloudProviderKind(rawValue: provider)
    }
}

struct CloudFile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    let modifiedDate: Date?
    let size: Int64?
}

struct CloudFileMetadata: Equatable, Sendable {
    let modifiedDate: Date
    let contentHash: String?
    let size: Int64
    let rev: String?

    init(
        modifiedDate: Date,
        contentHash: String?,
        size: Int64,
        rev: String? = nil
    ) {
        self.modifiedDate = modifiedDate
        self.contentHash = contentHash
        self.size = size
        self.rev = rev
    }

    func requiresDownload(comparedTo cached: CloudSyncMetadata, cacheExists: Bool) -> Bool {
        guard cacheExists else { return true }

        if let contentHash, let cachedHash = cached.remoteContentHash {
            return contentHash != cachedHash
        }

        if let rev, let cachedRev = cached.remoteRev {
            return rev != cachedRev
        }

        guard let cachedModifiedAt = cached.remoteModifiedAt else {
            return true
        }

        return modifiedDate != cachedModifiedAt
    }
}

struct CloudCreatedFile: Equatable, Sendable {
    let file: CloudFile
    let metadata: CloudFileMetadata
}

struct CloudSyncMetadata: Codable, Hashable, Sendable {
    let provider: String
    let accountId: String
    let fileId: String
    let displayPath: String
    var remoteContentHash: String?
    var remoteModifiedAt: Date?
    var remoteRev: String?
    var lastSyncedAt: Date?
    var lastSyncError: String?

    init(
        provider: String,
        accountId: String,
        fileId: String,
        displayPath: String,
        remoteContentHash: String?,
        remoteModifiedAt: Date?,
        remoteRev: String? = nil,
        lastSyncedAt: Date?,
        lastSyncError: String?
    ) {
        self.provider = provider
        self.accountId = accountId
        self.fileId = fileId
        self.displayPath = displayPath
        self.remoteContentHash = remoteContentHash
        self.remoteModifiedAt = remoteModifiedAt
        self.remoteRev = remoteRev
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
    }

    var isStale: Bool {
        lastSyncError != nil
    }

    var providerKind: CloudProviderKind? {
        CloudProviderKind(rawValue: provider)
    }

    func warningText(now: Date = .now, isAuthenticated: Bool) -> String? {
        if isAuthenticated == false {
            return "Disconnected"
        }

        if let lastSyncError, !lastSyncError.isEmpty {
            return lastSyncError
        }

        if let lastSyncedAt, now.timeIntervalSince(lastSyncedAt) > 86_400 {
            return "Sync older than 24h"
        }

        return nil
    }
}

enum DatabaseSource: Codable, Hashable, Sendable {
    case local
    case cloud(CloudSyncMetadata)
}
