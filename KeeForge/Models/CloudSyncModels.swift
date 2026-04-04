import Foundation

enum CloudProviderKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case dropbox = "dropbox"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dropbox:
            "Dropbox"
        }
    }

    var iconName: String {
        switch self {
        case .dropbox:
            "shippingbox.fill"
        }
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

    func requiresDownload(comparedTo cached: CloudSyncMetadata, cacheExists: Bool) -> Bool {
        guard cacheExists else { return true }

        if let contentHash, let cachedHash = cached.remoteContentHash {
            return contentHash != cachedHash
        }

        guard let cachedModifiedAt = cached.remoteModifiedAt else {
            return true
        }

        return modifiedDate != cachedModifiedAt
    }
}

struct CloudSyncMetadata: Codable, Hashable, Sendable {
    let provider: String
    let accountId: String
    let fileId: String
    let displayPath: String
    var remoteContentHash: String?
    var remoteModifiedAt: Date?
    var lastSyncedAt: Date?
    var lastSyncError: String?

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
