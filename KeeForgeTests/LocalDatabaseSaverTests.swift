import CryptoKit
import Darwin
import os
import XCTest
import KDBXKit
import KDBXXML
@testable import KeeForge

final class LocalDatabaseSaverTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    func testSaveRejectsInvalidXMLWithoutReplacingFileCacheOrBackups() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(databaseURL: databaseURL, entryTitle: "Pending Valid Entry")
        let original = try Data(contentsOf: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let root = context.draft.rootGroup
        let invalidEntry = KPEntry(title: "Pending Notes", notes: "Example heading\u{0}\r\nExample body")
        root.entries.append(invalidEntry)
        let invalidDraft = DatabaseDraft(rootGroup: root, meta: context.draft.meta, sessionKey: context.draft.writerSessionKey)

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: invalidDraft, reference: reference, compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Invalid XML must not reach storage")
        } catch {
            XCTAssertEqual((error as? LocalSaveBeforeReplacementFailure)?.underlying as? DocumentWriteFailure, DocumentWriteFailure(
                error: .invalidXMLCharacter("\u{0}", at: .init(owner: .entry(invalidEntry.id), part: .field(key: "Notes"))),
                ownerName: "Pending Notes"
            ))
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
        XCTAssertEqual(invalidDraft.rootGroup.entries.last?.notes, "Example heading\u{0}\r\nExample body")
        _ = try KDBXParser.parse(data: original, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
    }

    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        super.tearDown()
    }

    func testRealReplacementThenDirectorySyncFailureReturnsExactNewCiphertextOnce() async throws {
        try await assertPostReplacementWarning(coordinationFailure: false)
    }

    func testRealReplacementThenCoordinatorFailureReturnsExactNewCiphertextOnce() async throws {
        try await assertPostReplacementWarning(coordinationFailure: true)
    }

    private func assertPostReplacementWarning(coordinationFailure: Bool) async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: url)
        let original = try Data(contentsOf: url)
        let context = try makeDirtySaveContext(databaseURL: url, entryTitle: "Committed Once")
        let encryptions = WriteCounter()
        let replacements = WriteCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.increment()
            return try live.encryptDraft(draft, key, header, policy)
        }
        environment.replaceFileAtomically = { data, target, baseline, authorization in
            replacements.increment()
            var io = LocalDatabaseSaver.ReplacementIO()
            if coordinationFailure { io.coordinationCompletion = { throw POSIXError(.EIO) } }
            else { io.synchronize = { _ in throw POSIXError(.EACCES) } }
            return try LocalDatabaseSaver.replaceFileAtomically(data, at: target,
                expectedSHA512: baseline, authorization: authorization, io: io)
        }
        let result = try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
            compositeKey: context.compositeKey, openTimeSHA512: FileDigest.sha512(original), environment: environment)
        guard case .committedWithoutConfirmedDurability(let sha, _, _, let scope) = result else { return XCTFail("Expected committed warning") }
        let installed = try Data(contentsOf: url)
        XCTAssertNotEqual(installed, original)
        XCTAssertEqual(sha, FileDigest.sha512(installed))
        XCTAssertEqual(scope, .databaseFile)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), installed)
        let parsed = try KDBXParser.parse(data: installed, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(parsed.allEntries.contains { $0.title == "Committed Once" })
        XCTAssertEqual(encryptions.count, 1)
        XCTAssertEqual(replacements.count, 1)
    }

    func testSourcePayloadPostRenameFaultKeepsRecoverableCiphertextAndNeverCallsCacheReplacement() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: url)
        let original = try Data(contentsOf: url)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(databaseURL: url, entryTitle: "Retained Provisional")
        let encryptions = WriteCounter()
        let replacements = WriteCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.increment(); return try live.encryptDraft(draft, key, header, policy)
        }
        environment.replaceFileAtomically = { data, target, baseline, authorization in
            replacements.increment(); return try live.replaceFileAtomically(data, target, baseline, authorization)
        }
        environment.pendingLocalStorageIO.fileIO = { destination in
            var io = DurableFileWriteIO()
            if destination.pathExtension == "kdbx" { io.afterPublication = { _ in throw POSIXError(.EIO) } }
            return io
        }
        do {
            _ = try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
                compositeKey: context.compositeKey, openTimeSHA512: FileDigest.sha512(original), environment: environment)
            XCTFail("Preparation must stop before the cache replacement")
        } catch let failure as LocalSaveBeforeReplacementFailure {
            XCTAssertTrue(failure.underlying is PendingLocalSaveStore.SourcePreparationFailure)
        }
        XCTAssertEqual(encryptions.count, 1)
        XCTAssertEqual(replacements.count, 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), original)
        XCTAssertTrue(PendingLocalSaveStore.saves(for: reference.id).isEmpty)
        let recovery = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertTrue(recovery.needsRecovery)
        let bytes = try PendingLocalSaveStore.export(XCTUnwrap(recovery.receipts.first), for: reference.id)
        let parsed = try KDBXParser.parse(data: bytes, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(parsed.allEntries.contains { $0.title == "Retained Provisional" })
    }

    func testRemovalAfterDurableReplaceDoesNotRecreateTheDeletedSharedCache() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: url)
        let context = try makeDirtySaveContext(databaseURL: url, entryTitle: "Committed Before Removal")
        var environment = LocalDatabaseSaver.Environment.live
        environment.replaceFileAtomically = { data, target, baseline, authorization in
            var io = LocalDatabaseSaver.ReplacementIO()
            io.coordinationCompletion = { XCTAssertTrue(DatabaseListStore.remove(id: reference.id)) }
            return try LocalDatabaseSaver.replaceFileAtomically(data, at: target, expectedSHA512: baseline, authorization: authorization, io: io)
        }
        let result = try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
            compositeKey: context.compositeKey, openTimeSHA512: context.openTimeSHA512, environment: environment)
        guard case .saved(let sha, _, _) = result else { return XCTFail("The original replacement completed before removal") }
        XCTAssertEqual(sha, FileDigest.sha512(try Data(contentsOf: url)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DatabaseListStore.cacheLocation(for: reference).path))
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
        XCTAssertTrue(PendingLocalSaveStore.isRevoked(reference.id))
    }

    func testKeyAssociationPublicationAndOwnerPublicationFailuresNeverClaimDurableSettlement() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: url)
        let context = try makeDirtySaveContext(databaseURL: url, entryTitle: "New Key Bytes")
        let original = try Data(contentsOf: url)
        let association = PendingLocalSaveStore.KeyFileAssociation(bookmarkData: nil, filename: nil,
            changedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let newKey = try KDBXCrypto.compositeKey(password: "new installed key", keyFileData: nil)
        let outcome = try await PendingLocalSaveStore.$keyFileAssociation.withValue(association) {
            try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
                compositeKey: context.compositeKey, openTimeSHA512: context.openTimeSHA512,
                kdfPolicy: .mainApp, newCompositeKey: newKey)
        }
        guard case .saved(let sha, _, let optionalReceipt) = outcome else { return XCTFail("Expected installed file") }
        let receipt = try XCTUnwrap(optionalReceipt)
        XCTAssertThrowsError(try PendingLocalSaveStore.prepareSource(original, for: reference.id,
            masterKeyChangedAt: reference.lastMasterKeyChangeAt, baseCacheSHA512: sha))
        XCTAssertTrue(try PendingLocalSaveStore.recovery(for: reference.id).sourcePublicationPending)
        let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let previousRegistry = try Data(contentsOf: registry)
        var rejected = DurableFileWriteIO()
        rejected.write = { _, _, _ in 0 }
        guard case .notPublished = DatabaseListStore.publishKeyFileAssociation(for: reference.id,
            operationID: receipt.operationID, association: association, io: rejected) else { return XCTFail("Expected real staging failure") }
        XCTAssertEqual(try Data(contentsOf: registry), previousRegistry, "Failed field-specific publication preserves the registry")
        var writer = DurableFileWriteIO()
        writer.afterPublication = { _ in throw POSIXError(.EIO) }
        let publication = DatabaseListStore.publishKeyFileAssociation(for: reference.id,
            operationID: receipt.operationID, association: association, io: writer)
        guard case .publishedWithoutConfirmedDurability = publication else { return XCTFail("A visible rename is not durable association proof") }
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: reference.id).admission?.operationID, receipt.operationID)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id))
        guard case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(for: reference.id,
            operationID: receipt.operationID, association: association) else { return XCTFail("Expected explicit durable association reconfirmation") }
        var io = PendingLocalSaveStore.StorageIO()
        io.fileIO = { _ in
            var result = DurableFileWriteIO()
            result.afterPublication = { _ in throw POSIXError(.EIO) }
            return result
        }
        let settled = try LocalDatabaseSaver.settleInstalledKeyChange(receipt, reference: reference, associationProof: proof, io: io)
        XCTAssertEqual(settled, .resolvedVisibleWithoutConfirmedDurability)
        let snapshot = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertEqual(snapshot.keyEvidence?.sha512, sha)
        XCTAssertNil(snapshot.admission)
        XCTAssertTrue(PendingLocalSaveStore.hasSaves(for: reference.id), "No admitted receipts does not mean no late source")
        XCTAssertTrue(PendingLocalSaveStore.saves(for: reference.id).isEmpty)
        let late = try XCTUnwrap(snapshot.receipts.first)
        XCTAssertEqual(try PendingLocalSaveStore.export(late, for: reference.id), original)
        let updated = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        // A future mutation reconfirms the visible owner namespace under flock before using its epoch.
        try PendingLocalSaveStore.validateWriteContext(for: reference.id, token: nil,
            expectedMasterKeyChangeAt: updated.lastMasterKeyChangeAt, enforcesEpoch: true,
            isMasterKeyChange: false, preparesSource: false)
        let bytes = try Data(contentsOf: url)
        _ = try KDBXParser.parse(data: bytes, compositeKey: newKey, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try KDBXParser.parse(data: bytes, compositeKey: context.compositeKey, sessionKey: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testOpaqueAdapterErrorAfterRealSharedReplaceIsUnknownAndCannotActivateOrResendSource() async throws {
        let url = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: url)
        let original = try Data(contentsOf: url)
        try DatabaseListStore.cacheDatabaseCopy(original, for: reference)
        let context = try makeDirtySaveContext(databaseURL: url, entryTitle: "Opaque Adapter Commit")
        let encryptions = WriteCounter()
        let replacements = WriteCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.resolveLocation = { LocalDatabaseSaver.sharedCopyLocation(for: $0) }
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.increment(); return try live.encryptDraft(draft, key, header, policy)
        }
        environment.replaceFileAtomically = { data, target, baseline, authorization in
            replacements.increment()
            _ = try LocalDatabaseSaver.replaceFileAtomically(data, at: target, expectedSHA512: baseline, authorization: authorization)
            throw CocoaError(.fileWriteUnknown)
        }
        let outcome = try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
            compositeKey: context.compositeKey, openTimeSHA512: context.openTimeSHA512, environment: environment)
        XCTAssertEqual(outcome, .indeterminate(scope: .sharedCopy))
        let installed = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertNotEqual(installed, original)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let root = try KDBXParser.parse(data: installed, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(root.allEntries.contains { $0.title == "Opaque Adapter Commit" })
        XCTAssertEqual(encryptions.count, 1)
        XCTAssertEqual(replacements.count, 1)
        let snapshot = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertTrue(snapshot.needsRecovery)
        XCTAssertTrue(PendingLocalSaveStore.saves(for: reference.id).isEmpty)
        XCTAssertEqual(try PendingLocalSaveStore.export(XCTUnwrap(snapshot.receipts.first), for: reference.id), installed)
    }

    func testLegacyReferenceCleanupRejectsStaleAliasEpochAndRemovalWithoutOverwritingFields() throws {
        let url = try makeScratchDatabaseCopy()
        var reference = try makeRegisteredReference(for: url)
        reference.legacyKeychainFilename = "original-legacy.kdbx"
        DatabaseListStore.update(reference)
        var newer = reference
        newer.legacyKeychainFilename = "new-legacy.kdbx"
        newer.nickname = "Keep current nickname"
        newer.lastMasterKeyChangeAt = Date(timeIntervalSince1970: 1_900_000_000)
        DatabaseListStore.update(newer)
        XCTAssertFalse(DatabaseListStore.clearLegacyKeychainFilename(for: reference))
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }, newer)
        XCTAssertTrue(DatabaseListStore.clearLegacyKeychainFilename(for: newer))
        var cleared = newer
        cleared.legacyKeychainFilename = nil
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }, cleared)
        XCTAssertFalse(DatabaseListStore.clearLegacyKeychainFilename(for: newer), "Field cleanup is idempotent")
        XCTAssertTrue(DatabaseListStore.remove(id: reference.id))
        XCTAssertFalse(DatabaseListStore.clearLegacyKeychainFilename(for: newer))
        XCTAssertFalse(DatabaseListStore.databases.contains { $0.id == reference.id })
    }

    func testStaleDatabaseBookmarkRenewalCannotRestorePreRekeyFields() async throws {
        let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        guard case .masterKeyChange(let desired)? = setup.commit.purpose, let desired else { return XCTFail("Expected key receipt") }
        let location = DatabaseListStore.locateDatabaseFile(for: setup.reference,
            resolveBookmark: { _ in (setup.url, true) }, beforeBookmarkRenewal: {
                guard case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(for: setup.reference.id,
                    operationID: setup.commit.operationID, association: desired) else { throw SaveAssociationWarning() }
                XCTAssertEqual(try LocalDatabaseSaver.settleInstalledKeyChange(setup.commit, reference: setup.reference, associationProof: proof), .resolved)
            })
        guard case .available? = location else { return XCTFail("Read URL must remain usable") }
        let current = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == setup.reference.id })
        XCTAssertEqual(current.keyFileBookmarkData, desired.bookmarkData)
        XCTAssertEqual(current.keyFileFilename, desired.filename)
        XCTAssertEqual(current.lastMasterKeyChangeAt, desired.changedAt)
        XCTAssertEqual(current.bookmarkData, setup.reference.bookmarkData)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: current.id).keyEvidence)
        let newKeyFile = Data(repeating: 0x52, count: 32)
        let newKey = try KDBXCrypto.compositeKey(password: "new key-confirmation password", keyFileData: newKeyFile)
        let session = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: setup.newData, compositeKey: newKey, sessionKey: session)
        let draft = try DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: session,
            binaryPoolFields: parsed.header.innerHeaderBinaryFields).apply(.createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup), draft: EntryDraftPayload(title: "After Renewal Race", password: "kept")))
        let saved = try await LocalDatabaseSaver.save(draft: draft, reference: current, compositeKey: newKey,
            openTimeSHA512: FileDigest.sha512(setup.newData), kdfPolicy: .mainApp)
        guard case .saved = saved else { return XCTFail("Field-only renewal must leave future saves usable") }
        let reopened = try KDBXParser.parse(data: Data(contentsOf: setup.url), compositeKey: newKey, sessionKey: session)
        XCTAssertTrue(reopened.allEntries.contains { $0.title == "After Renewal Race" })
    }

    func testReadyCertificateReplayRetiresWithoutPinningLaterExternalRestorationAndPreservesNewSources() async throws {
        let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        guard case .masterKeyChange(let desired)? = setup.commit.purpose, let desired else { return XCTFail("Expected real key-change receipt") }
        guard case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(for: setup.reference.id,
            operationID: setup.commit.operationID, association: desired) else { return XCTFail("Expected durable factors") }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let certificate = OSAllocatedUnfairLock<Data?>(initialState: nil)
        var io = PendingLocalSaveStore.StorageIO()
        io.fileIO = { url in
            var writer = DurableFileWriteIO()
            let n = writes.withLock { value in value += 1; return value }
            if n == 1 { writer.afterPublication = { _ in certificate.withLock { $0 = try? Data(contentsOf: url) } } }
            if n == 2 {
                let published = OSAllocatedUnfairLock(initialState: false)
                writer.afterPublication = { _ in published.withLock { $0 = true } }
                writer.synchronizeParent = { directory in
                    if published.withLock({ $0 }) { throw POSIXError(.EIO) }
                    try synchronizeDirectory(directory)
                }
            }
            return writer
        }
        let completion = try LocalDatabaseSaver.settleInstalledKeyChange(setup.commit, reference: setup.reference,
            associationProof: proof, io: io)
        XCTAssertEqual(completion, .resolvedVisibleWithoutConfirmedDurability)
        let ready = try XCTUnwrap(certificate.withLock { $0 })
        let ownerURL = AppGroupContainer.url.appendingPathComponent("pending-local-save-owners/\(setup.reference.id.uuidString)/owner.json")
        // A crash may recover the already-durable certificate after a visible withdrawal.
        try setup.oldData.write(to: setup.url, options: .atomic)
        try writeAtomicallyAndDurably(ready, to: ownerURL)
        let snapshot = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        let evidence = try XCTUnwrap(snapshot.keyEvidence)
        XCTAssertTrue(evidence.targetState.isReadyToRetire)
        XCTAssertEqual(PendingLocalSaveStore.resumeCertifiedRetirement(evidence, for: setup.reference.id), .resolved)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: setup.reference.id).keyEvidence)
        XCTAssertEqual(try Data(contentsOf: setup.url), setup.oldData, "Retirement does not rewrite or permanently pin the target")
        let source = try PendingLocalSaveStore.prepareSource(setup.newData, for: setup.reference.id,
            masterKeyChangedAt: desired.changedAt, baseCacheSHA512: FileDigest.sha512(setup.newData))
        XCTAssertEqual(PendingLocalSaveStore.resumeCertifiedRetirement(evidence, for: setup.reference.id), .retainedForRecovery)
        let later = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertEqual(later.receipts, [source.receipt])
        XCTAssertEqual(try PendingLocalSaveStore.export(source.receipt, for: setup.reference.id), setup.newData)
    }

    func testScannerHealRelinkAndBothRawCacheWritersPreserveActiveKeyRecoveryCiphertext() async throws {
        let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
        defer { try? FileManager.default.removeItem(at: setup.directory); DatabaseListStore.documentsDirectoryOverride = nil }
        DatabaseListStore.documentsDirectoryOverride = setup.directory
        var resident = setup.reference
        resident.isDocumentsResident = true
        DatabaseListStore.update(resident)
        try setup.oldData.write(to: setup.url, options: .atomic)
        let cache = DatabaseListStore.cacheLocation(for: resident)
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber)
        DocumentsVaultScanner.scan(directory: setup.directory)
        XCTAssertEqual(try Data(contentsOf: cache), setup.newData)
        XCTAssertThrowsError(try DatabaseListStore.cacheDatabaseCopy(setup.oldData, for: resident.id))
        XCTAssertThrowsError(try DatabaseListStore.cacheDatabaseCopy(setup.oldData, for: resident))
        DatabaseListStore.cacheInitialCopyIfPossible(from: setup.url, for: resident.id)
        XCTAssertEqual(try Data(contentsOf: cache), setup.newData)
        resident.bookmarkData = Data("invalid Documents bookmark".utf8)
        DatabaseListStore.update(resident)
        _ = DatabaseListStore.locateDatabaseFile(for: resident)
        XCTAssertEqual(try Data(contentsOf: cache), setup.newData)
        let other = setup.directory.appendingPathComponent("relinked.kdbx")
        try setup.oldData.write(to: other)
        XCTAssertNotNil(try DatabaseListStore.relinkLocalDatabase(id: resident.id, to: other))
        XCTAssertEqual(try Data(contentsOf: cache), setup.newData)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber, before)
        let copy = try await LocalDatabaseSaver.exportKeyEpochCopy(XCTUnwrap(setup.snapshot.admission), for: resident)
        XCTAssertEqual(copy, setup.newData)
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: resident.id).admission, setup.snapshot.admission)
    }

    func testInitialCacheReadCannotPublishAfterRemovalOrEpochSettlement() async throws {
        for event in ["remove", "epoch"] {
            let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            let cache = DatabaseListStore.cacheLocation(for: setup.reference)
            let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber)
            DatabaseListStore.cacheInitialCopyIfPossible(from: setup.url, for: setup.reference.id, read: { url in
                let bytes = try CoordinatedFileReader.readData(from: url)
                if event == "remove" { XCTAssertFalse(DatabaseListStore.remove(id: setup.reference.id)) }
                else {
                    guard case .masterKeyChange(let desired)? = setup.commit.purpose, let desired,
                          case .durable(let proof) = DatabaseListStore.publishKeyFileAssociation(for: setup.reference.id,
                            operationID: setup.commit.operationID, association: desired) else { throw SaveError.saveContextUnavailable }
                    XCTAssertEqual(try LocalDatabaseSaver.settleInstalledKeyChange(setup.commit, reference: setup.reference,
                        associationProof: proof), .resolved)
                }
                return bytes
            })
            XCTAssertEqual(try Data(contentsOf: cache), setup.newData)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber, before)
            if event == "remove" { XCTAssertTrue(PendingLocalSaveStore.isRevoked(setup.reference.id)) }
            else { XCTAssertNil(try PendingLocalSaveStore.recovery(for: setup.reference.id).keyEvidence) }
        }
    }

    func testKeyConfirmationRejectsOldMissingAndForeignTargetsBeforePublishingNewFactors() async throws {
        for mutation in ["old", "missing", "foreign"] {
            let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
            defer { try? FileManager.default.removeItem(at: setup.directory) }
            let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
            let before = try Data(contentsOf: registry)
            switch mutation {
            case "old": try setup.oldData.write(to: setup.url, options: .atomic)
            case "missing": try FileManager.default.removeItem(at: setup.url)
            default: try Data("foreign ciphertext".utf8).write(to: setup.url, options: .atomic)
            }
            XCTAssertThrowsError(try LocalDatabaseSaver.confirmInstalledKeyChange(for: setup.reference, snapshot: setup.snapshot))
            XCTAssertEqual(try Data(contentsOf: registry), before, "Rejected confirmation must not publish new factors")
            XCTAssertEqual(try PendingLocalSaveStore.recovery(for: setup.reference.id).admission?.operationID,
                setup.snapshot.admission?.operationID)
            let oldKeyURL = try XCTUnwrap(DatabaseListStore.resolveKeyFileURL(for: setup.reference))
            XCTAssertEqual(try Data(contentsOf: oldKeyURL), setup.oldKeyFile)
            if mutation == "old" {
                _ = try KDBXParser.parse(data: Data(contentsOf: setup.url), compositeKey: setup.oldKey,
                    sessionKey: SymmetricKey(size: .bits256))
            }
            XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: setup.reference)), setup.newData)
        }
    }

    func testKeyConfirmationRechecksTargetUnderBothResourceCoordinationBeforePublishing() async throws {
        let setup = try await makePendingKeyChangeWithDistinctKeyFiles()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
        let before = try Data(contentsOf: registry)
        let target = setup.url
        let oldData = setup.oldData
        let installedSHA = FileDigest.sha512(setup.newData)
        XCTAssertThrowsError(try LocalDatabaseSaver.confirmInstalledKeyChange(for: setup.reference, snapshot: setup.snapshot,
            beforePublication: {
                _ = try LocalDatabaseSaver.replaceFileAtomically(oldData, at: target, expectedSHA512: installedSHA)
            }))
        XCTAssertEqual(try Data(contentsOf: target), oldData)
        XCTAssertEqual(try Data(contentsOf: registry), before)
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: setup.reference.id).admission?.operationID,
            setup.snapshot.admission?.operationID)
    }

    private func makeRegisteredReference(for url: URL) throws -> DatabaseReference {
        let reference = try TestDatabaseSupport.makeReference(for: url)
        DatabaseListStore.update(reference)
        return reference
    }

    private func makePendingKeyChangeWithDistinctKeyFiles() async throws -> (
        directory: URL, url: URL, reference: DatabaseReference, oldData: Data, newData: Data,
        oldKey: SymmetricKey, oldKeyFile: Data, snapshot: PendingLocalSaveStore.RecoverySnapshot,
        commit: PendingLocalSaveStore.CommitReceipt
    ) {
        let loaded = try KDBXCompatibilitySupport.load(.passwordKeyfile, bundle: Bundle(for: Self.self))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("key-confirmation.kdbx")
        try loaded.sourceData.write(to: url)
        let oldKeyFile = try XCTUnwrap(loaded.keyFileData)
        let oldKeyURL = directory.appendingPathComponent("old.keyx")
        try oldKeyFile.write(to: oldKeyURL)
        let newKeyURL = directory.appendingPathComponent("new.keyx")
        let newKeyFile = Data(repeating: 0x52, count: 32)
        try newKeyFile.write(to: newKeyURL)
        var reference = try DatabaseListStore.add(url: url)
        reference.keyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: oldKeyURL, readOnly: true)
        reference.keyFileFilename = oldKeyURL.lastPathComponent
        DatabaseListStore.update(reference)
        let desired = PendingLocalSaveStore.KeyFileAssociation(
            bookmarkData: try SecurityScopedBookmarkManager.makeBookmarkData(for: newKeyURL, readOnly: true),
            filename: newKeyURL.lastPathComponent, changedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let newKey = try KDBXCrypto.compositeKey(password: "new key-confirmation password", keyFileData: newKeyFile)
        let draft = DatabaseDraft(rootGroup: loaded.rootGroup, meta: loaded.meta, sessionKey: loaded.sessionKey,
            binaryPoolFields: loaded.header.innerHeaderBinaryFields)
        let outcome = try await PendingLocalSaveStore.$keyFileAssociation.withValue(desired) {
            try await LocalDatabaseSaver.save(draft: draft, reference: reference, compositeKey: loaded.compositeKey,
                openTimeSHA512: FileDigest.sha512(loaded.sourceData), kdfPolicy: .mainApp, newCompositeKey: newKey)
        }
        guard case .saved(_, _, let commit) = outcome, let commit else { throw SaveError.saveContextUnavailable }
        return (directory, url, reference, loaded.sourceData, try Data(contentsOf: url), loaded.compositeKey, oldKeyFile,
            try PendingLocalSaveStore.recovery(for: reference.id), commit)
    }

    func testSaveWritesValidKDBXThatReParsesEqualToDraft() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Slice 04 Added Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let reparsed = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: databaseURL),
            password: fixturePassword,
            sessionKey: context.draft.writerSessionKey
        )

        let expectedRoot = context.draft.rootGroup
        let expectedParent = TestDatabaseSupport.visibleRootGroupID(in: expectedRoot) == expectedRoot.id
            ? expectedRoot
            : expectedRoot.groups[0]
        let createdIndex = try XCTUnwrap(expectedParent.entries.firstIndex { $0.title == "Slice 04 Added Entry" })
        let createdAt = try XCTUnwrap(expectedParent.entries[createdIndex].creationTime)
        // KDBX timestamps store whole seconds.
        let storedTimestamp = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        expectedParent.entries[createdIndex].creationTime = storedTimestamp
        expectedParent.entries[createdIndex].lastModificationTime = storedTimestamp
        expectedParent.entries[createdIndex].locationChanged = storedTimestamp
        try KDBXTreeAssertions.assertTreesEqual(
            (rootGroup: reparsed.rootGroup, meta: reparsed.meta),
            (rootGroup: expectedRoot, meta: context.draft.meta),
            sessionKey: context.draft.writerSessionKey
        )
    }

    func testSaveTwofishDatabasePreservesCipherAndRefreshesCache() async throws {
        let databaseURL = try makeScratchTwofishDatabase()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Twofish Saved Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let savedData = try Data(contentsOf: databaseURL)
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: savedData,
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXOuterCipher.twofish256CBC.uuid)
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Twofish Saved Entry" })

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        XCTAssertEqual(try Data(contentsOf: cachedURL), savedData)
    }

    func testSaveTakesBackupOfPreviousBytesIntoBackupDirectory() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Backup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let backups = DatabaseListStore.recentBackups(for: reference)
        let backupURL = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
    }

    func testBackupTakenBySaveReopensWithOriginalCredentialsAtPreEditContent() async throws {
        // A backup that is merely present is worthless; this proves the bytes
        // written aside are a decryptable KDBX file that still holds the
        // pre-edit entry state, i.e. that a restore would actually recover it.
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let target = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "Twitter" })
        XCTAssertEqual(try target.password.decrypt(using: sessionKey), "twitterpass123")
        let originalTitles = parsed.rootGroup.allEntries.map(\.title).sorted()
        let originalHistoryCount = target.history.count

        let dirtyDraft = try DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey
        ).apply(
            .updateEntry(
                entryID: target.id,
                draft: EntryDraftPayload(
                    title: target.title,
                    username: target.username,
                    password: "rotated-password",
                    url: target.url,
                    notes: target.notes,
                    customFields: target.customFields,
                    tags: target.tags
                )
            )
        )

        _ = try await LocalDatabaseSaver.save(
            draft: dirtyDraft,
            reference: reference,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(originalData)
        )

        let verifyKey = SymmetricKey(size: .bits256)
        let savedParsed = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: databaseURL),
            password: fixturePassword,
            sessionKey: verifyKey
        )
        let savedEntry = try XCTUnwrap(savedParsed.rootGroup.allEntries.first { $0.title == "Twitter" })
        XCTAssertEqual(try savedEntry.password.decrypt(using: verifyKey), "rotated-password")
        XCTAssertEqual(savedEntry.history.count, originalHistoryCount + 1)

        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        let restored = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: backupURL),
            password: fixturePassword,
            sessionKey: verifyKey
        )
        let restoredEntry = try XCTUnwrap(restored.rootGroup.allEntries.first { $0.title == "Twitter" })

        XCTAssertEqual(try restoredEntry.password.decrypt(using: verifyKey), "twitterpass123")
        XCTAssertEqual(
            restoredEntry.history.count,
            originalHistoryCount,
            "The backup predates the edit, so it must not carry the snapshot the edit pushed"
        )
        XCTAssertEqual(restored.rootGroup.allEntries.map(\.title).sorted(), originalTitles)
    }

    func testSavePrunesBackupsToFiveNewest() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let dates = DateSequence(
            dates: (0..<7).map { Date(timeIntervalSince1970: 1_000 + Double($0)) }
        )
        var environment = LocalDatabaseSaver.Environment.live
        environment.now = {
            dates.next()
        }

        var priorVersions: [Data] = []
        for index in 0..<7 {
            let currentData = try Data(contentsOf: databaseURL)
            priorVersions.append(currentData)
            let context = try makeDirtySaveContext(
                databaseURL: databaseURL,
                entryTitle: "Prune Entry \(index)"
            )

            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                environment: environment
            )
        }

        let backups = DatabaseListStore.recentBackups(for: reference)
        let backupContents = try backups.map { try Data(contentsOf: $0) }

        XCTAssertEqual(backups.count, 5)
        XCTAssertEqual(backupContents, Array(priorVersions.suffix(5).reversed()))
    }

    func testSaveReturnsSavedSHA512ThatMatchesNewBytes() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Hash Entry"
        )

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )
        let savedData = try Data(contentsOf: databaseURL)

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected save to succeed.")
            return
        }

        XCTAssertEqual(newSHA512, FileDigest.sha512(savedData))
    }

    func testSaveRefreshesSharedCachedCopyWithSavedBytes() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Cached Entry"
        )
        let cacheWrites = WriteCounter()
        var environment = LocalDatabaseSaver.Environment.live
        let liveCacheCopy = environment.cacheDatabaseCopy
        environment.cacheDatabaseCopy = { data, reference in
            cacheWrites.increment()
            try liveCacheCopy(data, reference)
        }

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        let savedData = try Data(contentsOf: databaseURL)
        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))

        XCTAssertEqual(try Data(contentsOf: cachedURL), savedData)
        XCTAssertEqual(
            cacheWrites.count,
            1,
            "Local references save to the bookmarked file, so the explicit cache refresh is load-bearing"
        )
    }

    func testSaveWhoseSharedCopyRefreshFailsRemovesTheOlderCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: databaseURL), for: reference)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Uncached Entry"
        )
        var environment = LocalDatabaseSaver.Environment.live
        environment.cacheDatabaseCopy = { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            environment: environment
        )

        let savedData = try Data(contentsOf: databaseURL)
        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected save to succeed.")
            return
        }
        XCTAssertEqual(
            newSHA512,
            FileDigest.sha512(savedData),
            "The file is replaced, so the session must move on to its new bytes"
        )
        let reparsed = try KDBXParser.parseWithMeta(
            data: savedData,
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Uncached Entry" })
        XCTAssertNil(
            DatabaseListStore.cachedDatabaseURL(for: reference),
            "AutoFill must not keep opening the copy from before the save"
        )
    }

    func testRekeySaveWhoseSharedCopyRefreshFailsRemovesTheCopyUnderTheOldKey() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: databaseURL), for: reference)
        let context = try makeCleanSaveContext(databaseURL: databaseURL)
        let newPassword = "rotated-master-123"
        var environment = LocalDatabaseSaver.Environment.live
        environment.cacheDatabaseCopy = { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil),
            environment: environment
        )

        let savedData = try Data(contentsOf: databaseURL)
        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected save to succeed.")
            return
        }
        XCTAssertEqual(newSHA512, FileDigest.sha512(savedData))
        XCTAssertNoThrow(
            try KDBXParser.parseWithMeta(
                data: savedData,
                password: newPassword,
                sessionKey: SymmetricKey(size: .bits256)
            )
        )
        XCTAssertNil(
            DatabaseListStore.cachedDatabaseURL(for: reference),
            "A copy that only the old master key opens must not stay behind for AutoFill"
        )
    }

    func testSaveWhoseSharedCopyRefreshFailsSucceedsWithoutAnOlderCopy() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Never Cached Entry"
        )
        var environment = LocalDatabaseSaver.Environment.live
        environment.cacheDatabaseCopy = { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            environment: environment
        )

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected save to succeed.")
            return
        }
        XCTAssertEqual(newSHA512, FileDigest.sha512(try Data(contentsOf: databaseURL)))
        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: reference))
    }

    func testSaveCloudReferenceResolvedToCacheWritesCacheExactlyOnce() async throws {
        // A cloud-backed reference has no bookmark, so (as in an AutoFill
        // extension save) the resolved save location IS the shared cache
        // file. The atomic replace is the cache write; a second refresh
        // through cacheDatabaseCopy would write the same bytes again.
        let reference = makeCloudReference()
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL), for: reference)
        let cacheURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference))
        let context = try makeDirtySaveContext(
            databaseURL: cacheURL,
            entryTitle: "Cloud Cache Entry"
        )

        let cacheWrites = WriteCounter()
        let cachePath = cacheURL.standardizedFileURL.resolvingSymlinksInPath().path
        var environment = LocalDatabaseSaver.Environment.live
        let liveReplace = environment.replaceFileAtomically
        environment.replaceFileAtomically = { data, url, expectedSHA512, authorization in
            if url.standardizedFileURL.resolvingSymlinksInPath().path == cachePath {
                cacheWrites.increment()
            }
            return try liveReplace(data, url, expectedSHA512, authorization)
        }
        let liveCacheCopy = environment.cacheDatabaseCopy
        environment.cacheDatabaseCopy = { data, reference in
            cacheWrites.increment()
            try liveCacheCopy(data, reference)
        }

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            environment: environment
        )

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected save to succeed.")
            return
        }
        XCTAssertEqual(
            cacheWrites.count,
            1,
            "Saving a cloud reference must write the shared cache exactly once"
        )
        XCTAssertEqual(FileDigest.sha512(try Data(contentsOf: cacheURL)), newSHA512)
    }

    func testSaveFinishingWhileAnotherEncryptsConflictsInsteadOfOverwritingIt() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let pausedContext = try makeDirtySaveContext(databaseURL: databaseURL, entryTitle: "Paused Writer Entry")
        let finishingContext = try makeDirtySaveContext(databaseURL: databaseURL, entryTitle: "Finishing Writer Entry")

        let pausedWriterEncrypted = DispatchSemaphore(value: 0)
        let resumePausedWriter = DispatchSemaphore(value: 0)
        var pausedEnvironment = LocalDatabaseSaver.Environment.live
        let liveEncrypt = pausedEnvironment.encryptDraft
        pausedEnvironment.encryptDraft = { draft, compositeKey, header, kdfPolicy in
            let data = try liveEncrypt(draft, compositeKey, header, kdfPolicy)
            pausedWriterEncrypted.signal()
            resumePausedWriter.wait()
            return data
        }

        let pausedSave = Task {
            try await LocalDatabaseSaver.save(
                draft: pausedContext.draft,
                reference: reference,
                compositeKey: pausedContext.compositeKey,
                openTimeSHA512: pausedContext.openTimeSHA512,
                kdfPolicy: .mainApp,
                environment: pausedEnvironment
            )
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                pausedWriterEncrypted.wait()
                continuation.resume()
            }
        }

        let finishingResult = try await LocalDatabaseSaver.save(
            draft: finishingContext.draft,
            reference: reference,
            compositeKey: finishingContext.compositeKey,
            openTimeSHA512: finishingContext.openTimeSHA512,
            kdfPolicy: .mainApp
        )
        resumePausedWriter.signal()
        let pausedResult = try await pausedSave.value

        guard case .saved(let finishingSHA512, _, _) = finishingResult else {
            return XCTFail("The writer that finished first must save")
        }
        guard case .conflict(let remoteSHA512, let remoteData) = pausedResult else {
            return XCTFail("The paused writer must not overwrite the save that landed meanwhile")
        }
        let onDisk = try Data(contentsOf: databaseURL)
        XCTAssertEqual(remoteSHA512, finishingSHA512)
        XCTAssertEqual(remoteData, onDisk)
        XCTAssertEqual(FileDigest.sha512(onDisk), finishingSHA512)
        let titles = try KDBXParser.parse(data: onDisk, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
            .allEntries.map(\.title)
        XCTAssertTrue(titles.contains("Finishing Writer Entry"))
        XCTAssertFalse(titles.contains("Paused Writer Entry"))
    }

    func testSaveRemoteChangedSinceOpenReturnsConflictDoesNotWrite() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Conflict Entry"
        )
        let remoteData = Data("remote-change".utf8)
        try remoteData.write(to: databaseURL, options: .atomic)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected save conflict.")
            return
        }

        XCTAssertEqual(remoteSHA512, FileDigest.sha512(remoteData))
        XCTAssertEqual(conflictData, remoteData)
        XCTAssertEqual(try Data(contentsOf: databaseURL), remoteData)
    }

    // A merge has already read the diverged file and folded it into the draft,
    // so that file — and only that file — is safe to replace.

    func testSaveWithReconciledRemoteHashReplacesThatFileButNoOtherState() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Merged Entry"
        )

        let reconciledRemoteData = try makeDivergedDatabaseData(from: databaseURL)
        try reconciledRemoteData.write(to: databaseURL, options: .atomic)
        let reconciledRemoteSHA512 = FileDigest.sha512(reconciledRemoteData)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: .mainApp
        )

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("A save gated on the reconciled remote must replace exactly that file.")
            return
        }
        XCTAssertEqual(FileDigest.sha512(try Data(contentsOf: databaseURL)), newSHA512)

        // A third state under the save was never reconciled by anyone, so the
        // widened gate must still refuse it.
        let strangerData = try makeDivergedDatabaseData(from: databaseURL)
        try strangerData.write(to: databaseURL, options: .atomic)

        let secondResult = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            reconciledRemoteSHA512: reconciledRemoteSHA512,
            kdfPolicy: .mainApp
        )

        guard case .conflict(let remoteSHA512, _) = secondResult else {
            XCTFail("Expected a conflict for content neither the session nor the merge has seen.")
            return
        }
        XCTAssertEqual(remoteSHA512, FileDigest.sha512(strangerData))
        XCTAssertEqual(try Data(contentsOf: databaseURL), strangerData)
    }

    func testSaveOnReadOnlyFilesystemThrowsAndLeavesOriginalIntact() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let directoryURL = databaseURL.deletingLastPathComponent()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Read Only FS Entry"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Expected save to fail on a read-only filesystem.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        }
    }

    func testExclusiveDurablePublicationNeverReplacesAnExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.kdbx")
        let foreign = Data("owned by an earlier publisher".utf8)
        try foreign.write(to: url)
        guard case .notPublished(let error) = writeWithDurabilityOutcome(Data("new ciphertext".utf8), to: url, publication: .exclusive) else {
            return XCTFail("Exclusive publication cannot replace a foreign source")
        }
        XCTAssertEqual((error as? POSIXError)?.code, .EEXIST)
        XCTAssertEqual(try Data(contentsOf: url), foreign)
    }

    func testDurableWriterAcceptsEmptyDataAndRetriesInterruptedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload")
        try writeAtomicallyAndDurably(Data(), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data())
        let calls = WriteCounter()
        var io = DurableFileWriteIO()
        io.write = { descriptor, bytes, count in
            calls.increment()
            if calls.count == 1 { errno = EINTR; return -1 }
            return Darwin.write(descriptor, bytes, count)
        }
        let bytes = Data("complete payload after interrupt".utf8)
        try writeAtomicallyAndDurably(bytes, to: url, io: io)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertGreaterThanOrEqual(calls.count, 2)
    }

    func testDurableWriterTreatsZeroWriteAsFailureWithoutReplacingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("payload")
        let original = Data("original ciphertext".utf8)
        try original.write(to: url)
        var io = DurableFileWriteIO()
        io.write = { _, _, _ in 0 }
        XCTAssertThrowsError(try writeAtomicallyAndDurably(Data("new ciphertext".utf8), to: url, io: io))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["payload"])
    }

    func testDurableDirectoryStaysInsideGrantAndReconfirmsCreatedNamespaceAfterSyncFailure() throws {
        let anchor = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: anchor) }
        let child = anchor.appendingPathComponent("owned")
        let rootCalls = WriteCounter()
        let rootPath = anchor.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertThrowsError(try createDurableDirectory(at: child, anchor: anchor, synchronize: { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { throw POSIXError(.EACCES) }
            if path == rootPath {
                rootCalls.increment()
                if rootCalls.count == 2 { throw POSIXError(.EIO) }
            }
            try synchronizeDirectory(url)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        let childCalls = WriteCounter()
        let replayRootCalls = WriteCounter()
        try createDurableDirectory(at: child, anchor: anchor, synchronize: { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { throw POSIXError(.EACCES) }
            if path == rootPath { replayRootCalls.increment() } else { childCalls.increment() }
            try synchronizeDirectory(url)
        })
        XCTAssertGreaterThanOrEqual(childCalls.count, 1)
        XCTAssertGreaterThanOrEqual(replayRootCalls.count, 1)
    }

    func testRemovalDuringRealStagingPreventsTheFinalReplacement() throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try DatabaseListStore.add(url: databaseURL)
        let original = try Data(contentsOf: databaseURL)
        var io = LocalDatabaseSaver.ReplacementIO()
        io.stage = { data, stagingURL in
            try writeAtomicallyAndDurably(data, to: stagingURL)
            XCTAssertTrue(DatabaseListStore.remove(id: reference.id))
        }
        XCTAssertThrowsError(try LocalDatabaseSaver.replaceFileAtomically(
            Data("late ciphertext".utf8), at: databaseURL, expectedSHA512: FileDigest.sha512(original),
            authorization: .init(databaseID: reference.id), io: io
        ))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
        XCTAssertTrue(PendingLocalSaveStore.isRevoked(reference.id))
    }

    func testSaveAtomicReplaceDoesNotLeaveTempFilesOnSuccess() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Temp Cleanup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512
        )

        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: databaseURL.deletingLastPathComponent().path
        ).sorted()

        XCTAssertEqual(siblingNames, [databaseURL.lastPathComponent])
    }

    func testSaveAtomicReplaceFailureLeavesOriginalIntact() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Failure Entry"
        )
        let encryptions = WriteCounter()
        let live = LocalDatabaseSaver.Environment.live
        var environment = live
        environment.encryptDraft = { draft, key, header, policy in
            encryptions.increment(); return try live.encryptDraft(draft, key, header, policy)
        }
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
            XCTFail("Expected save to fail when the replace step throws.")
        } catch {
            XCTAssertTrue(error is LocalSaveBeforeReplacementFailure)
            XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        }
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: reference.id).admission)
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        environment.replaceFileAtomically = live.replaceFileAtomically
        let retried = try await LocalDatabaseSaver.save(draft: context.draft, reference: reference,
            compositeKey: context.compositeKey, openTimeSHA512: context.openTimeSHA512, environment: environment)
        guard case .saved = retried else { return XCTFail("A proven staging failure permits one explicit successful retry") }
        XCTAssertEqual(encryptions.count, 2)
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: reference.id).admission)
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
        let reopened = try KDBXParser.parse(data: Data(contentsOf: databaseURL), password: fixturePassword, sessionKey: context.draft.writerSessionKey)
        XCTAssertTrue(reopened.allEntries.contains { $0.title == "Failure Entry" })
    }

    func testSaveUnderNSFileCoordinatorDoesNotDeadlockWhenOtherCoordinatorActive() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Coordinated Entry"
        )

        let readerStarted = expectation(description: "reader started")
        DispatchQueue.global(qos: .utility).async {
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: databaseURL, options: [], error: &coordinatorError) { _ in
                readerStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        await fulfillment(of: [readerStarted], timeout: 5)

        // Generous budget: a deadlock never resolves, so this still catches one,
        // while a slow CI runner doing a real KDBX save (Argon2 + crypto) does
        // not false-fail. GitHub runners have exceeded the previous 5s budget.
        let result = try await withTimeout(seconds: 30) {
            try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
        }

        guard case .saved = result else {
            XCTFail("Expected save to succeed while another coordinator is active.")
            return
        }
    }

    func testSaveLegacyKDBX31ThrowsDatabaseIsReadOnly() async throws {
        let databaseURL = try makeScratchDatabaseCopy(fixtureName: "legacy-kdbx31")
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Legacy Save Attempt"
        )

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Expected legacy KDBX3 save to be blocked as read-only.")
        } catch let failure as LocalSaveBeforeReplacementFailure {
            XCTAssertEqual(failure.underlying as? SaveError, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Rekey (change master key, #59)

    func testRekeySaveWritesFileThatOpensWithNewKeyAndRejectsOldKey() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekeyed Entry"
        )
        let newPassword = "rotated-master-123"
        let newCompositeKey = try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: newCompositeKey
        )

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected rekey save to succeed.")
            return
        }

        let savedData = try Data(contentsOf: databaseURL)
        XCTAssertEqual(newSHA512, FileDigest.sha512(savedData))

        let reparsed = try KDBXParser.parseWithMeta(
            data: savedData,
            password: newPassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Rekeyed Entry" })

        XCTAssertThrowsError(
            try KDBXParser.parseWithMeta(
                data: savedData,
                password: fixturePassword,
                sessionKey: SymmetricKey(size: .bits256)
            ),
            "The old credentials must no longer open the rekeyed file."
        )
    }

    func testRekeySaveBackupStillOpensWithOldCredentials() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Backup Entry"
        )

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        )

        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
        let restored = try KDBXParser.parseWithMeta(
            data: try Data(contentsOf: backupURL),
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertEqual(
            restored.rootGroup.allEntries.map(\.title).sorted(),
            context.originalRootGroup.allEntries.map(\.title).sorted()
        )
    }

    func testRekeySaveConflictLeavesFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Conflict Entry"
        )
        let remoteData = Data("changed-outside".utf8)
        try remoteData.write(to: databaseURL, options: .atomic)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        )

        guard case .conflict = result else {
            XCTFail("Expected the rekey save to conflict.")
            return
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), remoteData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    func testRekeySaveVerificationFailureLeavesFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeDirtySaveContext(
            databaseURL: databaseURL,
            entryTitle: "Rekey Verify Entry"
        )
        let newCompositeKey = try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil)
        var environment = LocalDatabaseSaver.Environment.live
        let liveExtractHeader = environment.extractHeader
        environment.extractHeader = { data, key, kdfPolicy in
            if key == newCompositeKey {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try liveExtractHeader(data, key, kdfPolicy)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey,
                environment: environment
            )
            XCTFail("Expected the rekey save to fail verification.")
        } catch let failure as LocalSaveBeforeReplacementFailure {
            XCTAssertEqual(failure.underlying as? SaveError, .reencryptionVerificationFailed)
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    // MARK: - Encryption settings (#98)

    func testEncryptionSettingsSaveRewritesHeaderUnderTheSameKey() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let original = try KDBXFileSummary.inspect(data: originalData)
        XCTAssertEqual(original.cipher, .aes256CBC, "Fixture precondition")
        let context = try makeCleanSaveContext(databaseURL: databaseURL)
        let kdfParameters = try DatabaseCreationDefaults.argon2idKDFParameters(preset: .strong)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            encryptionSettings: EncryptionSettingsChange(
                cipherID: KDBXOuterCipher.chaCha20.uuid,
                kdfParameters: kdfParameters,
                compressionFlags: original.isCompressed ? 0 : 1
            )
        )

        guard case .saved(let newSHA512, _, _) = result else {
            XCTFail("Expected the encryption settings save to succeed.")
            return
        }
        let savedData = try Data(contentsOf: databaseURL)
        XCTAssertEqual(newSHA512, FileDigest.sha512(savedData))

        let saved = try KDBXFileSummary.inspect(data: savedData)
        XCTAssertEqual(saved.cipher, .chaCha20)
        XCTAssertEqual(saved.isCompressed, !original.isCompressed)
        XCTAssertEqual(
            saved.keyDerivation,
            .argon2id(
                iterations: DatabaseCreationKDFPreset.strong.iterations,
                memoryBytes: DatabaseCreationKDFPreset.strong.memoryBytes,
                parallelism: DatabaseCreationDefaults.argon2idParallelism
            )
        )
        XCTAssertEqual(saved.formatVersion, original.formatVersion)

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: savedData,
            compositeKey: context.compositeKey,
            sessionKey: SymmetricKey(size: .bits256),
            kdfPolicy: .mainApp
        )
        XCTAssertEqual(
            reparsed.rootGroup.allEntries.map(\.title).sorted(),
            context.originalRootGroup.allEntries.map(\.title).sorted()
        )
        XCTAssertNotEqual(
            reparsed.header.kdfParameters.bytes("S"),
            kdfParameters.bytes("S"),
            "The writer still rotates the KDF salt it was handed."
        )

        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalData)
    }

    func testEncryptionSettingsSaveMovesToAESKDFAndReopensUnderTheSameKey() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let original = try KDBXFileSummary.inspect(data: Data(contentsOf: databaseURL))
        guard case .argon2d = original.keyDerivation else {
            XCTFail("Fixture precondition: Argon2d, got \(original.keyDerivation)")
            return
        }
        let context = try makeCleanSaveContext(databaseURL: databaseURL)

        let result = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            encryptionSettings: EncryptionSettingsChange(
                kdfParameters: try EncryptionSettingsKeyDerivation.aesKDF(rounds: 10_000).kdfParameters()
            )
        )

        guard case .saved = result else {
            XCTFail("Expected the AES-KDF save to succeed.")
            return
        }
        let savedData = try Data(contentsOf: databaseURL)
        let saved = try KDBXFileSummary.inspect(data: savedData)
        XCTAssertEqual(saved.keyDerivation, .aesKDF(rounds: 10_000))
        XCTAssertEqual(saved.cipher, original.cipher, "AES-KDF must not change the outer cipher")
        XCTAssertEqual(saved.isCompressed, original.isCompressed)
        XCTAssertEqual(saved.formatVersion, original.formatVersion)

        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: savedData,
            compositeKey: context.compositeKey,
            sessionKey: SymmetricKey(size: .bits256),
            kdfPolicy: .autoFillExtension
        )
        XCTAssertEqual(
            reparsed.rootGroup.allEntries.map(\.title).sorted(),
            context.originalRootGroup.allEntries.map(\.title).sorted()
        )
        XCTAssertEqual((reparsed.header.kdfParameters.bytes("S"))?.count, 32)
    }

    func testEncryptionSettingsSaveKeepsUnchangedFields() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let original = try KDBXFileSummary.inspect(data: Data(contentsOf: databaseURL))
        let context = try makeCleanSaveContext(databaseURL: databaseURL)

        _ = try await LocalDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            kdfPolicy: .mainApp,
            encryptionSettings: EncryptionSettingsChange(compressionFlags: original.isCompressed ? 0 : 1)
        )

        let saved = try KDBXFileSummary.inspect(data: Data(contentsOf: databaseURL))
        XCTAssertEqual(saved.cipher, original.cipher)
        XCTAssertEqual(saved.keyDerivation, original.keyDerivation)
        XCTAssertEqual(saved.isCompressed, !original.isCompressed)
    }

    func testEncryptionSettingsSaveVerificationFailureLeavesFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        let context = try makeCleanSaveContext(databaseURL: databaseURL)
        let originalSHA512 = FileDigest.sha512(originalData)
        var environment = LocalDatabaseSaver.Environment.live
        let liveExtractHeader = environment.extractHeader
        environment.extractHeader = { data, key, kdfPolicy in
            guard FileDigest.sha512(data) == originalSHA512 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try liveExtractHeader(data, key, kdfPolicy)
        }

        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                kdfPolicy: .mainApp,
                encryptionSettings: EncryptionSettingsChange(cipherID: KDBXOuterCipher.chaCha20.uuid),
                environment: environment
            )
            XCTFail("Expected the encryption settings save to fail verification.")
        } catch let failure as LocalSaveBeforeReplacementFailure {
            XCTAssertEqual(failure.underlying as? SaveError, .reencryptionVerificationFailed)
        }

        XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    /// A real KDBX under the same key whose bytes differ from `databaseURL`'s
    /// — what another client would have left behind.
    // MARK: - Payload size limit

    func testSaveWithALargeAttachmentThatFitsReopensWithItsBytes() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        // A megabyte under the limit leaves room for the fixture's XML.
        let added = try makeAttachmentSaveContext(
            databaseURL: databaseURL,
            name: "large.bin",
            growingPoolTo: KDBXContainer.maxDecompressedPayloadSize - 1024 * 1024
        )

        _ = try await LocalDatabaseSaver.save(
            draft: added.context.draft,
            reference: reference,
            compositeKey: added.context.compositeKey,
            openTimeSHA512: added.context.openTimeSHA512
        )

        XCTAssertEqual(try attachmentBytes(in: databaseURL)["large.bin"], added.bytes)
    }

    func testSaveRefusesAnAttachmentThatLeavesNoRoomForTheXMLAndLeavesTheFileUntouched() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let originalData = try Data(contentsOf: databaseURL)
        // The draft accepts a pool that reaches the limit by itself; the XML
        // then takes the payload past what the reader inflates.
        let added = try makeAttachmentSaveContext(
            databaseURL: databaseURL,
            name: "large.bin",
            growingPoolTo: KDBXContainer.maxDecompressedPayloadSize
        )

        await assertSaveRefusesPayloadTooLarge(added.context, reference: reference)

        XCTAssertEqual(try Data(contentsOf: databaseURL), originalData)
    }

    func testSaveRefusesAttachmentsThatOnlyTogetherExceedTheReadLimit() async throws {
        let databaseURL = try makeScratchDatabaseCopy()
        let reference = try makeRegisteredReference(for: databaseURL)
        let first = try makeAttachmentSaveContext(
            databaseURL: databaseURL,
            name: "first.bin",
            growingPoolTo: KDBXContainer.maxDecompressedPayloadSize / 2
        )
        _ = try await LocalDatabaseSaver.save(
            draft: first.context.draft,
            reference: reference,
            compositeKey: first.context.compositeKey,
            openTimeSHA512: first.context.openTimeSHA512
        )
        let savedData = try Data(contentsOf: databaseURL)

        let second = try makeAttachmentSaveContext(
            databaseURL: databaseURL,
            name: "second.bin",
            growingPoolTo: KDBXContainer.maxDecompressedPayloadSize
        )
        await assertSaveRefusesPayloadTooLarge(second.context, reference: reference)

        XCTAssertEqual(try Data(contentsOf: databaseURL), savedData)
        let reopened = try attachmentBytes(in: databaseURL)
        XCTAssertEqual(reopened["first.bin"], first.bytes)
        XCTAssertNil(reopened["second.bin"])
    }

    private func assertSaveRefusesPayloadTooLarge(
        _ context: SaveContext,
        reference: DatabaseReference,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await LocalDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512
            )
            XCTFail("Expected the save to refuse a payload the reader cannot inflate.", file: file, line: line)
        } catch let failure as LocalSaveBeforeReplacementFailure {
            guard case KDBXContainerWriter.WriteError.payloadTooLarge = failure.underlying else {
                XCTFail("Expected payloadTooLarge, got \(failure)", file: file, line: line); return
            }
        } catch {
            XCTFail("Expected payloadTooLarge, got \(error)", file: file, line: line)
        }
    }

    /// A draft over the file at `databaseURL`, built with the file's pool as
    /// `DatabaseViewModel` builds it, that adds one entry carrying a new
    /// file. The file is sized so the pool then takes `poolByteCount` bytes
    /// of the inner header.
    private func makeAttachmentSaveContext(
        databaseURL: URL,
        name: String,
        growingPoolTo poolByteCount: Int
    ) throws -> (context: SaveContext, bytes: Data) {
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        XCTAssertEqual(parsed.header.compressionFlags, 1, "The limit applies to compressed payloads.")
        let pool = parsed.header.innerHeaderBinaryFields
        // Each field is a one-byte type, a four-byte length, and its value; a
        // pool entry's value is the file's bytes behind one flag byte.
        let fieldFraming = 5
        let openedPoolByteCount = pool.reduce(0) { $0 + fieldFraming + $1.count }
        var bytes = Data(count: poolByteCount - openedPoolByteCount - fieldFraming - 1)
        // Unlike any file already there, or the pool entry would be reused.
        bytes[0] = UInt8(pool.count + 1)

        let draft = try DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey,
            binaryPoolFields: pool
        ).apply(
            .createEntry(
                parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup),
                draft: EntryDraftPayload(
                    title: name,
                    password: "secret",
                    attachments: [.new(name: name, data: bytes)]
                )
            )
        )

        let context = SaveContext(
            draft: draft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(originalData),
            originalRootGroup: parsed.rootGroup
        )
        return (context, bytes)
    }

    /// Every attachment in the file at `databaseURL`, by name.
    private func attachmentBytes(in databaseURL: URL) throws -> [String: Data] {
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: try Data(contentsOf: databaseURL),
            password: fixturePassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        let pool = BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
        var bytes: [String: Data] = [:]
        for attachment in parsed.rootGroup.allEntries.flatMap(\.attachments) {
            bytes[attachment.name] = pool[attachment.ref]?.data
        }
        return bytes
    }

    private func makeDivergedDatabaseData(from databaseURL: URL) throws -> Data {
        let compositeKey = try KDBXCrypto.compositeKey(password: fixturePassword)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: try Data(contentsOf: databaseURL),
            compositeKey: compositeKey,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
        let parent = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup) == parsed.rootGroup.id
            ? parsed.rootGroup
            : parsed.rootGroup.groups[0]
        parent.entries.append(KPEntry(title: "Diverged \(UUID().uuidString)"))

        return try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            header: parsed.header,
            sessionKey: sessionKey,
            kdfPolicy: .mainApp
        )
    }

    private func makeDirtySaveContext(
        databaseURL: URL,
        entryTitle: String
    ) throws -> SaveContext {
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let cleanDraft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey
        )
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: entryTitle,
                    password: "secret-\(entryTitle)"
                )
            )
        )

        return SaveContext(
            draft: dirtyDraft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(originalData),
            originalRootGroup: parsed.rootGroup
        )
    }

    private func makeCleanSaveContext(databaseURL: URL) throws -> SaveContext {
        let originalData = try Data(contentsOf: databaseURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: originalData,
            password: fixturePassword,
            sessionKey: sessionKey
        )

        return SaveContext(
            draft: DatabaseDraft(rootGroup: parsed.rootGroup, meta: parsed.meta, sessionKey: sessionKey),
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: FileDigest.sha512(originalData),
            originalRootGroup: parsed.rootGroup
        )
    }

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
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-local-saver",
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

    private func makeScratchDatabaseCopy(fixtureName: String = "test") throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            named: fixtureName,
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scratchURL = scratchDirectory.appendingPathComponent("local-save.kdbx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data(contentsOf: fixtureURL).write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    private func makeScratchTwofishDatabase() throws -> URL {
        let fixtureURL = try TestDatabaseSupport.fixtureURL(
            named: "test",
            bundle: Bundle(for: LocalDatabaseSaverTests.self)
        )
        let sourceData = try Data(contentsOf: fixtureURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: sourceData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let compositeKey = KDBXCrypto.compositeKey(password: fixturePassword)
        let twofishData = try KDBXWriter.write(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            compositeKey: compositeKey,
            freshHeader: KDBXContainerWriter.FreshHeaderConfiguration(
                cipher: .twofish256CBC,
                kdfParameters: parsed.header.kdfParameters,
                innerHeaderBinaryFields: parsed.header.innerHeaderBinaryFields
            ),
            sessionKey: sessionKey
        )

        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scratchURL = scratchDirectory.appendingPathComponent("twofish-save.kdbx", isDirectory: false)
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try twofishData.write(to: scratchURL, options: .atomic)
        return scratchURL
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

private struct SaveContext {
    let draft: DatabaseDraft
    let compositeKey: SymmetricKey
    let openTimeSHA512: Data
    let originalRootGroup: KPGroup
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class DateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}

private struct TimeoutError: Error {}
