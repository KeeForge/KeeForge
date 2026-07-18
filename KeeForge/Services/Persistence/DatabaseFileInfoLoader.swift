import Foundation

/// Display-only facts about a database file for the details sheet.
struct DatabaseFileInfo: Equatable, Sendable {
    var fileSizeBytes: Int64?
    var modifiedAt: Date?
    var summary: KDBXFileSummary?
}

/// Reads file size, modification date, and the plaintext KDBX header summary
/// for a database reference without unlocking it. Cloud-backed references use
/// the locally cached copy; local references resolve their bookmark.
enum DatabaseFileInfoLoader {
    /// Real KDBX outer headers are well under a kilobyte; 64 KiB leaves room
    /// for unknown plugin header fields without reading attachment-heavy files
    /// in full.
    static let headerPrefixByteCount = 64 * 1024
    private static let readTimeout: Duration = .seconds(10)

    static func load(for reference: DatabaseReference) async -> DatabaseFileInfo? {
        try? await CoordinatedFileReader.performBlocking(timeout: readTimeout) {
            readInfo(for: reference)
        }
    }

    private static func readInfo(for reference: DatabaseReference) -> DatabaseFileInfo? {
        if reference.isCloudBacked {
            guard let url = DatabaseListStore.cachedDatabaseURL(for: reference) else { return nil }
            return readInfo(at: url)
        }

        guard case .available(let url) = DatabaseListStore.locateDatabaseFile(for: reference) else {
            return nil
        }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return readInfo(at: url)
    }

    private static func readInfo(at url: URL) -> DatabaseFileInfo? {
        var info = DatabaseFileInfo()

        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            info.fileSizeBytes = values.fileSize.map(Int64.init)
            info.modifiedAt = values.contentModificationDate
        }

        if let prefix = try? CoordinatedFileReader.readDataPrefix(from: url, byteCount: headerPrefixByteCount) {
            info.summary = try? KDBXFileSummary.inspect(data: prefix)
        }

        guard info.fileSizeBytes != nil || info.modifiedAt != nil || info.summary != nil else {
            return nil
        }
        return info
    }
}
