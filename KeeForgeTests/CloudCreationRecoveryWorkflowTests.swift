import XCTest
@testable import KeeForge

@MainActor
final class CloudCreationRecoveryWorkflowTests: XCTestCase {
    private func item(id: UUID = UUID(), paused: Bool = false) -> CloudCreationRecoveryItem {
        CloudCreationRecoveryItem(id: id, filename: "Original.kdbx", destination: "Original.kdbx", isPaused: paused, issue: nil)
    }

    private func reference(id: UUID) -> DatabaseReference {
        DatabaseReference(id: id, filename: "Original.kdbx", isQuickLaunch: false, addedAt: .now)
    }

    func testResumeUsesPersistedOperationAndReturnsReferenceWithoutPreparingNewKeys() async throws {
        let pending = item()
        let original = reference(id: pending.id)
        let calls = RecoveryWorkflowCalls()
        let model = DatabaseCreationViewModel(
            recoveryOperations: .init(
                list: { [pending] },
                resume: { id in await calls.resumed(id); return original },
                cancel: { id in await calls.cancelled(id) }
            ),
            preparationOperation: { _, _ in XCTFail("Recovery must never prepare ciphertext with new keys"); throw CloudProviderError.invalidConfiguration },
            cloudCreationOperation: { _, _, _ in XCTFail("Recovery must use the persisted operation"); throw CloudProviderError.invalidConfiguration }
        )
        model.password = "unrelated new password"
        model.confirmPassword = model.password
        await model.refreshPendingCreations()
        let recovered = await model.resumeCreation(pending)
        XCTAssertEqual(recovered, original)
        XCTAssertTrue(model.pendingCreations.isEmpty)
        XCTAssertEqual(model.password, "")
        XCTAssertNil(model.preparedDatabase)
        let resumed = await calls.resumedIDs
        XCTAssertEqual(resumed, [pending.id])
    }

    func testFormEditedDuringSuspendedRecoveryKeepsNewInputAndDoesNotDismiss() async {
        let pending = item()
        let original = reference(id: pending.id)
        let gate = RecoveryWorkflowGate<DatabaseReference>()
        let model = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { [pending] }, resume: { _ in try await gate.wait() }, cancel: { _ in }
        ))
        model.databaseName = "Previous form"
        model.password = "previous password"
        model.confirmPassword = model.password
        await model.refreshPendingCreations()
        let task = Task { await model.resumeCreation(pending) }
        await gate.waitUntilStarted()

        model.databaseName = "New database"
        model.password = "new password"
        model.confirmPassword = model.password
        model.destinationChoice = .files
        await gate.finish(.success(original))
        let recovered = await task.value

        XCTAssertNil(recovered, "Returning a reference would dismiss the newer form")
        XCTAssertEqual(model.databaseName, "New database")
        XCTAssertEqual(model.password, "new password")
        XCTAssertEqual(model.confirmPassword, "new password")
        XCTAssertEqual(model.destinationChoice, .files)
        XCTAssertTrue(model.pendingCreations.isEmpty, "The completed recovery still leaves the pending list")
        XCTAssertFalse(model.isRecovering)
        XCTAssertNil(model.recoveryMessage)
    }

    func testCancelRetainsPausedRecordAndCancelFailureIsVisible() async {
        let pending = item()
        let paused = item(id: pending.id, paused: true)
        let calls = RecoveryWorkflowCalls()
        let model = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { await calls.wasCancelled ? [paused] : [pending] },
            resume: { _ in throw CloudProviderError.notAuthenticated },
            cancel: { id in await calls.cancelled(id) }
        ))
        await model.refreshPendingCreations()
        await model.cancelCreation(pending)
        XCTAssertEqual(model.pendingCreations.map(\.id), [pending.id])
        XCTAssertTrue(model.pendingCreations[0].isPaused)
        XCTAssertFalse(model.isRecovering)

        let failed = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { [pending] }, resume: { _ in throw CloudProviderError.notAuthenticated },
            cancel: { _ in throw CloudProviderError.serviceUnavailable }
        ))
        await failed.refreshPendingCreations()
        await failed.cancelCreation(pending)
        XCTAssertEqual(failed.pendingCreations.map(\.id), [pending.id])
        XCTAssertEqual(failed.recoveryMessage, CloudProviderError.serviceUnavailable.localizedDescription)
    }

    func testDismissedRecoveryCannotReturnLateReferenceOrError() async {
        for fail in [false, true] {
            let pending = item()
            let original = reference(id: pending.id)
            let gate = RecoveryWorkflowGate<DatabaseReference>()
            let model = DatabaseCreationViewModel(recoveryOperations: .init(
                list: { [pending] }, resume: { _ in try await gate.wait() }, cancel: { _ in }
            ))
            await model.refreshPendingCreations()
            let task = Task { await model.resumeCreation(pending) }
            await gate.waitUntilStarted()
            XCTAssertTrue(model.isRecovering)
            model.cancelPendingCreation()
            await gate.finish(fail ? .failure(CloudProviderError.networkUnavailable) : .success(original))
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertNil(model.recoveryMessage)
            XCTAssertFalse(model.isRecovering)
        }
    }

    func testDismissedListCannotPublishAndUnknownOperationCannotResume() async {
        let pending = item()
        let gate = RecoveryWorkflowGate<[CloudCreationRecoveryItem]>()
        let calls = RecoveryWorkflowCalls()
        let model = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { try await gate.wait() },
            resume: { id in await calls.resumed(id); throw CloudProviderError.notAuthenticated },
            cancel: { _ in }
        ))
        let unknown = await model.resumeCreation(pending)
        XCTAssertNil(unknown)
        let load = Task { await model.refreshPendingCreations() }
        await gate.waitUntilStarted()
        model.cancelPendingCreation()
        await gate.finish(.success([pending]))
        await load.value
        XCTAssertTrue(model.pendingCreations.isEmpty)
        let resumed = await calls.resumedIDs
        XCTAssertTrue(resumed.isEmpty)
    }

    func testActiveCancelUsesPersistedIDAndFencesLateResumeCompletion() async {
        let pending = item()
        let paused = item(id: pending.id, paused: true)
        let original = reference(id: pending.id)
        let gate = RecoveryWorkflowGate<DatabaseReference>()
        let calls = RecoveryWorkflowCalls()
        let model = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { await calls.wasCancelled ? [paused] : [pending] },
            resume: { _ in try await gate.wait() },
            cancel: { id in await calls.cancelled(id) }
        ))
        await model.refreshPendingCreations()
        let active = Task { await model.resumeCreation(pending) }
        await gate.waitUntilStarted()
        await model.cancelCreation(pending)
        XCTAssertTrue(model.pendingCreations[0].isPaused)
        await gate.finish(.success(original))
        let result = await active.value
        XCTAssertNil(result)
        XCTAssertTrue(model.pendingCreations[0].isPaused)
        XCTAssertFalse(model.isRecovering)
        let cancelled = await calls.cancelledIDs
        XCTAssertEqual(cancelled, [pending.id])
    }

    func testConcurrentRecoveryDoesNotDuplicateResumeAndFailureRetainsVisibleIntent() async {
        let pending = item()
        let gate = RecoveryWorkflowGate<DatabaseReference>()
        let calls = RecoveryWorkflowCalls()
        let model = DatabaseCreationViewModel(recoveryOperations: .init(
            list: { [pending] },
            resume: { id in await calls.resumed(id); return try await gate.wait() },
            cancel: { id in await calls.cancelled(id) }
        ))
        await model.refreshPendingCreations()
        let first = Task { await model.resumeCreation(pending) }
        await gate.waitUntilStarted()
        let duplicate = await model.resumeCreation(pending)
        XCTAssertNil(duplicate)
        await gate.finish(.failure(CloudProviderError.notAuthenticated))
        _ = await first.value
        XCTAssertEqual(model.pendingCreations.map(\.id), [pending.id])
        XCTAssertEqual(model.recoveryMessage, CloudProviderError.notAuthenticated.localizedDescription)
        let resumed = await calls.resumedIDs
        let cancelled = await calls.cancelledIDs
        XCTAssertEqual(resumed, [pending.id])
        XCTAssertTrue(cancelled.isEmpty)
    }
}

private actor RecoveryWorkflowCalls {
    private(set) var resumedIDs: [UUID] = []
    private(set) var cancelledIDs: [UUID] = []
    var wasCancelled: Bool { !cancelledIDs.isEmpty }
    func resumed(_ id: UUID) { resumedIDs.append(id) }
    func cancelled(_ id: UUID) { cancelledIDs.append(id) }
}

private actor RecoveryWorkflowGate<Value: Sendable> {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ result: Result<Value, Error>) { waiter?.resume(with: result); waiter = nil }
}
