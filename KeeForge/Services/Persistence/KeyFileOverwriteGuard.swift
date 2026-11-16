import Foundation

/// Refuses to write a new key file over one a database still opens with. Until
/// a rekey commits, that file is the only way into the database and its backups.
enum KeyFileOverwriteGuard {
    struct KeyFileInUseError: LocalizedError {
        var errorDescription: String? {
            String(localized: "That file is a key file one of your databases still needs, so KeeForge did not replace it. Choose a different name or location for the new key file.")
        }
    }

    /// `keyFileData` catches a key file picked at unlock, which has no stored bookmark.
    static func check(
        _ destination: URL,
        keyFileData: [Data] = [],
        listedKeyFileURLs: () -> [URL] = { DatabaseListStore.databases.compactMap(DatabaseListStore.resolveKeyFileURL) }
    ) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        if listedKeyFileURLs().contains(where: { isSameFile($0, destination) }) {
            throw KeyFileInUseError()
        }
        if keyFileData.isEmpty == false, let existing = try? Data(contentsOf: destination), keyFileData.contains(existing) {
            throw KeyFileInUseError()
        }
    }

    private static func isSameFile(_ keyFile: URL, _ destination: URL) -> Bool {
        let accessed = keyFile.startAccessingSecurityScopedResource()
        defer { if accessed { keyFile.stopAccessingSecurityScopedResource() } }
        if canonicalPath(keyFile) == canonicalPath(destination) { return true }
        guard let first = identifier(keyFile), let second = identifier(destination) else { return false }
        return first.isEqual(second)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func identifier(_ url: URL) -> (any NSObjectProtocol)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}
