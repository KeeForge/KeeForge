import XCTest
@testable import KeeForge

@MainActor
final class AttachmentPreviewFileStoreTests: XCTestCase {
    private let owner = UUID()
    private let otherOwner = UUID()

    override func tearDown() async throws {
        AttachmentPreviewFileStore.clear(owner: owner)
        AttachmentPreviewFileStore.clear(owner: otherOwner)
        try await super.tearDown()
    }

    func testWriteCreatesReadableFileWithExpectedNameAndContents() throws {
        let data = Data("attachment-bytes".utf8)
        let url = try AttachmentPreviewFileStore.write(data, suggestedName: "notes.txt", owner: owner)

        XCTAssertEqual(url.lastPathComponent, "notes.txt")
        XCTAssertEqual(try Data(contentsOf: url), data)

        AttachmentPreviewFileStore.remove(url, owner: owner)
    }

    func testRemoveDeletesTheFile() throws {
        let url = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a.txt", owner: owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        AttachmentPreviewFileStore.remove(url, owner: otherOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        AttachmentPreviewFileStore.remove(url, owner: owner)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let orphan = url.deletingLastPathComponent().appendingPathComponent("orphan.txt")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)

        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testClearOwnerRemovesEveryOwnedFile() throws {
        let first = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a.txt", owner: owner)
        let second = try AttachmentPreviewFileStore.write(Data("y".utf8), suggestedName: "b.txt", owner: owner)

        let other = try AttachmentPreviewFileStore.write(
            Data("other".utf8), suggestedName: "c.txt", owner: otherOwner
        )

        AttachmentPreviewFileStore.clear(owner: owner)
        AttachmentPreviewFileStore.clear(owner: owner)
        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: other), Data("other".utf8))

        AttachmentPreviewFileStore.clear(owner: otherOwner)

        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testLockRemovesOnlyTheOwningSessionsPreviews() throws {
        let reference = DatabaseReference(
            id: UUID(), nickname: nil, filename: "preview-test.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: .now, colorTag: nil, legacyKeychainFilename: nil
        )
        let firstSession = DatabaseViewModel(databaseReference: reference)
        let secondSession = DatabaseViewModel(databaseReference: reference)
        defer {
            AttachmentPreviewFileStore.clear(owner: firstSession.attachmentPreviewOwnerID)
            AttachmentPreviewFileStore.clear(owner: secondSession.attachmentPreviewOwnerID)
        }
        let first = try AttachmentPreviewFileStore.write(
            Data("first".utf8), suggestedName: "a.txt", owner: firstSession.attachmentPreviewOwnerID
        )
        let second = try AttachmentPreviewFileStore.write(
            Data("second".utf8), suggestedName: "b.txt", owner: secondSession.attachmentPreviewOwnerID
        )

        firstSession.lock(preservingClipboard: true)
        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))

        secondSession.lock(preservingClipboard: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testSanitizesUnsafeCharactersAndEmptyNames() throws {
        let url = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "a/b:c\\d", owner: owner)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertFalse(url.lastPathComponent.contains("\\"))
        AttachmentPreviewFileStore.remove(url, owner: owner)

        let fallbackURL = try AttachmentPreviewFileStore.write(Data("x".utf8), suggestedName: "", owner: owner)
        XCTAssertEqual(fallbackURL.lastPathComponent, "attachment")
        AttachmentPreviewFileStore.remove(fallbackURL, owner: owner)
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

    func testPurgeOrphanedFilesIsNoOpWhileAnyOwnerHasLivePreviews() throws {
        let first = try AttachmentPreviewFileStore.write(Data("first".utf8), suggestedName: "a.txt", owner: owner)
        let second = try AttachmentPreviewFileStore.write(Data("second".utf8), suggestedName: "b.txt", owner: otherOwner)
        let orphan = first.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("orphan.txt")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)

        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        AttachmentPreviewFileStore.remove(first, owner: owner)
        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        AttachmentPreviewFileStore.remove(second, owner: otherOwner)
        AttachmentPreviewFileStore.purgeOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDistinctWritesWithSameNameDoNotCollide() throws {
        let first = try AttachmentPreviewFileStore.write(Data("first".utf8), suggestedName: "same.txt", owner: owner)
        let second = try AttachmentPreviewFileStore.write(Data("second".utf8), suggestedName: "same.txt", owner: owner)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))

        AttachmentPreviewFileStore.remove(first, owner: owner)
        AttachmentPreviewFileStore.remove(second, owner: owner)
    }
}
