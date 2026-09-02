import XCTest
@testable import KeeForge

/// App Group guardrail (macOS port, slice 01): the group container
/// Standing rule: only encrypted KDBX payloads, security-scoped bookmark
/// blobs, and filename metadata may be written there — never key material,
/// passwords, or decrypted content. These tests pin `SharedVaultStore`'s
/// write surface to exactly that shape. See
/// `KeeForge/Services/Persistence/AGENTS.md` for the guardrail note.
final class AppGroupGuardrailTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testCacheDirectoriesLiveUnderTheGroupContainer() {
        // On a physical device the group container lives under `/private/var`,
        // and Foundation drops the `/private` prefix only for paths that
        // already exist — so a not-yet-created cache directory would compare
        // unequal to its own parent. Normalize the prefix on both sides.
        func normalizedPath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }

        let containerPath = normalizedPath(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID)
                ?? FileManager.default.temporaryDirectory
        )
        let databasePath = normalizedPath(SharedVaultStore.databaseCacheDirectory)
        let cloudPath = normalizedPath(SharedVaultStore.cloudCacheDirectory)

        XCTAssertTrue(databasePath.hasPrefix(containerPath), "\(databasePath) is not under \(containerPath)")
        XCTAssertTrue(cloudPath.hasPrefix(containerPath), "\(cloudPath) is not under \(containerPath)")
    }

    func testCacheDatabaseCopyWritesOnlyKDBXPayloadsUnderTheContainer() throws {
        let encryptedBytes = Data("encrypted kdbx payload".utf8)
        let sourceURL = try makeTemporaryFileURL(name: "guardrail-test.kdbx", contents: encryptedBytes)

        try SharedVaultStore.cacheDatabaseCopy(encryptedBytes, sourceURL: sourceURL)

        let fm = FileManager.default
        let cachedFiles = try fm.contentsOfDirectory(
            at: SharedVaultStore.databaseCacheDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(cachedFiles.isEmpty)
        for file in cachedFiles {
            XCTAssertEqual(
                file.pathExtension.lowercased(),
                "kdbx",
                "Only .kdbx payloads may be cached in the group container (found \(file.lastPathComponent))"
            )
        }

        // The cached copy must be the encrypted bytes as handed in — the store
        // never transforms, decrypts, or augments them.
        let cachedURL = try XCTUnwrap(SharedVaultStore.loadCachedDatabaseURL())
        XCTAssertEqual(try Data(contentsOf: cachedURL), encryptedBytes)
    }

    func testSaveBookmarkStoresOnlyBookmarkBlobAndFilenameMetadata() throws {
        let sourceURL = try makeTemporaryFileURL(name: "guardrail-bookmark.kdbx")

        try SharedVaultStore.saveBookmark(for: sourceURL)

        let sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: SharedVaultStore.appGroupID))

        // The bookmark key must hold an opaque bookmark blob that resolves
        // back to the source URL — not a copy of the file or any secret.
        let bookmarkData = try XCTUnwrap(sharedDefaults.data(forKey: "savedDatabaseBookmark"))
        let resolved = try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: bookmarkData))
        XCTAssertEqual(resolved.url.lastPathComponent, sourceURL.lastPathComponent)

        // The filename key must hold exactly the filename — no paths beyond
        // the bookmark itself, no key material.
        XCTAssertEqual(sharedDefaults.string(forKey: "savedDatabaseFilename"), sourceURL.lastPathComponent)
    }

    private func makeTemporaryFileURL(name: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }
}
