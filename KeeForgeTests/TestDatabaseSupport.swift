import Foundation
import XCTest
@testable import KeeForge

enum TestDatabaseSupport {
    static func visibleRootGroupID(in rootGroup: KPGroup) -> UUID {
        if rootGroup.entries.isEmpty, rootGroup.groups.count == 1 {
            return rootGroup.groups[0].id
        }
        return rootGroup.id
    }

    static func fixtureURL(
        named name: String = "test",
        extension ext: String = "kdbx",
        subdirectory: String? = nil,
        bundle: Bundle
    ) throws -> URL {
        let url =
            bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) ??
            bundle.url(forResource: name, withExtension: ext)
        return try XCTUnwrap(url)
    }

    static func makeReference(
        for url: URL,
        id: UUID = UUID(),
        nickname: String? = nil,
        keyFileURL: URL? = nil,
        isQuickLaunch: Bool = false,
        lastOpenedAt: Date? = nil,
        addedAt: Date = .now,
        legacyKeychainFilename: String? = nil
    ) throws -> DatabaseReference {
        let bookmarkData = try makeBookmarkData(for: url)

        let keyFileBookmarkData: Data?
        let keyFileFilename: String?
        if let keyFileURL {
            keyFileBookmarkData = try makeBookmarkData(for: keyFileURL)
            keyFileFilename = keyFileURL.lastPathComponent
        } else {
            keyFileBookmarkData = nil
            keyFileFilename = nil
        }

        return DatabaseReference(
            id: id,
            nickname: nickname,
            filename: url.lastPathComponent,
            bookmarkData: bookmarkData,
            keyFileBookmarkData: keyFileBookmarkData,
            keyFileFilename: keyFileFilename,
            isQuickLaunch: isQuickLaunch,
            lastOpenedAt: lastOpenedAt,
            addedAt: addedAt,
            colorTag: nil,
            legacyKeychainFilename: legacyKeychainFilename
        )
    }

    // #if os(macOS): the sandboxed macOS test host cannot create
    // `.withSecurityScope` bookmarks for fixtures living in DerivedData — a
    // sandboxed process can only bookmark files it has full access to, and no
    // powerbox (user-selection) grant is possible in a headless test run. When
    // direct creation is denied, the fixture is copied into the host's
    // temporary directory (inside the sandbox container, where scoped
    // bookmarks work — the filename is preserved) and the copy is bookmarked
    // instead. iOS behavior is unchanged: creation succeeds directly there.
    private static func makeBookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        do {
            return try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        } catch {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return try SecurityScopedBookmarkManager.makeBookmarkData(for: copy)
        }
        #else
        return try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        #endif
    }
}
