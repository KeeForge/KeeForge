import XCTest
@testable import KeeForge

@MainActor
final class AttachmentLoadCoordinatorTests: XCTestCase {
    func testPreviewFinishingAfterLockCannotWriteATempFile() async throws {
        let coordinator = AttachmentLoadCoordinator()
        coordinator.activate()
        let started = expectation(description: "Preview decoding started")
        var continuation: CheckedContinuation<Data, Never>?
        var lockCycle = 0
        var previewURL: URL?
        let task = try XCTUnwrap(coordinator.load(
            operation: {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            },
            isCurrent: { lockCycle == 0 },
            onCompletion: {
                previewURL = try? AttachmentPreviewFileStore.write($0, suggestedName: "late.txt")
            }
        ))
        XCTAssertTrue(coordinator.isLoading)
        await fulfillment(of: [started], timeout: 1)

        lockCycle += 1
        AttachmentPreviewFileStore.clearAll()
        try XCTUnwrap(continuation).resume(returning: Data("private attachment".utf8))
        await task.value

        XCTAssertNil(previewURL)
        XCTAssertFalse(coordinator.isLoading)
    }

    func testImportFinishingAfterEditorDismissalDoesNotMutateTheForm() async throws {
        let coordinator = AttachmentLoadCoordinator()
        coordinator.activate()
        let form = EntryEditViewModel(createIn: UUID())
        let started = expectation(description: "Attachment read started")
        var continuation: CheckedContinuation<Data, Never>?
        let task = try XCTUnwrap(coordinator.load(
            operation: {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            },
            isCurrent: { true },
            onCompletion: { form.addAttachment(named: "late.txt", data: $0) }
        ))
        await fulfillment(of: [started], timeout: 1)

        coordinator.deactivate()
        try XCTUnwrap(continuation).resume(returning: Data("private attachment".utf8))
        await task.value

        XCTAssertTrue(form.attachments.isEmpty)
        XCTAssertFalse(form.isDirty)
        XCTAssertFalse(coordinator.isLoading)
    }

    func testOldCompletionDoesNotFinishOrPublishOverANewLoad() async throws {
        let coordinator = AttachmentLoadCoordinator()
        coordinator.activate()
        let firstStarted = expectation(description: "First load started")
        let secondStarted = expectation(description: "Second load started")
        var firstContinuation: CheckedContinuation<Data, Never>?
        var secondContinuation: CheckedContinuation<Data, Never>?
        var published: [Data] = []
        let first = try XCTUnwrap(coordinator.load(
            operation: {
                await withCheckedContinuation {
                    firstContinuation = $0
                    firstStarted.fulfill()
                }
            },
            isCurrent: { true },
            onCompletion: { published.append($0) }
        ))
        await fulfillment(of: [firstStarted], timeout: 1)
        coordinator.invalidate()
        let second = try XCTUnwrap(coordinator.load(
            operation: {
                await withCheckedContinuation {
                    secondContinuation = $0
                    secondStarted.fulfill()
                }
            },
            isCurrent: { true },
            onCompletion: { published.append($0) }
        ))
        await fulfillment(of: [secondStarted], timeout: 1)

        try XCTUnwrap(firstContinuation).resume(returning: Data("old".utf8))
        await first.value
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(coordinator.isLoading)
        try XCTUnwrap(secondContinuation).resume(returning: Data("new".utf8))
        await second.value

        XCTAssertEqual(published, [Data("new".utf8)])
        XCTAssertFalse(coordinator.isLoading)
    }

    func testCurrentImportPreservesPartialSuccessAndError() async throws {
        let coordinator = AttachmentLoadCoordinator()
        coordinator.activate()
        let form = EntryEditViewModel(createIn: UUID())
        var reportedError: String?
        let task = try XCTUnwrap(coordinator.load(
            operation: {
                (
                    files: [EntryAttachmentFileLoader.LoadedFile(name: "first.txt", data: Data("first".utf8))],
                    error: CocoaError(.fileReadNoPermission) as Error?
                )
            },
            isCurrent: { true },
            onCompletion: { loaded in
                loaded.files.forEach { form.addAttachment(named: $0.name, data: $0.data) }
                reportedError = loaded.error?.localizedDescription
            }
        ))
        await task.value

        XCTAssertEqual(form.attachments.map(\.name), ["first.txt"])
        XCTAssertNotNil(reportedError)
        XCTAssertTrue(form.isDirty)
        XCTAssertFalse(coordinator.isLoading)
    }

    func testInactiveCoordinatorDoesNotStartARead() {
        let coordinator = AttachmentLoadCoordinator()
        XCTAssertNil(coordinator.load(
            operation: { Data() },
            isCurrent: { true },
            onCompletion: { _ in XCTFail("An inactive load cannot complete") }
        ))
        XCTAssertFalse(coordinator.isLoading)
    }
}
