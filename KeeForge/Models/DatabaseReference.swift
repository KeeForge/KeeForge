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
}
