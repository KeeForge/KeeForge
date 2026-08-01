import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListViewModelTests: XCTestCase {
    private let autoFillSuiteName = "DatabaseListViewModelTests.AutoFill"

    override func setUp() async throws {
        try await super.setUp()
        await resetCredentialIdentityStoreState()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        SettingsService.showDatabaseUsageStats = true
        AutoFillStatusService.defaults = UserDefaults(suiteName: autoFillSuiteName)!
        AutoFillStatusService.resetForTesting()
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
        await resetCredentialIdentityStoreState()
        try await super.tearDown()
    }

    func testLocalRowStatusDefersBookmarkAccessUntilOpen() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "offline-share.kdbx"))
        reference.bookmarkData = Data("unresolvable-offline-bookmark".utf8)
        DatabaseListStore.update(reference)

        let viewModel = DatabaseListViewModel()

        XCTAssertFalse(viewModel.status(for: reference).hasAccessIssue)
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

    /// macOS returns nil because no extension ships there yet; nothing was
    /// asked, so nothing may be reported.
    func testRequestEnableAutoFillReportsNothingWhenRequestIsANoOp() async throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        AutoFillStatusService.enabledProvider = { false }
        AutoFillStatusService.enableRequester = { nil }
        let viewModel = DatabaseListViewModel()
        await viewModel.refreshAutoFillStatus()

        await viewModel.requestEnableAutoFill()

        XCTAssertFalse(viewModel.isAutoFillEnableRequestRejected)
        XCTAssertEqual(viewModel.isAutoFillProviderEnabled, false)
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
