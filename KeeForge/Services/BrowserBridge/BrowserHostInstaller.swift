#if os(macOS)
import AppKit
import Darwin
import Foundation

enum HostBrowser: String, CaseIterable, Sendable {
    case chrome, chromeBeta, chromium, brave, edge, vivaldi, arc, firefox

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .chromeBeta: "Chrome Beta"
        case .chromium: "Chromium"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .chrome: ["com.google.Chrome"]
        case .chromeBeta: ["com.google.Chrome.beta"]
        case .chromium: ["org.chromium.Chromium"]
        case .brave: ["com.brave.Browser"]
        case .edge: ["com.microsoft.edgemac"]
        case .vivaldi: ["com.vivaldi.Vivaldi"]
        case .arc: ["company.thebrowser.Browser"]
        case .firefox: ["org.mozilla.firefox"]
        }
    }

    var manifestRelativeDirectory: String {
        let parent: String = switch self {
        case .chrome: "Google/Chrome"
        case .chromeBeta: "Google/Chrome Beta"
        case .chromium: "Chromium"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc/User Data"
        case .firefox: "Mozilla"
        }
        return "Library/Application Support/\(parent)/NativeMessagingHosts"
    }

    var isFirefox: Bool { self == .firefox }
}

enum BrowserHostInstallerState: Equatable {
    case notInstalled, notSetUp, ready, needsRepair, accessLost, extensionIDNotConfigured
}

enum BrowserHostInstallerError: Error, Equatable {
    case grantCancelled, wrongFolder, browserParentMissing, accessLost
    case extensionIDNotConfigured, foreignManifest, unsafeManifest
}

struct BrowserHostBookmarkAccess {
    var create: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)
    var start: (URL) -> Bool
    var stop: (URL) -> Void

    static var live: Self {
        Self(
            create: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolve: {
                var stale = false
                let url = try URL(resolvingBookmarkData: $0, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        )
    }
}

protocol BrowserHostFileSystem {
    func isCanonicalPath(_ url: URL) -> Bool
    func directoryExists(_ url: URL) -> Bool
    func createManifestDirectory(in parent: URL) throws
    func read(in directory: URL) throws -> Data?
    func write(_ data: Data, in directory: URL) throws
    func remove(in directory: URL) throws
}

// Descriptor-relative operations refuse a symlinked folder or manifest and keep every mutation inside the granted directory.
struct BrowserHostLocalFileSystem: BrowserHostFileSystem {
    private let filename = BrowserBridgeIdentifiers.nativeHostName + ".json"

    func isCanonicalPath(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
    }

    func directoryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    // Opened by path: the sandbox grants the bookmarked folder, not the directories above it.
    private func inDirectory<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
        let fd = open(url.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BrowserHostInstallerError.accessLost }
        defer { close(fd) }
        return try body(fd)
    }

    func createManifestDirectory(in parent: URL) throws {
        try inDirectory(parent) { fd in
            guard mkdirat(fd, "NativeMessagingHosts", 0o700) == 0 || errno == EEXIST else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    func read(in directory: URL) throws -> Data? {
        try inDirectory(directory) { fd in try read(fd) }
    }

    private func read(_ directory: Int32) throws -> Data? {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw BrowserHostInstallerError.unsafeManifest
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536 else {
            throw BrowserHostInstallerError.unsafeManifest
        }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    private func checkOwnership(_ data: Data?) throws {
        guard let data else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == BrowserBridgeIdentifiers.nativeHostName else {
            throw BrowserHostInstallerError.foreignManifest
        }
    }

    func write(_ data: Data, in directory: URL) throws {
        try inDirectory(directory) { fd in
            try checkOwnership(read(fd))
            let temporary = ".keeforge-\(UUID().uuidString).tmp"
            let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(output); unlinkat(fd, temporary, 0) }
            try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: data)
            guard fsync(output) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try checkOwnership(read(fd))
            guard renameat(fd, temporary, fd, filename) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    func remove(in directory: URL) throws {
        try inDirectory(directory) { fd in
            guard let data = try read(fd) else { return }
            try checkOwnership(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["path"] as? String, path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().pathComponents.contains("KeeForge.app") else {
                throw BrowserHostInstallerError.foreignManifest
            }
            guard unlinkat(fd, filename, 0) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }
}

@MainActor
final class BrowserHostInstaller {
    struct FolderGrantRequest {
        let browser: HostBrowser
        let manifestDirectory: URL
        let directoryToGrant: URL
    }

    typealias FolderGrant = @MainActor (FolderGrantRequest) async throws -> URL?

    private let defaults: UserDefaults
    private let home: URL
    private let host: URL
    private let chromiumOrigins: [String]
    private let firefoxID: String
    private let files: any BrowserHostFileSystem
    private let bookmarks: BrowserHostBookmarkAccess
    private let isInstalled: (HostBrowser) -> Bool
    private let grantFolder: FolderGrant

    init(
        defaults: UserDefaults = .standard,
        home: URL = BrowserHostInstaller.realHomeDirectory(),
        appBundle: URL = Bundle.main.bundleURL,
        chromiumOrigins: [String] = BrowserBridgeIdentifiers.chromiumExtensionOrigins,
        firefoxID: String = BrowserBridgeIdentifiers.firefoxExtensionID,
        files: any BrowserHostFileSystem = BrowserHostLocalFileSystem(),
        bookmarks: BrowserHostBookmarkAccess = .live,
        isInstalled: @escaping (HostBrowser) -> Bool = { browser in
            browser.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        },
        grantFolder: @escaping FolderGrant
    ) {
        self.defaults = defaults
        self.home = home
        host = appBundle.appendingPathComponent("Contents/MacOS/keeforge-browser-host")
        self.chromiumOrigins = chromiumOrigins
        self.firefoxID = firefoxID
        self.files = files
        self.bookmarks = bookmarks
        self.isInstalled = isInstalled
        self.grantFolder = grantFolder
    }

    nonisolated static func realHomeDirectory() -> URL {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    func manifestDirectory(for browser: HostBrowser) -> URL {
        home.appendingPathComponent(browser.manifestRelativeDirectory, isDirectory: true)
    }

    private func bookmarkKey(_ browser: HostBrowser) -> String { "browserHost.folderBookmark.\(browser.rawValue)" }

    func manifest(for browser: HostBrowser) throws -> Data {
        let allowed = browser.isFirefox ? [firefoxID].filter { !$0.isEmpty } : chromiumOrigins
        guard !allowed.isEmpty else { throw BrowserHostInstallerError.extensionIDNotConfigured }
        let object: [String: Any] = [
            "name": BrowserBridgeIdentifiers.nativeHostName,
            "description": "KeeForge browser integration",
            "path": host.path,
            "type": "stdio",
            browser.isFirefox ? "allowed_extensions" : "allowed_origins": allowed
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func withStoredGrant<T>(_ browser: HostBrowser, _ body: (URL) throws -> T) throws -> T {
        guard let data = defaults.data(forKey: bookmarkKey(browser)) else { throw BrowserHostInstallerError.accessLost }
        let resolved = try bookmarks.resolve(data)
        guard !resolved.isStale else { throw BrowserHostInstallerError.accessLost }
        guard bookmarks.start(resolved.url) else { throw BrowserHostInstallerError.accessLost }
        defer { bookmarks.stop(resolved.url) }
        let directory = manifestDirectory(for: browser)
        try validateGrant(resolved.url, directory: directory)
        guard files.directoryExists(resolved.url), files.directoryExists(directory) else {
            throw BrowserHostInstallerError.accessLost
        }
        return try body(directory)
    }

    private func validateGrant(_ grant: URL, directory: URL) throws {
        let path = grant.standardizedFileURL.path
        guard grant.isFileURL, path == directory.standardizedFileURL.path || path == directory.deletingLastPathComponent().standardizedFileURL.path else {
            throw BrowserHostInstallerError.wrongFolder
        }
        guard files.isCanonicalPath(grant), files.isCanonicalPath(directory) else {
            throw BrowserHostInstallerError.unsafeManifest
        }
    }

    func state(for browser: HostBrowser) -> BrowserHostInstallerState {
        guard isInstalled(browser) else { return .notInstalled }
        guard let expected = try? manifest(for: browser) else { return .extensionIDNotConfigured }
        guard defaults.data(forKey: bookmarkKey(browser)) != nil else { return .notSetUp }
        do {
            return try withStoredGrant(browser) { directory in
                guard let actual = try files.read(in: directory),
                      let object = try? JSONSerialization.jsonObject(with: actual) as? NSDictionary,
                      let desired = try? JSONSerialization.jsonObject(with: expected) as? NSDictionary,
                      object == desired else { return .needsRepair }
                return .ready
            }
        } catch BrowserHostInstallerError.unsafeManifest { return .needsRepair }
        catch { return .accessLost }
    }

    func setUp(_ browser: HostBrowser) async throws {
        let data = try manifest(for: browser)
        let directory = manifestDirectory(for: browser)
        let target = files.directoryExists(directory) ? directory : directory.deletingLastPathComponent()
        guard let grant = try await grantFolder(.init(browser: browser, manifestDirectory: directory, directoryToGrant: target)) else {
            throw BrowserHostInstallerError.grantCancelled
        }
        guard grant.standardizedFileURL.path == target.standardizedFileURL.path else { throw BrowserHostInstallerError.wrongFolder }
        guard bookmarks.start(grant) else { throw BrowserHostInstallerError.accessLost }
        defer { bookmarks.stop(grant) }
        try validateGrant(grant, directory: directory)
        guard files.directoryExists(grant) else { throw BrowserHostInstallerError.browserParentMissing }
        if !files.directoryExists(directory) { try files.createManifestDirectory(in: grant) }
        try validateGrant(grant, directory: directory)
        let bookmark = try bookmarks.create(grant)
        try files.write(data, in: directory)
        defaults.set(bookmark, forKey: bookmarkKey(browser))
    }

    @discardableResult
    func repairAll() -> [HostBrowser: BrowserHostInstallerState] {
        for browser in HostBrowser.allCases where state(for: browser) == .needsRepair {
            try? withStoredGrant(browser) { try files.write(manifest(for: browser), in: $0) }
        }
        return Dictionary(uniqueKeysWithValues: HostBrowser.allCases.map { ($0, state(for: $0)) })
    }

    func remove(_ browser: HostBrowser) throws {
        defer { defaults.removeObject(forKey: bookmarkKey(browser)) }
        guard defaults.data(forKey: bookmarkKey(browser)) != nil else { return }
        try withStoredGrant(browser) { try files.remove(in: $0) }
    }

    @discardableResult
    func removeAll() -> [HostBrowser: BrowserHostInstallerError] {
        var errors: [HostBrowser: BrowserHostInstallerError] = [:]
        for browser in HostBrowser.allCases {
            do { try remove(browser) }
            catch { errors[browser] = (error as? BrowserHostInstallerError) ?? .accessLost }
        }
        return errors
    }
}
#endif
