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

/// An error that knows which `CloudSyncIssue` it represents, so recording it
/// keeps the code rather than falling back to a frozen sentence.
protocol CloudSyncIssueConvertible {
    var syncIssue: CloudSyncIssue { get }
}

/// Why a cloud sync last failed, recorded as a code rather than a rendered
/// sentence.
///
/// This outlives the failure: it is persisted in the database list and shown
/// again whenever the row is drawn, so a message localized at failure time
/// comes back in that language forever — including after the user switches
/// the device language. Storing the code and rendering it at display time
/// keeps the warning in the reader's language. Only `unknown` carries text,
/// because it wraps an error whose description the app did not write.
enum CloudSyncIssue: Hashable, Sendable {
    case invalidConfiguration
    case authenticationCancelled
    case notAuthenticated
    case networkUnavailable
    case fileNotFound
    case conflict
    case writeScopeRequired
    case rateLimited
    case serviceUnavailable
    case insufficientSpace
    case permissionDenied
    case invalidName
    case unknown(String)

    var localizedDescription: String {
        switch self {
        case .invalidConfiguration:
            String(localized: "Cloud sync is not configured for this build.")
        case .authenticationCancelled:
            String(localized: "Authentication was cancelled.")
        case .notAuthenticated:
            String(localized: "Please reconnect this cloud account.")
        case .networkUnavailable:
            String(localized: "No network connection. Using the cached copy if available.")
        case .fileNotFound:
            String(localized: "The remote database could not be found.")
        case .conflict:
            String(localized: "This database changed in the cloud. Reload before saving again.")
        case .writeScopeRequired:
            String(localized: "Reconnect this cloud account to save changes.")
        case .rateLimited:
            String(localized: "The cloud service is busy right now. Try again in a moment.")
        case .serviceUnavailable:
            String(localized: "The cloud service is temporarily unavailable. Try again later.")
        case .insufficientSpace:
            String(localized: "There isn't enough storage space in this cloud account.")
        case .permissionDenied:
            String(localized: "You don't have permission to change this file.")
        case .invalidName:
            String(localized: "The cloud service rejected this file name.")
        case .unknown(let message):
            message
        }
    }
}

extension CloudSyncIssue: Codable {
    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    /// Persisted discriminator. These strings are on disk in every user's
    /// database list — renaming one silently downgrades that issue to
    /// `unknown` on the next launch.
    private var code: String {
        switch self {
        case .invalidConfiguration: "invalidConfiguration"
        case .authenticationCancelled: "authenticationCancelled"
        case .notAuthenticated: "notAuthenticated"
        case .networkUnavailable: "networkUnavailable"
        case .fileNotFound: "fileNotFound"
        case .conflict: "conflict"
        case .writeScopeRequired: "writeScopeRequired"
        case .rateLimited: "rateLimited"
        case .serviceUnavailable: "serviceUnavailable"
        case .insufficientSpace: "insufficientSpace"
        case .permissionDenied: "permissionDenied"
        case .invalidName: "invalidName"
        case .unknown: "unknown"
        }
    }

    private init?(code: String) {
        switch code {
        case "invalidConfiguration": self = .invalidConfiguration
        case "authenticationCancelled": self = .authenticationCancelled
        case "notAuthenticated": self = .notAuthenticated
        case "networkUnavailable": self = .networkUnavailable
        case "fileNotFound": self = .fileNotFound
        case "conflict": self = .conflict
        case "writeScopeRequired": self = .writeScopeRequired
        case "rateLimited": self = .rateLimited
        case "serviceUnavailable": self = .serviceUnavailable
        case "insufficientSpace": self = .insufficientSpace
        case "permissionDenied": self = .permissionDenied
        case "invalidName": self = .invalidName
        default: return nil
        }
    }

    /// An unrecognized code decodes as `unknown` rather than throwing. This
    /// value sits inside `DatabaseReference`, and `DatabaseListStore` decodes
    /// the stored list all-or-nothing — one throw here would empty the user's
    /// database list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        self = Self(code: code) ?? .unknown(message ?? code)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        if case .unknown(let message) = self {
            try container.encode(message, forKey: .message)
        }
    }
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
    var lastSyncIssue: CloudSyncIssue?

    init(
        provider: String,
        accountId: String,
        fileId: String,
        displayPath: String,
        remoteContentHash: String?,
        remoteModifiedAt: Date?,
        remoteRev: String? = nil,
        lastSyncedAt: Date?,
        lastSyncIssue: CloudSyncIssue?
    ) {
        self.provider = provider
        self.accountId = accountId
        self.fileId = fileId
        self.displayPath = displayPath
        self.remoteContentHash = remoteContentHash
        self.remoteModifiedAt = remoteModifiedAt
        self.remoteRev = remoteRev
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncIssue = lastSyncIssue
    }

    var isStale: Bool {
        lastSyncIssue != nil
    }

    var providerKind: CloudProviderKind? {
        CloudProviderKind(rawValue: provider)
    }

    func warningText(now: Date = .now, isAuthenticated: Bool) -> String? {
        if isAuthenticated == false {
            return String(localized: "Disconnected")
        }

        if let lastSyncIssue {
            let message = lastSyncIssue.localizedDescription
            if message.isEmpty == false {
                return message
            }
        }

        if let lastSyncedAt, now.timeIntervalSince(lastSyncedAt) > 86_400 {
            return String(localized: "Sync older than 24h")
        }

        return nil
    }
}

enum DatabaseSource: Codable, Hashable, Sendable {
    case local
    case cloud(CloudSyncMetadata)
}
