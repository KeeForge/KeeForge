import Foundation

/// AutoFill saves to a bookmarked local database that could only be written to
/// the shared copy, kept until the app merges them into the database file.
///
/// The Mac extension's sandbox cannot open the file behind the app's bookmark,
/// and the app replaces the shared copy from that file, so the shared copy
/// alone cannot hold such a save. Each one is kept here as the complete
/// encrypted database the extension wrote.
enum PendingLocalSaveStore {
    struct PendingSave: Sendable, Equatable {
        let databaseID: UUID
        let fileURL: URL
    }

    @discardableResult
    static func add(_ encryptedBytes: Data, for databaseID: UUID, now: Date = .now) throws -> PendingSave {
        let directoryURL = directoryURL(for: databaseID)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Named like a backup, so a save that cannot be merged moves into the
        // database's backups under the time it was made.
        var date = now
        var fileURL = directoryURL.appendingPathComponent(LocalDatabaseSaver.backupFilename(for: date), isDirectory: false)
        while FileManager.default.fileExists(atPath: fileURL.path) {
            date.addTimeInterval(0.000_001)
            fileURL = directoryURL.appendingPathComponent(LocalDatabaseSaver.backupFilename(for: date), isDirectory: false)
        }

        try CoordinatedFileReader.writeData(encryptedBytes, to: fileURL, options: .atomicProtected)
        return PendingSave(databaseID: databaseID, fileURL: fileURL)
    }

    /// Oldest first.
    static func saves(for databaseID: UUID) -> [PendingSave] {
        let directory = directoryURL(for: databaseID)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        // Rebuilt from the directory: the listing resolves symlinks in the
        // path, so its URLs can differ from the one `add` returned.
        return contents
            .filter { $0.pathExtension.lowercased() == "kdbx" }
            .map(\.lastPathComponent)
            .sorted()
            .map { PendingSave(databaseID: databaseID, fileURL: directory.appendingPathComponent($0, isDirectory: false)) }
    }

    static func hasSaves(for databaseID: UUID) -> Bool {
        saves(for: databaseID).isEmpty == false
    }

    static func remove(_ save: PendingSave) {
        try? FileManager.default.removeItem(at: save.fileURL)
    }

    /// Moves a save that cannot be merged into the database's backups, where
    /// Database Details lists it for export.
    static func moveToBackups(_ save: PendingSave, for reference: DatabaseReference) throws -> URL {
        let backupDirectoryURL = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        try FileManager.default.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var backupURL = backupDirectoryURL.appendingPathComponent(save.fileURL.lastPathComponent, isDirectory: false)
        var date = Date.now
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = backupDirectoryURL.appendingPathComponent(LocalDatabaseSaver.backupFilename(for: date), isDirectory: false)
            date.addTimeInterval(0.000_001)
        }

        try FileManager.default.moveItem(at: save.fileURL, to: backupURL)
        return backupURL
    }

    static func removeAll(for databaseID: UUID) {
        try? FileManager.default.removeItem(at: directoryURL(for: databaseID))
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static var rootURL: URL {
        AppGroupContainer.url.appendingPathComponent("pending-local-saves", isDirectory: true)
    }

    private static func directoryURL(for databaseID: UUID) -> URL {
        rootURL.appendingPathComponent(databaseID.uuidString, isDirectory: true)
    }
}
