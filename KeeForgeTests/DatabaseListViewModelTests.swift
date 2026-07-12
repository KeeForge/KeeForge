import AuthenticationServices
import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListViewModelTests: XCTestCase {
    private let autoFillSuiteName = "DatabaseListViewModelTests.AutoFill"

    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        SettingsService.showDatabaseUsageStats = true
        AutoFillStatusService.defaults = UserDefaults(suiteName: autoFillSuiteName)!
        AutoFillStatusService.resetForTesting()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        SettingsService.showDatabaseUsageStats = true
        AutoFillStatusService.resetForTesting()
        AutoFillStatusService.defaults = .standard
        AutoFillStatusService.enabledProvider = {
            await ASCredentialIdentityStore.shared.state().isEnabled
        }
        UserDefaults.standard.removePersistentDomain(forName: autoFillSuiteName)
        super.tearDown()
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
