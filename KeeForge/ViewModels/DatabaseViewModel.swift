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
        let formatVersion: KDBXParser.FileVersion
        let sessionKey: SymmetricKey
        let openTimeSHA512: Data
    }

    struct PendingLockRequest: Identifiable, Equatable, Sendable {
        let manuallyTriggered: Bool

        var id: String {
            manuallyTriggered ? "manual" : "automatic"
        }
    }

    struct GroupDeletionSummary: Equatable, Sendable {
        let name: String
        let entryCount: Int
        let nestedGroupCount: Int
    }

    enum State: Sendable, Equatable {
        case locked
        case unlocking
        case unlocked
        case error(DatabaseOpenFailure)
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
    private static let sharedCloudRefreshMinimumInterval: TimeInterval = 30

    private enum SharedCacheRefreshFingerprint: Equatable {
        case local(url: URL, modificationDate: Date?)
        case cloud(fileID: String, remoteRev: String?, remoteModifiedAt: Date?, lastSyncedAt: Date?)
    }

    private(set) var databaseReference: DatabaseReference

    var sortAscending: Bool {
        didSet { Self.persistSortAscending(sortAscending) }
    }

    private(set) var state: State = .locked
    private(set) var lockCycleID = 0
    var didManuallyLock = false
    private(set) var rootGroup: KPGroup? {
        didSet { rebuildDerivedState() }
    }
    private(set) var openedFormatVersion: KDBXParser.FileVersion?
    private(set) var inactivityTimer: Timer?
    private(set) var inactivityTimerInterval: TimeInterval?
    private(set) var inactivityDeadline: Date?
    var searchText = "" {
        didSet {
            resetInactivityTimer()
            updateSearchResults()
        }
    }
    var isSearchActive = false {
        didSet { resetInactivityTimer() }
    }
    var navigationPath = NavigationPath() {
        didSet { resetInactivityTimer() }
    }
    var selectedGroupID: UUID? {
        didSet {
            if oldValue != selectedGroupID {
                selectedEntryID = nil
            }
            resetInactivityTimer()
        }
    }
    var selectedEntryID: UUID? {
        didSet { resetInactivityTimer() }
    }
    var sortOrder: SortOrder {
        didSet { Self.persistSortOrder(sortOrder) }
    }

    private(set) var failedAttempts = 0
    private(set) var lockoutUntil: Date?
    private(set) var compositeKey: Data?
    private(set) var sessionKey: SymmetricKey?
    var draft: DatabaseDraft? {
        didSet { rebuildDerivedState() }
    }
    private(set) var contentRevision = 0
    private(set) var searchResults: [KPEntry] = []
    private(set) var openTimeSHA512: Data?
    private(set) var saveError: DatabaseSaveError?
    private(set) var saveConflict: SaveConflict?
    private(set) var isSaving = false
    private(set) var pendingLockRequest: PendingLockRequest?
    private(set) var syncedFolderWarning: SyncedFolderWarning?
    private(set) var cloudSyncProgress: Double?
    private(set) var cloudSyncBannerText: String?
    private(set) var unlockStatusMessage: String
    private var entryIndex: [UUID: KPEntry] = [:]
    private var groupIndex: [UUID: KPGroup] = [:]
    private var groupEntryCounts: [UUID: Int] = [:]
    private var searchableEntries: [KPEntry] = []
    private var searchableEntryText: [UUID: String] = [:]
    private var recycleBinEntryIDs: Set<UUID> = []
    private var recycleBinGroupIDs: Set<UUID> = []
    private var lastSharedCacheRefreshFingerprint: SharedCacheRefreshFingerprint?
    private var isRefreshingSharedCache = false
    private var lastSharedCacheRefreshAt: Date?
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
    private let nowProvider: @Sendable () -> Date
    private var backgroundEnteredAt: Date?

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
        conflictCopyDateProvider: @escaping @Sendable () -> Date = { .now },
        nowProvider: @escaping @Sendable () -> Date = { .now }
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
        self.nowProvider = nowProvider
    }

    convenience init(createdDatabase: CreatedDatabase) {
        self.init(databaseReference: createdDatabase.reference)
        finalizeSuccessfulUnlock(
            payload: UnlockPayload(
                rootGroup: createdDatabase.rootGroup,
                meta: createdDatabase.meta,
                formatVersion: createdDatabase.formatVersion,
                openTimeSHA512: createdDatabase.openTimeSHA512
            ),
            compositeKey: createdDatabase.compositeKey,
            sessionKey: createdDatabase.sessionKey
        )
    }

    var databaseDisplayName: String {
        databaseReference.displayName
    }

    var databaseFilename: String {
        databaseReference.filename
    }

    var isReadOnly: Bool {
        databaseReference.isReadOnly || openedFormatVersion?.requiresReadOnlyMode == true
    }

    var isFormatReadOnly: Bool {
        openedFormatVersion?.requiresReadOnlyMode == true
    }

    var isDirty: Bool {
        draft?.isDirty ?? false
    }

    var currentRootGroup: KPGroup? {
        draft?.rootGroup ?? rootGroup
    }

    var visibleRootGroup: KPGroup? {
        guard let visibleRootGroupID else { return nil }
        return group(withID: visibleRootGroupID)
    }

    /// The group ID to display at the top level of the navigation stack.
    /// KDBX files wrap all content in a single root `<Group>`, so the parser's
    /// synthetic wrapper has one child — the actual visible root. Show that
    /// child's contents directly, skipping the wrapper level.
    var visibleRootGroupID: UUID? {
        guard let root = currentRootGroup else { return nil }
        if root.entries.isEmpty, root.groups.count == 1 {
            return root.groups[0].id
        }
        return root.id
    }

    var hasSavedFile: Bool {
        databaseReference.isCloudBacked ||
        databaseReference.bookmarkData != nil ||
        DatabaseListStore.cachedDatabaseURL(for: databaseReference) != nil
    }

    var openFailure: DatabaseOpenFailure? {
        guard case .error(let failure) = state else { return nil }
        return failure
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
        let failedAttemptsBeforeAttempt = failedAttempts
        if let until = lockoutUntil, Date.now < until {
            let seconds = Int(ceil(until.timeIntervalSinceNow))
            let diagnostics = makeUnlockDiagnostics(
                unlockMethod: .password,
                passwordSupplied: password.isEmpty == false,
                keyFileSupplied: keyFileData != nil,
                failedAttemptsBeforeAttempt: failedAttemptsBeforeAttempt,
                encryptedData: nil,
                cloudSyncStatus: nil
            )
            state = .error(lockoutFailure(seconds: seconds, diagnostics: diagnostics))
            return
        }

        prepareForUnlock()

        var encryptedData: Data?
        var cloudSyncStatus: CloudSyncResolution.Status?

        do {
            let readResult = try await readDatabaseData()
            let data = readResult.data
            encryptedData = data
            cloudSyncStatus = readResult.cloudSyncStatus
            try cacheDatabaseCopy(data)

            let compositeKey = KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
            let sessionKey = SymmetricKey(size: .bits256)

            let unlockPayload = try await Task.detached(priority: .userInitiated) {
                let parsed = try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey
                )
                return UnlockPayload(
                    rootGroup: parsed.rootGroup,
                    meta: parsed.meta,
                    formatVersion: parsed.header.formatVersion,
                    openTimeSHA512: KDBXCrypto.sha512(data)
                )
            }.value

            finalizeSuccessfulUnlock(
                payload: unlockPayload,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        } catch {
            let diagnostics = makeUnlockDiagnostics(
                unlockMethod: .password,
                passwordSupplied: password.isEmpty == false,
                keyFileSupplied: keyFileData != nil,
                failedAttemptsBeforeAttempt: failedAttemptsBeforeAttempt,
                encryptedData: encryptedData,
                cloudSyncStatus: cloudSyncStatus
            )
            handleUnlockFailure(error, diagnostics: diagnostics)
        }
    }

    func unlockWithBiometrics() async {
        let failedAttemptsBeforeAttempt = failedAttempts
        prepareForUnlock()

        var encryptedData: Data?
        var cloudSyncStatus: CloudSyncResolution.Status?

        do {
            let context = try await BiometricService.authenticate(reason: "Unlock your password database")
            let compositeKey = try retrieveStoredCompositeKey(context: context)
            let readResult = try await readDatabaseData()
            let data = readResult.data
            encryptedData = data
            cloudSyncStatus = readResult.cloudSyncStatus
            try cacheDatabaseCopy(data)
            let sessionKey = SymmetricKey(size: .bits256)

            let unlockPayload = try await Task.detached(priority: .userInitiated) {
                let parsed = try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey
                )
                return UnlockPayload(
                    rootGroup: parsed.rootGroup,
                    meta: parsed.meta,
                    formatVersion: parsed.header.formatVersion,
                    openTimeSHA512: KDBXCrypto.sha512(data)
                )
            }.value

            finalizeSuccessfulUnlock(
                payload: unlockPayload,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        } catch {
            let diagnostics = makeUnlockDiagnostics(
                unlockMethod: .biometrics,
                passwordSupplied: false,
                keyFileSupplied: false,
                failedAttemptsBeforeAttempt: failedAttemptsBeforeAttempt,
                encryptedData: encryptedData,
                cloudSyncStatus: cloudSyncStatus
            )
            handleUnlockFailure(error, diagnostics: diagnostics)
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
        _ = contentRevision
        return entryIndex[entryID]
    }

    func group(withID groupID: UUID) -> KPGroup? {
        _ = contentRevision
        return groupIndex[groupID]
    }

    func isEntryInRecycleBin(entryID: UUID) -> Bool {
        recycleBinEntryIDs.contains(entryID)
    }

    func isGroupInRecycleBin(groupID: UUID) -> Bool {
        recycleBinGroupIDs.contains(groupID)
    }

    func isGroupProtectedFromDeletion(groupID: UUID) -> Bool {
        guard let root = currentRootGroup else { return true }
        if groupID == root.id {
            return true
        }
        if let visibleRootGroupID, groupID == visibleRootGroupID {
            return true
        }

        guard let recycleBinID = root.recycleBinUUID else {
            return false
        }

        if groupID == recycleBinID {
            return true
        }

        guard let group = groupIndex[groupID] else {
            return false
        }

        return Self.group(group, containsGroupID: recycleBinID)
    }

    func groupDeletionSummary(forGroupID groupID: UUID) -> GroupDeletionSummary? {
        guard let group = groupIndex[groupID] else { return nil }
        return GroupDeletionSummary(
            name: group.name,
            entryCount: groupEntryCounts[groupID] ?? group.allEntries.count,
            nestedGroupCount: Self.nestedGroupCount(in: group)
        )
    }

    func applyEntryEdit(_ edit: EntryEdit) throws {
        draft = try makeWorkingDraft().apply(edit)
        saveConflict = nil
        refreshCredentialStoreForCurrentTreeIfNeeded()
        resetInactivityTimer()
    }

    func deleteEntry(_ entryID: UUID, sendToRecycleBin: Bool) throws {
        try applyEntryEdit(.deleteEntry(entryID: entryID, sendToRecycleBin: sendToRecycleBin))
    }

    func deleteGroup(_ groupID: UUID, sendToRecycleBin: Bool) throws {
        let affectedGroupIDs = groupIndex[groupID].map(Self.groupIDs(in:)) ?? []
        let affectedEntryIDs = Set(groupIndex[groupID]?.allEntries.map(\.id) ?? [])

        try applyEntryEdit(.deleteGroup(groupID: groupID, sendToRecycleBin: sendToRecycleBin))

        if let selectedGroupID, affectedGroupIDs.contains(selectedGroupID) {
            self.selectedGroupID = visibleRootGroupID
        }
        if let selectedEntryID, affectedEntryIDs.contains(selectedEntryID) {
            self.selectedEntryID = nil
        }
    }

    func createGroup(named name: String, in parentGroupID: UUID) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }
        try applyEntryEdit(.createGroup(parentGroupID: parentGroupID, name: trimmedName))
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
        backgroundEnteredAt = nil
        if manuallyTriggered {
            didManuallyLock = true
        }
        beginNewLockCycle()
        state = .locked
        rootGroup = nil
        openedFormatVersion = nil
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
        selectedGroupID = nil
        selectedEntryID = nil
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
        refreshCredentialStoreForCurrentTreeIfNeeded()
    }

    func save() async throws {
        if isReadOnly {
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
            populateCredentialStoreIfNeeded(root: draft.rootGroup)
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
        selectedGroupID = nil
        selectedEntryID = nil
        state = .unlocking
        cloudSyncProgress = nil
        unlockStatusMessage = databaseReference.isCloudBacked
            ? Self.syncStatusMessage(for: databaseReference)
            : Self.decryptingStatusMessage

        let reloaded = try await reloadOperation(databaseReference, compositeKey)
        rootGroup = reloaded.rootGroup
        databaseReference = reloaded.reference
        openedFormatVersion = reloaded.formatVersion
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
        synchronizeSelections()
        startInactivityTimer()
    }

    func selectGroup(_ groupID: UUID?) {
        selectedGroupID = groupID
    }

    func selectEntry(_ entryID: UUID?) {
        selectedEntryID = entryID
    }

    func setReadOnly(_ isReadOnly: Bool) {
        DatabaseListStore.setReadOnly(isReadOnly, for: databaseReference)
        refreshDatabaseReference()
    }

    func setNickname(_ nickname: String?) {
        var updatedReference = DatabaseListStore.databases.first(where: { $0.id == databaseReference.id }) ?? databaseReference
        updatedReference.nickname = nickname
        DatabaseListStore.update(updatedReference)
        refreshDatabaseReference()
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
        let timeout = SettingsService.autoLockTimeout
        backgroundEnteredAt = nil

        switch timeout {
        case .never:
            cancelInactivityTimer()
        case .immediately:
            cancelInactivityTimer()
            inactivityDeadline = nowProvider()
        case .thirtySeconds, .oneMinute, .fiveMinutes:
            guard let seconds = timeout.seconds else { return }
            scheduleInactivityTimer(until: nowProvider().addingTimeInterval(seconds))
        }
    }

    func cancelInactivityTimer(clearDeadline: Bool = true) {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        inactivityTimerInterval = nil
        if clearDeadline {
            inactivityDeadline = nil
        }
    }

    func resetInactivityTimer() {
        guard case .unlocked = state else { return }
        startInactivityTimer()
    }

    func handleSceneDidEnterBackground() {
        guard case .unlocked = state else { return }

        if SettingsService.lockOnBackground {
            lockRequest()
            return
        }

        backgroundEnteredAt = nowProvider()
        cancelInactivityTimer(clearDeadline: false)
    }

    func handleSceneDidBecomeActive() {
        guard case .unlocked = state else { return }

        guard backgroundEnteredAt != nil else {
            resetInactivityTimer()
            return
        }

        backgroundEnteredAt = nil

        switch SettingsService.autoLockTimeout {
        case .never:
            startInactivityTimer()
        case .immediately:
            lockRequest()
        case .thirtySeconds, .oneMinute, .fiveMinutes:
            guard let inactivityDeadline else {
                startInactivityTimer()
                return
            }

            if nowProvider() >= inactivityDeadline {
                lockRequest()
            } else {
                scheduleInactivityTimer(until: inactivityDeadline)
            }
        }
    }

    private func scheduleInactivityTimer(until deadline: Date) {
        cancelInactivityTimer(clearDeadline: false)
        inactivityDeadline = deadline

        let remaining = deadline.timeIntervalSince(nowProvider())
        guard remaining > 0 else { return }

        inactivityTimerInterval = remaining
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lockRequest()
            }
        }
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
                let fingerprint = databaseReference.isCloudBacked
                    ? nil
                    : try Self.makeSharedCacheRefreshFingerprint(for: databaseReference)
                let refreshStart = Date.now
                let shouldRefresh = await MainActor.run { () -> Bool in
                    guard self.isRefreshingSharedCache == false else { return false }
                    if let fingerprint {
                        guard self.lastSharedCacheRefreshFingerprint != fingerprint else { return false }
                    } else if let lastSharedCacheRefreshAt = self.lastSharedCacheRefreshAt,
                              refreshStart.timeIntervalSince(lastSharedCacheRefreshAt) < Self.sharedCloudRefreshMinimumInterval {
                        return false
                    }
                    self.isRefreshingSharedCache = true
                    return true
                }
                guard shouldRefresh else { return }
                defer {
                    Task { @MainActor in
                        self.isRefreshingSharedCache = false
                    }
                }

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

                await MainActor.run {
                    self.lastSharedCacheRefreshFingerprint = fingerprint
                    self.lastSharedCacheRefreshAt = refreshStart
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

    func entryCount(forGroupID groupID: UUID) -> Int {
        _ = contentRevision
        return groupEntryCounts[groupID] ?? 0
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
        let formatVersion: KDBXParser.FileVersion
        let openTimeSHA512: Data
    }

    private func beginNewLockCycle() {
        lockCycleID += 1
    }

    private func rebuildDerivedState() {
        guard let root = currentRootGroup else {
            entryIndex = [:]
            groupIndex = [:]
            groupEntryCounts = [:]
            searchableEntries = []
            searchableEntryText = [:]
            recycleBinEntryIDs = []
            recycleBinGroupIDs = []
            searchResults = []
            contentRevision += 1
            selectedGroupID = nil
            selectedEntryID = nil
            return
        }

        var nextEntryIndex: [UUID: KPEntry] = [:]
        var nextGroupIndex: [UUID: KPGroup] = [:]
        var nextGroupEntryCounts: [UUID: Int] = [:]
        var nextSearchableEntries: [KPEntry] = []
        var nextSearchableEntryText: [UUID: String] = [:]
        var nextRecycleBinEntryIDs = Set<UUID>()
        var nextRecycleBinGroupIDs = Set<UUID>()
        let recycleBinID = root.recycleBinUUID

        @discardableResult
        func index(group: KPGroup, includeInSearch: Bool) -> Int {
            nextGroupIndex[group.id] = group
            if includeInSearch == false, group.id != recycleBinID {
                nextRecycleBinGroupIDs.insert(group.id)
            }

            var totalEntryCount = 0
            for entry in group.entries {
                nextEntryIndex[entry.id] = entry
                totalEntryCount += 1
                if includeInSearch {
                    nextSearchableEntries.append(entry)
                    nextSearchableEntryText[entry.id] = Self.searchText(for: entry)
                } else {
                    nextRecycleBinEntryIDs.insert(entry.id)
                }
            }

            for childGroup in group.groups {
                let childIncludedInSearch = includeInSearch && childGroup.id != recycleBinID
                totalEntryCount += index(group: childGroup, includeInSearch: childIncludedInSearch)
            }

            nextGroupEntryCounts[group.id] = totalEntryCount
            return totalEntryCount
        }

        index(group: root, includeInSearch: true)

        entryIndex = nextEntryIndex
        groupIndex = nextGroupIndex
        groupEntryCounts = nextGroupEntryCounts
        searchableEntries = nextSearchableEntries
        searchableEntryText = nextSearchableEntryText
        recycleBinEntryIDs = nextRecycleBinEntryIDs
        recycleBinGroupIDs = nextRecycleBinGroupIDs
        contentRevision += 1
        synchronizeSelections()
        updateSearchResults()
    }

    private func updateSearchResults() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            searchResults = []
            return
        }

        let query = trimmedQuery.lowercased()
        searchResults = searchableEntries.filter { entry in
            searchableEntryText[entry.id]?.contains(query) == true
        }
    }

    private func synchronizeSelections() {
        guard let visibleRootGroupID else {
            selectedGroupID = nil
            selectedEntryID = nil
            return
        }

        if let selectedGroupID, groupIndex[selectedGroupID] == nil {
            self.selectedGroupID = visibleRootGroupID
        } else if selectedGroupID == nil {
            selectedGroupID = visibleRootGroupID
        }

        if let selectedEntryID, entryIndex[selectedEntryID] == nil {
            self.selectedEntryID = nil
        }
    }

    private static func nestedGroupCount(in group: KPGroup) -> Int {
        group.groups.reduce(0) { count, childGroup in
            count + 1 + nestedGroupCount(in: childGroup)
        }
    }

    private static func group(_ group: KPGroup, containsGroupID groupID: UUID) -> Bool {
        group.id == groupID || group.groups.contains { Self.group($0, containsGroupID: groupID) }
    }

    private static func groupIDs(in group: KPGroup) -> Set<UUID> {
        group.groups.reduce(into: [group.id]) { ids, childGroup in
            ids.formUnion(groupIDs(in: childGroup))
        }
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
        lastSharedCacheRefreshFingerprint = nil
        isRefreshingSharedCache = false
        lastSharedCacheRefreshAt = nil
    }

    private func finalizeSuccessfulUnlock(
        payload: UnlockPayload,
        compositeKey: Data,
        sessionKey: SymmetricKey
    ) {
        self.rootGroup = payload.rootGroup
        self.compositeKey = compositeKey
        self.sessionKey = sessionKey
        self.unlockedMeta = payload.meta
        self.openedFormatVersion = payload.formatVersion
        self.openTimeSHA512 = payload.openTimeSHA512
        self.draft = nil
        self.saveError = nil
        self.saveConflict = nil
        self.pendingLockRequest = nil
        self.syncedFolderWarning = nil
        self.failedAttempts = 0
        self.lockoutUntil = nil
        self.state = .unlocked
        synchronizeSelections()
        startInactivityTimer()

        persistCompositeKeyForBiometricUnlock(compositeKey)
        DatabaseListStore.markDatabaseOpened(id: databaseReference.id)
        refreshDatabaseReference()
        populateCredentialStoreIfNeeded(root: payload.rootGroup)
        ReviewPromptService.requestReviewIfAppropriate()
    }

    private func handleUnlockFailure(_ error: Error, diagnostics: DatabaseOpenDiagnostics?) {
        let failure = DatabaseOpenFailure.classify(
            error,
            isCloudBacked: databaseReference.isCloudBacked,
            diagnostics: diagnostics
        )

        if failure.countsTowardFailedAttempts {
            failedAttempts += 1
            let delay = lockoutDelay
            if delay > 0 {
                lockoutUntil = Date.now.addingTimeInterval(delay)
                let seconds = Int(ceil(delay))
                state = .error(lockoutFailure(seconds: seconds, diagnostics: diagnostics))
                return
            }
        }

        state = .error(failure)
    }

    private func lockoutFailure(seconds: Int, diagnostics: DatabaseOpenDiagnostics? = nil) -> DatabaseOpenFailure {
        DatabaseOpenFailure(
            title: "Too Many Failed Attempts",
            summary: "KeeForge is temporarily slowing down unlock attempts. Try again in \(seconds) seconds.",
            technicalDetails: "Unlock temporarily rate-limited after repeated authentication failures.",
            errorCode: "auth.locked_out",
            category: .authentication,
            countsTowardFailedAttempts: false,
            canChooseDifferentFile: false,
            diagnostics: diagnostics
        )
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

    nonisolated private static func makeSharedCacheRefreshFingerprint(
        for reference: DatabaseReference
    ) throws -> SharedCacheRefreshFingerprint {
        if let metadata = reference.cloudSyncMetadata {
            return .cloud(
                fileID: metadata.fileId,
                remoteRev: metadata.remoteRev,
                remoteModifiedAt: metadata.remoteModifiedAt,
                lastSyncedAt: metadata.lastSyncedAt
            )
        }

        guard let url = DatabaseListStore.resolveDatabaseURL(for: reference) else {
            throw SaveError.databaseLocationUnavailable
        }

        return .local(
            url: url,
            modificationDate: try readSecurityScopedModificationDate(from: url)
        )
    }

    private static func searchText(for entry: KPEntry) -> String {
        [
            entry.title,
            entry.username,
            entry.url,
            entry.notes,
        ]
        .joined(separator: "\n")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
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

    private func makeUnlockDiagnostics(
        unlockMethod: DatabaseOpenDiagnostics.UnlockMethod,
        passwordSupplied: Bool,
        keyFileSupplied: Bool,
        failedAttemptsBeforeAttempt: Int,
        encryptedData: Data?,
        cloudSyncStatus: CloudSyncResolution.Status?
    ) -> DatabaseOpenDiagnostics {
        DatabaseOpenDiagnostics.make(
            reference: databaseReference,
            unlockMethod: unlockMethod,
            passwordSupplied: passwordSupplied,
            keyFileSupplied: keyFileSupplied,
            failedAttemptsBeforeAttempt: failedAttemptsBeforeAttempt,
            encryptedData: encryptedData,
            cloudSyncStatus: cloudSyncStatus
        )
    }

    private func readDatabaseData() async throws -> (url: URL, data: Data, cloudSyncStatus: CloudSyncResolution.Status?) {
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
            return (resolution.localURL, resolution.data, resolution.status)
        }

        cloudSyncBannerText = nil
        unlockStatusMessage = Self.decryptingStatusMessage

        if let url = DatabaseListStore.resolveDatabaseURL(for: databaseReference) {
            return (url, try readSecurityScoped(url: url), nil)
        }

        throw CocoaError(.fileReadNoSuchFile)
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

    private func refreshCredentialStoreForCurrentTreeIfNeeded() {
        guard case .unlocked = state else { return }
        guard let currentRootGroup else { return }
        populateCredentialStoreIfNeeded(root: currentRootGroup)
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
            guard let url = DatabaseListStore.resolveDatabaseURL(for: reference) else {
                throw SaveError.databaseLocationUnavailable
            }
            data = try readSecurityScopedData(from: url)
            updatedReference = reference
        }

        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try await Task.detached(priority: .utility) {
            try KDBXParser.parseWithMetaAndHeader(
                data: data,
                compositeKey: compositeKey,
                sessionKey: sessionKey
            )
        }.value

        return ReloadedDatabase(
            reference: updatedReference,
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            formatVersion: parsed.header.formatVersion,
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

    nonisolated private static func readSecurityScopedModificationDate(from url: URL) throws -> Date? {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
