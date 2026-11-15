import Foundation
import XCTest
import KDBXKit
import CryptoKit
@testable import KeeForge

@MainActor
final class PendingUploadDrainerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }


    func test_drain_provisionalMarkerKeepsItsCoverUntilFinalized() async throws {
        let context = try makeContext(install: false)
        let transport = CloudJournalTransport()
        let drainer = PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport)))
        let beforeSave = await drainer.drainAll()
        XCTAssertEqual(beforeSave.conflictDatabaseIDs, [context.reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.base)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
        let covered = try XCTUnwrap(PendingUploadQueue.readJournal(for: context.reference.id).first)
        XCTAssertEqual(covered.id, context.stored.id)
        XCTAssertEqual(covered.marker.isPayloadFinalized, false)
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: context.reference) else {
            return XCTFail("A prepared immutable payload must be recoverable without confusing it with the base")
        }
        XCTAssertEqual(sources.map(\.data), [context.payload])
        let replacement = try LocalDatabaseSaver.replaceFileAtomically(context.payload, at: context.cacheURL,
            expectedSHA512: FileDigest.sha512(context.base),
            authorization: .init(databaseID: context.reference.id, enforcesEpoch: false, targetIsSharedCopy: true))
        guard case .replaced = replacement else { return XCTFail("Expected real prepared-cache replacement") }
        let afterSave = await drainer.drainAll()
        XCTAssertEqual(afterSave.drainedDatabaseIDs, [context.reference.id])
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: context.reference.id).isEmpty)
    }

    func test_drain_provisionalMarkerIsNotDroppedAsAlreadyUploaded() async throws {
        let context = try makeContext()
        let provisional = try enqueueLegacy(for: context.reference, bytes: context.payload, finalized: false)
        let transport = CloudJournalTransport()
        let drainer = PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport)))
        let outcome = await drainer.drainAll()
        XCTAssertEqual(outcome.drainedDatabaseIDs, [context.reference.id])
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        let remaining = try PendingUploadQueue.readJournal(for: context.reference.id)
        XCTAssertEqual(remaining.map(\.id), [provisional.id])
        XCTAssertEqual(remaining.first?.marker, provisional.marker)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
    }

    func test_drain_legacyMarkerWithoutPhaseRetainsUnidentifiedPayload() async throws {
        // A shipped marker without a phase may identify the base, never the saved payload.
        let reference = registeredReference()
        let bytes = Data("legacy-cache-ciphertext".utf8)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let path = try PendingUploadQueue.makeRelativeAppGroupPath(for: DatabaseListStore.cacheLocation(for: reference))
        let shippedJSON = """
        {"databaseId":"\(reference.id.uuidString)","encryptedBytesCacheURL":"\(path)",
         "openTimeSHA512":"\(FileDigest.sha512(bytes).base64EncodedString())","expectedRev":"rev-1","createdAt":0}
        """
        let decoded = try JSONDecoder().decode(PendingUploadQueue.Marker.self, from: Data(shippedJSON.utf8))
        XCTAssertNil(decoded.isPayloadFinalized)
        let stored = try PendingUploadQueue.enqueue(decoded, notifying: false)
        let encoded = try Data(contentsOf: stored.fileURL)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("isPayloadFinalized"))
        XCTAssertNil(try JSONDecoder().decode(PendingUploadQueue.Marker.self, from: encoded).isPayloadFinalized)
        let transport = CloudJournalTransport()
        let saver = transportEnvironment(reference: reference, transport: transport)
        let outcome = await PendingUploadDrainer(environment: drainerEnvironment(saver: saver)).drainAll()
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).map(\.id), [stored.id])
        guard case .unidentified = PendingUploadRecovery.lookUpPayloads(for: reference) else {
            return XCTFail("Matching a legacy base hash is not payload authority")
        }
    }

    func test_drain_legacyConflictDoesNotMutateProvisionalSibling() async throws {
        let reference = registeredReference()
        let bytes = Data("legacy-sibling-ciphertext".utf8)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let unknown = try enqueueLegacy(for: reference, bytes: bytes, finalized: nil)
        let provisional = try enqueueLegacy(for: reference, bytes: bytes, finalized: false)
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: drainerEnvironment(
            saver: transportEnvironment(reference: reference, transport: transport))).drainAll()
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        let remaining = try PendingUploadQueue.readJournal(for: reference.id)
        let conflicted = try XCTUnwrap(remaining.first { $0.id == unknown.id })
        XCTAssertTrue(conflicted.marker.isConflicted)
        XCTAssertNil(conflicted.marker.isPayloadFinalized)
        XCTAssertEqual(remaining.first { $0.id == provisional.id }?.marker, provisional.marker)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
    }

    func testLegacyFinalizedMatchingStrongRevisionWithoutBaselineExportsOriginalFactorsInsteadOfBlindDelivery() async throws {
        let reference = registeredReference()
        let bytes = try KDBXTestFixture.kitchenSink.data(in: Bundle(for: Self.self))
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let stored = try enqueueLegacy(for: reference, bytes: bytes, finalized: true)
        let transport = CloudJournalTransport(remote: bytes, revision: reference.expectedCloudRevision)
        var saver = transportEnvironment(reference: reference, transport: transport)
        saver.revisionIdentifiesContent = { _, _ in true }
        let outcome = await PendingUploadDrainer(environment: drainerEnvironment(saver: saver)).drainAll()
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertEqual(transport.effects.downloads, 0)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(retained.id, stored.id)
        XCTAssertNil(retained.marker.remoteBaseSHA512)
        let exported = try PendingUploadQueue.readImmutablePayload(retained)
        XCTAssertEqual(exported, bytes)
        _ = try KDBXParser.parseWithMetaAndHeader(data: exported,
            password: KDBXTestFixture.kitchenSink.password, sessionKey: SymmetricKey(size: .bits256))
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: reference) else {
            return XCTFail("The existing explicit merge/export route must retain this original-factor snapshot")
        }
        XCTAssertEqual(sources.map(\.data), [bytes])
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
    }

    func test_drain_finalizedLegacyMarkerPromotesExactCiphertextAndExposesRecovery() async throws {
        let reference = registeredReference()
        let bytes = Data("verified-legacy-payload".utf8)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let stored = try enqueueLegacy(for: reference, bytes: bytes, finalized: true)
        let transport = CloudJournalTransport(remote: Data("unseen-remote".utf8))
        let outcome = await PendingUploadDrainer(environment: drainerEnvironment(
            saver: transportEnvironment(reference: reference, transport: transport))).drainAll()
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        let promoted = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(promoted.id, stored.id)
        XCTAssertEqual(promoted.marker.intendedPayloadSHA512, FileDigest.sha512(bytes))
        let path = try XCTUnwrap(promoted.marker.intendedPayloadPath)
        XCTAssertEqual(try Data(contentsOf: PendingUploadQueue.resolveAppGroupURL(for: path)), bytes)
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: reference) else {
            return XCTFail("Verified legacy payloads must remain usable for explicit recovery")
        }
        XCTAssertEqual(sources.map(\.data), [bytes])
        XCTAssertEqual(sources.map(\.storedMarker.id), [stored.id])
    }

    func test_drain_happyPath_uploadsAndDropsMarker() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertEqual(outcome.drainedDatabaseIDs, [context.reference.id])
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: context.reference.id).isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try context.payloadURL.path))
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == context.reference.id }?.cloudSyncMetadata?.remoteRev, "rev-2")
    }

    func test_drain_conflict_marksConflicted_keepsMarker() async throws {
        try await assertRemoteConflict(remote: Data("changed-remote".utf8))
    }

    func test_drain_payloadShaMismatch_marksConflicted_doesNotPush() async throws {
        let context = try makeContext()
        let tampered = Data("corrupt-immutable-payload".utf8)
        try tampered.write(to: context.payloadURL)
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertNotNil(outcome.userIssue)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), tampered)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: context.reference.id).map(\.id), [context.stored.id])
    }

    func test_drain_markerOlderThanMasterKeyChange_retainsSourceWithoutDispatch() async throws {
        let context = try makeContext()
        var reference = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == context.reference.id })
        reference.lastMasterKeyChangeAt = context.stored.marker.createdAt.addingTimeInterval(10)
        DatabaseListStore.testUpsert(reference)
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertNotNil(outcome.userIssue)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
        let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(retained.marker, context.stored.marker)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), context.payload)
    }

    func test_drain_crossDeviceConflict_isNotAutoRebased() async throws {
        try await assertRemoteConflict(remote: Data("foreign-device-ciphertext".utf8), revision: "rev-2")
    }

    func test_drain_offline_keepsMarkerUnchanged() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport(metadataError: .networkUnavailable)
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.userIssue?.kind, .message)
        XCTAssertEqual(outcome.userIssue?.message, CloudProviderError.networkUnavailable.localizedDescription)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: context.reference.id).first?.marker, context.stored.marker)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
    }

    func test_drain_writeScopeRequired_surfacesAlertViaList() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport(metadataError: .writeScopeRequired)
        let viewModel = DatabaseListViewModel(pendingUploadDrainer: PendingUploadDrainer(
            environment: context.drainerEnvironment(saver: context.environment(transport: transport))))
        await viewModel.pushPendingChanges(for: context.reference)
        XCTAssertEqual(viewModel.pendingUploadAlert?.databaseId, context.reference.id)
        XCTAssertEqual(viewModel.pendingUploadAlert?.kind, .writeScopeRequired)
        XCTAssertEqual(viewModel.pendingUploadAlert?.message, CloudProviderError.writeScopeRequired.localizedDescription)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
    }

    func test_drain_skipsLocalSourceMarkers() async throws {
        let reference = makeLocalReference()
        let marker = try enqueueLegacy(for: reference, bytes: Data("local".utf8), finalized: true)
        var environment = drainerEnvironment(saver: .live)
        environment.resolveReference = { _ in reference }
        environment.deliverMarker = { _, _ in XCTFail("A local source must not enter delivery"); return nil }
        let outcome = await PendingUploadDrainer(environment: environment).drainAll()
        XCTAssertEqual(outcome.skippedDatabaseIDs, [reference.id])
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).first?.marker, marker.marker)
        try PendingUploadQueue.removeAllMarkers(for: reference.id)
    }

    func test_drain_rebasesOnlyWhenPayloadDerivesFromRemoteHead() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport(remote: context.base, revision: "rev-2")
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertEqual(transport.effects.downloads, 1)
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-2")])
        XCTAssertEqual(outcome.drainedDatabaseIDs, [context.reference.id])
        XCTAssertTrue(outcome.conflictDatabaseIDs.isEmpty)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: context.reference.id).isEmpty)
    }

    func test_drain_appSaveCompletedDuringAutoFillSession_isNotForcePushed() async throws {
        try await assertRemoteConflict(remote: Data("app-save-ciphertext".utf8), revision: "rev-B")
    }

    func test_drain_legacyMarkerWithoutBaseRev_isNeverAutoRebased() async throws {
        let reference = registeredReference()
        let bytes = Data("legacy-payload-without-proven-base".utf8)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let stored = try enqueueLegacy(for: reference, bytes: bytes, finalized: true, baseRev: nil)
        let transport = CloudJournalTransport(remote: Data("remote-head".utf8), revision: "rev-2")
        let outcome = await PendingUploadDrainer(environment: drainerEnvironment(saver: transportEnvironment(reference: reference, transport: transport))).drainAll()
        XCTAssertEqual(outcome.conflictDatabaseIDs, [reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).map(\.id), [stored.id])
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: reference) else { return XCTFail("Recovery must expose the legacy payload") }
        XCTAssertEqual(sources.map(\.data), [bytes])
    }

    func testThreeConfirmedAncestorsRetireWithoutReplacingTheCurrentDescendantOrResending() async throws {
        let first = try makeContext()
        let referenceB = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == first.reference.id })
        let second = try CloudJournalTestContext(reference: referenceB, base: first.payload, payload: Data("ciphertext-C".utf8))
        let referenceC = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == first.reference.id })
        let third = try CloudJournalTestContext(reference: referenceC, base: second.payload, payload: Data("ciphertext-D".utf8))
        let owners = [first, second, third]
        for (index, owner) in owners.enumerated() {
            let transport = CloudJournalTransport(remote: owner.base, revision: "remote-\(index)",
                response: .init(modifiedDate: .now, contentHash: nil, size: Int64(owner.payload.count), rev: "remote-\(index + 1)"))
            let environment = owner.environment(transport: transport)
            guard case .saved? = try await CloudDatabaseSaver.deliver(owner.stored, reference: owner.reference, environment: environment) else {
                return XCTFail("Verified ancestry must reconcile without rolling back its descendant")
            }
            XCTAssertEqual(transport.effects.uploads, [.init(bytes: owner.payload, revision: "remote-\(index)")])
            XCTAssertEqual(try Data(contentsOf: third.cacheURL), third.payload)
            let remaining = try PendingUploadQueue.readJournal(for: first.reference.id)
            XCTAssertEqual(Set(remaining.map(\.id)), Set(owners.dropFirst(index + 1).map { $0.stored.id }))
            if let child = remaining.first(where: { $0.marker.predecessorOperationID == owner.stored.id }) {
                XCTAssertEqual(child.marker.remoteBaseSHA512, FileDigest.sha512(owner.payload))
                XCTAssertEqual(child.marker.expectedRev, "remote-\(index + 1)")
            }
            let lateCompletion = try await CloudDatabaseSaver.deliver(owner.stored, reference: owner.reference, environment: environment)
            XCTAssertNil(lateCompletion)
            XCTAssertEqual(transport.effects.uploads.count, 1)
        }
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: first.reference.id).isEmpty)
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == first.reference.id }?.cloudSyncMetadata?.localHeadOperationID, third.stored.id)
    }

    func testConfirmedRetirementRemovalFailureKeepsExactPayloadAndReconcilesWithoutProviderIO() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport()
        var faulty = context.environment(transport: transport)
        let faultReached = CloudJournalEffectCounter()
        let remove = faulty.queue.removeItem
        faulty.queue.removeItem = { url in
            if url.resolvingSymlinksInPath().standardizedFileURL == context.stored.fileURL.resolvingSymlinksInPath().standardizedFileURL { faultReached.record(); throw CocoaError(.fileWriteNoPermission) }
            try remove(url)
        }
        do {
            _ = try await CloudDatabaseSaver.deliver(context.stored, reference: context.reference, environment: faulty)
            XCTFail("A failed journal retirement cannot report complete")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        XCTAssertGreaterThan(faultReached.value, 0)
        let confirmed = try XCTUnwrap(PendingUploadQueue.readJournal(for: context.reference.id).first)
        XCTAssertEqual(CloudJournalDecision.state(of: confirmed.marker), .confirmed)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(confirmed), context.payload)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        guard case .saved? = try await CloudDatabaseSaver.deliver(confirmed, reference: context.reference,
            environment: context.environment(transport: transport)) else { return XCTFail("Explicit confirmation recovery must finish locally") }
        XCTAssertEqual(transport.effects.uploads.count, 1)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: context.reference.id).isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
    }

    func test_drain_confirmedFollowUpReconcilesWithoutUploadingAgain() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport()
        var faulty = context.environment(transport: transport)
        faulty.synchronizeCacheFile = { _ in throw CocoaError(.fileWriteUnknown) }
        let first = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: faulty)).drainAll()
        XCTAssertEqual(first.skippedDatabaseIDs, [context.reference.id])
        let confirmed = try XCTUnwrap(PendingUploadQueue.readJournal(for: context.reference.id).first)
        XCTAssertNotNil(confirmed.marker.confirmedAt)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
        let recovered = await PendingUploadDrainer(environment: context.drainerEnvironment(
            saver: context.environment(transport: transport))).drainAll()
        XCTAssertEqual(recovered.drainedDatabaseIDs, [context.reference.id])
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        XCTAssertEqual(transport.effects.metadataCalls, 1)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: context.reference.id).isEmpty)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
    }

    func test_drain_requestDuringInFlightDrain_runsAdditionalPass() async throws {
        let first = try makeContext()
        let firstPushStarted = XCTestExpectation(description: "First journal upload entered")
        firstPushStarted.assertForOverFulfill = false
        let resumeFirstPush = AsyncSignal()
        let transport = CloudJournalTransport(beforeUpload: {
            firstPushStarted.fulfill()
            await resumeFirstPush.wait()
        })
        let drainer = PendingUploadDrainer(environment: first.drainerEnvironment(saver: first.environment(transport: transport)))
        let firstDrain = Task { await drainer.drainAll() }
        await fulfillment(of: [firstPushStarted], timeout: 5)
        let second = try makeContext()
        let coalescedDrain = Task { await drainer.drainAll() }
        for _ in 0..<5 { await Task.yield() }
        resumeFirstPush.signal()
        let outcome = await firstDrain.value
        _ = await coalescedDrain.value
        XCTAssertEqual(transport.effects.uploads.count, 2)
        XCTAssertEqual(transport.effects.uploads.map(\.bytes), [first.payload, second.payload])
        XCTAssertEqual(outcome.drainedDatabaseIDs, [first.reference.id, second.reference.id])
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: first.reference.id).isEmpty)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: second.reference.id).isEmpty)
    }

    func test_drain_ignoresReadOnlyFlagForExistingPendingMarkers() async throws {
        let context = try makeContext()
        var reference = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == context.reference.id })
        reference.isReadOnly = true
        DatabaseListStore.testUpsert(reference)
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertEqual(outcome.drainedDatabaseIDs, [reference.id])
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
    }

    func test_drain_readOnlyDoesNotAuthorizeChangedKeyFactor() async throws {
        let context = try makeContext()
        var reference = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == context.reference.id })
        reference.isReadOnly = true
        reference.keyFileFilename = "foreign.keyx"
        DatabaseListStore.testUpsert(reference)
        let transport = CloudJournalTransport()
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).first?.id, context.stored.id)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
    }

    func test_drain_uncertainAttemptNeverResendsAcrossFreshDrainer() async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport(uploadError: .networkUnavailable)
        let environment = context.drainerEnvironment(saver: context.environment(transport: transport))
        let first = await PendingUploadDrainer(environment: environment).drainAll()
        XCTAssertNotNil(first.userIssue)
        let attempted = try XCTUnwrap(PendingUploadQueue.readJournal(for: context.reference.id).first)
        XCTAssertNotNil(attempted.marker.uploadAttemptID)
        XCTAssertNil(attempted.marker.confirmedAt)
        for _ in 0..<2 {
            let retry = await PendingUploadDrainer(environment: environment).drainAll()
            XCTAssertEqual(retry.skippedDatabaseIDs, [context.reference.id])
        }
        XCTAssertEqual(transport.effects.uploads, [.init(bytes: context.payload, revision: "rev-1")])
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: context.reference.id).first?.marker, attempted.marker)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
        XCTAssertFalse(try PendingUploadQueue.dropIfUnchanged(attempted))
    }

    func test_delivery_unknownSchemaAndUnreadableJournalFailClosedWithoutDroppingSource() async throws {
        for corrupt in [false, true] {
            let context = try makeContext()
            let original = try Data(contentsOf: context.stored.fileURL)
            let faultReached = CloudJournalEffectCounter()
            var saver = context.environment()
            if corrupt {
                saver.queue.readData = { url in
                    if url.resolvingSymlinksInPath().standardizedFileURL == context.stored.fileURL.resolvingSymlinksInPath().standardizedFileURL { faultReached.record(); throw CocoaError(.fileReadNoPermission) }
                    return try Data(contentsOf: url)
                }
            } else {
                var marker = context.stored.marker
                marker.journalVersion = 99
                try JSONEncoder().encode(marker).write(to: context.stored.fileURL)
            }
            let transport = CloudJournalTransport()
            saver.upload = { _, bytes, rev, _ in try await transport.upload(bytes, revision: rev) }
            do {
                _ = try await CloudDatabaseSaver.deliver(context.stored, reference: context.reference, environment: saver)
                XCTFail("Unreadable or unknown journal must not be treated as empty")
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, corrupt ? .fileReadNoPermission : .fileReadCorruptFile)
            }
            if corrupt { XCTAssertGreaterThan(faultReached.value, 0) }
            XCTAssertTrue(transport.effects.uploads.isEmpty)
            XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
            XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.stored.fileURL.path))
            try original.write(to: context.stored.fileURL)
        }
    }

    private func assertRemoteConflict(remote: Data, revision: String = "rev-2") async throws {
        let context = try makeContext()
        let transport = CloudJournalTransport(remote: remote, revision: revision)
        let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drainAll()
        XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
        XCTAssertEqual(outcome.conflictDatabaseIDs, [context.reference.id])
        XCTAssertTrue(transport.effects.uploads.isEmpty)
        let marker = try XCTUnwrap(PendingUploadQueue.readJournal(for: context.reference.id).first)
        XCTAssertEqual(marker.id, context.stored.id)
        XCTAssertTrue(marker.marker.isConflicted)
        XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        XCTAssertEqual(try Data(contentsOf: context.payloadURL), context.payload)
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: context.reference) else { return XCTFail("Conflict must expose exact intended bytes") }
        XCTAssertEqual(sources.map(\.data), [context.payload])
    }

    private func registeredReference() -> DatabaseReference {
        let reference = makeCloudReference()
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    private func makeContext(install: Bool = true) throws -> CloudJournalTestContext {
        try CloudJournalTestContext(reference: registeredReference(), install: install)
    }

    private func enqueueLegacy(for reference: DatabaseReference, bytes: Data, finalized: Bool?, baseRev: String? = "rev-1") throws -> PendingUploadQueue.StoredMarker {
        try PendingUploadQueue.enqueue(.init(databaseId: reference.id,
            encryptedBytesCacheURL: PendingUploadQueue.makeRelativeAppGroupPath(for: DatabaseListStore.cacheLocation(for: reference)),
            openTimeSHA512: FileDigest.sha512(bytes), expectedRev: reference.expectedCloudRevision,
            createdAt: .now, baseRev: baseRev, isPayloadFinalized: finalized), notifying: false)
    }

    private func transportEnvironment(reference: DatabaseReference, transport: CloudJournalTransport) -> CloudDatabaseSaver.Environment {
        var saver = CloudDatabaseSaver.Environment.live
        saver.getMetadata = { _ in try transport.metadata(byteCount: 0) }
        saver.downloadRemoteData = { _ in transport.download(fallback: Data()) }
        saver.upload = { _, bytes, rev, _ in try await transport.upload(bytes, revision: rev) }
        saver.revisionIdentifiesContent = { _, _ in false }
        return saver
    }

    private func drainerEnvironment(saver: CloudDatabaseSaver.Environment) -> PendingUploadDrainer.Environment {
        var environment = PendingUploadDrainer.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.deliverMarker = { try await CloudDatabaseSaver.deliver($0, reference: $1, environment: saver) }
        return environment
    }

    private func makeCloudReference(
        id: UUID = UUID(),
        rev: String? = "rev-1",
        isReadOnly: Bool = false
    ) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "cloud.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            isReadOnly: isReadOnly,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/\(id.uuidString).kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: rev,
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }

    private func makeLocalReference(id: UUID = UUID()) -> DatabaseReference {
        DatabaseReference(
            id: id,
            nickname: nil,
            filename: "local.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil
        )
    }

    /// One-shot signal usable across isolation domains: `wait()` suspends
    /// until `signal()` has been called (immediately resuming if it already
    /// was).
    private final class AsyncSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignaled = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func signal() {
            lock.lock()
            isSignaled = true
            let pending = continuations
            continuations = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isSignaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }
}
