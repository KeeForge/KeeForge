import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

@MainActor @Observable
final class DatabaseViewModel {
    enum State: Sendable, Equatable {
        case locked
        case unlocking
        case unlocked
        case error(String)
    }

    enum SortOrder: String, CaseIterable, Sendable {
        case title = "Title"
        case createdDate = "Date Created"
        case modifiedDate = "Date Modified"
    }

    private static let sortOrderKey = "KeeForge.sortOrder"
    private static let sortAscendingKey = "KeeForge.sortAscending"

    private(set) var databaseReference: DatabaseReference

    var sortAscending: Bool {
        didSet { Self.persistSortAscending(sortAscending) }
    }

    private(set) var state: State = .locked
    private(set) var lockCycleID = 0
    var didManuallyLock = false
    private(set) var rootGroup: KPGroup?
    private(set) var inactivityTimer: Timer?
    private(set) var inactivityTimerInterval: TimeInterval?
    var searchText = "" {
        didSet { resetInactivityTimer() }
    }
    var isSearchActive = false {
        didSet { resetInactivityTimer() }
    }
    var navigationPath = NavigationPath() {
        didSet { resetInactivityTimer() }
    }
    var sortOrder: SortOrder {
        didSet { Self.persistSortOrder(sortOrder) }
    }

    private(set) var failedAttempts = 0
    private(set) var lockoutUntil: Date?
    private(set) var compositeKey: Data?
    private(set) var sessionKey: SymmetricKey?
    private(set) var cloudSyncProgress: Double?
    private(set) var cloudSyncBannerText: String?

    init(databaseReference: DatabaseReference) {
        self.databaseReference = databaseReference
        sortOrder = Self.savedSortOrder()
        sortAscending = Self.savedSortAscending()
    }

    var databaseDisplayName: String {
        databaseReference.displayName
    }

    var databaseFilename: String {
        databaseReference.filename
    }

    var hasSavedFile: Bool {
        databaseReference.isCloudBacked ||
        databaseReference.bookmarkData != nil ||
        DatabaseListStore.cachedDatabaseURL(for: databaseReference) != nil
    }

    var canUseBiometrics: Bool {
        guard BiometricService.isAvailable else { return false }
        return KeychainService.hasStoredKey(
            for: databaseReference.id,
            legacyFilename: databaseReference.legacyKeychainFilename
        )
    }

    var biometricLabel: String {
        switch BiometricService.availableType {
        case .faceID: "Unlock with Face ID"
        case .touchID: "Unlock with Touch ID"
        case .none: "Biometrics unavailable"
        }
    }

    var biometricIcon: String {
        switch BiometricService.availableType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .none: "lock.fill"
        }
    }

    var searchResults: [KPEntry] {
        guard !searchText.isEmpty, let root = rootGroup else { return [] }
        let query = searchText.lowercased()
        let candidates: [KPEntry]
        if let recycleBinID = root.recycleBinUUID {
            candidates = root.allEntries(excludingGroupID: recycleBinID)
        } else {
            candidates = root.allEntries
        }
        return candidates.filter { entry in
            entry.title.lowercased().contains(query) ||
            entry.username.lowercased().contains(query) ||
            entry.url.lowercased().contains(query) ||
            entry.notes.lowercased().contains(query)
        }
    }

    /// Lockout delay in seconds: 0, 0, 0, 2, 4, 8, 16, 30, 30, 30...
    private var lockoutDelay: TimeInterval {
        guard failedAttempts >= 3 else { return 0 }
        return min(30, pow(2, Double(failedAttempts - 2)))
    }

    var lockoutRemaining: TimeInterval {
        guard let until = lockoutUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    func unlock(password: String, keyFileData: Data? = nil) async {
        if let until = lockoutUntil, Date.now < until {
            let seconds = Int(ceil(until.timeIntervalSinceNow))
            state = .error("Too many failed attempts. Try again in \(seconds)s.")
            return
        }

        state = .unlocking
        cloudSyncProgress = nil

        do {
            let (_, data) = try await readDatabaseData()
            try cacheDatabaseCopy(data)

            let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
            let sessionKey = SymmetricKey(size: .bits256)

            let root = try await Task.detached {
                try KDBXParser.parse(data: data, password: password, keyFileData: keyFileData, sessionKey: sessionKey)
            }.value

            await finalizeSuccessfulUnlock(
                root: root,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        } catch {
            handleUnlockFailure(error)
        }
    }

    func unlockWithBiometrics() async {
        state = .unlocking
        cloudSyncProgress = nil

        do {
            let context = try await BiometricService.authenticate(reason: "Unlock your password database")
            let compositeKey = try retrieveStoredCompositeKey(context: context)
            let (_, data) = try await readDatabaseData()
            try cacheDatabaseCopy(data)
            let sessionKey = SymmetricKey(size: .bits256)

            let root = try await Task.detached {
                try KDBXParser.parse(data: data, compositeKey: compositeKey, sessionKey: sessionKey)
            }.value

            await finalizeSuccessfulUnlock(
                root: root,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func loadAssociatedKeyFile() -> (data: Data, filename: String)? {
        guard let url = DatabaseListStore.resolveKeyFileURL(for: databaseReference) else { return nil }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else { return nil }

        refreshDatabaseReference()
        let filename = databaseReference.keyFileFilename ?? url.lastPathComponent
        return (data, filename)
    }

    func lock(manuallyTriggered: Bool = false) {
        cancelInactivityTimer()
        if manuallyTriggered {
            didManuallyLock = true
        }
        beginNewLockCycle()
        state = .locked
        rootGroup = nil
        compositeKey = nil
        sessionKey = nil
        cloudSyncProgress = nil
        cloudSyncBannerText = nil
        searchText = ""
        navigationPath = NavigationPath()
    }

    // MARK: - Inactivity Timer

    func startInactivityTimer() {
        cancelInactivityTimer()
        let timeout = SettingsService.autoLockTimeout
        guard let seconds = timeout.seconds, seconds > 0 else { return }
        inactivityTimerInterval = seconds
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lock()
            }
        }
    }

    func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        inactivityTimerInterval = nil
    }

    func resetInactivityTimer() {
        guard case .unlocked = state else { return }
        startInactivityTimer()
    }

    func refreshSharedDatabaseCacheIfPossible() {
        let expectedLockCycleID = lockCycleID
        let databaseReference = self.databaseReference
        let compositeKeyForStoreRefresh: Data?

        if case .unlocked = state,
           SettingsService.quickAutoFillEnabled,
           let compositeKey {
            compositeKeyForStoreRefresh = compositeKey
        } else {
            compositeKeyForStoreRefresh = nil
        }

        Task.detached(priority: .utility) {
            do {
                let data: Data

                if databaseReference.isCloudBacked {
                    let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: databaseReference)
                    DatabaseListStore.update(resolution.reference)
                    data = resolution.data

                    await MainActor.run {
                        if self.databaseReference.id == resolution.reference.id {
                            self.databaseReference = resolution.reference
                            self.cloudSyncBannerText = resolution.bannerMessage
                        }
                    }
                } else {
                    guard let url = DatabaseListStore.resolveDatabaseURL(for: databaseReference) else { return }
                    data = try Self.readSecurityScopedData(from: url)
                    try DatabaseListStore.cacheDatabaseCopy(data, for: databaseReference.id)
                }

                if let compositeKeyForStoreRefresh {
                    let refreshedRoot = try KDBXParser.parse(
                        data: data,
                        compositeKey: compositeKeyForStoreRefresh,
                        sessionKey: SymmetricKey(size: .bits256)
                    )
                    await self.refreshCredentialStoreIfStillUnlocked(
                        with: refreshedRoot,
                        expectedLockCycleID: expectedLockCycleID
                    )
                }
            } catch {
                return
            }
        }
    }

    func sortedGroups(_ groups: [KPGroup]) -> [KPGroup] {
        let asc = sortAscending
        switch sortOrder {
        case .title:
            return groups.sorted {
                let result = $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                return asc ? result : !result
            }
        case .createdDate:
            return groups.sorted {
                let result = ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast)
                return asc ? result : !result
            }
        case .modifiedDate:
            return groups.sorted {
                let result = ($0.lastModificationTime ?? .distantPast) < ($1.lastModificationTime ?? .distantPast)
                return asc ? result : !result
            }
        }
    }

    func sortedEntries(_ entries: [KPEntry]) -> [KPEntry] {
        let asc = sortAscending
        switch sortOrder {
        case .title:
            return entries.sorted {
                let result = $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                return asc ? result : !result
            }
        case .createdDate:
            return entries.sorted {
                let result = ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast)
                return asc ? result : !result
            }
        case .modifiedDate:
            return entries.sorted {
                let result = ($0.lastModificationTime ?? .distantPast) < ($1.lastModificationTime ?? .distantPast)
                return asc ? result : !result
            }
        }
    }

    func populateCredentialStoreIfUnlocked() {
        guard let root = rootGroup else { return }
        populateCredentialStoreIfNeeded(root: root)
    }

    static func credentialStoreEntries(from root: KPGroup) -> [KPEntry] {
        let entries: [KPEntry]
        if let recycleBinID = root.recycleBinUUID {
            entries = root.allEntries(excludingGroupID: recycleBinID)
        } else {
            entries = root.allEntries
        }

        return entries.filter { $0.hasPassword || $0.hasPasskey }
    }

    static func savedSortOrder() -> SortOrder {
        guard let raw = UserDefaults.standard.string(forKey: sortOrderKey) else { return .title }
        return SortOrder(rawValue: raw) ?? .title
    }

    static func persistSortOrder(_ order: SortOrder) {
        UserDefaults.standard.set(order.rawValue, forKey: sortOrderKey)
    }

    static func savedSortAscending() -> Bool {
        if UserDefaults.standard.object(forKey: sortAscendingKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: sortAscendingKey)
    }

    static func persistSortAscending(_ ascending: Bool) {
        UserDefaults.standard.set(ascending, forKey: sortAscendingKey)
    }

    // MARK: - Private

    private func beginNewLockCycle() {
        lockCycleID += 1
    }

    private func finalizeSuccessfulUnlock(root: KPGroup, compositeKey: Data, sessionKey: SymmetricKey) async {
        self.rootGroup = root
        self.compositeKey = compositeKey
        self.sessionKey = sessionKey
        self.failedAttempts = 0
        self.lockoutUntil = nil
        self.state = .unlocked
        startInactivityTimer()

        persistCompositeKeyForBiometricUnlock(compositeKey)
        DatabaseListStore.markDatabaseOpened(id: databaseReference.id)
        refreshDatabaseReference()
        populateCredentialStoreIfNeeded(root: root)
        ReviewPromptService.requestReviewIfAppropriate()
    }

    private func handleUnlockFailure(_ error: Error) {
        failedAttempts += 1
        let delay = lockoutDelay
        if delay > 0 {
            lockoutUntil = Date.now.addingTimeInterval(delay)
            let seconds = Int(ceil(delay))
            state = .error("Too many failed attempts. Try again in \(seconds)s.")
        } else {
            state = .error(error.localizedDescription)
        }
    }

    private func persistCompositeKeyForBiometricUnlock(_ compositeKey: Data) {
        guard BiometricService.isAvailable else { return }

        do {
            try KeychainService.storeCompositeKey(compositeKey, for: databaseReference.id)

            if let legacyFilename = databaseReference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
                DatabaseListStore.clearLegacyKeychainFilename(for: databaseReference.id)
            }
        } catch {
            return
        }
    }

    private func retrieveStoredCompositeKey(context: LAContext) throws -> Data {
        do {
            return try KeychainService.retrieveCompositeKey(for: databaseReference.id, context: context)
        } catch {
            guard KeychainService.isItemNotFound(error),
                  let legacyFilename = databaseReference.legacyKeychainFilename else {
                throw error
            }

            return try KeychainService.retrieveLegacyCompositeKey(forFilename: legacyFilename, context: context)
        }
    }

    private func refreshDatabaseReference() {
        if let refreshedReference = DatabaseListStore.databases.first(where: { $0.id == databaseReference.id }) {
            databaseReference = refreshedReference
        }
    }

    private func readDatabaseData() async throws -> (url: URL, data: Data) {
        if databaseReference.isCloudBacked {
            let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: databaseReference,
                progress: { progress in
                    Task { @MainActor in
                        self.cloudSyncProgress = progress
                    }
                }
            )
            cloudSyncProgress = nil
            cloudSyncBannerText = resolution.bannerMessage
            DatabaseListStore.update(resolution.reference)
            databaseReference = resolution.reference
            return (resolution.localURL, resolution.data)
        }

        var lastReadError: Error?
        cloudSyncBannerText = nil

        if let url = DatabaseListStore.resolveDatabaseURL(for: databaseReference) {
            do {
                return (url, try readSecurityScoped(url: url))
            } catch {
                lastReadError = error
            }
        }

        if let cachedURL = DatabaseListStore.cachedDatabaseURL(for: databaseReference) {
            return (cachedURL, try CoordinatedFileReader.readData(from: cachedURL))
        }

        throw lastReadError ?? CocoaError(.fileReadNoSuchFile)
    }

    private func readSecurityScoped(url: URL) throws -> Data {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try CoordinatedFileReader.readData(from: url)
    }

    private func populateCredentialStoreIfNeeded(root: KPGroup) {
        guard SettingsService.quickAutoFillEnabled else { return }
        DatabaseListStore.activeAutoFillDatabaseID = databaseReference.id
        CredentialIdentityStoreManager.populate(with: Self.credentialStoreEntries(from: root))
    }

    private func cacheDatabaseCopy(_ data: Data) throws {
        try DatabaseListStore.cacheDatabaseCopy(data, for: databaseReference)
    }

    private func refreshCredentialStoreIfStillUnlocked(with root: KPGroup, expectedLockCycleID: Int) {
        guard expectedLockCycleID == lockCycleID else { return }
        guard case .unlocked = state else { return }
        populateCredentialStoreIfNeeded(root: root)
    }

    nonisolated private static func readSecurityScopedData(from url: URL) throws -> Data {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try CoordinatedFileReader.readData(from: url)
    }
}
