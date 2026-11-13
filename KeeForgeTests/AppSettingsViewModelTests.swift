import XCTest
@testable import KeeForge

@MainActor
final class AppSettingsViewModelTests: XCTestCase {
    private let keys = [
        "autoLockTimeout", "lockOnBackground", "clipboardTimeout", "authenticationGracePeriod",
        "autoUnlockWithFaceID",
        "showWebsiteIcons", "showDatabaseUsageStats", "showWhatsNewAfterUpdates", "appearanceMode", "appAccentColor",
        "quickAutoFillEnabled", "autoFillCopyTOTP", "sortOrder", "sortAscending",
        "macLockPolicy", "blockScreenCapture",
    ].map { "KeeForge.\($0)" }
    private var savedStandard: [String: Any] = [:]
    private var savedShared: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys {
            savedStandard[key] = UserDefaults.standard.object(forKey: key)
            savedShared[key] = AppGroupContainer.defaults.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            AppGroupContainer.defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in keys {
            UserDefaults.standard.set(savedStandard[key], forKey: key)
            AppGroupContainer.defaults.set(savedShared[key], forKey: key)
        }
        try await super.tearDown()
    }

    func testTimeoutIsPersistedBeforeResettingTheLiveTimerAndUnchangedValuesDoNothing() {
        var observedTimeouts: [SettingsService.AutoLockTimeout] = []
        let model = AppSettingsViewModel(resetInactivityTimer: {
            observedTimeouts.append(SettingsService.autoLockTimeout)
        })

        model.autoLockTimeout = .fiveMinutes
        model.autoLockTimeout = .fiveMinutes

        XCTAssertEqual(observedTimeouts, [.fiveMinutes])
    }

    func testQuickAutoFillTransitionsPersistBeforeEffectsAndExplicitClearDoesNotRepublish() {
        SettingsService.quickAutoFillEnabled = false
        var refreshedValues: [Bool] = []
        var clearedValues: [Bool] = []
        let model = AppSettingsViewModel(
            refreshCredentials: { refreshedValues.append(SettingsService.quickAutoFillEnabled) },
            clearCredentialStore: { clearedValues.append(SettingsService.quickAutoFillEnabled) }
        )

        model.quickAutoFillEnabled = true
        model.quickAutoFillEnabled = true
        model.clearAutoFillEntries()
        model.quickAutoFillEnabled = false
        model.quickAutoFillEnabled = false

        XCTAssertEqual(refreshedValues, [true])
        XCTAssertEqual(clearedValues, [true, false])
        XCTAssertFalse(SettingsService.quickAutoFillEnabled)
    }

    func testReloadReflectsExternalChangesWithoutReplayingSecurityOrAutoFillEffects() {
        var effects = 0
        var accounts: [CloudAccount] = []
        let model = AppSettingsViewModel(
            resetInactivityTimer: { effects += 1 },
            refreshCredentials: { effects += 1 },
            sortOrderChanged: { _ in effects += 1 },
            sortDirectionChanged: { _ in effects += 1 },
            clearCredentialStore: { effects += 1 },
            capturePolicyDidChange: { effects += 1 },
            authenticationGracePeriodDidChange: { effects += 1 },
            quickUnlockPasswordIntervalDidChange: { effects += 1 },
            loadCloudAccounts: { accounts }
        )
        SettingsService.autoLockTimeout = .oneMinute
        SettingsService.authenticationGracePeriod = .oneMinute
        let previousInterval = SettingsService.quickUnlockPasswordInterval
        defer { SettingsService.quickUnlockPasswordInterval = previousInterval }
        SettingsService.quickUnlockPasswordInterval = .always
        SettingsService.quickAutoFillEnabled = !model.quickAutoFillEnabled
        SettingsService.blockScreenCapture = !model.blockScreenCapture
        SettingsService.appearanceMode = .dark
        DatabaseViewModel.persistSortOrder(.modifiedDate)
        DatabaseViewModel.persistSortAscending(false)
        accounts = [CloudAccount(id: "account", displayName: "Account", provider: "dropbox")]

        model.reload()

        XCTAssertEqual(model.autoLockTimeout, .oneMinute)
        XCTAssertEqual(model.authenticationGracePeriod, .oneMinute)
        XCTAssertEqual(model.quickUnlockPasswordInterval, .always)
        XCTAssertEqual(model.quickAutoFillEnabled, SettingsService.quickAutoFillEnabled)
        XCTAssertEqual(model.blockScreenCapture, SettingsService.blockScreenCapture)
        XCTAssertEqual(model.appearanceMode, .dark)
        XCTAssertEqual(model.sortOrder, .modifiedDate)
        XCTAssertFalse(model.sortAscending)
        XCTAssertEqual(model.cloudAccounts, accounts)
        XCTAssertEqual(effects, 0)
    }

    func testCapturePolicyPersistsBeforeLiveNotification() {
        var observedPolicies: [Bool] = []
        let model = AppSettingsViewModel(capturePolicyDidChange: {
            observedPolicies.append(SettingsService.blockScreenCapture)
        })
        let newValue = !model.blockScreenCapture

        model.blockScreenCapture = newValue
        model.blockScreenCapture = newValue

        XCTAssertEqual(observedPolicies, [newValue])
    }

    func testGracePeriodPersistsBeforeTellingTheLiveGatesAndUnchangedValuesDoNothing() {
        var observedPeriods: [SettingsService.AuthenticationGracePeriod] = []
        let model = AppSettingsViewModel(authenticationGracePeriodDidChange: {
            observedPeriods.append(SettingsService.authenticationGracePeriod)
        })

        model.authenticationGracePeriod = .oneMinute
        model.authenticationGracePeriod = .oneMinute
        model.authenticationGracePeriod = .alwaysAsk

        XCTAssertEqual(observedPeriods, [.oneMinute, .alwaysAsk])
    }

    /// Saved keys that a stricter interval makes due must go when the setting
    /// changes, not at their next use.
    func testPasswordIntervalPersistsBeforeExpiringDueKeys() {
        let previousInterval = SettingsService.quickUnlockPasswordInterval
        defer { SettingsService.quickUnlockPasswordInterval = previousInterval }
        SettingsService.quickUnlockPasswordInterval = .fourteenDays
        var observedIntervals: [SettingsService.QuickUnlockPasswordInterval] = []
        let model = AppSettingsViewModel(quickUnlockPasswordIntervalDidChange: {
            observedIntervals.append(SettingsService.quickUnlockPasswordInterval)
        })

        model.quickUnlockPasswordInterval = .always
        model.quickUnlockPasswordInterval = .always
        model.quickUnlockPasswordInterval = .thirtyDays

        XCTAssertEqual(observedIntervals, [.always, .thirtyDays])
    }

    func testSortPreferencesPersistBeforeUpdatingTheOpenSession() {
        var observedOrders: [DatabaseViewModel.SortOrder] = []
        var observedDirections: [Bool] = []
        let model = AppSettingsViewModel(
            sortOrderChanged: { order in
                XCTAssertEqual(DatabaseViewModel.savedSortOrder(), order)
                observedOrders.append(order)
            },
            sortDirectionChanged: { ascending in
                XCTAssertEqual(DatabaseViewModel.savedSortAscending(), ascending)
                observedDirections.append(ascending)
            }
        )

        model.sortOrder = .createdDate
        model.sortAscending = false

        XCTAssertEqual(observedOrders, [.createdDate])
        XCTAssertEqual(observedDirections, [false])
    }

    func testConnectingAnotherStoreAndDisconnectingStopsUpdatingThePreviousSessions() {
        let reference = DatabaseReference(
            id: UUID(), nickname: nil, filename: "settings-test.kdbx", bookmarkData: nil,
            keyFileBookmarkData: nil, keyFileFilename: nil, isQuickLaunch: false,
            lastOpenedAt: nil, addedAt: Date(), colorTag: nil, legacyKeychainFilename: nil
        )
        let first = DatabaseViewModel(databaseReference: reference)
        let second = DatabaseViewModel(databaseReference: reference)
        let firstStore = DatabaseSessionStore()
        firstStore.adopt(first)
        let secondStore = DatabaseSessionStore()
        secondStore.adopt(second)
        let model = AppSettingsViewModel()
        model.connect(to: firstStore)
        model.sortOrder = .createdDate
        XCTAssertEqual(first.sortOrder, .createdDate)

        model.connect(to: secondStore)
        model.sortOrder = .modifiedDate
        model.sortAscending = false
        XCTAssertEqual(first.sortOrder, .createdDate)
        XCTAssertTrue(first.sortAscending)
        XCTAssertEqual(second.sortOrder, .modifiedDate)
        XCTAssertFalse(second.sortAscending)

        model.connect(to: nil)
        model.sortOrder = .title
        XCTAssertEqual(second.sortOrder, .modifiedDate)
        XCTAssertEqual(DatabaseViewModel.savedSortOrder(), .title)
    }

    func testSettingsEffectsReachEverySessionOpenedAfterConnecting() async throws {
        SettingsService.autoLockTimeout = .fiveMinutes
        let store = DatabaseSessionStore()
        defer { for session in store.openSessions { session.lock() } }
        let model = AppSettingsViewModel()
        model.connect(to: store)
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<2 {
            let reference = try TestDatabaseSupport.makeReference(
                for: KDBXTestFixture.test.url(in: Bundle(for: Self.self)),
                autoFillEnabled: false
            )
            let session = DatabaseViewModel(
                databaseReference: reference,
                quickUnlockKeyPersistOperation: { _, _, _ in false },
                storedKeyPresenceCheck: { _ in false },
                nowProvider: { now }
            )
            store.adopt(session)
            await session.unlock(password: KDBXTestFixture.test.password)
            XCTAssertEqual(session.state, .unlocked)
            XCTAssertEqual(session.inactivityDeadline, Date(timeIntervalSince1970: 1_300))
        }
        store.activeSessionID = store.openSessions.last?.databaseReference.id

        model.autoLockTimeout = .thirtySeconds
        model.sortOrder = .createdDate
        model.sortAscending = false

        XCTAssertEqual(store.openSessions.count, 2)
        for session in store.openSessions {
            XCTAssertEqual(session.inactivityDeadline, Date(timeIntervalSince1970: 1_030))
            XCTAssertEqual(session.sortOrder, .createdDate)
            XCTAssertFalse(session.sortAscending)
        }
    }

    func testDisplayPrivacyAndExtensionPreferencesPersistWithoutAView() {
        let model = AppSettingsViewModel()
        model.lockOnBackground = false
        model.clipboardTimeout = .tenSeconds
        model.autoUnlockWithFaceID = true
        model.showWebsiteIcons = true
        model.showDatabaseUsageStats = false
        model.showWhatsNewAfterUpdates = false
        model.appearanceMode = .dark
        model.appAccentColor = .init(red: 0.25, green: 0.5, blue: 0.75)
        model.autoFillCopyTOTP = !model.autoFillCopyTOTP
        model.macLockPolicy = .appDeactivates

        let reopened = AppSettingsViewModel()
        XCTAssertFalse(reopened.lockOnBackground)
        XCTAssertEqual(reopened.clipboardTimeout, .tenSeconds)
        XCTAssertTrue(reopened.autoUnlockWithFaceID)
        XCTAssertTrue(reopened.showWebsiteIcons)
        XCTAssertFalse(reopened.showDatabaseUsageStats)
        XCTAssertFalse(reopened.showWhatsNewAfterUpdates)
        XCTAssertEqual(reopened.appearanceMode, .dark)
        XCTAssertEqual(reopened.appAccentColor, model.appAccentColor)
        XCTAssertEqual(reopened.autoFillCopyTOTP, model.autoFillCopyTOTP)
        XCTAssertEqual(reopened.macLockPolicy, .appDeactivates)
        model.appAccentColor = nil
        XCTAssertNil(SettingsService.appAccentColor)
    }

    func testSignOutReloadsAccountsAfterTheProviderFinishesAndCacheClearIsExplicit() {
        let account = CloudAccount(id: "account", displayName: "Account", provider: "dropbox")
        var accounts = [account]
        var signedOut: [CloudAccount] = []
        var cacheClears = 0
        let model = AppSettingsViewModel(
            clearFaviconCache: { cacheClears += 1 },
            loadCloudAccounts: { accounts },
            signOut: { signedOut.append($0); accounts = [] }
        )

        model.showWebsiteIcons = true
        XCTAssertEqual(cacheClears, 0)
        model.clearFaviconCache()
        model.signOut(account)

        XCTAssertEqual(cacheClears, 1)
        XCTAssertEqual(signedOut, [account])
        XCTAssertTrue(model.cloudAccounts.isEmpty)
    }
}
