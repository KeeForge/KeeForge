import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

enum DatabaseSaveError: Error, LocalizedError, Identifiable, Equatable, Sendable {
    case databaseIsReadOnly
    case databaseLocationUnavailable
    case saveContextUnavailable
    case writeScopeRequired
    case notAuthenticated
    case networkUnavailable
    case fileNotFound
    case unknown(String)

    var id: String {
        switch self {
        case .unknown(let message):
            "unknown:\(message)"
        case .databaseIsReadOnly:
            "databaseIsReadOnly"
        case .databaseLocationUnavailable:
            "databaseLocationUnavailable"
        case .saveContextUnavailable:
            "saveContextUnavailable"
        case .writeScopeRequired:
            "writeScopeRequired"
        case .notAuthenticated:
            "notAuthenticated"
        case .networkUnavailable:
            "networkUnavailable"
        case .fileNotFound:
            "fileNotFound"
        }
    }

    var errorDescription: String? {
        switch self {
        case .databaseIsReadOnly:
            SaveError.databaseIsReadOnly.localizedDescription
        case .databaseLocationUnavailable:
            SaveError.databaseLocationUnavailable.localizedDescription
        case .saveContextUnavailable:
            SaveError.saveContextUnavailable.localizedDescription
        case .writeScopeRequired:
            CloudProviderError.writeScopeRequired.localizedDescription
        case .notAuthenticated:
            CloudProviderError.notAuthenticated.localizedDescription
        case .networkUnavailable:
            CloudProviderError.networkUnavailable.localizedDescription
        case .fileNotFound:
            CloudProviderError.fileNotFound.localizedDescription
        case .unknown(let message):
            message
        }
    }

    var isWriteScopeRequired: Bool {
        self == .writeScopeRequired
    }

    init(_ error: Error) {
        switch error {
        case let saveError as SaveError:
            switch saveError {
            case .databaseIsReadOnly:
                self = .databaseIsReadOnly
            case .databaseLocationUnavailable:
                self = .databaseLocationUnavailable
            case .saveContextUnavailable:
                self = .saveContextUnavailable
            }
        case let cloudError as CloudProviderError:
            switch cloudError {
            case .writeScopeRequired:
                self = .writeScopeRequired
            case .notAuthenticated:
                self = .notAuthenticated
            case .networkUnavailable:
                self = .networkUnavailable
            case .fileNotFound:
                self = .fileNotFound
            default:
                self = .unknown(cloudError.localizedDescription)
            }
        default:
            self = .unknown(error.localizedDescription)
        }
    }
}

@MainActor @Observable
final class DatabaseViewModel {
    struct ReloadedDatabase: Sendable {
        let reference: DatabaseReference
        let rootGroup: KPGroup
        let meta: KPMeta
        let sessionKey: SymmetricKey
        let openTimeSHA512: Data
    }

    struct PendingLockRequest: Identifiable, Equatable, Sendable {
        let manuallyTriggered: Bool

        var id: String {
            manuallyTriggered ? "manual" : "automatic"
        }
    }

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

    typealias CloudSyncOperation = @Sendable (
        _ reference: DatabaseReference,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudSyncResolution
    typealias LocalSaveOperation = @Sendable (
        _ draft: DatabaseDraft,
        _ reference: DatabaseReference,
        _ compositeKey: Data,
        _ openTimeSHA512: Data
    ) async throws -> SaveResult
    typealias CloudSaveOperation = @Sendable (
        _ draft: DatabaseDraft,
        _ reference: DatabaseReference,
        _ compositeKey: Data,
        _ openTimeSHA512: Data,
        _ expectedRev: String?
    ) async throws -> SaveResult
    typealias ConflictCopyEncryptionOperation = @Sendable (
        _ draft: DatabaseDraft,
        _ compositeKey: Data,
        _ sourceData: Data
    ) async throws -> Data
    typealias LocalConflictCopyOperation = @Sendable (
        _ reference: DatabaseReference,
        _ filename: String,
        _ bytes: Data
    ) async throws -> Void
    typealias CloudConflictCopyOperation = @Sendable (
        _ reference: DatabaseReference,
        _ fileID: String,
        _ bytes: Data
    ) async throws -> Void
    typealias ReloadOperation = @Sendable (
        _ reference: DatabaseReference,
        _ compositeKey: Data
    ) async throws -> ReloadedDatabase
    typealias SyncedFolderDetectionOperation = @Sendable (DatabaseReference) async -> SyncedFolderLocation
    typealias SyncedFolderWarningHandler = @MainActor @Sendable (SyncedFolderWarning) async -> SyncedFolderWarningAction

    private static let sortOrderKey = "KeeForge.sortOrder"
    private static let sortAscendingKey = "KeeForge.sortAscending"
    private static let decryptingStatusMessage = "Decrypting your database securely..."

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
    var draft: DatabaseDraft?
    private(set) var openTimeSHA512: Data?
    private(set) var saveError: DatabaseSaveError?
    private(set) var saveConflict: SaveConflict?
    private(set) var isSaving = false
    private(set) var pendingLockRequest: PendingLockRequest?
    private(set) var syncedFolderWarning: SyncedFolderWarning?
    private(set) var cloudSyncProgress: Double?
    private(set) var cloudSyncBannerText: String?
    private(set) var unlockStatusMessage: String
    private var unlockedMeta: KPMeta?
    private let cloudSyncOperation: CloudSyncOperation
    private let localSaveOperation: LocalSaveOperation
    private let cloudSaveOperation: CloudSaveOperation
    private let conflictCopyEncryptionOperation: ConflictCopyEncryptionOperation
    private let localConflictCopyOperation: LocalConflictCopyOperation
    private let cloudConflictCopyOperation: CloudConflictCopyOperation
    private let reloadOperation: ReloadOperation
    private let syncedFolderDetector: SyncedFolderDetectionOperation
    private let syncedFolderWarningHandler: SyncedFolderWarningHandler
    private let conflictCopyDateProvider: @Sendable () -> Date

    init(
        databaseReference: DatabaseReference,
        cloudSyncOperation: @escaping CloudSyncOperation = { reference, progress in
            try await CloudSyncCoordinator.syncIfNeededForOpen(
                reference: reference,
                progress: progress
            )
        },
        localSaveOperation: @escaping LocalSaveOperation = { draft, reference, compositeKey, openTimeSHA512 in
            try await LocalDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512
            )
        },
        cloudSaveOperation: @escaping CloudSaveOperation = { draft, reference, compositeKey, openTimeSHA512, expectedRev in
            try await CloudDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                expectedRev: expectedRev
            )
        },
        conflictCopyEncryptionOperation: @escaping ConflictCopyEncryptionOperation = { draft, compositeKey, sourceData in
            try await DatabaseViewModel.encryptConflictCopy(
                draft: draft,
                compositeKey: compositeKey,
                sourceData: sourceData
            )
        },
        localConflictCopyOperation: @escaping LocalConflictCopyOperation = { reference, filename, bytes in
            try await DatabaseViewModel.writeConflictCopyLocally(
                reference: reference,
                filename: filename,
                bytes: bytes
            )
        },
        cloudConflictCopyOperation: @escaping CloudConflictCopyOperation = { reference, fileID, bytes in
            try await DatabaseViewModel.writeConflictCopyToCloud(
                reference: reference,
                fileID: fileID,
                bytes: bytes
            )
        },
        reloadOperation: @escaping ReloadOperation = { reference, compositeKey in
            try await DatabaseViewModel.reloadDatabase(
                reference: reference,
                compositeKey: compositeKey
            )
        },
        syncedFolderDetector: @escaping SyncedFolderDetectionOperation = { reference in
            await SyncedFolderDetector.detect(reference: reference)
        },
        syncedFolderWarningHandler: @escaping SyncedFolderWarningHandler = { _ in
            .continueEditing
        },
        conflictCopyDateProvider: @escaping @Sendable () -> Date = { .now }
    ) {
        self.databaseReference = databaseReference
        sortOrder = Self.savedSortOrder()
        sortAscending = Self.savedSortAscending()
        unlockStatusMessage = databaseReference.isCloudBacked
            ? DatabaseViewModel.syncStatusMessage(for: databaseReference)
            : Self.decryptingStatusMessage
        self.cloudSyncOperation = cloudSyncOperation
        self.localSaveOperation = localSaveOperation
        self.cloudSaveOperation = cloudSaveOperation
        self.conflictCopyEncryptionOperation = conflictCopyEncryptionOperation
        self.localConflictCopyOperation = localConflictCopyOperation
        self.cloudConflictCopyOperation = cloudConflictCopyOperation
        self.reloadOperation = reloadOperation
        self.syncedFolderDetector = syncedFolderDetector
        self.syncedFolderWarningHandler = syncedFolderWarningHandler
        self.conflictCopyDateProvider = conflictCopyDateProvider
    }

    var databaseDisplayName: String {
        databaseReference.displayName
    }

    var databaseFilename: String {
        databaseReference.filename
    }

    var isReadOnly: Bool {
        databaseReference.isReadOnly
    }

    var isDirty: Bool {
        draft?.isDirty ?? false
    }

    var currentRootGroup: KPGroup? {
        draft?.rootGroup ?? rootGroup
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
        guard !searchText.isEmpty, let root = currentRootGroup else { return [] }
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

        prepareForUnlock()

        do {
            let (_, data) = try await readDatabaseData()
            try cacheDatabaseCopy(data)

            let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
            let sessionKey = SymmetricKey(size: .bits256)

            let unlockPayload = try await Task.detached {
                let parsed = try KDBXParser.parseWithMeta(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey
                )
                return UnlockPayload(
                    rootGroup: parsed.rootGroup,
                    meta: parsed.meta,
                    openTimeSHA512: KDBXCrypto.sha512(data)
                )
            }.value

            await finalizeSuccessfulUnlock(
                payload: unlockPayload,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        } catch {
            handleUnlockFailure(error)
        }
    }

    func unlockWithBiometrics() async {
        prepareForUnlock()

        do {
            let context = try await BiometricService.authenticate(reason: "Unlock your password database")
            let compositeKey = try retrieveStoredCompositeKey(context: context)
            let (_, data) = try await readDatabaseData()
            try cacheDatabaseCopy(data)
            let sessionKey = SymmetricKey(size: .bits256)

            let unlockPayload = try await Task.detached {
                let parsed = try KDBXParser.parseWithMeta(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey
                )
                return UnlockPayload(
                    rootGroup: parsed.rootGroup,
                    meta: parsed.meta,
                    openTimeSHA512: KDBXCrypto.sha512(data)
                )
            }.value

            await finalizeSuccessfulUnlock(
                payload: unlockPayload,
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

    func entry(withID entryID: UUID) -> KPEntry? {
        currentRootGroup?.allEntries.first(where: { $0.id == entryID })
    }

    func group(withID groupID: UUID) -> KPGroup? {
        Self.findGroup(groupID, in: currentRootGroup)
    }

    func applyEntryEdit(_ edit: EntryEdit) throws {
        draft = try makeWorkingDraft().apply(edit)
        saveConflict = nil
        resetInactivityTimer()
    }

    func deleteEntry(_ entryID: UUID, sendToRecycleBin: Bool) throws {
        try applyEntryEdit(.deleteEntry(entryID: entryID, sendToRecycleBin: sendToRecycleBin))
    }

    func saveHandlingError() async {
        do {
            try await save()
        } catch {
            saveError = DatabaseSaveError(error)
        }
    }

    func clearSaveError() {
        saveError = nil
    }

    func presentSaveError(_ error: Error) {
        saveError = DatabaseSaveError(error)
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
        unlockedMeta = nil
        draft = nil
        openTimeSHA512 = nil
        saveError = nil
        saveConflict = nil
        pendingLockRequest = nil
        syncedFolderWarning = nil
        cloudSyncProgress = nil
        cloudSyncBannerText = nil
        unlockStatusMessage = databaseReference.isCloudBacked
            ? Self.syncStatusMessage(for: databaseReference)
            : Self.decryptingStatusMessage
        searchText = ""
        navigationPath = NavigationPath()
    }

    func lockRequest(force: Bool = false, manuallyTriggered: Bool = false) {
        guard case .unlocked = state else {
            if force {
                lock(manuallyTriggered: manuallyTriggered)
            }
            return
        }

        if force || isDirty == false {
            discardDraft()
            lock(manuallyTriggered: manuallyTriggered)
            return
        }

        pendingLockRequest = PendingLockRequest(manuallyTriggered: manuallyTriggered)
    }

    func cancelLockRequest() {
        pendingLockRequest = nil
        resetInactivityTimer()
    }

    func discardDraft() {
        draft = nil
        saveConflict = nil
    }

    func save() async throws {
        if databaseReference.isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        guard case .unlocked = state else { return }
        guard let draft else { return }
        guard draft.isDirty else { return }
        guard let compositeKey, let openTimeSHA512 else {
            throw SaveError.saveContextUnavailable
        }

        isSaving = true
        saveError = nil
        saveConflict = nil
        defer {
            isSaving = false
        }

        let saveResult: SaveResult
        switch databaseReference.source {
        case .local:
            saveResult = try await localSaveOperation(
                draft,
                databaseReference,
                compositeKey,
                openTimeSHA512
            )
        case .cloud:
            saveResult = try await cloudSaveOperation(
                draft,
                databaseReference,
                compositeKey,
                openTimeSHA512,
                databaseReference.expectedCloudRevision
            )
        }

        switch saveResult {
        case .saved(let newSHA512):
            rootGroup = draft.rootGroup
            unlockedMeta = draft.meta
            self.openTimeSHA512 = newSHA512
            self.draft = nil
            saveConflict = nil
            saveError = nil
            refreshDatabaseReference()
        case .conflict(let remoteSHA512, let remoteData):
            saveConflict = SaveConflict(
                remoteSHA512: remoteSHA512,
                remoteData: remoteData
            )
        }
    }

    func saveAsConflictCopy() async throws {
        guard let draft, let saveConflict, let compositeKey else {
            throw SaveError.saveContextUnavailable
        }

        let bytes = try await conflictCopyEncryptionOperation(
            draft,
            compositeKey,
            saveConflict.remoteData
        )
        let filename = conflictCopyFilename(for: databaseReference.filename)

        switch databaseReference.source {
        case .local:
            try await localConflictCopyOperation(databaseReference, filename, bytes)
        case .cloud(let metadata):
            let fileID = Self.siblingCloudConflictFileID(
                currentFileID: metadata.fileId,
                filename: filename
            )
            try await cloudConflictCopyOperation(databaseReference, fileID, bytes)
        }

        discardDraft()
    }

    func reloadDiscardingDraft() async throws {
        guard let compositeKey else {
            throw SaveError.saveContextUnavailable
        }

        saveError = nil
        saveConflict = nil
        navigationPath = NavigationPath()
        searchText = ""
        isSearchActive = false
        state = .unlocking
        cloudSyncProgress = nil
        unlockStatusMessage = databaseReference.isCloudBacked
            ? Self.syncStatusMessage(for: databaseReference)
            : Self.decryptingStatusMessage

        let reloaded = try await reloadOperation(databaseReference, compositeKey)
        rootGroup = reloaded.rootGroup
        databaseReference = reloaded.reference
        sessionKey = reloaded.sessionKey
        unlockedMeta = reloaded.meta
        openTimeSHA512 = reloaded.openTimeSHA512
        draft = nil
        saveConflict = nil
        syncedFolderWarning = nil
        cloudSyncBannerText = nil
        failedAttempts = 0
        lockoutUntil = nil
        state = .unlocked
        startInactivityTimer()
    }

    func acknowledgeEditingIfNeeded() async -> AcknowledgmentResult {
        guard case .local = databaseReference.source else {
            return .acknowledged
        }

        guard databaseReference.bookmarkData != nil else {
            return .acknowledged
        }

        if databaseReference.editsAcknowledgedAt != nil {
            return .acknowledged
        }

        let syncedFolderLocation = await syncedFolderDetector(databaseReference)
        guard syncedFolderLocation != .notSynced else {
            return .acknowledged
        }

        let warning = SyncedFolderWarning(location: syncedFolderLocation)
        syncedFolderWarning = warning
        let action = await syncedFolderWarningHandler(warning)
        syncedFolderWarning = nil

        switch action {
        case .continueEditing:
            DatabaseListStore.acknowledgeEdits(for: databaseReference)
            refreshDatabaseReference()
            return .acknowledged
        case .keepReadOnly:
            DatabaseListStore.setReadOnly(true, for: databaseReference)
            refreshDatabaseReference()
            return .keptReadOnly
        }
    }

    // MARK: - Inactivity Timer

    func startInactivityTimer() {
        cancelInactivityTimer()
        let timeout = SettingsService.autoLockTimeout
        guard let seconds = timeout.seconds, seconds > 0 else { return }
        inactivityTimerInterval = seconds
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockRequest()
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

    private static func syncStatusMessage(for reference: DatabaseReference) -> String {
        let providerName = reference.cloudProviderKind?.displayName ?? "cloud"
        return "Syncing with \(providerName)..."
    }

    private struct UnlockPayload: Sendable {
        let rootGroup: KPGroup
        let meta: KPMeta
        let openTimeSHA512: Data
    }

    private func beginNewLockCycle() {
        lockCycleID += 1
    }

    private func prepareForUnlock() {
        state = .unlocking
        draft = nil
        openTimeSHA512 = nil
        saveError = nil
        saveConflict = nil
        pendingLockRequest = nil
        syncedFolderWarning = nil
        unlockedMeta = nil
        cloudSyncProgress = nil
        unlockStatusMessage = databaseReference.isCloudBacked
            ? Self.syncStatusMessage(for: databaseReference)
            : Self.decryptingStatusMessage
    }

    private func finalizeSuccessfulUnlock(
        payload: UnlockPayload,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) async {
        self.rootGroup = payload.rootGroup
        self.compositeKey = compositeKey
        self.sessionKey = sessionKey
        self.unlockedMeta = payload.meta
        self.openTimeSHA512 = payload.openTimeSHA512
        self.draft = nil
        self.saveError = nil
        self.saveConflict = nil
        self.pendingLockRequest = nil
        self.syncedFolderWarning = nil
        self.failedAttempts = 0
        self.lockoutUntil = nil
        self.state = .unlocked
        startInactivityTimer()

        persistCompositeKeyForBiometricUnlock(compositeKey)
        DatabaseListStore.markDatabaseOpened(id: databaseReference.id)
        refreshDatabaseReference()
        populateCredentialStoreIfNeeded(root: payload.rootGroup)
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

    private func makeWorkingDraft() throws -> DatabaseDraft {
        if let draft {
            return draft
        }

        guard let rootGroup = rootGroup,
              let unlockedMeta,
              let sessionKey else {
            throw SaveError.saveContextUnavailable
        }

        return DatabaseDraft(
            rootGroup: rootGroup,
            meta: unlockedMeta,
            sessionKey: sessionKey
        )
    }

    private func readDatabaseData() async throws -> (url: URL, data: Data) {
        if databaseReference.isCloudBacked {
            let resolution = try await cloudSyncOperation(databaseReference) { progress in
                Task { @MainActor in
                    self.cloudSyncProgress = progress
                }
            }
            cloudSyncProgress = nil
            cloudSyncBannerText = resolution.bannerMessage
            unlockStatusMessage = Self.decryptingStatusMessage
            DatabaseListStore.update(resolution.reference)
            databaseReference = resolution.reference
            return (resolution.localURL, resolution.data)
        }

        var lastReadError: Error?
        cloudSyncBannerText = nil
        unlockStatusMessage = Self.decryptingStatusMessage

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

    private func conflictCopyFilename(for filename: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let suffix = " (conflict \(formatter.string(from: conflictCopyDateProvider())))"
        if ext.isEmpty {
            return stem + suffix
        }
        return "\(stem)\(suffix).\(ext)"
    }

    private static func findGroup(_ groupID: UUID, in rootGroup: KPGroup?) -> KPGroup? {
        guard let rootGroup else { return nil }
        if rootGroup.id == groupID {
            return rootGroup
        }

        for childGroup in rootGroup.groups {
            if let match = findGroup(groupID, in: childGroup) {
                return match
            }
        }

        return nil
    }

    private static func encryptConflictCopy(
        draft: DatabaseDraft,
        compositeKey: Data,
        sourceData: Data
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
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
    }

    private static func writeConflictCopyLocally(
        reference: DatabaseReference,
        filename: String,
        bytes: Data
    ) async throws {
        try await Task.detached(priority: .utility) {
            let originalURL = DatabaseListStore.resolveDatabaseURL(for: reference) ?? DatabaseListStore.cacheLocation(for: reference)
            let usesSecurityScope = reference.bookmarkData != nil
            let hasSecurityScope = usesSecurityScope ? originalURL.startAccessingSecurityScopedResource() : false
            defer {
                if hasSecurityScope {
                    originalURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = originalURL.deletingLastPathComponent().appendingPathComponent(filename)
            try CoordinatedFileReader.writeData(
                bytes,
                to: destinationURL,
                options: [.atomic, .completeFileProtection]
            )
        }.value
    }

    private static func writeConflictCopyToCloud(
        reference: DatabaseReference,
        fileID: String,
        bytes: Data
    ) async throws {
        guard let metadata = reference.cloudSyncMetadata else {
            throw SaveError.saveContextUnavailable
        }

        guard let provider = CloudProviderRegistry.provider(for: metadata.provider) else {
            throw CloudProviderError.notAuthenticated
        }

        _ = try await provider.upload(
            accountId: metadata.accountId,
            fileId: fileID,
            data: bytes,
            expectedRev: nil,
            progress: { _ in }
        )
    }

    private static func siblingCloudConflictFileID(currentFileID: String, filename: String) -> String {
        let currentURL = URL(fileURLWithPath: currentFileID)
        let directory = currentURL.deletingLastPathComponent()
        let siblingURL = directory.appendingPathComponent(filename)
        let siblingPath = siblingURL.path
        return siblingPath.hasPrefix("/") ? siblingPath : "/\(siblingPath)"
    }

    private static func reloadDatabase(
        reference: DatabaseReference,
        compositeKey: Data
    ) async throws -> ReloadedDatabase {
        let data: Data
        let updatedReference: DatabaseReference

        if reference.isCloudBacked {
            let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: reference)
            data = resolution.data
            updatedReference = resolution.reference
        } else {
            guard let url = DatabaseListStore.resolveDatabaseURL(for: reference) ?? DatabaseListStore.cachedDatabaseURL(for: reference) else {
                throw SaveError.databaseLocationUnavailable
            }
            data = try readSecurityScopedData(from: url)
            updatedReference = reference
        }

        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try await Task.detached(priority: .utility) {
            try KDBXParser.parseWithMeta(
                data: data,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        }.value

        return ReloadedDatabase(
            reference: updatedReference,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey,
            openTimeSHA512: KDBXCrypto.sha512(data)
        )
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
