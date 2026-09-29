import AuthenticationServices
import CryptoKit
import XCTest
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

    func testManualPolicyOpenFlagsTheSkippedRefreshWithoutAWarning() async throws {
        let openedData = try fixtureData()
        let vm = makeViewModel(reference: try makeStoredManualReference(), openedData: openedData)

        await vm.unlock(password: fixturePassword)

        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertTrue(vm.isCloudRefreshPending)
        XCTAssertNil(vm.cloudSyncBannerText, "A deliberate skip must not wear the offline or error warning")
        XCTAssertNil(vm.cloudSyncOutcome)
        XCTAssertTrue(CloudSyncStatusBanner.isVisible(for: vm))
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
        let titlesBefore = entryTitles(in: vm)
        vm.selectEntry(vm.rootGroup?.allEntries.first?.id)
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
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(newerData))
        XCTAssertNotEqual(entryTitles(in: vm), titlesBefore)
        XCTAssertNil(vm.selectedEntryID, "Selection must not point into the replaced tree")
        XCTAssertEqual(vm.state, .unlocked)
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
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(openedData), "The save must compare against what was opened")
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
        let savedData = try fixtureData(named: "kitchen-sink")
        let savedSHA512 = KDBXCrypto.sha512(savedData)
        let gate = SaveGate()
        let refreshRecorder = RefreshRecorder()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                refreshRecorder.record(reference)
                guard refreshRecorder.references.count == 1 else {
                    return Self.resolution(reference, data: savedData, status: .current)
                }
                await gate.signalStarted()
                await gate.waitUntilOpen()
                return Self.resolution(reference, data: openedData, status: .current)
            },
            cloudSaveOperation: { _, _, _, _, _, _, _, _ in
                .saved(newSHA512: savedSHA512)
            }
        )
        await vm.unlock(password: fixturePassword)

        let syncTask = Task { await vm.syncCloudNow() }
        await gate.waitUntilStarted()
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Saved Mid-Sync", password: "p"))
        )
        try await vm.save()
        XCTAssertFalse(vm.isDirty)
        await gate.open()
        await syncTask.value

        XCTAssertEqual(refreshRecorder.references.count, 2, "The superseded response must be fetched again")
        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
        XCTAssertTrue(entryTitles(in: vm).contains("Saved Mid-Sync"))
        XCTAssertEqual(vm.openTimeSHA512, savedSHA512)
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
        // Same bytes, new revision: the metadata-only change the saver rebases over.
        let remote = InMemoryRemoteProvider(bytes: openedData, rev: "rev-B")
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
        let savedData = remote.currentBytes
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(savedData))
        await gate.open()
        await syncTask.value

        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
        XCTAssertTrue(entryTitles(in: vm).contains("Saved Mid-Sync"))
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(savedData))
        XCTAssertEqual(try Data(contentsOf: cacheURL), savedData, "The stale download must not replace the saved cache")
        XCTAssertEqual(vm.state, .unlocked)

        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Saved After Sync", password: "p"))
        )
        try await vm.save()
        XCTAssertNil(vm.saveConflict)
        let remoteTitles = try Self.entryTitles(in: remote.currentBytes, password: fixturePassword)
        XCTAssertTrue(remoteTitles.isSuperset(of: ["Saved Mid-Sync", "Saved After Sync"]))
    }

    /// The response can also arrive while a save is still uploading. Nothing
    /// shows the save yet, so Sync Now must wait it out and ask again rather
    /// than merge the older revision ahead of the save's own, which would
    /// keep the save's revision from being recorded.
    func testSyncNowWaitsOutASaveStillInFlightWhenItsResponseArrives() async throws {
        let openedData = try fixtureData()
        let savedData = try fixtureData(named: "kitchen-sink")
        let savedSHA512 = KDBXCrypto.sha512(savedData)
        let refreshGate = SaveGate()
        let saveGate = SaveGate()
        let refreshRecorder = RefreshRecorder()
        let vm = makeViewModel(
            reference: try makeStoredManualReference(),
            openedData: openedData,
            cloudRefreshOperation: { reference, _ in
                refreshRecorder.record(reference)
                guard refreshRecorder.references.count == 1 else {
                    return Self.resolution(reference, data: savedData, status: .current)
                }
                await refreshGate.signalStarted()
                await refreshGate.waitUntilOpen()
                var learned = reference
                learned.updateCloudSyncMetadata { metadata in
                    metadata.remoteRev = "rev-B"
                    metadata.lastSyncedAt = .now
                }
                return Self.resolution(learned, data: openedData, status: .current)
            },
            cloudSaveOperation: { _, reference, _, _, _, _, _, _ in
                await saveGate.signalStarted()
                await saveGate.waitUntilOpen()
                // What `applyUploadedBytesAfterSave` records once the upload lands.
                let observed = try XCTUnwrap(reference.cloudSyncMetadata)
                _ = DatabaseListStore.updateCloudSyncMetadata(for: reference.id, ifUnchangedFrom: observed) { metadata in
                    metadata.remoteRev = "rev-C"
                }
                return .saved(newSHA512: savedSHA512)
            }
        )
        await vm.unlock(password: fixturePassword)

        let syncTask = Task { await vm.syncCloudNow() }
        await refreshGate.waitUntilStarted()
        let parentGroupID = try XCTUnwrap(vm.visibleRootGroup?.id)
        try vm.applyEntryEdit(
            .createEntry(parentGroupID: parentGroupID, draft: EntryDraftPayload(title: "Saved Mid-Sync", password: "p"))
        )
        let saveTask = Task { try await vm.save() }
        await saveGate.waitUntilStarted()
        await refreshGate.open()
        // Let Sync Now take the response while the save is still uploading.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(vm.cloudSyncOutcome, "Sync Now must not settle while a save is in flight")
        await saveGate.open()
        try await saveTask.value
        await syncTask.value

        XCTAssertEqual(refreshRecorder.references.count, 2, "The response that predates the save must be fetched again")
        XCTAssertEqual(vm.cloudSyncOutcome, .upToDate)
        XCTAssertEqual(vm.openTimeSHA512, savedSHA512)
        let stored = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == vm.databaseReference.id }))
        XCTAssertEqual(stored.cloudSyncMetadata?.remoteRev, "rev-C", "The save's revision must be the one recorded")
        XCTAssertEqual(vm.databaseReference.cloudSyncMetadata?.remoteRev, "rev-C")
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
        DatabaseListStore.update(reference)
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
        XCTAssertEqual(vm.openTimeSHA512, KDBXCrypto.sha512(openedData))
        XCTAssertEqual(vm.state, .unlocked)
        XCTAssertFalse(vm.isCloudRefreshPending)
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

    func testSettingThePolicyFromTheSessionPersistsIt() async throws {
        let reference = try makeStoredManualReference()
        let vm = makeViewModel(reference: reference, openedData: try fixtureData())

        vm.setCloudSyncPolicy(.onOpen)

        XCTAssertEqual(vm.databaseReference.cloudSyncPolicy, .onOpen)
        XCTAssertEqual(DatabaseListStore.databases.first(where: { $0.id == reference.id })?.cloudSyncPolicy, .onOpen)
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
        await gate.firstCallStarted()

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
        pendingUploadMarkerCheck: @escaping DatabaseViewModel.PendingUploadMarkerCheck = { _ in false },
        importStagingOperation: @escaping DatabaseViewModel.ImportStagingOperation = DatabaseViewModel.stageImportedEntries
    ) -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .refreshSkipped)
            },
            cloudRefreshOperation: cloudRefreshOperation,
            cloudSaveOperation: cloudSaveOperation,
            pendingUploadMarkerCheck: pendingUploadMarkerCheck,
            importStagingOperation: importStagingOperation
        )
    }

    /// The production coordinator and saver on the shared cache, with only
    /// the provider transport replaced by `remote`.
    private func makeViewModelOnTheRealCache(
        reference: DatabaseReference,
        remote: InMemoryRemoteProvider
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
                try await CloudSyncCoordinator.syncIfNeededForOpen(
                    reference: reference,
                    honorsManualSyncPolicy: false,
                    providerResolver: { _ in remote },
                    progress: progress
                )
            },
            cloudSaveOperation: { draft, reference, compositeKey, openTimeSHA512, reconciledRemoteSHA512, expectedRev, newCompositeKey, encryptionSettings in
                try await CloudDatabaseSaver.save(
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

    private func makeStoredManualReference(provider: CloudProviderKind = .dropbox) throws -> DatabaseReference {
        let file = CloudFile(
            id: "/Vaults/manual.kdbx",
            name: "manual.kdbx",
            path: "/Vaults/manual.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 100),
            size: 128
        )
        var reference = DatabaseListStore.addCloud(provider: provider.rawValue, accountId: "acct-1", file: file)
        reference.cloudSyncPolicy = .manual
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteRev = "rev-A"
            metadata.lastSyncedAt = Date(timeIntervalSince1970: 1_000)
        }
        DatabaseListStore.update(reference)
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
