import XCTest
@testable import KeeForge

final class DatabaseFileInfoLoaderTests: XCTestCase {
    private var scratchDirectory: URL!

    override func setUpWithError() throws {
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseFileInfoLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    private func makeLocalReference(
        fixtureName: String,
        filename: String
    ) throws -> (reference: DatabaseReference, byteCount: Int) {
        let bundle = Bundle(for: DatabaseFileInfoLoaderTests.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: fixtureName, withExtension: "kdbx"))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let databaseURL = scratchDirectory.appendingPathComponent(filename)
        try fixtureData.write(to: databaseURL)

        let reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: filename,
            bookmarkData: try SecurityScopedBookmarkManager.makeBookmarkData(for: databaseURL),
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )
        return (reference, fixtureData.count)
    }

    func testLoadReadsSizeDateAndHeaderSummaryForLocalReference() async throws {
        let (reference, byteCount) = try makeLocalReference(fixtureName: "test", filename: "loader-test.kdbx")

        let loaded = await DatabaseFileInfoLoader.load(for: reference)
        let info = try XCTUnwrap(loaded)

        XCTAssertEqual(info.fileSizeBytes, Int64(byteCount))
        XCTAssertNotNil(info.modifiedAt)

        let summary = try XCTUnwrap(info.summary)
        XCTAssertEqual(summary.formatVersion, .kdbx4(minor: 0))
        XCTAssertEqual(summary.cipher, .aes256CBC)
        XCTAssertEqual(
            summary.keyDerivation,
            .argon2d(iterations: 14, memoryBytes: 64 * 1024 * 1024, parallelism: 2)
        )
    }

    func testLoadReturnsNilWhenReferenceHasNoBookmark() async {
        let reference = DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "missing.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: .now,
            colorTag: nil,
            legacyKeychainFilename: nil
        )

        let info = await DatabaseFileInfoLoader.load(for: reference)

        XCTAssertNil(info)
    }
}
