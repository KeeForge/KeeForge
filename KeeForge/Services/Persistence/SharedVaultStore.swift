import Foundation

enum SharedVaultStore {
    static let appGroupID = "group.com.keevault.shared"

    private static let bookmarkKey = "savedDatabaseBookmark"
    private static let databaseFilenameKey = "savedDatabaseFilename"
    private static let databaseCacheDirectoryName = "databases"
    private static let cloudCacheDirectoryName = "cloud-cache"

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private static var sharedContainerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.temporaryDirectory
    }

    /// The `UserDefaults` backing cloud-account records, chosen per platform.
    ///
    /// Cloud-account records carry PII (Dropbox/OneDrive account emails,
    /// WebDAV "user@host/path" strings), so where they live is a privacy
    /// decision — the same one `FaviconService.cacheContainerURL` makes:
    ///
    /// - iOS keeps them in the App Group suite. The App Group is
    ///   sandbox-private on iOS, so nothing outside the app family can read
    ///   it. (The AutoFill extensions do not read this key today; iOS
    ///   behavior is simply left unchanged.)
    /// - macOS keeps them in the app's *own* sandbox defaults
    ///   (`UserDefaults.standard`) because the extension does not use them;
    ///   account emails and server paths do not belong in shared storage.
    ///
    /// Lives here (not on `CloudAccountStore`) because `DatabaseListStore`'s
    /// UI-test bootstrap seeds the same defaults and is compiled into the
    /// AutoFill extensions, which do not include `CloudAccountStore.swift`.
    /// `CloudAccountStore.defaults` wraps this. Extension-safe: pure Foundation.
    static var cloudAccountDefaults: UserDefaults {
        #if os(macOS)
        return .standard
        #else
        return UserDefaults(suiteName: appGroupID) ?? .standard
        #endif
    }

    static var databaseCacheDirectory: URL {
        sharedContainerURL.appendingPathComponent(databaseCacheDirectoryName, isDirectory: true)
    }

    static var cloudCacheDirectory: URL {
        sharedContainerURL.appendingPathComponent(cloudCacheDirectoryName, isDirectory: true)
    }

    static var legacyBookmarkData: Data? {
        sharedDefaults.data(forKey: bookmarkKey)
    }

    static var legacyDatabaseFilename: String? {
        storedDatabaseFilename
    }

    static var legacyCachedDatabaseURL: URL? {
        loadCachedDatabaseURL()
    }

    static func saveBookmark(for url: URL) throws {
        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        sharedDefaults.set(bookmarkData, forKey: bookmarkKey)
        sharedDefaults.set(databaseFilename(for: url), forKey: databaseFilenameKey)
    }

    static func loadBookmarkedURL() -> URL? {
        guard let data = sharedDefaults.data(forKey: bookmarkKey) else { return nil }
        guard let resolved = SecurityScopedBookmarkManager.resolveURL(from: data) else { return nil }
        let url = resolved.url

        if resolved.isStale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            try? saveBookmark(for: url)
        }

        if sharedDefaults.string(forKey: databaseFilenameKey) == nil {
            sharedDefaults.set(databaseFilename(for: url), forKey: databaseFilenameKey)
        }

        return url
    }

    static func cacheDatabaseCopy(_ data: Data, sourceURL: URL) throws {
        let filename = databaseFilename(for: sourceURL)
        let fm = FileManager.default

        if let storedDatabaseFilename, storedDatabaseFilename != filename {
            clearCachedDatabaseCopy()
        }

        if !fm.fileExists(atPath: databaseCacheDirectory.path) {
            try fm.createDirectory(at: databaseCacheDirectory, withIntermediateDirectories: true)
        }

        let cachedURL = cachedDatabaseURL(forFilename: filename)
        try CoordinatedFileReader.writeData(
            data,
            to: cachedURL,
            options: .atomicProtected
        )
        sharedDefaults.set(filename, forKey: databaseFilenameKey)
    }

    static func loadCachedDatabaseURL() -> URL? {
        guard let filename = storedDatabaseFilename else { return nil }
        let url = cachedDatabaseURL(forFilename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func loadDatabaseKeychainPath() -> String? {
        if let cachedURL = loadCachedDatabaseURL() {
            return cachedURL.path
        }

        if let filename = storedDatabaseFilename {
            return cachedDatabaseURL(forFilename: filename).path
        }

        return loadBookmarkedURL()?.path
    }

    static func clearCachedDatabaseCopy() {
        try? FileManager.default.removeItem(at: databaseCacheDirectory)
    }

    static func clearBookmark() {
        clearCachedDatabaseCopy()
        sharedDefaults.removeObject(forKey: bookmarkKey)
        sharedDefaults.removeObject(forKey: databaseFilenameKey)
    }

    private static var storedDatabaseFilename: String? {
        guard let filename = sharedDefaults.string(forKey: databaseFilenameKey), !filename.isEmpty else {
            return nil
        }
        return filename
    }

    private static func databaseFilename(for url: URL) -> String {
        let filename = (url.lastPathComponent as NSString).lastPathComponent
        return filename.isEmpty ? "database.kdbx" : filename
    }

    private static func cachedDatabaseURL(forFilename filename: String) -> URL {
        databaseCacheDirectory.appendingPathComponent(filename, isDirectory: false)
    }
}
