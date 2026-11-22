import AuthenticationServices
import CryptoKit
import LocalAuthentication
import XCTest
import KDBXKit
@testable import KeeForge

/// The manual cloud sync policy as the unlocked session sees it: the skipped
/// refresh it reports on open, and Sync Now.
@MainActor
final class DatabaseViewModelCloudSyncTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() async throws {
        CredentialIdentityStoreManager.populateObserver = nil
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    private struct PendingMergeSetup {
        let vm: DatabaseViewModel
        let reference: DatabaseReference
        let base: Data
        let source: CloudJournalTestContext
        let remote: InMemoryRemoteProvider
        let saver: CloudDatabaseSaver.Environment
        let encryptions: CloudJournalEffectCounter
        let replacements: CloudJournalEffectCounter
        let keyEffects: CloudJournalEffectCounter
        let diagnostics: TestDatabaseSupport.LocalPublicationTrace
    }

    private func pendingMergeSetup(payload: Data? = nil, conflicted: Bool = true, sourceAfterUnlock: Bool = false, legacy: Bool = false,
        beforeSave: (@MainActor @Sendable (DatabaseReference) async throws -> Void)? = nil,
        failFinalization: Bool = false, diagnostics: TestDatabaseSupport.LocalPublicationTrace = .init(),
        configureSaver: @Sendable (inout CloudDatabaseSaver.Environment) -> Void = { _ in },
        afterSaver: (@Sendable () async -> Void)? = nil, recordedContentHash: String? = nil) async throws -> PendingMergeSetup {
        let base = try fixtureData()
        var reference = try makeStoredManualReference(fileID: "/merge-\(UUID().uuidString).kdbx", autoFillEnabled: false)
        if let recordedContentHash {
            reference.updateCloudSyncMetadata { $0.remoteContentHash = recordedContentHash }
            DatabaseListStore.testUpsert(reference)
        }
        try DatabaseListStore.cacheDatabaseCopy(base, for: reference)
        let remote = InMemoryRemoteProvider(bytes: base, rev: "rev-A")
        let encryptions = CloudJournalEffectCounter()
        let replacements = CloudJournalEffectCounter()
        let keyEffects = CloudJournalEffectCounter()
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        let encrypt = environment.encryptDraft
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.record()
            diagnostics.recordObservation("encrypt.begin count=\(encryptions.value)")
            let result = try encrypt(draft, key, header, policy)
            diagnostics.recordObservation("encrypt.end")
            return result
        }
        let replace = environment.replaceFile
        environment.replaceFile = { data, url, sha, ref in
            replacements.record()
            diagnostics.recordObservation("replacement.begin count=\(replacements.value)")
            do {
                let result = try replace(data, url, sha, ref)
                diagnostics.recordObservation("replacement.end")
                return result
            } catch { diagnostics.record("replacement", error); throw error }
        }
        let metadataCalls = CloudJournalEffectCounter()
        let downloadCalls = CloudJournalEffectCounter()
        let uploadCalls = CloudJournalEffectCounter()
        environment.getMetadata = { _ in
            metadataCalls.record(); diagnostics.recordObservation("metadata count=\(metadataCalls.value)")
            return remote.currentMetadata
        }
        environment.downloadRemoteData = { _ in
            downloadCalls.record(); diagnostics.recordObservation("download count=\(downloadCalls.value)")
            return remote.currentBytes
        }
        environment.upload = { _, bytes, rev, _ in
            uploadCalls.record(); diagnostics.recordObservation("upload.begin count=\(uploadCalls.value)")
            let result = try remote.store(bytes, expectedRev: rev)
            diagnostics.recordObservation("upload.end")
            return result
        }
        let read = environment.readData
        environment.readData = { url in
            diagnostics.recordObservation("saver-read.begin")
            do { let data = try read(url); diagnostics.recordObservation("saver-read.end"); return data }
            catch { diagnostics.record("saver-read", error); throw error }
        }
        environment.queue.observedCommitLockFailure = { code in
            diagnostics.recordObservation("commit-flock actualErrno=\(code)")
        }
        environment.revisionIdentifiesContent = { _, _ in false }
        if failFinalization {
            let encode = environment.queue.encodeMarker
            environment.queue.encodeMarker = { marker in
                if marker.isPayloadFinalized == true { throw CocoaError(.fileWriteNoPermission) }
                return try encode(marker)
            }
        }
        configureSaver(&environment)
        let saver = environment
        let vm = DatabaseViewModel(databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in remote })
            }, cloudRefreshOperation: { reference, _ in
                try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference,
                    honorsManualSyncPolicy: false, providerResolver: { _ in remote })
            }, localPublicationFailure: { diagnostics.record($0, $1) },
            cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
                try await beforeSave?(reference)
                diagnostics.recordObservation("saver.enter")
                do {
                    let result = try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                        openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev,
                        kdfPolicy: .mainApp, newCompositeKey: newKey, encryptionSettings: settings, environment: saver)
                    diagnostics.recordObservation("saver.return")
                    await afterSaver?()
                    return result
                } catch { diagnostics.record("saver", error); throw error }
            }, reloadOperation: { reference, key in
                try await DatabaseViewModel.reloadDatabase(reference: reference, compositeKey: key, providerResolver: { _ in remote })
            }, quickUnlockKeyPersistOperation: { _, _, _ in false },
            expressUnlockKeySaveOperation: { _, _ in keyEffects.record() })
        diagnostics.recordObservation("setup-unlock-source.begin")
        do {
        if sourceAfterUnlock { await vm.unlock(password: fixturePassword) }
        let source = try CloudJournalTestContext(reference: reference, base: base,
            payload: payload ?? mergeVariant(title: "AutoFill Entry"), legacy: legacy)
        if conflicted && !legacy { _ = try PendingUploadQueue.markConflicted(source.stored) }
        if !sourceAfterUnlock { await vm.unlock(password: fixturePassword) }
        XCTAssertEqual(vm.state, .unlocked)
        let cache = try Data(contentsOf: source.cacheURL)
        diagnostics.recordObservation("setup-source generation=\(source.stored.marker.generation) cacheMatches=\(cache == source.payload) headMatches=\(DatabaseListStore.databases.first { $0.id == reference.id }?.cloudSyncMetadata?.localHeadOperationID == source.stored.id)")
        return .init(vm: vm, reference: reference, base: base, source: source, remote: remote, saver: saver,
            encryptions: encryptions, replacements: replacements, keyEffects: keyEffects, diagnostics: diagnostics)
        } catch {
            let diagnostic = diagnostics.failure(error, at: "setup-unlock-source")
            XCTFail(diagnostic)
            vm.lock()
            throw error
        }
    }

    private func mergeVariant(title: String, pool: [Data]? = nil, attachment: Bool = false) throws -> Data {
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let session = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: fixtureData(), compositeKey: key, sessionKey: session)
        let root = parsed.rootGroup
        let visible = TestDatabaseSupport.visibleRootGroupID(in: root) == root.id ? root : root.groups[0]
        var entry = KPEntry(title: title)
        if attachment { entry.attachments = [KPAttachment(name: "note.txt", ref: 0)] }
        visible.entries.append(entry)
        var header = parsed.header
        if let pool { header.innerHeaderBinaryFields = pool }
        return try KDBXWriter.write(rootGroup: root, meta: parsed.meta, compositeKey: key,
            header: header, sessionKey: session, kdfPolicy: .mainApp)
    }

    private func mergedJournal(_ setup: PendingMergeSetup, titles: Set<String>) throws -> PendingUploadQueue.StoredMarker {
        let journal = try PendingUploadQueue.readJournal(for: setup.reference.id)
        let merged = try XCTUnwrap(journal.first)
        XCTAssertEqual(journal.count, 1)
        XCTAssertNotEqual(merged.id, setup.source.stored.id)
        setup.diagnostics.recordObservation("journal-proof.begin generation=\(merged.marker.generation)")
        let bytes = try PendingUploadQueue.readImmutablePayload(merged)
        let cache = try Data(contentsOf: setup.source.cacheURL)
        setup.diagnostics.recordObservation("journal-proof cacheMatches=\(bytes == cache) headMatches=\(DatabaseListStore.databases.first { $0.id == setup.reference.id }?.cloudSyncMetadata?.localHeadOperationID == merged.id)")
        XCTAssertEqual(bytes, cache)
        XCTAssertEqual(FileDigest.sha512(bytes), setup.vm.openTimeSHA512)
        XCTAssertTrue(try Self.entryTitles(in: bytes, password: fixturePassword).isSuperset(of: titles))
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
        XCTAssertNil(setup.vm.pendingUploadMergeFailure)
        return merged
    }

    func testMergePendingUploadsTransfersTheAutoFillChangeToDurableOwnerThenDelivers() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            phase = "setup.before"
            let setup = try await pendingMergeSetup(diagnostics: diagnostics)
            cleanupVM = setup.vm
            let opened = entryTitles(in: setup.vm)
            XCTAssertTrue(setup.vm.hasPendingUploadConflict)
            phase = "merge-pending.before"
            try await setup.vm.mergePendingUploads()
            phase = "merge-pending.after"
            phase = "journal-proof.before"
            let merged = try mergedJournal(setup, titles: opened.union(["AutoFill Entry"]))
            XCTAssertEqual(setup.remote.currentBytes, setup.base, "A local commit queues delivery; it is not an upload")
            XCTAssertNotNil(setup.vm.mergeSummaryMessage)
            phase = "deliver.before"
            guard case .saved? = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: setup.saver) else {
                return XCTFail("The durable merged owner must deliver")
            }
            XCTAssertTrue(try PendingUploadQueue.readJournal(for: setup.reference.id).isEmpty)
            XCTAssertEqual(try Self.entryTitles(in: setup.remote.currentBytes, password: fixturePassword),
                try Self.entryTitles(in: Data(contentsOf: setup.source.cacheURL), password: fixturePassword))
            XCTAssertEqual(setup.encryptions.value, 1)
            XCTAssertEqual(setup.replacements.value, 1)
            XCTAssertEqual(setup.keyEffects.value, 0)
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    func testPublishedLegacyPendingMergeCreatesNewBoundOwner() async throws {
        let setup = try await pendingMergeSetup(legacy: true)
        defer { setup.vm.lock() }
        let before = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
        XCTAssertNil(before.marker.journalVersion)
        XCTAssertNil(before.marker.binding)
        XCTAssertTrue(setup.vm.hasPendingUploadConflict)
        guard case .recovered(let payloads) = PendingUploadRecovery.lookUpPayloads(for: setup.reference) else {
            return XCTFail("The finalized legacy payload must be recoverable")
        }
        XCTAssertEqual(payloads.first?.data, setup.source.payload)
        let promoted = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
        XCTAssertNil(promoted.marker.binding)
        XCTAssertNil(promoted.marker.localCommitBaseline)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(promoted), setup.source.payload)
        _ = try setup.remote.store(mergeVariant(title: "Remote B"), expectedRev: nil)
        try await setup.vm.mergePendingUploads()
        let merged = try mergedJournal(setup, titles: ["AutoFill Entry", "Remote B"])
        XCTAssertNotNil(merged.marker.binding)
        XCTAssertNotEqual(merged.id, before.id)
        guard case .saved? = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: setup.saver) else {
            return XCTFail("The authenticated merge must deliver its new bound operation")
        }
        XCTAssertTrue(try Self.entryTitles(in: setup.remote.currentBytes, password: fixturePassword).isSuperset(of: ["AutoFill Entry", "Remote B"]))
    }

    func testMergePendingUploadsKeepsUnsavedEditsInTheUpload() async throws {
        let setup = try await pendingMergeSetup(sourceAfterUnlock: true)
        defer { setup.vm.lock() }
        var phase = "remote-change"
        do {
        _ = try setup.remote.store(mergeVariant(title: "Remote B"), expectedRev: nil)
        try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Unsaved Local Entry", password: "C")))
        phase = "merge"
        try await setup.vm.mergePendingUploads()
        let merged = try mergedJournal(setup, titles: ["AutoFill Entry", "Remote B", "Unsaved Local Entry"])
        XCTAssertEqual(merged.marker.binding?.baseline?.headOperationID, setup.source.stored.id)
        XCTAssertFalse(setup.vm.isDirty)
        XCTAssertEqual(merged.marker.remoteBaseSHA512, FileDigest.sha512(setup.remote.currentBytes))
        phase = "deliver-merged"
        guard case .saved? = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: setup.saver) else {
            return XCTFail("Z/A/B must deliver against B")
        }
        try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Next Explicit Save", password: "D")))
        phase = "save-next"
        try await setup.vm.save()
        let next = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
        phase = "deliver-next"
        guard case .saved? = try await CloudDatabaseSaver.deliver(next, reference: setup.vm.databaseReference, environment: setup.saver) else {
            return XCTFail("A subsequent explicit save must remain usable")
        }
        XCTAssertTrue(try Self.entryTitles(in: setup.remote.currentBytes, password: fixturePassword)
            .isSuperset(of: ["AutoFill Entry", "Remote B", "Unsaved Local Entry", "Next Explicit Save"]))
        XCTAssertEqual(setup.encryptions.value, 2)
        } catch {
            XCTFail(setup.diagnostics.failure(error, at: phase))
            throw error
        }
    }

    func testMergePendingUploadsWhenTheCloudCopyChangedAgainKeepsTheMarker() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            phase = "setup.before"
            let setup = try await pendingMergeSetup(diagnostics: diagnostics)
            cleanupVM = setup.vm
            phase = "merge-pending.before"
            try await setup.vm.mergePendingUploads()
            phase = "merge-pending.after"
            phase = "journal-proof.before"
            let merged = try mergedJournal(setup, titles: ["AutoFill Entry"])
            phase = "remote-change.before"
            _ = try setup.remote.store(mergeVariant(title: "Later Remote"), expectedRev: nil)
            phase = "deliver.before"
            guard case .conflict? = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: setup.saver) else {
                return XCTFail("Remote divergence must conflict without dispatch")
            }
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(merged), try Data(contentsOf: setup.source.cacheURL))
            XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
            XCTAssertFalse(try Self.entryTitles(in: setup.remote.currentBytes, password: fixturePassword).contains("AutoFill Entry"))
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    func testMergePendingUploadsThatHitANewerCloudCopySucceedsAfterSyncNow() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            phase = "setup.before"
            let setup = try await pendingMergeSetup(diagnostics: diagnostics)
            cleanupVM = setup.vm
            phase = "merge-pending.before"
            try await setup.vm.mergePendingUploads()
            phase = "merge-pending.after"
            phase = "journal-proof.before"
            let first = try mergedJournal(setup, titles: ["AutoFill Entry"])
            phase = "remote-change.before"
            _ = try setup.remote.store(mergeVariant(title: "Newer Cloud Entry"), expectedRev: nil)
            phase = "deliver.before"
            guard case .conflict? = try await CloudDatabaseSaver.deliver(first, reference: setup.vm.databaseReference, environment: setup.saver) else {
                return XCTFail("A new remote edit must be detected")
            }
            await setup.vm.syncCloudNow()
            XCTAssertEqual(setup.vm.saveConflict?.remoteData, setup.remote.currentBytes)
            phase = "merge-conflict.before"
            try await setup.vm.mergeAndSave()
            phase = "merge-conflict.after"
            phase = "journal-proof.before"
            let second = try mergedJournal(setup, titles: ["AutoFill Entry", "Newer Cloud Entry"])
            XCTAssertNotEqual(first.id, second.id)
            phase = "deliver.before"
            guard case .saved? = try await CloudDatabaseSaver.deliver(second, reference: setup.vm.databaseReference, environment: setup.saver) else {
                return XCTFail("Explicitly merging the newer remote must resolve the conflict")
            }
            XCTAssertTrue(try PendingUploadQueue.readJournal(for: setup.reference.id).isEmpty)
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    func testMergePendingUploadsWhoseUploadFailsKeepsTheMarker() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        try await setup.vm.mergePendingUploads()
        let merged = try mergedJournal(setup, titles: ["AutoFill Entry"])
        let transport = CloudJournalTransport(remote: setup.base, revision: "rev-A", uploadError: .networkUnavailable)
        let failing = setup.source.environment(transport: transport)
        do { _ = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: failing); XCTFail("Lost response must be reported") }
        catch { XCTAssertEqual(error as? CloudProviderError, .networkUnavailable) }
        let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
        XCTAssertEqual(retained.id, merged.id)
        XCTAssertNotNil(retained.marker.uploadAttemptID)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), try Data(contentsOf: setup.source.cacheURL))
        _ = try await CloudDatabaseSaver.deliver(retained, reference: setup.vm.databaseReference, environment: failing)
        XCTAssertEqual(transport.effects.uploads.count, 1, "An uncertain attempt cannot resend")
        XCTAssertEqual(setup.encryptions.value, 1)
        XCTAssertFalse(setup.vm.isSaving)
    }

    func testMergePendingUploadsWithTheChangeGoneFromTheDeviceWritesNothing() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        try FileManager.default.removeItem(at: setup.source.payloadURL)
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .changeUnavailable)
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
    }

    func testMergePendingUploadsWithAnUnprovenMarkerWritesNothingAndKeepsIt() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        var source = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
        source.marker.isPayloadFinalized = nil
        source.marker.journalVersion = nil
        _ = try PendingUploadQueue.update(source)
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .changeUnidentified)
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
        XCTAssertTrue(setup.vm.hasPendingUploadConflict)
        XCTAssertNil(setup.vm.mergeSummaryMessage)
    }

    func testMergePendingUploadsWithAnUnreadableChangeWritesNothing() async throws {
        let setup = try await pendingMergeSetup(payload: Data("not-a-kdbx-file".utf8), sourceAfterUnlock: true)
        defer { setup.vm.lock() }
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .changeUnreadable(.cache))
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
    }

    func testMergePendingUploadsWithDivergedAttachmentsWritesNothing() async throws {
        let setup = try await pendingMergeSetup(payload: mergeVariant(title: "Attachment Source", pool: [Data([0]) + Data("attachment".utf8)], attachment: true), sourceAfterUnlock: true)
        defer { setup.vm.lock() }
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .attachmentsDiverged(.cache))
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
    }

    func testMergePendingUploadsRefusesARemoteRefIntoAFileTheUnsavedEditAdded() async throws {
        let setup = try await pendingMergeSetup(payload: mergeVariant(title: "Dangling Attachment Source", attachment: true), sourceAfterUnlock: true)
        defer { setup.vm.lock() }
        XCTAssertEqual(setup.vm.binaryPool?.count, 0)
        let entry = try XCTUnwrap(setup.vm.currentRootGroup?.allEntries.first)
        try setup.vm.applyEntryEdit(.updateEntry(entryID: entry.id,
            draft: EntryDraftPayload(title: entry.title, password: "local",
                attachments: [.new(name: "local.txt", data: Data("local-bytes".utf8))])))
        let edits = try XCTUnwrap(setup.vm.draft).pendingEdits
        let localPool = try XCTUnwrap(setup.vm.draft?.binaryPoolFields)
        XCTAssertEqual(localPool.count, 1)
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .attachmentsDiverged(.cache))
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
        XCTAssertTrue(setup.vm.isDirty)
        XCTAssertEqual(setup.vm.draft?.pendingEdits, edits)
        XCTAssertEqual(setup.vm.draft?.binaryPoolFields, localPool)
    }

    func testAnOrdinarySaveRetainsTheConflictedSourceUntilExplicitOwnedMerge() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            phase = "setup.before"
            let setup = try await pendingMergeSetup(diagnostics: diagnostics)
            cleanupVM = setup.vm
            // A fresh read of A may save on A; it does not prove that an old conflict was reconciled.
            setup.vm.lock()
            await setup.vm.unlock(password: fixturePassword)
            try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Ordinary Edit", password: "local")))
            phase = "save.before"
            try await setup.vm.save()
            phase = "save.after"
            XCTAssertTrue(try PendingUploadQueue.readJournal(for: setup.reference.id).contains(where: { $0.id == setup.source.stored.id }))
            XCTAssertTrue(setup.vm.hasPendingUploadConflict)
            phase = "merge-pending.before"
            try await setup.vm.mergePendingUploads()
            phase = "merge-pending.after"
            phase = "journal-proof.before"
            _ = try mergedJournal(setup, titles: ["AutoFill Entry", "Ordinary Edit"])
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    func testPendingUploadConflictIsNotOfferedForAReadOnlyDatabase() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        setup.vm.setReadOnly(true)
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
        try await setup.vm.mergePendingUploads()
        XCTAssertEqual(setup.vm.pendingUploadMergeFailure, .sessionUnavailable)
        XCTAssertEqual(setup.encryptions.value, 0)
        XCTAssertEqual(setup.replacements.value, 0)
    }

    func testPendingUploadConflictAvailabilityTracksReadOnlyChanges() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        setup.vm.setReadOnly(true)
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
        setup.vm.setReadOnly(false)
        XCTAssertTrue(setup.vm.hasPendingUploadConflict)
        setup.vm.setReadOnly(true)
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
    }

    func testPendingUploadConflictIsNotReportedWithoutAConflict() async throws {
        let setup = try await pendingMergeSetup(conflicted: false)
        defer { setup.vm.lock() }
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
        XCTAssertTrue(CloudSyncControls.showsPendingUploadNote(for: setup.vm))
    }

    func testSyncStatusBannerLeavesAConflictedUploadToTheConflictBanner() async throws {
        let conflicted = try await pendingMergeSetup()
        defer { conflicted.vm.lock() }
        XCTAssertTrue(conflicted.vm.hasPendingCloudUploads)
        XCTAssertTrue(conflicted.vm.hasPendingUploadConflict)
        XCTAssertFalse(CloudSyncControls.showsPendingUploadNote(for: conflicted.vm))
        let waiting = try await pendingMergeSetup(conflicted: false)
        defer { waiting.vm.lock() }
        XCTAssertFalse(waiting.vm.hasPendingUploadConflict)
        XCTAssertTrue(CloudSyncControls.showsPendingUploadNote(for: waiting.vm))
    }

    func testLockingClearsThePendingUploadState() async throws {
        let setup = try await pendingMergeSetup(payload: Data("unreadable".utf8), sourceAfterUnlock: true)
        try await setup.vm.mergePendingUploads()
        XCTAssertNotNil(setup.vm.pendingUploadMergeFailure)
        setup.vm.lock()
        XCTAssertFalse(setup.vm.hasPendingUploadConflict)
        XCTAssertNil(setup.vm.pendingUploadMergeFailure)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 1)
    }

    func testReconciledBaselineEqualToCacheCannotBorrowHashFromOlderRemoteBytes() async throws {
        let oldX = try fixtureData()
        let oldHash = FileDigest.sha512(oldX).base64EncodedString()
        let cacheA = try mergeVariant(title: "Authenticated A")
        XCTAssertNotEqual(cacheA, oldX)
        for restoresX in [true, false] {
            let setup = try await pendingMergeSetup(payload: cacheA, recordedContentHash: oldHash)
            defer { setup.vm.lock() }
            _ = try setup.remote.store(cacheA, expectedRev: nil)
            try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Explicit Merge M", password: "M")))
            try await setup.vm.mergePendingUploads()
            let merged = try mergedJournal(setup, titles: ["Authenticated A", "Explicit Merge M"])
            XCTAssertEqual(merged.marker.remoteBaseSHA512, FileDigest.sha512(cacheA))
            XCTAssertEqual(merged.marker.predecessorSHA512, merged.marker.remoteBaseSHA512,
                "The reconciled remote snapshot equals the actual pending cache, which must not bind an old validator")
            XCTAssertNil(merged.marker.expectedRev)
            XCTAssertNil(merged.marker.baseRev)
            XCTAssertEqual(setup.vm.databaseReference.cloudSyncMetadata?.remoteContentHash, oldHash)
            let output = try PendingUploadQueue.readImmutablePayload(merged)
            if restoresX { _ = try setup.remote.store(oldX, expectedRev: nil) }
            let remoteBytes = setup.remote.currentBytes
            let remoteMetadata = setup.remote.currentMetadata
            let downloads = CloudJournalEffectCounter()
            let uploads = CloudJournalEffectCounter()
            var delivery = setup.saver
            delivery.getMetadata = { _ in
                CloudFileMetadata(modifiedDate: remoteMetadata.modifiedDate,
                    contentHash: FileDigest.sha512(remoteBytes).base64EncodedString(),
                    size: Int64(remoteBytes.count), rev: remoteMetadata.rev)
            }
            delivery.downloadRemoteData = { _ in downloads.record(); return remoteBytes }
            delivery.upload = { _, bytes, rev, _ in uploads.record(); return try setup.remote.store(bytes, expectedRev: rev) }
            let result = try await CloudDatabaseSaver.deliver(merged, reference: setup.vm.databaseReference, environment: delivery)
            XCTAssertEqual(downloads.value, 1, "Cleared validators require proof against the actual reconciled bytes")
            XCTAssertEqual(setup.encryptions.value, 1)
            XCTAssertEqual(setup.replacements.value, 1)
            XCTAssertEqual(try Data(contentsOf: setup.source.cacheURL), output)
            if restoresX {
                guard case .conflict? = result else { return XCTFail("The matching old hash must not authorize overwriting restored X") }
                XCTAssertEqual(uploads.value, 0)
                XCTAssertEqual(setup.remote.currentBytes, oldX)
                let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: setup.reference.id).first)
                XCTAssertEqual(retained.id, merged.id)
                XCTAssertNil(retained.marker.uploadAttemptID)
                XCTAssertNil(retained.marker.confirmedAt)
                XCTAssertTrue(retained.marker.isConflicted)
                XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), output)
            } else {
                guard case .saved? = result else { return XCTFail("An unchanged authenticated A still permits one delivery") }
                XCTAssertEqual(uploads.value, 1)
                XCTAssertEqual(setup.remote.currentBytes, output)
                XCTAssertTrue(try PendingUploadQueue.readJournal(for: setup.reference.id).isEmpty)
            }
        }
    }

    func testMergeNotificationDrainerCannotTakeLeaseBeforeOwnedHandoff() async throws {
        try await exerciseNotificationHandoff(externalContention: false)
    }

    func testExternalDrainerLeaseStillRetainsSourcesWithoutSecondCryptoOrResend() async throws {
        try await exerciseNotificationHandoff(externalContention: true)
    }

    private func exerciseNotificationHandoff(externalContention: Bool) async throws {
        let base = try fixtureData()
        let transport = CloudJournalTransport(remote: base, revision: "rev-A",
            metadataError: externalContention ? .networkUnavailable : nil)
        let leaseEntered = DispatchSemaphore(value: 0)
        let releaseLease = DispatchSemaphore(value: 0)
        let completed = XCTestExpectation(description: "real notification drain ended")
        let cleanupCompleted = XCTestExpectation(description: "real drain cleanup ended")
        let readCalls = CloudJournalEffectCounter()
        let notifications = CloudJournalEffectCounter()
        let trace = TestDatabaseSupport.LocalPublicationTrace()
        var delivery = CloudDatabaseSaver.Environment.live
        delivery.getMetadata = { _ in try transport.metadata(byteCount: base.count) }
        delivery.downloadRemoteData = { _ in transport.download(fallback: base) }
        delivery.upload = { _, bytes, rev, _ in try await transport.upload(bytes, revision: rev) }
        delivery.revisionIdentifiesContent = { _, _ in false }
        let read = delivery.queue.readData
        delivery.queue.readData = { url in
            readCalls.record()
            if readCalls.value == 1 {
                leaseEntered.signal()
                guard releaseLease.wait(timeout: .now() + 15) == .success else { throw WaitTimedOut() }
            }
            return try read(url)
        }
        let heldDelivery = delivery
        var draining = PendingUploadDrainer.Environment.live
        draining.beginBackgroundTask = { _ in .invalid }
        draining.endBackgroundTask = { _ in }
        draining.deliverMarker = { try await CloudDatabaseSaver.deliver($0, reference: $1, environment: heldDelivery) }
        let drainer = PendingUploadDrainer(environment: draining)
        let liveNotify = PendingUploadQueue.Environment.live.postDarwinNotification
        let notifyAndHold: @Sendable () -> Void = {
            liveNotify()
            notifications.record()
            XCTAssertEqual(leaseEntered.wait(timeout: .now() + 15), .success,
                "The real drainer must enter its queue read while holding the actual commit lease")
        }
        let beforeHandoff: @Sendable () async -> Void = {
            await Task.detached { notifyAndHold() }.value
        }
        let setup = try await pendingMergeSetup(diagnostics: trace, configureSaver: { environment in
            environment.queue.postDarwinNotification = externalContention ? liveNotify : notifyAndHold
        }, afterSaver: externalContention ? beforeHandoff : nil)
        defer { setup.vm.lock() }
        var drainStarted = false
        drainer.startObserving {
            guard !drainStarted,
                  PendingUploadQueue.listMarkers(for: setup.reference.id).contains(where: { $0.id != setup.source.stored.id }) else { return }
            drainStarted = true
            Task { @MainActor in
                _ = await drainer.drain(databaseId: setup.reference.id)
                completed.fulfill()
                cleanupCompleted.fulfill()
            }
        }
        defer { drainer.stopObserving() }
        var drainJoined = false
        do {
            if externalContention {
                do { try await setup.vm.mergePendingUploads(); XCTFail("External preclaim contention must remain recovery") }
                catch { XCTAssertTrue(error is SaveBookkeepingWarning, trace.failure(error, at: "expected-external-contention")) }
                XCTAssertTrue(trace.summary.contains("cloud-merge-consume.commit-entry"), trace.summary)
                XCTAssertTrue(trace.summary.contains("cloud-merge-consume.flock-errno"), trace.summary)
                let journal = try PendingUploadQueue.readJournal(for: setup.reference.id)
                XCTAssertEqual(journal.count, 2)
                XCTAssertTrue(journal.contains(where: { $0.id == setup.source.stored.id }))
                XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(setup.source.stored), setup.source.payload)
                let output = try XCTUnwrap(journal.first { $0.id != setup.source.stored.id })
                XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(output), try Data(contentsOf: setup.source.cacheURL))
            } else {
                try await setup.vm.mergePendingUploads()
                _ = try mergedJournal(setup, titles: ["AutoFill Entry"])
                XCTAssertFalse(PendingUploadQueue.listMarkers(for: setup.reference.id).contains { $0.id == setup.source.stored.id })
            }
            XCTAssertEqual(notifications.value, 1)
            XCTAssertEqual(setup.encryptions.value, 1)
            XCTAssertEqual(setup.replacements.value, 1)
            XCTAssertEqual(transport.effects.metadataCalls, 0, "Provider IO cannot run through the held lease")
            XCTAssertEqual(transport.effects.uploads.count, 0, "Provider dispatch cannot run through the held lease")
            releaseLease.signal()
            let joined = await XCTWaiter.fulfillment(of: [completed], timeout: 30)
            guard joined == .completed else { throw WaitTimedOut() }
            drainJoined = true
            XCTAssertEqual(setup.encryptions.value, 1)
            XCTAssertEqual(setup.replacements.value, 1)
            if externalContention {
                XCTAssertGreaterThan(transport.effects.metadataCalls, 0, "Retention must reach the scripted metadata failure after the lease releases")
                XCTAssertEqual(transport.effects.downloads, 0)
                XCTAssertEqual(transport.effects.uploads.count, 0)
                XCTAssertEqual(try PendingUploadQueue.readJournal(for: setup.reference.id).count, 2)
            } else {
                XCTAssertEqual(transport.effects.uploads.count, 1)
                XCTAssertEqual(transport.effects.uploads.first?.bytes, try Data(contentsOf: setup.source.cacheURL))
                XCTAssertTrue(try PendingUploadQueue.readJournal(for: setup.reference.id).isEmpty)
            }
        } catch {
            let diagnostic = trace.failure(error, at: "notification-handoff")
            setup.vm.lock()
            releaseLease.signal()
            if !drainJoined {
                let joined = await XCTWaiter.fulfillment(of: [cleanupCompleted], timeout: 30)
                guard joined == .completed else {
                    XCTFail(diagnostic + "; real drain did not join after all gates released")
                    fatalError("Unquiesced notification drain test cannot clear its store")
                }
            }
            XCTFail(diagnostic)
            throw error
        }
    }

    func testAuthenticatedMergeRejectsChangedSourcesTargetsAndReferenceBeforeEncryption() async throws {
        for fault in ["source-bytes", "new-source", "provisional", "unknown-schema", "missing-source", "same-inode-bytes", "new-inode", "factors", "epoch", "revoked"] {
            let setup = try await pendingMergeSetup(sourceAfterUnlock: true, beforeSave: { reference in
                let current = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
                var source = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
                let payload = try PendingUploadQueue.readImmutablePayload(source)
                let url = PendingUploadQueue.resolveAppGroupURL(for: try XCTUnwrap(source.marker.intendedPayloadPath))
                let cache = DatabaseListStore.cacheLocation(for: current)
                switch fault {
                case "source-bytes": try Data("foreign-ciphertext".utf8).write(to: url)
                case "missing-source": try FileManager.default.removeItem(at: url)
                case "new-source":
                    _ = try CloudJournalTestContext(reference: current, base: Data(contentsOf: cache), payload: payload)
                case "provisional":
                    _ = try CloudJournalTestContext(reference: current, base: Data(contentsOf: cache), payload: payload, install: false)
                case "unknown-schema": source.marker.journalVersion = 999; _ = try PendingUploadQueue.update(source)
                case "same-inode-bytes": try Data("foreign-cache".utf8).write(to: cache)
                case "new-inode": try payload.write(to: cache, options: .atomic)
                case "factors":
                    var changed = current
                    changed.keyFileFilename = "another-keyfile.keyx"
                    DatabaseListStore.testUpsert(changed)
                case "epoch":
                    var changed = current
                    changed.updateCloudSyncMetadata { $0.keyEpoch = UUID() }
                    DatabaseListStore.testUpsert(changed)
                case "revoked": CloudDatabaseSaver.mergeContext?.revoke()
                default: XCTFail("Unknown fault")
                }
            })
            try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Retained Draft", password: "draft")))
            let edits = try XCTUnwrap(setup.vm.draft).pendingEdits
            do { try await setup.vm.mergePendingUploads(); XCTFail("\(fault) must reject the captured merge") }
            catch { XCTAssertFalse(error is SaveDurabilityWarning, "\(fault) is a pre-effect authority rejection") }
            XCTAssertEqual(setup.encryptions.value, 0, fault)
            XCTAssertEqual(setup.replacements.value, 0, fault)
            XCTAssertEqual(setup.keyEffects.value, 0, fault)
            XCTAssertTrue(PendingUploadQueue.listMarkers(for: setup.reference.id).contains(where: { $0.id == setup.source.stored.id }), fault)
            XCTAssertEqual(setup.vm.draft?.pendingEdits, edits, fault)
            XCTAssertEqual(setup.remote.currentBytes, setup.base, fault)
            setup.vm.lock()
        }
    }

    func testAuthenticatedMergeRetainsNewSourceArrivingAfterInstalledOutput() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        let base = setup.base
        let reference = setup.reference
        let saver = setup.saver
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let session = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: base, compositeKey: key, sessionKey: session)
        let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session,
            binaryPoolFields: parsed.header.innerHeaderBinaryFields)
        let sources = try PendingUploadQueue.readJournal(for: reference.id)
        let remote = CloudSyncResolution(reference: reference, localURL: setup.source.cacheURL, data: base, status: .current)
        let authenticated = try await DatabaseViewModel.CloudMergeAuthentication.merging(reference: reference,
            sources: sources, remote: remote, draft: draft, compositeKey: key, sessionKey: session)
        let authentication = authenticated.1
        let mergedDraft = DatabaseDraft(rootGroup: authenticated.0.rootGroup, meta: authenticated.0.meta,
            sessionKey: session, binaryPoolFields: draft.binaryPoolFields)
        let context = try await Task.detached { try CloudDatabaseSaver.MergeContext.capture(authentication) }.value
        defer { context.finish() }
        let result = try await CloudDatabaseSaver.$mergeContext.withValue(context) {
            try await CloudDatabaseSaver.save(draft: mergedDraft, reference: reference, compositeKey: key,
                openTimeSHA512: FileDigest.sha512(base), reconciledRemoteSHA512: FileDigest.sha512(base),
                expectedRev: reference.expectedCloudRevision, kdfPolicy: .mainApp, environment: saver)
        }
        guard case .saved(let sha, _, _) = result else { return XCTFail("Real durable output is required") }
        let current = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        let installed = try Data(contentsOf: setup.source.cacheURL)
        let later = try CloudJournalTestContext(reference: current, base: installed, payload: installed)
        do { try await Task.detached { try context.consume(sha512: sha) }.value; XCTFail("New ownership must prevent consumption") }
        catch { XCTAssertEqual(error as? SaveError, .saveContextUnavailable) }
        let journal = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(journal.count, 3)
        XCTAssertTrue(journal.contains(where: { $0.id == setup.source.stored.id }))
        XCTAssertTrue(journal.contains(where: { $0.id == later.stored.id }))
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(later.stored), installed)
        XCTAssertEqual(setup.encryptions.value, 1)
        XCTAssertEqual(setup.replacements.value, 1)
    }

    func testAuthenticatedMergeRejectsForeignReferenceAndSecondInvocation() async throws {
        let setup = try await pendingMergeSetup()
        defer { setup.vm.lock() }
        let reference = setup.vm.databaseReference
        let base = setup.base
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let session = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: base, compositeKey: key, sessionKey: session)
        let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session,
            binaryPoolFields: parsed.header.innerHeaderBinaryFields)
        let sources = try PendingUploadQueue.readJournal(for: reference.id)
        let remote = CloudSyncResolution(reference: reference, localURL: setup.source.cacheURL, data: base, status: .current)
        let authenticated = try await DatabaseViewModel.CloudMergeAuthentication.merging(reference: reference,
            sources: sources, remote: remote, draft: draft, compositeKey: key, sessionKey: session)
        let authentication = authenticated.1
        let mergedDraft = DatabaseDraft(rootGroup: authenticated.0.rootGroup, meta: authenticated.0.meta,
            sessionKey: session, binaryPoolFields: draft.binaryPoolFields)
        let context = try await Task.detached { try CloudDatabaseSaver.MergeContext.capture(authentication) }.value
        defer { context.finish() }
        let foreign = try makeStoredManualReference(fileID: "/foreign-merge.kdbx", autoFillEnabled: false)
        do {
            _ = try await CloudDatabaseSaver.$mergeContext.withValue(context) {
                try await CloudDatabaseSaver.save(draft: mergedDraft, reference: foreign, compositeKey: key,
                    openTimeSHA512: FileDigest.sha512(base), reconciledRemoteSHA512: FileDigest.sha512(base),
                    expectedRev: nil, kdfPolicy: .mainApp, environment: setup.saver)
            }
            XCTFail("A foreign reference cannot claim the context")
        } catch { XCTAssertEqual(error as? SaveError, .saveContextUnavailable) }
        XCTAssertEqual(setup.encryptions.value, 0)
        let result = try await CloudDatabaseSaver.$mergeContext.withValue(context) {
            try await CloudDatabaseSaver.save(draft: mergedDraft, reference: reference, compositeKey: key,
                openTimeSHA512: FileDigest.sha512(base), reconciledRemoteSHA512: FileDigest.sha512(base),
                expectedRev: nil, kdfPolicy: .mainApp, environment: setup.saver)
        }
        guard case .saved = result else { return XCTFail("One exact invocation may commit") }
        do {
            _ = try await CloudDatabaseSaver.$mergeContext.withValue(context) {
                try await CloudDatabaseSaver.save(draft: mergedDraft, reference: reference, compositeKey: key,
                    openTimeSHA512: FileDigest.sha512(base), reconciledRemoteSHA512: FileDigest.sha512(base),
                    expectedRev: nil, kdfPolicy: .mainApp, environment: setup.saver)
            }
            XCTFail("The context is single use")
        } catch { XCTAssertEqual(error as? SaveError, .saveContextUnavailable) }
        XCTAssertEqual(setup.encryptions.value, 1)
        XCTAssertEqual(setup.replacements.value, 1)
    }

    func testUnconfirmedMergeOutputRetainsSourcesAndDoesNotAuthorizeConsumption() async throws {
        let setup = try await pendingMergeSetup(failFinalization: true)
        defer { setup.vm.lock() }
        try setup.vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(setup.vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Known Queued Draft", password: "local")))
        do { try await setup.vm.mergePendingUploads(); XCTFail("Post-replace publication failure must be terminal recovery") }
        catch { XCTAssertTrue(error is CloudSaveRecoveryWarning) }
        let journal = try PendingUploadQueue.readJournal(for: setup.reference.id)
        XCTAssertEqual(journal.count, 2)
        XCTAssertTrue(journal.contains(where: { $0.id == setup.source.stored.id }))
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(setup.source.stored), setup.source.payload)
        let installed = try Data(contentsOf: setup.source.cacheURL)
        XCTAssertEqual(setup.vm.openTimeSHA512, FileDigest.sha512(installed))
        XCTAssertTrue(try Self.entryTitles(in: installed, password: fixturePassword).contains("Known Queued Draft"))
        XCTAssertFalse(setup.vm.isDirty)
        XCTAssertEqual(setup.encryptions.value, 1)
        XCTAssertEqual(setup.replacements.value, 1)
        XCTAssertEqual(setup.keyEffects.value, 0)
        XCTAssertEqual(setup.remote.currentBytes, setup.base)
    }

    func testCapturedMergeCannotWriteAfterAnotherWindowSettlesThenRekeysOrRemoves() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            for remove in [false, true] {
                phase = "setup.before"
                let setup = try await pendingMergeSetup(diagnostics: diagnostics)
                cleanupVM = setup.vm
                let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
                let session = SymmetricKey(size: .bits256)
                phase = "reparse.before"
                let parsed = try KDBXParser.parseWithMetaAndHeader(data: setup.base, compositeKey: key, sessionKey: session)
                let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session,
                    binaryPoolFields: parsed.header.innerHeaderBinaryFields)
                let before = setup.vm.databaseReference
                let sources = try PendingUploadQueue.readJournal(for: before.id)
                let remote = CloudSyncResolution(reference: before, localURL: setup.source.cacheURL, data: setup.base, status: .current)
                let authenticated = try await DatabaseViewModel.CloudMergeAuthentication.merging(reference: before,
                    sources: sources, remote: remote, draft: draft, compositeKey: key, sessionKey: session)
                phase = "capture-context.before"
                let old = try await Task.detached { try CloudDatabaseSaver.MergeContext.capture(authenticated.1) }.value
                defer { old.finish() }
                let mergedDraft = DatabaseDraft(rootGroup: authenticated.0.rootGroup, meta: authenticated.0.meta,
                    sessionKey: session, binaryPoolFields: draft.binaryPoolFields)
                // A different invocation settles A before the captured invocation resumes.
                phase = "merge-pending.before"
                try await setup.vm.mergePendingUploads()
                phase = "merge-pending.after"
                phase = "journal-proof.before"
                let owner = try mergedJournal(setup, titles: ["AutoFill Entry"])
                phase = "deliver.before"
                guard case .saved? = try await CloudDatabaseSaver.deliver(owner, reference: setup.vm.databaseReference, environment: setup.saver) else {
                    return XCTFail("Settlement must precede rekey/removal")
                }
                let current = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == before.id }))
                let expected: Data?
                if remove {
                    XCTAssertTrue(DatabaseListStore.remove(id: before.id))
                    expected = nil
                } else {
                    let bytes = try Data(contentsOf: setup.source.cacheURL)
                    phase = "reparse.before"
                    let opened = try KDBXParser.parseWithMetaAndHeader(data: bytes, compositeKey: key, sessionKey: session)
                    let clean = DatabaseDraft(rootGroup: opened.rootGroup, meta: opened.meta, sessionKey: session,
                        binaryPoolFields: opened.header.innerHeaderBinaryFields)
                    let nextKey = try KDBXCrypto.compositeKey(password: "epoch B", keyFileData: nil)
                    phase = "saver-or-rekey.before"
                    let result = try await CloudDatabaseSaver.save(draft: clean, reference: current, compositeKey: key,
                        openTimeSHA512: FileDigest.sha512(bytes), expectedRev: current.expectedCloudRevision, kdfPolicy: .mainApp, newCompositeKey: nextKey,
                        keyChange: .init(keyFileBookmarkData: nil, keyFileFilename: nil), environment: setup.saver)
                    guard case .saved = result else { return XCTFail("B must actually commit") }
                    expected = try Data(contentsOf: setup.source.cacheURL)
                    phase = "reparse.before"
                    _ = try KDBXParser.parseWithMeta(data: XCTUnwrap(expected), password: "epoch B", sessionKey: SymmetricKey(size: .bits256))
                    XCTAssertNotEqual(DatabaseListStore.databases.first(where: { $0.id == before.id })?.cloudSyncMetadata?.keyEpoch,
                        before.cloudSyncMetadata?.keyEpoch)
                }
                let encryptionCount = setup.encryptions.value
                let replacementCount = setup.replacements.value
                do {
                    _ = try await CloudDatabaseSaver.$mergeContext.withValue(old) {
                        phase = "saver-or-rekey.before"
                        try await CloudDatabaseSaver.save(draft: mergedDraft, reference: before, compositeKey: key,
                            openTimeSHA512: FileDigest.sha512(setup.base), reconciledRemoteSHA512: FileDigest.sha512(setup.base),
                            expectedRev: nil, kdfPolicy: .mainApp, environment: setup.saver)
                    }
                    XCTFail("Stale captured ownership cannot authorize a write")
                } catch { XCTAssertFalse(error is CloudSaveRecoveryWarning) }
                XCTAssertEqual(setup.encryptions.value, encryptionCount)
                XCTAssertEqual(setup.replacements.value, replacementCount)
                XCTAssertEqual(setup.keyEffects.value, 0)
                XCTAssertEqual(try? Data(contentsOf: setup.source.cacheURL), expected)
                XCTAssertTrue(try PendingUploadQueue.readJournal(for: before.id).isEmpty)
                if remove { XCTAssertFalse(DatabaseListStore.databases.contains(where: { $0.id == before.id })) }
                setup.vm.lock()
            }
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    func testLockAndCancellationBeforeMergeSaverKeepSourcesAndPreventLateEffects() async throws {
        for cancel in [false, true] {
            let gate = SaveGate()
            let entered = XCTestExpectation(description: "actual merge saver entry")
            let completed = XCTestExpectation(description: "whole merge task completed")
            let setup = try await pendingMergeSetup(sourceAfterUnlock: true, beforeSave: { _ in
                entered.fulfill()
                await gate.waitUntilOpen()
            })
            let loading = Task { @MainActor in
                defer { completed.fulfill() }
                do { try await setup.vm.mergePendingUploads() }
                catch { XCTAssertTrue(error is CancellationError || error is SaveError) }
            }
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 60)
            if cancel { loading.cancel() } else { setup.vm.lock() }
            await gate.open()
            let joined = await XCTWaiter.fulfillment(of: [completed], timeout: 30)
            guard joined == .completed else {
                XCTFail("Merge task did not quiesce after all gates were released")
                // A live worker must never reach teardown of its shared store.
                fatalError("Unquiesced authenticated-merge test task")
            }
            await loading.value
            XCTAssertEqual(entry, .completed)
            XCTAssertEqual(setup.encryptions.value, 0)
            XCTAssertEqual(setup.replacements.value, 0)
            XCTAssertEqual(setup.keyEffects.value, 0)
            XCTAssertEqual(setup.vm.state, cancel ? .unlocked : .locked)
            if cancel { XCTAssertNotNil(setup.vm.compositeKey) } else { XCTAssertNil(setup.vm.compositeKey) }
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(setup.source.stored), setup.source.payload)
            setup.vm.lock()
        }
    }

    func testOrdinaryConflictReadsRemoteWithoutOverwritingPendingCacheThenExplicitMergeDeliversAndSavesAgain() async throws {
        let diagnostics = TestDatabaseSupport.LocalPublicationTrace()
        var phase = "setup.before"
        var cleanupVM: DatabaseViewModel?
        defer { cleanupVM?.lock() }
        do {
            let base = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
            let reference = try makeStoredManualReference(fileID: "/ordinary-merge.kdbx", autoFillEnabled: false)
            try DatabaseListStore.cacheDatabaseCopy(base, for: reference)
            let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
            let remoteSession = SymmetricKey(size: .bits256)
            phase = "reparse.before"
            let parsed = try KDBXParser.parseWithMetaAndHeader(data: base, compositeKey: key, sessionKey: remoteSession)
            let remoteDraft = try DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta,
                sessionKey: remoteSession, binaryPoolFields: parsed.header.innerHeaderBinaryFields).apply(
                    .createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup),
                        draft: EntryDraftPayload(title: "Remote B", password: "B")))
            let remoteB = try CloudDatabaseSaver.Environment.live.encryptDraft(remoteDraft, key, parsed.header, .mainApp).data
            let remote = InMemoryRemoteProvider(bytes: base, rev: "rev-A")
            let encryptions = CloudJournalEffectCounter()
            let uploads = CloudJournalEffectCounter()
            let keyEffects = CloudJournalEffectCounter()
            var environment = CloudDatabaseSaver.Environment.live
            environment.beginBackgroundTask = { _ in .invalid }
            environment.endBackgroundTask = { _ in }
            let encrypt = environment.encryptDraft
            environment.encryptDraft = { draft, key, header, policy in
                encryptions.record(); diagnostics.recordObservation("encrypt count=\(encryptions.value)")
                return try encrypt(draft, key, header, policy)
            }
            environment.getMetadata = { _ in remote.currentMetadata }
            environment.downloadRemoteData = { _ in remote.currentBytes }
            phase = "remote-change.before"
            environment.upload = { _, data, rev, _ in
                uploads.record(); diagnostics.recordObservation("upload count=\(uploads.value)")
                return try remote.store(data, expectedRev: rev)
            }
            environment.queue.observedCommitLockFailure = { code in
                diagnostics.recordObservation("commit-flock actualErrno=\(code)")
            }
            environment.revisionIdentifiesContent = { _, _ in false }
            let saver = environment
            let vm = DatabaseViewModel(databaseReference: reference,
                cloudSyncOperation: { reference, _ in
                    try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in remote })
                }, cloudRefreshOperation: { reference, _ in
                    try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, honorsManualSyncPolicy: false,
                        providerResolver: { _ in remote })
                }, localPublicationFailure: { diagnostics.record($0, $1) },
            cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
                    diagnostics.recordObservation("saver.enter")
                let result = try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                        openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev, kdfPolicy: .mainApp,
                        newCompositeKey: newKey, encryptionSettings: settings, environment: saver)
                diagnostics.recordObservation("saver.return")
                return result
                }, reloadOperation: { reference, key in
                    try await DatabaseViewModel.reloadDatabase(reference: reference, compositeKey: key, providerResolver: { _ in remote })
                }, quickUnlockKeyPersistOperation: { _, _, _ in false },
                expressUnlockKeySaveOperation: { _, _ in keyEffects.record() })
            await vm.unlock(password: fixturePassword)
            cleanupVM = vm
            try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Local A", password: "A")))
            phase = "save.before"
            try await vm.save()
            phase = "save.after"
            let source = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            let localA = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
            phase = "remote-change.before"
            _ = try remote.store(remoteB, expectedRev: nil)
            phase = "deliver.before"
            guard case .conflict? = try await CloudDatabaseSaver.deliver(source, reference: reference, environment: saver) else {
                return XCTFail("Remote B must conflict before any upload of local A")
            }
            XCTAssertEqual(uploads.value, 0)
            await vm.syncCloudNow()
            XCTAssertEqual(vm.saveConflict?.remoteData, remoteB)
            XCTAssertTrue(entryTitles(in: vm).contains("Local A"))
            XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), localA)
            let captured = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(captured), localA)
            try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Draft C", password: "C")))
            do { try await vm.reloadDiscardingDraft(); XCTFail("Reload cannot overwrite unresolved pending ciphertext") }
            catch { XCTAssertTrue(error is CloudPendingMergeRequired) }
            XCTAssertTrue(vm.isDirty)
            XCTAssertTrue(vm.currentRootGroup?.allEntries.contains { $0.title == "Draft C" } == true)
            XCTAssertEqual(vm.saveConflict?.remoteData, remoteB)
            phase = "merge-conflict.before"
            try await vm.mergeAndSave()
            phase = "merge-conflict.after"
            XCTAssertNil(vm.saveConflict)
            let merged = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertNotEqual(merged.id, source.id)
            XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).count, 1)
            XCTAssertEqual(merged.marker.remoteBaseSHA512, FileDigest.sha512(remoteB))
            XCTAssertNil(merged.marker.expectedRev)
            phase = "deliver.before"
            guard case .saved? = try await CloudDatabaseSaver.deliver(merged, reference: vm.databaseReference, environment: saver) else {
                return XCTFail("The exact explicitly reconciled remote baseline must deliver once")
            }
            phase = "reparse.before"
            let reopened = try KDBXParser.parseWithMeta(data: remote.currentBytes, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
            let titles = Set(reopened.rootGroup.allEntries.map(\.title))
            XCTAssertTrue(titles.isSuperset(of: ["Local A", "Remote B", "Draft C"]))
            XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
            XCTAssertEqual(uploads.value, 1)
            XCTAssertEqual(encryptions.value, 2)
            try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
                draft: EntryDraftPayload(title: "Next D", password: "D")))
            phase = "save.before"
            try await vm.save()
            phase = "save.after"
            phase = "reparse.before"
            let final = try KDBXParser.parseWithMeta(data: Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
                password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
            XCTAssertTrue(Set(final.rootGroup.allEntries.map(\.title)).isSuperset(of: ["Local A", "Remote B", "Draft C", "Next D"]))
            XCTAssertFalse(vm.isDirty)
            XCTAssertEqual(encryptions.value, 3)
            XCTAssertEqual(uploads.value, 1)
            XCTAssertEqual(keyEffects.value, 0)
        } catch {
            diagnostics.recordObservation("errorType=\(String(reflecting: type(of: error)))")
            let diagnostic = diagnostics.failure(error, at: phase)
            XCTFail(diagnostic)
            throw error
        }
    }

    private func joinCloudRefresh(_ worker: Task<Void, Never>, vm: DatabaseViewModel) async throws {
        let completed = XCTestExpectation(description: "foreground worker completed")
        let cleanupCompleted = XCTestExpectation(description: "foreground worker completed after cleanup")
        let joining = Task { await worker.value; completed.fulfill(); cleanupCompleted.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 30)
        if result != .completed {
            vm.lock()
            worker.cancel()
            let cleanup = await XCTWaiter.fulfillment(of: [cleanupCompleted], timeout: 30)
            guard cleanup == .completed else {
                XCTFail("Foreground metadata worker did not terminate after cancellation")
                // An unquiesced worker must not outlive teardown of its shared test store.
                fatalError("Unquiesced foreground metadata regression worker")
            }
            await joining.value
            throw WaitTimedOut()
        }
        await joining.value
    }

    func testPublishedCloudReadMetadataDoesNotImportConcurrentReferenceFields() async throws {
        let bytes = try fixtureData()
        let reference = try makeStoredManualReference(fileID: "/metadata-only.kdbx", autoFillEnabled: false)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let remote = InMemoryRemoteProvider(bytes: bytes, rev: "rev-A")
        let effects = CloudJournalEffectCounter()
        let vm = DatabaseViewModel(databaseReference: reference, cloudSyncOperation: { ref, _ in
            try await CloudSyncCoordinator.syncIfNeededForOpen(reference: ref, providerResolver: { _ in remote })
        }, cloudRefreshOperation: { ref, _ in
            let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: ref,
                honorsManualSyncPolicy: false, providerResolver: { _ in remote })
            var current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == ref.id })
            current.nickname = "Concurrent window nickname"
            DatabaseListStore.testUpsert(current)
            return resolution
        }, quickUnlockKeyPersistOperation: { _, _, _ in effects.record(); return false })
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        let historical = vm.databaseReference
        let beforeEffects = effects.value
        _ = try remote.store(bytes, expectedRev: "rev-A")
        await vm.syncCloudNow()
        let current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertEqual(vm.databaseReference.cloudSyncMetadata, current.cloudSyncMetadata)
        XCTAssertEqual(current.cloudSyncMetadata?.remoteRev, remote.currentMetadata.rev)
        XCTAssertEqual(current.nickname, "Concurrent window nickname")
        XCTAssertEqual(vm.databaseReference.nickname, historical.nickname)
        XCTAssertEqual(vm.databaseReference.keyFileBookmarkData, historical.keyFileBookmarkData)
        XCTAssertEqual(vm.databaseReference.lastMasterKeyChangeAt, historical.lastMasterKeyChangeAt)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(bytes))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertEqual(effects.value, beforeEffects)
        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
    }

    func testCloudMetadataWriteFailureLeavesSyncAndForegroundHistoricalAndCacheReadable() async throws {
        let bytes = try fixtureData()
        var reference = try makeStoredManualReference(fileID: "/metadata-write-failure.kdbx", autoFillEnabled: false)
        reference.cloudSyncPolicy = .onOpen
        DatabaseListStore.testUpsert(reference)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let effects = CloudJournalEffectCounter()
        let writePhases = CloudJournalEffectCounter()
        let failWrites = CloudJournalEffectCounter()
        var io = DurableFileWriteIO()
        let synchronize = io.synchronizeFile
        io.synchronizeFile = { descriptor in
            try synchronize(descriptor)
            if failWrites.value > 0 {
                writePhases.record()
                throw POSIXError(.EIO)
            }
        }
        let resolve: DatabaseViewModel.CloudSyncOperation = { ref, _ in
            var learned = ref
            if failWrites.value > 0 { learned.updateCloudSyncMetadata { $0.remoteRev = "changed-revision" } }
            return CloudSyncResolution(reference: learned, localURL: DatabaseListStore.cacheLocation(for: ref), data: bytes, status: .current)
        }
        let vm = DatabaseViewModel(databaseReference: reference, cloudMetadataWriteIO: io, cloudSyncOperation: resolve,
            cloudRefreshOperation: resolve, quickUnlockKeyPersistOperation: { _, _, _ in effects.record(); return false })
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.state, .unlocked)
        let historical = vm.databaseReference
        let initialEffects = effects.value
        let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let registryBytes = try Data(contentsOf: registry)
        failWrites.record()
        await vm.syncCloudNow()
        XCTAssertEqual(vm.databaseReference, historical)
        XCTAssertEqual(writePhases.value, 1, "Sync Now reached fsynced registry staging before the injected failure")
        let worker = try XCTUnwrap(vm.refreshSharedDatabaseCacheIfPossible())
        try await joinCloudRefresh(worker, vm: vm)
        XCTAssertEqual(vm.databaseReference, historical)
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(bytes))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        XCTAssertEqual(writePhases.value, 2, "Foreground reached the same durable write boundary")
        XCTAssertEqual(try Data(contentsOf: registry), registryBytes)
        XCTAssertEqual(effects.value, initialEffects)
    }

    func testOldCloudOpenResolutionCannotOverwriteAConfirmedRekeyOrResurrectRemoval() async throws {
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        for removeAfterRekey in [false, true] {
            var reference = try makeStoredManualReference(fileID: "/late-open-\(removeAfterRekey).kdbx", autoFillEnabled: false)
            reference.cloudSyncPolicy = .onOpen
            reference.legacyKeychainFilename = "old-open-\(UUID().uuidString).kdbx"
            DatabaseListStore.testUpsert(reference)
            let capturedReference = reference
            try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
            let entered = XCTestExpectation(description: "Old resolution captured")
            let completed = XCTestExpectation(description: "Old unlock fully returned")
            let release = AsyncStream<Void>.makeStream()
            let effects = CloudJournalEffectCounter()
            let vm = DatabaseViewModel(databaseReference: reference, cloudSyncOperation: { reference, _ in
                let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in nil })
                entered.fulfill()
                for await _ in release.stream { break }
                return resolution
            }, cloudRefreshOperation: { ref, _ in
                try await CloudSyncCoordinator.syncIfNeededForOpen(reference: ref, honorsManualSyncPolicy: false,
                    providerResolver: { _ in nil })
            }, quickUnlockKeyPersistOperation: { _, _, _ in effects.record(); return true })
            let opening = Task { await vm.unlock(password: KDBXTestFixture.test.password); completed.fulfill() }
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 30)
            var openingJoined = false
            do {
                guard entry == .completed else { XCTFail("Old open never reached its captured resolution"); throw WaitTimedOut() }
                let session = SymmetricKey(size: .bits256)
                let parsed = try KDBXParser.parseWithMeta(data: bytes, password: fixturePassword, sessionKey: session)
                let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session)
                let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let keyFileBytes = Data(repeating: 0x42, count: 32)
                try keyFileBytes.write(to: keyFile)
                defer { try? FileManager.default.removeItem(at: keyFile) }
                let bookmark = try SecurityScopedBookmarkManager.makeBookmarkData(for: keyFile, readOnly: true)
                let change = PendingUploadQueue.KeyChange(keyFileBookmarkData: bookmark, keyFileFilename: "B.key")
                let newKey = try KDBXCrypto.compositeKey(password: "confirmed-B", keyFileData: keyFileBytes)
                let transport = CloudJournalTransport(remote: bytes, revision: "rev-A")
                var environment = CloudDatabaseSaver.Environment.live
                environment.beginBackgroundTask = { _ in .invalid }
                environment.endBackgroundTask = { _ in }
                environment.getMetadata = { _ in try transport.metadata(byteCount: bytes.count) }
                environment.downloadRemoteData = { _ in bytes }
                environment.upload = { _, bytes, rev, _ in try await transport.upload(bytes, revision: rev) }
                let saver = environment
                let result = try await CloudDatabaseSaver.$keyChange.withValue(change) {
                    try await CloudDatabaseSaver.save(draft: draft, reference: reference,
                        compositeKey: KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self)),
                        openTimeSHA512: FileDigest.sha512(bytes), expectedRev: "rev-A", kdfPolicy: .mainApp,
                        newCompositeKey: newKey, environment: saver)
                }
                guard case .saved = result else { throw SaveError.saveContextUnavailable }
                let committed = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
                XCTAssertEqual(committed.cloudSyncMetadata?.keyEpoch, change.epoch)
                XCTAssertEqual(committed.keyFileBookmarkData, bookmark)
                XCTAssertNotNil(committed.lastMasterKeyChangeAt)
                XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
                let installedB = try Data(contentsOf: DatabaseListStore.cacheLocation(for: committed))
                _ = try KDBXParser.parse(data: installedB, compositeKey: newKey, sessionKey: SymmetricKey(size: .bits256))
                if removeAfterRekey { XCTAssertTrue(DatabaseListStore.remove(id: reference.id)) }
                else {
                    // Supported restoration after full settlement does not carry an old invocation's authority forward.
                    try DatabaseListStore.cacheDatabaseCopy(bytes, for: committed)
                    XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: committed)), bytes)
                }
                release.continuation.finish()
                let joined = await XCTWaiter.fulfillment(of: [completed], timeout: 30)
                if joined != .completed {
                    XCTFail("Old cloud unlock did not complete after its only gate was released")
                    fatalError("Old cloud unlock failed to join after releasing its only test gate")
                }
                openingJoined = true
                await opening.value
                if removeAfterRekey { XCTAssertNil(DatabaseListStore.databases.first { $0.id == reference.id }) }
                else { XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }, committed) }
                XCTAssertEqual(effects.value, 0)
                XCTAssertEqual(vm.databaseReference.cloudSyncMetadata?.keyEpoch, capturedReference.cloudSyncMetadata?.keyEpoch)
                XCTAssertEqual(vm.databaseReference.keyFileBookmarkData, capturedReference.keyFileBookmarkData)
                XCTAssertEqual(vm.databaseReference.lastMasterKeyChangeAt, capturedReference.lastMasterKeyChangeAt)
                if !removeAfterRekey {
                    XCTAssertEqual(vm.state, .unlocked, "The historically authenticated ciphertext may remain readable")
                    XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(bytes))
                    XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }?.legacyKeychainFilename,
                        committed.legacyKeychainFilename, "Rejected publication must not run legacy registry cleanup")
                    let historical = vm.databaseReference
                    await vm.syncCloudNow()
                    XCTAssertEqual(vm.databaseReference, historical, "Offline Sync Now cannot import the fallback's B tuple")
                    XCTAssertEqual(effects.value, 0)
                    XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }, committed)
                    let foreground = try XCTUnwrap(vm.refreshSharedDatabaseCacheIfPossible())
                    try await joinCloudRefresh(foreground, vm: vm)
                    XCTAssertEqual(vm.databaseReference, historical, "Automatic foreground fallback cannot import B authority")
                    XCTAssertEqual(effects.value, 0)
                    XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: committed)), bytes)
                    XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }, committed)
                    let freshEffects = CloudJournalEffectCounter()
                    let fresh = DatabaseViewModel(databaseReference: committed, cloudSyncOperation: { ref, _ in
                        try await CloudSyncCoordinator.syncIfNeededForOpen(reference: ref, providerResolver: { _ in nil })
                    }, quickUnlockKeyPersistOperation: { _, ref, _ in
                        XCTAssertEqual(ref.cloudSyncMetadata?.keyEpoch, change.epoch)
                        freshEffects.record()
                        return true
                    })
                    defer { fresh.lock() }
                    await fresh.unlock(password: fixturePassword)
                    XCTAssertEqual(fresh.state, .unlocked, "A new authenticated restore keeps main semantics after full settlement")
                    XCTAssertEqual(fresh.openTimeSHA512, FileDigest.sha512(bytes))
                    XCTAssertEqual(freshEffects.value, 1, "No permanent rollback pin is introduced")
                    let afterFresh = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
                    var expectedMetadata = committed.cloudSyncMetadata
                    expectedMetadata?.lastSyncIssue = .notAuthenticated
                    XCTAssertEqual(afterFresh.cloudSyncMetadata, expectedMetadata)
                    XCTAssertEqual(afterFresh.lastMasterKeyChangeAt, committed.lastMasterKeyChangeAt)
                    XCTAssertEqual(afterFresh.keyFileBookmarkData, committed.keyFileBookmarkData)
                    XCTAssertNil(afterFresh.legacyKeychainFilename, "Only the fresh admitted publication may clear legacy metadata")
                } else {
                    let historical = vm.databaseReference
                    await vm.syncCloudNow()
                    let foreground = try XCTUnwrap(vm.refreshSharedDatabaseCacheIfPossible())
                    try await joinCloudRefresh(foreground, vm: vm)
                    XCTAssertEqual(vm.databaseReference, historical)
                    XCTAssertNil(DatabaseListStore.databases.first { $0.id == reference.id })
                    XCTAssertFalse(FileManager.default.fileExists(atPath: DatabaseListStore.cacheLocation(for: reference).path))
                    XCTAssertEqual(effects.value, 0)
                }
                vm.lock()
            } catch {
                vm.lock()
                opening.cancel()
                release.continuation.finish()
                if !openingJoined {
                    let joined = await XCTWaiter.fulfillment(of: [completed], timeout: 30)
                    if joined != .completed {
                        XCTFail("Cloud open cleanup did not join the complete task after cancellation and gate release")
                        fatalError("Cloud open regression cannot clear stores beneath an unquiesced worker")
                    }
                }
                await opening.value
                vm.lock()
                throw error
            }
        }
    }

    func testRecoveredRekeyAllowsFreshUnlockAndOrdinarySaveWithPriorOwnerEpoch() async throws {
        let base = try fixtureData()
        let reference = try makeStoredManualReference(fileID: "/rekey-reopen-\(UUID().uuidString).kdbx", autoFillEnabled: false)
        try DatabaseListStore.cacheDatabaseCopy(base, for: reference)
        _ = try PendingLocalSaveStore.prepareSource(base, for: reference.id,
            masterKeyChangedAt: reference.lastMasterKeyChangeAt, baseCacheSHA512: FileDigest.sha512(base))
        XCTAssertEqual(try PendingLocalSaveStore.discard(PendingLocalSaveStore.recovery(for: reference.id)), .resolved)
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let session = SymmetricKey(size: .bits256)
        let opened = try KDBXParser.parseWithMeta(data: base, compositeKey: key, sessionKey: session)
        let draft = DatabaseDraft(rootGroup: opened.rootGroup, meta: opened.meta, sessionKey: session)
        let newPassword = "new-cloud-rekey-password"
        let newKey = try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil)
        let remote = InMemoryRemoteProvider(bytes: base, rev: "rev-A")
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = { _ in remote.currentMetadata }
        environment.downloadRemoteData = { _ in remote.currentBytes }
        environment.upload = { _, bytes, rev, _ in try remote.store(bytes, expectedRev: rev) }
        environment.revisionIdentifiesContent = { _, _ in false }
        environment.writeGuarantee = { _, _, _ in .preflightOnly }
        let saver = environment
        let change = PendingUploadQueue.KeyChange(keyFileBookmarkData: nil, keyFileFilename: nil)
        let result = try await CloudDatabaseSaver.$keyChange.withValue(change) {
            try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: FileDigest.sha512(base), expectedRev: "rev-A", kdfPolicy: .mainApp,
                newCompositeKey: newKey, environment: saver)
        }
        guard case .saved = result else { return XCTFail("Expected durable rekey") }
        let current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: current.id).isEmpty)
        let cache = DatabaseListStore.cacheLocation(for: current)
        let vm = DatabaseViewModel(databaseReference: current, cloudSyncOperation: { reference, _ in
            CloudSyncResolution(reference: reference, localURL: cache, data: try Data(contentsOf: cache), status: .current)
        }, cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
            try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev,
                kdfPolicy: .mainApp, newCompositeKey: newKey, encryptionSettings: settings, environment: saver)
        }, quickUnlockKeyPersistOperation: { _, _, _ in false }, expressUnlockKeySaveOperation: { _, _ in })
        await vm.unlock(password: newPassword)
        defer { vm.lock() }
        XCTAssertEqual(vm.state, .unlocked)
        try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "After rekey restart", password: "new")))
        try await vm.save()
        let pending = try XCTUnwrap(PendingUploadQueue.readJournal(for: current.id).first)
        XCTAssertNotNil(pending.marker.binding)
        XCTAssertTrue(try Self.entryTitles(in: Data(contentsOf: cache), password: newPassword).contains("After rekey restart"))
    }

    func testUncertainRekeyRetirementKeepsPayloadAndAllowsFreshUnlock() async throws {
        let base = try fixtureData()
        let reference = try makeStoredManualReference(fileID: "/rekey-reopen-\(UUID().uuidString).kdbx", autoFillEnabled: false)
        try DatabaseListStore.cacheDatabaseCopy(base, for: reference)
        _ = try PendingLocalSaveStore.prepareSource(base, for: reference.id,
            masterKeyChangedAt: reference.lastMasterKeyChangeAt, baseCacheSHA512: FileDigest.sha512(base))
        XCTAssertEqual(try PendingLocalSaveStore.discard(PendingLocalSaveStore.recovery(for: reference.id)), .resolved)
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let session = SymmetricKey(size: .bits256)
        let opened = try KDBXParser.parseWithMeta(data: base, compositeKey: key, sessionKey: session)
        let draft = DatabaseDraft(rootGroup: opened.rootGroup, meta: opened.meta, sessionKey: session)
        let newPassword = "new-cloud-rekey-password"
        let newKey = try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil)
        let remote = InMemoryRemoteProvider(bytes: base, rev: "rev-A")
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = { _ in remote.currentMetadata }
        environment.downloadRemoteData = { _ in remote.currentBytes }
        environment.upload = { _, bytes, rev, _ in try remote.store(bytes, expectedRev: rev) }
        environment.revisionIdentifiesContent = { _, _ in false }
        environment.writeGuarantee = { _, _, _ in .preflightOnly }
        let failedRetirement = CloudJournalEffectCounter()
        environment.queue.synchronizeRetirementDirectory = { _ in
            failedRetirement.record()
            throw CocoaError(.fileWriteUnknown)
        }
        let writeMarker = environment.queue.writeMarkerAtomically
        environment.queue.writeMarkerAtomically = { bytes, url in
            if failedRetirement.value > 0 { throw CocoaError(.fileWriteUnknown) }
            try writeMarker(bytes, url)
        }
        let saver = environment
        let change = PendingUploadQueue.KeyChange(keyFileBookmarkData: nil, keyFileFilename: nil)
        let result = try await CloudDatabaseSaver.$keyChange.withValue(change) {
            try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: FileDigest.sha512(base), expectedRev: "rev-A", kdfPolicy: .mainApp,
                newCompositeKey: newKey, environment: saver)
        }
        guard case .committedWithoutConfirmedDurability = result else { return XCTFail("Expected uncertain retirement") }
        XCTAssertEqual(failedRetirement.value, 1)
        let current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: current.id).isEmpty)
        let cache = DatabaseListStore.cacheLocation(for: current)
        let directory = AppGroupContainer.url.appendingPathComponent("pending-uploads").appendingPathComponent(current.id.uuidString)
        let payloads = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "kdbx" }
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(payloads.first)), try Data(contentsOf: cache))
        var resumedSaver = environment
        resumedSaver.queue = .live
        let normalSaver = resumedSaver
        let vm = DatabaseViewModel(databaseReference: current, cloudSyncOperation: { reference, _ in
            CloudSyncResolution(reference: reference, localURL: cache, data: try Data(contentsOf: cache), status: .current)
        }, cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
            try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev,
                kdfPolicy: .mainApp, newCompositeKey: newKey, encryptionSettings: settings, environment: normalSaver)
        }, quickUnlockKeyPersistOperation: { _, _, _ in false }, expressUnlockKeySaveOperation: { _, _ in })
        await vm.unlock(password: newPassword)
        defer { vm.lock() }
        XCTAssertEqual(vm.state, .unlocked)
        try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "After rekey restart", password: "new")))
        try await vm.save()
        let pending = try XCTUnwrap(PendingUploadQueue.readJournal(for: current.id).first)
        XCTAssertNotNil(pending.marker.binding)
        XCTAssertTrue(try Self.entryTitles(in: Data(contentsOf: cache), password: newPassword).contains("After rekey restart"))
    }

    func testOfflineBoundDescendantsSurviveReopenAndDeliverInOrder() async throws {
        let base = try fixtureData()
        let reference = try makeStoredManualReference(fileID: "/offline-chain-\(UUID().uuidString).kdbx", autoFillEnabled: false)
        try DatabaseListStore.cacheDatabaseCopy(base, for: reference)
        let remote = InMemoryRemoteProvider(bytes: base, rev: "rev-A")
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = { _ in remote.currentMetadata }
        environment.downloadRemoteData = { _ in remote.currentBytes }
        environment.upload = { _, bytes, rev, _ in try remote.store(bytes, expectedRev: rev) }
        environment.writeGuarantee = { _, _, _ in .preflightOnly }
        environment.revisionIdentifiesContent = { _, _ in false }
        let saver = environment
        func open(_ reference: DatabaseReference) async -> DatabaseViewModel {
            let vm = DatabaseViewModel(databaseReference: reference, cloudSyncOperation: { reference, _ in
                let cache = DatabaseListStore.cacheLocation(for: reference)
                return CloudSyncResolution(reference: reference, localURL: cache, data: try Data(contentsOf: cache), status: .current)
            }, cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
                try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                    openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev,
                    kdfPolicy: .mainApp, newCompositeKey: newKey, encryptionSettings: settings, environment: saver)
            }, quickUnlockKeyPersistOperation: { _, _, _ in false }, expressUnlockKeySaveOperation: { _, _ in })
            await vm.unlock(password: fixturePassword)
            return vm
        }
        let first = await open(reference)
        XCTAssertEqual(first.state, .unlocked)
        try first.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(first.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Offline A", password: "A")))
        try await first.save()
        first.lock()
        let reloaded = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        let second = await open(reloaded)
        defer { second.lock() }
        XCTAssertEqual(second.state, .unlocked)
        for title in ["Offline B", "Offline C"] {
            try second.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(second.visibleRootGroupID),
                draft: EntryDraftPayload(title: title, password: title)))
            try await second.save()
        }
        let chain = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(chain.count, 3)
        XCTAssertTrue(chain.allSatisfy { $0.marker.binding != nil })
        XCTAssertEqual(chain[1].marker.predecessorOperationID, chain[0].id)
        XCTAssertEqual(chain[2].marker.predecessorOperationID, chain[1].id)
        for marker in chain {
            let current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
            let latest = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first { $0.id == marker.id })
            guard case .saved? = try await CloudDatabaseSaver.deliver(latest, reference: current, environment: saver) else {
                return XCTFail("Bound descendant delivery failed")
            }
        }
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
        XCTAssertTrue(try Self.entryTitles(in: remote.currentBytes, password: fixturePassword).isSuperset(of: ["Offline A", "Offline B", "Offline C"]))
    }

    func testOfflineKnownSaveCompletesSessionBookkeepingWithoutOptionalKeyPublicationOrRepeatedEncryption() async throws {
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        let reference = try makeStoredManualReference(fileID: "/queued-save.kdbx", autoFillEnabled: false)
        try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
        let encrypted = CloudJournalEffectCounter()
        let replacements = CloudJournalEffectCounter()
        let keyEffects = CloudJournalEffectCounter()
        let uploads = CloudJournalEffectCounter()
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        let encrypt = environment.encryptDraft
        environment.encryptDraft = { draft, key, header, policy in encrypted.record(); return try encrypt(draft, key, header, policy) }
        let replace = environment.replaceFile
        environment.replaceFile = { bytes, url, sha, ref in replacements.record(); return try replace(bytes, url, sha, ref) }
        environment.upload = { _, _, _, _ in uploads.record(); throw CloudProviderError.networkUnavailable }
        let saver = environment
        let vm = DatabaseViewModel(databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in nil })
            }, cloudSaveOperation: { draft, reference, key, sha, remoteSHA, rev, newKey, settings in
                try await CloudDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                    openTimeSHA512: sha, reconciledRemoteSHA512: remoteSHA, expectedRev: rev,
                    kdfPolicy: .mainApp, newCompositeKey: newKey, encryptionSettings: settings, environment: saver)
            }, quickUnlockKeyPersistOperation: { _, _, _ in false },
            expressUnlockKeySaveOperation: { _, _ in keyEffects.record() })
        await vm.unlock(password: fixturePassword)
        defer { vm.lock() }
        try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Durably queued edit", password: "queued")))
        try await vm.save()
        XCTAssertFalse(vm.isDirty)
        XCTAssertNil(vm.saveError)
        let installed = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        let reopened = try KDBXParser.parseWithMeta(data: installed, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(reopened.rootGroup.allEntries.contains { $0.title == "Durably queued edit" })
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(installed))
        let pending = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(pending), installed)
        XCTAssertEqual(CloudJournalDecision.state(of: pending.marker), .ready)
        XCTAssertEqual(keyEffects.value, 0)
        XCTAssertEqual(uploads.value, 0)
        XCTAssertEqual(encrypted.value, 1)
        XCTAssertEqual(replacements.value, 1)
        try await vm.save()
        XCTAssertEqual(encrypted.value, 1)
        XCTAssertEqual(replacements.value, 1)
    }

    func testCloudReadPublicationDeadlineKeepsMainActorResponsiveAndNeverReopensClosedPermission() async throws {
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        for claimFirst in [false, true] {
            let reference = try makeStoredManualReference(fileID: "/Vaults/cloud-publication-\(claimFirst).kdbx", autoFillEnabled: false)
            try DatabaseListStore.cacheDatabaseCopy(bytes, for: reference)
            let entered = XCTestExpectation(description: "Cloud worker reached controlled boundary")
            let workerEnded = XCTestExpectation(description: "Actual cloud publication worker ended")
            let unlockEnded = XCTestExpectation(description: "Unlock returned after its publication deadline")
            let heartbeat = XCTestExpectation(description: "Main actor heartbeat during blocked cloud IO")
            let gate = CloudPublicationTestGate()
            let effects = CloudJournalEffectCounter()
            var io = DatabaseListStore.KeyCommitPublicationIO()
            let liveCoordinate = io.coordinate
            if !claimFirst {
                io.coordinate = { target, registry, accessor in
                    entered.fulfill()
                    guard gate.wait() else { throw CocoaError(.fileReadUnknown) }
                    try liveCoordinate(target, registry, accessor)
                }
            }
            io.didFinish = { workerEnded.fulfill() }
            let vm = DatabaseViewModel(databaseReference: reference,
                cloudSyncOperation: { reference, _ in
                    try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in nil })
                }, localReadPublicationIO: io, localReadPublicationTimeout: .milliseconds(100),
                quickUnlockKeyPersistOperation: { _, _, _ in
                    effects.record()
                    if claimFirst { entered.fulfill(); return gate.wait() }
                    return true
                })
            let opening = Task { await vm.unlock(password: KDBXTestFixture.test.password); unlockEnded.fulfill() }
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 60)
            Task { @MainActor in heartbeat.fulfill() }
            let deadline = await XCTWaiter.fulfillment(of: [unlockEnded, heartbeat], timeout: 5)
            vm.lock()
            XCTAssertEqual(vm.state, .locked)
            XCTAssertNil(vm.compositeKey)
            gate.release()
            let joined = await XCTWaiter.fulfillment(of: [workerEnded], timeout: 15)
            if joined != .completed {
                XCTFail("Cloud publication worker failed to finish after releasing every test gate")
                // Shared storage cannot be cleared beneath an unquiesced worker.
                fatalError("Cloud publication test failed bounded worker termination")
            }
            if deadline != .completed {
                let finalJoin = await XCTWaiter.fulfillment(of: [unlockEnded], timeout: 15)
                if finalJoin != .completed { fatalError("Cloud unlock failed bounded termination after worker completion") }
            }
            await opening.value
            XCTAssertEqual(entry, .completed)
            XCTAssertEqual(deadline, .completed)
            XCTAssertEqual(effects.value, claimFirst ? 1 : 0)
            XCTAssertEqual(vm.state, .locked)
            XCTAssertNil(vm.compositeKey)
            XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), bytes)
        }
    }

    func testValidCloudCacheUnlocksDuringUnavailableRecoveryButMutationAndKeyPublicationStayClosed() async throws {
        let bytes = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        for fault in CloudJournalReadFault.allCases {
            let reference = try makeStoredManualReference(fileID: "/Vaults/recovery-\(fault).kdbx", autoFillEnabled: false)
            let context = try CloudJournalTestContext(reference: reference, base: bytes, payload: bytes)
            try fault.install(in: context)
            let effects = CloudJournalEffectCounter()
            let vm = DatabaseViewModel(databaseReference: reference,
                cloudSyncOperation: { reference, _ in
                    try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference, providerResolver: { _ in nil })
                }, quickUnlockKeyPersistOperation: { _, _, _ in effects.record(); return true })
            await vm.unlock(password: KDBXTestFixture.test.password)
            defer { vm.lock() }
            XCTAssertEqual(vm.state, .unlocked)
            XCTAssertFalse(vm.rootGroup?.allEntries.isEmpty ?? true)
            XCTAssertEqual(effects.value, 0)
            let session = SymmetricKey(size: .bits256)
            let parsed = try KDBXParser.parseWithMeta(data: bytes, password: KDBXTestFixture.test.password, sessionKey: session)
            let draft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session)
            let mutationEffects = CloudJournalEffectCounter()
            var mutation = context.environment()
            let encrypt = mutation.encryptDraft
            mutation.encryptDraft = { draft, key, header, policy in mutationEffects.record(); return try encrypt(draft, key, header, policy) }
            let replace = mutation.replaceFile
            mutation.replaceFile = { bytes, url, sha, reference in mutationEffects.record(); return try replace(bytes, url, sha, reference) }
            do {
                _ = try await CloudDatabaseSaver.save(draft: draft, reference: reference,
                    compositeKey: KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self)),
                    openTimeSHA512: FileDigest.sha512(bytes), expectedRev: reference.expectedCloudRevision,
                    environment: mutation)
                XCTFail("Unavailable recovery cannot authorize another local mutation")
            } catch { XCTAssertTrue(error is CloudSaveRecoveryWarning || error is SaveError) }
            XCTAssertEqual(mutationEffects.value, 0)
            let transport = CloudJournalTransport()
            let outcome = await PendingUploadDrainer(environment: context.drainerEnvironment(saver: context.environment(transport: transport))).drain(databaseId: reference.id)
            XCTAssertTrue(outcome.drainedDatabaseIDs.isEmpty)
            XCTAssertEqual(outcome.userIssue?.databaseId, reference.id)
            XCTAssertTrue(transport.effects.uploads.isEmpty)
            XCTAssertEqual(try Data(contentsOf: context.cacheURL), bytes)
            XCTAssertFalse(PendingUploadQueue.listMarkers(for: reference.id).isEmpty)
        }
    }

    func testSyncAndConflictOnOneDatabasePreserveTheOtherSessionsCloudState() async throws {
        let openedData = try KDBXTestFixture.test.data(in: Bundle(for: Self.self))
        let newerData = try KDBXTestFixture.kitchenSink.data(in: Bundle(for: Self.self))
        let firstReference = try makeStoredManualReference(fileID: "/Vaults/A.kdbx", autoFillEnabled: false)
        let secondReference = try makeStoredManualReference(fileID: "/Vaults/B.kdbx", autoFillEnabled: false)
        XCTAssertNotEqual(firstReference.id, secondReference.id)
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: firstReference)
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: secondReference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-B")
        let first = makeViewModelOnTheRealCache(reference: firstReference, remote: remote)
        let second = makeViewModel(
            reference: secondReference,
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .offlineCached)
            },
            pendingUploadMarkerCheck: { _ in true }
        )
        defer { first.lock(); second.lock() }
        let store = DatabaseSessionStore()
        store.adopt(first)
        store.adopt(second)
        await first.unlock(password: fixturePassword)
        await second.unlock(password: fixturePassword)
        await second.syncCloudNow()
        XCTAssertEqual(first.state, .unlocked)
        XCTAssertEqual(second.state, .unlocked)
        XCTAssertTrue(second.hasPendingCloudUploads)
        XCTAssertTrue(CloudSyncControls.showsWarning(for: second))
        let secondMetadata = second.databaseReference.cloudSyncMetadata
        let secondStoredMetadata = DatabaseListStore.databases.first { $0.id == secondReference.id }?.cloudSyncMetadata
        let secondOutcome = second.cloudSyncOutcome
        let secondBanner = second.cloudSyncBannerText
        let secondRefreshPending = second.isCloudRefreshPending
        let secondRoot = second.rootGroup
        let secondHash = second.openTimeSHA512
        let secondCache = DatabaseListStore.cacheLocation(for: secondReference)
        let secondBytes = try Data(contentsOf: secondCache)

        for conflict in [false, true] {
            if conflict {
                _ = try remote.store(newerData, expectedRev: nil)
                try first.applyEntryEdit(.createEntry(
                    parentGroupID: XCTUnwrap(first.visibleRootGroupID),
                    draft: EntryDraftPayload(title: "A conflict", password: "secret")
                ))
                try await first.save()
                let marker = try XCTUnwrap(PendingUploadQueue.readJournal(for: firstReference.id).first)
                var delivery = CloudDatabaseSaver.Environment.live
                delivery.getMetadata = { _ in remote.currentMetadata }
                delivery.downloadRemoteData = { _ in remote.currentBytes }
                delivery.upload = { _, bytes, rev, _ in try remote.store(bytes, expectedRev: rev) }
                var drainerEnvironment = PendingUploadDrainer.Environment.live
                drainerEnvironment.beginBackgroundTask = { _ in .invalid }
                drainerEnvironment.endBackgroundTask = { _ in }
                let liveDelivery = delivery
                drainerEnvironment.deliverMarker = { marker, reference in
                    try await CloudDatabaseSaver.deliver(marker, reference: reference, environment: liveDelivery)
                }
                let list = DatabaseListViewModel(pendingUploadDrainer: PendingUploadDrainer(environment: drainerEnvironment))
                store.installListHooks(on: list)
                store.handleAppDidBecomeActive()
                await list.drainPendingUploadsOnAppActive()
                let observedJournal = try PendingUploadQueue.readJournal(for: firstReference.id)
                XCTAssertEqual(observedJournal.count, 1)
                XCTAssertTrue(try XCTUnwrap(observedJournal.first).marker.isConflicted)
                XCTAssertEqual(list.rowStatuses[firstReference.id]?.pendingUploadConflictCount, 1)
                XCTAssertTrue(first.hasPendingCloudUploads)
                XCTAssertTrue(first.hasPendingUploadConflict)
                XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(marker),
                    try Data(contentsOf: DatabaseListStore.cacheLocation(for: firstReference)))
            } else {
                await first.syncCloudNow()
                XCTAssertEqual(first.cloudSyncOutcome, .upToDate)
                XCTAssertEqual(first.databaseReference.cloudSyncMetadata?.remoteRev, "rev-B")
            }

            XCTAssertEqual(second.databaseReference.cloudSyncMetadata, secondMetadata)
            XCTAssertEqual(DatabaseListStore.databases.first { $0.id == secondReference.id }?.cloudSyncMetadata,
                           secondStoredMetadata)
            XCTAssertTrue(second.hasPendingCloudUploads)
            XCTAssertEqual(second.isCloudRefreshPending, secondRefreshPending)
            XCTAssertEqual(second.cloudSyncOutcome, secondOutcome)
            XCTAssertEqual(second.cloudSyncBannerText, secondBanner)
            XCTAssertTrue(CloudSyncControls.showsWarning(for: second))
            XCTAssertFalse(second.isSyncingCloud)
            XCTAssertNil(second.saveConflict)
            XCTAssertTrue(second.rootGroup === secondRoot)
            XCTAssertEqual(second.openTimeSHA512, secondHash)
            XCTAssertEqual(try Data(contentsOf: secondCache), secondBytes)
        }
    }

    func testDrainStateRefreshDoesNotReviveLockedOrRetiredSessions() async throws {
        let reference = try makeStoredManualReference()
        let openedData = try fixtureData()
        let vm = makeViewModel(reference: reference, openedData: openedData,
            pendingUploadMarkerCheck: { _ in true })
        let store = DatabaseSessionStore()
        store.adopt(vm)
        await vm.unlock(password: fixturePassword)
        vm.lock()
        store.refreshPendingUploads(for: [reference.id])
        XCTAssertEqual(vm.state, .locked)
        XCTAssertFalse(vm.hasPendingCloudUploads)
        XCTAssertFalse(vm.hasPendingUploadConflict)
        XCTAssertTrue(store.retire(reference.id, force: true))
        store.refreshPendingUploads(for: [reference.id])
        XCTAssertNil(store.session(for: reference.id))
        XCTAssertEqual(vm.state, .locked)
    }

    func testManualPolicyOpenFlagsTheSkippedRefreshWithoutAWarning() async throws {
        let openedData = try fixtureData()
        let vm = makeViewModel(reference: try makeStoredManualReference(), openedData: openedData)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertTrue(vm.isCloudRefreshPending)
        XCTAssertNil(vm.cloudSyncBannerText, "A deliberate skip must not wear the offline or error warning")
        XCTAssertNil(vm.cloudSyncOutcome)
        XCTAssertTrue(CloudSyncControls.isVisible(for: vm))
        XCTAssertTrue(CloudSyncControls.showsWarning(for: vm))
        XCTAssertTrue(vm.canSyncCloudNow)
    }

    func testSyncNowWithUnchangedCopyReportsUpToDateAndKeepsTheOpenTree() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        let refreshRecorder = RefreshRecorder()
        let syncedAt = Date(timeIntervalSince1970: 5_000)
        let vm = makeViewModel(
            reference: reference,
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                refreshRecorder.record(reference)
                var synced = reference
                synced.updateCloudSyncMetadata { metadata in
                    metadata.remoteRev = "rev-A"
                    metadata.lastSyncedAt = syncedAt
                    metadata.lastSyncIssue = nil
                }
                return Self.resolution(synced, data: openedData, status: .current)
            }
        )
        await vm.unlock(password: fixturePassword)
        let rootBefore = try XCTUnwrap(vm.rootGroup)
        let sessionKeyBefore = try XCTUnwrap(vm.sessionKey)

        await vm.syncCloudNow()

        XCTAssertEqual(refreshRecorder.references.map(\.id), [reference.id])
        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
        XCTAssertFalse(vm.isCloudRefreshPending)
        XCTAssertFalse(vm.isSyncingCloud)
        XCTAssertTrue(vm.rootGroup === rootBefore, "Identical bytes must not be re-parsed")
        XCTAssertEqual(
            vm.sessionKey?.withUnsafeBytes { Data($0) },
            sessionKeyBefore.withUnsafeBytes { Data($0) }
        )
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(stored.cloudSyncMetadata?.lastSyncedAt, syncedAt)
        XCTAssertEqual(stored.cloudSyncPolicy, .manual, "Syncing once must not change the policy")
        XCTAssertEqual(vm.databaseReference.cloudSyncMetadata?.lastSyncedAt, syncedAt)
        XCTAssertFalse(CloudSyncControls.showsWarning(for: vm))
        vm.dismissCloudSyncOutcome()
        XCTAssertTrue(CloudSyncControls.isVisible(for: vm), "The shortcut must survive dismissing a successful result")
        XCTAssertTrue(vm.canSyncCloudNow)
        await vm.syncCloudNow()
        XCTAssertEqual(refreshRecorder.references.count, 2)
        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
    }

    func testSyncNowWithNewerCopyReplacesTheOpenDatabase() async throws {
        let openedData = try fixtureData()
        let newerData = try fixtureData(named: "kitchen-sink")
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: newerData, status: .downloaded)
            }
        )
        await vm.unlock(password: fixturePassword)
        XCTAssertFalse(vm.openingSyncReachedCloud)
        let titlesBefore = entryTitles(in: vm)
        vm.workspace.selectedEntryID = vm.rootGroup?.allEntries.first?.id
        let newerTitles = try Self.entryTitles(in: newerData, password: fixturePassword)
        let republished = expectation(description: "AutoFill republished from the newer tree")
        republished.assertForOverFulfill = false
        CredentialIdentityStoreManager.populateObserver = { _, entries in
            let titles = Set(entries.map(\.title))
            if titles.isEmpty == false, titles.isSubset(of: newerTitles), titles.isSubset(of: titlesBefore) == false {
                republished.fulfill()
            }
        }
        var observedStates: [DatabaseViewModel.State] = []
        let stateObservation = Task { @MainActor in
            while !Task.isCancelled {
                if observedStates.last != vm.state {
                    observedStates.append(vm.state)
                }
                await Task.yield()
            }
        }

        await vm.syncCloudNow()
        stateObservation.cancel()

        XCTAssertEqual(vm.cloudSyncOutcome, .updated)
        XCTAssertTrue(
            observedStates.contains(.unlocking),
            "The swap must pass through .unlocking so open editors are torn down"
        )
        await fulfillment(of: [republished], timeout: 10)
        XCTAssertFalse(vm.isCloudRefreshPending)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(newerData))
        XCTAssertNotEqual(entryTitles(in: vm), titlesBefore)
        XCTAssertNil(vm.workspace.selectedEntryID, "Selection must not point into the replaced tree")
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertTrue(vm.openingSyncReachedCloud, "The replacement came from the provider")
    }

    /// The opening steps tick the sync only when the open reached the
    /// provider; a cached open (sync on open off, offline, signed out) is not a sync.
    func testTheOpeningStepsTickTheSyncOnlyWhenTheOpenReachedTheProvider() async throws {
        let openedData = try fixtureData()
        let statuses: [(CloudSyncResolution.Status, Bool)] = [
            (.current, true),
            (.downloaded, true),
            (.refreshSkipped, false),
            (.offlineCached, false),
            (.disconnectedCached, false),
            (.cachedWithError("Server error"), false),
        ]
        for (status, reachedCloud) in statuses {
            let vm = DatabaseViewModel(
                databaseReference: try makeStoredManualReference(provider: .webDAV),
                cloudSyncOperation: { reference, _ in
                    Self.resolution(reference, data: openedData, status: status)
                }
            )
            await vm.unlock(password: fixturePassword)

            XCTAssertEqual(vm.state, .unlocked, "\(status)")
            XCTAssertEqual(vm.openingSyncReachedCloud, reachedCloud, "\(status)")
            let steps = DatabaseOpeningSteps.make(step: .decrypting, isCloudBacked: true, provider: .webDAV,
                                                  progress: nil, syncReachedCloud: vm.openingSyncReachedCloud)
            XCTAssertEqual(steps.first?.state, reachedCloud ? .done : .skipped, "\(status)")
            vm.lock()
        }
    }

    func testSyncNowOfflineKeepsTheOpenCopyAndTheSkippedRefreshFlag() async throws {
        let openedData = try fixtureData()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                var failed = reference
                failed.updateCloudSyncMetadata { $0.lastSyncIssue = .networkUnavailable }
                return Self.resolution(failed, data: openedData, status: .offlineCached)
            }
        )
        await vm.unlock(password: fixturePassword)
        let rootBefore = try XCTUnwrap(vm.rootGroup)

        await vm.syncCloudNow()

        XCTAssertEqual(vm.cloudSyncOutcome, .failed(CloudSyncResolution.offlineCachedBannerMessage))
        XCTAssertEqual(vm.cloudSyncBannerText, CloudSyncResolution.offlineCachedBannerMessage)
        XCTAssertTrue(vm.isCloudRefreshPending, "The cloud still has not been checked")
        XCTAssertTrue(vm.rootGroup === rootBefore)
        XCTAssertTrue(CloudSyncControls.showsWarning(for: vm), "A failed check must not clear the warning")
        XCTAssertTrue(CloudSyncControls.isVisible(for: vm))
    }

    func testSyncNowThatThrowsReportsTheFailure() async throws {
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: try fixtureData(),
            cloudRefreshOperation: { _, _ in
                throw CloudProviderError.fileNotFound
            }
        )
        await vm.unlock(password: fixturePassword)

        await vm.syncCloudNow()

        XCTAssertEqual(vm.cloudSyncOutcome, .failed(CloudProviderError.fileNotFound.localizedDescription))
        XCTAssertTrue(vm.isCloudRefreshPending)
        XCTAssertFalse(vm.isSyncingCloud)
    }

    func testSyncNowRefusesWhileChangesAreUnsaved() async throws {
        let refreshRecorder = RefreshRecorder()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: try fixtureData(),
            cloudRefreshOperation: { reference, _ in
                refreshRecorder.record(reference)
                throw CloudProviderError.networkUnavailable
            }
        )
        await vm.unlock(password: fixturePassword)
        let editorID = UUID()
        vm.setEditorHasUnsavedChanges(true, editorID: editorID)

        XCTAssertFalse(vm.canSyncCloudNow)
        XCTAssertTrue(CloudSyncControls.isVisible(for: vm), "Unsaved work disables the shortcut rather than hiding it")
        await vm.syncCloudNow()

        XCTAssertTrue(refreshRecorder.references.isEmpty)
        XCTAssertNil(vm.cloudSyncOutcome)

        vm.setEditorHasUnsavedChanges(false, editorID: editorID)
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Unsaved", password: "p"))
        )
        XCTAssertTrue(vm.isDirty)

        XCTAssertFalse(vm.canSyncCloudNow)
        await vm.syncCloudNow()
        XCTAssertTrue(refreshRecorder.references.isEmpty)
    }

    /// An edit can start while the sync is out on the network. Its draft must
    /// survive: the newer copy stays in the cache for the save to meet.
    func testSyncNowLeavesAnEditStartedMidSyncForTheSaveToMerge() async throws {
        let openedData = try fixtureData()
        let newerData = try fixtureData(named: "kitchen-sink")
        let gate = SaveGate()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return Self.resolution(reference, data: newerData, status: .downloaded)
            }
        )
        await vm.unlock(password: fixturePassword)
        let rootBefore = try XCTUnwrap(vm.rootGroup)

        let syncTask = Task { await vm.syncCloudNow() }
        await gate.waitUntilStarted()
        XCTAssertTrue(vm.isSyncingCloud)
        XCTAssertFalse(vm.canSyncCloudNow)
        vm.setEditorHasUnsavedChanges(true, editorID: UUID())
        await gate.open()
        await syncTask.value

        XCTAssertEqual(vm.cloudSyncOutcome, .updateWaitsForSave)
        XCTAssertTrue(vm.rootGroup === rootBefore)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(openedData), "The save must compare against what was opened")
        XCTAssertFalse(vm.isCloudRefreshPending)
        XCTAssertFalse(vm.isSyncingCloud)
    }

    func testLockDuringSyncNowDropsItsResult() async throws {
        let gate = SaveGate()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: try fixtureData(),
            cloudRefreshOperation: { reference, _ in
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return Self.resolution(reference, data: try Self.bundledFixtureData(named: "kitchen-sink"), status: .downloaded)
            }
        )
        await vm.unlock(password: fixturePassword)

        let syncTask = Task { await vm.syncCloudNow() }
        await gate.waitUntilStarted()
        vm.lock(manuallyTriggered: true)
        await gate.open()
        await syncTask.value

        XCTAssertEqual(vm.state, .locked)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(vm.cloudSyncOutcome)
        XCTAssertFalse(vm.isSyncingCloud)
        XCTAssertFalse(vm.isCloudRefreshPending)
    }

    /// A save can finish while Sync Now is out on the network. The copy that
    /// comes back predates it, so it must not replace the saved tree; Sync
    /// Now asks again and meets the saved copy.
    func testSyncNowDoesNotRollBackASaveThatFinishedMidSync() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let gate = SaveGate()
        let refreshRecorder = RefreshRecorder()
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-B")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote,
            onRefresh: { refreshRecorder.record($0) })
        await vm.unlock(password: fixturePassword)
        remote.holdNextDownload(on: gate)
        let syncTask = Task { await vm.syncCloudNow() }
        await gate.waitUntilStarted()
        let parent = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(.createEntry(parentGroupID: parent, draft: EntryDraftPayload(title: "Saved Mid-Sync", password: "p")))
        try await vm.save()
        let saved = try Data(contentsOf: cacheURL)
        let marker = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(marker), saved)
        XCTAssertEqual(marker.marker.expectedRev, reference.expectedCloudRevision)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(saved))
        await gate.open()
        await syncTask.value
        XCTAssertEqual(refreshRecorder.references.count, 2)
        XCTAssertEqual(vm.cloudSyncOutcome, .updateWaitsForSave)
        XCTAssertNotNil(vm.saveConflict)
        XCTAssertTrue(entryTitles(in: vm).contains("Saved Mid-Sync"))
        XCTAssertEqual(try Data(contentsOf: cacheURL), saved)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(saved))
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertFalse(vm.isSyncingCloud)
    }

    /// The same race through the production coordinator and saver, where the
    /// cache is shared: the held download predates the save, and the save
    /// rewrites the cache and the recorded revision while it is out. Only the
    /// provider transport is faked. Letting the stale download land in the
    /// cache would make the re-fetch trust it (its revision is the save's),
    /// replace the saved tree, and let the next save drop the entry remotely.
    func testSyncNowKeepsASaveThatLandedDuringItsDownloadThroughTheRealCache() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let remote = InMemoryRemoteProvider(bytes: try mergeVariant(title: "Remote Mid-Sync"), rev: "rev-B")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.state, .unlocked)

        let gate = SaveGate()
        remote.holdNextDownload(on: gate)
        let syncTask = Task { await vm.syncCloudNow() }
        await gate.waitUntilStarted()
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Saved Mid-Sync", password: "p"))
        )
        try await vm.save()
        XCTAssertNil(vm.saveConflict)
        let savedData = try Data(contentsOf: cacheURL)
        let source = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(source), savedData)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(savedData))
        await gate.open()
        await syncTask.value

        XCTAssertEqual(vm.cloudSyncOutcome, .updateWaitsForSave)
        XCTAssertTrue(entryTitles(in: vm).contains("Saved Mid-Sync"))
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(savedData))
        XCTAssertEqual(try Data(contentsOf: cacheURL), savedData, "The stale download must not replace the saved cache")
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(source), savedData)
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertNotNil(vm.saveConflict)
        try await vm.mergeAndSave()
        let merged = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        let mergedBytes = try PendingUploadQueue.readImmutablePayload(merged)
        XCTAssertEqual(try Data(contentsOf: cacheURL), mergedBytes)
        XCTAssertTrue(try Self.entryTitles(in: mergedBytes, password: fixturePassword)
            .isSuperset(of: ["Saved Mid-Sync", "Remote Mid-Sync"]))
        var delivery = CloudDatabaseSaver.Environment.live
        delivery.getMetadata = { _ in remote.currentMetadata }
        delivery.downloadRemoteData = { _ in remote.currentBytes }
        delivery.upload = { _, data, rev, _ in try remote.store(data, expectedRev: rev) }
        guard case .saved? = try await CloudDatabaseSaver.deliver(merged, reference: vm.databaseReference, environment: delivery) else {
            return XCTFail("Merged payload must deliver")
        }
        XCTAssertEqual(remote.currentBytes, mergedBytes)
        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Saved After Sync", password: "p"))
        )
        try await vm.save()
        XCTAssertNil(vm.saveConflict)
        let next = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        let nextBytes = try PendingUploadQueue.readImmutablePayload(next)
        guard case .saved? = try await CloudDatabaseSaver.deliver(next, reference: vm.databaseReference, environment: delivery) else {
            return XCTFail("Subsequent save must deliver")
        }
        XCTAssertEqual(remote.currentBytes, nextBytes)
        let remoteTitles = try Self.entryTitles(in: remote.currentBytes, password: fixturePassword)
        XCTAssertTrue(remoteTitles.isSuperset(of: ["Saved Mid-Sync", "Remote Mid-Sync", "Saved After Sync"]))
    }

    /// The response can also arrive while a save is still uploading. Nothing
    /// shows the save yet, so Sync Now must wait it out and ask again rather
    /// than merge the older revision ahead of the save's own, which would
    /// keep the save's revision from being recorded.
    func testSyncNowWaitsOutASaveStillInFlightWhenItsResponseArrives() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let refreshGate = SaveGate()
        let saveGate = SaveGate()
        let refreshRecorder = RefreshRecorder()
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-B")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote,
            beforeSave: { await saveGate.signalStarted(); await saveGate.waitUntilOpen() },
            onRefresh: { refreshRecorder.record($0) })
        await vm.unlock(password: fixturePassword)
        remote.holdNextDownload(on: refreshGate)
        let syncTask = Task { await vm.syncCloudNow() }
        await refreshGate.waitUntilStarted()
        let parent = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(.createEntry(parentGroupID: parent, draft: EntryDraftPayload(title: "Saved Mid-Sync", password: "p")))
        let saveTask = Task { try await vm.save() }
        await saveGate.waitUntilStarted()
        try vm.applyEntryEdit(.createEntry(parentGroupID: parent, draft: EntryDraftPayload(title: "Late Edit", password: "p")))
        await refreshGate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.cloudSyncOutcome, "Sync Now must wait for the in-flight save")
        await saveGate.open()
        try await saveTask.value
        await syncTask.value
        let saved = try Data(contentsOf: cacheURL)
        let journal = try PendingUploadQueue.readJournal(for: reference.id)
        XCTAssertEqual(journal.count, 2)
        let first = try XCTUnwrap(journal.first)
        let marker = try XCTUnwrap(journal.last)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(marker), saved)
        XCTAssertNotEqual(try PendingUploadQueue.readImmutablePayload(first), saved)
        XCTAssertEqual(marker.marker.predecessorOperationID, first.id)
        XCTAssertEqual(marker.marker.expectedRev, reference.expectedCloudRevision)
        XCTAssertEqual(refreshRecorder.references.count, 2)
        XCTAssertEqual(vm.cloudSyncOutcome, .updateWaitsForSave)
        XCTAssertNotNil(vm.saveConflict)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(saved))
        XCTAssertTrue(entryTitles(in: vm).isSuperset(of: ["Saved Mid-Sync", "Late Edit"]))
        XCTAssertTrue(try Self.entryTitles(in: saved, password: fixturePassword).isSuperset(of: ["Saved Mid-Sync", "Late Edit"]))
        XCTAssertEqual(vm.databaseReference.expectedCloudRevision, reference.expectedCloudRevision)
        XCTAssertFalse(vm.isSyncingCloud)
    }

    /// Backgrounding while the fetched copy is parsed must still lock. The
    /// swap reads `.unlocking`, which the lifecycle handlers used to ignore.
    func testBackgroundingWhileSyncNowParsesLocksTheSession() async throws {
        let savedLockOnBackground = SettingsService.lockOnBackground
        SettingsService.lockOnBackground = true
        defer { SettingsService.lockOnBackground = savedLockOnBackground }

        let vm = try await makeViewModelParsingANewerCopy()
        let lockTrigger = triggerWhenParsing(vm) { vm.handleSceneDidEnterBackground() }

        await vm.syncCloudNow()
        let didTrigger = await lockTrigger.value

        XCTAssertTrue(didTrigger, "The background event must land while the copy is parsed")
        assertLockedAfterSync(vm)
    }

    /// The inactivity timer and the Lock command go through `lockRequest()`.
    func testLockRequestWhileSyncNowParsesLocksTheSession() async throws {
        let vm = try await makeViewModelParsingANewerCopy()
        let lockTrigger = triggerWhenParsing(vm) { vm.lockRequest() }

        await vm.syncCloudNow()
        let didTrigger = await lockTrigger.value

        XCTAssertTrue(didTrigger, "The lock request must land while the copy is parsed")
        assertLockedAfterSync(vm)
    }

    func testDatabaseTransitionDuringSyncReloadHonorsUnsavedEditorBeforeLocking() async throws {
        let vm = try await makeViewModelParsingANewerCopy()
        let routing = AppRoutingCoordinator()
        let editorID = UUID()
        let lockTrigger = triggerWhenParsing(vm) {
            vm.setEditorHasUnsavedChanges(true, editorID: editorID)

            routing.requestDatabaseTransition(to: .close, from: vm)

            XCTAssertEqual(vm.state, .unlocking, "A reload is still an open session for editor decisions")
            XCTAssertEqual(vm.pendingLockRequest?.reason, .openEditor)
            XCTAssertNil(routing.completeDatabaseTransition(from: vm))
            let request = vm.pendingLockRequest
            vm.setEditorHasUnsavedChanges(false, editorID: editorID)
            if let request { vm.resumeLockRequest(request) }
        }
        defer {
            lockTrigger.cancel()
            vm.lock()
        }

        await vm.syncCloudNow()
        lockTrigger.cancel()
        let didTrigger = await lockTrigger.value

        XCTAssertTrue(didTrigger, "The transition must arrive while the newer copy is parsed")
        assertLockedAfterSync(vm)
        guard case .close? = routing.completeDatabaseTransition(from: vm) else {
            return XCTFail("Resolving the editor should resume the close during reload")
        }
    }

    /// A YubiKey session's composite key holds the response to the opened
    /// copy's challenge. A newer copy carries a new challenge, so Sync Now
    /// leaves it in the cache for the next unlock instead of failing to parse.
    func testSyncNowLeavesANewerYubiKeyCopyForTheNextUnlock() async throws {
        let bundle = Bundle(for: Self.self)
        let openedData = try KDBXTestFixture.challengeResponse.data(in: bundle)
        let newerData = try KDBXTestFixture.challengeResponseAESKDF.data(in: bundle)
        XCTAssertNotEqual(
            try ChallengeResponseKey.challenge(forDatabase: openedData),
            try ChallengeResponseKey.challenge(forDatabase: newerData)
        )
        var reference = try makeStoredManualReference()
        reference.hardwareKey = HardwareKeyConfiguration(transport: .nfc, slot: .two)
        DatabaseListStore.testUpsert(reference)
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .refreshSkipped)
            },
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: newerData, status: .downloaded)
            },
            hardwareKeyResponseOperation: { challenge, _ in
                YubiKeyEmulator.response(to: challenge)
            },
            hardwareKeyTransportsProvider: { [.nfc] }
        )
        await vm.unlock(password: KDBXTestFixture.challengeResponse.password)
        XCTAssertTrue(vm.sessionUsesHardwareKey)
        let rootBefore = try XCTUnwrap(vm.rootGroup)

        await vm.syncCloudNow()

        XCTAssertEqual(vm.cloudSyncOutcome, .updateWaitsForUnlock)
        XCTAssertTrue(vm.rootGroup === rootBefore)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(openedData))
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertFalse(vm.isCloudRefreshPending)
    }

    /// The provider round trip needs no key, so it must not wait for the
    /// biometric prompt to finish.
    func testBiometricUnlockSyncsWhileThePromptIsUp() async throws {
        let openedData = try fixtureData()
        let syncStarted = PendingFlag(false)
        let vm = DatabaseViewModel(
            databaseReference: try makeStoredManualReference(),
            cloudSyncOperation: { reference, _ in
                syncStarted.value = true
                return Self.resolution(reference, data: openedData, status: .current)
            },
            biometricCompositeKeyOperation: { [fixturePassword] _, _ in
                try await Self.waitUntil { syncStarted.value }
                return QuickUnlockKeys(
                    storedKey: try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil)
                )
            }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(vm.state, .unlocked)
    }

    /// A sync that finished during a prompt the user then left must not
    /// reach the session or the stored reference.
    func testLeftBiometricPromptDropsTheOverlappingSync() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        let syncFinished = PendingFlag(false)
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                var offline = reference
                offline.updateCloudSyncMetadata { $0.lastSyncIssue = .networkUnavailable }
                syncFinished.value = true
                return Self.resolution(offline, data: openedData, status: .offlineCached)
            },
            biometricCompositeKeyOperation: { _, _ in
                try await Self.waitUntil { syncFinished.value }
                throw LAError(.userFallback)
            }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .passwordFallback)
        XCTAssertEqual(vm.state, .locked)
        XCTAssertNil(vm.cloudSyncBannerText)
        XCTAssertNil(vm.databaseReference.cloudSyncMetadata?.lastSyncIssue)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertNil(stored.cloudSyncMetadata?.lastSyncIssue)
    }

    /// Progress the sync reports behind the prompt is session state too, so
    /// a prompt the user left must not leave a progress bar behind.
    func testLeftBiometricPromptShowsNoProgressFromTheOverlappingSync() async throws {
        let openedData = try fixtureData()
        let syncFinished = PendingFlag(false)
        let vm = DatabaseViewModel(
            databaseReference: try makeStoredManualReference(),
            cloudSyncOperation: { reference, progress in
                progress(0.5)
                syncFinished.value = true
                return Self.resolution(reference, data: openedData, status: .current)
            },
            biometricCompositeKeyOperation: { _, _ in
                try await Self.waitUntil { syncFinished.value }
                throw LAError(.userFallback)
            }
        )

        let outcome = await vm.unlockWithBiometrics()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(outcome, .passwordFallback)
        XCTAssertNil(vm.cloudSyncProgress)
    }

    /// An offline provider can take its full timeout to give up, and some
    /// ignore cancellation. A failed prompt must return to the unlock form
    /// right away instead of waiting for it.
    func testFailedBiometricPromptDoesNotWaitForTheOverlappingSync() async throws {
        let openedData = try fixtureData()
        let providerAnswers = PendingFlag(false)
        defer { providerAnswers.value = true }
        let vm = DatabaseViewModel(
            databaseReference: try makeStoredManualReference(),
            cloudSyncOperation: { reference, _ in
                while providerAnswers.value == false {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return Self.resolution(reference, data: openedData, status: .current)
            },
            biometricCompositeKeyOperation: { _, _ in
                throw LAError(.userFallback)
            }
        )

        let returned = expectation(description: "biometric unlock returned")
        let unlock = Task {
            let outcome = await vm.unlockWithBiometrics()
            returned.fulfill()
            return outcome
        }
        await fulfillment(of: [returned], timeout: 5)
        providerAnswers.value = true

        let outcome = await unlock.value
        XCTAssertEqual(outcome, .passwordFallback)
        XCTAssertEqual(vm.state, .locked)
    }

    /// Cancel while the provider is still answering: the answer, an offline
    /// copy with a sync issue, reaches neither the session nor the stored
    /// reference, and the correct password it would have opened with is moot.
    func testCancellingDuringTheCloudReadLeavesNoSyncStatusBehind() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        let syncStarted = PendingFlag(false)
        let providerAnswers = PendingFlag(false)
        defer { providerAnswers.value = true }
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, progress in
                syncStarted.value = true
                progress(0.5)
                try await Self.waitUntil { providerAnswers.value }
                var offline = reference
                offline.updateCloudSyncMetadata { $0.lastSyncIssue = .networkUnavailable }
                return Self.resolution(offline, data: openedData, status: .offlineCached)
            },
            pendingUploadMarkerCheck: { _ in true }
        )
        let unlock = Task { await vm.unlock(password: fixturePassword) }
        try await Self.waitUntil { syncStarted.value }
        await Task.yield()

        XCTAssertTrue(vm.cancelUnlockAttempt())
        XCTAssertEqual(vm.state, .locked)
        providerAnswers.value = true
        await unlock.value
        try await Task.sleep(for: .milliseconds(50))

        assertNoSyncStatus(on: vm, reference: reference)
    }

    /// Cancel behind the Touch ID prompt: the prompt then succeeds and the
    /// overlapping sync finishes, but neither may unlock or leave status.
    func testCancellingDuringTheBiometricPromptDropsTheOverlappingSync() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        let syncFinished = PendingFlag(false)
        let promptAnswers = PendingFlag(false)
        defer { promptAnswers.value = true }
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, progress in
                progress(0.5)
                var offline = reference
                offline.updateCloudSyncMetadata { $0.lastSyncIssue = .networkUnavailable }
                syncFinished.value = true
                return Self.resolution(offline, data: openedData, status: .offlineCached)
            },
            biometricCompositeKeyOperation: { [fixturePassword] _, _ in
                try await Self.waitUntil { promptAnswers.value }
                return QuickUnlockKeys(storedKey: try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil))
            },
            pendingUploadMarkerCheck: { _ in true }
        )
        let unlock = Task { await vm.unlockWithBiometrics() }
        try await Self.waitUntil { syncFinished.value }
        await Task.yield()

        XCTAssertTrue(vm.cancelUnlockAttempt())
        promptAnswers.value = true
        let outcome = await unlock.value
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(vm.didManuallyLock)
        assertNoSyncStatus(on: vm, reference: reference)
    }

    /// Sync Now replacing the open tree reads `.unlocking`, but it is not an
    /// open that Cancel may end.
    func testCancelUnlockAttemptIsRefusedWhileSyncNowReplacesTheTree() async throws {
        let vm = try await makeViewModelParsingANewerCopy()
        let trigger = triggerWhenParsing(vm) {
            XCTAssertFalse(vm.canCancelUnlockAttempt)
            XCTAssertFalse(vm.cancelUnlockAttempt())
        }

        await vm.syncCloudNow()
        let didTrigger = await trigger.value

        XCTAssertTrue(didTrigger, "Cancel must be tried while the copy is parsed")
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertFalse(vm.didManuallyLock)
    }

    private func assertNoSyncStatus(
        on vm: DatabaseViewModel,
        reference: DatabaseReference,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(vm.state, .locked, file: file, line: line)
        XCTAssertNil(vm.rootGroup, file: file, line: line)
        XCTAssertNil(vm.openFailure, file: file, line: line)
        XCTAssertNil(vm.cloudSyncBannerText, file: file, line: line)
        XCTAssertNil(vm.cloudSyncProgress, file: file, line: line)
        XCTAssertNil(vm.cloudSyncOutcome, file: file, line: line)
        XCTAssertFalse(vm.isCloudRefreshPending, file: file, line: line)
        XCTAssertFalse(vm.hasPendingCloudUploads, file: file, line: line)
        XCTAssertNil(vm.databaseReference.cloudSyncMetadata?.lastSyncIssue, file: file, line: line)
        let stored = DatabaseListStore.databases.first { $0.id == reference.id }
        XCTAssertNotNil(stored, file: file, line: line)
        XCTAssertNil(stored?.cloudSyncMetadata?.lastSyncIssue, file: file, line: line)
    }

    /// A progress report still queued when the sync is applied must not bring
    /// the progress bar back over the unlocked database.
    func testProgressReportedAfterTheOpenSyncWasAppliedIsDropped() async throws {
        let openedData = try fixtureData()
        let reportProgress = ProgressHandlerBox()
        let vm = DatabaseViewModel(
            databaseReference: try makeStoredManualReference(),
            cloudSyncOperation: { reference, progress in
                reportProgress.handler = progress
                return Self.resolution(reference, data: openedData, status: .current)
            },
            biometricCompositeKeyOperation: { [fixturePassword] _, _ in
                QuickUnlockKeys(storedKey: try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil))
            }
        )

        let outcome = await vm.unlockWithBiometrics()
        XCTAssertEqual(outcome, .unlocked)
        reportProgress.handler?(0.9)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.cloudSyncProgress)

        vm.lock()
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.state, .unlocked)
        reportProgress.handler?(0.9)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.cloudSyncProgress)
    }

    func testOpenAndSyncNowReportPendingAutoFillUploads() async throws {
        let openedData = try fixtureData()
        let pending = PendingFlag(true)
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .current)
            },
            pendingUploadMarkerCheck: { _ in pending.value }
        )

        await vm.unlock(password: fixturePassword)
        XCTAssertTrue(vm.hasPendingCloudUploads)

        pending.value = false
        await vm.syncCloudNow()
        XCTAssertFalse(vm.hasPendingCloudUploads)
    }

    func testAutoFillEntryReachesTheOpenSessionOnceItsUploadDrains() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-A")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.state, .unlocked)

        try await saveThroughAutoFill(title: "Created in AutoFill", reference: reference)
        try await deliverPendingUploads(for: reference, to: remote)
        XCTAssertTrue(try Self.entryTitles(in: remote.currentBytes, password: fixturePassword).contains("Created in AutoFill"))
        XCTAssertFalse(entryTitles(in: vm).contains("Created in AutoFill"))

        let adopted = await vm.adoptChangedCloudCacheIfPossible()

        XCTAssertTrue(adopted)
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertTrue(entryTitles(in: vm).contains("Created in AutoFill"))
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(try Data(contentsOf: cacheURL)))
        let unchanged = await vm.adoptChangedCloudCacheIfPossible()
        XCTAssertFalse(unchanged, "An unchanged cache must not be parsed again")

        // The next app save builds on the AutoFill change instead of conflicting with it.
        try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Saved in App", password: "p")))
        try await vm.save()
        XCTAssertNil(vm.saveConflict)
        try await deliverPendingUploads(for: reference, to: remote)
        XCTAssertTrue(try Self.entryTitles(in: remote.currentBytes, password: fixturePassword)
            .isSuperset(of: ["Created in AutoFill", "Saved in App"]))
    }

    func testSessionStoreAdoptsTheAutoFillEntryWhenTheDrainReportsTheDatabase() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-A")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        defer { vm.lock() }
        let store = DatabaseSessionStore()
        store.adopt(vm)
        await vm.unlock(password: fixturePassword)
        try await saveThroughAutoFill(title: "Created in AutoFill", reference: reference)

        store.refreshPendingUploads(for: [reference.id])

        for _ in 0..<300 where !entryTitles(in: vm).contains("Created in AutoFill") {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(entryTitles(in: vm).contains("Created in AutoFill"))
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertTrue(vm.hasPendingCloudUploads, "The change is open here but still queued for upload")
    }

    func testSyncNowWithAQueuedAutoFillChangeReportsItWaitingInsteadOfAConflict() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-A")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        try await saveThroughAutoFill(title: "Created in AutoFill", reference: reference)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let autoFillBytes = try Data(contentsOf: cacheURL)

        await vm.syncCloudNow()

        XCTAssertNil(vm.saveConflict, "A queued upload on an unchanged cloud copy is not a conflict")
        XCTAssertEqual(vm.cloudSyncOutcome, .uploadsPending)
        XCTAssertTrue(entryTitles(in: vm).contains("Created in AutoFill"))
        XCTAssertEqual(try Data(contentsOf: cacheURL), autoFillBytes)
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).count, 1)
        XCTAssertEqual(remote.currentBytes, openedData)
        XCTAssertTrue(CloudSyncControls.showsWarning(for: vm))
        XCTAssertFalse(CloudSyncControls.showsPendingUploadDetail(for: vm), "The result already says it is waiting")
        try await deliverPendingUploads(for: reference, to: remote)
        XCTAssertEqual(remote.currentBytes, autoFillBytes)
    }

    func testSyncNowHandsAQueuedAutoFillChangeToTheDrainerAndOpensIt() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-A")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        defer { vm.lock() }
        vm.pendingUploadDrain = { [unowned self] reference in
            try? await self.deliverPendingUploads(for: reference, to: remote)
        }
        await vm.unlock(password: fixturePassword)
        try await saveThroughAutoFill(title: "Created in AutoFill", reference: reference)

        await vm.syncCloudNow()

        XCTAssertNil(vm.saveConflict)
        XCTAssertEqual(vm.cloudSyncOutcome, .updated)
        XCTAssertTrue(try PendingUploadQueue.readJournal(for: reference.id).isEmpty)
        XCTAssertTrue(try Self.entryTitles(in: remote.currentBytes, password: fixturePassword).contains("Created in AutoFill"))
        XCTAssertTrue(entryTitles(in: vm).contains("Created in AutoFill"))
        XCTAssertFalse(vm.hasPendingCloudUploads)
    }

    func testChangedCacheNeverReplacesUnsavedWork() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-A")
        let vm = makeViewModelOnTheRealCache(reference: reference, remote: remote)
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        try await saveThroughAutoFill(title: "Created in AutoFill", reference: reference)
        try vm.applyEntryEdit(.createEntry(parentGroupID: XCTUnwrap(vm.visibleRootGroupID),
            draft: EntryDraftPayload(title: "Unsaved", password: "p")))

        let adopted = await vm.adoptChangedCloudCacheIfPossible()

        XCTAssertFalse(adopted)
        XCTAssertTrue(vm.isDirty)
        XCTAssertTrue(vm.currentRootGroup?.allEntries.contains { $0.title == "Unsaved" } == true)
        XCTAssertFalse(vm.currentRootGroup?.allEntries.contains { $0.title == "Created in AutoFill" } == true)
    }

    /// Saves a new entry the way the AutoFill extension does: into the shared
    /// cached copy, queueing its upload.
    private func saveThroughAutoFill(title: String, reference: DatabaseReference) async throws {
        let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        let cacheData = try Data(contentsOf: DatabaseListStore.cacheLocation(for: stored))
        let key = try KDBXTestFixture.test.compositeKey(in: Bundle(for: Self.self))
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: cacheData, compositeKey: key, sessionKey: sessionKey)
        var environment = AutoFillSaveCoordinator.Environment.live
        environment.populateCredentialStore = { _, _ in }
        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(title: title, username: "autofill", password: "secret", url: "https://example.com"),
            reference: stored, rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey,
            compositeKey: key, openTimeSHA512: FileDigest.sha512(cacheData), environment: environment)
        guard case .saved(let outcome) = result, outcome.enqueuedPendingUpload else {
            XCTFail("The AutoFill save must land in the cache with a queued upload: \(result)")
            throw SaveError.saveContextUnavailable
        }
        XCTAssertEqual(try PendingUploadQueue.readJournal(for: reference.id).count, 1)
    }

    private func deliverPendingUploads(for reference: DatabaseReference, to remote: InMemoryRemoteProvider) async throws {
        var delivery = CloudDatabaseSaver.Environment.live
        delivery.beginBackgroundTask = { _ in .invalid }
        delivery.endBackgroundTask = { _ in }
        delivery.getMetadata = { _ in remote.currentMetadata }
        delivery.downloadRemoteData = { _ in remote.currentBytes }
        delivery.upload = { _, data, rev, _ in try remote.store(data, expectedRev: rev) }
        for marker in try PendingUploadQueue.readJournal(for: reference.id) {
            let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
            guard case .saved? = try await CloudDatabaseSaver.deliver(marker, reference: stored, environment: delivery) else {
                XCTFail("The queued upload must deliver")
                throw SaveError.saveContextUnavailable
            }
        }
    }

    func testSettingThePolicyFromTheSessionPersistsIt() async throws {
        let reference = try makeStoredManualReference()
        let vm = makeViewModel(reference: reference, openedData: try fixtureData())

        vm.setCloudSyncPolicy(.onOpen)

        XCTAssertEqual(vm.databaseReference.cloudSyncPolicy, .onOpen)
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == reference.id })?.cloudSyncPolicy, .onOpen)
    }

    /// The sync controls are the one place a cloud database warns, so an open
    /// that fell back to the cached copy has to show there too.
    func testOpenFromTheCachedCopyWarnsInTheSyncControls() async throws {
        var reference = try makeStoredManualReference()
        reference.cloudSyncPolicy = .onOpen
        DatabaseListStore.testUpsert(reference)
        let openedData = try fixtureData()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .offlineCached)
            }
        )
        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertNil(vm.cloudSyncOutcome)
        XCTAssertEqual(vm.cloudSyncBannerText, CloudSyncResolution.offlineCachedBannerMessage)
        XCTAssertTrue(CloudSyncControls.showsWarning(for: vm))
        XCTAssertEqual(CloudSyncControls.title(for: vm), CloudSyncResolution.offlineCachedBannerMessage)
    }

    func testSyncShortcutSurvivesChangingPolicyAfterACheckedOpen() async throws {
        var reference = try makeStoredManualReference()
        reference.cloudSyncPolicy = .onOpen
        DatabaseListStore.testUpsert(reference)
        let openedData = try fixtureData()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .current)
            }
        )
        await vm.unlock(password: fixturePassword)

        XCTAssertTrue(CloudSyncControls.isVisible(for: vm))
        XCTAssertFalse(CloudSyncControls.showsWarning(for: vm))
        vm.setCloudSyncPolicy(.manual)
        XCTAssertTrue(CloudSyncControls.isVisible(for: vm))
        XCTAssertFalse(vm.isCloudRefreshPending, "Changing future opens must not misreport this open")
        XCTAssertFalse(CloudSyncControls.showsWarning(for: vm))
        XCTAssertTrue(vm.canSyncCloudNow)
    }

    func testLocalDatabaseHasNoCloudSyncShortcut() throws {
        var reference = try makeStoredManualReference()
        reference.source = .local
        let vm = DatabaseViewModel(databaseReference: reference)
        XCTAssertFalse(CloudSyncControls.isVisible(for: vm))
    }

    /// The foreground refresh is the other automatic remote check. A manual
    /// database must skip it, so the credential store is populated only by
    /// the unlock itself.
    func testForegroundRefreshSkipsAManualPolicyDatabase() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference()
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let vm = makeViewModel(reference: reference, openedData: openedData)

        var populateCount = 0
        let unlockPopulate = expectation(description: "Unlock populates the credential store")
        let refreshPopulate = expectation(description: "Foreground refresh populates again")
        refreshPopulate.isInverted = true
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            populateCount += 1
            if populateCount == 1 {
                unlockPopulate.fulfill()
            } else {
                refreshPopulate.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)
        await fulfillment(of: [unlockPopulate], timeout: 30)
        vm.refreshSharedDatabaseCacheIfPossible()

        await fulfillment(of: [refreshPopulate], timeout: 2)
        XCTAssertEqual(populateCount, 1)
    }

    /// Reload after a save conflict must fetch the remote copy even for a
    /// manual database, or it reloads the stale cache and conflicts again.
    /// The account is not connected, so reaching the provider shows up as a
    /// recorded `notAuthenticated` issue; a skipped refresh would record none.
    func testReloadAfterConflictChecksTheCloudEvenUnderTheManualPolicy() async throws {
        let openedData = try fixtureData()
        let reference = try makeStoredManualReference(provider: .webDAV)
        try DatabaseListStore.cacheDatabaseCopy(openedData, for: reference)
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .refreshSkipped)
            }
        )
        await vm.unlock(password: fixturePassword)
        XCTAssertNil(vm.databaseReference.cloudSyncMetadata?.lastSyncIssue)

        try await vm.reloadDiscardingDraft()

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertEqual(vm.databaseReference.cloudSyncMetadata?.lastSyncIssue, .notAuthenticated)
        XCTAssertTrue(vm.isCloudRefreshPending, "The provider was not reached")
    }

    func testImportStagedWhileSyncNowReplacesTheTreeReportsAChangeNotALock() async throws {
        let gate = InFlightSaveGate()
        let newerData = try fixtureData(named: "kitchen-sink")
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: try fixtureData(),
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: newerData, status: .downloaded)
            },
            cloudSaveOperation: { _, _, _, _, _, _, _, _ in
                XCTFail("entries built on the replaced tree must not be saved")
                throw CloudProviderError.networkUnavailable
            },
            importStagingOperation: { base, drafts, groupID in
                await gate.parkFirstCall()
                return try await DatabaseViewModel.stageImportedEntries(base, drafts, groupID)
            }
        )
        await vm.unlock(password: fixturePassword)
        let groupID = try XCTUnwrap(vm.visibleRootGroupID)
        let csv = """
        Title,URL,Username,Password
        Imported During Sync,https://imported.example,me,secret

        """
        let drafts = try ApplePasswordsCSVImporter.preview(from: Data(csv.utf8)).items.map(\.draft)
        let importTask = Task { try await vm.importEntries(drafts, into: groupID) }
        do {
            try await gate.firstCallStarted(for: importTask)

            // The staged entries come back while the fetched copy is parsed.
            let parsing = triggerWhenParsing(vm) {
                Task { await gate.releaseFirstCall() }
            }
            let sync = Task { await vm.syncCloudNow() }
            do {
                _ = try await importTask.value
                XCTFail("entries built on the replaced tree must not be staged")
            } catch {
                XCTAssertEqual(
                    error as? DatabaseViewModel.PasswordImportFailure,
                    .databaseChanged,
                    "a tree being replaced is a change, not a locked session"
                )
            }
            await sync.value
            let triggered = await parsing.value

            XCTAssertTrue(triggered)
            XCTAssertEqual(vm.cloudSyncOutcome, .updated)
            XCTAssertEqual(vm.state, .unlocked)
            XCTAssertNil(vm.draft)
            XCTAssertFalse(entryTitles(in: vm).contains("Imported During Sync"))
        } catch {
            await gate.releaseFirstCall()
            _ = await importTask.result
            throw error
        }
    }

    // MARK: - Helpers

    private func makeViewModel(
        reference: DatabaseReference,
        openedData: Data,
        cloudRefreshOperation: @escaping DatabaseViewModel.CloudSyncOperation = { _, _ in
            throw CloudProviderError.networkUnavailable
        },
        cloudSaveOperation: @escaping DatabaseViewModel.CloudSaveOperation = { _, _, _, _, _, _, _, _ in
            throw CloudProviderError.networkUnavailable
        },
        localPublicationFailure: @escaping @Sendable (String, Error) -> Void = { _, _ in },
        pendingUploadMarkerCheck: @escaping DatabaseViewModel.PendingUploadMarkerCheck = { _ in false },
        importStagingOperation: @escaping DatabaseViewModel.ImportStagingOperation = DatabaseViewModel.stageImportedEntries
    ) -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .refreshSkipped)
            },
            cloudRefreshOperation: cloudRefreshOperation,
            localPublicationFailure: localPublicationFailure,
            cloudSaveOperation: cloudSaveOperation,
            pendingUploadMarkerCheck: pendingUploadMarkerCheck,
            importStagingOperation: importStagingOperation
        )
    }

    /// The production coordinator and saver on the shared cache, with only
    /// the provider transport replaced by `remote`.
    private func makeViewModelOnTheRealCache(
        reference: DatabaseReference,
        remote: InMemoryRemoteProvider,
        beforeSave: @escaping @Sendable () async -> Void = {},
        onRefresh: @escaping @Sendable (DatabaseReference) -> Void = { _ in }
    ) -> DatabaseViewModel {
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = { _ in remote.currentMetadata }
        environment.upload = { _, data, expectedRev, _ in try remote.store(data, expectedRev: expectedRev) }
        environment.downloadRemoteData = { _ in remote.currentBytes }
        let saverEnvironment = environment
        return DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, progress in
                try await CloudSyncCoordinator.syncIfNeededForOpen(
                    reference: reference,
                    providerResolver: { _ in remote },
                    progress: progress
                )
            },
            cloudRefreshOperation: { reference, progress in
                onRefresh(reference)
                return try await CloudSyncCoordinator.syncIfNeededForOpen(
                    reference: reference,
                    honorsManualSyncPolicy: false,
                    providerResolver: { _ in remote },
                    progress: progress
                )
            },
            cloudSaveOperation: { draft, reference, compositeKey, openTimeSHA512, reconciledRemoteSHA512, expectedRev, newCompositeKey, encryptionSettings in
                await beforeSave()
                return try await CloudDatabaseSaver.save(
                    draft: draft,
                    reference: reference,
                    compositeKey: compositeKey,
                    openTimeSHA512: openTimeSHA512,
                    reconciledRemoteSHA512: reconciledRemoteSHA512,
                    expectedRev: expectedRev,
                    kdfPolicy: .mainApp,
                    newCompositeKey: newCompositeKey,
                    encryptionSettings: encryptionSettings,
                    environment: saverEnvironment
                )
            }
        )
    }

    private func makeViewModelParsingANewerCopy() async throws -> DatabaseViewModel {
        let newerData = try fixtureData(named: "kitchen-sink")
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: try fixtureData(),
            cloudRefreshOperation: { reference, _ in
                Self.resolution(reference, data: newerData, status: .downloaded)
            }
        )
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.state, .unlocked)
        return vm
    }

    /// Runs `trigger` on the main actor as soon as Sync Now has moved to
    /// `.unlocking`, i.e. while the fetched copy is parsed off the main actor.
    private func triggerWhenParsing(
        _ vm: DatabaseViewModel,
        _ trigger: @escaping @MainActor () -> Void
    ) -> Task<Bool, Never> {
        Task { @MainActor in
            while Task.isCancelled == false {
                if vm.state == .unlocking {
                    trigger()
                    return true
                }
                if vm.cloudSyncOutcome != nil {
                    return false
                }
                await Task.yield()
            }
            return false
        }
    }

    private func assertLockedAfterSync(
        _ vm: DatabaseViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(vm.state, .locked, file: file, line: line)
        XCTAssertNil(vm.rootGroup, file: file, line: line)
        XCTAssertNil(vm.sessionKey, file: file, line: line)
        XCTAssertNil(vm.openTimeSHA512, file: file, line: line)
        XCTAssertNil(vm.cloudSyncOutcome, file: file, line: line)
        XCTAssertFalse(vm.isSyncingCloud, file: file, line: line)
    }

    private struct WaitTimedOut: Error {}

    nonisolated private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        var remainingPolls = 500
        while condition() == false {
            guard remainingPolls > 0 else { throw WaitTimedOut() }
            remainingPolls -= 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated private static func resolution(
        _ reference: DatabaseReference,
        data: Data,
        status: CloudSyncResolution.Status
    ) -> CloudSyncResolution {
        CloudSyncResolution(
            reference: reference,
            localURL: DatabaseListStore.cacheLocation(for: reference),
            data: data,
            status: status
        )
    }

    private func makeStoredManualReference(
        provider: CloudProviderKind = .dropbox,
        fileID: String = "/Vaults/manual.kdbx",
        autoFillEnabled: Bool = true
    ) throws -> DatabaseReference {
        let file = CloudFile(
            id: fileID,
            name: URL(fileURLWithPath: fileID).lastPathComponent,
            path: fileID,
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 100),
            size: 128
        )
        var reference = try! DatabaseListStore.addCloud(provider: provider.rawValue, accountId: "acct-1", file: file)
        reference.cloudSyncPolicy = .manual
        reference.autoFillEnabled = autoFillEnabled
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-A"
            metadata.lastSyncedAt = Date(timeIntervalSince1970: 1_000)
        }
        DatabaseListStore.testUpsert(reference)
        return reference
    }

    private func entryTitles(in vm: DatabaseViewModel) -> Set<String> {
        Set(vm.rootGroup?.allEntries.map(\.title) ?? [])
    }

    private static func entryTitles(in data: Data, password: String) throws -> Set<String> {
        let parsed = try KDBXParser.parseWithMeta(data: data, password: password, sessionKey: SymmetricKey(size: .bits256))
        return Set(parsed.rootGroup.allEntries.map(\.title))
    }

    private func fixtureData(named name: String = "test") throws -> Data {
        try Self.bundledFixtureData(named: name)
    }

    nonisolated private static func bundledFixtureData(named name: String) throws -> Data {
        try Data(contentsOf: TestDatabaseSupport.fixtureURL(
            named: name,
            bundle: Bundle(for: DatabaseViewModelCloudSyncTests.self)
        ))
    }
}

private final class RefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DatabaseReference] = []

    var references: [DatabaseReference] {
        lock.withLock { recorded }
    }

    func record(_ reference: DatabaseReference) {
        lock.withLock { recorded.append(reference) }
    }
}

/// A remote file with real revision semantics: uploads check `expectedRev`
/// and mint a new revision. `holdNextDownload` parks one download after it
/// has read the remote bytes, the way a slow transfer delivers what was there
/// when it started.
private final class InMemoryRemoteProvider: CloudProvider, @unchecked Sendable {
    let id = CloudProviderKind.dropbox.rawValue
    let displayName = CloudProviderKind.dropbox.displayName
    let iconName = CloudProviderKind.dropbox.iconName

    private let lock = NSLock()
    private var bytes: Data
    private var rev: String
    private var uploadCount = 0
    private var downloadGate: SaveGate?

    init(bytes: Data, rev: String) {
        self.bytes = bytes
        self.rev = rev
    }

    var currentBytes: Data {
        lock.withLock { bytes }
    }

    var currentMetadata: CloudFileMetadata {
        lock.withLock { Self.metadata(bytes: bytes, rev: rev) }
    }

    func holdNextDownload(on gate: SaveGate) {
        lock.withLock { downloadGate = gate }
    }

    func store(_ data: Data, expectedRev: String?) throws -> CloudFileMetadata {
        try lock.withLock {
            if let expectedRev, expectedRev != rev {
                throw CloudProviderError.conflict(remoteRev: rev)
            }
            uploadCount += 1
            bytes = data
            rev = "rev-upload-\(uploadCount)"
            return Self.metadata(bytes: bytes, rev: rev)
        }
    }

    @MainActor
    func authenticate(from anchor: ASPresentationAnchor) async throws -> CloudAccount {
        XCTFail("authenticate(from:) should not be called")
        throw CloudProviderError.authenticationCancelled
    }

    func isAuthenticated(accountId: String) -> Bool { true }

    func signOut(accountId: String) {}

    func listFiles(accountId: String, path: String?, query: String?, includesAllFiles: Bool) async throws -> [CloudFile] { [] }

    @discardableResult
    func download(
        accountId: String,
        fileId: String,
        to localURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata? {
        let (snapshot, gate) = lock.withLock { () -> ((Data, String), SaveGate?) in
            let gate = downloadGate
            downloadGate = nil
            return ((bytes, rev), gate)
        }
        if let gate {
            await gate.signalStarted()
            await gate.waitUntilOpen()
        }
        try snapshot.0.write(to: localURL)
        progress(1)
        return Self.metadata(bytes: snapshot.0, rev: snapshot.1)
    }

    func getMetadata(accountId: String, fileId: String) async throws -> CloudFileMetadata {
        currentMetadata
    }

    func upload(
        accountId: String,
        fileId: String,
        data: Data,
        expectedRev: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudFileMetadata {
        try store(data, expectedRev: expectedRev)
    }

    private static func metadata(bytes: Data, rev: String) -> CloudFileMetadata {
        CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 100),
            contentHash: nil,
            size: Int64(bytes.count),
            rev: rev
        )
    }
}

private final class ProgressHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@Sendable (Double) -> Void)?

    var handler: (@Sendable (Double) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
}

private final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class CloudPublicationTestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() -> Bool { semaphore.wait(timeout: .now() + 15) == .success }
    func release() { semaphore.signal() }
}
