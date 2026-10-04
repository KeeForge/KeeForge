import Foundation
import Observation

@MainActor @Observable
final class AppSettingsViewModel {
    var autoLockTimeout = SettingsService.autoLockTimeout {
        didSet {
            guard !isReloading, oldValue != autoLockTimeout else { return }
            SettingsService.autoLockTimeout = autoLockTimeout
            resetInactivityTimer()
        }
    }
    var lockOnBackground = SettingsService.lockOnBackground {
        didSet {
            guard !isReloading, oldValue != lockOnBackground else { return }
            SettingsService.lockOnBackground = lockOnBackground
        }
    }
    var clipboardTimeout = SettingsService.clipboardTimeout {
        didSet {
            guard !isReloading, oldValue != clipboardTimeout else { return }
            SettingsService.clipboardTimeout = clipboardTimeout
        }
    }
    var authenticationGracePeriod = SettingsService.authenticationGracePeriod {
        didSet {
            guard !isReloading, oldValue != authenticationGracePeriod else { return }
            SettingsService.authenticationGracePeriod = authenticationGracePeriod
        }
    }
    var autoUnlockWithFaceID = SettingsService.autoUnlockWithFaceID {
        didSet {
            guard !isReloading, oldValue != autoUnlockWithFaceID else { return }
            SettingsService.autoUnlockWithFaceID = autoUnlockWithFaceID
        }
    }
    var showWebsiteIcons = SettingsService.showWebsiteIcons {
        didSet {
            guard !isReloading, oldValue != showWebsiteIcons else { return }
            SettingsService.showWebsiteIcons = showWebsiteIcons
        }
    }
    var showDatabaseUsageStats = SettingsService.showDatabaseUsageStats {
        didSet {
            guard !isReloading, oldValue != showDatabaseUsageStats else { return }
            SettingsService.showDatabaseUsageStats = showDatabaseUsageStats
        }
    }
    var appearanceMode = SettingsService.appearanceMode {
        didSet {
            guard !isReloading, oldValue != appearanceMode else { return }
            SettingsService.appearanceMode = appearanceMode
        }
    }
    var appAccentColor = SettingsService.appAccentColor {
        didSet {
            guard !isReloading, oldValue != appAccentColor else { return }
            SettingsService.appAccentColor = appAccentColor
        }
    }
    var quickAutoFillEnabled = SettingsService.quickAutoFillEnabled {
        didSet {
            guard !isReloading, oldValue != quickAutoFillEnabled else { return }
            SettingsService.quickAutoFillEnabled = quickAutoFillEnabled
            if quickAutoFillEnabled {
                refreshCredentials()
            } else {
                clearCredentialStore()
            }
        }
    }
    var autoFillCopyTOTP = SettingsService.autoFillCopyTOTP {
        didSet {
            guard !isReloading, oldValue != autoFillCopyTOTP else { return }
            SettingsService.autoFillCopyTOTP = autoFillCopyTOTP
        }
    }
    var sortOrder = DatabaseViewModel.savedSortOrder() {
        didSet {
            guard !isReloading, oldValue != sortOrder else { return }
            DatabaseViewModel.persistSortOrder(sortOrder)
            sortOrderChanged(sortOrder)
        }
    }
    var sortAscending = DatabaseViewModel.savedSortAscending() {
        didSet {
            guard !isReloading, oldValue != sortAscending else { return }
            DatabaseViewModel.persistSortAscending(sortAscending)
            sortDirectionChanged(sortAscending)
        }
    }
    var macLockPolicy = SettingsService.macLockPolicy {
        didSet {
            guard !isReloading, oldValue != macLockPolicy else { return }
            SettingsService.macLockPolicy = macLockPolicy
        }
    }
    var blockScreenCapture = SettingsService.blockScreenCapture {
        didSet {
            guard !isReloading, oldValue != blockScreenCapture else { return }
            SettingsService.blockScreenCapture = blockScreenCapture
            capturePolicyDidChange()
        }
    }
    private(set) var cloudAccounts: [CloudAccount] = []

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var resetInactivityTimer: () -> Void
    @ObservationIgnored private var refreshCredentials: () -> Void
    @ObservationIgnored private var sortOrderChanged: (DatabaseViewModel.SortOrder) -> Void
    @ObservationIgnored private var sortDirectionChanged: (Bool) -> Void
    @ObservationIgnored private let clearCredentialStore: () -> Void
    @ObservationIgnored private let clearFaviconCacheOperation: () -> Void
    @ObservationIgnored private let capturePolicyDidChange: () -> Void
    @ObservationIgnored private let loadCloudAccounts: () -> [CloudAccount]
    @ObservationIgnored private let signOutOperation: (CloudAccount) -> Void

    init(
        resetInactivityTimer: @escaping () -> Void = {},
        refreshCredentials: @escaping () -> Void = {},
        sortOrderChanged: @escaping (DatabaseViewModel.SortOrder) -> Void = { _ in },
        sortDirectionChanged: @escaping (Bool) -> Void = { _ in },
        clearCredentialStore: @escaping () -> Void = { CredentialIdentityStoreManager.clearStore() },
        clearFaviconCache: @escaping () -> Void = { FaviconService.clearCache() },
        capturePolicyDidChange: @escaping () -> Void = {
            #if os(macOS)
            NotificationCenter.default.post(
                name: ScreenProtectionService.captureBlockingDidChangeNotification,
                object: nil
            )
            #endif
        },
        loadCloudAccounts: @escaping () -> [CloudAccount] = { CloudAccountStore.accounts },
        signOut: @escaping (CloudAccount) -> Void = {
            CloudProviderRegistry.provider(for: $0.provider)?.signOut(accountId: $0.id)
        }
    ) {
        self.resetInactivityTimer = resetInactivityTimer
        self.refreshCredentials = refreshCredentials
        self.sortOrderChanged = sortOrderChanged
        self.sortDirectionChanged = sortDirectionChanged
        self.clearCredentialStore = clearCredentialStore
        self.clearFaviconCacheOperation = clearFaviconCache
        self.capturePolicyDidChange = capturePolicyDidChange
        self.loadCloudAccounts = loadCloudAccounts
        self.signOutOperation = signOut
        cloudAccounts = loadCloudAccounts()
    }

    func connect(to database: DatabaseViewModel?) {
        resetInactivityTimer = { [weak database] in database?.resetInactivityTimer() }
        refreshCredentials = { [weak database] in database?.populateCredentialStoreIfUnlocked() }
        sortOrderChanged = { [weak database] in database?.sortOrder = $0 }
        sortDirectionChanged = { [weak database] in database?.sortAscending = $0 }
    }

    func reload() {
        // Opening Settings reflects external changes without replaying user actions.
        isReloading = true
        defer { isReloading = false }
        autoLockTimeout = SettingsService.autoLockTimeout
        lockOnBackground = SettingsService.lockOnBackground
        clipboardTimeout = SettingsService.clipboardTimeout
        authenticationGracePeriod = SettingsService.authenticationGracePeriod
        autoUnlockWithFaceID = SettingsService.autoUnlockWithFaceID
        showWebsiteIcons = SettingsService.showWebsiteIcons
        showDatabaseUsageStats = SettingsService.showDatabaseUsageStats
        appearanceMode = SettingsService.appearanceMode
        appAccentColor = SettingsService.appAccentColor
        quickAutoFillEnabled = SettingsService.quickAutoFillEnabled
        autoFillCopyTOTP = SettingsService.autoFillCopyTOTP
        sortOrder = DatabaseViewModel.savedSortOrder()
        sortAscending = DatabaseViewModel.savedSortAscending()
        macLockPolicy = SettingsService.macLockPolicy
        blockScreenCapture = SettingsService.blockScreenCapture
        cloudAccounts = loadCloudAccounts()
    }

    func clearAutoFillEntries() {
        clearCredentialStore()
    }

    func clearFaviconCache() {
        clearFaviconCacheOperation()
    }

    func signOut(_ account: CloudAccount) {
        signOutOperation(account)
        cloudAccounts = loadCloudAccounts()
    }
}
