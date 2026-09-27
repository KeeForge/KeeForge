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

    // MARK: - Helpers

    private func makeViewModel(
        reference: DatabaseReference,
        openedData: Data,
        cloudRefreshOperation: @escaping DatabaseViewModel.CloudSyncOperation = { _, _ in
            throw CloudProviderError.networkUnavailable
        },
        pendingUploadMarkerCheck: @escaping DatabaseViewModel.PendingUploadMarkerCheck = { _ in false }
    ) -> DatabaseViewModel {
        DatabaseViewModel(
            databaseReference: reference,
            cloudSyncOperation: { reference, _ in
                Self.resolution(reference, data: openedData, status: .refreshSkipped)
            },
            cloudRefreshOperation: cloudRefreshOperation,
            pendingUploadMarkerCheck: pendingUploadMarkerCheck
        )
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
