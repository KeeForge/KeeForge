import AuthenticationServices
import CryptoKit
import LocalAuthentication
import SwiftUI
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseViewModelTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        await resetCredentialIdentityStoreState()
    }

    override func tearDown() async throws {
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    func testInitialStateIsLockedWithSavedDatabaseReference() throws {
        let vm = try makeViewModel()

        XCTAssertState(vm.state, is: .locked)
        XCTAssertTrue(vm.hasSavedFile)
        XCTAssertFalse(vm.canUseBiometrics)
        XCTAssertEqual(vm.lockCycleID, 0)
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testBiometricAutoUnlockPolicyDisablesLifecyclePromptsOnCompatibilityPlatforms() {
        XCTAssertFalse(BiometricAutoUnlockPolicy.allowsAutomaticUnlock(
            isiOSAppOnMac: true, isiOSAppOnVision: false
        ))
        XCTAssertFalse(BiometricAutoUnlockPolicy.allowsAutomaticUnlock(
            isiOSAppOnMac: false, isiOSAppOnVision: true
        ))
        XCTAssertTrue(BiometricAutoUnlockPolicy.allowsAutomaticUnlock(
            isiOSAppOnMac: false, isiOSAppOnVision: false
        ))
    }

    // The simulator and the native macOS test host both run outside
    // compatibility mode, so the shipped accessor must allow auto-unlock here;
    // this catches an inverted platform branch that the pure helper cannot.
    func testBiometricAutoUnlockPolicyAllowsAutomaticUnlockInTestEnvironment() {
        XCTAssertTrue(BiometricAutoUnlockPolicy.allowsAutomaticUnlock)
    }

    func testUnlockWithCorrectPasswordTransitionsToUnlocked() async throws {
        let vm = try makeViewModel()

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.rootGroup)
        XCTAssertFalse(vm.rootGroup?.allEntries.isEmpty ?? true)
    }

    func testBiometricUnlockOpensDatabaseWithTheStoredCompositeKey() async throws {
        let vm = try makeViewModel(
            biometricCompositeKeyOperation: { [fixturePassword] _, _ in
                try KDBXCrypto.compositeKey(password: fixturePassword, keyFileData: nil)
            }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .unlocked)
        XCTAssertState(vm.state, is: .unlocked)
    }

    /// LocalAuthentication answers `notInteractive` when it cannot present its
    /// prompt because the app is not foreground-active — what lock-on-background
    /// and Quick Launch used to trigger (#60). Nothing was shown, so this is not
    /// an unlock failure: the database stays locked and re-armable rather than
    /// stranding the session on a "biometric.unexpected" error screen.
    func testBiometricUnlockStaysLockedWhenThePromptCannotBePresented() async throws {
        let vm = try makeViewModel(
            biometricCompositeKeyOperation: { _, _ in throw LAError(.notInteractive) }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .promptUnavailable)
        XCTAssertState(vm.state, is: .locked)
        XCTAssertNil(vm.openFailure)
    }

    /// The prompt offers a "Use Password" fallback; taking it is a choice, not
    /// a failure.
    func testBiometricUnlockStaysLockedWhenTheUserChoosesThePasswordFallback() async throws {
        let vm = try makeViewModel(
            biometricCompositeKeyOperation: { _, _ in throw LAError(.userFallback) }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .passwordFallback)
        XCTAssertState(vm.state, is: .locked)
        XCTAssertNil(vm.openFailure)
    }

    func testBiometricUnlockStillSurfacesRealBiometricFailures() async throws {
        let vm = try makeViewModel(
            biometricCompositeKeyOperation: { _, _ in throw LAError(.biometryLockout) }
        )

        let outcome = await vm.unlockWithBiometrics()

        XCTAssertEqual(outcome, .failed)
        let failure = try XCTUnwrap(vm.openFailure)
        XCTAssertEqual(failure.errorCode, "biometric.unavailable")
        XCTAssertEqual(failure.category, DatabaseOpenFailure.Category.biometric)
    }

    func testUnlockCloudDatabaseDoesNotRewriteSharedCache() async throws {
        // A cloud unlock reads its bytes FROM the shared cache, so rewriting
        // them used to silently revert an AutoFill save that landed in the
        // meantime. The cache here holds fresher bytes and must survive the
        // unlock untouched.
        let reference = makeCloudReference(remoteRev: "rev-1")
        let pendingAutoFillBytes = Data("pending-autofill-save-bytes".utf8)
        try DatabaseListStore.cacheDatabaseCopy(pendingAutoFillBytes, for: reference)

        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: Data("stale-open-snapshot".utf8),
                    status: .current
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        let cacheBytes = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        XCTAssertEqual(cacheBytes, pendingAutoFillBytes)
    }

    func testCreatedDatabaseInitializerStartsUnlocked() async throws {
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Created",
                destination: .appOnlyAcknowledged,
                password: "created password"
            )
        )

        let vm = DatabaseViewModel(createdDatabase: created)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.databaseReference.id, created.reference.id)
        XCTAssertEqual(vm.openTimeSHA512, created.openTimeSHA512)
        XCTAssertEqual(vm.visibleRootGroup?.name, "Created")
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, created.reference.id)
    }

    func testCreatedDatabaseCanSaveFirstEntry() async throws {
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "First Entry",
                destination: .appOnlyAcknowledged,
                password: "created save password"
            )
        )
        let vm = DatabaseViewModel(createdDatabase: created)
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        let initialContentRevision = vm.contentRevision

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: "First Saved Entry",
                    username: "alice",
                    password: "saved-secret",
                    url: "https://example.com"
                )
            )
        )
        XCTAssertGreaterThan(vm.contentRevision, initialContentRevision)
        XCTAssertEqual(vm.group(withID: parentGroupID)?.entries.map(\.title), ["First Saved Entry"])

        try await vm.save()

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: created.reference))
        let parsed = try KDBXParser.parse(
            data: Data(contentsOf: cachedURL),
            password: "created save password",
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertTrue(parsed.allEntries.contains(where: { $0.title == "First Saved Entry" }))
        XCTAssertNil(vm.draft)
        XCTAssertFalse(vm.isDirty)
    }

    /// End-to-end proof for #14: hide a group, save through the real save path,
    /// then read the encrypted file back from disk and check that AutoFill's
    /// actual entry source no longer offers the entry.
    func testHiddenGroupSurvivesSaveAndStaysOutOfCredentialStore() async throws {
        let password = "hidden group save password"
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Hidden Group Persistence",
                destination: .appOnlyAcknowledged,
                password: password
            )
        )
        let vm = DatabaseViewModel(createdDatabase: created)
        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.createGroup(named: "Banking", in: rootGroupID)
        let hiddenGroupID = try XCTUnwrap(
            vm.group(withID: rootGroupID)?.groups.first(where: { $0.name == "Banking" })?.id
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: hiddenGroupID,
                draft: EntryDraftPayload(
                    title: "Bank Login",
                    username: "alice",
                    password: "bank-secret",
                    url: "https://bank.example.com"
                )
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: rootGroupID,
                draft: EntryDraftPayload(
                    title: "Mail Login",
                    username: "alice",
                    password: "mail-secret",
                    url: "https://mail.example.com"
                )
            )
        )

        try vm.setGroupExcludedFromAutoFill(true, groupID: hiddenGroupID)
        try await vm.save()

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: created.reference))
        let reparsedRoot = try KDBXParser.parse(
            data: Data(contentsOf: cachedURL),
            password: password,
            sessionKey: SymmetricKey(size: .bits256)
        )

        let reparsedHiddenGroup = try XCTUnwrap(
            Self.findGroup(withID: hiddenGroupID, in: reparsedRoot)
        )
        XCTAssertEqual(
            reparsedHiddenGroup.searchingEnabled,
            .disabled,
            "The flag must survive a real encrypted save and reload"
        )

        let offeredTitles = Set(
            DatabaseViewModel.credentialStoreEntries(from: reparsedRoot).map(\.title)
        )
        XCTAssertTrue(
            offeredTitles.contains("Mail Login"),
            "Entries outside the hidden group must still be offered"
        )
        XCTAssertFalse(
            offeredTitles.contains("Bank Login"),
            "The hidden group's entry must not reach AutoFill after a save and reload"
        )
    }

    private static func findGroup(withID groupID: UUID, in group: KPGroup) -> KPGroup? {
        if group.id == groupID { return group }
        for childGroup in group.groups {
            if let match = findGroup(withID: groupID, in: childGroup) { return match }
        }
        return nil
    }

    func testSetNicknamePersistsAndRefreshesCurrentReference() throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)

        vm.setNickname("Travel Vault")

        let storedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertEqual(storedReference.nickname, "Travel Vault")
        XCTAssertEqual(vm.databaseReference.nickname, "Travel Vault")
        XCTAssertEqual(vm.databaseDisplayName, "Travel Vault")
    }

    func testUnlockLegacyKDBX31ForcesReadOnlyMode() async throws {
        let reference = try TestDatabaseSupport.makeReference(for: legacyFixtureURL())
        let vm = try makeViewModel(reference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.openedFormatVersion, .kdbx3_1)
        XCTAssertTrue(vm.isFormatReadOnly)
        XCTAssertTrue(vm.isReadOnly)
    }

    func testUnlockCachesPerDatabaseCopy() async throws {
        let reference = try makeReference()
        let vm = DatabaseViewModel(databaseReference: reference)
        let sourceURL = try fixtureURL()

        await vm.unlock(password: fixturePassword)

        let cachedURL = try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))
        XCTAssertEqual(cachedURL.lastPathComponent, "\(reference.id.uuidString).kdbx")
        XCTAssertEqual(try Data(contentsOf: cachedURL), try Data(contentsOf: sourceURL))
    }

    func testUnlockCapturesOpenTimeSHA512() async throws {
        let vm = try makeViewModel()
        let expectedHash = KDBXCrypto.sha512(try Data(contentsOf: fixtureURL()))

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.openTimeSHA512, expectedHash)
    }

    func testAttachmentDataReturnsNilBeforeUnlockAndForDanglingRefAfterUnlock() async throws {
        let vm = try makeViewModel()

        let beforeUnlock = await vm.attachmentData(for: KPAttachment(name: "missing.txt", ref: 0))
        XCTAssertNil(beforeUnlock)

        await vm.unlock(password: fixturePassword)

        let danglingRef = await vm.attachmentData(for: KPAttachment(name: "missing.txt", ref: 0))
        XCTAssertNil(danglingRef)

        vm.lock()
        let afterLock = await vm.attachmentData(for: KPAttachment(name: "missing.txt", ref: 0))
        XCTAssertNil(afterLock)
    }

    func testUnlockFailsWhenLocalBookmarkCannotBeResolved() async throws {
        var reference = try makeReference()
        reference.bookmarkData = Data("invalid-bookmark".utf8)

        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL()), for: reference.id)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .error)
        XCTAssertNil(vm.rootGroup)
        // The removal affordance is scoped to Documents-resident references.
        XCTAssertFalse(vm.canRemoveMissingDocumentsFile)
    }

    func testMissingDocumentsFileUnlockOffersRemoveFromList() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        try Data(contentsOf: fixtureURL()).write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.openFailure?.errorCode, "file.not_found")
        XCTAssertTrue(vm.canRemoveMissingDocumentsFile)

        // Same consequences as a manual list removal.
        vm.removeMissingDocumentsDatabase()
        XCTAssertTrue(DatabaseListStore.databases.isEmpty)
        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: reference.id))
    }

    func testRemoveMissingDocumentsFileIsNoOpOnceFileIsRestored() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        let fixtureData = try Data(contentsOf: fixtureURL())
        try fixtureData.write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        XCTAssertTrue(vm.canRemoveMissingDocumentsFile)

        // The affordance is evaluated once when the failure is recorded, so
        // it stays visible — but a remove after the file came back must be a
        // no-op (re-verified at action time) and clear the stale flag.
        try fixtureData.write(to: fileURL)
        vm.removeMissingDocumentsDatabase()
        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [reference.id])
        XCTAssertFalse(vm.canRemoveMissingDocumentsFile)
    }

    func testRetryUnlockSucceedsAfterScannerHealsStoredReference() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        let fixtureData = try Data(contentsOf: fixtureURL())
        try fixtureData.write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)
        try FileManager.default.removeItem(at: fileURL)

        let vm = DatabaseViewModel(databaseReference: reference)
        await vm.unlock(password: fixturePassword)
        XCTAssertEqual(vm.openFailure?.errorCode, "file.not_found")

        // Restore the file (delete+recopy, so the original bookmark is dead)
        // and let the foreground scan heal the stored reference. The unlock
        // sheet is still open on its pre-heal reference snapshot; Try Again
        // must pick up the healed bookmark instead of failing again.
        try fixtureData.write(to: fileURL)
        DocumentsVaultScanner.scan(directory: documentsDirectory)

        await vm.unlock(password: fixturePassword)
        XCTAssertState(vm.state, is: .unlocked)
    }

    func testRetryUnlockAdoptsRederivedIdentityFromStoredReference() async throws {
        let documentsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        DatabaseListStore.documentsDirectoryOverride = documentsDirectory
        defer {
            DatabaseListStore.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: documentsDirectory)
        }

        let fileURL = documentsDirectory.appendingPathComponent("resident.kdbx")
        let fixtureData = try Data(contentsOf: fixtureURL())
        try fixtureData.write(to: fileURL)
        let reference = try DatabaseListStore.add(url: fileURL)
        let vm = DatabaseViewModel(databaseReference: reference)

        // Files-app rename, noticed by a foreground scan: the stored
        // reference's filename follows the file, the sheet's snapshot keeps
        // the old one.
        let renamedURL = documentsDirectory.appendingPathComponent("renamed.kdbx")
        try FileManager.default.moveItem(at: fileURL, to: renamedURL)
        DocumentsVaultScanner.scan(directory: documentsDirectory)

        // Finder replace over USB (delete+recopy) kills the snapshot's
        // bookmark; the next scan heals the stored reference at its rederived
        // path. The snapshot can no longer self-heal — its path-keyed rebind
        // looks at the old filename.
        try FileManager.default.removeItem(at: renamedURL)
        try fixtureData.write(to: renamedURL)
        DocumentsVaultScanner.scan(directory: documentsDirectory)

        XCTAssertEqual(DatabaseListStore.databases.map(\.id), [reference.id])

        await vm.unlock(password: fixturePassword)
        XCTAssertState(vm.state, is: .unlocked)
    }

    func testUnlockShowsServerUnavailableWhenLocalReadTimesOut() async throws {
        let reference = try makeReference()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localDatabaseReadOperation: { _ in
                throw CoordinatedFileReader.TimeoutError.timedOut
            }
        )

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.openFailure?.errorCode, "file.read_timeout")
        XCTAssertEqual(vm.openFailure?.category, .fileAccess)
        XCTAssertFalse(vm.openFailure?.countsTowardFailedAttempts ?? true)
    }

    func testUnlockFailsWhenDatabaseFileIsInRecentlyDeleted() async throws {
        // A bookmark follows its file into the Files app's Recently Deleted
        // (".Trash"), so unlock must refuse the stale copy with a dedicated
        // failure instead of silently opening it.
        let fileManager = FileManager.default
        let trashDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
        try fileManager.createDirectory(at: trashDirectoryURL, withIntermediateDirectories: true)
        let trashedURL = trashDirectoryURL.appendingPathComponent("test.kdbx")
        try fileManager.copyItem(at: fixtureURL(), to: trashedURL)
        let reference = try TestDatabaseSupport.makeReference(for: trashedURL)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .error)
        XCTAssertEqual(vm.openFailure?.errorCode, "file.in_recently_deleted")
        XCTAssertEqual(vm.openFailure?.category, .fileAccess)
        XCTAssertFalse(vm.openFailure?.countsTowardFailedAttempts ?? true)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(DatabaseListStore.cachedDatabaseURL(for: reference.id))
    }

    func testBlockingFileAccessTimesOutWithoutBlockingCallerActor() async {
        do {
            let _: Data = try await CoordinatedFileReader.performBlocking(timeout: .milliseconds(20)) {
                Thread.sleep(forTimeInterval: 0.25)
                return Data("eventual result".utf8)
            }
            XCTFail("Expected the blocking file access to time out")
        } catch {
            XCTAssertEqual(error as? CoordinatedFileReader.TimeoutError, .timedOut)
        }
    }

    func testForegroundRefreshRepopulatesCredentialStoreWhenUnlocked() async throws {
        let vm = try makeViewModel()
        let expectedDatabaseID = vm.databaseReference.id

        let refreshExpectation = expectation(description: "Credential store repopulated after refresh")
        var populateCallCount = 0
        var observedDatabaseIDs: [UUID] = []
        CredentialIdentityStoreManager.populateObserver = { databaseID, _ in
            observedDatabaseIDs.append(databaseID)
            populateCallCount += 1
            if populateCallCount == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)
        vm.refreshSharedDatabaseCacheIfPossible()

        await fulfillment(of: [refreshExpectation], timeout: 30)
        XCTAssertEqual(populateCallCount, 2)
        XCTAssertEqual(
            observedDatabaseIDs,
            [expectedDatabaseID, expectedDatabaseID],
            "Every populate must be tagged with the unlocked database's id"
        )
    }

    func testApplyEntryEditRefreshesCredentialStoreFromDraft() async throws {
        let vm = try makeViewModel()
        let refreshExpectation = expectation(description: "Credential store refreshed after edit")
        var observedEntries: [[KPEntry]] = []

        CredentialIdentityStoreManager.populateObserver = { _, entries in
            observedEntries.append(entries)
            if observedEntries.count == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)

        let originalEntry = try XCTUnwrap(
            vm.rootGroup?.allEntries.first(where: {
                $0.hasPassword &&
                !$0.url.isEmpty &&
                !$0.username.isEmpty &&
                $0.totpConfig == nil &&
                $0.passkeyCredential == nil
            })
        )

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: originalEntry.id,
                draft: EntryDraftPayload(
                    title: originalEntry.title,
                    username: "cache-updated-user",
                    password: "cache-updated-password",
                    url: "https://cache-update.example.com/login",
                    notes: originalEntry.notes,
                    customFields: originalEntry.customFields,
                    tags: originalEntry.tags
                )
            )
        )

        await fulfillment(of: [refreshExpectation], timeout: 30)

        let refreshedEntry = try XCTUnwrap(observedEntries.last?.first(where: { $0.id == originalEntry.id }))
        XCTAssertEqual(refreshedEntry.username, "cache-updated-user")
        XCTAssertEqual(refreshedEntry.url, "https://cache-update.example.com/login")
    }

    func testCreateGroupAddsSubgroupToParent() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let parentGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Work" }))

        try vm.createGroup(named: "Projects", in: parentGroup.id)

        let updatedParentGroup = try XCTUnwrap(vm.group(withID: parentGroup.id))
        XCTAssertTrue(updatedParentGroup.groups.contains(where: { $0.name == "Projects" }))
        XCTAssertTrue(vm.isDirty)
    }

    func testCreateGroupDuplicateNameThrowsTypedError() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let parentGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Work" }))
        try vm.createGroup(named: "Projects", in: parentGroup.id)

        XCTAssertThrowsError(
            try vm.createGroup(named: "projects", in: parentGroup.id)
        ) { error in
            XCTAssertEqual(
                error as? DatabaseDraft.DraftError,
                .duplicateGroupName(parentGroupID: parentGroup.id, name: "projects")
            )
        }
    }

    func testDeleteGroupRefreshesCredentialStoreAndMovesGroupToRecycleBin() async throws {
        let vm = try makeViewModel()
        let refreshExpectation = expectation(description: "Credential store refreshed after group recycle")
        var observedEntries: [[KPEntry]] = []

        CredentialIdentityStoreManager.populateObserver = { _, entries in
            observedEntries.append(entries)
            if observedEntries.count == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)

        let workGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Work" }))
        let deletedEntryIDs = Set(workGroup.allEntries.map(\.id))

        try vm.deleteGroup(workGroup.id, sendToRecycleBin: true)

        await fulfillment(of: [refreshExpectation], timeout: 30)

        XCTAssertTrue(vm.isGroupInRecycleBin(groupID: workGroup.id))
        XCTAssertTrue(deletedEntryIDs.isDisjoint(with: Set(observedEntries.last?.map(\.id) ?? [])))
    }

    func testDeleteGroupSelectionFallsBackToVisibleRoot() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let socialGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Social" }))
        let entry = try XCTUnwrap(socialGroup.entries.first)

        vm.selectGroup(socialGroup.id)
        vm.selectEntry(entry.id)

        try vm.deleteGroup(socialGroup.id, sendToRecycleBin: true)

        XCTAssertEqual(vm.selectedGroupID, vm.visibleRootGroupID)
        XCTAssertNil(vm.selectedEntryID)
        XCTAssertTrue(vm.isGroupInRecycleBin(groupID: socialGroup.id))
    }

    func testPermanentEntryDeleteKeepsSelectionForDetailViewToClear() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let socialGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Social" }))
        let entry = try XCTUnwrap(socialGroup.entries.first)
        vm.selectGroup(socialGroup.id)
        vm.selectEntry(entry.id)

        try vm.deleteEntry(entry.id, sendToRecycleBin: false)

        XCTAssertNil(vm.entry(withID: entry.id))
        // The stale selection is kept for the mounted EntryDetailView to clear;
        // clearing it in the delete update would wedge a pushed entry editor.
        XCTAssertEqual(vm.selectedEntryID, entry.id)
    }

    func testHidingGroupFromAutoFillMarksItAndItsSubgroupsExcluded() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Hidden Parent", in: rootGroupID)
        let parent = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Hidden Parent" }))
        try vm.createGroup(named: "Hidden Child", in: parent.id)
        let child = try XCTUnwrap(vm.group(withID: parent.id)?.groups.first)

        XCTAssertFalse(vm.isGroupExcludedFromAutoFill(groupID: parent.id))
        XCTAssertFalse(vm.isGroupExcludedFromAutoFill(groupID: child.id))

        try vm.setGroupExcludedFromAutoFill(true, groupID: parent.id)

        XCTAssertTrue(vm.isGroupExcludedFromAutoFill(groupID: parent.id))
        XCTAssertTrue(vm.isGroupExcludedFromAutoFill(groupID: child.id))
        XCTAssertFalse(
            vm.isGroupExclusionInherited(groupID: parent.id),
            "The parent carries the flag itself"
        )
        XCTAssertTrue(
            vm.isGroupExclusionInherited(groupID: child.id),
            "The child is only excluded through its parent"
        )
        XCTAssertFalse(vm.isGroupExcludedFromAutoFill(groupID: rootGroupID))
    }

    func testSettingGroupIconAppliesToTheGroup() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Banking", in: rootGroupID)
        let group = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Banking" }))
        XCTAssertNotEqual(group.iconID, 37)

        try vm.setGroupIcon(37, groupID: group.id)

        XCTAssertEqual(vm.group(withID: group.id)?.iconID, 37)
        XCTAssertTrue(vm.isDirty)
    }

    /// KDBX writes `<IconID>` as a bare integer, so an index with no glyph would be
    /// persisted and then render as whatever fallback each client happens to pick.
    func testSettingGroupIconIgnoresIndexesOutsideTheStandardSet() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Unchanged", in: rootGroupID)
        let group = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Unchanged" }))
        let originalIconID = group.iconID

        try vm.setGroupIcon(69, groupID: group.id)
        try vm.setGroupIcon(-1, groupID: group.id)
        try vm.setGroupIcon(Int.max, groupID: group.id)

        XCTAssertEqual(vm.group(withID: group.id)?.iconID, originalIconID)
    }

    /// Re-picking the icon a group already has would otherwise cost a full re-encrypt
    /// and save for no visible change.
    func testSettingGroupIconToTheCurrentIconIsANoOp() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Same Icon", in: rootGroupID)
        let group = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Same Icon" }))
        let modificationTimeBefore = group.lastModificationTime

        try vm.setGroupIcon(group.iconID, groupID: group.id)

        XCTAssertEqual(vm.group(withID: group.id)?.lastModificationTime, modificationTimeBefore)
    }

    func testSettingEntryIconAppliesToTheEntry() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first)
        XCTAssertNotEqual(entry.iconID, 37)

        try vm.setEntryIcon(.standard(iconID: 37), entryID: entry.id)

        XCTAssertEqual(vm.entry(withID: entry.id)?.iconID, 37)
        XCTAssertTrue(vm.isDirty)
    }

    /// Same reason `setGroupIcon` screens the index: KDBX writes `<IconID>` as a
    /// bare integer, so an index with no glyph is persisted happily and then
    /// rendered as whatever fallback each client picks.
    func testSettingEntryIconIgnoresIndexesOutsideTheStandardSet() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first)
        let originalIconID = entry.iconID

        try vm.setEntryIcon(.standard(iconID: 69), entryID: entry.id)
        try vm.setEntryIcon(.standard(iconID: -1), entryID: entry.id)
        try vm.setEntryIcon(.standard(iconID: Int.max), entryID: entry.id)

        XCTAssertEqual(vm.entry(withID: entry.id)?.iconID, originalIconID)
        XCTAssertFalse(vm.isDirty)
    }

    /// A `<CustomIconUUID>` that resolves to nothing renders as each client's own
    /// fallback, which is a worse outcome than leaving the icon the entry has.
    func testSettingEntryIconIgnoresACustomIconTheDatabaseDoesNotDefine() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first)

        try vm.setEntryIcon(.custom(uuid: UUID()), entryID: entry.id)

        XCTAssertNil(vm.entry(withID: entry.id)?.customIconUUID)
        XCTAssertFalse(vm.isDirty)
    }

    /// Re-picking the icon an entry already shows would otherwise cost a full
    /// re-encrypt, a save, and a history version for no visible change.
    func testSettingEntryIconToTheCurrentIconIsANoOp() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first)
        let historyCountBefore = entry.history.count

        try vm.setEntryIcon(.standard(iconID: entry.iconID), entryID: entry.id)

        XCTAssertEqual(vm.entry(withID: entry.id)?.history.count, historyCountBefore)
        XCTAssertFalse(vm.isDirty)
    }

    /// The picker asks before it offers the action, so the answer has to match
    /// what `downloadFavicon` would actually do — a button that is enabled and
    /// then refuses is worse than one that was never offered.
    func testFaviconDownloadIsOfferedOnlyForAPublicWebsiteAddress() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)
        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        func entryID(url: String, title: String) throws -> UUID {
            try vm.applyEntryEdit(
                .createEntry(parentGroupID: rootGroupID, draft: EntryDraftPayload(title: title, url: url))
            )
            return try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { $0.title == title }?.id)
        }

        let publicSite = try entryID(url: "https://example.com/login", title: "Public")
        XCTAssertTrue(vm.canDownloadFavicon(forEntryID: publicSite))

        for (url, title) in [
            ("", "No URL"),
            ("http://localhost:8080", "Localhost"),
            ("https://192.168.1.10", "Private IP"),
            ("https://nas.local", "Private TLD"),
        ] {
            let id = try entryID(url: url, title: title)
            XCTAssertFalse(
                vm.canDownloadFavicon(forEntryID: id),
                "\(title) names no host a favicon service could be asked about"
            )
            do {
                try await vm.downloadFavicon(forEntryID: id)
                XCTFail("\(title) must fail before any network call")
            } catch {
                XCTAssertEqual(error as? DatabaseViewModel.FaviconDownloadFailure, .noPublicDomain)
            }
        }
    }

    /// `unlockedMeta` is only refreshed by a successful save, so every
    /// custom-icon read has to go through the draft as well. Otherwise a save
    /// that fails — offline, conflicted — leaves the entry pointing at a UUID
    /// nothing can resolve: it renders its fallback icon and the picker omits
    /// the image, so a download that worked looks like one that did nothing.
    /// A retry then misses the no-op guard and writes another history version.
    func testACustomIconIsVisibleBeforeTheSaveThatWouldPersistIt() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first)
        let iconUUID = UUID()
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x11, 0x22])

        try vm.applyEntryEdit(
            .addEntryCustomIcon(entryID: entry.id, iconUUID: iconUUID, imageData: imageData)
        )

        let updated = try XCTUnwrap(vm.entry(withID: entry.id))
        XCTAssertEqual(updated.customIconUUID, iconUUID)
        XCTAssertEqual(
            vm.customIconData(for: updated), imageData,
            "the entry must render the icon it was just given, saved or not"
        )
        XCTAssertTrue(
            vm.customIcons.contains { $0.id == iconUUID && $0.data == imageData },
            "and the picker must offer it"
        )
    }

    /// Nothing was saved, so the icon is still only in the draft — and the
    /// picker offering it has to mean picking it works.
    func testAnUnsavedCustomIconCanBeSelectedForAnotherEntry() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entries = try XCTUnwrap(vm.visibleRootGroup?.allEntries)
        let first = try XCTUnwrap(entries.first)
        let second = try XCTUnwrap(entries.dropFirst().first)
        let iconUUID = UUID()

        try vm.applyEntryEdit(
            .addEntryCustomIcon(entryID: first.id, iconUUID: iconUUID, imageData: Data([0x01, 0x02]))
        )
        try vm.setEntryIcon(.custom(uuid: iconUUID), entryID: second.id)

        XCTAssertEqual(vm.entry(withID: second.id)?.customIconUUID, iconUUID)
    }

    /// The picker reads a clean return as success: it dismisses and runs the
    /// follow-up save with nothing staged, which is indistinguishable from a
    /// stored icon. The window is narrow — a tap racing a read-only flip from
    /// another scene — but a distinct error costs nothing.
    func testDownloadingAFaviconIntoAReadOnlyDatabaseFails() async throws {
        var reference = try makeReference()
        reference.isReadOnly = true
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)
        XCTAssertTrue(vm.isReadOnly)

        let entryID = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { $0.url.isEmpty == false }?.id)
        XCTAssertFalse(vm.canDownloadFavicon(forEntryID: entryID))

        do {
            try await vm.downloadFavicon(forEntryID: entryID)
            XCTFail("a read-only database must refuse the edit rather than return cleanly")
        } catch {
            XCTAssertEqual(error as? DatabaseViewModel.FaviconDownloadFailure, .entryNotEditable)
        }
    }

    func testDownloadingAFaviconForAnEntryThatIsGoneFails() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        do {
            try await vm.downloadFavicon(forEntryID: UUID())
            XCTFail("an entry that no longer exists must not read as a stored icon")
        } catch {
            XCTAssertEqual(error as? DatabaseViewModel.FaviconDownloadFailure, .entryNotEditable)
        }
    }

    /// `applyEntryEdit` has no reentry guard, so an edit can land while a save's
    /// upload is in flight — and that edit's own follow-up save no-ops on
    /// `isSaving`. The in-flight save must go around again for it: clearing the
    /// draft unconditionally on completion silently threw the edit away, with
    /// nothing left dirty to ever save it.
    func testAnEditAppliedWhileASaveIsInFlightIsSavedNotDiscarded() async throws {
        let gate = InFlightSaveGate()
        let recorder = SavedDraftRecorder()

        let vm = DatabaseViewModel(
            databaseReference: try makeReference(),
            localSaveOperation: { draft, _, _, _, _ in
                await recorder.record(editCount: draft.pendingEdits.count)
                await gate.parkFirstCall()
                return .saved(newSHA512: Data("saved-\(draft.pendingEdits.count)".utf8))
            }
        )
        await vm.unlock(password: fixturePassword)

        let entries = try XCTUnwrap(vm.visibleRootGroup?.allEntries)
        let first = try XCTUnwrap(entries.first)
        let second = try XCTUnwrap(entries.dropFirst().first)

        try vm.applyEntryEdit(.setEntryIcon(entryID: first.id, icon: .standard(iconID: 5)))
        let saveTask = Task { try await vm.save() }
        await gate.firstCallStarted()

        // The mid-save edit, exactly as a view would produce it: apply, then a
        // follow-up save that no-ops against the in-flight one.
        try vm.applyEntryEdit(.setEntryIcon(entryID: second.id, icon: .standard(iconID: 7)))
        await vm.saveHandlingError()
        XCTAssertTrue(vm.isDirty, "the mid-save edit must still be pending while the first upload runs")

        await gate.releaseFirstCall()
        try await saveTask.value

        let editCounts = await recorder.editCounts
        XCTAssertEqual(editCounts, [1, 2], "the save must go around again, writing the grown draft whole")
        XCTAssertFalse(vm.isDirty, "nothing may be left behind once both uploads landed")
        XCTAssertNil(vm.saveError)
        XCTAssertEqual(vm.entry(withID: first.id)?.iconID, 5)
        XCTAssertEqual(vm.entry(withID: second.id)?.iconID, 7)
    }

    private func makeViewModelWithEditedEntry() async throws -> (
        vm: DatabaseViewModel, entryID: UUID, originalUsername: String, historyCountBefore: Int
    ) {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let original = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { !$0.username.isEmpty })
        let historyCountBefore = original.history.count
        try vm.applyEntryEdit(
            .updateEntry(
                entryID: original.id,
                draft: EntryDraftPayload(
                    title: original.title,
                    username: "history-updated-user",
                    password: "history-updated-password",
                    url: original.url,
                    notes: original.notes,
                    customFields: original.customFields,
                    tags: original.tags
                )
            )
        )

        return (vm, original.id, original.username, historyCountBefore)
    }

    /// Locking must take the history with it. The viewer can still be on screen when
    /// the app locks, and stored versions are database contents like any other — an
    /// entry's old passwords must not survive the session key being discarded.
    func testHistoryIsUnreachableAfterLocking() async throws {
        let (vm, entryID, _, _) = try await makeViewModelWithEditedEntry()
        XCTAssertFalse(vm.history(forEntryID: entryID).isEmpty, "precondition: versions exist while unlocked")

        vm.lock(manuallyTriggered: true)

        XCTAssertTrue(vm.history(forEntryID: entryID).isEmpty)
        XCTAssertNil(vm.entry(withID: entryID))
        XCTAssertNil(vm.sessionKey)
    }

    func testHistoryExposesTheEntrysEarlierVersions() async throws {
        let (vm, entryID, originalUsername, countBefore) = try await makeViewModelWithEditedEntry()

        let versions = vm.history(forEntryID: entryID)

        XCTAssertEqual(versions.count, countBefore + 1, "the edit adds exactly one version")
        XCTAssertEqual(versions[0].entry.username, originalUsername, "the newest version holds the replaced contents")
        XCTAssertEqual(vm.entry(withID: entryID)?.username, "history-updated-user")
    }

    /// KeePass and KeePassXC store history oldest-first, so trusting storage order would put
    /// the oldest version at the top for every database this app did not write. The storage
    /// index must survive the sort, since restoring addresses the raw array.
    func testHistoryIsSortedNewestFirstAndKeepsStorageIndices() async throws {
        let (vm, entryID, _, _) = try await makeViewModelWithEditedEntry()

        let versions = vm.history(forEntryID: entryID)
        let times = versions.compactMap(\.entry.lastModificationTime)

        XCTAssertEqual(times, times.sorted(by: >))
        XCTAssertEqual(Set(versions.map(\.index)), Set(0..<versions.count))
    }

    func testHistoryIsEmptyForAnUnknownEntry() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        XCTAssertTrue(vm.history(forEntryID: UUID()).isEmpty)
    }

    /// A restored password must reach AutoFill. Otherwise someone deliberately rolls back a
    /// password and AutoFill keeps filling the newer one they just discarded — the failure
    /// would be invisible in the app and only show up on a website.
    func testRestoringAnEarlierVersionRepublishesItToTheCredentialStore() async throws {
        let vm = try makeViewModel()
        var observedEntries: [[KPEntry]] = []
        let refreshExpectation = expectation(description: "Credential store refreshed after a restore")

        CredentialIdentityStoreManager.populateObserver = { _, entries in
            observedEntries.append(entries)
            if observedEntries.count == 3 {
                refreshExpectation.fulfill()
            }
        }
        defer { CredentialIdentityStoreManager.populateObserver = nil }

        await vm.unlock(password: fixturePassword)

        let original = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { !$0.username.isEmpty })
        let originalUsername = original.username
        try vm.applyEntryEdit(
            .updateEntry(
                entryID: original.id,
                draft: EntryDraftPayload(
                    title: original.title,
                    username: "autofill-updated-user",
                    password: "autofill-updated-password",
                    url: original.url,
                    notes: original.notes,
                    customFields: original.customFields,
                    tags: original.tags
                )
            )
        )

        try vm.restoreEntryVersion(entryID: original.id, historyIndex: 0)

        await fulfillment(of: [refreshExpectation], timeout: 30)

        let republished = try XCTUnwrap(observedEntries.last)
        let entry = try XCTUnwrap(republished.first { $0.id == original.id })
        XCTAssertEqual(
            entry.username,
            originalUsername,
            "AutoFill must see the restored values, not the ones that were rolled back"
        )
    }

    /// Restoring must carry the secondary secrets, not just the password: a version with a
    /// TOTP config and a passkey has to come back usable, both being advertised features.
    func testRestoringCarriesTOTPAndPasskeyBack() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)
        let sessionKey = try XCTUnwrap(vm.sessionKey)

        let original = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { $0.totpConfig != nil })
        let originalSecret = try XCTUnwrap(original.totpConfig?.secret.decrypt(using: sessionKey))
        let originalPasskey = original.passkeyCredential != nil

        // Edit it in a way that drops the TOTP, then roll that back.
        try vm.applyEntryEdit(
            .updateEntry(
                entryID: original.id,
                draft: EntryDraftPayload(
                    title: original.title,
                    username: original.username,
                    password: "totp-dropped",
                    url: original.url,
                    notes: original.notes,
                    customFields: [:],
                    tags: original.tags,
                    totpConfig: nil
                )
            )
        )
        XCTAssertNil(vm.entry(withID: original.id)?.totpConfig, "precondition: the edit dropped it")

        try vm.restoreEntryVersion(entryID: original.id, historyIndex: 0)

        let restored = try XCTUnwrap(vm.entry(withID: original.id))
        let restoredSecret = try XCTUnwrap(restored.totpConfig?.secret.decrypt(using: sessionKey))
        XCTAssertEqual(restoredSecret, originalSecret, "the TOTP secret must come back intact")
        XCTAssertEqual(restored.hasPasskey, originalPasskey, "a passkey must survive the round trip")
        let code = TOTPGenerator.generateCode(config: try XCTUnwrap(restored.totpConfig), sessionKey: sessionKey)
        XCTAssertFalse(code.isEmpty, "the restored TOTP config must still produce a code")
    }

    /// The Restore action is hidden in a read-only database, but the guard that actually
    /// protects the file is the save path. This pins that a restore cannot slip past it.
    func testRestoringInAReadOnlyDatabaseNeverReachesDisk() async throws {
        var reference = try makeReference()
        reference.isReadOnly = true

        let localSaverCalls = CallTracker()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        XCTAssertTrue(vm.isReadOnly)

        let entry = try XCTUnwrap(vm.visibleRootGroup?.allEntries.first { !$0.history.isEmpty })
        try vm.restoreEntryVersion(entryID: entry.id, historyIndex: 0)

        do {
            try await vm.save()
            XCTFail("Expected the save to be refused for a read-only database.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        }

        XCTAssertFalse(localSaverCalls.didCall, "nothing may be written")
    }

    func testRestoringAnEarlierVersionBringsBackItsValues() async throws {
        let (vm, entryID, originalUsername, _) = try await makeViewModelWithEditedEntry()

        try vm.restoreEntryVersion(entryID: entryID, historyIndex: 0)

        XCTAssertEqual(vm.entry(withID: entryID)?.username, originalUsername)
        XCTAssertTrue(vm.isDirty)
    }

    /// Restoring must stay undoable: the replaced state becomes the newest version.
    func testRestoringKeepsTheReplacedStateSoItCanBeUndone() async throws {
        let (vm, entryID, originalUsername, _) = try await makeViewModelWithEditedEntry()

        try vm.restoreEntryVersion(entryID: entryID, historyIndex: 0)
        XCTAssertEqual(vm.history(forEntryID: entryID).first?.entry.username, "history-updated-user")

        try vm.restoreEntryVersion(entryID: entryID, historyIndex: 0)

        XCTAssertEqual(vm.entry(withID: entryID)?.username, "history-updated-user")
        XCTAssertEqual(vm.history(forEntryID: entryID).first?.entry.username, originalUsername)
    }

    func testRestoringAnOutOfRangeVersionThrowsAndChangesNothing() async throws {
        let (vm, entryID, _, _) = try await makeViewModelWithEditedEntry()
        let usernameBefore = vm.entry(withID: entryID)?.username

        XCTAssertThrowsError(try vm.restoreEntryVersion(entryID: entryID, historyIndex: 5))

        XCTAssertEqual(vm.entry(withID: entryID)?.username, usernameBefore)
    }

    func testShowingGroupInAutoFillAgainOverridesExcludedParent() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Excluded Parent", in: rootGroupID)
        let parent = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Excluded Parent" }))
        try vm.createGroup(named: "Exception", in: parent.id)
        let child = try XCTUnwrap(vm.group(withID: parent.id)?.groups.first)

        try vm.setGroupExcludedFromAutoFill(true, groupID: parent.id)
        try vm.setGroupExcludedFromAutoFill(false, groupID: child.id)

        XCTAssertTrue(vm.isGroupExcludedFromAutoFill(groupID: parent.id))
        XCTAssertFalse(vm.isGroupExcludedFromAutoFill(groupID: child.id))
    }

    func testEntriesInGroupHiddenFromSearchAreExcludedFromSearchResults() async throws {
        let visible = KPEntry(title: "Searchable Alpha")
        let hidden = KPEntry(title: "Searchable Beta")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Visible", entries: [visible]),
            KPGroup(name: "Secret", entries: [hidden], searchingEnabled: .disabled),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        vm.searchText = "Searchable"

        XCTAssertEqual(vm.searchResults.map(\.id), [visible.id])
        XCTAssertFalse(
            vm.isEntryInRecycleBin(entryID: hidden.id),
            "Search exclusion must not mark entries as recycled"
        )
    }

    func testSearchExclusionIsInheritedBySubgroups() async throws {
        let visible = KPEntry(title: "Searchable Alpha")
        let deeplyHidden = KPEntry(title: "Searchable Deep")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Visible", entries: [visible]),
            KPGroup(
                name: "Secret",
                groups: [KPGroup(name: "Deeper", entries: [deeplyHidden])],
                searchingEnabled: .disabled
            ),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        vm.searchText = "Searchable"

        XCTAssertEqual(vm.searchResults.map(\.id), [visible.id])
    }

    func testExplicitlyEnabledSubgroupOverridesInheritedSearchExclusion() async throws {
        let hidden = KPEntry(title: "Searchable Hidden")
        let reEnabled = KPEntry(title: "Searchable Exception")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(
                name: "Secret",
                entries: [hidden],
                groups: [KPGroup(name: "Exception", entries: [reEnabled], searchingEnabled: .enabled)],
                searchingEnabled: .disabled
            ),
            KPGroup(name: "Filler"),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        vm.searchText = "Searchable"

        XCTAssertEqual(vm.searchResults.map(\.id), [reEnabled.id])
    }

    func testTogglingSearchExclusionUpdatesSearchResultsLive() async throws {
        let target = KPEntry(title: "Toggle Target")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Hideable", entries: [target]),
            KPGroup(name: "Filler"),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)
        let group = try XCTUnwrap(vm.currentRootGroup?.groups.first(where: { $0.name == "Hideable" }))

        vm.searchText = "Toggle Target"
        XCTAssertEqual(vm.searchResults.map(\.id), [target.id])

        try vm.setGroupExcludedFromAutoFill(true, groupID: group.id)
        XCTAssertTrue(vm.searchResults.isEmpty)

        try vm.setGroupExcludedFromAutoFill(false, groupID: group.id)
        XCTAssertEqual(vm.searchResults.map(\.id), [target.id])
    }

    /// Deliberate: `<EnableSearching>` hides a group from search and AutoFill,
    /// not from browsing surfaces — the tag browser keeps listing its entries.
    func testTagBrowserStillListsEntriesInGroupsHiddenFromSearch() async throws {
        let tagged = KPEntry(title: "Tagged Hidden", tags: ["ops"], hasTagsElement: true)
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Secret", entries: [tagged], searchingEnabled: .disabled),
            KPGroup(name: "Filler"),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(vm.entries(withTag: "ops").map(\.id), [tagged.id])

        vm.searchText = "ops"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testFolderPathJoinsAncestorGroupNamesBelowVisibleRoot() async throws {
        let nested = KPEntry(title: "Nested")
        let topLevel = KPEntry(title: "Top Level")
        let root = KPGroup(
            name: "Root",
            entries: [topLevel],
            groups: [KPGroup(name: "Work", groups: [KPGroup(name: "Servers", entries: [nested])])]
        )
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(vm.folderPath(forEntryID: nested.id), "Work / Servers")
        XCTAssertNil(vm.folderPath(forEntryID: topLevel.id))
        XCTAssertNil(vm.folderPath(forEntryID: UUID()))
    }

    /// A KDBX tree wraps everything in a synthetic root whose one child is the
    /// visible root; neither name belongs in an entry's folder path.
    func testFolderPathExcludesSyntheticWrapperAndVisibleRootName() async throws {
        let nested = KPEntry(title: "Nested")
        let topLevel = KPEntry(title: "Top Level")
        let wrapper = KPGroup(name: "Wrapper", groups: [
            KPGroup(
                name: "Passwords",
                entries: [topLevel],
                groups: [KPGroup(name: "Work", entries: [nested])]
            ),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: wrapper)

        XCTAssertEqual(vm.folderPath(forEntryID: nested.id), "Work")
        XCTAssertNil(vm.folderPath(forEntryID: topLevel.id))
    }

    func testHidingGroupFromAutoFillRemovesItsEntriesFromCredentialStore() async throws {
        let vm = try makeViewModel()
        var observedEntries: [[KPEntry]] = []
        let refreshExpectation = expectation(description: "Credential store refreshed after hiding a group")

        CredentialIdentityStoreManager.populateObserver = { _, entries in
            observedEntries.append(entries)
            if observedEntries.count == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)

        let workGroup = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Work" }))
        let hiddenEntry = try XCTUnwrap(workGroup.allEntries.first(where: { !$0.title.isEmpty }))
        let hiddenEntryIDs = Set(workGroup.allEntries.map(\.id))

        try vm.setGroupExcludedFromAutoFill(true, groupID: workGroup.id)

        await fulfillment(of: [refreshExpectation], timeout: 30)

        XCTAssertTrue(
            hiddenEntryIDs.isDisjoint(with: Set(observedEntries.last?.map(\.id) ?? [])),
            "Entries of a hidden group must not reach the credential store"
        )

        vm.searchText = hiddenEntry.title
        XCTAssertFalse(
            vm.searchResults.contains(where: { $0.id == hiddenEntry.id }),
            "Hiding a group also hides its entries from the in-app search"
        )
        XCTAssertFalse(
            vm.isEntryInRecycleBin(entryID: hiddenEntry.id),
            "Search exclusion must not mark entries as recycled"
        )
    }

    func testGroupDeletionSummaryCountsEntriesAndNestedGroups() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let rootGroupID = try XCTUnwrap(vm.visibleRootGroupID)
        try vm.createGroup(named: "Parent Summary", in: rootGroupID)
        let parent = try XCTUnwrap(vm.visibleRootGroup?.groups.first(where: { $0.name == "Parent Summary" }))
        try vm.createGroup(named: "Child Summary", in: parent.id)
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parent.id,
                draft: EntryDraftPayload(title: "Summary Entry", password: "secret")
            )
        )

        let summary = try XCTUnwrap(vm.groupDeletionSummary(forGroupID: parent.id))

        XCTAssertEqual(summary.name, "Parent Summary")
        XCTAssertEqual(summary.entryCount, 1)
        XCTAssertEqual(summary.nestedGroupCount, 1)
        XCTAssertFalse(vm.isGroupProtectedFromDeletion(groupID: parent.id))
    }

    func testMoveToRecycleBinRefreshesCredentialStoreAndRemovesEntry() async throws {
        let vm = try makeViewModel()
        let refreshExpectation = expectation(description: "Credential store refreshed after recycle bin move")
        var observedEntries: [[KPEntry]] = []

        CredentialIdentityStoreManager.populateObserver = { _, entries in
            observedEntries.append(entries)
            if observedEntries.count == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(
            vm.rootGroup?.allEntries.first(where: {
                $0.hasPassword &&
                !$0.url.isEmpty &&
                !$0.username.isEmpty
            })
        )

        try vm.deleteEntry(entry.id, sendToRecycleBin: true)

        await fulfillment(of: [refreshExpectation], timeout: 30)

        XCTAssertFalse(observedEntries.last?.contains(where: { $0.id == entry.id }) ?? true)
        XCTAssertTrue(vm.isEntryInRecycleBin(entryID: entry.id))
    }

    func testPermanentDeleteFromRecycleBinRefreshesCredentialStore() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        let entry = try XCTUnwrap(
            vm.rootGroup?.allEntries.first(where: {
                $0.hasPassword &&
                !$0.url.isEmpty &&
                !$0.username.isEmpty
            })
        )

        let recycleExpectation = expectation(description: "Credential store refreshed after recycle bin move")
        var observedRecycleRefresh = false
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            guard observedRecycleRefresh == false else { return }
            observedRecycleRefresh = true
            recycleExpectation.fulfill()
        }
        try vm.deleteEntry(entry.id, sendToRecycleBin: true)
        await fulfillment(of: [recycleExpectation], timeout: 30)
        XCTAssertTrue(vm.isEntryInRecycleBin(entryID: entry.id))

        let refreshExpectation = expectation(description: "Credential store refreshed after permanent delete")
        var refreshedEntries: [KPEntry] = []
        var observedPermanentDeleteRefresh = false
        CredentialIdentityStoreManager.populateObserver = { _, entries in
            guard observedPermanentDeleteRefresh == false else { return }
            observedPermanentDeleteRefresh = true
            refreshedEntries = entries
            refreshExpectation.fulfill()
        }

        try vm.deleteEntry(entry.id, sendToRecycleBin: false)

        await fulfillment(of: [refreshExpectation], timeout: 30)

        XCTAssertFalse(refreshedEntries.contains(where: { $0.id == entry.id }))
        XCTAssertFalse(vm.isEntryInRecycleBin(entryID: entry.id))
    }

    func testCredentialStoreEntriesIncludePasskeyOnlyEntries() {
        let sessionKey = SymmetricKey(size: .bits256)
        let passwordEntry = KPEntry(
            title: "Password Entry",
            username: "alice",
            password: try! EncryptedValue.encrypt("secret", using: sessionKey),
            url: "https://example.com"
        )
        let passkeyEntry = KPEntry(
            title: "Passkey Entry",
            username: "",
            password: .empty,
            url: "https://example.com",
            customFields: passkeyFields(),
            passkeyPrivateKey: try! EncryptedValue.encrypt(
                "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgZz8y\n-----END PRIVATE KEY-----",
                using: sessionKey
            )
        )
        let noteEntry = KPEntry(title: "Note Entry", username: "", password: .empty, url: "")
        let expiredEntry = KPEntry(
            title: "Expired Entry",
            username: "expired",
            password: try! EncryptedValue.encrypt("old-secret", using: sessionKey),
            url: "https://expired.example.com",
            expires: true,
            expiryTime: .distantPast
        )
        let root = KPGroup(
            name: "Root",
            entries: [passwordEntry, passkeyEntry, noteEntry, expiredEntry]
        )

        let identities = DatabaseViewModel.credentialStoreEntries(from: root)

        XCTAssertEqual(Set(identities.map(\.id)), Set([passwordEntry.id, passkeyEntry.id]))
    }

    func testCredentialStoreEntriesSkipsGroupsHiddenFromAutoFill() throws {
        let sessionKey = SymmetricKey(size: .bits256)
        func makeEntry(_ title: String) throws -> KPEntry {
            KPEntry(
                title: title,
                username: "user",
                password: try EncryptedValue.encrypt("secret", using: sessionKey),
                url: "https://example.com"
            )
        }

        let visible = try makeEntry("Visible")
        let hidden = try makeEntry("Hidden")
        let deeplyHidden = try makeEntry("Deeply Hidden")
        let reEnabled = try makeEntry("Re-enabled")

        let root = KPGroup(
            name: "Root",
            entries: [visible],
            groups: [
                KPGroup(
                    name: "Secret",
                    entries: [hidden],
                    groups: [
                        KPGroup(name: "Deeper", entries: [deeplyHidden]),
                        KPGroup(name: "Exception", entries: [reEnabled], searchingEnabled: .enabled),
                    ],
                    searchingEnabled: .disabled
                )
            ]
        )

        let identities = DatabaseViewModel.credentialStoreEntries(from: root)

        XCTAssertEqual(Set(identities.map(\.id)), Set([visible.id, reEnabled.id]))
    }

    func testSaveCoordinatorCredentialStoreEntriesSkipsGroupsHiddenFromAutoFill() throws {
        let sessionKey = SymmetricKey(size: .bits256)
        let visible = KPEntry(
            title: "Visible",
            password: try EncryptedValue.encrypt("secret", using: sessionKey)
        )
        let hidden = KPEntry(
            title: "Hidden",
            password: try EncryptedValue.encrypt("secret", using: sessionKey)
        )
        let root = KPGroup(
            name: "Root",
            entries: [visible],
            groups: [KPGroup(name: "Secret", entries: [hidden], searchingEnabled: .disabled)]
        )

        let entries = AutoFillSaveCoordinator.credentialStoreEntries(from: root)

        XCTAssertEqual(Set(entries.map(\.id)), Set([visible.id]))
    }

    func testUnlockDisabledDatabaseDoesNotPopulateOrClaimActivePointer() async throws {
        let otherReference = try makeReference()
        DatabaseListStore.update(otherReference)
        DatabaseListStore.markDatabaseOpened(id: otherReference.id)

        let disabledReference = try makeReference(autoFillEnabled: false)
        DatabaseListStore.update(disabledReference)

        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("Unlocking an AutoFill-disabled database must not populate the credential store")
        }

        let vm = try makeViewModel(reference: disabledReference)
        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, otherReference.id)
        let storedReference = try XCTUnwrap(
            DatabaseListStore.databases.first(where: { $0.id == disabledReference.id })
        )
        XCTAssertNotNil(storedReference.lastOpenedAt, "markDatabaseOpened still records the open time")
        XCTAssertFalse(storedReference.autoFillEnabled)
    }

    func testUnlockEnabledDatabasePopulatesAndSetsActivePointer() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)

        let populateExpectation = expectation(description: "Credential store populated after unlocking an enabled database")
        var observedDatabaseID: UUID?
        var observedEntries: [KPEntry] = []
        var didObservePopulate = false
        CredentialIdentityStoreManager.populateObserver = { databaseID, entries in
            guard didObservePopulate == false else { return }
            didObservePopulate = true
            observedDatabaseID = databaseID
            observedEntries = entries
            populateExpectation.fulfill()
        }

        await vm.unlock(password: fixturePassword)

        await fulfillment(of: [populateExpectation], timeout: 30)
        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(observedDatabaseID, reference.id)
        XCTAssertFalse(observedEntries.isEmpty)
        let unlockedRoot = try XCTUnwrap(vm.rootGroup)
        XCTAssertEqual(
            Set(observedEntries.map(\.id)),
            Set(DatabaseViewModel.credentialStoreEntries(from: unlockedRoot).map(\.id))
        )
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
    }

    func testSaveOnDisabledDatabaseDoesNotRepopulateStore() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(
            reference: reference,
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("saved-hash".utf8))
            }
        )
        await unlockAwaitingInitialPopulate(vm)

        DatabaseListStore.setAutoFillEnabled(false, for: reference)
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("Saving a database disabled for AutoFill must not repopulate the credential store")
        }

        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Saved While Disabled")
        try await vm.save()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.draft)
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func testPopulateCredentialStoreIfUnlockedRereadsFlagFromRegistry() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)

        // Disable in the persisted registry only; the view model keeps its
        // (now stale) enabled in-memory copy, so silence proves the guard
        // re-reads the registry.
        DatabaseListStore.setAutoFillEnabled(false, for: reference)
        XCTAssertTrue(vm.databaseReference.autoFillEnabled)
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("The foreground refresh must re-read the persisted AutoFill flag and stay silent")
        }

        vm.populateCredentialStoreIfUnlocked()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(DatabaseListStore.activeAutoFillDatabaseID)
    }

    func testUnlockRefreshesOnlyTheUnlockedDatabase() async throws {
        let fake = FakeCredentialIdentityStore()
        let otherDatabaseID = UUID()
        let otherEntry = KPEntry(
            title: "Other Database Entry",
            username: "bob",
            password: try EncryptedValue.encrypt("other-secret", using: SymmetricKey(size: .bits256)),
            url: "https://other-database.example.com"
        )
        fake.stored = CredentialIdentityStoreManager.passwordIdentities(for: otherEntry, in: otherDatabaseID)
        XCTAssertFalse(fake.stored.isEmpty)
        CredentialIdentityStoreManager.storeProviderOverride = fake

        let mutationExpectation = expectation(description: "Unlock refresh mutated the fake store")
        fake.onMutation = {
            mutationExpectation.fulfill()
        }

        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)

        let populateExpectation = expectation(description: "Populate observer fired for the unlocked database")
        var observedDatabaseIDs: [UUID] = []
        CredentialIdentityStoreManager.populateObserver = { databaseID, _ in
            observedDatabaseIDs.append(databaseID)
            populateExpectation.fulfill()
        }

        await vm.unlock(password: fixturePassword)

        await fulfillment(of: [populateExpectation, mutationExpectation], timeout: 30)
        await CredentialIdentityStoreManager.waitForPendingMutations()
        XCTAssertEqual(observedDatabaseIDs, [reference.id])
        XCTAssertEqual(fake.calls, ["saveCredentialIdentities"])

        let storedDatabaseIDs = Set(fake.stored.compactMap { identity -> UUID? in
            guard let recordIdentifier = identity.recordIdentifier,
                  case .current(let parsed) = CredentialRecordIdentifier.parse(recordIdentifier)
            else { return nil }
            return parsed.databaseID
        })
        XCTAssertEqual(
            storedDatabaseIDs,
            [reference.id, otherDatabaseID],
            "The unlocked database's refresh must keep the other database's identities"
        )
        XCTAssertFalse(fake.calls.contains("replaceCredentialIdentities"))
        XCTAssertFalse(fake.calls.contains("removeAllCredentialIdentities"))
    }

    /// End-to-end version of `testUnlockRefreshesOnlyTheUnlockedDatabase`:
    /// there the first database's identities are hand-seeded, here they are
    /// published by a real unlock. The app holds one session at a time, so
    /// reaching a two-database store means unlock A → lock A → unlock B, and
    /// every step of that sequence has to leave A's suggestions in place for
    /// QuickType to offer both databases for the same site.
    func testUnlockingASecondDatabaseAddsToTheFirstDatabasesIdentities() async throws {
        let fake = FakeCredentialIdentityStore()
        CredentialIdentityStoreManager.storeProviderOverride = fake

        let referenceA = try makeReference()
        DatabaseListStore.update(referenceA)
        let viewModelA = try makeViewModel(reference: referenceA)
        await unlockAwaitingInitialPopulate(viewModelA)
        try await awaitStoredDatabaseIDs(in: fake, toEqual: [referenceA.id])

        viewModelA.lock(manuallyTriggered: true)
        XCTAssertState(viewModelA.state, is: .locked)

        let referenceB = try makeReference()
        DatabaseListStore.update(referenceB)
        let viewModelB = try makeViewModel(reference: referenceB)
        await unlockAwaitingInitialPopulate(viewModelB)

        try await awaitStoredDatabaseIDs(in: fake, toEqual: [referenceA.id, referenceB.id])
        XCTAssertFalse(
            fake.calls.contains("removeAllCredentialIdentities"),
            "The second unlock must refresh additively, never empty the store"
        )
    }

    /// Locking is a session teardown, not an AutoFill state change: the
    /// published identities have to survive it, or QuickType suggestions
    /// would vanish the moment the app auto-locks.
    func testLockLeavesPublishedIdentitiesInTheStore() async throws {
        let fake = FakeCredentialIdentityStore()
        CredentialIdentityStoreManager.storeProviderOverride = fake

        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)
        try await awaitStoredDatabaseIDs(in: fake, toEqual: [reference.id])
        let identityCountAfterUnlock = fake.stored.count

        fake.onMutation = { XCTFail("Locking must not mutate the credential identity store") }
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Locking must not clear the credential identity store")
        }
        CredentialIdentityStoreManager.removeDatabaseObserver = { _, _ in
            XCTFail("Locking must not remove the database's identities")
        }

        vm.lock(manuallyTriggered: true)

        await CredentialIdentityStoreManager.waitForPendingMutations()
        XCTAssertState(vm.state, is: .locked)
        XCTAssertEqual(fake.stored.count, identityCountAfterUnlock)
        fake.onMutation = nil
    }

    /// Polls the fake store until the set of database ids owning its tagged
    /// identities equals `expected`. The manager's writes are fire-and-forget
    /// `Task`s, so the store settles a little after `populateObserver` fires.
    private func awaitStoredDatabaseIDs(
        in store: FakeCredentialIdentityStore,
        toEqual expected: Set<UUID>,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var observed: Set<UUID> = []

        while ContinuousClock.now < deadline {
            observed = Set(store.stored.compactMap { identity -> UUID? in
                guard let recordIdentifier = identity.recordIdentifier,
                      case .current(let parsed) = CredentialRecordIdentifier.parse(recordIdentifier)
                else { return nil }
                return parsed.databaseID
            })
            if observed == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail(
            "Timed out waiting for the store to hold identities of \(expected); it held \(observed)",
            file: file,
            line: line
        )
    }

    func testGlobalToggleOnRefreshesOnlyUnlockedEnabledDatabase() async throws {
        // The Settings screen's Quick AutoFill "on" handler calls
        // populateCredentialStoreIfUnlocked() on the open session. The silent
        // half (open database disabled in the registry) is pinned by
        // testPopulateCredentialStoreIfUnlockedRereadsFlagFromRegistry.
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)

        let refreshExpectation = expectation(description: "Toggle-on refresh populated the open database")
        var observedDatabaseID: UUID?
        var didObserveRefresh = false
        CredentialIdentityStoreManager.populateObserver = { databaseID, _ in
            guard didObserveRefresh == false else { return }
            didObserveRefresh = true
            observedDatabaseID = databaseID
            refreshExpectation.fulfill()
        }

        vm.populateCredentialStoreIfUnlocked()

        await fulfillment(of: [refreshExpectation], timeout: 30)
        XCTAssertEqual(observedDatabaseID, reference.id)
    }

    func testToggleOnOfOpenDatabaseRefreshesImmediatelyThroughHandler() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)

        let listViewModel = DatabaseListViewModel()
        var handlerInvocations: [UUID] = []
        // The AppRootView wiring: refresh immediately when the just-enabled
        // database is the currently unlocked session, no-op otherwise.
        listViewModel.autoFillEnabledRefreshHandler = { databaseID in
            handlerInvocations.append(databaseID)
            guard databaseID == vm.databaseReference.id else { return }
            vm.populateCredentialStoreIfUnlocked()
        }

        let refreshExpectation = expectation(description: "Re-enabling the open database republished immediately")
        var observedDatabaseID: UUID?
        var didObserveRefresh = false
        CredentialIdentityStoreManager.populateObserver = { databaseID, _ in
            guard didObserveRefresh == false else { return }
            didObserveRefresh = true
            observedDatabaseID = databaseID
            refreshExpectation.fulfill()
        }

        listViewModel.setAutoFillEnabled(false, for: reference)
        listViewModel.setAutoFillEnabled(true, for: reference)

        await fulfillment(of: [refreshExpectation], timeout: 30)
        XCTAssertEqual(observedDatabaseID, reference.id)
        XCTAssertEqual(handlerInvocations, [reference.id], "The handler runs only for the enable")
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
    }

    func testToggleOnOfNonOpenDatabaseStaysLazy() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let backgroundReference = try makeReference(autoFillEnabled: false)
        DatabaseListStore.update(backgroundReference)

        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)

        let listViewModel = DatabaseListViewModel()
        var handlerInvocations: [UUID] = []
        listViewModel.autoFillEnabledRefreshHandler = { databaseID in
            handlerInvocations.append(databaseID)
            guard databaseID == vm.databaseReference.id else { return }
            vm.populateCredentialStoreIfUnlocked()
        }
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("Enabling a database that is not the open session must stay lazy")
        }

        listViewModel.setAutoFillEnabled(true, for: backgroundReference)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(handlerInvocations, [backgroundReference.id])
        let storedBackgroundReference = try XCTUnwrap(
            DatabaseListStore.databases.first(where: { $0.id == backgroundReference.id })
        )
        XCTAssertTrue(storedBackgroundReference.autoFillEnabled, "The enable itself must still persist")
    }

    func testToggleOffOfBackgroundDatabaseTriggersRemovalNotClear() async throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let backgroundReference = try makeReference()
        DatabaseListStore.update(backgroundReference)

        let vm = try makeViewModel(reference: reference)
        await unlockAwaitingInitialPopulate(vm)
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)

        let listViewModel = DatabaseListViewModel()
        var handlerInvocations: [UUID] = []
        listViewModel.autoFillEnabledRefreshHandler = { databaseID in
            handlerInvocations.append(databaseID)
        }
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            XCTFail("Disabling a background database must not repopulate anything")
        }
        CredentialIdentityStoreManager.clearObserver = {
            XCTFail("Disabling one database must not clear the whole credential store")
        }
        let removalExpectation = expectation(description: "Targeted removal for the disabled background database")
        var observedRemoval: (databaseID: UUID, includingLegacyIdentifiers: Bool)?
        var didObserveRemoval = false
        CredentialIdentityStoreManager.removeDatabaseObserver = { databaseID, includingLegacyIdentifiers in
            guard didObserveRemoval == false else { return }
            didObserveRemoval = true
            observedRemoval = (databaseID, includingLegacyIdentifiers)
            removalExpectation.fulfill()
        }

        listViewModel.setAutoFillEnabled(false, for: backgroundReference)

        await fulfillment(of: [removalExpectation], timeout: 30)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(observedRemoval?.databaseID, backgroundReference.id)
        XCTAssertEqual(observedRemoval?.includingLegacyIdentifiers, false)
        XCTAssertTrue(handlerInvocations.isEmpty, "The refresh handler runs only for enables")
        XCTAssertEqual(DatabaseListStore.activeAutoFillDatabaseID, reference.id)
    }

    func testUnlockWithWrongPasswordTransitionsToError() async throws {
        let vm = try makeViewModel()
        let data = try Data(contentsOf: fixtureURL())
        let fullSHA256 = KDBXCrypto.sha256(data).hexString
        let expectedSHA256Prefix = String(fullSHA256.prefix(16))

        await vm.unlock(password: "wrong-password")

        guard case .error(let failure) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertEqual(failure.category, .authentication)
        XCTAssertEqual(failure.errorCode, "auth.invalid_credentials")
        XCTAssertEqual(vm.failedAttempts, 1)
        XCTAssertNil(vm.rootGroup)

        let diagnostics = try XCTUnwrap(failure.diagnostics)
        XCTAssertTrue(diagnostics.details.contains("Unlock Method: password"))
        XCTAssertTrue(diagnostics.details.contains("Password Supplied: yes"))
        XCTAssertTrue(diagnostics.details.contains("Key File Supplied: no"))
        XCTAssertTrue(diagnostics.details.contains("Failed Attempts Before Attempt: 0"))
        XCTAssertTrue(diagnostics.details.contains("Database Source: local"))
        XCTAssertTrue(diagnostics.details.contains("Encrypted File Bytes: \(data.count)"))
        XCTAssertTrue(diagnostics.details.contains("Encrypted File SHA-256 Prefix: \(expectedSHA256Prefix)"))
        XCTAssertTrue(diagnostics.details.contains("KDBX Header: version=KDBX"))
        XCTAssertFalse(diagnostics.details.contains(fullSHA256))
        XCTAssertTrue(failure.copyableDetails.contains("Diagnostics:"))
    }

    func testCloudParseFailureIncludesSyncDiagnosticsWithoutPrivateIdentifiers() async throws {
        let remoteRev = "rev-1234567890abcdef"
        let remoteHash = "hash-abcdefghijklmnop"
        let lastSyncedAt = Date(timeIntervalSince1970: 123)
        let invalidData = Data("not-a-kdbx".utf8)
        let resolvedReference = {
            var reference = makeCloudReference(remoteRev: remoteRev)
            reference.updateCloudSyncMetadata { metadata in
                metadata.remoteContentHash = remoteHash
                metadata.lastSyncedAt = lastSyncedAt
            }
            return reference
        }()
        let cacheURL = DatabaseListStore.cacheLocation(for: resolvedReference)

        let vm = DatabaseViewModel(
            databaseReference: makeCloudReference(),
            cloudSyncOperation: { _, _ in
                CloudSyncResolution(
                    reference: resolvedReference,
                    localURL: cacheURL,
                    data: invalidData,
                    status: .downloaded
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        guard case .error(let failure) = vm.state else {
            XCTFail("Expected .error state")
            return
        }

        let diagnostics = try XCTUnwrap(failure.diagnostics)
        XCTAssertTrue(diagnostics.details.contains("Database Source: cloud"))
        XCTAssertTrue(diagnostics.details.contains("Cloud Provider: Dropbox"))
        XCTAssertTrue(diagnostics.details.contains("Cloud Sync Status: downloaded"))
        XCTAssertTrue(diagnostics.details.contains("Remote Revision Prefix: \(String(remoteRev.prefix(12)))"))
        XCTAssertTrue(diagnostics.details.contains("Remote Content Hash Prefix: \(String(remoteHash.prefix(12)))"))
        XCTAssertTrue(diagnostics.details.contains("Encrypted File Bytes: \(invalidData.count)"))
        XCTAssertFalse(diagnostics.details.contains(remoteRev))
        XCTAssertFalse(diagnostics.details.contains(remoteHash))
        XCTAssertFalse(diagnostics.details.contains("/Vaults/vault.kdbx"))
        XCTAssertFalse(diagnostics.details.contains("acct-1"))
        XCTAssertFalse(diagnostics.details.contains("fileId"))
    }

    func testBiometricFailureDiagnosticsDescribeBiometricMethodWithoutPasswordOrKeyFileData() throws {
        let diagnostics = DatabaseOpenDiagnostics.make(
            reference: try makeReference(),
            unlockMethod: .biometrics,
            passwordSupplied: false,
            keyFileSupplied: false,
            failedAttemptsBeforeAttempt: 0,
            encryptedData: nil,
            cloudSyncStatus: nil
        )

        let failure = DatabaseOpenFailure.classify(
            LAError(.biometryNotAvailable),
            isCloudBacked: false,
            diagnostics: diagnostics
        )

        let details = try XCTUnwrap(failure.diagnostics?.details)
        XCTAssertEqual(failure.category, DatabaseOpenFailure.Category.biometric)
        XCTAssertTrue(details.contains("Unlock Method: biometrics"))
        XCTAssertTrue(details.contains("Password Supplied: no"))
        XCTAssertTrue(details.contains("Key File Supplied: no"))
        XCTAssertFalse(details.contains(fixturePassword))
        XCTAssertFalse(details.localizedCaseInsensitiveContains("key file data"))
    }

    func testMalformedXMLKeyFileFailureKeepsItsActionableMessage() {
        let failure = DatabaseOpenFailure.classify(
            KeyFileProcessor.KeyFileError.xmlKeyDataInvalid,
            isCloudBacked: false
        )

        XCTAssertEqual(failure.summary, "Key file XML contains invalid key data")
        XCTAssertEqual(failure.errorCode, "key_file.invalid_xml_data")
        XCTAssertEqual(failure.category, .fileAccess)
        XCTAssertFalse(failure.countsTowardFailedAttempts)
        XCTAssertFalse(failure.canChooseDifferentFile)
        XCTAssertTrue(failure.canRetryUnlock)
    }

    func testTwofishHeaderDiagnosticsUseRecognizedCipherName() throws {
        let loaded = try KDBXCompatibilitySupport.load(
            .syntheticTwofish,
            bundle: Bundle(for: Self.self)
        )
        let diagnostics = DatabaseOpenDiagnostics.make(
            reference: try makeReference(),
            unlockMethod: .password,
            passwordSupplied: true,
            keyFileSupplied: false,
            failedAttemptsBeforeAttempt: 0,
            encryptedData: loaded.sourceData,
            cloudSyncStatus: nil
        )

        XCTAssertTrue(diagnostics.details.contains("cipher=Twofish-256-CBC"))
        XCTAssertFalse(diagnostics.details.contains("cipher=unknown"))
    }

    func testCloudUnlockShowsProviderSpecificSyncMessageBeforeDecryption() async throws {
        let reference = makeCloudReference()
        let data = try Data(contentsOf: fixtureURL())
        let syncStarted = expectation(description: "Cloud sync started")
        let gate = AsyncGate()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                await gate.pause(started: syncStarted)
                return CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: data,
                    status: .downloaded
                )
            }
        )

        let unlockTask = Task {
            await vm.unlock(password: fixturePassword)
        }

        await fulfillment(of: [syncStarted], timeout: 1)
        await gate.waitUntilPaused()

        XCTAssertState(vm.state, is: .unlocking)
        XCTAssertEqual(vm.unlockStatusMessage, DatabaseViewModel.syncStatusMessage(for: reference))

        await gate.resume()
        await unlockTask.value

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.unlockStatusMessage, DatabaseViewModel.decryptingStatusMessage)
    }

    func testCloudUnlockShowsOfflineBannerWhenCachedCopyDecryptsSuccessfully() async throws {
        let reference = makeCloudReference()
        let data = try Data(contentsOf: fixtureURL())
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: data,
                    status: .offlineCached
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertEqual(vm.cloudSyncBannerText, CloudSyncResolution.offlineCachedBannerMessage)
    }

    func testCloudUnlockTransitionsToErrorWhenSyncFails() async {
        let vm = DatabaseViewModel(
            databaseReference: makeCloudReference(),
            cloudSyncOperation: { _, _ in
                throw CloudProviderError.fileNotFound
            }
        )

        await vm.unlock(password: fixturePassword)

        guard case .error(let failure) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertEqual(failure.category, .cloud)
        XCTAssertEqual(failure.errorCode, "cloud.file_not_found")
        XCTAssertEqual(vm.failedAttempts, 0)
        XCTAssertNil(vm.rootGroup)
    }

    func testCloudUnlockTransitionsToErrorWhenDownloadedDataCannotBeParsed() async {
        let reference = makeCloudReference()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: Data("not-a-kdbx".utf8),
                    status: .downloaded
                )
            }
        )

        await vm.unlock(password: fixturePassword)

        guard case .error(let failure) = vm.state else {
            XCTFail("Expected .error state")
            return
        }
        XCTAssertEqual(failure.errorCode, "format.invalid_signature")
        XCTAssertEqual(vm.failedAttempts, 0)
        XCTAssertNil(vm.rootGroup)
        XCTAssertNil(vm.cloudSyncBannerText)
    }

    func testFileAccessErrorDoesNotIncrementFailedAttempts() async throws {
        var reference = try makeReference()
        reference.bookmarkData = Data("invalid-bookmark".utf8)

        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL()), for: reference.id)
        let vm = DatabaseViewModel(databaseReference: reference)

        await vm.unlock(password: fixturePassword)

        guard case .error(let failure) = vm.state else {
            XCTFail("Expected .error state")
            return
        }

        XCTAssertEqual(failure.category, .fileAccess)
        XCTAssertEqual(vm.failedAttempts, 0)
        XCTAssertNil(vm.lockoutUntil)
    }

    func testSearchResultsMatchesEntryFieldsCaseInsensitively() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        guard case .unlocked = vm.state else {
            XCTFail("Expected unlocked state before search")
            return
        }

        let allEntries = vm.rootGroup?.allEntries ?? []
        let entryByTitle = allEntries.first(where: { !$0.title.isEmpty })
        let entryByUsername = allEntries.first(where: { !$0.username.isEmpty })
        let entryByURL = allEntries.first(where: { !$0.url.isEmpty })
        let entryByNotes = allEntries.first(where: { !$0.notes.isEmpty })

        if let entryByTitle {
            vm.searchText = mixedCasePrefix(from: entryByTitle.title)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByTitle.id }))
        }

        if let entryByUsername {
            vm.searchText = mixedCasePrefix(from: entryByUsername.username)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByUsername.id }))
        }

        if let entryByURL {
            vm.searchText = mixedCasePrefix(from: entryByURL.url)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByURL.id }))
        }

        if let entryByNotes {
            vm.searchText = mixedCasePrefix(from: entryByNotes.notes)
            XCTAssertTrue(vm.searchResults.contains(where: { $0.id == entryByNotes.id }))
        }

        vm.searchText = ""
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "___no_match___"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testSearchResultsMatchDiacriticInsensitively() async throws {
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: "Diacritics",
                destination: .appOnlyAcknowledged,
                password: "diacritics password"
            )
        )
        let vm = DatabaseViewModel(createdDatabase: created)
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Café Münchén")
            )
        )

        for query in ["Café", "cafe", "CAFÉ", "Münchén", "munchen"] {
            vm.searchText = query
            XCTAssertTrue(
                vm.searchResults.contains(where: { $0.title == "Café Münchén" }),
                "Expected diacritic-insensitive match for query \"\(query)\""
            )
        }
    }

    func testEntryEditRefreshesTitleUsernameSearchAndSort() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Entry Refresh")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Zulu", username: "old-user")
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Bravo", username: "other-user")
            )
        )

        let editedEntryID = try XCTUnwrap(
            vm.group(withID: parentGroupID)?.entries.first(where: { $0.title == "Zulu" })?.id
        )
        vm.sortOrder = .title
        vm.sortAscending = true
        vm.searchText = "old-user"
        XCTAssertEqual(vm.searchResults.map(\.id), [editedEntryID])

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: editedEntryID,
                draft: EntryDraftPayload(title: "Alpha", username: "new-user")
            )
        )

        let editedEntry = try XCTUnwrap(vm.entry(withID: editedEntryID))
        XCTAssertEqual(editedEntry.title, "Alpha")
        XCTAssertEqual(editedEntry.username, "new-user")
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "new-user"
        XCTAssertEqual(vm.searchResults.map(\.id), [editedEntryID])
        XCTAssertEqual(
            vm.sortedEntries(vm.group(withID: parentGroupID)?.entries ?? []).map(\.title),
            ["Alpha", "Bravo"]
        )
    }

    // MARK: - Tag index

    func testTagIndexListsDistinctTagsWithCounts() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Index")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Alpha", tags: ["Work", "shared"])
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Beta", tags: ["work", "shared"])
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Gamma", tags: ["Personal", "Personal"])
            )
        )

        XCTAssertEqual(Set(vm.allTags), ["Work", "work", "shared", "Personal"])
        XCTAssertEqual(vm.entryCount(forTag: "shared"), 2)
        XCTAssertEqual(vm.entryCount(forTag: "Work"), 1, "Tag identity is exact-string, so case variants stay apart")
        XCTAssertEqual(vm.entryCount(forTag: "work"), 1)
        XCTAssertEqual(
            vm.entryCount(forTag: "Personal"),
            1,
            "An entry repeating a tag — as foreign files do — still counts once"
        )
        XCTAssertEqual(vm.entries(withTag: "shared").map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(vm.entryCount(forTag: "absent"), 0)
        XCTAssertTrue(vm.entries(withTag: "absent").isEmpty)
    }

    func testTagIndexIgnoresEntriesInTheRecycleBin() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Recycle")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Doomed", tags: ["recycled-only", "kept"])
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Survivor", tags: ["kept"])
            )
        )
        let doomed = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Doomed" }))

        try vm.deleteEntry(doomed.id, sendToRecycleBin: true)

        XCTAssertTrue(vm.isEntryInRecycleBin(entryID: doomed.id))
        XCTAssertFalse(vm.allTags.contains("recycled-only"))
        XCTAssertFalse(
            vm.tagsInDisplayOrder.contains("recycled-only"),
            "The editor's suggestion pool is this same index, so a recycled-only tag is never suggested either"
        )
        XCTAssertEqual(vm.entryCount(forTag: "recycled-only"), 0)
        XCTAssertTrue(vm.entries(withTag: "recycled-only").isEmpty)
        XCTAssertEqual(vm.entryCount(forTag: "kept"), 1, "The surviving entry still carries the shared tag")

        vm.searchText = "recycled-only"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testTagIndexUpdatesAfterAnEditAddsAndRemovesATag() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Updates")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Mutable", tags: ["first"])
            )
        )
        let entryID = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Mutable" })?.id)

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: entryID,
                draft: EntryDraftPayload(title: "Mutable", tags: ["first", "second"])
            )
        )

        XCTAssertEqual(Set(vm.allTags), ["first", "second"])
        XCTAssertEqual(vm.entries(withTag: "second").map(\.id), [entryID])

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: entryID,
                draft: EntryDraftPayload(title: "Mutable", tags: ["second"])
            )
        )

        XCTAssertEqual(vm.allTags, ["second"])
        XCTAssertEqual(vm.entryCount(forTag: "first"), 0)
    }

    func testTagIndexIsEmptyForADatabaseWithoutTags() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Free")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        XCTAssertTrue(vm.allTags.isEmpty, "A freshly created database carries no tags")

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Plain")
            )
        )

        XCTAssertTrue(vm.allTags.isEmpty)
        XCTAssertEqual(vm.entryCount(forTag: "anything"), 0)
        XCTAssertTrue(vm.entries(withTag: "anything").isEmpty)
    }

    func testSearchMatchesTagsCaseAndDiacriticInsensitively() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Search")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Bank", tags: ["Réunion Trip"])
            )
        )
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Untagged")
            )
        )

        // Full tag text, then a partial one, each folded like the other fields.
        for query in ["Réunion Trip", "reunion trip", "RÉUN", "trip"] {
            vm.searchText = query
            XCTAssertEqual(
                vm.searchResults.map(\.title),
                ["Bank"],
                "Expected the tag to match query \"\(query)\""
            )
        }

        vm.searchText = "___no_match___"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testSearchIgnoresATagThatSurvivesOnlyInEntryHistory() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag History")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Historic", tags: ["retired-tag"])
            )
        )
        let entryID = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Historic" })?.id)

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: entryID,
                draft: EntryDraftPayload(title: "Historic", tags: ["current-tag"])
            )
        )

        let historySnapshot = try XCTUnwrap(vm.entry(withID: entryID)?.history.first)
        XCTAssertEqual(
            historySnapshot.tags,
            ["retired-tag"],
            "Precondition: the replaced tag lives on in the history snapshot"
        )

        XCTAssertFalse(vm.allTags.contains("retired-tag"))
        vm.searchText = "retired-tag"
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "current-tag"
        XCTAssertEqual(vm.searchResults.map(\.id), [entryID])
    }

    // MARK: - Tag browser

    func testTagsInDisplayOrderSortsFinderStyle() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Sort")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: "Sorted",
                    tags: ["tag10", "Banana", "tag2", "apple"]
                )
            )
        )

        XCTAssertEqual(
            vm.tagsInDisplayOrder,
            ["apple", "Banana", "tag2", "tag10"],
            "Finder-style: case-insensitive (apple before Banana) and numeric-aware (tag2 before tag10)"
        )
    }

    func testTagsInDisplayOrderKeepsCaseVariantsAdjacentAndStable() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Sort Variants")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: "Variants",
                    tags: ["zeta", "Work", "Éclair", "work", "alpha", "WORK"]
                )
            )
        )
        let firstOrder = vm.tagsInDisplayOrder

        // Which case variant wins is the comparator's business (it is a stable,
        // documented tiebreak, not a product decision); what the browser
        // promises is that they land next to each other, with the accented tag
        // collated against its base letter rather than dumped after `z`.
        XCTAssertEqual(
            firstOrder.map { $0.lowercased() },
            ["alpha", "éclair", "work", "work", "work", "zeta"]
        )
        XCTAssertEqual(Set(firstOrder).count, 6, "Case variants stay distinct tags")

        // An unrelated edit rebuilds the index, reordering the dictionary the
        // tags come out of; the tiebreak has to keep the display order put.
        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Unrelated")
            )
        )

        XCTAssertEqual(vm.tagsInDisplayOrder, firstOrder)
    }

    func testSelectedTagAndSelectedGroupAreMutuallyExclusive() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Selection")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Tagged", tags: ["selected"])
            )
        )
        let entryID = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Tagged" })?.id)
        vm.selectedGroupID = parentGroupID
        vm.selectEntry(entryID)

        vm.selectedTag = "selected"

        XCTAssertNil(vm.selectedGroupID, "Selecting a tag clears the sidebar's group selection")
        XCTAssertNil(vm.selectedEntryID, "Selecting a tag clears the entry selection, like switching groups")

        vm.selectedGroupID = parentGroupID

        XCTAssertNil(vm.selectedTag, "Selecting a group clears the tag selection")
    }

    func testSelectedTagSurvivesAnUnrelatedRebuild() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Selection Rebuild")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Tagged", tags: ["kept"])
            )
        )
        vm.selectedTag = "kept"

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Unrelated")
            )
        )

        XCTAssertEqual(vm.selectedTag, "kept")
        XCTAssertNil(
            vm.selectedGroupID,
            "The root fallback must not snap back while a tag is selected — that would clear it"
        )
    }

    func testSelectedTagClearsWhenItsLastCarrierLosesTheTag() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Selection Vanish")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Only Carrier", tags: ["doomed"])
            )
        )
        let entryID = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Only Carrier" })?.id)
        vm.selectedTag = "doomed"
        XCTAssertEqual(vm.entries(withTag: "doomed").map(\.id), [entryID])

        try vm.applyEntryEdit(
            .updateEntry(
                entryID: entryID,
                draft: EntryDraftPayload(title: "Only Carrier", tags: ["replacement"])
            )
        )

        XCTAssertNil(vm.selectedTag, "A tag with no live carrier stops being a valid selection")
        XCTAssertEqual(
            vm.selectedGroupID,
            vm.visibleRootGroupID,
            "The sidebar falls back to the group tree once the tag selection is gone"
        )
        XCTAssertTrue(vm.entries(withTag: "doomed").isEmpty)
        XCTAssertEqual(vm.entryCount(forTag: "doomed"), 0)
    }

    func testFilteredEntriesEmptyOutWhenTheLastCarrierIsRecycled() async throws {
        let vm = try await makeCreatedViewModel(displayName: "Tag Filter Recycle")
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroupID)

        try vm.applyEntryEdit(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Last Carrier", tags: ["fleeting"])
            )
        )
        let entryID = try XCTUnwrap(vm.visibleRootGroup?.entries.first(where: { $0.title == "Last Carrier" })?.id)
        vm.selectedTag = "fleeting"
        XCTAssertEqual(vm.entries(withTag: "fleeting").count, 1)

        try vm.deleteEntry(entryID, sendToRecycleBin: true)

        // The tag-filtered screen re-derives on every render, so this is what it
        // shows: an empty list and its own empty state, no crash and no pop.
        XCTAssertTrue(vm.entries(withTag: "fleeting").isEmpty)
        XCTAssertFalse(vm.tagsInDisplayOrder.contains("fleeting"))
        XCTAssertNil(vm.selectedTag)
    }

    func testLockClearsTheSelectedTag() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        vm.selectedTag = "anything"
        vm.navigationPath.append(TagDestination.allTags)

        vm.lock()

        XCTAssertNil(vm.selectedTag)
        XCTAssertTrue(vm.navigationPath.isEmpty, "Pushed tag destinations clear with the rest of the path")
    }

    func testReloadDiscardingDraftClearsTheSelectedTag() async throws {
        let vm = try makeViewModel(
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference,
                    rootGroup: KPGroup(name: "Reloaded Root", entries: [KPEntry(title: "Reloaded Entry")]),
                    meta: KPMeta(),
                    formatVersion: .kdbx4(minor: 0),
                    sessionKey: SymmetricKey(size: .bits256),
                    openTimeSHA512: Data("reloaded-hash".utf8),
                    binaryPool: BinaryPool(rawFields: [])
                )
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.selectedTag = "anything"
        vm.navigationPath.append(TagDestination.entries(tag: "anything"))

        try await vm.reloadDiscardingDraft()

        XCTAssertNil(vm.selectedTag)
        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    // MARK: - Tag inheritance (group tags)
    //
    // These scenarios build KPGroup trees directly and inject them through the
    // reload seam (`makeInjectedViewModel`) rather than going through
    // `updateGroup`, so inheritance is tested against an exact tree shape
    // instead of whatever the editor happens to produce.

    func testGroupTagAppliesToEntriesInsideTheGroup() async throws {
        let alpha = KPEntry(title: "Alpha")
        let outside = KPEntry(title: "Outside")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Projects", tags: ["team"], hasTagsElement: true, entries: [alpha]),
            KPGroup(name: "Plain", entries: [outside]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(vm.entryCount(forTag: "team"), 1)
        XCTAssertEqual(vm.entries(withTag: "team").map(\.id), [alpha.id])
        XCTAssertTrue(
            vm.tagsInDisplayOrder.contains("team"),
            "The slice 02 browser derivations must surface inherited tags with no extra wiring"
        )
        XCTAssertFalse(vm.entries(withTag: "team").map(\.id).contains(outside.id))
    }

    func testNestedGroupsAccumulateAncestorAndOwnTagsOnTheDeepestEntry() async throws {
        let beta = KPEntry(title: "Beta", tags: ["own-tag"], hasTagsElement: true)
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Projects", tags: ["team"], hasTagsElement: true, groups: [
                KPGroup(name: "Client Work", tags: ["billable"], hasTagsElement: true, entries: [beta]),
            ]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        for tag in ["own-tag", "team", "billable"] {
            XCTAssertEqual(vm.entryCount(forTag: tag), 1, "Expected \(tag) to be effective on the nested entry")
            XCTAssertEqual(vm.entries(withTag: tag).map(\.id), [beta.id])
        }
    }

    func testInheritedTagsResolvePerLocationForTheEntryEditor() async throws {
        let beta = KPEntry(title: "Beta", tags: ["own-tag"], hasTagsElement: true)
        let clientWork = KPGroup(name: "Client Work", tags: ["billable"], hasTagsElement: true, entries: [beta])
        let projects = KPGroup(name: "Projects", tags: ["team"], hasTagsElement: true, groups: [clientWork])
        let plain = KPGroup(name: "Plain")
        let root = KPGroup(name: "Root", groups: [projects, plain])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(
            vm.inheritedTags(forGroupID: clientWork.id),
            ["team", "billable"],
            "A new entry here inherits the ancestors' tags root-most first, then the group's own"
        )
        XCTAssertEqual(vm.inheritedTags(forGroupID: projects.id), ["team"])
        XCTAssertEqual(vm.inheritedTags(forGroupID: root.id), [], "An untagged branch grants nothing")
        XCTAssertEqual(vm.inheritedTags(forGroupID: plain.id), [])
        XCTAssertEqual(vm.inheritedTags(forGroupID: UUID()), [], "An unknown group resolves to nothing")

        XCTAssertEqual(
            vm.inheritedTags(forEntryID: beta.id),
            ["team", "billable"],
            "Editing an existing entry resolves the same tags through its parent group"
        )
        XCTAssertFalse(
            vm.inheritedTags(forEntryID: beta.id).contains("own-tag"),
            "The entry's own tags stay in the field, not in the inherited exclusions"
        )
        XCTAssertEqual(vm.inheritedTags(forEntryID: UUID()), [])
    }

    func testDetailTagsSplitTheEntrysOwnTagsFromTheOnesItGetsFromItsGroups() async throws {
        let beta = KPEntry(title: "Beta", tags: ["own-tag"], hasTagsElement: true)
        let untagged = KPEntry(title: "Untagged")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Projects", tags: ["team"], hasTagsElement: true, groups: [
                KPGroup(name: "Client Work", tags: ["billable"], hasTagsElement: true, entries: [beta]),
            ]),
            KPGroup(name: "Plain", entries: [untagged]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        let tags = vm.detailTags(forEntryID: beta.id)
        XCTAssertEqual(tags.own, ["own-tag"], "The entry's own tags come first, in stored order")
        XCTAssertEqual(
            tags.inherited,
            ["team", "billable"],
            "Then the ancestors' tags, root-most first — the tag index's own ordering"
        )
        // The chips the detail screen draws are exactly what the tag browser
        // matched on: neither list may carry a tag the other side lacks.
        for tag in tags.own + tags.inherited {
            XCTAssertEqual(
                vm.entries(withTag: tag).map(\.id),
                [beta.id],
                "Browsing to \(tag) must reach the entry whose detail screen shows it"
            )
        }

        let untaggedTags = vm.detailTags(forEntryID: untagged.id)
        XCTAssertEqual(untaggedTags.own, [])
        XCTAssertEqual(untaggedTags.inherited, [], "An untagged branch grants nothing")

        let unknownTags = vm.detailTags(forEntryID: UUID())
        XCTAssertEqual(unknownTags.own, [])
        XCTAssertEqual(unknownTags.inherited, [])
    }

    func testDetailTagsShowATagSharedWithAnAncestorGroupOnceAsTheEntrysOwn() async throws {
        let entry = KPEntry(title: "Doubly Tagged", tags: ["shared"], hasTagsElement: true)
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Shared Group", tags: ["shared", "team"], hasTagsElement: true, entries: [entry]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        let tags = vm.detailTags(forEntryID: entry.id)
        XCTAssertEqual(tags.own, ["shared"])
        XCTAssertEqual(
            tags.inherited,
            ["team"],
            "A tag on both the entry and its group draws one chip, the entry's own"
        )
    }

    func testRootGroupTagReachesAllLiveEntries() async throws {
        let atRoot = KPEntry(title: "At Root")
        let nested = KPEntry(title: "Nested")
        let root = KPGroup(
            name: "Root",
            tags: ["global"],
            hasTagsElement: true,
            entries: [atRoot],
            groups: [KPGroup(name: "Child", entries: [nested])]
        )
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(vm.entryCount(forTag: "global"), 2)
        XCTAssertEqual(Set(vm.entries(withTag: "global").map(\.id)), [atRoot.id, nested.id])
    }

    func testGroupAndEntrySharingATagCountTheEntryOnce() async throws {
        let entry = KPEntry(title: "Doubly Tagged", tags: ["shared"], hasTagsElement: true)
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Shared Group", tags: ["shared"], hasTagsElement: true, entries: [entry]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(
            vm.entryCount(forTag: "shared"),
            1,
            "Effective tags are exact-string deduped, so own + inherited copies of one tag count once"
        )
        XCTAssertEqual(vm.entries(withTag: "shared").map(\.id), [entry.id])
    }

    func testCaseVariantGroupAndEntryTagsStayDistinct() async throws {
        let entry = KPEntry(title: "Cased", tags: ["work"], hasTagsElement: true)
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Work Group", tags: ["Work"], hasTagsElement: true, entries: [entry]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertEqual(Set(vm.allTags), ["work", "Work"], "Tag identity is exact-string; case variants stay apart")
        XCTAssertEqual(vm.entryCount(forTag: "work"), 1)
        XCTAssertEqual(vm.entryCount(forTag: "Work"), 1)
    }

    func testRecycledEntriesUnderATaggedGroupStayExcluded() async throws {
        let binID = UUID()
        let doomed = KPEntry(title: "Doomed", tags: ["doomed-own"], hasTagsElement: true)
        let survivor = KPEntry(title: "Survivor")
        let root = KPGroup(
            name: "Root",
            groups: [
                KPGroup(name: "Live", entries: [survivor]),
                KPGroup(id: binID, name: "Recycle Bin", groups: [
                    KPGroup(name: "Old Projects", tags: ["archived"], hasTagsElement: true, entries: [doomed]),
                ]),
            ],
            recycleBinUUID: binID
        )
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertTrue(vm.isEntryInRecycleBin(entryID: doomed.id))
        XCTAssertFalse(vm.allTags.contains("archived"), "A tagged group inside the bin must not surface its tag")
        XCTAssertFalse(vm.allTags.contains("doomed-own"))
        XCTAssertEqual(vm.entryCount(forTag: "archived"), 0)
        XCTAssertTrue(vm.entries(withTag: "archived").isEmpty)

        vm.searchText = "archived"
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testRecycleBinGroupsOwnTagsNeverSurface() async throws {
        let binID = UUID()
        let recycled = KPEntry(title: "Recycled")
        let live = KPEntry(title: "Live Entry")
        let root = KPGroup(
            name: "Root",
            entries: [live],
            groups: [
                KPGroup(id: binID, name: "Recycle Bin", tags: ["bin-tag"], hasTagsElement: true, entries: [recycled]),
            ],
            recycleBinUUID: binID
        )
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertFalse(
            vm.allTags.contains("bin-tag"),
            "The bin group's own tags accumulate only into its excluded subtree and must never reach the index"
        )
        XCTAssertEqual(vm.entryCount(forTag: "bin-tag"), 0)

        vm.searchText = "bin-tag"
        XCTAssertTrue(vm.searchResults.isEmpty, "The live entry must not inherit the bin group's tag either")
    }

    func testSearchFindsAnEntryViaAncestorGroupTag() async throws {
        let tagged = KPEntry(title: "Bank")
        let untagged = KPEntry(title: "Untagged")
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Trips", tags: ["Réunion Trip"], hasTagsElement: true, entries: [tagged]),
            KPGroup(name: "Plain", entries: [untagged]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        // Folded like every other searchable field: case- and
        // diacritic-insensitive, full text and partial.
        for query in ["Réunion Trip", "reunion trip", "RÉUN", "trip"] {
            vm.searchText = query
            XCTAssertEqual(
                vm.searchResults.map(\.title),
                ["Bank"],
                "Expected the ancestor group's tag to match query \"\(query)\""
            )
        }
    }

    func testHistoryOnlyTagUnderATaggedGroupStillFindsNothing() async throws {
        let snapshot = KPEntry(title: "Historic", tags: ["retired"], hasTagsElement: true)
        let live = KPEntry(title: "Historic", tags: ["current"], hasTagsElement: true, history: [snapshot])
        let root = KPGroup(name: "Root", groups: [
            KPGroup(name: "Projects", tags: ["team"], hasTagsElement: true, entries: [live]),
        ])
        let vm = try await makeInjectedViewModel(rootGroup: root)

        XCTAssertFalse(vm.allTags.contains("retired"), "History snapshots stay out of the index entirely")
        vm.searchText = "retired"
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "team"
        XCTAssertEqual(vm.searchResults.map(\.id), [live.id])
        vm.searchText = "current"
        XCTAssertEqual(vm.searchResults.map(\.id), [live.id])
    }

    func testWhitespaceOnlySearchQueryIsTreatedAsEmpty() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        XCTAssertTrue(vm.isSearchQueryEmpty)

        vm.searchText = "   \n"
        XCTAssertTrue(vm.isSearchQueryEmpty)
        XCTAssertTrue(vm.searchResults.isEmpty)

        vm.searchText = "a"
        XCTAssertFalse(vm.isSearchQueryEmpty)
    }

    func testLockClearsSensitiveAndNavigationState() async throws {
        let vm = try makeViewModel()
        await vm.unlock(password: fixturePassword)

        vm.searchText = "query"
        vm.navigationPath.append("pushed")

        vm.lock()

        XCTAssertState(vm.state, is: .locked)
        XCTAssertNil(vm.rootGroup)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertTrue(vm.navigationPath.isEmpty)
    }

    func testSaveOnCleanDraftIsNoOp() async throws {
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        let originalHash = vm.openTimeSHA512
        vm.draft = try makeCleanDraft(from: vm)

        try await vm.save()

        XCTAssertFalse(localSaverCalls.didCall)
        XCTAssertEqual(vm.openTimeSHA512, originalHash)
        XCTAssertNotNil(vm.draft)
    }

    func testSaveOnDirtyDraftReplacesRootClearsDraft() async throws {
        let savedHash = Data("saved-hash".utf8)
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: savedHash)
            }
        )

        await vm.unlock(password: fixturePassword)
        let dirtyDraft = try makeDirtyDraft(from: vm, entryTitle: "Saved Entry")
        let expectedTitles = dirtyDraft.rootGroup.allEntries.map(\.title).sorted()
        vm.draft = dirtyDraft

        try await vm.save()

        XCTAssertEqual(vm.rootGroup?.allEntries.map(\.title).sorted(), expectedTitles)
        XCTAssertNil(vm.draft)
        XCTAssertEqual(vm.openTimeSHA512, savedHash)
    }

    func testSaveRepopulatesCredentialStoreAfterSuccessfulSave() async throws {
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("saved-hash".utf8))
            }
        )
        let refreshExpectation = expectation(description: "Credential store repopulated after save")
        var populateCallCount = 0
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            populateCallCount += 1
            if populateCallCount == 2 {
                refreshExpectation.fulfill()
            }
        }

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Saved Entry")

        try await vm.save()

        await fulfillment(of: [refreshExpectation], timeout: 30)
        XCTAssertEqual(populateCallCount, 2)
    }

    func testSaveOnConflictSetsSaveConflictDoesNotClearDraft() async throws {
        let remoteData = Data("remote".utf8)
        let remoteHash = KDBXCrypto.sha512(remoteData)
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .conflict(remoteSHA512: remoteHash, remoteData: remoteData)
            }
        )

        await vm.unlock(password: fixturePassword)
        let dirtyDraft = try makeDirtyDraft(from: vm, entryTitle: "Conflicted Entry")
        vm.draft = dirtyDraft

        try await vm.save()

        XCTAssertEqual(
            vm.saveConflict,
            SaveConflict(remoteSHA512: remoteHash, remoteData: remoteData)
        )
        XCTAssertNotNil(vm.draft)
    }

    func testSaveWhenReadOnlyThrowsDatabaseIsReadOnlyDoesNotEncrypt() async throws {
        var reference = try makeReference()
        reference.isReadOnly = true

        let localSaverCalls = CallTracker()
        let vm = DatabaseViewModel(
            databaseReference: reference,
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Read Only Entry")

        do {
            try await vm.save()
            XCTFail("Expected save to throw when the database is read-only.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testSaveLegacyKDBX31ThrowsDatabaseIsReadOnlyBeforeSaveOperation() async throws {
        let localSaverCalls = CallTracker()
        let reference = try TestDatabaseSupport.makeReference(for: legacyFixtureURL())
        let vm = try makeViewModel(
            reference: reference,
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Legacy Edit")

        do {
            try await vm.save()
            XCTFail("Expected legacy KDBX3 save to stay read-only.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testSaveWriteScopeMissingOnCloudDatabaseThrowsTypedError() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let fixtureData = try Data(contentsOf: fixtureURL())
        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: fixtureData,
                    status: .current
                )
            },
            cloudSaveOperation: { _, _, _, _, _, _ in
                throw CloudProviderError.writeScopeRequired
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Cloud Save Entry")

        do {
            try await vm.save()
            XCTFail("Expected cloud save to surface a typed write-scope error.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .writeScopeRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNotNil(vm.draft)
    }

    func testSaveAsConflictCopyLocalWritesSiblingFileClearsConflict() async throws {
        let conflictBytes = Data("conflict-copy".utf8)
        let fixedDate = Date(timeIntervalSince1970: 1_775_603_700)
        let recorder = ConflictCopyRecorder()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .conflict(remoteSHA512: Data("remote".utf8), remoteData: Data("remote-data".utf8))
            },
            conflictCopyEncryptionOperation: { _, _, _ in
                conflictBytes
            },
            localConflictCopyOperation: { _, filename, bytes in
                await recorder.record(filename: filename, bytes: bytes)
            },
            conflictCopyDateProvider: { fixedDate }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Conflict Copy Entry")
        try await vm.save()

        try await vm.saveAsConflictCopy()

        let recordedCall = await recorder.firstCall()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(
            call.filename,
            expectedConflictFilename(originalFilename: "test.kdbx", date: fixedDate)
        )
        XCTAssertEqual(call.bytes, conflictBytes)
        XCTAssertNil(vm.draft)
        XCTAssertNil(vm.saveConflict)
    }

    func testSaveAsConflictCopyCloudUploadsSuffixedFileClearsConflict() async throws {
        let conflictBytes = Data("cloud-conflict-copy".utf8)
        let fixedDate = Date(timeIntervalSince1970: 1_775_603_700)
        let recorder = ConflictCopyRecorder()
        let reference = makeCloudReference(remoteRev: "rev-A")
        let fixtureData = try Data(contentsOf: fixtureURL())
        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: fixtureData,
                    status: .current
                )
            },
            cloudSaveOperation: { _, _, _, _, _, _ in
                .conflict(remoteSHA512: Data("remote".utf8), remoteData: Data("remote-data".utf8))
            },
            conflictCopyEncryptionOperation: { _, _, _ in
                conflictBytes
            },
            cloudConflictCopyOperation: { _, fileID, bytes in
                await recorder.record(filename: fileID, bytes: bytes)
            },
            conflictCopyDateProvider: { fixedDate }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Cloud Conflict Copy Entry")
        try await vm.save()

        try await vm.saveAsConflictCopy()

        let recordedCall = await recorder.firstCall()
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(
            call.filename,
            "/Vaults/\(expectedConflictFilename(originalFilename: "vault.kdbx", date: fixedDate))"
        )
        XCTAssertEqual(call.bytes, conflictBytes)
        XCTAssertNil(vm.draft)
        XCTAssertNil(vm.saveConflict)
    }

    // MARK: - Conflict copies are create-only (M8)

    func testConflictCopyToCloudUsesCreateOnlyUploadNeverOverwrite() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let provider = ConflictCopyCloudProvider()

        try await DatabaseViewModel.writeConflictCopyToCloud(
            reference: reference,
            fileID: "/Vaults/vault (conflict 2026-04-07 161500).kdbx",
            bytes: Data("conflict-copy".utf8),
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(provider.createdPaths, ["/Vaults/vault (conflict 2026-04-07 161500).kdbx"])
        XCTAssertEqual(
            provider.uploadCallCount,
            0,
            "`upload` overwrites on every provider, which is what destroyed earlier conflict copies."
        )
    }

    func testConflictCopyToCloudNumbersTheNameWhenItAlreadyExists() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let provider = ConflictCopyCloudProvider()
        // Two resolutions inside the same second: the first copy already
        // occupies the name, so create-only rejects it.
        provider.pathsRejectedAsExisting = [
            "/Vaults/vault (conflict 2026-04-07 161500).kdbx",
            "/Vaults/vault (conflict 2026-04-07 161500) 2.kdbx",
        ]

        try await DatabaseViewModel.writeConflictCopyToCloud(
            reference: reference,
            fileID: "/Vaults/vault (conflict 2026-04-07 161500).kdbx",
            bytes: Data("conflict-copy".utf8),
            providerResolver: { _ in provider }
        )

        XCTAssertEqual(
            provider.createdPaths,
            [
                "/Vaults/vault (conflict 2026-04-07 161500).kdbx",
                "/Vaults/vault (conflict 2026-04-07 161500) 2.kdbx",
                "/Vaults/vault (conflict 2026-04-07 161500) 3.kdbx",
            ]
        )
        XCTAssertEqual(provider.uploadCallCount, 0)
    }

    func testConflictCopyToCloudSurfacesNonConflictFailuresImmediately() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let provider = ConflictCopyCloudProvider()
        provider.createFailure = .insufficientSpace

        do {
            try await DatabaseViewModel.writeConflictCopyToCloud(
                reference: reference,
                fileID: "/Vaults/vault (conflict 2026-04-07 161500).kdbx",
                bytes: Data("conflict-copy".utf8),
                providerResolver: { _ in provider }
            )
            XCTFail("Expected the provider error to surface.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .insufficientSpace)
        }

        XCTAssertEqual(provider.createdPaths.count, 1, "A real failure must not be retried under new names.")
    }

    func testConflictCopyFilenameCarriesSecondsSoNearbyResolutionsDiffer() throws {
        let vm = try makeViewModel(conflictCopyDateProvider: { Date(timeIntervalSince1970: 1_775_603_700) })
        let other = try makeViewModel(conflictCopyDateProvider: { Date(timeIntervalSince1970: 1_775_603_730) })

        let first = vm.conflictCopyFilename(for: "test.kdbx")
        let second = other.conflictCopyFilename(for: "test.kdbx")

        XCTAssertNotEqual(
            first,
            second,
            "Thirty seconds apart collapsed to one name under minute granularity."
        )
        XCTAssertTrue(first.hasSuffix(".kdbx"))
    }

    // MARK: - Save serialization and lock safety (M9, L2)

    func testSecondSaveWhileTheFirstIsInFlightIsIgnored() async throws {
        let gate = SaveGate()
        let saveCalls = SaveCallCounter()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, openTimeSHA512, _ in
                // Only the first save parks on the gate. A reentrant one must
                // never get here at all, and if it does the test has to fail
                // rather than deadlock waiting for a gate nobody will open.
                if await saveCalls.increment() == 1 {
                    await gate.signalStarted()
                    await gate.waitUntilOpen()
                }
                return .saved(newSHA512: openTimeSHA512)
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Reentrant Save Entry")

        let firstSave = Task { try await vm.save() }
        await gate.waitUntilStarted()
        XCTAssertTrue(vm.isSaving)

        // The macOS ⌘S path can reach this while the first save is still out,
        // because `isDirty` stays true for the whole flight.
        try await vm.save()

        let callsDuringFlight = await saveCalls.value
        XCTAssertEqual(callsDuringFlight, 1, "The reentrant save must not start a second upload.")
        XCTAssertNotNil(vm.draft)

        await gate.open()
        try await firstSave.value

        let callsAfterCompletion = await saveCalls.value
        XCTAssertEqual(callsAfterCompletion, 1)
        XCTAssertFalse(vm.isSaving)
        XCTAssertNil(vm.draft)
    }

    func testSaveCompletingAfterLockDoesNotResurrectUnlockedState() async throws {
        let gate = SaveGate()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, openTimeSHA512, _ in
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return .saved(newSHA512: openTimeSHA512)
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Save After Lock Entry")

        let save = Task { try await vm.save() }
        await gate.waitUntilStarted()

        vm.lock()
        await gate.open()
        try await save.value

        XCTAssertNil(vm.rootGroup, "A completed save must not repopulate a locked session.")
        XCTAssertNil(vm.draft)
        XCTAssertNil(vm.saveConflict)
        guard case .locked = vm.state else {
            XCTFail("Expected the session to stay locked.")
            return
        }
    }

    func testConflictingSaveCompletingAfterLockDoesNotRaiseAConflictPrompt() async throws {
        let gate = SaveGate()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return .conflict(remoteSHA512: Data("remote".utf8), remoteData: Data("remote-data".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Conflict After Lock Entry")

        let save = Task { try await vm.save() }
        await gate.waitUntilStarted()

        vm.lock()
        await gate.open()
        try await save.value

        XCTAssertNil(vm.saveConflict, "A conflict sheet must not appear behind the lock screen.")
    }

    func testReloadDiscardingDraftReplacesRootWithFreshTreeFromDiskClearsDraft() async throws {
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .conflict(remoteSHA512: Data("remote".utf8), remoteData: Data("remote-data".utf8))
            },
            reloadOperation: { reference, _ in
                var updatedReference = reference
                updatedReference.nickname = "Reloaded"
                return DatabaseViewModel.ReloadedDatabase(
                    reference: updatedReference,
                    rootGroup: KPGroup(name: "Reloaded Root", entries: [KPEntry(title: "Reloaded Entry")]),
                    meta: KPMeta(),
                    formatVersion: .kdbx4(minor: 0),
                    sessionKey: SymmetricKey(size: .bits256),
                    openTimeSHA512: Data("reloaded-hash".utf8),
                    binaryPool: BinaryPool(rawFields: [])
                )
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved")
        try await vm.save()
        vm.searchText = "discord"
        vm.navigationPath.append("detail")

        try await vm.reloadDiscardingDraft()

        XCTAssertEqual(vm.rootGroup?.name, "Reloaded Root")
        XCTAssertEqual(vm.rootGroup?.allEntries.map(\.title), ["Reloaded Entry"])
        XCTAssertEqual(vm.databaseReference.nickname, "Reloaded")
        XCTAssertEqual(vm.openTimeSHA512, Data("reloaded-hash".utf8))
        XCTAssertNil(vm.draft)
        XCTAssertNil(vm.saveConflict)
        XCTAssertTrue(vm.navigationPath.isEmpty)
        XCTAssertEqual(vm.searchText, "")
        XCTAssertState(vm.state, is: .unlocked)
    }

    func testLockWhileDirtyRequiresExplicitConfirmation() async throws {
        let vm = try makeViewModel()

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Entry")

        vm.lockRequest(manuallyTriggered: true)

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.draft)
        XCTAssertEqual(vm.pendingLockRequest, .init(manuallyTriggered: true))
        XCTAssertFalse(vm.pendingLockRequest?.requiresAuthenticationToContinueEditing == true)

        vm.lockRequest(force: true)

        XCTAssertState(vm.state, is: .locked)
        XCTAssertNil(vm.draft)
        XCTAssertNil(vm.pendingLockRequest)
    }

    func testManualKeepEditingPreservesDirtyDraftWithoutAuthentication() async throws {
        let vm = try makeViewModel()

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Entry")
        vm.lockRequest(manuallyTriggered: true)

        await vm.continueEditingAfterLockRequest()

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.draft)
        XCTAssertNil(vm.pendingLockRequest)
    }

    func testBackgroundTimeoutWhileDirtyRequiresAuthenticatedResume() async throws {
        let savedAutoLockTimeout = SettingsService.autoLockTimeout
        let savedLockOnBackground = SettingsService.lockOnBackground
        SettingsService.autoLockTimeout = .thirtySeconds
        SettingsService.lockOnBackground = false
        defer {
            SettingsService.autoLockTimeout = savedAutoLockTimeout
            SettingsService.lockOnBackground = savedLockOnBackground
        }

        let clock = MutableNowProvider(now: Date(timeIntervalSince1970: 1_000))
        let vm = try makeViewModel(nowProvider: { clock.now })

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Background Entry")

        vm.handleSceneDidEnterBackground()
        clock.advance(by: 31)
        vm.handleSceneDidBecomeActive()

        XCTAssertState(vm.state, is: .unlocked)
        XCTAssertNotNil(vm.draft)
        XCTAssertEqual(vm.pendingLockRequest, .init(manuallyTriggered: false))
        XCTAssertTrue(vm.pendingLockRequest?.requiresAuthenticationToContinueEditing == true)
    }

    func testSetReadOnlyUpdatesInMemoryReferenceAndStore() throws {
        let reference = try makeReference()
        DatabaseListStore.update(reference)
        let vm = DatabaseViewModel(databaseReference: reference)
        XCTAssertFalse(vm.isReadOnly)

        vm.setReadOnly(true)

        XCTAssertTrue(vm.isReadOnly)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertTrue(stored.isReadOnly)

        vm.setReadOnly(false)

        XCTAssertFalse(vm.isReadOnly)
        let storedAfterOff = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertFalse(storedAfterOff.isReadOnly)
    }

    // MARK: - Change master key (#59)

    func testChangeMasterKeyToNewPasswordUpdatesSessionKeyAndHash() async throws {
        let savedHash = Data("rekeyed-hash".utf8)
        let capturedKeys = RekeyedKeyCapture()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, compositeKey, _, newCompositeKey in
                capturedKeys.record(oldKey: compositeKey, newKey: newCompositeKey)
                return .saved(newSHA512: savedHash)
            }
        )

        await vm.unlock(password: fixturePassword)
        let oldCompositeKey = try XCTUnwrap(vm.compositeKey)

        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        let expectedNewKey = try KDBXCrypto.compositeKey(password: "rotated-master", keyFileData: nil)
        XCTAssertEqual(capturedKeys.oldKey, oldCompositeKey)
        XCTAssertEqual(capturedKeys.newKey, expectedNewKey)
        XCTAssertEqual(vm.compositeKey, expectedNewKey)
        XCTAssertEqual(vm.openTimeSHA512, savedHash)
        XCTAssertNil(vm.draft)
        XCTAssertFalse(vm.isSaving)
        XCTAssertState(vm.state, is: .unlocked)
    }

    func testChangeMasterKeyAddingKeyFilePersistsAssociationOnReference() async throws {
        let keyFileData = Data("rekey key file bytes".utf8)
        let bookmarkData = Data("rekey-bookmark".utf8)
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("rekeyed-hash".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)

        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: keyFileData,
            newKeyFileBookmarkData: bookmarkData,
            newKeyFileFilename: "vault.key"
        )

        XCTAssertEqual(
            vm.compositeKey,
            try KDBXCrypto.compositeKey(password: "rotated-master", keyFileData: keyFileData)
        )
        XCTAssertEqual(vm.databaseReference.keyFileBookmarkData, bookmarkData)
        XCTAssertEqual(vm.databaseReference.keyFileFilename, "vault.key")
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == vm.databaseReference.id }))
        XCTAssertEqual(stored.keyFileBookmarkData, bookmarkData)
        XCTAssertEqual(stored.keyFileFilename, "vault.key")
    }

    func testChangeMasterKeyRemovingKeyFileClearsAssociationOnReference() async throws {
        var reference = try makeReference()
        reference.keyFileBookmarkData = Data("stale-bookmark".utf8)
        reference.keyFileFilename = "old.key"
        DatabaseListStore.update(reference)
        let vm = try makeViewModel(
            reference: reference,
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("rekeyed-hash".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)

        try await vm.changeMasterKey(
            newPassword: "password-only",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        XCTAssertNil(vm.databaseReference.keyFileBookmarkData)
        XCTAssertNil(vm.databaseReference.keyFileFilename)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        XCTAssertNil(stored.keyFileBookmarkData)
        XCTAssertNil(stored.keyFileFilename)
    }

    func testChangeMasterKeyCloudRoutesNewKeyThroughCloudSaveOperation() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let fixtureData = try Data(contentsOf: fixtureURL())
        let capturedKeys = RekeyedKeyCapture()
        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: fixtureData,
                    status: .current
                )
            },
            cloudSaveOperation: { _, _, compositeKey, _, expectedRev, newCompositeKey in
                capturedKeys.record(oldKey: compositeKey, newKey: newCompositeKey, expectedRev: expectedRev)
                return .saved(newSHA512: Data("cloud-rekeyed-hash".utf8))
            },
            pendingUploadMarkerCheck: { _ in false }
        )

        await vm.unlock(password: fixturePassword)
        let oldCompositeKey = try XCTUnwrap(vm.compositeKey)

        try await vm.changeMasterKey(
            newPassword: "cloud-rotated",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        let expectedNewKey = try KDBXCrypto.compositeKey(password: "cloud-rotated", keyFileData: nil)
        XCTAssertEqual(capturedKeys.oldKey, oldCompositeKey)
        XCTAssertEqual(capturedKeys.newKey, expectedNewKey)
        XCTAssertEqual(capturedKeys.expectedRev, "rev-A")
        XCTAssertEqual(vm.compositeKey, expectedNewKey)
        XCTAssertEqual(vm.openTimeSHA512, Data("cloud-rekeyed-hash".utf8))
    }

    func testChangeMasterKeyWhenReadOnlyThrowsWithoutSaving() async throws {
        var reference = try makeReference()
        reference.isReadOnly = true
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            reference: reference,
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)

        await assertChangeMasterKeyThrows(.databaseIsReadOnly, on: vm, newPassword: "rotated")
        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testChangeMasterKeyOnLegacyKDBX31ThrowsReadOnly() async throws {
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            reference: try TestDatabaseSupport.makeReference(for: legacyFixtureURL()),
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)

        await assertChangeMasterKeyThrows(.databaseIsReadOnly, on: vm, newPassword: "rotated")
        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testChangeMasterKeyWhileLockedThrowsSessionUnavailable() async throws {
        let vm = try makeViewModel()

        await assertChangeMasterKeyThrows(.sessionUnavailable, on: vm, newPassword: "rotated")
    }

    func testChangeMasterKeyWithDirtyDraftThrowsUnsavedChanges() async throws {
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "Unsaved Before Rekey")

        await assertChangeMasterKeyThrows(.unsavedChanges, on: vm, newPassword: "rotated")
        XCTAssertFalse(localSaverCalls.didCall)
        XCTAssertNotNil(vm.draft)
    }

    func testChangeMasterKeyWhileSaveInFlightThrowsSaveInProgress() async throws {
        let gate = SaveGate()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, openTimeSHA512, _ in
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return .saved(newSHA512: openTimeSHA512)
            }
        )

        await vm.unlock(password: fixturePassword)
        vm.draft = try makeDirtyDraft(from: vm, entryTitle: "In Flight Entry")

        let save = Task { try await vm.save() }
        await gate.waitUntilStarted()

        await assertChangeMasterKeyThrows(.saveInProgress, on: vm, newPassword: "rotated")

        await gate.open()
        try await save.value
    }

    func testChangeMasterKeyWithEmptyCredentialsThrowsMissingKeyComponent() async throws {
        let localSaverCalls = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                localSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            }
        )

        await vm.unlock(password: fixturePassword)

        await assertChangeMasterKeyThrows(.missingKeyComponent, on: vm, newPassword: nil)
        await assertChangeMasterKeyThrows(.missingKeyComponent, on: vm, newPassword: "")
        XCTAssertFalse(localSaverCalls.didCall)
    }

    func testChangeMasterKeyCloudWithPendingUploadMarkersThrows() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let fixtureData = try Data(contentsOf: fixtureURL())
        let cloudSaverCalls = CallTracker()
        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: fixtureData,
                    status: .current
                )
            },
            cloudSaveOperation: { _, _, _, _, _, _ in
                cloudSaverCalls.recordCall()
                return .saved(newSHA512: Data("saved".utf8))
            },
            pendingUploadMarkerCheck: { _ in true }
        )

        await vm.unlock(password: fixturePassword)

        await assertChangeMasterKeyThrows(.pendingUploadsExist, on: vm, newPassword: "rotated")
        XCTAssertFalse(cloudSaverCalls.didCall)
    }

    func testChangeMasterKeyConflictThrowsAndLeavesSessionUnchanged() async throws {
        let storedKeyStores = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .conflict(remoteSHA512: Data("remote".utf8), remoteData: Data("remote-data".utf8))
            },
            storedKeyPresenceCheck: { _ in true },
            storedKeyStoreOperation: { _, _ in storedKeyStores.recordCall() }
        )

        await vm.unlock(password: fixturePassword)
        let oldCompositeKey = vm.compositeKey
        let oldHash = vm.openTimeSHA512

        await assertChangeMasterKeyThrows(.conflict, on: vm, newPassword: "rotated")

        XCTAssertEqual(vm.compositeKey, oldCompositeKey)
        XCTAssertEqual(vm.openTimeSHA512, oldHash)
        XCTAssertNil(vm.saveConflict, "A rekey conflict must not enter the conflict-copy machinery.")
        XCTAssertFalse(vm.isSaving)
        XCTAssertFalse(storedKeyStores.didCall)
    }

    func testChangeMasterKeyRefreshesStoredKeyOnlyWhenOneWasStored() async throws {
        let storedKeys = RekeyedKeyCapture()
        let deletions = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("rekeyed-hash".utf8))
            },
            storedKeyPresenceCheck: { _ in true },
            storedKeyStoreOperation: { key, _ in storedKeys.record(oldKey: nil, newKey: key) },
            storedKeyDeleteOperation: { _ in deletions.recordCall() }
        )

        await vm.unlock(password: fixturePassword)
        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        XCTAssertEqual(
            storedKeys.newKey,
            try KDBXCrypto.compositeKey(password: "rotated-master", keyFileData: nil)
        )
        XCTAssertFalse(deletions.didCall)
    }

    func testChangeMasterKeyWithoutStoredKeyDoesNotStoreOne() async throws {
        let storedKeyStores = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("rekeyed-hash".utf8))
            },
            storedKeyPresenceCheck: { _ in false },
            storedKeyStoreOperation: { _, _ in storedKeyStores.recordCall() }
        )

        await vm.unlock(password: fixturePassword)
        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        XCTAssertFalse(storedKeyStores.didCall)
    }

    func testChangeMasterKeyDeletesStoredKeyWhenRefreshFails() async throws {
        let deletions = CallTracker()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, _ in
                .saved(newSHA512: Data("rekeyed-hash".utf8))
            },
            storedKeyPresenceCheck: { _ in true },
            storedKeyStoreOperation: { _, _ in
                throw KeychainService.KeychainError.storeFailed(-1)
            },
            storedKeyDeleteOperation: { _ in deletions.recordCall() }
        )

        await vm.unlock(password: fixturePassword)
        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        XCTAssertTrue(deletions.didCall, "A failed re-store must drop the stale stored key.")
    }

    func testChangeMasterKeyCloudRekeyAppliedRemotelyStillRefreshesStoredKey() async throws {
        let reference = makeCloudReference(remoteRev: "rev-A")
        let fixtureData = try Data(contentsOf: fixtureURL())
        let storedKeys = RekeyedKeyCapture()
        let vm = try makeViewModel(
            reference: reference,
            cloudSyncOperation: { reference, _ in
                CloudSyncResolution(
                    reference: reference,
                    localURL: DatabaseListStore.cacheLocation(for: reference),
                    data: fixtureData,
                    status: .current
                )
            },
            cloudSaveOperation: { _, _, _, _, _, _ in
                throw SaveError.rekeyAppliedRemotely
            },
            pendingUploadMarkerCheck: { _ in false },
            storedKeyPresenceCheck: { _ in true },
            storedKeyStoreOperation: { key, _ in storedKeys.record(oldKey: nil, newKey: key) }
        )

        await vm.unlock(password: fixturePassword)
        let oldCompositeKey = try XCTUnwrap(vm.compositeKey)

        do {
            try await vm.changeMasterKey(
                newPassword: "cloud-rotated",
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("Expected rekeyAppliedRemotely to propagate")
        } catch SaveError.rekeyAppliedRemotely {
            // Expected: the upload landed but the local apply failed.
        }

        XCTAssertEqual(
            storedKeys.newKey,
            try KDBXCrypto.compositeKey(password: "cloud-rotated", keyFileData: nil),
            "Keychain must point at the key the remote now requires"
        )
        XCTAssertEqual(
            vm.compositeKey,
            oldCompositeKey,
            "The session keeps the key matching the still-old local cache"
        )
    }

    func testChangeMasterKeySavesDraftThatGrewDuringRekey() async throws {
        final class Box: @unchecked Sendable {
            var growDraft: (@MainActor () -> Void)?
            var followUpDidRun = false
        }
        let box = Box()
        let vm = try makeViewModel(
            localSaveOperation: { _, _, _, _, newCompositeKey in
                if newCompositeKey != nil {
                    // An edit lands while the rekey save is in flight.
                    await MainActor.run { box.growDraft?() }
                } else {
                    box.followUpDidRun = true
                }
                return .saved(newSHA512: Data("rekeyed-hash".utf8))
            }
        )
        box.growDraft = { [weak vm, weak self] in
            guard let vm, let self else { return }
            vm.draft = try? self.makeDirtyDraft(from: vm, entryTitle: "Mid-Rekey Entry")
        }

        await vm.unlock(password: fixturePassword)
        try await vm.changeMasterKey(
            newPassword: "rotated-master",
            newKeyFileData: nil,
            newKeyFileBookmarkData: nil,
            newKeyFileFilename: nil
        )

        // The flush runs in a follow-up task once `isSaving` clears.
        for _ in 0..<200 where box.followUpDidRun == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(box.followUpDidRun, "An edit applied during the rekey must be saved afterwards")
        XCTAssertNil(vm.draft)
    }

    private func assertChangeMasterKeyThrows(
        _ expected: DatabaseViewModel.RekeyError,
        on viewModel: DatabaseViewModel,
        newPassword: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await viewModel.changeMasterKey(
                newPassword: newPassword,
                newKeyFileData: nil,
                newKeyFileBookmarkData: nil,
                newKeyFileFilename: nil
            )
            XCTFail("Expected changeMasterKey to throw \(expected).", file: file, line: line)
        } catch let error as DatabaseViewModel.RekeyError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeViewModel(
        reference: DatabaseReference? = nil,
        cloudSyncOperation: @escaping DatabaseViewModel.CloudSyncOperation = { reference, progress in
            try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                progress: progress
            )
        },
        localSaveOperation: @escaping DatabaseViewModel.LocalSaveOperation = { draft, reference, compositeKey, openTimeSHA512, newCompositeKey in
            try await LocalDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey
            )
        },
        cloudSaveOperation: @escaping DatabaseViewModel.CloudSaveOperation = { draft, reference, compositeKey, openTimeSHA512, expectedRev, newCompositeKey in
            try await CloudDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                expectedRev: expectedRev,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey
            )
        },
        conflictCopyEncryptionOperation: @escaping DatabaseViewModel.ConflictCopyEncryptionOperation = { draft, compositeKey, sourceData in
            try await Task.detached {
                let parsed = try KDBXParser.parseWithMetaAndHeader(
                    data: sourceData,
                    compositeKey: compositeKey,
                    sessionKey: SymmetricKey(size: .bits256)
                )
                return try KDBXWriter.write(
                    rootGroup: draft.rootGroup,
                    meta: draft.meta,
                    compositeKey: compositeKey,
                    header: parsed.header,
                    sessionKey: draft.writerSessionKey
                )
            }.value
        },
        localConflictCopyOperation: @escaping DatabaseViewModel.LocalConflictCopyOperation = { reference, filename, bytes in
            try await Task.detached {
                let originalURL = DatabaseListStore.resolveDatabaseURL(for: reference) ?? DatabaseListStore.cacheLocation(for: reference)
                let destinationURL = originalURL.deletingLastPathComponent().appendingPathComponent(filename)
                try CoordinatedFileReader.writeData(
                    bytes,
                    to: destinationURL,
                    options: [.atomic, .completeFileProtection]
                )
            }.value
        },
        cloudConflictCopyOperation: @escaping DatabaseViewModel.CloudConflictCopyOperation = { reference, fileID, bytes in
            guard let metadata = reference.cloudSyncMetadata,
                  let provider = CloudProviderRegistry.provider(for: metadata.provider) else {
                throw CloudProviderError.notAuthenticated
            }

            _ = try await provider.upload(
                accountId: metadata.accountId,
                fileId: fileID,
                data: bytes,
                expectedRev: nil,
                progress: { _ in }
            )
        },
        reloadOperation: @escaping DatabaseViewModel.ReloadOperation = { reference, compositeKey in
            let data: Data
            let updatedReference: DatabaseReference

            if reference.isCloudBacked {
                let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference)
                data = resolution.data
                updatedReference = resolution.reference
            } else {
                guard let url = DatabaseListStore.resolveDatabaseURL(for: reference) else {
                    throw SaveError.databaseLocationUnavailable
                }
                data = try Data(contentsOf: url)
                updatedReference = reference
            }

            let sessionKey = SymmetricKey(size: .bits256)
            let parsed = try await Task.detached {
                try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey
                )
            }.value

            return DatabaseViewModel.ReloadedDatabase(
                reference: updatedReference,
                rootGroup: parsed.rootGroup,
                meta: parsed.meta,
                formatVersion: parsed.header.formatVersion,
                sessionKey: sessionKey,
                openTimeSHA512: KDBXCrypto.sha512(data),
                binaryPool: BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
            )
        },
        biometricCompositeKeyOperation: @escaping DatabaseViewModel.BiometricCompositeKeyOperation = { reference, reason in
            let context = try await BiometricService.authenticate(reason: reason)
            return try DatabaseViewModel.retrieveStoredCompositeKey(for: reference, context: context)
        },
        pendingUploadMarkerCheck: @escaping DatabaseViewModel.PendingUploadMarkerCheck = { reference in
            PendingUploadQueue.listMarkers(for: reference.id).isEmpty == false
        },
        storedKeyPresenceCheck: @escaping DatabaseViewModel.StoredKeyPresenceCheck = { reference in
            KeychainService.hasStoredKey(for: reference.id, legacyFilename: reference.legacyKeychainFilename)
        },
        storedKeyStoreOperation: @escaping DatabaseViewModel.StoredKeyStoreOperation = { compositeKey, reference in
            try KeychainService.storeCompositeKey(compositeKey, for: reference.id)
        },
        storedKeyDeleteOperation: @escaping DatabaseViewModel.StoredKeyDeleteOperation = { reference in
            KeychainService.deleteCompositeKey(for: reference.id)
        },
        conflictCopyDateProvider: @escaping @Sendable () -> Date = { .now },
        nowProvider: @escaping @Sendable () -> Date = { .now }
    ) throws -> DatabaseViewModel {
        let resolvedReference = if let reference {
            reference
        } else {
            try makeReference()
        }

        return DatabaseViewModel(
            databaseReference: resolvedReference,
            cloudSyncOperation: cloudSyncOperation,
            localSaveOperation: localSaveOperation,
            cloudSaveOperation: cloudSaveOperation,
            conflictCopyEncryptionOperation: conflictCopyEncryptionOperation,
            localConflictCopyOperation: localConflictCopyOperation,
            cloudConflictCopyOperation: cloudConflictCopyOperation,
            reloadOperation: reloadOperation,
            biometricCompositeKeyOperation: biometricCompositeKeyOperation,
            pendingUploadMarkerCheck: pendingUploadMarkerCheck,
            storedKeyPresenceCheck: storedKeyPresenceCheck,
            storedKeyStoreOperation: storedKeyStoreOperation,
            storedKeyDeleteOperation: storedKeyDeleteOperation,
            conflictCopyDateProvider: conflictCopyDateProvider,
            nowProvider: nowProvider
        )
    }

    private func makeCloudReference(remoteRev: String? = nil) -> DatabaseReference {
        DatabaseReference(
            id: UUID(),
            nickname: nil,
            filename: "vault.kdbx",
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: false,
            lastOpenedAt: nil,
            addedAt: Date(timeIntervalSince1970: 50),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: .cloud(
                CloudSyncMetadata(
                    provider: CloudProviderKind.dropbox.rawValue,
                    accountId: "acct-1",
                    fileId: "/Vaults/vault.kdbx",
                    displayPath: "/Vaults/vault.kdbx",
                    remoteContentHash: nil,
                    remoteModifiedAt: nil,
                    remoteRev: remoteRev,
                    lastSyncedAt: nil,
                    lastSyncError: nil
                )
            )
        )
    }

    private func makeReference(autoFillEnabled: Bool = true) throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(for: fixtureURL(), autoFillEnabled: autoFillEnabled)
    }

    /// A freshly created, already unlocked database — the cleanest route to a
    /// view model whose entire content the test controls.
    private func makeCreatedViewModel(displayName: String) async throws -> DatabaseViewModel {
        let created = try await DatabaseCreationService.create(
            request: DatabaseCreationRequest(
                displayName: displayName,
                destination: .appOnlyAcknowledged,
                password: "\(displayName) password"
            )
        )
        return DatabaseViewModel(createdDatabase: created)
    }

    /// An unlocked view model over an arbitrary in-memory tree, injected
    /// through the reload seam. This is the only way to put group tags in
    /// front of the view model: they are read-only (parsed from KDBX 4.1
    /// files), so neither `DatabaseCreationService` nor any KeeForge edit can
    /// author one.
    private func makeInjectedViewModel(rootGroup: KPGroup) async throws -> DatabaseViewModel {
        let vm = try makeViewModel(
            reloadOperation: { reference, _ in
                DatabaseViewModel.ReloadedDatabase(
                    reference: reference,
                    rootGroup: rootGroup,
                    meta: KPMeta(
                        recycleBinUUID: rootGroup.recycleBinUUID,
                        hasRecycleBinUUIDElement: rootGroup.recycleBinUUID != nil
                    ),
                    formatVersion: .kdbx4(minor: 1),
                    sessionKey: SymmetricKey(size: .bits256),
                    openTimeSHA512: Data("injected-tree-hash".utf8),
                    binaryPool: BinaryPool(rawFields: [])
                )
            }
        )
        await vm.unlock(password: fixturePassword)
        try await vm.reloadDiscardingDraft()
        return vm
    }

    /// Unlocks the view model and waits for the unlock-triggered credential
    /// store populate to settle, so callers can install their own observers
    /// (including `XCTFail`-ing ones) without catching the initial refresh.
    private func unlockAwaitingInitialPopulate(_ viewModel: DatabaseViewModel) async {
        let initialPopulateExpectation = expectation(description: "Initial credential store populate after unlock")
        var didObserveInitialPopulate = false
        CredentialIdentityStoreManager.populateObserver = { _, _ in
            guard didObserveInitialPopulate == false else { return }
            didObserveInitialPopulate = true
            initialPopulateExpectation.fulfill()
        }

        await viewModel.unlock(password: fixturePassword)

        await fulfillment(of: [initialPopulateExpectation], timeout: 30)
        CredentialIdentityStoreManager.populateObserver = nil
    }

    private func makeCleanDraft(from viewModel: DatabaseViewModel) throws -> DatabaseDraft {
        guard let rootGroup = viewModel.rootGroup else {
            throw TestError.missingRootGroup
        }
        guard let sessionKey = viewModel.sessionKey else {
            throw TestError.missingSessionKey
        }

        return DatabaseDraft(
            rootGroup: rootGroup,
            meta: KPMeta(
                recycleBinUUID: rootGroup.recycleBinUUID,
                hasRecycleBinUUIDElement: rootGroup.recycleBinUUID != nil
            ),
            sessionKey: sessionKey
        )
    }

    private func makeDirtyDraft(
        from viewModel: DatabaseViewModel,
        entryTitle: String
    ) throws -> DatabaseDraft {
        let cleanDraft = try makeCleanDraft(from: viewModel)
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: cleanDraft.rootGroup)
        return try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: entryTitle,
                    password: "secret-\(entryTitle)"
                )
            )
        )
    }

    private func fixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: DatabaseViewModelTests.self))
    }

    private func legacyFixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test-v3-backup", bundle: Bundle(for: DatabaseViewModelTests.self))
    }

    private func passkeyFields() -> [String: String] {
        [
            PasskeyCredential.credentialIDKey: "dGVzdC1jcmVkZW50aWFsLWlk",
            PasskeyCredential.relyingPartyKey: "example.com",
            PasskeyCredential.usernameKey: "alice@example.com",
            PasskeyCredential.userHandleKey: "dXNlci1oYW5kbGU",
        ]
    }

    private func mixedCasePrefix(from source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(4))
        guard !prefix.isEmpty else { return source }
        return prefix.uppercased()
    }

    private func expectedConflictFilename(originalFilename: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // Seconds, matching `DatabaseViewModel.conflictCopyFilename`: minute
        // granularity let two resolutions moments apart collide on one name.
        formatter.dateFormat = "yyyy-MM-dd HHmmss"

        let stem = (originalFilename as NSString).deletingPathExtension
        let ext = (originalFilename as NSString).pathExtension
        let suffix = " (conflict \(formatter.string(from: date)))"
        if ext.isEmpty {
            return stem + suffix
        }
        return "\(stem)\(suffix).\(ext)"
    }

    private func XCTAssertState(_ state: DatabaseViewModel.State, is expected: ExpectedState, file: StaticString = #filePath, line: UInt = #line) {
        switch (state, expected) {
        case (.locked, .locked), (.unlocking, .unlocking), (.unlocked, .unlocked):
            return
        case (.error, .error):
            return
        default:
            XCTFail("Unexpected state: \(state)", file: file, line: line)
        }
    }

    private enum ExpectedState {
        case locked
        case unlocking
        case unlocked
        case error
    }

    private enum TestError: Error {
        case missingRootGroup
        case missingSessionKey
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isPaused = false

    func pause(started: XCTestExpectation) async {
        isPaused = true
        started.fulfill()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async {
        while isPaused == false {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

/// Parks the first save-operation call until the test releases it, so an edit
/// can land while that save is provably in flight. Later calls pass through.
private actor InFlightSaveGate {
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func parkFirstCall() async {
        guard hasStarted == false else { return }
        hasStarted = true
        startWaiter?.resume()
        startWaiter = nil
        guard isReleased == false else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func firstCallStarted() async {
        guard hasStarted == false else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func releaseFirstCall() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SavedDraftRecorder {
    private(set) var editCounts: [Int] = []

    func record(editCount: Int) {
        editCounts.append(editCount)
    }
}

private final class RekeyedKeyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOldKey: Data?
    private var storedNewKey: Data?
    private var storedExpectedRev: String?

    func record(oldKey: Data?, newKey: Data?, expectedRev: String? = nil) {
        lock.lock()
        storedOldKey = oldKey
        storedNewKey = newKey
        storedExpectedRev = expectedRev
        lock.unlock()
    }

    var oldKey: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedOldKey
    }

    var newKey: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedNewKey
    }

    var expectedRev: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedExpectedRev
    }
}

private final class CallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    var didCall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callCount > 0
    }

    func recordCall() {
        lock.lock()
        callCount += 1
        lock.unlock()
    }
}

private actor ConflictCopyRecorder {
    private var calls: [(filename: String, bytes: Data)] = []

    func record(filename: String, bytes: Data) {
        calls.append((filename, bytes))
    }

    func firstCall() -> (filename: String, bytes: Data)? {
        calls.first
    }
}

private final class MutableNowProvider: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
    }
}
