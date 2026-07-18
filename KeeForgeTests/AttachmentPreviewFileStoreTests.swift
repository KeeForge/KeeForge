import XCTest
@testable import KeeForge

@MainActor
final class AttachmentPreviewFileStoreTests: XCTestCase {
    override func tearDown() async throws {
        AttachmentPreviewFileStore.clearAll()
        try await super.tearDown()
    }

    func testWriteCreatesReadableFileWithExpectedNameAndContents() throws {
        let data = Data("attachment-bytes".utf8)
        let url = try AttachmentPreviewFileStore.write(data, suggestedName: "notes.txt")

        XCTAssertEqual(url.lastPathComponent, "notes.txt")
        XCTAssertEqual(try Data(contentsOf: url), data)

        AttachmentPreviewFileStore.remove(url)
    }

    func testRemoveDeletesTheFile() throws {
        let url = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        AttachmentPreviewFileStore.remove(url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearAllRemovesEveryTrackedFile() throws {
        let first = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a.txt")
        let second = try AttachmentPreviewFileStore.write(Data("y".utf8), suggestedName: "b.txt")

        AttachmentPreviewFileStore.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testSanitizesUnsafeCharactersAndEmptyNames() throws {
        let url = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a/b:c\\d")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertFalse(url.lastPathComponent.contains("\\"))
        AttachmentPreviewFileStore.remove(url)

        let fallbackURL = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "")
        XCTAssertEqual(fallbackURL.lastPathComponent, "attachment")
        AttachmentPreviewFileStore.remove(fallbackURL)
    }

    func testPurgeOrphanedFilesDeletesLeftoversFromPriorSession() throws {
        // Simulate a file orphaned by a crashed prior process: it exists on
        // disk under the preview directory but is not tracked in memory.
        let fm = FileManager.default
        let orphanDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-previews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        let orphan = orphanDirectory.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: orphan)

        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertFalse(fm.fileExists(atPath: orphanDirectory.path))
    }

    func testPurgeOrphanedFilesKeepsLivePreviewsFromCurrentSession() throws {
        let url = try AttachmentPreviewFileStore.write(Data("live".utf8), suggestedName: "live.txt")

        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), Data("live".utf8))

        AttachmentPreviewFileStore.remove(url)
    }

    func testDistinctWritesWithSameNameDoNotCollide() throws {
        let first = try AttachmentPreviewFileStore.write(Data("first".utf8), suggestedName: "same.txt")
        let second = try AttachmentPreviewFileStore.write(Data("second".utf8), suggestedName: "same.txt")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))

        AttachmentPreviewFileStore.remove(first)
        AttachmentPreviewFileStore.remove(second)
    }
}
