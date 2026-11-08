import CryptoKit
import XCTest
@testable import KeeForge

final class CloudDatabaseSaverTests: XCTestCase {
    override func setUpWithError() throws {
        XCTAssertTrue(AppGroupContainer.isRedirectedForTesting)
        DatabaseListStore.clearAll()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        super.tearDown()
    }

    func testOfflineSaveSurvivesRestartWithExactImmutableCiphertext() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        let result = try await saveAndDrain(context, remote: remote)
        guard case .saved(let sha, _) = result else { return XCTFail("Local commit must succeed offline") }
        let stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        let payload = try immutableBytes(stored)
        XCTAssertEqual(KDBXCrypto.sha512(payload), sha)
        XCTAssertEqual(try cache(context.reference), payload)
        XCTAssertEqual(stored.marker.remoteBaseSHA512, KDBXCrypto.sha512(context.source))
        XCTAssertNil(stored.marker.uploadAttemptID)
        XCTAssertNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
        // A fresh enumeration and environment model process restart; no in-memory queue state is reused.
        await remote.setOffline(false)
        let reloaded = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        _ = try await CloudDatabaseSaver.deliver(reloaded, reference: current(context.reference), environment: environment(remote))
        let awaited1 = await remote.data()
        XCTAssertEqual(awaited1, payload)
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
        XCTAssertNotNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
        let parsed = try KDBXParser.parseWithMeta(data: payload, compositeKey: context.key, sessionKey: context.sessionKey)
        XCTAssertTrue(parsed.rootGroup.allEntries.contains { $0.title == "first" })
    }

    func testSuccessiveOfflineSavesRetainExactPredecessorAndRemoteBase() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        _ = try await saveAndDrain(context, remote: remote)
        let first = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        let firstBytes = try cache(context.reference)
        let secondDraft = try edit(firstBytes, key: context.key, sessionKey: context.sessionKey, title: "second")
        _ = try await CloudDatabaseSaver.save(draft: secondDraft, reference: current(context.reference), compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(firstBytes), expectedRev: "r0", kdfPolicy: .mainApp, environment: environment(remote))
        let second = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first { $0.id != first.id })
        XCTAssertEqual(second.marker.predecessorOperationID, first.id)
        XCTAssertEqual(second.marker.predecessorSHA512, KDBXCrypto.sha512(firstBytes))
        XCTAssertEqual(second.marker.remoteBaseSHA512, KDBXCrypto.sha512(context.source))
        XCTAssertEqual(second.marker.expectedRev, "r0")
        let newest = try cache(context.reference)
        await remote.setOffline(false)
        _ = try await CloudDatabaseSaver.deliver(first, reference: current(context.reference), environment: environment(remote))
        XCTAssertEqual(try cache(context.reference), newest)
        XCTAssertNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
        let rebased = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertEqual(rebased.marker.remoteBaseSHA512, KDBXCrypto.sha512(firstBytes))
        XCTAssertEqual(rebased.marker.expectedRev, "r1")
        _ = try await CloudDatabaseSaver.deliver(rebased, reference: current(context.reference), environment: environment(remote))
        let awaited2 = await remote.data()
        XCTAssertEqual(awaited2, newest)
        XCTAssertNotNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
    }

    func testPreparedJournalRecoversOnlyAfterCacheCommitAndLegacyRemainsUnproven() throws {
        let context = try makeContext()
        let cacheURL = DatabaseListStore.cacheLocation(for: context.reference)
        let intended = Data("distinct encrypted test payload".utf8)
        let prepared = try PendingUploadQueue.withCommitLock(for: context.reference.id) {
            try PendingUploadQueue.prepare(reference: context.reference, currentData: context.source, intendedData: intended, cacheURL: cacheURL)
        }
        XCTAssertEqual(try PendingUploadQueue.recoverPrepared(prepared).marker.isPayloadFinalized, false)
        _ = try LocalDatabaseSaver.Environment.live.replaceFileAtomically(intended, cacheURL, KDBXCrypto.sha512(context.source))
        let recovered = try PendingUploadQueue.recoverPrepared(prepared)
        XCTAssertEqual(recovered.marker.isPayloadFinalized, true)
        XCTAssertEqual(recovered.marker.openTimeSHA512, KDBXCrypto.sha512(intended))
        var legacy = prepared.marker
        legacy.intendedPayloadPath = nil
        legacy.intendedPayloadSHA512 = nil
        legacy.isPayloadFinalized = nil
        let old = try PendingUploadQueue.enqueue(legacy, notifying: false)
        XCTAssertNil(try PendingUploadQueue.recoverPrepared(old).marker.isPayloadFinalized)
    }

    func testFailedFinalizeIsRecoveredFromDurableIntentAfterRestart() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        let writes = JournalWriteCounter()
        var env = environment(remote)
        env.queue.writeMarkerAtomically = { data, url in
            if url.pathExtension == "json", writes.increment() > 1 { throw CocoaError(.fileWriteUnknown) }
            try writeAtomicallyAndDurably(data, to: url)
        }
        let result = try await saveAndDrain(context, remote: remote, environment: env)
        guard case .saved = result else { return XCTFail("The durable intent covers the committed cache") }
        let provisional = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertEqual(provisional.marker.isPayloadFinalized, false)
        let recovered = try PendingUploadQueue.recoverPrepared(provisional)
        XCTAssertEqual(recovered.marker.isPayloadFinalized, true)
        XCTAssertEqual(try immutableBytes(recovered), try cache(context.reference))
    }

    func testFailedReplacementNeverMakesPreparedPayloadEligible() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        var env = environment(remote)
        env.replaceFile = { _, _, _ in throw CocoaError(.fileWriteUnknown) }
        do { _ = try await saveAndDrain(context, remote: remote, environment: env); XCTFail("Expected replacement failure") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown) }
        let intent = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertEqual(try PendingUploadQueue.recoverPrepared(intent).marker.isPayloadFinalized, false)
        let result = try await CloudDatabaseSaver.deliver(intent, reference: context.reference, environment: environment(remote))
        XCTAssertNil(result)
        let awaited3 = await remote.uploadCount()
        XCTAssertEqual(awaited3, 0)
        XCTAssertEqual(try cache(context.reference), context.source)
    }

    func testAcceptedResponseLostReconcilesExactBytesWithoutResend() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.loseNextResponse()
        _ = try await saveAndDrain(context, remote: remote)
        let stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertNotNil(stored.marker.uploadAttemptID)
        let payload = try immutableBytes(stored)
        let awaited4 = await remote.data()
        XCTAssertEqual(awaited4, payload)
        _ = try await CloudDatabaseSaver.deliver(stored, reference: current(context.reference), environment: environment(remote))
        let awaited5 = await remote.uploadCount()
        XCTAssertEqual(awaited5, 1)
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
    }

    func testBaseEqualProbeCannotFenceDelayedPreflightRequest() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.delayNextAcceptance()
        _ = try await saveAndDrain(context, remote: remote, environment: environment(remote, guarantee: .preflightOnly))
        let stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertNotNil(stored.marker.uploadAttemptID)
        let awaited6 = await remote.data()
        XCTAssertEqual(awaited6, context.source)
        let deferred = try await CloudDatabaseSaver.deliver(stored, reference: current(context.reference), environment: environment(remote, guarantee: .preflightOnly))
        XCTAssertNil(deferred)
        let awaited7 = await remote.uploadCount()
        XCTAssertEqual(awaited7, 1)
        await remote.finishDelayedAcceptance()
        _ = try await CloudDatabaseSaver.deliver(stored, reference: current(context.reference), environment: environment(remote, guarantee: .preflightOnly))
        let awaited8 = await remote.uploadCount()
        XCTAssertEqual(awaited8, 1)
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
    }

    func testConditionalRetryUsesOriginalValidatorAndExactCiphertext() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.failNextUpload(.networkUnavailable)
        _ = try await saveAndDrain(context, remote: remote)
        let stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        _ = try await CloudDatabaseSaver.deliver(stored, reference: current(context.reference), environment: environment(remote))
        let awaited9 = await remote.uploadCount()
        XCTAssertEqual(awaited9, 2)
        let awaited10 = await remote.data()
        XCTAssertEqual(awaited10, try cache(context.reference))
        let awaited11 = await remote.validators()
        XCTAssertEqual(awaited11, ["r0", "r0"])
    }

    func testAuthQuotaAndPermissionErrorsRetainLocalCommitAndIssue() async throws {
        for issue in [CloudProviderError.notAuthenticated, .insufficientSpace, .permissionDenied] {
            DatabaseListStore.clearAll()
            let context = try makeContext()
            let remote = Remote(context.source)
            await remote.failNextUpload(issue)
            _ = try await saveAndDrain(context, remote: remote)
            let stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
            XCTAssertEqual(try immutableBytes(stored), try cache(context.reference))
            XCTAssertEqual(current(context.reference).cloudSyncMetadata?.lastSyncIssue, issue.syncIssue)
            XCTAssertNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
            XCTAssertNotNil(stored.marker.uploadAttemptID)
        }
    }

    func testStaleUploadCompletionCannotRevertNewerAutoFillLocalCommit() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        let gate = Gate()
        await remote.pauseNextUpload(gate)
        let env = environment(remote)
        let task = Task {
            let result = try await CloudDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
                openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp, environment: env)
            if let stored = PendingUploadQueue.listMarkers(for: context.reference.id).first {
                _ = try await CloudDatabaseSaver.deliver(stored, reference: context.reference, environment: env)
            }
            return result
        }
        await gate.waitUntilHeld()
        let first = try cache(context.reference)
        let secondDraft = try edit(first, key: context.key, sessionKey: context.sessionKey, title: "AutoFill successor")
        _ = try await LocalDatabaseSaver.save(draft: secondDraft, reference: current(context.reference), compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(first), kdfPolicy: .autoFillExtension)
        let newest = try cache(context.reference)
        await gate.release()
        _ = try await task.value
        XCTAssertEqual(try cache(context.reference), newest)
        let awaited12 = await remote.data()
        XCTAssertNotEqual(awaited12, newest)
        XCTAssertNil(current(context.reference).cloudSyncMetadata?.lastSyncedAt)
        let successor = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertEqual(successor.marker.remoteBaseSHA512, KDBXCrypto.sha512(first))
        _ = try await CloudDatabaseSaver.deliver(successor, reference: current(context.reference), environment: environment(remote))
        let awaited13 = await remote.data()
        XCTAssertEqual(awaited13, newest)
    }

    func testConcurrentAppAndAutoFillBaselineAllowsOnlyOneCommit() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        let env = environment(remote)
        async let app = CloudDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp, environment: env)
        async let autoFill = AutoFillSaveCoordinator.saveNewEntry(draftPayload: EntryDraftPayload(title: "AutoFill"),
            reference: context.reference, rootGroup: context.draft.rootGroup, meta: context.draft.meta,
            sessionKey: context.sessionKey, compositeKey: context.key, openTimeSHA512: KDBXCrypto.sha512(context.source))
        let (appResult, extensionResult) = try await (app, autoFill)
        var saved = 0
        if case .saved = appResult { saved += 1 }
        if case .saved = extensionResult { saved += 1 }
        XCTAssertEqual(saved, 1)
        let markers = PendingUploadQueue.listMarkers(for: context.reference.id)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(try immutableBytes(XCTUnwrap(markers.first)), try cache(context.reference))
    }

    func testImmutablePendingPayloadSurvivesCacheRefreshAndMoreThanFiveBackups() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        _ = try await saveAndDrain(context, remote: remote)
        var stored = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        let payload = try immutableBytes(stored)
        stored.marker.isConflicted = true
        stored = try PendingUploadQueue.update(stored)
        let backups = DatabaseListStore.databaseBackupDirectoryURL(for: context.reference)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for index in 0..<10 {
            let url = backups.appendingPathComponent(LocalDatabaseSaver.backupFilename(for: Date(timeIntervalSince1970: Double(index))))
            try Data("backup-\(index)".utf8).write(to: url)
        }
        try DatabaseListStore.cacheDatabaseCopy(context.source, for: context.reference)
        try DatabaseListStore.pruneBackups(for: context.reference, keeping: 5)
        XCTAssertEqual(DatabaseListStore.recentBackups(for: context.reference).count, 5)
        guard case .recovered(let sources) = PendingUploadRecovery.lookUpPayloads(for: current(context.reference)) else { return XCTFail("Immutable source must remain recoverable") }
        XCTAssertEqual(sources.first?.data, payload)
    }

    func testDisabledReplacementKeepsLocalBytesAndNeverDispatches() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        _ = try await saveAndDrain(context, remote: remote, environment: environment(remote, guarantee: .disabled))
        let awaited14 = await remote.uploadCount()
        XCTAssertEqual(awaited14, 0)
        XCTAssertNotEqual(try cache(context.reference), context.source)
        XCTAssertEqual(PendingUploadQueue.listMarkers(for: context.reference.id).count, 1)
    }

    func testRekeyOfflineRejectsBeforeJournalAndCacheMutation() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        do {
            _ = try await rekey(context, remote: remote)
            XCTFail("Offline rekey must reject")
        } catch { XCTAssertEqual(error as? CloudProviderError, .networkUnavailable) }
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
        XCTAssertEqual(try cache(context.reference), context.source)
    }

    func testResponseLostRekeyRecoversAssociationAndEpochAfterInitiatingSessionIsGone() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.loseNextResponse()
        do { _ = try await rekey(context, remote: remote); XCTFail("Lost response is uncertain") }
        catch { XCTAssertEqual(error as? CloudProviderError, .networkUnavailable) }
        let journal = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertNotNil(journal.marker.rekeyContext)
        XCTAssertNotNil(journal.marker.uploadAttemptID)
        XCTAssertEqual(try cache(context.reference), context.source)
        do {
            _ = try await LocalDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
                openTimeSHA512: KDBXCrypto.sha512(context.source), kdfPolicy: .autoFillExtension)
            XCTFail("An old-key AutoFill commit cannot pass the rekey fence")
        } catch { XCTAssertEqual(error as? SaveError, .saveContextUnavailable) }
        _ = try await CloudDatabaseSaver.deliver(journal, reference: current(context.reference), environment: environment(remote))
        let updated = current(context.reference)
        XCTAssertEqual(updated.cloudSyncMetadata?.keyEpoch, journal.marker.rekeyContext?.epoch)
        XCTAssertEqual(updated.cloudSyncMetadata?.requiresTypedUnlock, true)
        XCTAssertEqual(updated.keyFileFilename, "new.keyx")
        XCTAssertEqual(updated.keyFileBookmarkData, Data("new bookmark".utf8))
        XCTAssertNotNil(updated.lastMasterKeyChangeAt)
        let awaited15 = await remote.uploadCount()
        XCTAssertEqual(awaited15, 1)
        let newKey = try KDBXCrypto.compositeKey(password: "new password")
        _ = try KDBXParser.parseWithMeta(data: cache(updated), compositeKey: newKey, sessionKey: context.sessionKey)
        XCTAssertThrowsError(try KDBXParser.parseWithMeta(data: cache(updated), compositeKey: context.key, sessionKey: context.sessionKey))
    }

    func testPreflightUncertainRekeyBlocksOldKeyDrainAndKeepsJournalOnBaseEqualProbe() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.delayNextAcceptance()
        let env = environment(remote, guarantee: .preflightOnly)
        do { _ = try await rekey(context, remote: remote, environment: env); XCTFail("Expected uncertain rekey") } catch { }
        let journal = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        let path = try PendingUploadQueue.makeRelativeAppGroupPath(for: DatabaseListStore.cacheLocation(for: context.reference))
        let legacy = try PendingUploadQueue.enqueue(.init(databaseId: context.reference.id, encryptedBytesCacheURL: path,
            openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", createdAt: .distantPast), notifying: false)
        let awaited16 = try await CloudDatabaseSaver.deliver(legacy, reference: context.reference, environment: env)
        XCTAssertNil(awaited16)
        let awaited17 = try await CloudDatabaseSaver.deliver(journal, reference: context.reference, environment: env)
        XCTAssertNil(awaited17)
        let awaited18 = await remote.uploadCount()
        XCTAssertEqual(awaited18, 1)
        XCTAssertEqual(try cache(context.reference), context.source)
        await remote.finishDelayedAcceptance()
        _ = try await CloudDatabaseSaver.deliver(journal, reference: context.reference, environment: env)
        let old = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first { $0.id == legacy.id })
        guard case .conflict = try await CloudDatabaseSaver.deliver(old, reference: current(context.reference), environment: env) else { return XCTFail("Old epoch must remain a recoverable conflict") }
        let awaited19 = await remote.uploadCount()
        XCTAssertEqual(awaited19, 1)
    }

    func testMergedSourcesAreRetainedUnlessDurableReplacementOwnsThem() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        await remote.setOffline(true)
        _ = try await saveAndDrain(context, remote: remote)
        let source = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        try PendingUploadQueue.transferMergedSources([source], toPayloadSHA512: Data("unowned".utf8), for: context.reference.id)
        XCTAssertEqual(PendingUploadQueue.listMarkers(for: context.reference.id).count, 1)
        let bytes = try cache(context.reference)
        let merged = try edit(bytes, key: context.key, sessionKey: context.sessionKey, title: "merged")
        _ = try await LocalDatabaseSaver.save(draft: merged, reference: current(context.reference), compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(bytes), kdfPolicy: .mainApp)
        let mergedBytes = try cache(context.reference)
        try PendingUploadQueue.transferMergedSources([source], toPayloadSHA512: KDBXCrypto.sha512(mergedBytes), for: context.reference.id)
        let owner = try XCTUnwrap(PendingUploadQueue.listMarkers(for: context.reference.id).first)
        XCTAssertEqual(owner.marker.absorbedOperationIDs, [source.id])
        XCTAssertEqual(try immutableBytes(owner), mergedBytes)
    }

    func testRemoteHasDivergedComparesRevExactlyWhenOneWasRecorded() {
        let recorded = makeRecordedMetadata(rev: "rev-A", contentHash: "hash-A")

        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-Z", size: 1, rev: "rev-A"),
                expectedRev: "rev-A"
            ),
            "A matching rev decides the question on its own; the hash is not consulted."
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: "rev-B"),
                expectedRev: "rev-A"
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: "rev-A"
            )
        )
    }

    func testRemoteHasDivergedFallsBackToContentHashWhenNoRevWasRecorded() {
        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: "hash-A"),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: nil
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: "hash-A"),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-B", size: 1, rev: nil),
                expectedRev: nil
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: nil),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: nil
            ),
            "Remote reports a hash we never recorded, so we have not seen these bytes."
        )
        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: nil),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: nil, size: 1, rev: nil),
                expectedRev: nil
            ),
            "Bare WebDAV residue: nothing to verify against, so the save proceeds."
        )
    }

    private func makeRecordedMetadata(rev: String?, contentHash: String?) -> CloudSyncMetadata {
        CloudSyncMetadata(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            fileId: "/Vaults/cloud-save.kdbx",
            displayPath: "/Vaults/cloud-save.kdbx",
            remoteContentHash: contentHash,
            remoteModifiedAt: Date(timeIntervalSince1970: 100),
            remoteRev: rev,
            lastSyncedAt: nil,
            lastSyncIssue: nil
        )
    }

    func testOrdinarySaveReturnsBeforeAnyProviderRequest() async throws {
        let context = try makeContext()
        let calls = JournalWriteCounter()
        var env = CloudDatabaseSaver.Environment.live
        env.queue.postDarwinNotification = { }
        env.getMetadata = { _ in _ = calls.increment(); throw CloudProviderError.networkUnavailable }
        env.upload = { _, _, _, _ in _ = calls.increment(); throw CloudProviderError.networkUnavailable }
        let result = try await CloudDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp, environment: env)
        guard case .saved = result else { return XCTFail("Expected durable local commit") }
        XCTAssertEqual(calls.increment(), 1, "Only this assertion may increment the counter")
        XCTAssertNil(PendingUploadQueue.listMarkers(for: context.reference.id).first?.marker.uploadAttemptID)
    }

    func testLocalBaselineAndBackupFailureNeverPublishAnEligibleIntent() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        var env = environment(remote)
        env.writeBackup = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        do { _ = try await saveAndDrain(context, remote: remote, environment: env); XCTFail("Backup failure must abort") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        XCTAssertEqual(try cache(context.reference), context.source)
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
        let foreign = Data("foreign ciphertext".utf8)
        try DatabaseListStore.cacheDatabaseCopy(foreign, for: context.reference)
        let result = try await saveAndDrain(context, remote: remote)
        guard case .conflict(let sha, let bytes) = result else { return XCTFail("Actual local overwrite gate must conflict") }
        XCTAssertEqual(bytes, foreign)
        XCTAssertEqual(sha, KDBXCrypto.sha512(foreign))
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
    }

    func testReadOnlyAndInvalidXMLNeverCommitOrDispatch() async throws {
        let context = try makeContext()
        let remote = Remote(context.source)
        var readOnly = context.reference
        readOnly.isReadOnly = true
        do {
            _ = try await CloudDatabaseSaver.save(draft: context.draft, reference: readOnly, compositeKey: context.key,
                openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp, environment: environment(remote))
            XCTFail("Read-only database must reject")
        } catch { XCTAssertEqual(error as? SaveError, .databaseIsReadOnly) }
        context.draft.rootGroup.entries.append(KPEntry(title: "Invalid", notes: "nul\u{0}"))
        do { _ = try await saveAndDrain(context, remote: remote); XCTFail("Invalid XML must reject") }
        catch { XCTAssertEqual(error as? KDBXXMLSerializer.SerializationError, .invalidXMLCharacter(0)) }
        XCTAssertEqual(try cache(context.reference), context.source)
        XCTAssertTrue(PendingUploadQueue.listMarkers(for: context.reference.id).isEmpty)
        let count = await remote.uploadCount()
        XCTAssertEqual(count, 0)
    }

    #if os(macOS)
    func testLocalHeadMutationWaitsForAnotherProcessesDatabaseListLock() throws {
        let context = try makeContext()
        let lockURL = AppGroupContainer.url.appendingPathComponent(".database-list.lock")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('x',flush=True); sys.stdin.buffer.read(1)", lockURL.path]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 1), Data("x".utf8))
        let premature = expectation(description: "No mutation while another process holds the list lock")
        premature.isInverted = true
        let finished = expectation(description: "Mutation finishes after cross-process unlock")
        let operationID = UUID()
        DispatchQueue.global().async {
            DatabaseListStore.recordCloudLocalCommit(for: context.reference.id, operationID: operationID)
            premature.fulfill()
            finished.fulfill()
        }
        wait(for: [premature], timeout: 0.1)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(current(context.reference).cloudSyncMetadata?.localHeadOperationID, operationID)
    }
    #endif

    private struct Context: Sendable {
        let reference: DatabaseReference
        let source: Data
        let key: SymmetricKey
        let sessionKey: SymmetricKey
        let draft: DatabaseDraft
    }

    private func makeContext() throws -> Context {
        let loaded = try KDBXCompatibilitySupport.load(.syntheticRich, bundle: Bundle(for: Self.self))
        let file = CloudFile(id: "/vault.kdbx", name: "vault.kdbx", path: "/vault.kdbx", isFolder: false, modifiedDate: .now, size: Int64(loaded.sourceData.count))
        var reference = DatabaseListStore.addCloud(provider: "webdav", accountId: "test", file: file)
        reference.updateCloudSyncMetadata { $0.remoteRev = "r0"; $0.lastSyncedAt = .now }
        DatabaseListStore.update(reference)
        try DatabaseListStore.cacheDatabaseCopy(loaded.sourceData, for: reference)
        let draft = try edit(loaded.sourceData, key: loaded.compositeKey, sessionKey: loaded.sessionKey, title: "first")
        return Context(reference: reference, source: loaded.sourceData, key: loaded.compositeKey, sessionKey: loaded.sessionKey, draft: draft)
    }

    private func edit(_ bytes: Data, key: SymmetricKey, sessionKey: SymmetricKey, title: String) throws -> DatabaseDraft {
        let parsed = try KDBXParser.parseWithMeta(data: bytes, compositeKey: key, sessionKey: sessionKey)
        let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey)
        return try draft.apply(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup), draft: EntryDraftPayload(title: title, password: "secret")))
    }

    private func current(_ reference: DatabaseReference) -> DatabaseReference {
        DatabaseListStore.databases.first { $0.id == reference.id } ?? reference
    }

    private func cache(_ reference: DatabaseReference) throws -> Data {
        try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
    }

    private func immutableBytes(_ stored: PendingUploadQueue.StoredMarker) throws -> Data {
        try Data(contentsOf: PendingUploadQueue.resolveAppGroupURL(for: XCTUnwrap(stored.marker.intendedPayloadPath)))
    }

    private func environment(_ remote: Remote, guarantee: CloudWriteGuarantee = .serverConditional) -> CloudDatabaseSaver.Environment {
        var env = CloudDatabaseSaver.Environment.live
        env.beginBackgroundTask = { _ in .invalid }
        env.endBackgroundTask = { _ in }
        env.queue.postDarwinNotification = { }
        env.getMetadata = { _ in try await remote.metadata() }
        env.downloadRemoteData = { _ in try await remote.download() }
        env.upload = { _, bytes, rev, _ in try await remote.upload(bytes, expectedRev: rev) }
        env.writeGuarantee = { _, _, _ in guarantee }
        return env
    }

    private func saveAndDrain(_ context: Context, remote: Remote, environment env: CloudDatabaseSaver.Environment? = nil) async throws -> SaveResult {
        let effective = env ?? environment(remote)
        let result = try await CloudDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp, environment: effective)
        if case .saved = result {
            for stored in PendingUploadQueue.listMarkers(for: context.reference.id) {
                _ = try? await CloudDatabaseSaver.deliver(stored, reference: current(context.reference), environment: effective)
            }
        }
        return result
    }

    private func rekey(_ context: Context, remote: Remote, environment env: CloudDatabaseSaver.Environment? = nil) async throws -> SaveResult {
        try await CloudDatabaseSaver.save(draft: context.draft, reference: context.reference, compositeKey: context.key,
            openTimeSHA512: KDBXCrypto.sha512(context.source), expectedRev: "r0", kdfPolicy: .mainApp,
            newCompositeKey: KDBXCrypto.compositeKey(password: "new password"),
            rekeyContext: .init(keyFileBookmarkData: Data("new bookmark".utf8), keyFileFilename: "new.keyx"), environment: env ?? environment(remote))
    }

    private actor Remote {
        private var bytes: Data
        private var revision = 0
        private var count = 0
        private var revs: [String?] = []
        private var offline = false
        private var nextFailure: CloudProviderError?
        private var loseResponse = false
        private var delayed = false
        private var delayedBytes: Data?
        private var gate: Gate?
        init(_ bytes: Data) { self.bytes = bytes }
        func setOffline(_ value: Bool) { offline = value }
        func failNextUpload(_ error: CloudProviderError) { nextFailure = error }
        func loseNextResponse() { loseResponse = true }
        func delayNextAcceptance() { delayed = true }
        func pauseNextUpload(_ gate: Gate) { self.gate = gate }
        func data() -> Data { bytes }
        func uploadCount() -> Int { count }
        func validators() -> [String?] { revs }
        func metadata() throws -> CloudFileMetadata {
            if offline { throw CloudProviderError.networkUnavailable }
            return CloudFileMetadata(modifiedDate: .now, contentHash: nil, size: Int64(bytes.count), rev: "r\(revision)")
        }
        func download() throws -> Data {
            if offline { throw CloudProviderError.networkUnavailable }
            return bytes
        }
        func upload(_ data: Data, expectedRev: String?) async throws -> CloudFileMetadata {
            count += 1
            revs.append(expectedRev)
            if let gate { self.gate = nil; await gate.hold() }
            if let error = nextFailure { nextFailure = nil; throw error }
            guard expectedRev == "r\(revision)" else { throw CloudProviderError.conflict(remoteRev: "r\(revision)") }
            if delayed { delayed = false; delayedBytes = data; throw CloudProviderError.networkUnavailable }
            bytes = data
            revision += 1
            if loseResponse { loseResponse = false; throw CloudProviderError.networkUnavailable }
            return try metadata()
        }
        func finishDelayedAcceptance() {
            if let delayedBytes { bytes = delayedBytes; revision += 1; self.delayedBytes = nil }
        }
    }

    private actor Gate {
        private var held = false
        private var entered: CheckedContinuation<Void, Never>?
        private var exit: CheckedContinuation<Void, Never>?
        func waitUntilHeld() async {
            if held { return }
            await withCheckedContinuation { entered = $0 }
        }
        func hold() async {
            held = true
            entered?.resume(); entered = nil
            await withCheckedContinuation { exit = $0 }
        }
        func release() { exit?.resume(); exit = nil }
    }
}

private final class JournalWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
