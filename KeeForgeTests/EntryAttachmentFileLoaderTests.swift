import XCTest
@testable import KeeForge

@MainActor
final class EntryAttachmentFileLoaderTests: XCTestCase {
    func testOversizedSparseFileIsRejectedWithoutLoadingItIntoTheEditor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(KDBXCrypto.maxDecompressedSize) + 1)
        try handle.close()
        let form = EntryEditViewModel(createIn: UUID())
        form.title = "Unsaved title"
        form.password = "Unsaved password"

        let result = await EntryAttachmentFileLoader.load([url])
        result.files.forEach { form.addAttachment(named: $0.name, data: $0.data) }

        XCTAssertEqual(result.error as? DatabaseDraft.DraftError, .attachmentsTooLarge)
        XCTAssertTrue(form.attachments.isEmpty)
        XCTAssertEqual(form.title, "Unsaved title")
        XCTAssertEqual(form.password, "Unsaved password")
    }

    func testSelectionStopsAtCumulativeLimitAndPreservesEarlierFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write(Data("first".utf8), named: "first.txt", in: directory)
        let second = try write(Data("next".utf8), named: "second.txt", in: directory)
        let third = try write(Data("x".utf8), named: "third.txt", in: directory)

        let result = await EntryAttachmentFileLoader.load([first, second, third], maximumByteCount: 8)

        XCTAssertEqual(result.files.map(\.name), ["first.txt"])
        XCTAssertEqual(result.files.map(\.data), [Data("first".utf8)])
        XCTAssertEqual(result.error as? DatabaseDraft.DraftError, .attachmentsTooLarge)
    }

    func testRepeatedImportsShareTheFormsRemainingBudgetAndRemovalRestoresIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write(Data("first".utf8), named: "first.txt", in: directory)
        let second = try write(Data("next".utf8), named: "second.txt", in: directory)
        let form = EntryEditViewModel(createIn: UUID())
        let initial = await EntryAttachmentFileLoader.load([first], maximumByteCount: 8)
        XCTAssertNil(initial.error)
        initial.files.forEach { form.addAttachment(named: $0.name, data: $0.data) }

        let rejected = await EntryAttachmentFileLoader.load(
            [second], maximumByteCount: form.attachmentImportByteBudget(availableByteCount: 8)
        )
        XCTAssertEqual(rejected.error as? DatabaseDraft.DraftError, .attachmentsTooLarge)
        XCTAssertEqual(form.attachments.map(\.name), ["first.txt"])

        form.removeAttachment(id: try XCTUnwrap(form.attachments.first).id)
        let retried = await EntryAttachmentFileLoader.load(
            [second], maximumByteCount: form.attachmentImportByteBudget(availableByteCount: 8)
        )
        XCTAssertNil(retried.error)
        XCTAssertEqual(retried.files.map(\.data), [Data("next".utf8)])
    }

    func testExactBudgetAcceptsCompleteFilesIncludingAnEmptyFinalFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write(Data("123".utf8), named: "first.txt", in: directory)
        let second = try write(Data("45678".utf8), named: "second.txt", in: directory)
        let empty = try write(Data(), named: "empty.txt", in: directory)

        let result = await EntryAttachmentFileLoader.load([first, second, empty], maximumByteCount: 8)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.files.map(\.data), [Data("123".utf8), Data("45678".utf8), Data()])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
