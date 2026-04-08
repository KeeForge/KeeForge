import Foundation

struct DatabaseReference: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var nickname: String?
    var filename: String
    var bookmarkData: Data?
    var keyFileBookmarkData: Data?
    var keyFileFilename: String?
    var isQuickLaunch: Bool
    var lastOpenedAt: Date?
    var addedAt: Date
    var colorTag: String?
    var legacyKeychainFilename: String?
    var isReadOnly: Bool = false
    var editsAcknowledgedAt: Date?
    var source: DatabaseSource = .local

    var displayName: String {
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedNickname, !trimmedNickname.isEmpty {
            return trimmedNickname
        }

        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? filename : stem
    }

    var showsFilenameSubtitle: Bool {
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedNickname, !trimmedNickname.isEmpty else {
            return false
        }
        return trimmedNickname != filename && trimmedNickname != (filename as NSString).deletingPathExtension
    }

    var hasAssociatedKeyFile: Bool {
        keyFileBookmarkData != nil || keyFileFilename != nil
    }

    var isCloudBacked: Bool {
        if case .cloud = source {
            return true
        }
        return false
    }

    var cloudSyncMetadata: CloudSyncMetadata? {
        guard case .cloud(let metadata) = source else { return nil }
        return metadata
    }

    var cloudProviderKind: CloudProviderKind? {
        cloudSyncMetadata?.providerKind
    }

    var expectedCloudRevision: String? {
        cloudSyncMetadata?.remoteRev
    }

    mutating func updateCloudSyncMetadata(_ mutate: (inout CloudSyncMetadata) -> Void) {
        guard case .cloud(var metadata) = source else { return }
        mutate(&metadata)
        source = .cloud(metadata)
    }
}

extension DatabaseReference {
    private enum CodingKeys: String, CodingKey {
        case id
        case nickname
        case filename
        case bookmarkData
        case keyFileBookmarkData
        case keyFileFilename
        case isQuickLaunch
        case lastOpenedAt
        case addedAt
        case colorTag
        case legacyKeychainFilename
        case isReadOnly
        case editsAcknowledgedAt
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        filename = try container.decode(String.self, forKey: .filename)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        keyFileBookmarkData = try container.decodeIfPresent(Data.self, forKey: .keyFileBookmarkData)
        keyFileFilename = try container.decodeIfPresent(String.self, forKey: .keyFileFilename)
        isQuickLaunch = try container.decode(Bool.self, forKey: .isQuickLaunch)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        colorTag = try container.decodeIfPresent(String.self, forKey: .colorTag)
        legacyKeychainFilename = try container.decodeIfPresent(String.self, forKey: .legacyKeychainFilename)
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        editsAcknowledgedAt = try container.decodeIfPresent(Date.self, forKey: .editsAcknowledgedAt)
        source = try container.decodeIfPresent(DatabaseSource.self, forKey: .source) ?? .local
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encode(filename, forKey: .filename)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encodeIfPresent(keyFileBookmarkData, forKey: .keyFileBookmarkData)
        try container.encodeIfPresent(keyFileFilename, forKey: .keyFileFilename)
        try container.encode(isQuickLaunch, forKey: .isQuickLaunch)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(colorTag, forKey: .colorTag)
        try container.encodeIfPresent(legacyKeychainFilename, forKey: .legacyKeychainFilename)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encodeIfPresent(editsAcknowledgedAt, forKey: .editsAcknowledgedAt)
        try container.encode(source, forKey: .source)
    }
}
