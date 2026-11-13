import CryptoKit
import Darwin
import os
import KDBXKit
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListViewModelTests: XCTestCase {
    private let autoFillSuiteName = "DatabaseListViewModelTests.AutoFill"
    private let macAppSuggestionSuiteName = "DatabaseListViewModelTests.MacAppSuggestion"

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        SettingsService.showDatabaseUsageStats = true
        AutoFillStatusService.defaults = UserDefaults(suiteName: autoFillSuiteName)!
        AutoFillStatusService.resetForTesting()
        MacAppSuggestionService.defaults = UserDefaults(suiteName: macAppSuggestionSuiteName)!
        MacAppSuggestionService.resetForTesting()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        SettingsService.showDatabaseUsageStats = true
        AutoFillStatusService.resetForTesting()
        AutoFillStatusService.defaults = .standard
        UserDefaults.standard.removePersistentDomain(forName: autoFillSuiteName)
        MacAppSuggestionService.resetForTesting()
        MacAppSuggestionService.defaults = .standard
        UserDefaults.standard.removePersistentDomain(forName: macAppSuggestionSuiteName)
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    func testSameEpochSelectClearPreservesKeyTargetThenAllowsExplicitSave() async throws {
        let setup = try await makePreferenceDatabase()
        defer { setup.database.lock() }
        let before = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        let target = try Data(contentsOf: setup.url)
        var io = DatabaseListStore.KeyFilePreferenceIO()
        io.registry.synchronizeFile = { descriptor in
            XCTAssertFalse(Thread.isMainThread)
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        }
        let preferences = DatabaseListViewModel(keyFilePreferenceIO: io)
        try await preferences.setKeyFile(url: setup.secondKeyURL, for: setup.reference)
        let selected = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == setup.reference.id })
        XCTAssertEqual(selected.keyFileFilename, setup.secondKeyURL.lastPathComponent)
        XCTAssertEqual(selected.lastMasterKeyChangeAt, setup.reference.lastMasterKeyChangeAt)
        let afterSelect = try PendingLocalSaveStore.recovery(for: selected.id)
        XCTAssertEqual(afterSelect.keyEvidence?.targetState, before.keyEvidence?.targetState)
        XCTAssertEqual(afterSelect.keyEvidence?.epochID, before.keyEvidence?.epochID)
        XCTAssertNotEqual(afterSelect.associationVersion, before.associationVersion)
        XCTAssertEqual(afterSelect.receipts, before.receipts)
        try await preferences.setKeyFile(url: nil, for: selected)
        let cleared = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == selected.id })
        XCTAssertNil(cleared.keyFileBookmarkData)
        XCTAssertNil(cleared.keyFileFilename)
        XCTAssertEqual(try Data(contentsOf: setup.url), target)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
        XCTAssertEqual(setup.effects.withLock { $0.providers }, 0)
        try setup.database.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: XCTUnwrap(setup.database.rootGroup)),
            draft: EntryDraftPayload(title: "After Preference", password: "unchanged master key")))
        try await setup.database.save()
        let reopened = try KDBXParser.parse(data: Data(contentsOf: setup.url), password: "preference epoch key",
            keyFileData: setup.keyFileData, sessionKey: SymmetricKey(size: .bits256))
        XCTAssertTrue(reopened.allEntries.contains { $0.title == "After Preference" })
        XCTAssertEqual(setup.effects.withLock { $0.rekeys }, 1)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 2)
    }

    func testKnownUnconfirmedTargetAllowsPreferenceAndFutureExplicitWriteWithoutRepeatingRekey() async throws {
        let setup = try await makePreferenceDatabase(denyTargetDirectorySync: true)
        defer { setup.database.lock() }
        let before = try XCTUnwrap(PendingLocalSaveStore.recovery(for: setup.reference.id).keyEvidence)
        XCTAssertTrue(before.targetDurabilityUnconfirmed)
        let preferences = DatabaseListViewModel()
        try await preferences.setKeyFile(url: setup.secondKeyURL, for: setup.reference)
        let selected = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == setup.reference.id })
        let after = try XCTUnwrap(PendingLocalSaveStore.recovery(for: selected.id).keyEvidence)
        XCTAssertEqual(after.targetState, before.targetState)
        XCTAssertEqual(after.epochID, before.epochID)
        XCTAssertEqual(selected.lastMasterKeyChangeAt, setup.reference.lastMasterKeyChangeAt)
        try setup.database.applyEntryEdit(.createEntry(parentGroupID: TestDatabaseSupport.visibleRootGroupID(in: XCTUnwrap(setup.database.rootGroup)),
            draft: EntryDraftPayload(title: "Future Explicit Write", password: "preserve")))
        do { try await setup.database.save(); XCTFail("Persistent parent denial still needs a file warning") }
        catch { XCTAssertTrue(error is SaveDurabilityWarning) }
        XCTAssertEqual(setup.effects.withLock { $0.rekeys }, 1)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 2)
        XCTAssertTrue(try XCTUnwrap(PendingLocalSaveStore.recovery(for: selected.id).keyEvidence).targetDurabilityUnconfirmed)
    }

    func testPreferencePublicationFaultsRetainExactDesiredChoiceForExplicitRestartRecovery() async throws {
        for phase in ["before-registry", "after-registry", "owner-completion"] {
            let setup = try await makePreferenceDatabase()
            defer { setup.database.lock() }
            let before = try PendingLocalSaveStore.recovery(for: setup.reference.id)
            let registry = AppGroupContainer.url.appendingPathComponent("database-list.json")
            let oldRegistry = try Data(contentsOf: registry)
            var io = DatabaseListStore.KeyFilePreferenceIO()
            let ownerWrites = OSAllocatedUnfairLock(initialState: 0)
            if phase == "before-registry" { io.registry.write = { _, _, _ in 0 } }
            if phase == "after-registry" { io.registry.afterPublication = { _ in throw POSIXError(.EIO) } }
            if phase == "owner-completion" {
                io.owner.fileIO = { destination in
                    var writer = DurableFileWriteIO()
                    if destination.lastPathComponent == "owner.json" {
                        let number = ownerWrites.withLock { value in value += 1; return value }
                        if number > 1 { writer.write = { _, _, _ in 0 } }
                    }
                    return writer
                }
            }
            let preferences = DatabaseListViewModel(keyFilePreferenceIO: io)
            do { try await preferences.setKeyFile(url: setup.secondKeyURL, for: setup.reference); XCTFail("Expected a typed preference outcome") }
            catch let failure as DatabaseListStore.KeyFilePreferenceError {
                XCTAssertEqual(failure.outcome, phase == "before-registry" ? .notPublished : .publishedWithoutConfirmedDurability)
            }
            let interrupted = try PendingLocalSaveStore.recovery(for: setup.reference.id)
            XCTAssertEqual(interrupted.keyEvidence?.targetState, before.keyEvidence?.targetState)
            XCTAssertEqual(interrupted.keyEvidence?.epochID, before.keyEvidence?.epochID)
            XCTAssertEqual(interrupted.receipts, before.receipts)
            if phase == "before-registry" {
                XCTAssertEqual(try Data(contentsOf: registry), oldRegistry)
                XCTAssertNil(interrupted.preferenceIntent)
            } else {
                let intent = try XCTUnwrap(interrupted.preferenceIntent)
                XCTAssertEqual(intent.desired.filename, setup.secondKeyURL.lastPathComponent)
                let recovery = PendingLocalRecoveryViewModel(databaseID: setup.reference.id)
                await recovery.refresh()
                await recovery.confirmInstalledKeyChange(reference: setup.reference, snapshot: try XCTUnwrap(recovery.snapshot))
                XCTAssertNil(recovery.errorMessage)
                let settled = try PendingLocalSaveStore.recovery(for: setup.reference.id)
                XCTAssertNil(settled.preferenceIntent)
                XCTAssertEqual(settled.keyEvidence?.association.filename, setup.secondKeyURL.lastPathComponent)
                let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == setup.reference.id })
                XCTAssertEqual(stored.keyFileFilename, setup.secondKeyURL.lastPathComponent)
                let restarted = DatabaseViewModel(databaseReference: stored, quickUnlockKeyPersistOperation: { _, _, _ in false })
                await restarted.unlock(password: "preference epoch key")
                XCTAssertEqual(restarted.state, .unlocked)
                restarted.lock()
                XCTAssertEqual(DatabaseListStore.databases.first { $0.id == stored.id }?.keyFileFilename, setup.secondKeyURL.lastPathComponent)
            }
            XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
            XCTAssertEqual(setup.effects.withLock { $0.providers }, 0)
        }
    }

    func testStaleSelectCannotOverwriteNewerSelectionRekeyOrRemoval() async throws {
        for newer in ["selection", "rekey", "removal"] {
            let setup = try await makePreferenceDatabase()
            defer { setup.database.lock() }
            let gate = InFlightSaveGate()
            let firstWindow = DatabaseListViewModel(keyFileBookmarkOperation: { url in
                await gate.parkFirstCall()
                return try await Task.detached { try SecurityScopedBookmarkManager.makeBookmarkData(for: url, readOnly: true) }.value
            })
            let pending = Task { try await firstWindow.setKeyFile(url: setup.firstKeyURL, for: setup.reference) }
            await gate.firstCallStarted()
            if newer == "selection" { try await DatabaseListViewModel().setKeyFile(url: setup.secondKeyURL, for: setup.reference) }
            else if newer == "rekey" {
                try await setup.database.changeMasterKey(newPassword: "a later epoch", newKeyFileData: setup.keyFileData,
                    newKeyFileBookmarkData: setup.reference.keyFileBookmarkData, newKeyFileFilename: setup.reference.keyFileFilename)
            } else { XCTAssertTrue(DatabaseListStore.remove(id: setup.reference.id)) }
            let currentRegistry = try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json"))
            let version = try PendingLocalSaveStore.recovery(for: setup.reference.id).associationVersion
            await gate.releaseFirstCall()
            do { try await pending.value; XCTFail("Stale select must be rejected") }
            catch { XCTAssertTrue(error is DatabaseListStore.KeyFilePreferenceError) }
            XCTAssertEqual(try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json")), currentRegistry)
            XCTAssertEqual(try PendingLocalSaveStore.recovery(for: setup.reference.id).associationVersion, version)
            XCTAssertEqual(setup.effects.withLock { $0.encryptions }, newer == "rekey" ? 2 : 1)
            XCTAssertEqual(setup.effects.withLock { $0.providers }, 0)
        }
    }

    func testAutomaticBookmarkRenewalCannotRevertASelectionPublishedDuringResolution() async throws {
        let setup = try await makePreferenceDatabase()
        defer { setup.database.lock() }
        let newerBookmark = try SecurityScopedBookmarkManager.makeBookmarkData(for: setup.secondKeyURL, readOnly: true)
        let reference = setup.reference
        let firstURL = setup.firstKeyURL
        let desired = PendingLocalSaveStore.KeyFilePreference(bookmarkData: newerBookmark, filename: setup.secondKeyURL.lastPathComponent)
        let outcome = await Task.detached {
            DatabaseListStore.renewKeyFileBookmark(for: reference, resolve: { _ in (url: firstURL, isStale: true) }, makeBookmark: { url in
                let newerToken = try DatabaseListStore.prepareKeyFilePreference(for: reference)
                XCTAssertEqual(DatabaseListStore.publishKeyFilePreference(newerToken, desired: desired), .saved)
                return try SecurityScopedBookmarkManager.makeBookmarkData(for: url, readOnly: true)
            })
        }.value
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == reference.id }?.keyFileBookmarkData, newerBookmark)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
    }

    func testCloudKeyFilePreferenceNeverCreatesLocalAdmissionOrChangesCloudMetadata() async throws {
        let file = CloudFile(id: "/cloud.kdbx", name: "cloud.kdbx", path: "/cloud.kdbx", isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 100), size: 128)
        let reference = DatabaseListStore.addCloud(provider: CloudProviderKind.dropbox.rawValue, accountId: "preference-only", file: file)
        let keyURL = try makeTemporaryFileURL(name: "cloud.keyx", contents: Data(repeating: 1, count: 32))
        var io = DatabaseListStore.KeyFilePreferenceIO()
        io.registry.afterPublication = { _ in throw POSIXError(.EIO) }
        let vm = DatabaseListViewModel(keyFilePreferenceIO: io)
        do { try await vm.setKeyFile(url: keyURL, for: reference); XCTFail("Expected preference publication warning") }
        catch let error as DatabaseListStore.KeyFilePreferenceError { XCTAssertEqual(error.outcome, .publishedWithoutConfirmedDurability) }
        let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == reference.id })
        XCTAssertEqual(stored.keyFileFilename, keyURL.lastPathComponent)
        XCTAssertEqual(stored.cloudSyncMetadata, reference.cloudSyncMetadata)
        XCTAssertEqual(stored.lastMasterKeyChangeAt, reference.lastMasterKeyChangeAt)
        let owner = try PendingLocalSaveStore.recovery(for: reference.id)
        XCTAssertNil(owner.preferenceIntent)
        XCTAssertNil(owner.keyEvidence)
        XCTAssertNil(owner.admission)
        guard case .missing = owner.ownerObservation else { return XCTFail("Cloud selection must not publish local owner state") }
        XCTAssertFalse(PendingLocalSaveStore.hasSaves(for: reference.id))
    }

    func testSameValuePreferencePublicationStillInvalidatesAnOlderAssociationGeneration() async throws {
        let setup = try await makePreferenceDatabase()
        defer { setup.database.lock() }
        let reference = setup.reference
        let token = try await Task.detached { try DatabaseListStore.prepareKeyFilePreference(for: reference) }.value
        let desired = PendingLocalSaveStore.KeyFilePreference(reference)
        let newer = try await Task.detached { try DatabaseListStore.prepareKeyFilePreference(for: reference) }.value
        let published = await Task.detached { DatabaseListStore.publishKeyFilePreference(newer, desired: desired) }.value
        XCTAssertEqual(published, .saved)
        let before = try PendingLocalSaveStore.recovery(for: reference.id)
        let registry = try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json"))
        let stale = await Task.detached { DatabaseListStore.publishKeyFilePreference(token,
            desired: .init(bookmarkData: nil, filename: nil)) }.value
        XCTAssertEqual(stale, .rejected)
        XCTAssertEqual(try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json")), registry)
        XCTAssertEqual(try PendingLocalSaveStore.recovery(for: reference.id).associationVersion, before.associationVersion)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
    }

    func testCancelledSelectionCannotPublishAfterANewerSelectionInTheSameWindow() async throws {
        let setup = try await makePreferenceDatabase()
        defer { setup.database.lock() }
        let gate = InFlightSaveGate()
        let preferences = DatabaseListViewModel(keyFileBookmarkOperation: { url in
            if url.lastPathComponent == "first.keyx" { await gate.parkFirstCall() }
            return try await Task.detached { try SecurityScopedBookmarkManager.makeBookmarkData(for: url, readOnly: true) }.value
        })
        let first = Task { try await preferences.setKeyFile(url: setup.firstKeyURL, for: setup.reference) }
        await gate.firstCallStarted()
        preferences.cancelKeyFilePreference(for: setup.reference.id)
        XCTAssertFalse(preferences.isChangingKeyFile(for: setup.reference.id))
        first.cancel()
        try await preferences.setKeyFile(url: setup.secondKeyURL, for: setup.reference)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first { $0.id == setup.reference.id })
        await gate.releaseFirstCall()
        do { try await first.value; XCTFail("Cancelled selection must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(DatabaseListStore.databases.first { $0.id == stored.id }?.keyFileBookmarkData, stored.keyFileBookmarkData)
        XCTAssertEqual(stored.keyFileFilename, setup.secondKeyURL.lastPathComponent)
        XCTAssertFalse(preferences.isChangingKeyFile(for: stored.id))
        XCTAssertNil(try PendingLocalSaveStore.recovery(for: stored.id).preferenceIntent)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
    }

    func testPreferenceRejectsAnActiveSourceAdmissionAndLegacySelectionInventsNoEpoch() async throws {
        let setup = try await makePreferenceDatabase()
        defer { setup.database.lock() }
        let bytes = try Data(contentsOf: setup.url)
        let prepared = try PendingLocalSaveStore.prepareSource(bytes, for: setup.reference.id,
            masterKeyChangedAt: setup.reference.lastMasterKeyChangeAt, baseCacheSHA512: FileDigest.sha512(bytes))
        try writeAtomicallyAndDurably(bytes, to: PendingLocalSaveStore.sharedCopyURL(for: setup.reference.id), directoryAnchor: AppGroupContainer.url)
        XCTAssertEqual(PendingLocalSaveStore.activateSource(prepared), .accepted)
        let beforePreference = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        try await DatabaseListViewModel().setKeyFile(url: setup.secondKeyURL, for: setup.reference)
        let afterPreference = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertEqual(afterPreference.receipts, beforePreference.receipts)
        XCTAssertEqual(afterPreference.keyEvidence?.targetState, beforePreference.keyEvidence?.targetState)
        XCTAssertEqual(afterPreference.keyEvidence?.epochID, beforePreference.keyEvidence?.epochID)
        XCTAssertEqual(PendingLocalSaveStore.saves(for: setup.reference.id).map(\.fileURL), [prepared.save.fileURL])
        XCTAssertEqual(try Data(contentsOf: prepared.save.fileURL), bytes)
        let admission = try PendingLocalSaveStore.admit([prepared.receipt], for: setup.reference.id,
            target: LocalDatabaseSaver.captureTarget(for: setup.reference), baseline: FileDigest.sha512(bytes),
            masterKeyChangedAt: setup.reference.lastMasterKeyChangeAt)
        let oldRegistry = try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json"))
        do { try await DatabaseListViewModel().setKeyFile(url: nil, for: setup.reference); XCTFail("Admission cannot be cleared by preference selection") }
        catch { XCTAssertTrue(error is PendingLocalSaveStore.OwnershipError) }
        let unchanged = try PendingLocalSaveStore.recovery(for: setup.reference.id)
        XCTAssertEqual(unchanged.admission, admission.admission)
        XCTAssertEqual(unchanged.receipts, [prepared.receipt])
        XCTAssertEqual(try Data(contentsOf: AppGroupContainer.url.appendingPathComponent("database-list.json")), oldRegistry)
        XCTAssertEqual(setup.effects.withLock { $0.encryptions }, 1)
        let legacy = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "legacy-preference.kdbx"))
        let legacyList = DatabaseListViewModel()
        try await legacyList.setKeyFile(url: setup.secondKeyURL, for: legacy)
        let legacyState = try PendingLocalSaveStore.recovery(for: legacy.id)
        XCTAssertNil(legacyState.keyEvidence)
        XCTAssertNil(legacyState.admission)
        XCTAssertNil(legacyState.preferenceIntent)
        XCTAssertNil(DatabaseListStore.databases.first { $0.id == legacy.id }?.lastMasterKeyChangeAt)
    }

    private func makePreferenceDatabase(denyTargetDirectorySync: Bool = false) async throws -> (
        database: DatabaseViewModel, reference: DatabaseReference, url: URL, firstKeyURL: URL, secondKeyURL: URL,
        keyFileData: Data, effects: OSAllocatedUnfairLock<(encryptions: Int, rekeys: Int, providers: Int)>
    ) {
        let fixture = KDBXTestFixture.test
        let url = try makeTemporaryFileURL(name: "preference-target.kdbx", contents: fixture.data(in: Bundle(for: Self.self)))
        let first = url.deletingLastPathComponent().appendingPathComponent("first.keyx")
        let second = url.deletingLastPathComponent().appendingPathComponent("second.keyx")
        let keyFileData = Data(repeating: 0x4A, count: 32)
        try keyFileData.write(to: first)
        try keyFileData.write(to: second)
        let reference = try DatabaseListStore.add(url: url)
        let effects = OSAllocatedUnfairLock(initialState: (encryptions: 0, rekeys: 0, providers: 0))
        let live = LocalDatabaseSaver.Environment.live
        let database = DatabaseViewModel(databaseReference: reference, localSaveOperation: { draft, ref, key, hash, reconciled, newKey, settings in
            if newKey != nil { effects.withLock { $0.rekeys += 1 } }
            var environment = live
            environment.encryptDraft = { draft, key, header, policy in
                effects.withLock { $0.encryptions += 1 }; return try live.encryptDraft(draft, key, header, policy)
            }
            if denyTargetDirectorySync {
                environment.replaceFileAtomically = { data, target, baseline, authorization in
                    var io = LocalDatabaseSaver.ReplacementIO()
                    io.synchronize = { _ in throw POSIXError(.EACCES) }
                    return try LocalDatabaseSaver.replaceFileAtomically(data, at: target, expectedSHA512: baseline, authorization: authorization, io: io)
                }
            }
            return try await LocalDatabaseSaver.save(draft: draft, reference: ref, compositeKey: key,
                openTimeSHA512: hash, reconciledRemoteSHA512: reconciled, kdfPolicy: .mainApp,
                newCompositeKey: newKey, encryptionSettings: settings, environment: environment)
        }, cloudSaveOperation: { _, _, _, _, _, _, _, _ in
            effects.withLock { $0.providers += 1 }; throw SaveError.saveContextUnavailable
        }, quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await database.unlock(password: fixture.password)
        do {
            try await database.changeMasterKey(newPassword: "preference epoch key", newKeyFileData: keyFileData,
                newKeyFileBookmarkData: SecurityScopedBookmarkManager.makeBookmarkData(for: first, readOnly: true), newKeyFileFilename: first.lastPathComponent)
            if denyTargetDirectorySync { XCTFail("Expected directory warning") }
        } catch { if denyTargetDirectorySync { XCTAssertTrue(error is SaveDurabilityWarning) } else { throw error } }
        return (database, database.databaseReference, url, first, second, keyFileData, effects)
    }

    func testMoveDatabasesPublishesTheNewOrderImmediately() throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))

        let viewModel = DatabaseListViewModel()
        XCTAssertEqual(viewModel.databases.map(\.id), [first.id, second.id])

        viewModel.moveDatabases(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(
            viewModel.databases.map(\.id),
            [second.id, first.id],
            "The published list must carry the new order without waiting for a reload"
        )
    }

    #if os(macOS)
    func testSetKeyFilePersistsLockedFileAssociation() async throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "locked-key.kdbx"))
        let keyFileURL = try makeTemporaryFileURL(name: "locked.keyx")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: keyFileURL.path)
            try? FileManager.default.removeItem(at: keyFileURL.deletingLastPathComponent())
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: keyFileURL.path)

        try await DatabaseListViewModel().setKeyFile(url: keyFileURL, for: reference)

        let reloaded = DatabaseListViewModel()
        let stored = try XCTUnwrap(reloaded.databases.first)
        XCTAssertEqual(stored.keyFileFilename, "locked.keyx")
        XCTAssertNotNil(stored.keyFileBookmarkData)
        let resolved = try XCTUnwrap(DatabaseListStore.resolveKeyFileURL(for: stored))
        XCTAssertEqual(try Data(contentsOf: resolved), try Data(contentsOf: keyFileURL))
    }
    #endif

    func testMoveDatabasesDropsBetweenLaterRows() throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))
        let third = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "three.kdbx"))

        let viewModel = DatabaseListViewModel()

        // SwiftUI reports the drop index in the pre-move list, so dropping the
        // first row between the second and third arrives as destination 2.
        viewModel.moveDatabases(from: IndexSet(integer: 0), to: 2)

        XCTAssertEqual(viewModel.databases.map(\.id), [second.id, first.id, third.id])
    }

    func testLocalRowStatusDefersBookmarkAccessUntilOpen() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "offline-share.kdbx"))
        reference.bookmarkData = Data("unresolvable-offline-bookmark".utf8)
        DatabaseListStore.update(reference)

        let viewModel = DatabaseListViewModel()

        XCTAssertFalse(viewModel.status(for: reference).hasAccessIssue)
    }

    func testDocumentsResidentRowShowsFileMissingOnlyWhileFileIsGone() throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try Data("fixture".utf8).write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)

        let viewModel = DatabaseListViewModel()
        XCTAssertFalse(viewModel.status(for: reference).isDocumentsFileMissing)

        try FileManager.default.removeItem(at: fileURL)
        viewModel.reload()
        XCTAssertTrue(viewModel.status(for: reference).isDocumentsFileMissing)
        XCTAssertFalse(viewModel.status(for: reference).hasAccessIssue)

        // A restored (or replaced) file is rebindable, hence not "missing" —
        // even while the bookmark is still stranded. The pure status check
        // never heals; the locate paths (unlock/save/scan) do.
        try Data("restored".utf8).write(to: fileURL)
        viewModel.reload()
        XCTAssertFalse(viewModel.status(for: reference).isDocumentsFileMissing)
    }

    func testSingleDatabaseDoesNotAutoOpenWhenQuickLaunchIsOff() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        let viewModel = DatabaseListViewModel()

        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch())
    }

    func testSingleDatabaseAutoOpensWhenQuickLaunchIsOn() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        reference.isQuickLaunch = true
        DatabaseListStore.update(reference)

        let viewModel = DatabaseListViewModel()

        XCTAssertEqual(viewModel.databaseToAutoOpenOnLaunch()?.id, reference.id)
        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch(), "Initial launch selection should only be consumed once")
    }

    func testQuickLaunchDatabaseAutoOpensAmongMultipleDatabases() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        var second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))
        second.isQuickLaunch = true
        DatabaseListStore.update(second)

        let viewModel = DatabaseListViewModel()

        XCTAssertEqual(viewModel.databaseToAutoOpenOnLaunch()?.id, second.id)
        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch(), "Initial launch selection should only be consumed once")
    }

    func testMultipleDatabasesDoNotAutoOpenWhenQuickLaunchIsOff() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))
        let viewModel = DatabaseListViewModel()

        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch())
    }

    func testToggleQuickLaunchClearsPreviousSelection() throws {
        var first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))
        first.isQuickLaunch = true
        DatabaseListStore.update(first)

        let viewModel = DatabaseListViewModel()
        viewModel.toggleQuickLaunch(for: second)

        let updatedFirst = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == first.id }))
        let updatedSecond = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == second.id }))

        XCTAssertFalse(updatedFirst.isQuickLaunch)
        XCTAssertTrue(updatedSecond.isQuickLaunch)
    }

    func testSetReadOnlyPersistsFlag() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "readonly.kdbx"))
        let viewModel = DatabaseListViewModel()

        viewModel.setReadOnly(true, for: reference)

        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertTrue(updatedReference.isReadOnly)
    }

    func testSetNicknamePersistsAndRefreshesList() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        let viewModel = DatabaseListViewModel()

        viewModel.setNickname("Work Vault", for: reference)

        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(updatedReference.nickname, "Work Vault")
        XCTAssertEqual(viewModel.databases.first(where: { $0.id == reference.id })?.displayName, "Work Vault")
    }

    // MARK: - Per-database AutoFill toggle

    /// The store-owned "targeted removal, never a whole-store clear"
    /// invariant is exhaustively covered by DatabaseListStoreTests.swift; this
    /// only proves the view model delegates to
    /// `DatabaseListStore.setAutoFillEnabled` and that `reload()` refreshes
    /// its own `databases` copy of the persisted flag.
    func testSetAutoFillEnabledFalseDelegatesToStoreAndReloadsDatabases() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "autofill-off.kdbx"))
        let viewModel = DatabaseListViewModel()
        XCTAssertEqual(viewModel.databases.first(where: { $0.id == reference.id })?.autoFillEnabled, true)

        viewModel.setAutoFillEnabled(false, for: reference)

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertFalse(storedReference.autoFillEnabled, "setAutoFillEnabled must delegate to DatabaseListStore")
        let reloadedReference = try XCTUnwrap(viewModel.databases.first(where: { $0.id == reference.id }))
        XCTAssertFalse(reloadedReference.autoFillEnabled, "reload() should refresh the view model's copy of the flag")
    }

    func testSetAutoFillEnabledTrueInvokesRefreshHandlerWithDatabaseID() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "refresh-on-enable.kdbx"))
        let viewModel = DatabaseListViewModel()

        var refreshedDatabaseIDs: [UUID] = []
        viewModel.autoFillEnabledRefreshHandler = { refreshedDatabaseIDs.append($0) }

        viewModel.setAutoFillEnabled(false, for: reference)
        viewModel.setAutoFillEnabled(true, for: reference)

        XCTAssertEqual(
            refreshedDatabaseIDs,
            [reference.id],
            "The refresh handler must fire exactly once, with the reference's id, and only for the enable"
        )
    }

    func testSetAutoFillEnabledFalseDoesNotInvokeRefreshHandler() throws {
        let reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "no-refresh-on-disable.kdbx"))
        let viewModel = DatabaseListViewModel()

        viewModel.autoFillEnabledRefreshHandler = { _ in
            XCTFail("Disable is removal-only; there is nothing to republish, so the refresh handler must stay silent")
        }

        viewModel.setAutoFillEnabled(false, for: reference)

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertFalse(storedReference.autoFillEnabled)
    }

    func testDisablingActiveDatabaseThroughViewModelReassignsPointerAndPassesLegacyFlag() async throws {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "active.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "fallback.kdbx"))
        DatabaseListStore.markDatabaseOpened(id: second.id, at: Date(timeIntervalSinceNow: -60))
        DatabaseListStore.markDatabaseOpened(id: first.id, at: .now)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, first.id)
        let viewModel = DatabaseListViewModel()

        let removalExpectation = expectation(description: "Targeted identity removal for the disabled active database")
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            XCTAssertEqual(databaseID, first.id)
            XCTAssertTrue(
                includingLegacyIdentifiers,
                "Disabling the active database must sweep legacy bare-UUID identifiers"
            )
            removalExpectation.fulfill()
        }

        viewModel.setAutoFillEnabled(false, for: first)

        await fulfillment(of: [removalExpectation], timeout: 1)
        XCTAssertEqual(
            DatabaseListStore.activeAutoFillDatabaseID,
            second.id,
            "The pointer must move to the most recently opened remaining enabled database"
        )
    }

    func testAddCloudDatabaseCreatesCloudReferenceFromSelection() {
        let selection = CloudDatabaseSelection(
            provider: CloudProviderKind.dropbox.rawValue,
            account: CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: CloudProviderKind.dropbox.rawValue),
            file: CloudFile(
                id: "/Vaults/personal.kdbx",
                name: "personal.kdbx",
                path: "/Vaults/personal.kdbx",
                isFolder: false,
                modifiedDate: Date(timeIntervalSince1970: 100),
                size: 128
            )
        )
        let viewModel = DatabaseListViewModel()

        let reference = viewModel.addCloudDatabase(selection: selection)

        XCTAssertTrue(reference.isCloudBacked)
        XCTAssertEqual(reference.cloudSyncMetadata?.accountId, "acct-1")
        XCTAssertEqual(viewModel.databases.count, 1)
    }

    func testCloudRowStatusUsesConnectedAccountAndStaleWarningWhenCached() throws {
        let file = CloudFile(
            id: "/Vaults/personal.kdbx",
            name: "personal.kdbx",
            path: "/Vaults/personal.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 100),
            size: 128
        )
        var reference = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        reference.updateCloudSyncMetadata { metadata in
            metadata.lastSyncedAt = Date(timeIntervalSinceNow: -90_000)
        }
        DatabaseListStore.update(reference)
        try DatabaseListStore.cacheDatabaseCopy(Data("cached".utf8), for: reference)
        CloudAccountStore.upsert(
            CloudAccount(id: "acct-1", displayName: "alex@example.com", provider: CloudProviderKind.dropbox.rawValue)
        )

        let viewModel = DatabaseListViewModel()
        let status = viewModel.status(for: reference)

        XCTAssertFalse(status.hasAccessIssue)
        XCTAssertEqual(
            status.cloudState,
            CloudRowState(
                providerName: "Dropbox",
                isConnected: true,
                warningText: "Sync older than 24h",
                displayPath: "/Vaults/personal.kdbx",
                accountLabel: "alex@example.com"
            )
        )
    }

    func testCloudRowStatusMarksDisconnectedDatabaseWithoutCacheAsUnavailable() {
        let file = CloudFile(
            id: "/Vaults/work.kdbx",
            name: "work.kdbx",
            path: "/Vaults/work.kdbx",
            isFolder: false,
            modifiedDate: nil,
            size: nil
        )
        let reference = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )

        let viewModel = DatabaseListViewModel()
        let status = viewModel.status(for: reference)

        XCTAssertTrue(status.hasAccessIssue)
        XCTAssertEqual(status.cloudState?.isConnected, false)
        XCTAssertEqual(status.cloudState?.warningText, "Disconnected")
        XCTAssertEqual(status.cloudState?.accountLabel, "acct-1")
    }

    func testLastOpenedDescriptionReturnsTextWhenUsageStatsAreEnabled() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        reference.lastOpenedAt = Date().addingTimeInterval(-3_600)
        DatabaseListStore.update(reference)

        let viewModel = DatabaseListViewModel()

        XCTAssertNotNil(viewModel.lastOpenedDescription(for: reference))
    }

    func testLastOpenedDescriptionHidesWhenUsageStatsAreDisabled() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "private.kdbx"))
        reference.lastOpenedAt = Date().addingTimeInterval(-3_600)
        DatabaseListStore.update(reference)
        SettingsService.showDatabaseUsageStats = false

        let viewModel = DatabaseListViewModel()

        XCTAssertNil(viewModel.lastOpenedDescription(for: reference))
    }

    // MARK: - AutoFill enablement tip

    func testAutoFillTipHiddenBeforeStatusCheck() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        let viewModel = DatabaseListViewModel()

        XCTAssertFalse(viewModel.shouldShowAutoFillTip)
    }

    func testAutoFillTipShownWhenProviderDisabled() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        let viewModel = DatabaseListViewModel()

        await viewModel.refreshAutoFillStatus()

        XCTAssertTrue(viewModel.shouldShowAutoFillTip)
    }

    func testAutoFillTipHiddenWhenProviderEnabled() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { true }
        let viewModel = DatabaseListViewModel()

        await viewModel.refreshAutoFillStatus()

        XCTAssertFalse(viewModel.shouldShowAutoFillTip)
    }

    func testAutoFillTipHiddenWhenDatabaseListIsEmpty() async {
        AutoFillStatusService.enabledProvider = { false }
        let viewModel = DatabaseListViewModel()

        await viewModel.refreshAutoFillStatus()

        XCTAssertFalse(viewModel.shouldShowAutoFillTip)
    }

    func testDismissAutoFillTipHidesAndPersists() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()
        XCTAssertTrue(viewModel.shouldShowAutoFillTip)

        viewModel.dismissAutoFillTip()

        XCTAssertFalse(viewModel.shouldShowAutoFillTip)
        XCTAssertTrue(AutoFillStatusService.tipDismissed)

        let freshViewModel = DatabaseListViewModel()
        await freshViewModel.refreshAutoFillStatus()
        XCTAssertFalse(freshViewModel.shouldShowAutoFillTip)
    }

    // MARK: - Native Mac app suggestion

    func testMacAppSuggestionHiddenOffTheiOSAppOnMac() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        MacAppSuggestionService.isiOSAppOnMac = { false }
        let viewModel = DatabaseListViewModel()

        XCTAssertFalse(viewModel.shouldShowMacAppSuggestion)
    }

    func testMacAppSuggestionShownForTheiOSAppOnMac() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        MacAppSuggestionService.isiOSAppOnMac = { true }
        let viewModel = DatabaseListViewModel()

        XCTAssertTrue(viewModel.shouldShowMacAppSuggestion)
    }

    func testMacAppSuggestionShownWhenDatabaseListIsEmpty() {
        MacAppSuggestionService.isiOSAppOnMac = { true }
        let viewModel = DatabaseListViewModel()

        XCTAssertTrue(viewModel.shouldShowMacAppSuggestion)
    }

    func testDismissMacAppSuggestionHidesAndPersists() {
        MacAppSuggestionService.isiOSAppOnMac = { true }
        let viewModel = DatabaseListViewModel()
        XCTAssertTrue(viewModel.shouldShowMacAppSuggestion)

        viewModel.dismissMacAppSuggestion()

        XCTAssertFalse(viewModel.shouldShowMacAppSuggestion)
        XCTAssertTrue(MacAppSuggestionService.isDismissed)
        XCTAssertFalse(DatabaseListViewModel().shouldShowMacAppSuggestion)
    }

    func testDismissingOneBannerLeavesTheOtherUp() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        MacAppSuggestionService.isiOSAppOnMac = { true }
        AutoFillStatusService.enabledProvider = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()

        viewModel.dismissMacAppSuggestion()

        XCTAssertFalse(viewModel.shouldShowMacAppSuggestion)
        XCTAssertTrue(viewModel.shouldShowAutoFillTip)
    }

    // MARK: - Declined provider-enable requests

    func testRequestEnableAutoFillReportsRejectionWhenProviderStaysOff() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.enableRequester = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()

        await viewModel.requestEnableAutoFill()

        XCTAssertTrue(
            viewModel.isAutoFillEnableRequestRejected,
            "a declined request must be reported, not left looking like a switch that reset itself"
        )
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, false)
        XCTAssertTrue(viewModel.shouldShowAutoFillTip)
    }

    func testRequestEnableAutoFillReportsNothingWhenProviderTurnsOn() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.enableRequester = { true }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()

        await viewModel.requestEnableAutoFill()

        XCTAssertFalse(viewModel.isAutoFillEnableRequestRejected)
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, true)
        XCTAssertFalse(viewModel.shouldShowAutoFillTip)
    }

    /// The declined result is a report about the sheet, not about the store: if
    /// the provider is on anyway, there is nothing to explain to the user.
    func testRequestEnableAutoFillPrefersRealStateOverDeclinedResult() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.enableRequester = { false }
        let viewModel = DatabaseListViewModel()

        await viewModel.requestEnableAutoFill()

        XCTAssertFalse(viewModel.isAutoFillEnableRequestRejected)
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, true)
    }

    /// The note is persistent, so it has to retire itself: once the provider is
    /// on — however it got there, including from iOS Settings — a stale "the
    /// last attempt did not work" line would be a lie.
    func testEnabledProviderRetiresTheRejectionNote() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.enableRequester = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.requestEnableAutoFill()
        XCTAssertTrue(viewModel.isAutoFillEnableRequestRejected)

        AutoFillStatusService.enabledProvider = { true }
        await viewModel.refreshAutoFillStatus()

        XCTAssertFalse(viewModel.isAutoFillEnableRequestRejected)
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, true)
    }

    func testSuccessfulEnableRetiresAnEarlierRejectionNote() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.enableRequester = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.requestEnableAutoFill()
        XCTAssertTrue(viewModel.isAutoFillEnableRequestRejected)

        AutoFillStatusService.enableRequester = { true }
        await viewModel.requestEnableAutoFill()

        XCTAssertFalse(viewModel.isAutoFillEnableRequestRejected)
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, true)
    }

    // MARK: - One-database AutoFill limit

    func testOneDatabaseLimitUnknownBeforeStatusCheck() throws {
        try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.incrementalUpdatesProvider = { false }
        let viewModel = DatabaseListViewModel()

        XCTAssertNil(viewModel.autoFillStoreSupportsIncrementalUpdates)
        XCTAssertFalse(viewModel.isAutoFillLimitedToOneDatabase)
    }

    func testOneDatabaseLimitShownWhenStoreHasNoIncrementalUpdates() async throws {
        try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.incrementalUpdatesProvider = { false }
        let viewModel = DatabaseListViewModel()

        await viewModel.refreshAutoFillStatus()

        XCTAssertEqual(viewModel.autoFillStoreSupportsIncrementalUpdates, false)
        XCTAssertTrue(viewModel.isAutoFillLimitedToOneDatabase)
    }

    func testOneDatabaseLimitHiddenWhenStoreSupportsIncrementalUpdates() async throws {
        try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.incrementalUpdatesProvider = { true }
        let viewModel = DatabaseListViewModel()

        await viewModel.refreshAutoFillStatus()

        XCTAssertEqual(viewModel.autoFillStoreSupportsIncrementalUpdates, true)
        XCTAssertFalse(viewModel.isAutoFillLimitedToOneDatabase)
    }

    func testOneDatabaseLimitFollowsTheNumberOfAutoFillDatabases() async throws {
        let (_, second) = try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.incrementalUpdatesProvider = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()

        viewModel.setAutoFillEnabled(false, for: second)
        XCTAssertFalse(viewModel.isAutoFillLimitedToOneDatabase)

        viewModel.setAutoFillEnabled(true, for: second)
        XCTAssertTrue(viewModel.isAutoFillLimitedToOneDatabase)
    }

    /// The flag is only recorded for an enabled provider, so a disabled
    /// store's answer must not be read as the limit.
    func testOneDatabaseLimitUnknownWhileProviderIsOff() async throws {
        try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { true }
        AutoFillStatusService.incrementalUpdatesProvider = { false }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()
        XCTAssertTrue(viewModel.isAutoFillLimitedToOneDatabase)

        AutoFillStatusService.enabledProvider = { false }
        await viewModel.refreshAutoFillStatus()

        XCTAssertNil(viewModel.autoFillStoreSupportsIncrementalUpdates)
        XCTAssertFalse(viewModel.isAutoFillLimitedToOneDatabase)
    }

    func testSuccessfulEnableReadsTheOneDatabaseLimit() async throws {
        try addTwoAutoFillDatabases()
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.incrementalUpdatesProvider = { false }
        AutoFillStatusService.enableRequester = { true }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()
        XCTAssertFalse(viewModel.isAutoFillLimitedToOneDatabase)

        await viewModel.requestEnableAutoFill()

        XCTAssertTrue(viewModel.isAutoFillLimitedToOneDatabase)
    }

    @discardableResult
    private func addTwoAutoFillDatabases() throws -> (DatabaseReference, DatabaseReference) {
        let first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "work.kdbx"))
        return (first, second)
    }

    // MARK: - Pending upload alerts

    func testPushPendingChangesSurfacesConflictAlertForPushedDatabase() async {
        let reference = makeCloudReference()
        let viewModel = DatabaseListViewModel(
            pendingUploadDrainer: makeDrainer(
                markers: [makeStoredMarker(databaseId: reference.id)],
                reference: reference,
                pushPendingUpload: { _, _, _ in .conflict(remoteRev: "rev-2") }
            )
        )

        await viewModel.pushPendingChanges(for: reference)

        XCTAssertEqual(viewModel.pendingUploadAlert?.kind, .conflict)
        XCTAssertEqual(viewModel.pendingUploadAlert?.databaseId, reference.id)
    }

    func testAppActiveDrainStaysSilentOnConflict() async {
        let reference = makeCloudReference()
        let viewModel = DatabaseListViewModel(
            pendingUploadDrainer: makeDrainer(
                markers: [makeStoredMarker(databaseId: reference.id)],
                reference: reference,
                pushPendingUpload: { _, _, _ in .conflict(remoteRev: "rev-2") }
            )
        )

        await viewModel.drainPendingUploadsOnAppActive()

        XCTAssertNil(viewModel.pendingUploadAlert)
    }

    func testPushPendingChangesPrefersUserIssueOverConflict() async {
        let reference = makeCloudReference()
        let conflictMarker = makeStoredMarker(databaseId: reference.id, expectedRev: "rev-1")
        let failingMarker = makeStoredMarker(databaseId: reference.id, expectedRev: "rev-0")
        let viewModel = DatabaseListViewModel(
            pendingUploadDrainer: makeDrainer(
                markers: [conflictMarker, failingMarker],
                reference: reference,
                pushPendingUpload: { _, _, expectedRev in
                    if expectedRev == conflictMarker.marker.expectedRev {
                        return .conflict(remoteRev: "rev-2")
                    }
                    throw CloudProviderError.notAuthenticated
                }
            )
        )

        await viewModel.pushPendingChanges(for: reference)

        XCTAssertEqual(viewModel.pendingUploadAlert?.kind, .notAuthenticated)
        XCTAssertEqual(viewModel.pendingUploadAlert?.databaseId, reference.id)
    }

    func testDismissPendingUploadAlertClearsConflictAlert() async {
        let reference = makeCloudReference()
        let viewModel = DatabaseListViewModel(
            pendingUploadDrainer: makeDrainer(
                markers: [makeStoredMarker(databaseId: reference.id)],
                reference: reference,
                pushPendingUpload: { _, _, _ in .conflict(remoteRev: "rev-2") }
            )
        )
        await viewModel.pushPendingChanges(for: reference)
        XCTAssertNotNil(viewModel.pendingUploadAlert)

        viewModel.dismissPendingUploadAlert()

        XCTAssertNil(viewModel.pendingUploadAlert)
    }

    func testPickerPresentationStateKeepsTargetUntilCompletion() {
        var state = PickerPresentationState<String>()

        state.present("database")
        state.updatePresentation(false)

        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.activeTarget, "database")
        XCTAssertEqual(state.consumeActiveTarget(), "database")
        XCTAssertNil(state.activeTarget)
        XCTAssertFalse(state.isPresented)
    }

    private func makeCloudReference() -> DatabaseReference {
        var reference = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: CloudFile(
                id: "/Vaults/cloud.kdbx",
                name: "cloud.kdbx",
                path: "/Vaults/cloud.kdbx",
                isFolder: false,
                modifiedDate: nil,
                size: nil
            )
        )
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-1"
        }
        DatabaseListStore.update(reference)
        return reference
    }

    private func makeStoredMarker(databaseId: UUID, expectedRev: String? = "rev-1") -> PendingUploadQueue.StoredMarker {
        PendingUploadQueue.StoredMarker(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).json"),
            marker: PendingUploadQueue.Marker(
                databaseId: databaseId,
                encryptedBytesCacheURL: "cloud-cache/\(databaseId.uuidString).kdbx",
                openTimeSHA512: Data("open-sha".utf8),
                expectedRev: expectedRev,
                createdAt: Date(timeIntervalSince1970: 1_000),
                baseRev: expectedRev
            )
        )
    }

    private func makeDrainer(
        markers: [PendingUploadQueue.StoredMarker],
        reference: DatabaseReference,
        pushPendingUpload: @escaping @Sendable (DatabaseReference, Data, String?) async throws -> CloudDatabaseSaver.PendingUploadPushResult
    ) -> PendingUploadDrainer {
        PendingUploadDrainer(
            environment: PendingUploadDrainer.Environment(
                beginBackgroundTask: { _ in .invalid },
                endBackgroundTask: { _ in },
                listMarkers: { _ in markers },
                dropMarker: { _ in },
                updateMarker: { $0 },
                resolveReference: { $0 == reference.id ? reference : nil },
                readBytes: { _ in Data("encrypted-bytes".utf8) },
                sha512: { _ in Data("open-sha".utf8) },
                pushPendingUpload: pushPendingUpload,
            )
        )
    }

    private func makeTemporaryFileURL(name: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url)
        return url
    }
}
