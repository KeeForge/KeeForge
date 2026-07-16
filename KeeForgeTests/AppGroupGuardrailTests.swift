import XCTest
@testable import KeeForge

/// App Group guardrail (macOS port, slice 01): the group container
/// `group.com.keevault.shared` is user-world-readable on macOS 14, unlike iOS.
/// Standing rule: only encrypted KDBX payloads, security-scoped bookmark
/// blobs, and filename metadata may be written there — never key material,
/// passwords, or decrypted content. These tests pin `SharedVaultStore`'s
/// write surface to exactly that shape. See
/// `KeeForge/Services/Persistence/README.md` for the guardrail note.
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
        let containerPath = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID)?
            .standardizedFileURL.path
            ?? FileManager.default.temporaryDirectory.standardizedFileURL.path

        XCTAssertTrue(SharedVaultStore.databaseCacheDirectory.standardizedFileURL.path.hasPrefix(containerPath))
        XCTAssertTrue(SharedVaultStore.cloudCacheDirectory.standardizedFileURL.path.hasPrefix(containerPath))
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
