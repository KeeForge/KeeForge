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

    func testPausedConflictCopySurvivesRestartAndRecoversThroughProductionListAndQueue() async throws {
        guard AppGroupContainer.isRedirectedForTesting else { throw XCTSkip("Requires the isolated unit-test App Group") }
        let operationID = UUID()
        let ownerID = UUID()
        let filename = "Vault conflict (2).kdbx"
        let target = CloudFileCreationTarget(path: filename, parentFileID: "opaque-parent-id")
        let bytes = Data("retained conflict-copy ciphertext".utf8)
        let payloadURL = PendingUploadQueue.creationPayloadURL(ownerDatabaseID: ownerID, operationID: operationID)
        defer {
            DatabaseListStore.remove(id: operationID)
            try? FileManager.default.removeItem(at: payloadURL.deletingLastPathComponent())
        }
        try PendingUploadQueue.Environment.live.createDirectory(payloadURL.deletingLastPathComponent())
        try PendingUploadQueue.Environment.live.writeMarkerAtomically(bytes, payloadURL)
        var template = reference(id: operationID)
        template.filename = filename
        var receipt = template
        receipt.source = .cloud(CloudSyncMetadata(
            provider: "googledrive", accountId: "original-permission-id", fileId: "generated-conflict-copy-id",
            displayPath: filename, remoteContentHash: nil, remoteModifiedAt: nil, remoteRev: "opaque-revision",
            lastSyncedAt: nil, lastSyncIssue: nil
        ))
        var intent = PendingUploadQueue.CreationIntent(
            operationID: operationID, ownerDatabaseID: ownerID, provider: "googledrive",
            accountID: "original-permission-id", target: target, payloadSHA512: FileDigest.sha512(bytes),
            payloadPath: try PendingUploadQueue.makeRelativeAppGroupPath(for: payloadURL),
            referenceTemplate: template, isConflictCopy: true
        )
        intent.creationID = "generated-conflict-copy-id"
        intent.phase = .confirmed
        intent.receipt = receipt
        try PendingUploadQueue.storeCreation(intent)

        let firstSession = DatabaseCreationViewModel()
        await firstSession.refreshPendingCreations()
        let firstItem = try XCTUnwrap(firstSession.pendingCreations.first { $0.id == operationID })
        await firstSession.cancelCreation(firstItem)
        firstSession.cancelPendingCreation()

        let persisted = try XCTUnwrap(PendingUploadQueue.listCreations(for: ownerID).first { $0.operationID == operationID })
        XCTAssertTrue(persisted.isConflictCopy)
        XCTAssertTrue(persisted.isPaused)
        XCTAssertEqual(persisted.accountID, "original-permission-id")
        XCTAssertEqual(persisted.target, target)
        XCTAssertEqual(try Data(contentsOf: payloadURL), bytes)
        let restarted = DatabaseCreationViewModel()
        await restarted.refreshPendingCreations()
        let visible = try XCTUnwrap(restarted.pendingCreations.first { $0.id == operationID })
        XCTAssertTrue(visible.isPaused)
        XCTAssertEqual(visible.filename, filename)
        XCTAssertEqual(visible.destination, filename)

        let resumed = await restarted.resumeCreation(visible)
        let recovered = try XCTUnwrap(resumed)
        XCTAssertEqual(recovered.id, operationID)
        XCTAssertEqual(recovered.filename, filename)
        XCTAssertEqual(recovered.cloudSyncMetadata?.accountId, "original-permission-id")
        XCTAssertEqual(recovered.cloudSyncMetadata?.fileId, "generated-conflict-copy-id")
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == operationID }, recovered)
        let cacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: recovered))
        XCTAssertEqual(try Data(contentsOf: cacheURL), bytes)
        XCTAssertFalse(restarted.pendingCreations.contains { $0.id == operationID })
        XCTAssertTrue(try PendingUploadQueue.listCreations(for: ownerID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
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
        await fulfillment(of: [gate.started], timeout: 30)

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
            await fulfillment(of: [gate.started], timeout: 30)
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
        await fulfillment(of: [gate.started], timeout: 30)
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
        await fulfillment(of: [gate.started], timeout: 30)
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
        await fulfillment(of: [gate.started], timeout: 30)
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
    nonisolated let started = XCTestExpectation(description: "Recovery reached the injected suspension")
    private var waiter: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func wait() async throws -> Value {
        started.fulfill()
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func finish(_ result: Result<Value, Error>) {
        self.result = result
        waiter?.resume(with: result)
        waiter = nil
    }
}
