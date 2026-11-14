import CryptoKit
import XCTest
import KDBXKit
@testable import KeeForge

/// AutoFill saves the Mac extension can only write to the shared copy (#182):
/// the store that keeps them, the save that records them, and the app-side
/// merge that carries them into the database file.
@MainActor
final class PendingLocalSaveTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        try await super.tearDown()
    }

    func testUnreadableSourceDoesNotHideHealthyExportAndCanBeDeliberatelyDiscarded() throws {
        let id = UUID()
        let blocked = try seedAcceptedSource(Data("blocked ciphertext".utf8), for: id)
        let healthy = try seedAcceptedSource(Data("healthy ciphertext".utf8), for: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.fileURL.path) }
        guard (try? Data(contentsOf: blocked.fileURL)) == nil else { throw XCTSkip("This host bypasses POSIX read denial") }
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries.filter { $0.receipt == nil }.count, 1)
        XCTAssertTrue(snapshot.needsRecovery)
        let receipt = try XCTUnwrap(snapshot.receipts.first)
        XCTAssertEqual(try PendingLocalSaveStore.export(receipt, for: id), Data("healthy ciphertext".utf8))
        try PendingLocalSaveStore.discard(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: healthy.fileURL.path))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: id))
    }

    func testUnreadableOwnerCanBeResolvedByItsExactIdentityWithoutReadingItsBytes() throws {
        let id = UUID()
        let source = try seedAcceptedSource(Data("encrypted".utf8), for: id)
        let owner = AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(id.uuidString)/owner.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: owner.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path) }
        guard (try? Data(contentsOf: owner)) == nil else { throw XCTSkip("This host bypasses POSIX read denial") }
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        XCTAssertTrue(snapshot.ownerUnavailable)
        XCTAssertEqual(try PendingLocalSaveStore.export(XCTUnwrap(snapshot.receipts.first), for: id), Data("encrypted".utf8))
        try PendingLocalSaveStore.discard(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: id))
    }

    func testSameCiphertextAtADifferentInodeDoesNotSatisfyReceiptOrDiscardConsent() throws {
        let id = UUID()
        let bytes = Data("same encrypted bytes".utf8)
        let source = try seedAcceptedSource(bytes, for: id)
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        let receipt = try XCTUnwrap(snapshot.receipts.first)
        try bytes.write(to: source.fileURL, options: .atomic)
        XCTAssertThrowsError(try PendingLocalSaveStore.export(receipt, for: id))
        XCTAssertThrowsError(try PendingLocalSaveStore.discard(snapshot))
        XCTAssertEqual(try Data(contentsOf: source.fileURL), bytes)
    }

    func testForegroundRefreshObservesAnExternalLegacySourceWhileTheSessionRemainsLocked() async throws {
        let id = UUID()
        let recovery = PendingLocalRecoveryViewModel(databaseID: id)
        await recovery.refresh()
        XCTAssertTrue(try XCTUnwrap(recovery.snapshot).entries.isEmpty)
        let directory = AppGroupContainer.url.appendingPathComponent("pending-local-saves/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Another process sends no Foundation NotificationCenter event to this process.
        try Data("external encrypted source".utf8).write(to: directory.appendingPathComponent("20261113-120000-000001.kdbx"))
        await recovery.becameActive()
        let snapshot = try XCTUnwrap(recovery.snapshot)
        XCTAssertEqual(snapshot.receipts.count, 1)
        XCTAssertEqual(try PendingLocalSaveStore.export(XCTUnwrap(snapshot.receipts.first), for: id), Data("external encrypted source".utf8))
    }

    func testCreatedPayloadAndOwnerFilesKeepPrivatePermissionsAndIOSCompleteProtection() throws {
        let id = UUID()
        let source = try seedAcceptedSource(Data("encrypted snapshot".utf8), for: id)
        XCTAssertFalse(try PendingLocalSaveStore.revokeForRemoval(id))
        let owner = AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(id.uuidString)")
        let files = [source.fileURL, owner.appendingPathComponent("owner.json"), owner.appendingPathComponent(".tombstone"), owner.appendingPathComponent(".lock")]
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file.lastPathComponent)
        }
        XCTAssertEqual(try Data(contentsOf: source.fileURL), Data("encrypted snapshot".utf8))
        #if os(iOS)
        func protection(_ file: URL) throws -> String? {
            let raw = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
            if let value = raw as? FileProtectionType { return value.rawValue }
            if let value = raw as? String { return value }
            guard raw == nil else { throw CocoaError(.fileReadCorruptFile) }
            return nil
        }
        let control = owner.appendingPathComponent("protection-control")
        defer { try? FileManager.default.removeItem(at: control) }
        try Data("independent complete protection".utf8).write(to: control, options: [.atomic, .completeFileProtection])
        let controlProtection = try protection(control)
        let actual = try files.map(protection)
        #if targetEnvironment(simulator)
        if controlProtection == nil, actual.allSatisfy({ $0 == nil }) {
            throw XCTSkip("Simulator exposes no protection attribute even for an independent complete-protection write; modes/bytes were verified, device class-A validation remains required")
        }
        #endif
        XCTAssertEqual(controlProtection, FileProtectionType.complete.rawValue)
        for (file, value) in zip(files, actual) { XCTAssertEqual(value, FileProtectionType.complete.rawValue, file.lastPathComponent) }
        #endif
    }

    func testHealthyPendingSourcesAllowConflictReloadButAdmissionStillBlocksIt() throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: url)
        let bytes = try Data(contentsOf: url)
        let source = try seedAcceptedSource(bytes, for: reference.id)
        XCTAssertFalse(PendingLocalSaveStore.requiresConflictRecovery(for: reference))
        let snapshot = try PendingLocalSaveStore.recovery(for: reference.id)
        _ = try PendingLocalSaveStore.admit(snapshot.receipts, for: reference.id,
            target: LocalDatabaseSaver.captureTarget(for: reference), baseline: FileDigest.sha512(bytes), masterKeyChangedAt: nil)
        XCTAssertTrue(PendingLocalSaveStore.requiresConflictRecovery(for: reference))
        XCTAssertEqual(try Data(contentsOf: source.fileURL), bytes)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testExclusiveSourceIdentityNeverReplacesAnExistingSnapshot() throws {
        let id = UUID()
        let sourceID = UUID()
        let first = try seedAcceptedSource(Data("A".utf8), for: id, sourceID: sourceID)
        XCTAssertThrowsError(try seedAcceptedSource(Data("B".utf8), for: id, sourceID: sourceID))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("A".utf8))
        XCTAssertEqual(PendingLocalSaveStore.saves(for: id).count, 1)
    }

    func testReceiptExportAndDiscardRefuseAReplacedSource() throws {
        let id = UUID()
        let first = try seedAcceptedSource(Data("A".utf8), for: id)
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        let receipt = try XCTUnwrap(snapshot.receipts.first)
        try Data("B".utf8).write(to: first.fileURL, options: .atomic)
        XCTAssertThrowsError(try PendingLocalSaveStore.export(receipt, for: id))
        XCTAssertThrowsError(try PendingLocalSaveStore.discard(snapshot))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("B".utf8))
    }

    func testSnapshotDiscardKeepsSourcesAddedAfterConfirmation() throws {
        let id = UUID()
        let first = try seedAcceptedSource(Data("A".utf8), for: id)
        let confirmed = try PendingLocalSaveStore.recovery(for: id)
        let later = try seedAcceptedSource(Data("B".utf8), for: id)
        try PendingLocalSaveStore.discard(confirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: later.fileURL), Data("B".utf8))
        assertSavesEqual(PendingLocalSaveStore.saves(for: id), [later])
    }

    func testRevocationFencesAReplacementAndPreventsSourceAndReferenceResurrection() throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: url)
        let source = try seedAcceptedSource(Data("A".utf8), for: reference.id)
        let original = try Data(contentsOf: url)
        XCTAssertFalse(DatabaseListStore.remove(id: reference.id), "Ordinary removal is not consent to lose AutoFill changes")
        XCTAssertThrowsError(try LocalDatabaseSaver.replaceFileAtomically(
            Data("late replacement".utf8), at: url, expectedSHA512: FileDigest.sha512(original),
            authorization: .init(databaseID: reference.id)
        ))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try seedAcceptedSource(Data("late add".utf8), for: reference.id))
        XCTAssertEqual(try Data(contentsOf: source.fileURL), Data("A".utf8))
        try PendingLocalSaveStore.discard(PendingLocalSaveStore.recovery(for: reference.id))
        XCTAssertTrue(DatabaseListStore.remove(id: reference.id))
        DatabaseListStore.update(reference)
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
        XCTAssertThrowsError(try seedAcceptedSource(Data("stale add".utf8), for: reference.id))
    }

    func testUnknownOwnerVersionBlocksWritesButExactEncryptedExportAndExplicitDiscardRemainAvailable() throws {
        let id = UUID()
        let source = try seedAcceptedSource(Data("encrypted".utf8), for: id)
        let owner = AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(id.uuidString)/owner.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as? [String: Any])
        metadata["version"] = 999
        try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys).write(to: owner, options: .atomic)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: id))
        XCTAssertThrowsError(try seedAcceptedSource(Data("new".utf8), for: id))
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        XCTAssertTrue(snapshot.ownerUnavailable)
        let receipt = try XCTUnwrap(snapshot.receipts.first)
        XCTAssertEqual(try PendingLocalSaveStore.export(receipt, for: id), Data("encrypted".utf8))
        try PendingLocalSaveStore.discard(snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.fileURL.path))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: id))
    }

    func testLegacyTimestampSourceStillProducesAnExactReceiptAndExportWithoutUnlocking() throws {
        let id = UUID()
        let directory = AppGroupContainer.url.appendingPathComponent("pending-local-saves/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: makeScratchDatabaseCopy())
        let url = directory.appendingPathComponent("20261113-120000-000001.kdbx")
        try bytes.write(to: url, options: .atomic)
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        XCTAssertEqual(snapshot.receipts.count, 1)
        XCTAssertEqual(try PendingLocalSaveStore.export(XCTUnwrap(snapshot.receipts.first), for: id), bytes)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: id).first?.fileURL.lastPathComponent, url.lastPathComponent)
    }

    func testAcceptedPublicationSyncFailureDoesNotPretendNothingChanged() throws {
        let id = UUID()
        let cache = PendingLocalSaveStore.sharedCopyURL(for: id)
        let bytes = try Data(contentsOf: makeScratchDatabaseCopy())
        try writeAtomicallyAndDurably(bytes, to: cache, directoryAnchor: AppGroupContainer.url)
        let prepared = try PendingLocalSaveStore.prepareSource(bytes, for: id, baseCacheSHA512: FileDigest.sha512(bytes))
        var io = PendingLocalSaveStore.StorageIO()
        io.fileIO = { _ in
            var writer = DurableFileWriteIO()
            writer.afterPublication = { _ in throw POSIXError(.EIO) }
            return writer
        }
        XCTAssertEqual(PendingLocalSaveStore.activateSource(prepared, io: io), .acceptedWithoutConfirmedDurability)
        assertSavesEqual(PendingLocalSaveStore.saves(for: id), [prepared.save], "Publication is visible despite its failed flush")
        XCTAssertEqual(try PendingLocalSaveStore.export(prepared.receipt, for: id), bytes)
    }

    func testAdmittedCrashBlocksBothSessionsAndNewAutomaticSourcesWithoutCallingSaver() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: url)
        let original = try Data(contentsOf: url)
        _ = try seedAcceptedSource(original, for: reference.id)
        let receipt = try XCTUnwrap(PendingLocalSaveStore.recovery(for: reference.id).receipts.first)
        let token = try PendingLocalSaveStore.admit([receipt], for: reference.id,
            target: LocalDatabaseSaver.captureTarget(for: reference), baseline: FileDigest.sha512(original), masterKeyChangedAt: nil)
        _ = try seedAcceptedSource(original, for: reference.id)
        let attempts = PendingEffectCounter()
        for _ in 0..<2 {
            let vm = DatabaseViewModel(databaseReference: reference, localSaveOperation: { _, _, _, _, _, _, _ in
                attempts.increment(); throw SaveError.saveContextUnavailable
            })
            await vm.unlock(password: fixturePassword)
            for _ in 0..<3 { _ = await vm.mergePendingLocalSaves() }
            XCTAssertEqual(vm.pendingUploadMergeFailure, .localSourceRecovery)
            vm.lock()
        }
        XCTAssertEqual(attempts.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: reference.id).admission, token.admission)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 2)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testMergeRealPostReplaceWarningRetainsExactSourceAcrossActivationAndNewSession() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: url)
        let original = try Data(contentsOf: url)
        let source = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Retained Source")) }
        try seedPendingSave(source, for: reference)
        let originalReceipt = try XCTUnwrap(PendingLocalSaveStore.recovery(for: reference.id).receipts.first)
        let encryptions = PendingEffectCounter()
        let replacements = PendingEffectCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.increment(); return try live.encryptDraft(draft, key, header, policy)
        }
        environment.replaceFileAtomically = { bytes, target, baseline, authorization in
            replacements.increment()
            var io = LocalDatabaseSaver.ReplacementIO()
            io.synchronize = { _ in throw POSIXError(.EIO) }
            return try LocalDatabaseSaver.replaceFileAtomically(bytes, at: target, expectedSHA512: baseline, authorization: authorization, io: io)
        }
        let configured = environment
        let operation: DatabaseViewModel.LocalSaveOperation = { draft, reference, key, baseline, reconciled, newKey, settings in
            try await LocalDatabaseSaver.save(draft: draft, reference: reference, compositeKey: key,
                openTimeSHA512: baseline, reconciledRemoteSHA512: reconciled, kdfPolicy: .mainApp,
                newCompositeKey: newKey, encryptionSettings: settings, environment: configured)
        }
        let first = DatabaseViewModel(databaseReference: reference, localSaveOperation: operation)
        await first.unlock(password: fixturePassword)
        let installed = try Data(contentsOf: url)
        XCTAssertTrue(try entryTitles(in: installed).contains("Retained Source"))
        XCTAssertEqual(first.openTimeSHA512, FileDigest.sha512(installed))
        XCTAssertEqual(first.pendingUploadMergeFailure, .localSaveDurability)
        for _ in 0..<3 { _ = await first.mergePendingLocalSaves() }
        first.lock()
        let second = DatabaseViewModel(databaseReference: reference, localSaveOperation: operation)
        await second.unlock(password: fixturePassword)
        _ = await second.mergePendingLocalSaves()
        second.lock()
        XCTAssertEqual(encryptions.count, 1)
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(try PendingLocalSaveStore.export(originalReceipt, for: reference.id), source)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
        let consent = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertEqual(try PendingLocalSaveStore.discard(consent), .resolved)
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: url), installed)
        XCTAssertEqual(encryptions.count, 1)
    }

    func testDurableMergeClearPublishedWithoutFlushCannotResendConsumedReceipts() async throws {
        let setup = try makeAdmittedSave()
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(_, _, let optionalCommit) = result else { return XCTFail("Expected durable replacement") }
        let commit = try XCTUnwrap(optionalCommit)
        let ownerURL = ownerRecordURL(for: setup.reference.id)
        let oldCheckpoint = try Data(contentsOf: ownerURL)
        let later = try seedAcceptedSource(setup.original, for: setup.reference.id)
        var io = PendingLocalSaveStore.StorageIO()
        io.fileIO = { _ in
            var writer = DurableFileWriteIO()
            writer.afterPublication = { _ in throw POSIXError(.EIO) }
            return writer
        }
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(commit, reference: setup.reference, io: io), .resolvedVisibleWithoutConfirmedDurability)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: setup.reference.id).admission)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.source.fileURL.path))
        assertSavesEqual(PendingLocalSaveStore.saves(for: setup.reference.id), [later])
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(commit, reference: setup.reference), .retainedForRecovery, "A stale callback cannot resolve a new state")
        // A crash can revive the old checkpoint, but its durably removed sources stay missing.
        try writeAtomicallyAndDurably(oldCheckpoint, to: ownerURL)
        let restarted = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertTrue(restarted.needsRecovery)
        XCTAssertTrue(restarted.entries.contains { $0.receipt == nil })
        XCTAssertEqual(try Data(contentsOf: later.fileURL), setup.original)
    }

    func testMergeCompletionKeepsBookmarkScopeThroughSourceRetirementAndRealCacheRefresh() async throws {
        let setup = try makeAdmittedSave()
        let cache = DatabaseListStore.cacheLocation(for: setup.reference)
        DatabaseListStore.update(setup.reference)
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setup.original.write(to: cache, options: .atomicProtected)
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(_, _, let optionalCommit) = result else { return XCTFail("Expected durable merge output") }
        let commit = try XCTUnwrap(optionalCommit)
        let installed = try Data(contentsOf: XCTUnwrap(LocalDatabaseSaver.resolveLocation(for: setup.reference)).url)
        XCTAssertEqual(FileDigest.sha512(installed), commit.sha512)
        XCTAssertEqual(try Data(contentsOf: cache), setup.original)
        let observations = ScopeObservations()
        var scope = LocalDatabaseSaver.SecurityScopeIO()
        // This observes grant lifetime; a temporary file does not prove a signed sandbox grant.
        scope.begin = { url in
            let depth = observations.begin()
            XCTAssertEqual(FileManager.default.fileExists(atPath: setup.source.fileURL.path), depth == 1,
                "The outer grant must precede retirement and remain open for the nested cache publication")
            XCTAssertEqual(try? PendingLocalSaveStore.targetIdentity(at: url), commit.installedTarget)
            return true
        }
        scope.end = { _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.source.fileURL.path))
            XCTAssertEqual(try? Data(contentsOf: cache), installed)
            observations.end()
        }
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(commit, reference: setup.reference, scopeIO: scope), .resolved)
        XCTAssertEqual(observations.events, ["begin:1", "begin:2", "end:2", "end:1"])
        XCTAssertEqual(try Data(contentsOf: cache), installed)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: setup.reference.id).admission)
    }

    private final class ScopeObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var depth = 0
        private var values: [String] = []
        var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
        func begin() -> Int { lock.lock(); defer { lock.unlock() }; depth += 1; values.append("begin:\(depth)"); return depth }
        func end() { lock.lock(); defer { lock.unlock() }; values.append("end:\(depth)"); depth -= 1 }
    }

    func testConsumeUnlinkThenDirectoryFailureRetainsAdmissionAndLaterSource() async throws {
        let setup = try makeAdmittedSave()
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(_, _, let optionalCommit) = result else { return XCTFail("Expected durable replacement") }
        let later = try seedAcceptedSource(setup.original, for: setup.reference.id)
        var io = PendingLocalSaveStore.StorageIO()
        io.synchronize = { _ in throw POSIXError(.EIO) }
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(try XCTUnwrap(optionalCommit), reference: setup.reference, io: io), .retainedForRecovery)
        let restarted = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertEqual(restarted.admission?.operationID, setup.token.admission.operationID)
        XCTAssertTrue(restarted.needsRecovery)
        XCTAssertEqual(try Data(contentsOf: later.fileURL), setup.original)
    }

    private func ownerRecordURL(for id: UUID) -> URL {
        AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(id.uuidString)/owner.json")
    }

    private func makeAdmittedSave(sourceCount: Int = 1) throws -> (reference: DatabaseReference, original: Data,
        source: PendingLocalSaveStore.PendingSave, sources: [PendingLocalSaveStore.PendingSave], token: PendingLocalSaveStore.Token, context: SaveContext) {
        let url = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: url)
        let original = try Data(contentsOf: url)
        let sources = try (0..<sourceCount).map { index in
            try seedAcceptedSource(original, for: reference.id, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
        }
        let receipts = try PendingLocalSaveStore.recovery(for: reference.id).receipts
        let token = try PendingLocalSaveStore.admit(receipts, for: reference.id,
            target: LocalDatabaseSaver.captureTarget(for: reference), baseline: FileDigest.sha512(original), masterKeyChangedAt: nil)
        return (reference, original, try XCTUnwrap(sources.first), sources, token, try makeDirtySaveContext(data: original, entryTitle: "Merged Output"))
    }

    func testParentAliasDoesNotAuthorizeExportOrDiscardOfTheMovedSource() throws {
        let id = UUID()
        let bytes = Data("exact source".utf8)
        let source = try seedAcceptedSource(bytes, for: id)
        let snapshot = try PendingLocalSaveStore.recovery(for: id)
        let parent = source.fileURL.deletingLastPathComponent()
        let moved = parent.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        XCTAssertThrowsError(try PendingLocalSaveStore.export(XCTUnwrap(snapshot.receipts.first), for: id))
        XCTAssertThrowsError(try PendingLocalSaveStore.discard(snapshot))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(source.fileURL.lastPathComponent)), bytes)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: id))
    }

    func testRemovalListWriteFailureKeepsReferenceButDurablyRevokesLateWriters() throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: url)
        _ = try PendingLocalSaveStore.recovery(for: reference.id)
        let root = AppGroupContainer.url
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path) }
        guard !FileManager.default.isWritableFile(atPath: root.path) else { throw XCTSkip("Host bypasses POSIX write denial") }
        XCTAssertFalse(DatabaseListStore.remove(id: reference.id))
        let list = try JSONDecoder().decode([DatabaseReference].self,
            from: Data(contentsOf: root.appendingPathComponent("database-list.json")))
        XCTAssertTrue(list.contains { $0.id == reference.id })
        XCTAssertTrue(PendingLocalSaveStore.isRevoked(reference.id))
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try LocalDatabaseSaver.replaceFileAtomically(Data("late".utf8), at: url,
            expectedSHA512: FileDigest.sha512(original), authorization: .init(databaseID: reference.id)))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testRealStagingFailureReleasesAdmissionForOneExplicitSuccessfulRetry() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: url)
        let original = try Data(contentsOf: url)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Retry After Proven Failure")) }
        try seedPendingSave(pending, for: reference)
        let attempts = PendingEffectCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.replaceFileAtomically = { data, target, baseline, authorization in
            attempts.increment()
            var io = LocalDatabaseSaver.ReplacementIO()
            if attempts.count == 1 {
                io.stage = { bytes, staging in
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    try writeAtomicallyAndDurably(bytes, to: staging)
                }
            }
            return try LocalDatabaseSaver.replaceFileAtomically(data, at: target, expectedSHA512: baseline, authorization: authorization, io: io)
        }
        let configured = environment
        let vm = DatabaseViewModel(databaseReference: reference, localSaveOperation: { draft, ref, key, hash, reconciled, newKey, settings in
            try await LocalDatabaseSaver.save(draft: draft, reference: ref, compositeKey: key,
                openTimeSHA512: hash, reconciledRemoteSHA512: reconciled, kdfPolicy: .mainApp,
                newCompositeKey: newKey, encryptionSettings: settings, environment: configured)
        })
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: reference.id).admission)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
        _ = await vm.mergePendingLocalSaves()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertTrue(try entryTitles(in: Data(contentsOf: url)).contains("Retry After Proven Failure"))
        vm.lock()
    }

    func testTargetChangedAfterDurableReplacePreventsReceiptConsumption() async throws {
        let setup = try makeAdmittedSave()
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(_, _, let receipt) = result else { return XCTFail("Expected durable replacement") }
        let target = try XCTUnwrap(DatabaseListStore.resolveDatabaseURL(for: setup.reference))
        try setup.original.write(to: target, options: .atomic)
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(try XCTUnwrap(receipt), reference: setup.reference), .retainedForRecovery)
        XCTAssertEqual(try Data(contentsOf: setup.source.fileURL), setup.original)
        XCTAssertTrue(try PendingLocalSaveStore.recovery(for: setup.reference.id).needsRecovery)
    }

    func testPartialMultiSourceRetirementPreservesUnconsumedReceiptsAndAdmission() async throws {
        let setup = try makeAdmittedSave(sourceCount: 2)
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(_, _, let receipt) = result else { return XCTFail("Expected durable output") }
        let payloadRemovals = PendingEffectCounter()
        var io = PendingLocalSaveStore.StorageIO()
        io.remove = { url in
            if url.pathExtension == "kdbx" {
                payloadRemovals.increment()
                if payloadRemovals.count == 2 { throw POSIXError(.EIO) }
            }
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(try XCTUnwrap(receipt), reference: setup.reference, io: io), .retainedForRecovery)
        let admitted = setup.token.admission.sources
        let sourceDirectory = AppGroupContainer.url.appendingPathComponent("pending-local-saves/\(setup.reference.id.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.appendingPathComponent(admitted[0].relativePath).path))
        XCTAssertEqual(try Data(contentsOf: sourceDirectory.appendingPathComponent(admitted[1].relativePath)), setup.original)
        let restarted = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertEqual(restarted.admission?.operationID, setup.token.admission.operationID)
        XCTAssertTrue(restarted.needsRecovery)
        XCTAssertEqual(restarted.admission?.sources.count, 2)
    }

    func testOldCompletionCannotClearANewerAdmissionWithDifferentCapturedSources() async throws {
        let setup = try makeAdmittedSave()
        let result = try await PendingLocalSaveStore.$saveToken.withValue(setup.token) {
            try await LocalDatabaseSaver.save(draft: setup.context.draft, reference: setup.reference,
                compositeKey: setup.context.compositeKey, openTimeSHA512: FileDigest.sha512(setup.original))
        }
        guard case .saved(let sha, _, let optionalReceipt) = result else { return XCTFail("Expected durable output") }
        let receipt = try XCTUnwrap(optionalReceipt)
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(receipt, reference: setup.reference), .resolved)
        let later = try seedAcceptedSource(setup.original, for: setup.reference.id)
        let captured = try XCTUnwrap(PendingLocalSaveStore.recovery(for: setup.reference.id).receipts.first)
        let next = try PendingLocalSaveStore.admit([captured], for: setup.reference.id,
            target: LocalDatabaseSaver.captureTarget(for: setup.reference), baseline: sha, masterKeyChangedAt: nil)
        XCTAssertEqual(LocalDatabaseSaver.completePendingMerge(receipt, reference: setup.reference), .retainedForRecovery)
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: setup.reference.id).admission?.operationID, next.admission.operationID)
        XCTAssertEqual(try Data(contentsOf: later.fileURL), setup.original)
    }

    // MARK: - Store

    func testAddKeepsEncryptedBytesUnderTheGroupContainerOldestFirst() throws {
        let databaseID = UUID()
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)

        let second = try seedAcceptedSource(Data("second".utf8), for: databaseID, now: earlier.addingTimeInterval(60))
        let first = try seedAcceptedSource(Data("first".utf8), for: databaseID, now: earlier)

        assertSavesEqual(PendingLocalSaveStore.saves(for: databaseID), [first, second])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("second".utf8))
        XCTAssertTrue(PendingLocalSaveStore.saves(for: UUID()).isEmpty)

        let containerPath = normalizedPath(AppGroupContainer.url)
        for save in [first, second] {
            XCTAssertTrue(normalizedPath(save.fileURL).hasPrefix(containerPath))
            XCTAssertEqual(save.fileURL.pathExtension, "kdbx", "Only .kdbx payloads may be written to the group container")
        }
    }

    func testAddNeverReplacesASaveMadeAtTheSameInstant() throws {
        let databaseID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try seedAcceptedSource(Data("first".utf8), for: databaseID, now: now)
        let second = try seedAcceptedSource(Data("second".utf8), for: databaseID, now: now)

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        assertSavesEqual(PendingLocalSaveStore.saves(for: databaseID), [first, second])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
    }

    func testReferenceRemovalRequiresSnapshotDiscardAndKeepsOtherDatabasesSources() throws {
        let reference = try DatabaseListStore.add(url: makeScratchDatabaseCopy())
        let kept = UUID()
        try seedAcceptedSource(Data("removed".utf8), for: reference.id)
        try seedAcceptedSource(Data("kept".utf8), for: kept)

        XCTAssertFalse(DatabaseListStore.remove(id: reference.id))
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
        try PendingLocalSaveStore.discard(PendingLocalSaveStore.recovery(for: reference.id))
        XCTAssertTrue(DatabaseListStore.remove(id: reference.id))

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: kept))
    }

    func testMoveToBackupsListsTheSaveAmongTheDatabaseBackups() throws {
        let reference = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        let save = try seedAcceptedSource(Data("unmergeable".utf8), for: reference.id)

        let backupURL = try PendingLocalSaveStore.moveToBackups(save, for: reference)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(
            DatabaseListStore.recentBackups(for: reference).map(\.lastPathComponent),
            [backupURL.lastPathComponent]
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), Data("unmergeable".utf8))
        XCTAssertTrue(DatabaseListStore.isRetainedBackup(backupURL))
        XCTAssertEqual(
            DatabaseExportService.backupDate(fromFilename: backupURL.lastPathComponent),
            DatabaseExportService.backupDate(fromFilename: save.fileURL.lastPathComponent),
            "Database Details dates a backup from its filename, and this one keeps the time of the AutoFill save"
        )
    }

    func testBackupRotationNeverRemovesASaveMovedToTheBackups() throws {
        let reference = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let save = try seedAcceptedSource(Data("unmergeable".utf8), for: reference.id, now: earlier)
        let retainedURL = try PendingLocalSaveStore.moveToBackups(save, for: reference)
        let backupDirectory = DatabaseListStore.databaseBackupDirectoryURL(for: reference)
        for offset in 1...7 {
            let name = LocalDatabaseSaver.backupFilename(for: earlier.addingTimeInterval(Double(offset) * 60))
            try Data("ordinary-\(offset)".utf8).write(to: backupDirectory.appendingPathComponent(name))
        }

        try DatabaseListStore.pruneBackups(for: reference, keeping: 5)

        let remaining = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(remaining.filter { DatabaseListStore.isRetainedBackup($0) == false }.count, 5)
        XCTAssertEqual(try Data(contentsOf: retainedURL), Data("unmergeable".utf8), "The oldest file, and the only copy of the save")

        try DatabaseListStore.pruneBackups(for: reference, keeping: 0)

        XCTAssertEqual(DatabaseListStore.recentBackups(for: reference).map(\.lastPathComponent), [retainedURL.lastPathComponent])
    }

    // MARK: - Saving to the shared copy

    /// The reported failure and its fix in one place: the Mac extension's
    /// sandbox denies the read of the bookmarked file, which is where the save
    /// used to go.
    func testSaveToTheSharedCopySucceedsWhereTheBookmarkedFileCannotBeOpened() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "New Passkey")

        var sandboxed = LocalDatabaseSaver.Environment.live
        let liveRead = sandboxed.readData
        let cachePath = normalizedPath(DatabaseListStore.cacheLocation(for: reference))
        sandboxed.readData = { url in
            guard normalizedPath(url) == cachePath else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try liveRead(url)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: sandboxed
            )
            XCTFail("A save aimed at the bookmarked file cannot succeed without access to it")
        } catch {
            let failure = try XCTUnwrap(error as? LocalSaveBeforeReplacementFailure)
            XCTAssertEqual((failure.underlying as? CocoaError)?.code, .fileReadNoPermission)
        }
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))

        sandboxed.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: sandboxed
        )

        guard case .saved(let newSHA512, _, _) = result else {
            return XCTFail("Expected the save to the shared copy to succeed")
        }
        let sharedCopy = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(FileDigest.sha512(sharedCopy), newSHA512)
        XCTAssertTrue(try entryTitles(in: sharedCopy).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "The bookmarked file is the app's to write")

        let pendingSaves = PendingLocalSaveStore.saves(for: reference.id)
        XCTAssertEqual(pendingSaves.count, 1)
        XCTAssertEqual(try pendingSaves.first.map { try Data(contentsOf: $0.fileURL) }, sharedCopy)

        let backups = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try backups.first.map { try Data(contentsOf: $0) }, original)
    }

    func testRealSharedCopyStagingFailureKeepsProvisionalCiphertextOutOfAutomaticMerge() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "Never Saved")

        var environment = LocalDatabaseSaver.Environment.live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
        environment.replaceFileAtomically = { data, url, baseline, authorization in
            var io = LocalDatabaseSaver.ReplacementIO()
            io.stage = { bytes, staging in
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                try writeAtomicallyAndDurably(bytes, to: staging)
            }
            return try LocalDatabaseSaver.replaceFileAtomically(data, at: url, expectedSHA512: baseline, authorization: authorization, io: io)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: environment
            )
            XCTFail("Expected the save to fail when the replace step throws")
        } catch {
            XCTAssertNotNil(error as? LocalSaveBeforeReplacementFailure)
        }

        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertTrue(PendingLocalSaveStore.saves(for: reference.id).isEmpty)
        let recovery = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertTrue(recovery.needsRecovery)
        let retained = try PendingLocalSaveStore.export(XCTUnwrap(recovery.receipts.first), for: reference.id)
        XCTAssertTrue(try entryTitles(in: retained).contains("Never Saved"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
    }

    func testSaveAgainstAChangedSharedCopyConflictsAndKeepsNoPendingSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let refreshed = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "App Refresh")) }
        try writeAtomicallyAndDurably(refreshed, to: DatabaseListStore.cacheLocation(for: reference), directoryAnchor: AppGroupContainer.url)
        let context = try makeDirtySaveContext(data: original, entryTitle: "Stale Save")

        var environment = LocalDatabaseSaver.Environment.live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        guard case .conflict = result else {
            return XCTFail("The shared copy changed after it was read, so the save must conflict")
        }
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), refreshed)
    }

    func testAnAppSaveLeavesTheSharedCopyAloneWhileASaveIsPending() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "App Edit")

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        guard case .saved = result else {
            return XCTFail("Expected the app save to succeed")
        }
        XCTAssertTrue(try entryTitles(in: try Data(contentsOf: databaseURL)).contains("App Edit"))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            pending,
            "AutoFill reads the shared copy, and the saved bytes do not hold the pending passkey"
        )
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
    }

    func testFailedCacheRefreshDoesNotDeleteAPendingAutoFillSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let context = try makeDirtySaveContext(data: original, entryTitle: "App Edit")
        var environment = LocalDatabaseSaver.Environment.live
        environment.cacheDatabaseCopy = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        guard case .saved = result else {
            return XCTFail("Expected the app save to succeed")
        }
        XCTAssertTrue(try entryTitles(in: try Data(contentsOf: databaseURL)).contains("App Edit"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), pending)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
    }

    func testAutoFillSaveOfABookmarkedDatabaseLandsWhereTheExtensionCanWrite() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        DatabaseListStore.update(reference)
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(data: original, password: fixturePassword, sessionKey: sessionKey)
        var environment = AutoFillSaveCoordinator.Environment.live
        environment.populateCredentialStore = { _, _ in }

        let result = try await AutoFillSaveCoordinator.saveNewEntry(
            draftPayload: EntryDraftPayload(title: "example.com", username: "alice", url: "https://example.com"),
            reference: reference,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(original),
            environment: environment
        )

        guard case .saved(let outcome) = result else {
            return XCTFail("Expected the AutoFill save to succeed")
        }
        let sharedCopy = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(FileDigest.sha512(sharedCopy), outcome.newSHA512)
        #if os(macOS)
        XCTAssertTrue(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: reference))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "The Mac extension cannot open the bookmarked file")
        XCTAssertEqual(
            try PendingLocalSaveStore.saves(for: reference.id).map { try Data(contentsOf: $0.fileURL) },
            [sharedCopy]
        )
        #else
        XCTAssertFalse(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: reference))
        XCTAssertEqual(try Data(contentsOf: databaseURL), sharedCopy, "The iOS extension writes the bookmarked file itself")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        #endif
    }

    #if os(macOS)
    func testOnlyBookmarkedLocalDatabasesAwaitWriteBackOnTheMac() throws {
        let bookmarked = try TestDatabaseSupport.makeReference(for: makeScratchDatabaseCopy())
        var appOnly = bookmarked
        appOnly.bookmarkData = nil

        XCTAssertTrue(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: bookmarked))
        XCTAssertFalse(
            LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: appOnly),
            "A database without a bookmark lives in the shared copy, which is its only file"
        )
        XCTAssertFalse(LocalDatabaseSaver.autoFillSavesAwaitWriteBack(for: makeCloudReference()))

        let location = try XCTUnwrap(LocalDatabaseSaver.Environment.autoFillExtension.resolveLocation(bookmarked))
        XCTAssertEqual(normalizedPath(location.url), normalizedPath(DatabaseListStore.cacheLocation(for: bookmarked)))
        XCTAssertTrue(location.awaitsWriteBack)
        XCTAssertFalse(location.usesSecurityScope)
    }
    #endif

    // MARK: - Merging into the database file

    func testUnlockMergesAPendingSaveIntoTheDatabaseFileAndRemovesIt() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        let saved = try Data(contentsOf: databaseURL)
        XCTAssertTrue(try entryTitles(in: saved).contains("New Passkey"))
        XCTAssertTrue(Set(try entryTitles(in: saved)).isSuperset(of: try entryTitles(in: original)))
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(vm.openTimeSHA512, FileDigest.sha512(saved))
        XCTAssertTrue(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), saved)
        XCTAssertTrue(
            try DatabaseListStore.recentBackups(for: reference).contains { try Data(contentsOf: $0) == original },
            "The file's previous bytes are backed up like any other save"
        )
        XCTAssertNil(vm.pendingUploadMergeFailure)
        XCTAssertNil(vm.saveError)
        XCTAssertFalse(vm.isSaving)
    }

    func testUnlockKeepsWhatTheFileGainedSinceTheSharedCopyWasTaken() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)
        try seedPendingSave(pending, for: reference)
        try seedAcceptedSource(pending, for: reference.id)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        let titles = try entryTitles(in: try Data(contentsOf: databaseURL))
        XCTAssertTrue(titles.contains("New Passkey"))
        XCTAssertTrue(titles.contains("Added In Another App"))
        XCTAssertEqual(titles.filter { $0 == "New Passkey" }.count, 1, "Merging the same save twice adds it once")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testUnlockLeavesTheSharedCopyAloneWhileASaveIsPending() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        var reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        reference.isReadOnly = true
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            pending,
            "Replacing the shared copy from the file would hide the save from AutoFill"
        )
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1, "A read-only session cannot merge")
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testUnlockWithoutAPendingSaveStillRefreshesTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        DatabaseListStore.update(reference)
        try writeAtomicallyAndDurably(Data("stale".utf8), to: DatabaseListStore.cacheLocation(for: reference), directoryAnchor: AppGroupContainer.url)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testAPendingSaveThatCannotBeOpenedMovesToTheBackupsAndIsReported() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let unreadable = Data("not-a-kdbx-file".utf8)
        try seedPendingSave(unreadable, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        let backupURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == unreadable }
        )
        guard case .changeUnreadable(.backup(let reportedURL))? = vm.pendingUploadMergeFailure else {
            return XCTFail("Expected the unreadable save to be reported, got \(String(describing: vm.pendingUploadMergeFailure))")
        }
        XCTAssertEqual(normalizedPath(reportedURL), normalizedPath(backupURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            original,
            "The shared copy follows the file again"
        )
    }

    func testAPendingSaveWithDivergedAttachmentsMovesToTheBackupsAndIsReported() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let diverged = try makeVariantData(
            of: original,
            binaryPoolFields: [Data([0x00]) + Data("attachment-bytes".utf8)]
        ) { visibleRoot in
            var entry = KPEntry(title: "Entry With Attachment")
            entry.attachments = [KPAttachment(name: "note.txt", ref: 0)]
            visibleRoot.entries.append(entry)
        }
        let mergeable = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(diverged, for: reference, now: Date(timeIntervalSince1970: 1_800_000_000))
        try seedAcceptedSource(mergeable, for: reference.id, now: Date(timeIntervalSince1970: 1_800_000_060))
        let trace = TestDatabaseSupport.LocalPublicationTrace()
        let vm = diagnosticViewModel(reference, trace: trace)
        defer { vm.lock() }

        await vm.unlock(password: fixturePassword)

        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        let backupURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == diverged }
        )
        guard case .attachmentsDivergedFromFile(let reportedURL)? = vm.pendingUploadMergeFailure else {
            return XCTFail("Expected the diverged save to be reported, got \(String(describing: vm.pendingUploadMergeFailure))")
        }
        XCTAssertEqual(normalizedPath(reportedURL), normalizedPath(backupURL))
        let titles = try entryTitles(in: try Data(contentsOf: databaseURL))
        XCTAssertTrue(titles.contains("New Passkey"), "One unmergeable save must not hold back the others")
        XCTAssertFalse(titles.contains("Entry With Attachment"))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            try Data(contentsOf: databaseURL),
            "diverged-cache-byte-comparison boundaries=" + trace.summary
        )
    }

    func testASaveMovedToTheBackupsSurvivesTheBackupRotationOfLaterSaves() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let diverged = try makeVariantData(
            of: original,
            binaryPoolFields: [Data([0x00]) + Data("attachment-bytes".utf8)]
        ) { visibleRoot in
            var entry = KPEntry(title: "Only Copy Of This Passkey")
            entry.attachments = [KPAttachment(name: "note.txt", ref: 0)]
            visibleRoot.entries.append(entry)
        }
        try seedPendingSave(diverged, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let retainedURL = try XCTUnwrap(
            DatabaseListStore.recentBackups(for: reference).first { (try? Data(contentsOf: $0)) == diverged }
        )

        for index in 1...6 {
            vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Later Edit \(index)")
            try await vm.save()
        }

        XCTAssertEqual(
            try entryTitles(in: try Data(contentsOf: databaseURL)).filter { $0.hasPrefix("Later Edit") }.count,
            6
        )
        let backups = DatabaseListStore.recentBackups(for: reference)
        XCTAssertEqual(backups.filter { DatabaseListStore.isRetainedBackup($0) == false }.count, 5, "Ordinary backups still rotate")
        XCTAssertEqual(try Data(contentsOf: retainedURL), diverged)
        XCTAssertTrue(try entryTitles(in: try Data(contentsOf: retainedURL)).contains("Only Copy Of This Passkey"))
    }

    func testAPendingSaveWaitsForUnsavedEditsAndIsMergedByTheSaveThatWritesThem() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Edit")

        await vm.mergePendingLocalSaves()

        XCTAssertEqual(try Data(contentsOf: databaseURL), original, "Unsaved edits are the user's to save or discard")
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), pending)

        try await vm.save()

        let saved = try Data(contentsOf: databaseURL)
        let titles = try entryTitles(in: saved)
        XCTAssertTrue(titles.contains("Unsaved Edit"))
        XCTAssertTrue(titles.contains("New Passkey"), "The save the merge was waiting for must run it")
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(
            try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)),
            saved,
            "AutoFill must never lose sight of the passkey"
        )
        XCTAssertTrue(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
        XCTAssertNil(vm.draft)
    }

    func testChangingTheMasterKeyMergesAPendingSaveFirst() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        DatabaseListStore.update(reference)
        let trace = TestDatabaseSupport.LocalPublicationTrace()
        let vm = diagnosticViewModel(reference, trace: trace)
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        do {
            try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
        } catch {
            XCTFail(trace.failure(error, at: "pending-rekey"))
            throw error
        }

        let rekeyed = try Data(contentsOf: databaseURL)
        let reopened = try KDBXParser.parse(data: rekeyed, password: "rotated-master", sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(
            allEntryTitles(in: reopened).contains("New Passkey"),
            "A save written under the old key cannot be merged once the key has changed"
        )
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), rekeyed)
    }

    func testChangingTheMasterKeyIsRefusedWhileAPendingSaveCannotBeMerged() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        DatabaseListStore.update(reference)
        let trace = TestDatabaseSupport.LocalPublicationTrace()
        let vm = diagnosticViewModel(reference, trace: trace)
        defer { vm.lock() }
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)

        do {
            try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("The pending save is still under the old key")
        } catch {
            // Not `pendingUploadsExist`: its message tells the user to wait
            // for syncing, and no amount of waiting moves this session's
            // baseline past the change another app made.
            XCTAssertEqual(error as? DatabaseViewModel.RekeyError, .conflict, trace.failure(error, at: "pending-conflict-rekey"))
            XCTAssertEqual(
                MasterKeyChangeViewModel.message(for: error),
                String(localized: "The database file changed since it was opened. Reload the database and try again.")
            )
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), changedElsewhere)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)

        // Following that message works: the reload takes the other app's
        // change as the baseline, and the retry merges the save and rekeys.
        do {
            try await vm.reloadDiscardingDraft()
                try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )

            let reopened = try KDBXParser.parse(
                data: try Data(contentsOf: databaseURL), password: "rotated-master", sessionKey: SymmetricKey(size: .bits256)
            )
            let titles = allEntryTitles(in: reopened)
            XCTAssertTrue(titles.contains("New Passkey"))
            XCTAssertTrue(titles.contains("Added In Another App"))
            XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        } catch {
            XCTFail(trace.failure(error, at: "pending-reload-and-retry"))
            throw error
        }
    }

    func testChangingTheMasterKeyOffersRecoveryForAnUnknownPendingMergeOutcome() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        // A save that fails for another reason than a changed file leaves the
        // pending save in place without a conflict to reload out of.
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _, _, _, _ in throw SaveError.saveContextUnavailable }
        )
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        do {
            DatabaseListStore.update(vm.databaseReference)
            try await vm.changeMasterKey(
                newPassword: "rotated-master",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("The pending save is still under the old key")
        } catch {
            XCTAssertEqual(error as? PendingLocalSaveStore.OwnershipError, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
    }

    func testMergeWhoseSaveConflictsKeepsThePendingSave() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let changedElsewhere = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "Added In Another App")) }
        try changedElsewhere.write(to: databaseURL, options: .atomic)

        let result = await vm.mergePendingLocalSaves()

        XCTAssertEqual(result, .fileChangedSinceOpen)
        XCTAssertEqual(try Data(contentsOf: databaseURL), changedElsewhere, "The file moved on since this session opened it")
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertNil(vm.pendingUploadMergeFailure)
        XCTAssertNil(vm.saveConflict)
        XCTAssertFalse(vm.isSaving)
        XCTAssertFalse(allEntryTitles(in: try XCTUnwrap(vm.rootGroup)).contains("New Passkey"))
    }

    func testBecomingActiveMergesAPendingSaveInsteadOfReplacingTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)

        vm.refreshSharedDatabaseCacheIfPossible()

        try await waitUntil("the pending save is merged") {
            PendingLocalSaveStore.hasSaves(for: reference.id) == false && vm.isSaving == false
        }
        let saved = try Data(contentsOf: databaseURL)
        XCTAssertTrue(try entryTitles(in: saved).contains("New Passkey"))
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), saved)
    }

    func testBecomingActiveWhileLockedLeavesThePendingSaveAndTheSharedCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try TestDatabaseSupport.makeReference(for: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        let pending = try makeVariantData(of: original) { $0.entries.append(KPEntry(title: "New Passkey")) }
        try seedPendingSave(pending, for: reference)
        let vm = DatabaseViewModel(databaseReference: reference)

        vm.refreshSharedDatabaseCacheIfPossible()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), pending)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: reference.id).count, 1)
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    // MARK: - Helpers

    @discardableResult
    private nonisolated func seedAcceptedSource(
        _ data: Data, for id: UUID, now: Date = .now, sourceID: UUID = UUID(), masterKeyChangedAt: Date? = nil
    ) throws -> PendingLocalSaveStore.PendingSave {
        let cache = PendingLocalSaveStore.sharedCopyURL(for: id)
        if !FileManager.default.fileExists(atPath: cache.path) {
            try writeAtomicallyAndDurably(Data(), to: cache, directoryAnchor: AppGroupContainer.url)
        }
        let baseline = FileDigest.sha512(try Data(contentsOf: cache))
        let prepared = try PendingLocalSaveStore.prepareSource(data, for: id, masterKeyChangedAt: masterKeyChangedAt,
            baseCacheSHA512: baseline, now: now, sourceID: sourceID)
        try writeAtomicallyAndDurably(data, to: cache, directoryAnchor: AppGroupContainer.url)
        guard PendingLocalSaveStore.activateSource(prepared) == .accepted else { throw PendingLocalSaveStore.OwnershipError.recoveryRequired }
        return prepared.save
    }

    private func assertSavesEqual(_ actual: [PendingLocalSaveStore.PendingSave], _ expected: [PendingLocalSaveStore.PendingSave],
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (observed, captured) in zip(actual, expected) {
            XCTAssertEqual(observed.databaseID, captured.databaseID, message, file: file, line: line)
            XCTAssertEqual(try PendingLocalSaveStore.targetIdentity(at: observed.fileURL),
                try PendingLocalSaveStore.targetIdentity(at: captured.fileURL), message, file: file, line: line)
        }
    }

    private struct SaveContext {
        let draft: DatabaseDraft
        let compositeKey: SymmetricKey
        let openTimeSHA512: Data
    }

    /// What the extension leaves behind: the saved bytes in the shared copy
    /// and the same bytes as a pending save.
    private func seedPendingSave(_ data: Data, for reference: DatabaseReference, now: Date = .now) throws {
        DatabaseListStore.update(reference)
        _ = try seedAcceptedSource(data, for: reference.id, now: now, masterKeyChangedAt: reference.lastMasterKeyChangeAt)
    }

    private func diagnosticViewModel(_ reference: DatabaseReference, trace: TestDatabaseSupport.LocalPublicationTrace) -> DatabaseViewModel {
        DatabaseViewModel(databaseReference: reference, localPublicationFailure: { trace.record($0, $1) },
            localSaveOperation: { draft, ref, key, sha, reconciled, newKey, settings in
                var environment = LocalDatabaseSaver.Environment.live
                environment.localPublicationFailure = { trace.record($0, $1) }
                environment.replaceFileAtomically = { bytes, target, baseline, authorization in
                    var io = LocalDatabaseSaver.ReplacementIO()
                    io.observedFailure = { trace.record("replacement-" + $0, $1) }
                    return try LocalDatabaseSaver.replaceFileAtomically(bytes, at: target, expectedSHA512: baseline,
                        authorization: authorization, io: io)
                }
                return try await LocalDatabaseSaver.save(draft: draft, reference: ref, compositeKey: key,
                    openTimeSHA512: sha, reconciledRemoteSHA512: reconciled, kdfPolicy: .mainApp,
                    newCompositeKey: newKey, encryptionSettings: settings, environment: environment)
            })
    }

    private func makeDirtySaveContext(data: Data, entryTitle: String) throws -> SaveContext {
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(data: data, password: fixturePassword, sessionKey: sessionKey)
        let cleanDraft = DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup),
                draft: EntryDraftPayload(title: entryTitle, password: "secret-\(entryTitle)")
            )
        )
        return SaveContext(
            draft: dirtyDraft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(data)
        )
    }

    private func makeDirtyDraft(from viewModel: DatabaseViewModel, entryTitle: String) throws -> DatabaseDraft {
        let rootGroup = try XCTUnwrap(viewModel.rootGroup)
        let cleanDraft = DatabaseDraft(
            rootGroup: rootGroup,
            meta: KPMeta(
                recycleBin: rootGroup.recycleBinUUID.map { .group($0) }
            ),
            sessionKey: try XCTUnwrap(viewModel.sessionKey)
        )
        return try cleanDraft.apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: rootGroup),
                draft: EntryDraftPayload(title: entryTitle, password: "secret-\(entryTitle)")
            )
        )
    }

    /// A database that opens with the fixture password but whose content
    /// differs from `data`, as another writer would leave it.
    private func makeVariantData(
        of data: Data,
        binaryPoolFields: [Data]? = nil,
        mutate: (KPGroup) -> Void
    ) throws -> Data {
        let compositeKey = try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
        let visibleRoot = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup) == parsed.rootGroup.id
            ? parsed.rootGroup
            : parsed.rootGroup.groups[0]
        mutate(visibleRoot)

        var header = parsed.header
        if let binaryPoolFields {
            header.innerHeaderBinaryFields = binaryPoolFields
        }
        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: header,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }

    private func entryTitles(in data: Data) throws -> [String] {
        let root = try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        return allEntryTitles(in: root)
    }

    private func allEntryTitles(in group: KPGroup) -> [String] {
        group.entries.map(\.title) + group.groups.flatMap(allEntryTitles(in:))
    }

    private func makeScratchDatabaseCopy() throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(bundle: Bundle(for: PendingLocalSaveTests.self))
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true, attributes: nil)
        let scratchURL = scratchDirectory.appendingPathComponent("pending-local-save.kdbx", isDirectory: false)
        try Data(contentsOf: fixtureURL).write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    #if os(macOS)
    private func makeCloudReference() -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
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
            isReadOnly: false,
            autoFillEnabled: true,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.webDAV.rawValue,
                    accountId: "acct-pending-local-save",
                    fileId: "/Vaults/cloud.kdbx",
                    displayPath: "/Vaults/cloud.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: "rev-1",
                    lastSyncedAt: nil,
                    lastSyncIssue: nil
                )
            )
        )
    }
    #endif

    private func waitUntil(
        _ description: String,
        // A merge is several KDF runs; shared CI simulators take 2-3x a local run.
        timeout: Duration = .seconds(60),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting until \(description)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// On a device the group container lives under `/private/var`, and Foundation
/// drops that prefix only for paths that already exist.
private func normalizedPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}

private final class PendingEffectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
