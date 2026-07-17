import XCTest
@testable import KeeForge

final class SharedVaultStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testSharedVaultStoreSaveLoadAndClearBookmark() throws {
        let url = try makeTemporaryFileURL(name: "shared-store-test.kdbx")

        try SharedVaultStore.saveBookmark(for: url)
        let loaded = try XCTUnwrap(SharedVaultStore.loadBookmarkedURL())
        XCTAssertEqual(loaded.path, url.path)

        SharedVaultStore.clearBookmark()
        XCTAssertNil(SharedVaultStore.loadBookmarkedURL())
    }

    func testDocumentPickerServiceDelegatesSaveLoadAndClear() throws {
        let url = try makeTemporaryFileURL(name: "doc-picker-test.kdbx")

        try DocumentPickerService.saveBookmark(for: url)
        let loaded = try XCTUnwrap(DocumentPickerService.loadBookmarkedURL())
        XCTAssertEqual(loaded.path, url.path)

        DocumentPickerService.clearBookmark()
        XCTAssertNil(DocumentPickerService.loadBookmarkedURL())
    }

    func testDocumentPickerRecognizesKDBXExtensionWithoutReadingHeader() {
        let url = URL(fileURLWithPath: "/tmp/vault.kdbx")
        var didReadHeader = false

        let isSupported = DocumentPickerService.isSupportedDatabaseFile(at: url) { _, _ in
            didReadHeader = true
            return Data()
        }

        XCTAssertTrue(isSupported)
        XCTAssertFalse(didReadHeader)
    }

    func testDatabasePickerContentTypesIncludeKDBXAndGenericItemFallback() {
        XCTAssertTrue(DocumentPickerService.databasePickerContentTypes.contains(DocumentPickerService.databaseContentType))
        XCTAssertTrue(DocumentPickerService.databasePickerContentTypes.contains(.item))
    }

    func testInvalidDatabaseSelectionAlertUsesFriendlyCopy() {
        XCTAssertEqual(
            DocumentPickerService.invalidDatabaseSelectionAlert(),
            .init(
                title: String(localized: "Invalid File"),
                message: String(localized: "Please select a KeePass .kdbx database.")
            )
        )
    }

    func testDocumentPickerRecognizesKDBXHeaderWhenProviderURLHasNoExtension() {
        let url = URL(fileURLWithPath: "/tmp/File Provider Storage/vault")

        let isSupported = DocumentPickerService.isSupportedDatabaseFile(at: url) { _, requestedBytes in
            XCTAssertEqual(requestedBytes, 8)
            return Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB, 0x4B, 0xB5, 0x00, 0x01])
        }

        XCTAssertTrue(isSupported)
    }

    func testDocumentPickerRejectsUnsupportedFileWhenExtensionAndHeaderDoNotMatch() {
        let url = URL(fileURLWithPath: "/tmp/readme.txt")

        let isSupported = DocumentPickerService.isSupportedDatabaseFile(at: url) { _, _ in
            Data("not-a-database".utf8)
        }

        XCTAssertFalse(isSupported)
    }

    func testSecurityScopedBookmarkManagerResolvesPlainBookmarkData() throws {
        let url = try makeTemporaryFileURL(name: "plain-bookmark.kdbx")
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let resolvedURL = try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: bookmarkData)?.url)

        XCTAssertEqual(resolvedURL.path, url.path)
    }

    func testPickerFailureAlertSuppressesUserCancelledError() {
        let cancelled = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        XCTAssertNil(DocumentPickerService.pickerFailureAlert(for: cancelled))
    }

    func testPickerFailureAlertUsesLocalizedDescription() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "File provider unavailable."]
        )

        XCTAssertEqual(
            DocumentPickerService.pickerFailureAlert(for: error),
            .init(title: String(localized: "Couldn’t Open File"), message: "File provider unavailable.")
        )
    }

    func testCacheDatabaseCopyWritesLoadableSharedCopy() throws {
        let sourceData = Data("cached database".utf8)
        let url = try makeTemporaryFileURL(name: "cache-test.kdbx", contents: sourceData)

        try SharedVaultStore.cacheDatabaseCopy(sourceData, sourceURL: url)

        let cachedURL = try XCTUnwrap(SharedVaultStore.loadCachedDatabaseURL())
        XCTAssertEqual(cachedURL.lastPathComponent, url.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: cachedURL), sourceData)
    }

    func testLoadDatabaseKeychainPathUsesStoredFilenameWithoutCache() throws {
        let url = try makeTemporaryFileURL(name: "keychain-path-test.kdbx")

        try SharedVaultStore.saveBookmark(for: url)

        let keychainPath = try XCTUnwrap(SharedVaultStore.loadDatabaseKeychainPath())
        XCTAssertEqual((keychainPath as NSString).lastPathComponent, url.lastPathComponent)
    }

    func testClearBookmarkRemovesCachedDatabaseCopy() throws {
        let sourceData = Data("cached database".utf8)
        let url = try makeTemporaryFileURL(name: "clear-cache-test.kdbx", contents: sourceData)

        try SharedVaultStore.saveBookmark(for: url)
        try SharedVaultStore.cacheDatabaseCopy(sourceData, sourceURL: url)
        XCTAssertNotNil(SharedVaultStore.loadCachedDatabaseURL())

        SharedVaultStore.clearBookmark()

        XCTAssertNil(SharedVaultStore.loadBookmarkedURL())
        XCTAssertNil(SharedVaultStore.loadCachedDatabaseURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: SharedVaultStore.databaseCacheDirectory.path))
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
