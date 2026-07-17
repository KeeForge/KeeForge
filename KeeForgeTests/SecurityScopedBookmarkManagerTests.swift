import XCTest
@testable import KeeForge

/// Covers the macOS-port load-bearing change: on macOS, bookmarks must be
/// created AND resolved with `.withSecurityScope` or file access silently
/// fails after relaunch under the sandbox. iOS behavior is unchanged
/// (implicit security scope, `options: []` in both directions).
final class SecurityScopedBookmarkManagerTests: XCTestCase {
    func testBookmarkRoundTripResolvesAndGrantsAccess() throws {
        let url = try makeTemporaryFileURL(name: "bookmark-roundtrip.kdbx")

        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        let resolved = try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: bookmarkData))

        XCTAssertEqual(resolved.url.path, url.path)
        XCTAssertFalse(resolved.isStale)

        // On macOS this exercises the `.withSecurityScope` resolution path;
        // start/stop must succeed and the file must be readable through it.
        let accessed = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if accessed { resolved.url.stopAccessingSecurityScopedResource() }
        }
        XCTAssertEqual(try Data(contentsOf: resolved.url), Data("fixture".utf8))
    }

    #if os(macOS)
    func testMacBookmarkIsCreatedWithSecurityScope() throws {
        let url = try makeTemporaryFileURL(name: "scoped-creation.kdbx")

        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)

        // Resolving with `.withSecurityScope` throws for bookmarks that were
        // not created with security scope, so a successful scoped resolution
        // proves the manager created a security-scoped bookmark on macOS.
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        XCTAssertEqual(resolved.path, url.path)

        let accessed = resolved.startAccessingSecurityScopedResource()
        defer {
            if accessed { resolved.stopAccessingSecurityScopedResource() }
        }
        XCTAssertEqual(try Data(contentsOf: resolved), Data("fixture".utf8))
    }

    func testMacResolutionFallsBackForPlainBookmarks() throws {
        // Older (plain) bookmark data must still resolve on macOS via the
        // documented fallback instead of returning nil.
        let url = try makeTemporaryFileURL(name: "plain-fallback.kdbx")
        let plainBookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let resolved = try XCTUnwrap(SecurityScopedBookmarkManager.resolveURL(from: plainBookmarkData))
        XCTAssertEqual(resolved.url.path, url.path)
    }
    #endif

    func testIsInTrashDirectoryMatchesExactTrashPathComponent() throws {
        let trashedURL = try makeTemporaryFileURL(name: ".Trash/trashed.kdbx")

        XCTAssertTrue(SecurityScopedBookmarkManager.isInTrashDirectory(trashedURL))
    }

    func testIsInTrashDirectoryMatchesNestedTrashSubfolder() throws {
        let trashedURL = try makeTemporaryFileURL(name: ".Trash/subfolder/trashed.kdbx")

        XCTAssertTrue(SecurityScopedBookmarkManager.isInTrashDirectory(trashedURL))
    }

    func testIsInTrashDirectoryIgnoresSimilarlyNamedFolders() throws {
        // Only the exact ".Trash" component counts; a user folder that merely
        // starts with the same prefix must stay fully usable.
        let lookalikeURL = try makeTemporaryFileURL(name: ".TrashCan/database.kdbx")

        XCTAssertFalse(SecurityScopedBookmarkManager.isInTrashDirectory(lookalikeURL))
    }

    func testIsInTrashDirectoryIsFalseForRegularFiles() throws {
        let url = try makeTemporaryFileURL(name: "regular.kdbx")

        XCTAssertFalse(SecurityScopedBookmarkManager.isInTrashDirectory(url))
    }

    private func makeTemporaryFileURL(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
}
