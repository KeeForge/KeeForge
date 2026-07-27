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
    struct LocalDatabaseReadResult: Sendable {
        let url: URL
        let data: Data
    }

    struct ReloadedDatabase: Sendable {
        let reference: DatabaseReference
        let rootGroup: KPGroup
        let meta: KPMeta
        let formatVersion: KDBXParser.FileVersion
        let sessionKey: SymmetricKey
        let openTimeSHA512: Data
        let binaryPool: BinaryPool
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

        /// Localized display text. `rawValue` is persisted in `UserDefaults`
        /// and must stay stable (English) across locales.
        var title: String {
            switch self {
            case .title:
                String(localized: "Title")
            case .createdDate:
                String(localized: "Date Created")
            case .modifiedDate:
                String(localized: "Date Modified")
            }
        }
    }

    typealias CloudSyncOperation = @Sendable (
        _ reference: DatabaseReference,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CloudSyncResolution
    typealias LocalDatabaseReadOperation = @Sendable (DatabaseReference) async throws -> LocalDatabaseReadResult
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
    /// Shared with tests so status-message assertions stay locale-agnostic.
    static let decryptingStatusMessage = String(localized: "Decrypting your database securely...")
    private static let sharedCloudRefreshMinimumInterval: TimeInterval = 30
    private static let localDatabaseReadTimeout: Duration = .seconds(10)

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
    /// Whether the search query is empty after trimming whitespace, matching
    /// how `updateSearchResults()` decides there is nothing to search.
    var isSearchQueryEmpty: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                if selectedGroupID != nil {
                    selectedTag = nil
                }
            }
            resetInactivityTimer()
        }
    }
    /// The tag selected in the macOS sidebar's Tags section. Mutually exclusive
    /// with `selectedGroupID`: the sidebar shows exactly one selection, so
    /// setting either one clears the other (and the entry selection, the same
    /// way switching groups does). Tag identity is exact-string.
    var selectedTag: String? {
        didSet {
            if oldValue != selectedTag {
                selectedEntryID = nil
                if selectedTag != nil {
                    selectedGroupID = nil
                }
            }
            resetInactivityTimer()
        }
    }
    var selectedEntryID: UUID? {
        didSet { resetInactivityTimer() }
    }
    /// Incremented by the macOS menu-bar "New Entry" command (⌘N); the
    /// unlocked workspace observes it and presents the entry editor.
    private(set) var newEntryRequestID = 0
    /// Incremented by the macOS menu-bar "Find" command (⌘F); the group list
    /// observes it and focuses the search field.
    private(set) var searchFocusRequestID = 0
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
    /// Live (non-recycled) entries carrying each distinct tag, in tree order.
    /// Tag identity is exact-string, so `Work` and `work` are separate keys.
    private var tagEntryIDs: [String: [UUID]] = [:]
    /// The tags an entry stored directly in each group inherits: every ancestor
    /// group's tags, root-most first, then the group's own. Kept per group
    /// rather than per entry because inheritance resolves once per group; a
    /// group whose branch carries no tags is simply absent.
    private var groupInheritedTags: [UUID: [String]] = [:]
    /// The group each entry currently sits in, so an entry's inherited tags
    /// resolve without walking the tree a second time.
    private var entryParentGroupIDs: [UUID: UUID] = [:]
    private var recycleBinEntryIDs: Set<UUID> = []
    private var recycleBinGroupIDs: Set<UUID> = []
    /// Groups whose resolved `<EnableSearching>` is false, including the ones
    /// that only inherit it from an ancestor.
    private var autoFillExcludedGroupIDs: Set<UUID> = []
    private var lastSharedCacheRefreshFingerprint: SharedCacheRefreshFingerprint?
    private var isRefreshingSharedCache = false
    private var lastSharedCacheRefreshAt: Date?
    private var unlockedMeta: KPMeta?
    /// Decoded inner-header binary pool for the currently unlocked database.
    /// Cleared on lock; attachments are resolved against it lazily.
    private(set) var binaryPool: BinaryPool?
    private let cloudSyncOperation: CloudSyncOperation
    private let localDatabaseReadOperation: LocalDatabaseReadOperation
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
        localDatabaseReadOperation: @escaping LocalDatabaseReadOperation = { reference in
            try await DatabaseViewModel.readLocalDatabase(reference: reference)
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
        self.localDatabaseReadOperation = localDatabaseReadOperation
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
                openTimeSHA512: createdDatabase.openTimeSHA512,
                binaryPool: BinaryPool(rawFields: [])
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
            try cacheDatabaseCopyForLocalDatabase(data)

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
                    openTimeSHA512: KDBXCrypto.sha512(data),
                    binaryPool: BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
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
            let context = try await BiometricService.authenticate(reason: String(localized: "Unlock your password database"))
            let compositeKey = try retrieveStoredCompositeKey(context: context)
            let readResult = try await readDatabaseData()
            let data = readResult.data
            encryptedData = data
            cloudSyncStatus = readResult.cloudSyncStatus
            try cacheDatabaseCopyForLocalDatabase(data)
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
                    openTimeSHA512: KDBXCrypto.sha512(data),
                    binaryPool: BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
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

    func loadAssociatedKeyFile() async -> (data: Data, filename: String)? {
        let reference = databaseReference
        guard let associatedKeyFile = try? await CoordinatedFileReader.performBlocking(
            timeout: Self.localDatabaseReadTimeout,
            operation: { () throws -> (data: Data, filename: String)? in
                guard let url = DatabaseListStore.resolveKeyFileURL(for: reference) else { return nil }
                let hasSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard let data = try? CoordinatedFileReader.readData(from: url) else { return nil }
                return (data: data, filename: reference.keyFileFilename ?? url.lastPathComponent)
            }
        ) else { return nil }

        refreshDatabaseReference()
        return associatedKeyFile
    }

    func entry(withID entryID: UUID) -> KPEntry? {
        _ = contentRevision
        return entryIndex[entryID]
    }

    func group(withID groupID: UUID) -> KPGroup? {
        _ = contentRevision
        return groupIndex[groupID]
    }

    /// Every distinct tag carried by a live entry, unordered — callers sort for
    /// display. Recycled entries contribute nothing.
    var allTags: [String] {
        _ = contentRevision
        return Array(tagEntryIDs.keys)
    }

    /// `allTags` in the order the tag browser renders them: Finder-style
    /// case-insensitive, locale-aware, and numeric-aware, so `tag2` comes
    /// before `tag10` and case variants sit next to each other.
    ///
    /// `localizedStandardCompare` can call two distinct strings `.orderedSame`
    /// (it folds case and character width), and `sorted(by:)` is not a stable
    /// sort, so exact-string comparison breaks those ties. Without it two
    /// equivalent-but-different tags could swap places on every rebuild even
    /// though nothing about them changed.
    var tagsInDisplayOrder: [String] {
        allTags.sorted { lhs, rhs in
            switch lhs.localizedStandardCompare(rhs) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs < rhs
            }
        }
    }

    /// How many live entries carry `tag`, matched exact-string.
    func entryCount(forTag tag: String) -> Int {
        _ = contentRevision
        return tagEntryIDs[tag]?.count ?? 0
    }

    /// Live entries carrying `tag`, in tree order.
    func entries(withTag tag: String) -> [KPEntry] {
        _ = contentRevision
        return tagEntryIDs[tag]?.compactMap { entryIndex[$0] } ?? []
    }

    /// The tags an entry stored directly in `groupID` inherits: every ancestor
    /// group's tags, root-most first, then the group's own. Named from the
    /// entry's point of view — a group does not inherit its own tags, but an
    /// entry inside it effectively does, which is what the editor needs in
    /// order to stop suggesting tags the entry already carries by location.
    ///
    /// Empty for an unknown group and for one whose branch has no group tags.
    func inheritedTags(forGroupID groupID: UUID) -> [String] {
        _ = contentRevision
        return TagNormalizer.tags(from: groupInheritedTags[groupID] ?? [])
    }

    /// `inheritedTags(forGroupID:)` for the group currently holding `entryID` —
    /// what the entry gets from where it sits, excluding its own tags. Empty
    /// for an unknown entry.
    func inheritedTags(forEntryID entryID: UUID) -> [String] {
        _ = contentRevision
        guard let parentGroupID = entryParentGroupIDs[entryID] else { return [] }
        return inheritedTags(forGroupID: parentGroupID)
    }

    /// Decoded image data of the entry's custom icon, if the database defines
    /// one for it in `Meta/CustomIcons`.
    func customIconData(for entry: KPEntry) -> Data? {
        guard let uuid = entry.customIconUUID else { return nil }
        return unlockedMeta?.customIcons[uuid]
    }

    /// Decoded image data of the group's custom icon, if the database defines
    /// one for it in `Meta/CustomIcons`.
    func customIconData(for group: KPGroup) -> Data? {
        guard let uuid = group.customIconUUID else { return nil }
        return unlockedMeta?.customIcons[uuid]
    }

    /// Resolves and decodes attachment bytes for `attachment` against the
    /// currently unlocked database's inner-header binary pool. Decoding runs
    /// off the main thread; returns `nil` for dangling refs or when no
    /// database is unlocked.
    func attachmentData(for attachment: KPAttachment) async -> Data? {
        guard let binaryPool else { return nil }
        return await Task.detached(priority: .userInitiated) {
            binaryPool[attachment.ref]?.data
        }.value
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
        // Deselect only an entry that still exists (recycled with its group);
        // a permanently deleted one is handled as in `synchronizeSelections()`.
        if let selectedEntryID, affectedEntryIDs.contains(selectedEntryID),
           entryIndex[selectedEntryID] != nil {
            self.selectedEntryID = nil
        }
    }

    func createGroup(named name: String, in parentGroupID: UUID) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }
        try applyEntryEdit(.createGroup(parentGroupID: parentGroupID, name: trimmedName))
    }

    /// Whether AutoFill currently skips this group, taking an inherited
    /// `<EnableSearching>` from an ancestor into account. Resolved once per
    /// tree rebuild, like `isGroupInRecycleBin`.
    func isGroupExcludedFromAutoFill(groupID: UUID) -> Bool {
        _ = contentRevision
        return autoFillExcludedGroupIDs.contains(groupID)
    }

    /// True when the exclusion comes from an ancestor rather than from this
    /// group, so the UI can explain why a group is skipped without a toggle
    /// that looks broken.
    func isGroupExclusionInherited(groupID: UUID) -> Bool {
        _ = contentRevision
        guard groupIndex[groupID]?.searchingEnabled?.boolValue == nil else { return false }
        return autoFillExcludedGroupIDs.contains(groupID)
    }

    /// Changes which of the standard KDBX icons a group displays.
    ///
    /// Ignores an `iconID` outside the standard set: KDBX stores `<IconID>` as a
    /// bare integer, so an unmapped value would be written happily and then render
    /// as whatever fallback each client picks.
    ///
    /// Applies even when `iconID` already matches, as long as the group still
    /// carries a custom icon — that case is precisely the one where the standard
    /// icon isn't the one being shown, so it is not a no-op.
    func setGroupIcon(_ iconID: Int, groupID: UUID) throws {
        guard KPEntry.standardIconNames[iconID] != nil else { return }
        guard let group = groupIndex[groupID] else { return }
        guard group.iconID != iconID || group.customIconUUID != nil else { return }
        try applyEntryEdit(.setGroupIcon(groupID: groupID, iconID: iconID))
    }

    func setGroupExcludedFromAutoFill(_ excluded: Bool, groupID: UUID) throws {
        // Re-including writes an explicit `True` rather than `inherit`, so that
        // a group inside an excluded parent can actually be turned back on.
        try applyEntryEdit(
            .setGroupSearchingEnabled(
                groupID: groupID,
                value: excluded ? .disabled : .enabled
            )
        )
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

    /// Requests presenting the entry editor for the currently visible group.
    /// Used by the macOS menu-bar New Entry command.
    func requestNewEntry() {
        guard case .unlocked = state, isReadOnly == false else { return }
        newEntryRequestID += 1
    }

    /// Requests focusing the search field. Used by the macOS Find command.
    func requestSearchFocus() {
        guard case .unlocked = state else { return }
        searchFocusRequestID += 1
    }

    func lock(manuallyTriggered: Bool = false, preservingClipboard: Bool = false) {
        cancelInactivityTimer()
        backgroundEnteredAt = nil
        if manuallyTriggered {
            didManuallyLock = true
        }
        // Only iOS backgrounding sets `preservingClipboard`: the user is
        // switching apps to paste, so scrubbing there made every copy arrive
        // empty (#34). iOS bounds the secret anyway via the expiration date and
        // `.localOnly` that `ClipboardService.copy` stamps on. Every other lock
        // means the user walked away, so those still scrub — which matters most
        // on macOS, where neither flag exists (`docs/macos-security-notes.md`).
        if preservingClipboard == false {
            ClipboardService.clearOwnedContents()
        }
        beginNewLockCycle()
        state = .locked
        rootGroup = nil
        openedFormatVersion = nil
        compositeKey = nil
        sessionKey = nil
        unlockedMeta = nil
        binaryPool = nil
        draft = nil
        openTimeSHA512 = nil
        AttachmentPreviewFileStore.clearAll()
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
        selectedTag = nil
        selectedEntryID = nil
    }

    func lockRequest(
        force: Bool = false,
        manuallyTriggered: Bool = false,
        preservingClipboard: Bool = false
    ) {
        guard case .unlocked = state else {
            if force {
                lock(manuallyTriggered: manuallyTriggered, preservingClipboard: preservingClipboard)
            }
            return
        }

        if force || isDirty == false {
            discardDraft()
            lock(manuallyTriggered: manuallyTriggered, preservingClipboard: preservingClipboard)
            return
        }

        // A dirty draft defers the lock behind the discard/save confirmation,
        // which the user only resolves once they are back in KeeForge — no
        // lock has happened yet, so the copy survives the trip regardless, and
        // resolving it in the foreground should scrub like any other
        // in-app lock. `preservingClipboard` deliberately does not carry over.
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
        // Reentry guard: `isDirty` stays true for the whole in-flight save, so
        // a repeated ⌘S would start a second one racing the same open-time SHA
        // and rev, losing into an unearned conflict dialog. Silent no-op — the
        // in-flight save is already doing what the caller asked for.
        guard isSaving == false else { return }
        guard let draft else { return }
        guard draft.isDirty else { return }
        guard let compositeKey, let openTimeSHA512 else {
            throw SaveError.saveContextUnavailable
        }

        // The awaits below outlast a lock: applying their result to a locked
        // session would resurrect `rootGroup`/`unlockedMeta` behind the lock
        // screen. Same guard shape as `refreshCredentialStoreIfStillUnlocked`.
        let expectedLockCycleID = lockCycleID

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

        // Locked while the save was in flight: the bytes did reach storage, and
        // the next unlock reads them back, so there is nothing to apply here.
        guard expectedLockCycleID == lockCycleID else { return }

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
        selectedTag = nil
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
        binaryPool = reloaded.binaryPool
        AttachmentPreviewFileStore.clearAll()
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
            // Scene phase cannot tell an app switch from a device lock, so iOS
            // keeps the pasteboard (#34) and a copy can outlive a screen lock
            // by up to the clipboard-clear timeout. On macOS this entry point
            // comes from `MacLockMonitor`, which only fires when the user
            // walked away — scrub there.
            #if os(iOS)
            lockRequest(preservingClipboard: true)
            #else
            lockRequest()
            #endif
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
                    let observedCloudMetadata = databaseReference.cloudSyncMetadata
                    let resolution = try await CloudSyncCoordinator.syncIfNeededForOpen(reference: databaseReference)
                    data = resolution.data

                    // Storing `resolution.reference` wholesale would revert a
                    // save or drain that landed during the round-trip, and the
                    // next save would conflict against the app's own upload.
                    // Merge only the sync fields learned here, and only while
                    // the stored state is unchanged (see
                    // `DatabaseListStore.updateCloudSyncMetadata`).
                    let mergedReference = observedCloudMetadata.flatMap { observed in
                        DatabaseListStore.updateCloudSyncMetadata(
                            for: resolution.reference.id,
                            ifUnchangedFrom: observed
                        ) { storedMetadata in
                            guard let learned = resolution.reference.cloudSyncMetadata else { return }
                            storedMetadata.remoteContentHash = learned.remoteContentHash
                            storedMetadata.remoteModifiedAt = learned.remoteModifiedAt
                            storedMetadata.remoteRev = learned.remoteRev
                            storedMetadata.lastSyncedAt = learned.lastSyncedAt
                            storedMetadata.lastSyncError = learned.lastSyncError
                        }
                    }

                    await MainActor.run {
                        guard self.databaseReference.id == resolution.reference.id else { return }
                        self.cloudSyncBannerText = resolution.bannerMessage
                        // Nil means skipped or unpersisted: keep the current
                        // reference so the next sync redoes the work rather
                        // than trusting an unsaved rev.
                        if let mergedReference {
                            self.databaseReference = mergedReference
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
        let entries = root.autoFillEntries(excludingGroupID: root.recycleBinUUID)
        return entries.filter { !$0.isExpired() && ($0.hasPassword || $0.hasPasskey) }
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

    /// Shared with tests so status-message assertions stay locale-agnostic.
    static func syncStatusMessage(for reference: DatabaseReference) -> String {
        let providerName = reference.cloudProviderKind?.displayName ?? String(localized: "cloud")
        return String(localized: "Syncing with \(providerName)...")
    }

    private struct UnlockPayload: Sendable {
        let rootGroup: KPGroup
        let meta: KPMeta
        let formatVersion: KDBXParser.FileVersion
        let openTimeSHA512: Data
        let binaryPool: BinaryPool
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
            tagEntryIDs = [:]
            groupInheritedTags = [:]
            entryParentGroupIDs = [:]
            recycleBinEntryIDs = []
            recycleBinGroupIDs = []
            autoFillExcludedGroupIDs = []
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
        var nextTagEntryIDs: [String: [UUID]] = [:]
        var nextGroupInheritedTags: [UUID: [String]] = [:]
        var nextEntryParentGroupIDs: [UUID: UUID] = [:]
        var nextRecycleBinEntryIDs = Set<UUID>()
        var nextRecycleBinGroupIDs = Set<UUID>()
        var nextAutoFillExcludedGroupIDs = Set<UUID>()
        let recycleBinID = root.recycleBinUUID

        @discardableResult
        func index(group: KPGroup, includeInSearch: Bool, autoFillEnabled: Bool, inheritedTags: [String]) -> Int {
            nextGroupIndex[group.id] = group
            if includeInSearch == false, group.id != recycleBinID {
                nextRecycleBinGroupIDs.insert(group.id)
            }

            // Mirrors `KPGroup.autoFillEntries`: an absent element or `.inherit`
            // takes the parent's answer, an explicit value overrides it.
            let resolvedAutoFillEnabled = group.searchingEnabled?.boolValue ?? autoFillEnabled
            if resolvedAutoFillEnabled == false {
                nextAutoFillExcludedGroupIDs.insert(group.id)
            }

            // Group tags resolve once per GROUP, never per entry: this group's
            // own tags append to the ancestors' accumulated list (root-most
            // first), and the result feeds every live entry below. A recycled
            // subtree still accumulates, but its entries never take the
            // `includeInSearch` branch, so recycle-bin-only tags (including
            // the bin group's own) never reach the tag index or search text.
            let accumulatedTags = group.tags.isEmpty ? inheritedTags : inheritedTags + group.tags
            // Only branches that actually carry a group tag get an entry, so
            // the common untagged database stores nothing here. Recycled
            // groups are recorded too: the editor asks about live locations
            // only, and skipping them would need a second condition to earn
            // nothing.
            if accumulatedTags.isEmpty == false {
                nextGroupInheritedTags[group.id] = accumulatedTags
            }

            var totalEntryCount = 0
            for entry in group.entries {
                nextEntryIndex[entry.id] = entry
                nextEntryParentGroupIDs[entry.id] = group.id
                totalEntryCount += 1
                if includeInSearch {
                    nextSearchableEntries.append(entry)
                    let tags = Self.effectiveTags(for: entry, inheritedGroupTags: accumulatedTags)
                    nextSearchableEntryText[entry.id] = Self.searchText(for: entry, tags: tags)
                    for tag in tags {
                        nextTagEntryIDs[tag, default: []].append(entry.id)
                    }
                } else {
                    nextRecycleBinEntryIDs.insert(entry.id)
                }
            }

            for childGroup in group.groups {
                let childIncludedInSearch = includeInSearch && childGroup.id != recycleBinID
                totalEntryCount += index(
                    group: childGroup,
                    includeInSearch: childIncludedInSearch,
                    autoFillEnabled: resolvedAutoFillEnabled,
                    inheritedTags: accumulatedTags
                )
            }

            nextGroupEntryCounts[group.id] = totalEntryCount
            return totalEntryCount
        }

        index(group: root, includeInSearch: true, autoFillEnabled: true, inheritedTags: [])

        entryIndex = nextEntryIndex
        groupIndex = nextGroupIndex
        groupEntryCounts = nextGroupEntryCounts
        searchableEntries = nextSearchableEntries
        searchableEntryText = nextSearchableEntryText
        tagEntryIDs = nextTagEntryIDs
        groupInheritedTags = nextGroupInheritedTags
        entryParentGroupIDs = nextEntryParentGroupIDs
        recycleBinEntryIDs = nextRecycleBinEntryIDs
        recycleBinGroupIDs = nextRecycleBinGroupIDs
        autoFillExcludedGroupIDs = nextAutoFillExcludedGroupIDs
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

        let query = trimmedQuery
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        searchResults = searchableEntries.filter { entry in
            searchableEntryText[entry.id]?.contains(query) == true
        }
    }

    private func synchronizeSelections() {
        guard let visibleRootGroupID else {
            selectedGroupID = nil
            selectedTag = nil
            selectedEntryID = nil
            return
        }

        // A tag stops existing the moment its last live carrier is edited,
        // deleted, or recycled. Drop the selection first so the group fallback
        // below picks the sidebar back up.
        if let selectedTag, tagEntryIDs[selectedTag] == nil {
            self.selectedTag = nil
        }

        if let selectedGroupID, groupIndex[selectedGroupID] == nil {
            self.selectedGroupID = visibleRootGroupID
        } else if selectedGroupID == nil, selectedTag == nil {
            // Only fall back to the root when nothing else is selected — a tag
            // selection deliberately leaves `selectedGroupID` nil, and snapping
            // it back here would clear the tag on the next rebuild.
            selectedGroupID = visibleRootGroupID
        }

        // A vanished entry's selection is left for the mounted `EntryDetailView`
        // to clear via `onClose`. Clearing it here unmounts the detail column in
        // the same update that deletes the entry, tearing down the entry
        // editor's presentation host while the editor is still pushed.
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
        binaryPool = nil
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
        self.binaryPool = payload.binaryPool
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
            title: String(localized: "Too Many Failed Attempts"),
            summary: String(localized: "KeeForge is temporarily slowing down unlock attempts. Try again in \(seconds) seconds."),
            technicalDetails: "Unlock temporarily rate-limited after repeated authentication failures.",
            errorCode: "auth.locked_out",
            category: .authentication,
            countsTowardFailedAttempts: false,
            canChooseDifferentFile: false,
            diagnostics: diagnostics
        )
    }

    private func persistCompositeKeyForBiometricUnlock(_ compositeKey: Data) {
        // Silently skip when `.biometryCurrentSet` cannot be satisfied — no
        // enrolled biometrics is the common Mac desktop case (no Touch ID, or
        // Touch ID never enrolled). `BiometricService.isAvailable` is false in
        // exactly those situations, so password unlock stays primary, nothing
        // is stored, no error is surfaced, and there are no retry loops.
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

    /// The tags an entry contributes to the tag index and to its searchable
    /// text — its "effective tags": the entry's own tags first (source
    /// order), then every ancestor group's tags (root-most ancestor first),
    /// exact-string deduped keeping the first occurrence. The single seam
    /// both readers go through, so the index and search can never disagree
    /// about an entry's tags. Slice 04's suggestion exclusions consume this
    /// same own-first ordering.
    private static func effectiveTags(for entry: KPEntry, inheritedGroupTags: [String]) -> [String] {
        TagNormalizer.tags(from: entry.tags + inheritedGroupTags)
    }

    private static func searchText(for entry: KPEntry, tags: [String]) -> String {
        ([
            entry.title,
            entry.username,
            entry.url,
            entry.notes,
        ] + tags)
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

        let result = try await localDatabaseReadOperation(databaseReference)
        return (result.url, result.data, nil)
    }

    nonisolated private static func readLocalDatabase(
        reference: DatabaseReference
    ) async throws -> LocalDatabaseReadResult {
        try await CoordinatedFileReader.performBlocking(timeout: localDatabaseReadTimeout) {
            guard let location = DatabaseListStore.locateDatabaseFile(for: reference) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard case .available(let url) = location else {
                throw DatabaseListStore.LocalDatabaseFileError.databaseInTrash
            }

            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            return LocalDatabaseReadResult(
                url: url,
                data: try CoordinatedFileReader.readData(from: url)
            )
        }
    }

    private func populateCredentialStoreIfNeeded(root: KPGroup) {
        guard SettingsService.quickAutoFillEnabled else { return }
        // Check the persisted registry (not just the in-memory copy, which can
        // be stale after the list screen toggles the flag): a database with
        // AutoFill disabled must neither claim the active pointer nor publish
        // identities — whatever database last populated the credential store
        // keeps its suggestions untouched.
        let currentReference = DatabaseListStore.databases
            .first { $0.id == databaseReference.id } ?? databaseReference
        guard currentReference.autoFillEnabled else { return }
        DatabaseListStore.activeAutoFillDatabaseID = databaseReference.id
        CredentialIdentityStoreManager.populate(
            with: Self.credentialStoreEntries(from: root),
            for: databaseReference.id
        )
    }

    /// Refreshes the shared AutoFill cache after an unlock read — local
    /// databases only. Cloud-backed unlocks read `data` FROM that cache, so
    /// rewriting it is redundant and unsafe: an AutoFill save landing between
    /// the coordinator's read and this write would be reverted with no backup,
    /// since only the coordinator's paths honor the pending-marker gate. Local
    /// databases never have markers, so the plain rewrite is safe there.
    private func cacheDatabaseCopyForLocalDatabase(_ data: Data) throws {
        guard databaseReference.isCloudBacked == false else { return }
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

    func conflictCopyFilename(for filename: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // Seconds, not minutes: two conflict resolutions a few seconds apart
        // otherwise produce the same name, and the second copy would land on
        // the first — destroying the exact bytes this feature exists to keep.
        formatter.dateFormat = "yyyy-MM-dd HHmmss"

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
            let originalURL: URL
            let usesSecurityScope: Bool
            if reference.bookmarkData == nil {
                // App-only databases live in the shared cache; the conflict
                // copy lands next to it, where the database itself is read.
                originalURL = DatabaseListStore.cacheLocation(for: reference)
                usesSecurityScope = false
            } else {
                // A bookmarked database must resolve to a usable file — the
                // cache directory is not user-visible, so writing the copy
                // there would silently strand it. Failing keeps the draft
                // alive for the user to retry.
                guard let location = DatabaseListStore.locateDatabaseFile(for: reference) else {
                    throw SaveError.databaseLocationUnavailable
                }
                guard case .available(let url) = location else {
                    throw DatabaseListStore.LocalDatabaseFileError.databaseInTrash
                }
                originalURL = url
                usesSecurityScope = true
            }
            let hasSecurityScope = usesSecurityScope ? originalURL.startAccessingSecurityScopedResource() : false
            defer {
                if hasSecurityScope {
                    originalURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = Self.availableConflictCopyURL(
                in: originalURL.deletingLastPathComponent(),
                filename: filename
            )
            try CoordinatedFileReader.writeData(
                bytes,
                to: destinationURL,
                options: .atomicProtected
            )
        }.value
    }

    /// Writes the conflict copy create-only: it exists to preserve bytes, so
    /// it must never overwrite. Do not go back to `upload(expectedRev: nil)` —
    /// that is `WriteMode.overwrite` on Dropbox and `conflictBehavior=replace`
    /// on OneDrive, and it destroyed an earlier copy of the same name.
    /// `createFile` is required to be no-overwrite (`Cloud/README.md`) and
    /// reports a collision as `.conflict`, which the retry answers by
    /// numbering the name. `providerResolver` is injectable only so tests can
    /// exercise this routing without a live provider.
    static func writeConflictCopyToCloud(
        reference: DatabaseReference,
        fileID: String,
        bytes: Data,
        providerResolver: (String) -> CloudProvider? = CloudProviderRegistry.provider(for:)
    ) async throws {
        guard let metadata = reference.cloudSyncMetadata else {
            throw SaveError.saveContextUnavailable
        }

        guard let provider = providerResolver(metadata.provider) else {
            throw CloudProviderError.notAuthenticated
        }

        for attempt in 1...conflictCopyNameAttemptLimit {
            let path = attempt == 1 ? fileID : uniquifiedConflictCopyName(fileID, attempt: attempt)
            do {
                _ = try await provider.createFile(
                    accountId: metadata.accountId,
                    path: path,
                    data: bytes,
                    progress: { _ in }
                )
                return
            } catch let error as CloudProviderError {
                guard case .conflict = error, attempt < conflictCopyNameAttemptLimit else {
                    throw error
                }
            }
        }

        throw CloudProviderError.conflict(remoteRev: nil)
    }

    /// How many numbered names a conflict copy may try before giving up.
    /// Reaching it needs 20 copies of one database within a single second.
    nonisolated private static let conflictCopyNameAttemptLimit = 20

    /// Inserts ` <attempt>` ahead of the extension (`… 143012).kdbx` becomes
    /// `… 143012) 2.kdbx`). Works on a bare filename or a full provider path.
    nonisolated private static func uniquifiedConflictCopyName(_ name: String, attempt: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let numberedStem = "\(stem) \(attempt)"
        return ext.isEmpty ? numberedStem : "\(numberedStem).\(ext)"
    }

    /// Picks a free name for a local conflict copy. Same no-overwrite rule as
    /// the cloud path, expressed as a search because
    /// `CoordinatedFileReader.writeData` replaces whatever is there. The
    /// check-then-write window is inherent without `O_EXCL`.
    nonisolated private static func availableConflictCopyURL(in directory: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let preferredURL = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        var lastCandidate = preferredURL
        for attempt in 2...conflictCopyNameAttemptLimit {
            lastCandidate = directory.appendingPathComponent(
                uniquifiedConflictCopyName(filename, attempt: attempt)
            )
            if fileManager.fileExists(atPath: lastCandidate.path) == false {
                return lastCandidate
            }
        }
        return lastCandidate
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
            guard let location = DatabaseListStore.locateDatabaseFile(for: reference) else {
                throw SaveError.databaseLocationUnavailable
            }
            guard case .available(let url) = location else {
                throw DatabaseListStore.LocalDatabaseFileError.databaseInTrash
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
            openTimeSHA512: KDBXCrypto.sha512(data),
            binaryPool: BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
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
