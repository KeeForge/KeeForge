#if os(macOS)
import CryptoKit
import XCTest
@testable import KeeForge

@MainActor
final class AttachmentPreviewSessionTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        RecordingPreviewStore.written = []
    }

    func testAPreviewWritesOneFileAndEndingThePreviewRemovesIt() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)

        await previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        let url = try XCTUnwrap(previews.previewURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("report".utf8))
        XCTAssertEqual(url.lastPathComponent, "report.txt")
        XCTAssertNil(previews.shareURL)

        previews.shareFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Only a share's end removes a shared file")
        previews.previewEnded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(previews.state, .idle)
    }

    func testAShareKeepsItsFileUntilTheShareFinishes() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)

        await previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        let preview = try XCTUnwrap(previews.previewURL)
        await previews.share(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path), "One file per window: sharing ends the preview")
        let shared = try XCTUnwrap(previews.shareURL)
        XCTAssertNil(previews.previewURL)

        previews.previewEnded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        previews.shareFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertEqual(previews.state, .idle)
    }

    func testALoadFinishingAfterLockWritesNothing() async throws {
        let (session, entry) = try await makeSession()
        let loader = SuspendedLoader()
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self,
                                                loadData: { _, _ in await loader.load() })

        let task = try XCTUnwrap(previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session))
        await loader.waitUntilRequested()
        XCTAssertTrue(previews.isLoading(entryID: entry.id, attachmentIndex: 0))
        session.lockRequest(force: true)
        loader.finish(Data("late".utf8))
        await task.value

        XCTAssertEqual(RecordingPreviewStore.written, [])
        XCTAssertNil(previews.previewURL)
        previews.reconcile()
        XCTAssertEqual(previews.state, .idle)
    }

    func testALoadFinishingAfterAnotherEntryIsSelectedWritesNothing() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let loader = SuspendedLoader()
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self,
                                                loadData: { _, _ in await loader.load() })

        let task = try XCTUnwrap(previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session))
        await loader.waitUntilRequested()
        session.workspace.selectedEntryID = UUID()
        loader.finish(Data("late".utf8))
        await task.value

        XCTAssertEqual(RecordingPreviewStore.written, [])
    }

    func testLockAnotherEntryAndAnotherSessionEachCloseAnOpenFile() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        var shown: DatabaseViewModel? = session
        let previews = AttachmentPreviewSession(currentSession: { shown }, store: RecordingPreviewStore.self)

        await previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        var url = try XCTUnwrap(previews.previewURL)
        previews.reconcile()
        XCTAssertEqual(previews.previewURL, url, "Nothing changed, so the preview stays")
        session.workspace.selectedEntryID = UUID()
        previews.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(previews.state, .idle)

        session.workspace.selectedEntryID = entry.id
        await previews.share(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        url = try XCTUnwrap(previews.shareURL)
        shown = nil
        previews.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        shown = session
        await previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        url = try XCTUnwrap(previews.previewURL)
        session.lockRequest(force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The session's lock clear is the backstop")
        previews.reconcile()
        XCTAssertEqual(previews.state, .idle)
    }

    func testRemovingTheAttachmentClosesItsPreview() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)
        await previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        let url = try XCTUnwrap(previews.previewURL)

        let form = EntryEditViewModel(editing: try XCTUnwrap(session.entry(withID: entry.id)), sessionKey: key)
        form.removeAttachment(id: try XCTUnwrap(form.attachments.first).id)
        try session.applyEntryEdit(.updateEntry(entryID: entry.id, draft: form.entryDraftPayload))
        previews.reconcile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(previews.state, .idle)
    }

    func testClosingTheWindowRemovesTheFileAndRefusesLaterRequests() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)
        await previews.share(attachmentAt: 0, ofEntry: entry.id, in: session)?.value
        let url = try XCTUnwrap(previews.shareURL)

        previews.windowClosed()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session))
        XCTAssertEqual(previews.state, .idle)
    }

    func testADanglingAttachmentIsUnavailableAndWritesNothing() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)

        await previews.preview(attachmentAt: 1, ofEntry: entry.id, in: session)?.value

        XCTAssertEqual(previews.state, .unavailable(.init(entryID: entry.id, attachmentIndex: 1, purpose: .preview)))
        XCTAssertEqual(RecordingPreviewStore.written, [])
    }

    func testARequestForAnUnselectedEntryOrAMissingAttachmentStartsNothing() async throws {
        let (session, entry) = try await makeSession()
        defer { session.lockRequest(force: true) }
        let previews = AttachmentPreviewSession(currentSession: { session }, store: RecordingPreviewStore.self)

        XCTAssertNil(previews.preview(attachmentAt: 5, ofEntry: entry.id, in: session))
        session.workspace.selectedEntryID = nil
        XCTAssertNil(previews.preview(attachmentAt: 0, ofEntry: entry.id, in: session))
        XCTAssertEqual(previews.state, .idle)
    }

    // MARK: - Helpers

    private func makeSession() async throws -> (DatabaseViewModel, KPEntry) {
        let entry = KPEntry(title: "Files", attachments: [
            KPAttachment(name: "report.txt", ref: 0), KPAttachment(name: "gone.txt", ref: 7),
        ])
        let session = try await TestDatabaseSupport.makeUnlockedSession(
            root: KPGroup(name: "Root", entries: [entry]), key: key,
            binaryPool: BinaryPool(rawFields: [Data([0]) + Data("report".utf8)]), bundle: Bundle(for: Self.self)
        )
        session.workspace.selectedEntryID = entry.id
        return (session, entry)
    }

    @MainActor
    private enum RecordingPreviewStore: AttachmentPreviewFileStoring {
        static var written: [URL] = []

        static func write(_ data: Data, suggestedName: String, owner: UUID) throws -> URL {
            let url = try AttachmentPreviewFileStore.write(data, suggestedName: suggestedName, owner: owner)
            written.append(url)
            return url
        }

        static func remove(_ url: URL, owner: UUID) {
            AttachmentPreviewFileStore.remove(url, owner: owner)
        }
    }

    @MainActor
    private final class SuspendedLoader {
        private var continuation: CheckedContinuation<Data?, Never>?
        private var requested: CheckedContinuation<Void, Never>?

        func load() async -> Data? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                requested?.resume()
                requested = nil
            }
        }

        func waitUntilRequested() async {
            guard continuation == nil else { return }
            await withCheckedContinuation { requested = $0 }
        }

        func finish(_ data: Data?) {
            continuation?.resume(returning: data)
            continuation = nil
        }
    }
}
#endif
