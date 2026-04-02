import Foundation
import XCTest
@testable import KeeForge

enum TestDatabaseSupport {
    static func fixtureURL(
        named name: String = "test",
        extension ext: String = "kdbx",
        bundle: Bundle
    ) throws -> URL {
        try XCTUnwrap(bundle.url(forResource: name, withExtension: ext))
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
        let bookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)

        let keyFileBookmarkData: Data?
        let keyFileFilename: String?
        if let keyFileURL {
            keyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: keyFileURL)
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
}
