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
            case .rekeyVerificationFailed, .rekeyAppliedRemotely:
                self = .unknown(saveError.localizedDescription)
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

/// Why `DatabaseViewModel.mergeAndSave` produced no write. Every case leaves
/// the draft and the conflict untouched, so the user still has Reload and Save
/// as Conflict Copy.
///
/// Declared outside the view model so the off-main merge can throw it.
enum DatabaseMergeFailure: String, Error, Identifiable, Equatable, Sendable {
    /// The other copy would not open with this database's master key, or is a
    /// KDBX 3.1 file the writer cannot produce.
    case remoteUnreadable
    /// The two files store attachments differently and something points into
    /// the pool, so grafted references could resolve to other bytes.
    case attachmentsDiverged
    /// State the merge needs is missing — no unlocked session, no conflict to
    /// merge, or a save already in flight.
    case sessionUnavailable

    var id: String { rawValue }

    var message: String {
        switch self {
        case .remoteUnreadable:
            String(localized: "The other copy of this database could not be opened. It may use a different master key, or be an older KDBX 3.1 file. Reload the database or save your changes as a conflict copy instead.")
        case .attachmentsDiverged:
            String(localized: "The two copies store their attachments differently, so merging them could point an attachment at the wrong file. Reload the database or save your changes as a conflict copy instead.")
        case .sessionUnavailable:
            String(localized: "This database is not ready to merge right now. Reload it or save your changes as a conflict copy instead.")
        }
    }
}

/// Whether lifecycle-triggered biometric auto-unlock is allowed on this
/// platform. Only iOS on its own hardware qualifies: everywhere else
/// `scenePhase == .active` fails to prove the window is frontmost when a lock
/// cycle begins, so those platforms rely on the explicit biometric action in
/// `UnlockView` instead.
enum BiometricAutoUnlockPolicy {
    static var allowsAutomaticUnlock: Bool {
        #if os(iOS)
        var isiOSAppOnVision = false
        if #available(iOS 26.1, *) {
            isiOSAppOnVision = ProcessInfo.processInfo.isiOSAppOnVision
        }
        return allowsAutomaticUnlock(
            isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            isiOSAppOnVision: isiOSAppOnVision
        )
        #else
        // The native Mac app never auto-unlocks. `MacLockMonitor` starts its
        // lock cycles from screen lock, screensaver, sleep, user switching and
        // — under the strict policy — app deactivation, all delivered
        // synchronously while the scene can still report `.active`, so the
        // attempt in `View.biometricAutoUnlock(_:)` would raise a Touch ID
        // prompt for a Mac the user just walked away from, and
        // `.promptUnavailable` hands the cycle its attempt back so it repeats.
        // Touch ID stays one click away in `UnlockView`, and
        // `SettingsService.autoUnlockWithFaceID` still governs the Mac
        // AutoFill extension.
        return false
        #endif
    }

    static func allowsAutomaticUnlock(isiOSAppOnMac: Bool, isiOSAppOnVision: Bool) -> Bool {
        !isiOSAppOnMac && !isiOSAppOnVision
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
        /// Which unsaved state is holding the lock, and so which UI owns the
        /// decision: only the editor can resolve its own fields.
        enum Reason: String, Equatable, Sendable {
            case openEditor
            case draft
        }

        let manuallyTriggered: Bool
        let reason: Reason

        var requiresAuthenticationToContinueEditing: Bool {
            manuallyTriggered == false
        }

        var id: String {
            "\(manuallyTriggered ? "manual" : "automatic").\(reason.rawValue)"
        }
    }

    struct GroupDeletionSummary: Equatable, Sendable {
        let name: String
        let entryCount: Int
        let nestedGroupCount: Int
    }

    /// One row of the "Move to Group" picker: a group that can receive the
    /// moved item, with its tree depth for indentation. The current parent is
    /// flagged rather than omitted so the picker can show where the item
    /// already lives instead of presenting a hole in the tree.
    struct MoveDestinationOption: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let depth: Int
        let isCurrentParent: Bool
    }

    enum State: Sendable, Equatable {
        case locked
        case unlocking
        case unlocked
        case error(DatabaseOpenFailure)
    }

    enum BiometricUnlockOutcome: Sendable, Equatable {
        case unlocked
        case failed
        /// LocalAuthentication refused to present its prompt because the app
        /// was not foreground-active (`LAError.notInteractive`). Nothing was
        /// shown to the user, so the database stays locked and the caller may
        /// try again once the scene activates.
        case promptUnavailable
        /// The user picked the password fallback inside the biometric prompt.
        case passwordFallback
    }

    /// Typed rejection reasons for `changeMasterKey`. Presentation strings are
    /// the caller's responsibility.
    enum RekeyError: Error, Equatable, Sendable {
        case sessionUnavailable
        case databaseIsReadOnly
        case saveInProgress
        case unsavedChanges
        case missingKeyComponent
        case pendingUploadsExist
        case conflict
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
        _ compositeKey: SymmetricKey,
        _ openTimeSHA512: Data,
        _ reconciledRemoteSHA512: Data?,
        _ newCompositeKey: SymmetricKey?
    ) async throws -> SaveResult
    typealias CloudSaveOperation = @Sendable (
        _ draft: DatabaseDraft,
        _ reference: DatabaseReference,
        _ compositeKey: SymmetricKey,
        _ openTimeSHA512: Data,
        _ reconciledRemoteSHA512: Data?,
        _ expectedRev: String?,
        _ newCompositeKey: SymmetricKey?
    ) async throws -> SaveResult
    typealias ConflictCopyEncryptionOperation = @Sendable (
        _ draft: DatabaseDraft,
        _ compositeKey: SymmetricKey,
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
        _ compositeKey: SymmetricKey
    ) async throws -> ReloadedDatabase
    /// Biometric authentication plus the keychain read it gates, as one step:
    /// the `LAContext` that authorizes the read never leaves the operation.
    typealias BiometricCompositeKeyOperation = @Sendable (
        _ reference: DatabaseReference,
        _ reason: String
    ) async throws -> SymmetricKey
    typealias PendingUploadMarkerCheck = @Sendable (_ reference: DatabaseReference) -> Bool
    typealias StoredKeyPresenceCheck = @Sendable (_ reference: DatabaseReference) -> Bool
    typealias StoredKeyStoreOperation = @Sendable (_ compositeKey: SymmetricKey, _ reference: DatabaseReference) throws -> Void
    typealias StoredKeyDeleteOperation = @Sendable (_ reference: DatabaseReference) -> Void
    /// Injected so tests can drive the no-authentication-available branch.
    typealias DeviceOwnerAuthAvailabilityCheck = @MainActor () -> Bool

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
    /// Incremented by the macOS menu-bar "New Group" command (⇧⌘N); the
    /// unlocked workspace observes it and presents the new-group sheet.
    private(set) var newGroupRequestID = 0
    /// Incremented by the macOS menu-bar "Edit Entry" command (⌘E); the
    /// unlocked workspace observes it and opens the editor on the selection.
    private(set) var editEntryRequestID = 0
    /// Incremented by the macOS menu-bar "Delete" command (⌘⌫); the unlocked
    /// workspace observes it and raises the shared delete confirmation.
    private(set) var deleteSelectionRequestID = 0
    var sortOrder: SortOrder {
        didSet { Self.persistSortOrder(sortOrder) }
    }

    private(set) var failedAttempts = 0
    private(set) var lockoutUntil: Date?
    private(set) var compositeKey: SymmetricKey?
    private(set) var sessionKey: SymmetricKey? {
        didSet { fieldReferenceResolver = nil }
    }
    /// Key file supplied manually at password unlock. The reference's
    /// association is the usual key-file source, but a manual pick never
    /// persists one, and the session otherwise retains only the derived
    /// composite key — losing the fact that the master key includes a key
    /// file, which "keep current key file" in the rekey flow must preserve.
    private(set) var sessionKeyFileData: Data?
    var draft: DatabaseDraft? {
        didSet { rebuildDerivedState() }
    }
    private(set) var contentRevision = 0
    private(set) var searchResults: [KPEntry] = []
    private(set) var openTimeSHA512: Data?
    private(set) var saveError: DatabaseSaveError?
    private(set) var saveConflict: SaveConflict?
    /// Why the last merge attempt wrote nothing, awaiting acknowledgement.
    /// `saveConflict` is deliberately left standing alongside it: dismissing
    /// this hands the user back the Reload / Save-as-Copy options rather than
    /// leaving them at a dead end.
    private(set) var mergeFailure: DatabaseMergeFailure?
    /// Confirmation text for a merge that did write, awaiting acknowledgement.
    private(set) var mergeSummaryMessage: String?
    private(set) var isSaving = false
    private(set) var pendingLockRequest: PendingLockRequest?
    /// Open editors holding fields the draft has not seen. Without this a lock
    /// trigger tears the editor down and drops the typing with no prompt.
    private var unsavedEditorIDs: Set<UUID> = []
    private(set) var cloudSyncProgress: Double?
    private(set) var cloudSyncBannerText: String?
    private(set) var unlockStatusMessage: String
    private var entryIndex: [UUID: KPEntry] = [:]
    /// Built on first use over `currentRootGroup` + `sessionKey`; dropped with
    /// `entryIndex` (`rebuildDerivedState`) and whenever the session key changes.
    @ObservationIgnored private var fieldReferenceResolver: FieldReferenceResolver?
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
    /// Ancestor group names below the visible root per entry, joined with
    /// " / ". Entries sitting directly under the visible root are absent.
    private var entryFolderPaths: [UUID: String] = [:]
    private var recycleBinEntryIDs: Set<UUID> = []
    private var recycleBinGroupIDs: Set<UUID> = []
    /// Groups whose resolved `<EnableSearching>` is false, including the ones
    /// that only inherit it from an ancestor. Skipped by AutoFill and the
    /// in-app search; still shown when browsing.
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
    private let biometricCompositeKeyOperation: BiometricCompositeKeyOperation
    private let pendingUploadMarkerCheck: PendingUploadMarkerCheck
    private let storedKeyPresenceCheck: StoredKeyPresenceCheck
    private let storedKeyStoreOperation: StoredKeyStoreOperation
    private let storedKeyDeleteOperation: StoredKeyDeleteOperation
    private let deviceOwnerAuthAvailabilityCheck: DeviceOwnerAuthAvailabilityCheck
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
        localSaveOperation: @escaping LocalSaveOperation = { draft, reference, compositeKey, openTimeSHA512, reconciledRemoteSHA512, newCompositeKey in
            try await LocalDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                reconciledRemoteSHA512: reconciledRemoteSHA512,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey
            )
        },
        cloudSaveOperation: @escaping CloudSaveOperation = { draft, reference, compositeKey, openTimeSHA512, reconciledRemoteSHA512, expectedRev, newCompositeKey in
            try await CloudDatabaseSaver.save(
                draft: draft,
                reference: reference,
                compositeKey: compositeKey,
                openTimeSHA512: openTimeSHA512,
                reconciledRemoteSHA512: reconciledRemoteSHA512,
                expectedRev: expectedRev,
                kdfPolicy: .mainApp,
                newCompositeKey: newCompositeKey
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
        biometricCompositeKeyOperation: @escaping BiometricCompositeKeyOperation = { reference, reason in
            let context = try await BiometricService.authenticate(reason: reason)
            return try DatabaseViewModel.retrieveStoredCompositeKey(for: reference, context: context)
        },
        pendingUploadMarkerCheck: @escaping PendingUploadMarkerCheck = { reference in
            PendingUploadQueue.listMarkers(for: reference.id).isEmpty == false
        },
        storedKeyPresenceCheck: @escaping StoredKeyPresenceCheck = { reference in
            KeychainService.hasStoredKey(for: reference.id, legacyFilename: reference.legacyKeychainFilename)
        },
        storedKeyStoreOperation: @escaping StoredKeyStoreOperation = { compositeKey, reference in
            try KeychainService.storeCompositeKey(compositeKey, for: reference.id)
        },
        storedKeyDeleteOperation: @escaping StoredKeyDeleteOperation = { reference in
            KeychainService.deleteCompositeKey(for: reference.id)
        },
        deviceOwnerAuthAvailabilityCheck: @escaping DeviceOwnerAuthAvailabilityCheck = {
            BiometricService.canAuthenticateDeviceOwner
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
        self.biometricCompositeKeyOperation = biometricCompositeKeyOperation
        self.pendingUploadMarkerCheck = pendingUploadMarkerCheck
        self.storedKeyPresenceCheck = storedKeyPresenceCheck
        self.storedKeyStoreOperation = storedKeyStoreOperation
        self.storedKeyDeleteOperation = storedKeyDeleteOperation
        self.deviceOwnerAuthAvailabilityCheck = deviceOwnerAuthAvailabilityCheck
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

    /// `Meta` as the UI has to see it, the draft's taking precedence — the
    /// counterpart of `currentRootGroup`, and for the same reason.
    ///
    /// `unlockedMeta` is only refreshed by a *successful* save. Reading it
    /// directly means a save that fails — offline, conflicted — leaves a custom
    /// icon that is in the draft unresolvable: the entry falls back to a
    /// standard icon and the picker omits the image, so a download that worked
    /// looks like one that did nothing.
    var currentMeta: KPMeta? {
        draft?.meta ?? unlockedMeta
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

    /// One-tap cleanup offered only for a Documents-resident database whose
    /// file is genuinely gone from the Documents folder (Finder delete);
    /// every other open failure keeps the standard recovery actions.
    /// Evaluated once when the open failure is recorded — not per render —
    /// and cleared whenever the failure is; `removeMissingDocumentsDatabase`
    /// re-verifies before acting, so a file restored while the failure screen
    /// is up is still safe.
    private(set) var canRemoveMissingDocumentsFile = false

    /// Same cleanup as a manual list removal: cached copy, backups, Keychain
    /// key, pending-upload markers, and AutoFill identities all go with it.
    /// No-op when the file reappeared since the failure was recorded.
    func removeMissingDocumentsDatabase() {
        guard DatabaseListStore.isDocumentsFileMissing(for: databaseReference) else {
            canRemoveMissingDocumentsFile = false
            return
        }
        DatabaseListStore.remove(id: databaseReference.id)
    }

    private func evaluateMissingDocumentsFileRemoval(for failure: DatabaseOpenFailure) -> Bool {
        guard failure.errorCode == "file.not_found" || failure.errorCode == "file.in_recently_deleted",
              databaseReference.isDocumentsResident else {
            return false
        }
        return DatabaseListStore.isDocumentsFileMissing(for: databaseReference)
    }

    var canUseBiometrics: Bool {
        guard BiometricService.isAvailable else { return false }
        return KeychainService.hasStoredKey(
            for: databaseReference.id,
            legacyFilename: databaseReference.legacyKeychainFilename
        )
    }

    /// Whether this session should open itself with biometrics instead of
    /// showing the unlock form. Always false where `BiometricAutoUnlockPolicy`
    /// disallows lifecycle prompts; the attempt itself additionally requires a
    /// foreground-active scene — see `View.biometricAutoUnlock(_:)`.
    var isEligibleForBiometricAutoUnlock: Bool {
        guard BiometricAutoUnlockPolicy.allowsAutomaticUnlock else { return false }
        guard SettingsService.autoUnlockWithFaceID else { return false }
        guard hasSavedFile else { return false }
        guard canUseBiometrics else { return false }
        guard didManuallyLock == false else { return false }
        guard case .locked = state else { return false }
        return true
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
            canRemoveMissingDocumentsFile = false
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

            let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
            let sessionKey = SymmetricKey(size: .bits256)

            let unlockPayload = try await Task.detached(priority: .userInitiated) {
                let parsed = try KDBXParser.parseWithMetaAndHeader(
                    data: data,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey,
                    kdfPolicy: .mainApp
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
            sessionKeyFileData = keyFileData
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

    @discardableResult
    func unlockWithBiometrics() async -> BiometricUnlockOutcome {
        let failedAttemptsBeforeAttempt = failedAttempts
        prepareForUnlock()

        var encryptedData: Data?
        var cloudSyncStatus: CloudSyncResolution.Status?

        do {
            let compositeKey = try await biometricCompositeKeyOperation(
                databaseReference,
                String(localized: "Unlock your password database")
            )
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
                    sessionKey: sessionKey,
                    kdfPolicy: .mainApp
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
            return .unlocked
        } catch {
            if let outcome = Self.biometricOutcomeLeavingDatabaseLocked(for: error) {
                canRemoveMissingDocumentsFile = false
                state = .locked
                return outcome
            }

            let diagnostics = makeUnlockDiagnostics(
                unlockMethod: .biometrics,
                passwordSupplied: false,
                keyFileSupplied: false,
                failedAttemptsBeforeAttempt: failedAttemptsBeforeAttempt,
                encryptedData: encryptedData,
                cloudSyncStatus: cloudSyncStatus
            )
            handleUnlockFailure(error, diagnostics: diagnostics)
            return .failed
        }
    }

    /// LocalAuthentication results that are not unlock failures and must not
    /// reach the failure screen: the prompt was never presented because the
    /// app was not foreground-active, or the user chose the password fallback
    /// the prompt offers. Both leave the unlock form as the right next screen.
    private static func biometricOutcomeLeavingDatabaseLocked(
        for error: Error
    ) -> BiometricUnlockOutcome? {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain else { return nil }

        switch LAError.Code(rawValue: nsError.code) {
        case .notInteractive: return .promptUnavailable
        case .userFallback: return .passwordFallback
        default: return nil
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

    /// `raw` with every KeePass `{REF:…}` field reference replaced by the value
    /// it points at in the current tree. Display, copy, and fill only — never
    /// feed the result back into an edit or save.
    func resolvingFieldReferences(_ raw: String) -> String {
        _ = contentRevision
        guard FieldReferenceResolver.containsReference(raw) else { return raw }
        return currentFieldReferenceResolver().resolve(raw)
    }

    /// The entry's decrypted password with field references resolved; empty
    /// when the database is locked.
    func resolvedPassword(for entry: KPEntry) -> String {
        guard let sessionKey, let plaintext = try? entry.password.decrypt(using: sessionKey) else { return "" }
        return resolvingFieldReferences(plaintext)
    }

    private func currentFieldReferenceResolver() -> FieldReferenceResolver {
        if let fieldReferenceResolver { return fieldReferenceResolver }
        let resolver = FieldReferenceResolver(entries: currentRootGroup?.allEntries ?? [], sessionKey: sessionKey)
        fieldReferenceResolver = resolver
        return resolver
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

    /// The group `entryID` currently sits in; `nil` for an unknown entry.
    func parentGroupID(forEntryID entryID: UUID) -> UUID? {
        _ = contentRevision
        return entryParentGroupIDs[entryID]
    }

    /// `inheritedTags(forGroupID:)` for the group currently holding `entryID` —
    /// what the entry gets from where it sits, excluding its own tags. Empty
    /// for an unknown entry.
    func inheritedTags(forEntryID entryID: UUID) -> [String] {
        _ = contentRevision
        guard let parentGroupID = entryParentGroupIDs[entryID] else { return [] }
        return inheritedTags(forGroupID: parentGroupID)
    }

    /// The two chip groups the entry detail screen draws: the tags `entryID`
    /// stores itself, then the ones it carries only because of where it sits.
    /// Concatenated they are exactly that entry's effective tags in index
    /// order, because this splits that one list rather than deriving a second
    /// — so a chip on the screen and a hit in the tag browser cannot disagree.
    /// A tag on both the entry and an ancestor group lands in `own` only.
    /// Both lists are empty for an unknown entry.
    func detailTags(forEntryID entryID: UUID) -> (own: [String], inherited: [String]) {
        _ = contentRevision
        guard let entry = entryIndex[entryID] else { return ([], []) }
        let own = TagNormalizer.tags(from: entry.tags)
        let effective = Self.effectiveTags(
            for: entry,
            inheritedGroupTags: inheritedTags(forEntryID: entryID)
        )
        return (own, Array(effective.dropFirst(own.count)))
    }

    /// Decoded image data of the entry's custom icon, if the database defines
    /// one for it in `Meta/CustomIcons`.
    func customIconData(for entry: KPEntry) -> Data? {
        guard let uuid = entry.customIconUUID else { return nil }
        return currentMeta?.customIcons[uuid]
    }

    /// Decoded image data of the group's custom icon, if the database defines
    /// one for it in `Meta/CustomIcons`.
    func customIconData(for group: KPGroup) -> Data? {
        guard let uuid = group.customIconUUID else { return nil }
        return currentMeta?.customIcons[uuid]
    }

    /// One image from `Meta/CustomIcons`, addressable by the picker.
    struct CustomIcon: Identifiable, Sendable, Hashable {
        let id: UUID
        let data: Data
    }

    /// The database's custom icons, in a stable order.
    ///
    /// `Meta/CustomIcons` is a dictionary and KDBX fixes no order for it, so the
    /// UUID is what the sort runs on — an arbitrary order that at least does not
    /// reshuffle the grid between openings of the same database.
    var customIcons: [CustomIcon] {
        _ = contentRevision
        guard let icons = currentMeta?.customIcons else { return [] }
        return icons
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { CustomIcon(id: $0.key, data: $0.value) }
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

    /// The entry's folder location below the visible root as a display string
    /// ("Parent / Child"). `nil` for entries sitting directly under the
    /// visible root and for unknown IDs.
    func folderPath(forEntryID entryID: UUID) -> String? {
        _ = contentRevision
        return entryFolderPaths[entryID]
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

        // A recycled entry still exists in the rebuilt index, so a mounted
        // detail view cannot observe its disappearance and close itself.
        if selectedEntryID == entryID, entryIndex[entryID] != nil {
            selectedEntryID = nil
        }
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

    /// Moves an entry into another group. Silently drops a request that would
    /// change nothing — a vanished entry or destination, or the group the
    /// entry already sits in — the same way `setGroupIcon` screens no-ops.
    func moveEntry(entryID: UUID, toGroupID: UUID) throws {
        guard entryIndex[entryID] != nil else { return }
        guard groupIndex[toGroupID] != nil else { return }
        guard entryParentGroupIDs[entryID] != toGroupID else { return }
        try applyEntryEdit(.moveEntry(entryID: entryID, destinationGroupID: toGroupID))
    }

    /// Reparents a group under another group. No-ops mirror `moveEntry`'s
    /// (vanished IDs, the current parent, the group itself); draft-level
    /// refusals — a cycle, a protected group, a sibling name collision in the
    /// destination — propagate so the caller can present them.
    ///
    /// Selection needs no fixing here: a move removes no IDs, so
    /// `synchronizeSelections()` (run by the draft rebuild) keeps everything
    /// valid on its own.
    func moveGroup(groupID: UUID, toGroupID: UUID) throws {
        guard groupID != toGroupID else { return }
        guard groupIndex[groupID] != nil else { return }
        guard let destination = groupIndex[toGroupID] else { return }
        guard destination.groups.contains(where: { $0.id == groupID }) == false else { return }
        try applyEntryEdit(.moveGroup(groupID: groupID, destinationGroupID: toGroupID))
    }

    /// The groups this entry could move into, in tree order from the visible
    /// root, with the recycle-bin subtree pruned. Empty for an unknown entry.
    func moveDestinationOptions(forEntryID entryID: UUID) -> [MoveDestinationOption] {
        _ = contentRevision
        guard entryIndex[entryID] != nil else { return [] }
        return moveDestinationOptions(
            prunedSubtreeID: nil,
            currentParentID: entryParentGroupIDs[entryID]
        )
    }

    /// The groups this group could move under: same walk as the entry
    /// variant, additionally pruning the moved group's own subtree — a group
    /// cannot become its own descendant. Empty for an unknown group.
    func moveDestinationOptions(forGroupID groupID: UUID) -> [MoveDestinationOption] {
        _ = contentRevision
        guard groupIndex[groupID] != nil else { return [] }
        return moveDestinationOptions(
            prunedSubtreeID: groupID,
            currentParentID: currentRootGroup.flatMap { Self.parentGroupID(of: groupID, in: $0) }
        )
    }

    /// The groups a new entry could be created in, for the entry editor's
    /// destination row. Same walk as the move variants — the recycle bin is
    /// never a destination — with `currentGroupID` marked as the one the form
    /// is already aimed at.
    func groupDestinationOptions(currentGroupID: UUID?) -> [MoveDestinationOption] {
        _ = contentRevision
        return moveDestinationOptions(prunedSubtreeID: nil, currentParentID: currentGroupID)
    }

    private func moveDestinationOptions(
        prunedSubtreeID: UUID?,
        currentParentID: UUID?
    ) -> [MoveDestinationOption] {
        guard let visibleRoot = visibleRootGroup else { return [] }
        let recycleBinID = currentRootGroup?.recycleBinUUID
        var options: [MoveDestinationOption] = []

        func collect(_ group: KPGroup, depth: Int) {
            guard group.id != recycleBinID, group.id != prunedSubtreeID else { return }
            options.append(
                MoveDestinationOption(
                    id: group.id,
                    name: group.name,
                    depth: depth,
                    isCurrentParent: group.id == currentParentID
                )
            )
            for child in group.groups {
                collect(child, depth: depth + 1)
            }
        }

        collect(visibleRoot, depth: 0)
        return options
    }

    private static func parentGroupID(of groupID: UUID, in group: KPGroup) -> UUID? {
        if group.groups.contains(where: { $0.id == groupID }) {
            return group.id
        }
        for child in group.groups {
            if let found = parentGroupID(of: groupID, in: child) {
                return found
            }
        }
        return nil
    }

    /// Whether search and AutoFill currently skip this group, taking an
    /// inherited `<EnableSearching>` from an ancestor into account. Resolved
    /// once per tree rebuild, like `isGroupInRecycleBin`.
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

    /// Changes which icon an entry displays.
    ///
    /// Ignores an `iconID` outside the standard set for the same reason
    /// `setGroupIcon` does, and ignores a custom icon the database does not
    /// define — a `<CustomIconUUID>` pointing at nothing renders as each
    /// client's own fallback, which is worse than the icon the entry has.
    ///
    /// A selection that already matches is still not always a no-op: choosing
    /// the standard icon an entry nominally carries is exactly how a custom icon
    /// gets cleared, so only an unchanged pair of both values is dropped.
    func setEntryIcon(_ icon: EntryIconSelection, entryID: UUID) throws {
        guard let entry = entryIndex[entryID] else { return }

        switch icon {
        case .standard(let iconID):
            guard KPEntry.standardIconNames[iconID] != nil else { return }
            guard entry.iconID != iconID || entry.customIconUUID != nil else { return }
        case .custom(let uuid):
            guard currentMeta?.customIcons[uuid] != nil else { return }
            guard entry.customIconUUID != uuid else { return }
        }

        try applyEntryEdit(.setEntryIcon(entryID: entryID, icon: icon))
    }

    /// Why a favicon download produced no icon. Each case is a different thing
    /// to tell the user, which is why they are not one "it didn't work".
    enum FaviconDownloadFailure: LocalizedError, Equatable {
        /// The entry has no address, or one that names no public host — an IP,
        /// `localhost`, or an internal-only name, none of which a favicon
        /// service can be asked about.
        case noPublicDomain
        /// The host had nothing to give, or gave something unusable.
        case noIconAvailable
        /// The entry is gone, or the database stopped accepting edits, between
        /// the button being offered and being tapped.
        case entryNotEditable

        var errorDescription: String? {
            switch self {
            case .noPublicDomain:
                String(localized: "This entry has no website address to download an icon from. Add one to the entry first.")
            case .noIconAvailable:
                String(localized: "No icon could be downloaded for this website. It may not have one, or the connection failed.")
            case .entryNotEditable:
                String(localized: "This entry can no longer be edited. It may have been deleted, or the database may have been reopened read-only.")
            }
        }
    }

    /// Downloads the entry's website icon, stores it in the database, and points
    /// the entry at it.
    ///
    /// The fetch, the cache read and the re-encode all happen off the main
    /// actor, in `FaviconIconEncoder.downloadedIconData(for:)` — the image is
    /// untrusted input of a size the host picks, and decoding it here would
    /// block the UI for as long as it took.
    ///
    /// Unlike the automatic favicons in lists, this runs whatever the "show
    /// website icons" setting says — the setting governs fetching KeeForge does
    /// on its own, and this is the user asking.
    func downloadFavicon(forEntryID entryID: UUID) async throws {
        // Throwing rather than returning: the picker reads a clean return as
        // success and dismisses, which would show a stored icon that isn't one.
        guard isReadOnly == false, let entry = entryIndex[entryID] else {
            throw FaviconDownloadFailure.entryNotEditable
        }
        guard let domain = FaviconService.extractDomain(from: entry.url) else {
            throw FaviconDownloadFailure.noPublicDomain
        }

        let downloaded = await FaviconIconEncoder.downloadedIconData(for: domain)
        // Point of no return: everything below lands in the draft, so a caller
        // that gave up during the fetch is told so rather than handed an edit
        // it no longer wants.
        try Task.checkCancellation()
        guard let imageData = downloaded else {
            throw FaviconDownloadFailure.noIconAvailable
        }

        // Downloading the icon an entry already displays is a no-op for the same
        // reason re-picking the current icon is in `setEntryIcon`: the edit would
        // cost a history version, a re-encrypt and a save for no visible change.
        if let current = entry.customIconUUID, currentMeta?.customIcons[current] == imageData {
            return
        }

        try applyEntryEdit(
            .addEntryCustomIcon(entryID: entryID, iconUUID: UUID(), imageData: imageData)
        )
    }

    /// Whether `downloadFavicon(forEntryID:)` has an address to work from, so
    /// the picker can present the action as unavailable instead of offering a
    /// button whose only possible outcome is an error.
    func canDownloadFavicon(forEntryID entryID: UUID) -> Bool {
        guard isReadOnly == false, let entry = entryIndex[entryID] else { return false }
        return FaviconService.extractDomain(from: entry.url) != nil
    }

    /// Applies the group editor's payload: name, tags, notes, standard icon and
    /// AutoFill visibility in one edit.
    ///
    /// Rejects an empty name here, the way `createGroup` does, so the draft
    /// layer's guard stays a backstop rather than a user-visible error. An
    /// `iconID` outside the standard set is ignored for the same reason
    /// `setGroupIcon` ignores it — KDBX would store the bare integer happily and
    /// every client would render its own fallback.
    func updateGroup(groupID: UUID, draft: GroupDraftPayload) throws {
        guard groupIndex[groupID] != nil else { return }
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.name.isEmpty == false else { return }
        guard KPEntry.standardIconNames[draft.iconID] != nil else { return }
        try applyEntryEdit(.updateGroup(groupID: groupID, draft: draft))
    }

    /// One stored version with its position in `KPEntry.history`. Restoring addresses the
    /// raw array, so the index has to survive the display sort.
    struct EntryHistoryVersion: Identifiable, Sendable {
        let index: Int
        let entry: KPEntry

        var id: Int { index }
    }

    /// The entry's stored earlier versions, newest first.
    ///
    /// Sorted here rather than trusted from the file: KDBX fixes no order, and KeePass and
    /// KeePassXC append chronologically while this app's edit path prepends. Versions
    /// without a timestamp sort last.
    func history(forEntryID entryID: UUID) -> [EntryHistoryVersion] {
        _ = contentRevision
        let versions = entryIndex[entryID]?.history ?? []
        // KDBX timestamps are second-resolution and `sorted` is not documented as
        // stable, so ties fall back to storage order: the list and the version
        // screen each recompute this, and they must agree on which row is which.
        return versions.enumerated()
            .map { EntryHistoryVersion(index: $0.offset, entry: $0.element) }
            .sorted { lhs, rhs in
                switch (lhs.entry.lastModificationTime, rhs.entry.lastModificationTime) {
                case let (left?, right?): return left == right ? lhs.index < rhs.index : left > right
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.index < rhs.index
                }
            }
    }

    /// Whether restoring would keep the state it replaces, so the confirmation does not
    /// promise an undo the database's history caps cannot honour.
    func restoreKeepsReplacedState(entryID: UUID) -> Bool {
        _ = contentRevision
        return draft?.restoreKeepsReplacedState(entryID: entryID) ?? false
    }

    /// Makes the entry's `historyIndex`-th stored version current again.
    /// `historyIndex` addresses `KPEntry.history` in storage order — pass
    /// `EntryHistoryVersion.index`, never a position in the sorted display list.
    func restoreEntryVersion(entryID: UUID, historyIndex: Int) throws {
        try applyEntryEdit(.restoreEntryVersion(entryID: entryID, historyIndex: historyIndex))
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

    /// Requests presenting the new-group sheet under the selected group. Used
    /// by the macOS menu-bar New Group command.
    func requestNewGroup() {
        guard case .unlocked = state, isReadOnly == false else { return }
        newGroupRequestID += 1
    }

    /// Requests opening the entry editor on the current selection. Used by the
    /// macOS menu-bar Edit Entry command.
    func requestEntryEdit() {
        guard canEditSelectedEntry else { return }
        editEntryRequestID += 1
    }

    /// Requests the delete confirmation for the current selection. Used by the
    /// macOS menu-bar Delete command; the workspace raises the same alert the
    /// row context menus use, so a menu-bar delete never bypasses it.
    func requestDeleteSelection() {
        guard deletableSelection != nil else { return }
        deleteSelectionRequestID += 1
    }

    /// Whether the macOS Edit Entry command applies right now.
    var canEditSelectedEntry: Bool {
        guard case .unlocked = state, isReadOnly == false, sessionKey != nil else { return false }
        guard let selectedEntryID else { return false }
        return entry(withID: selectedEntryID) != nil
    }

    /// What the macOS Delete command would act on: the selected entry when
    /// there is one, otherwise the selected group. Sidebar and content
    /// selection are mutually exclusive in practice — selecting a group clears
    /// the entry selection — so the entry-first order matches what the user is
    /// looking at.
    enum SelectionDeletionTarget: Equatable {
        case entry(UUID)
        case group(UUID)
    }

    var deletableSelection: SelectionDeletionTarget? {
        guard case .unlocked = state, isReadOnly == false else { return nil }
        if let selectedEntryID, entry(withID: selectedEntryID) != nil {
            return .entry(selectedEntryID)
        }
        if let selectedGroupID,
           group(withID: selectedGroupID) != nil,
           isGroupProtectedFromDeletion(groupID: selectedGroupID) == false {
            return .group(selectedGroupID)
        }
        return nil
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
        canRemoveMissingDocumentsFile = false
        state = .locked
        rootGroup = nil
        openedFormatVersion = nil
        compositeKey = nil
        sessionKey = nil
        sessionKeyFileData = nil
        unlockedMeta = nil
        binaryPool = nil
        draft = nil
        openTimeSHA512 = nil
        AttachmentPreviewFileStore.clearAll()
        saveError = nil
        saveConflict = nil
        mergeFailure = nil
        mergeSummaryMessage = nil
        pendingLockRequest = nil
        unsavedEditorIDs.removeAll()
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
        #if os(macOS)
        grantPendingWindowCloseIfNeeded()
        #endif
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

        if force {
            discardDraft()
            lock(manuallyTriggered: manuallyTriggered, preservingClipboard: preservingClipboard)
            return
        }

        // Only the editor can save or discard its own fields, so it goes first.
        if hasUnsavedEditor {
            pendingLockRequest = PendingLockRequest(manuallyTriggered: manuallyTriggered, reason: .openEditor)
            return
        }

        if isDirty == false {
            discardDraft()
            lock(manuallyTriggered: manuallyTriggered, preservingClipboard: preservingClipboard)
            return
        }

        // A dirty draft defers the lock so the user can choose whether to lose
        // it. Automatic requests require device-owner authentication before
        // the unlocked session can resume.
        pendingLockRequest = PendingLockRequest(manuallyTriggered: manuallyTriggered, reason: .draft)
    }

    var hasUnsavedEditor: Bool {
        unsavedEditorIDs.isEmpty == false
    }

    /// Called by editors as their form dirties and again as they go away.
    func setEditorHasUnsavedChanges(_ hasUnsavedChanges: Bool, editorID: UUID) {
        if hasUnsavedChanges {
            unsavedEditorIDs.insert(editorID)
        } else {
            unsavedEditorIDs.remove(editorID)
        }
    }

    /// Re-drives a request the editor was holding, once it has saved into the
    /// draft or discarded. Re-defers if that save failed and left it dirty.
    func resumeLockRequest(_ request: PendingLockRequest) {
        pendingLockRequest = nil
        lockRequest(manuallyTriggered: request.manuallyTriggered)
    }

    /// Workspace prompt action: retry the failed write, then lock. A second
    /// failure re-defers, leaving Discard and Keep Editing on offer.
    func saveAndLockAfterLockRequest() async {
        guard let request = pendingLockRequest, request.reason == .draft else { return }
        pendingLockRequest = nil
        await saveHandlingError()
        lockRequest(manuallyTriggered: request.manuallyTriggered)
    }

    #if os(macOS)
    /// What the Mac window delegate has to do about a close it is holding.
    enum WindowCloseDecision: Equatable {
        /// Nothing is unsaved: let the close commit. The last window going
        /// away locks the vault through `MacLockMonitor` as usual.
        case close
        /// An open editor owns the decision, and is now showing the prompt it
        /// already has for a deferred lock. The close waits for
        /// `onWindowCloseGranted`.
        case waitForEditorPrompt
        /// A write that already failed is still unsaved. The caller asks,
        /// because unlike the editor's fields it can drive the retry itself.
        case promptForUnsavedDraft
    }

    /// Fired when a close that was waiting on unsaved work may commit: the
    /// vault locked with nothing left unsaved behind it.
    @ObservationIgnored var onWindowCloseGranted: (() -> Void)?

    /// Set for as long as a window close is waiting on an answer, so the lock
    /// that answers it can let the window go.
    private var isWindowClosePending = false

    /// Called before a window close commits. It never locks by itself — the
    /// lock is the ordinary last-window one, taken once the close is granted.
    func requestWindowClose() -> WindowCloseDecision {
        guard case .unlocked = state else { return .close }

        // Only the editor can save or discard its own fields, so it prompts.
        if hasUnsavedEditor {
            isWindowClosePending = true
            lockRequest(manuallyTriggered: true)
            return .waitForEditorPrompt
        }

        guard isDirty else { return .close }

        isWindowClosePending = true
        return .promptForUnsavedDraft
    }

    /// Save, chosen in the close prompt: retry the write that failed, then
    /// lock. A second failure re-defers to the workspace prompt with the close
    /// still waiting on it, exactly as `saveAndLockAfterLockRequest()` does.
    func saveAndCloseWindow() async {
        guard isWindowClosePending else { return }
        await saveHandlingError()
        lockRequest(manuallyTriggered: true)
    }

    /// Don't Save, chosen in the close prompt.
    func discardAndCloseWindow() {
        guard isWindowClosePending else { return }
        lockRequest(force: true, manuallyTriggered: true)
    }

    /// Cancel, chosen in the close prompt or in whichever prompt the close was
    /// waiting on: the window stays open and the session is untouched.
    func cancelWindowClose() {
        isWindowClosePending = false
    }

    private func grantPendingWindowCloseIfNeeded() {
        guard isWindowClosePending else { return }
        isWindowClosePending = false
        onWindowCloseGranted?()
    }
    #endif

    func continueEditingAfterLockRequest() async {
        guard let pendingLockRequest else { return }

        if pendingLockRequest.requiresAuthenticationToContinueEditing {
            // Unavailable authentication is not a pass: finish the lock.
            guard deviceOwnerAuthAvailabilityCheck() else {
                lockRequest(force: true)
                return
            }

            do {
                _ = try await BiometricService.authenticateDeviceOwner(
                    reason: String(localized: "Unlock Database")
                )
            } catch {
                lockRequest(force: true)
                return
            }
        }

        cancelLockRequest()
    }

    private func cancelLockRequest() {
        pendingLockRequest = nil
        #if os(macOS)
        // Keep Editing is also the Cancel of a window close waiting on this
        // prompt: the window stays open.
        cancelWindowClose()
        #endif
        resetInactivityTimer()
    }

    func discardDraft() {
        draft = nil
        saveConflict = nil
        mergeFailure = nil
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
        guard let compositeKey else {
            throw SaveError.saveContextUnavailable
        }

        isSaving = true
        saveError = nil
        saveConflict = nil
        defer {
            isSaving = false
        }

        // An edit can land while the upload below is in flight: `applyEntryEdit`
        // has no reentry guard, so `self.draft` keeps growing past the snapshot
        // being written while the edit's own follow-up save no-ops on
        // `isSaving`. Clearing the draft unconditionally on completion would
        // silently discard those edits, so each pass writes a snapshot and the
        // loop goes around again if the draft grew behind it — the grown draft
        // contains the saved edits plus the new ones, so re-saving it whole is
        // correct.
        var snapshot = draft
        while true {
            guard let openTimeSHA512 else {
                throw SaveError.saveContextUnavailable
            }

            // The awaits below outlast a lock: applying their result to a locked
            // session would resurrect `rootGroup`/`unlockedMeta` behind the lock
            // screen. Same guard shape as `refreshCredentialStoreIfStillUnlocked`.
            let expectedLockCycleID = lockCycleID

            let saveResult: SaveResult
            switch databaseReference.source {
            case .local:
                saveResult = try await localSaveOperation(
                    snapshot,
                    databaseReference,
                    compositeKey,
                    openTimeSHA512,
                    nil,
                    nil
                )
            case .cloud:
                saveResult = try await cloudSaveOperation(
                    snapshot,
                    databaseReference,
                    compositeKey,
                    openTimeSHA512,
                    nil,
                    databaseReference.expectedCloudRevision,
                    nil
                )
            }

            // Locked while the save was in flight: the bytes did reach storage,
            // and the next unlock reads them back, so there is nothing to apply
            // here.
            guard expectedLockCycleID == lockCycleID else { return }

            switch saveResult {
            case .saved(let newSHA512):
                rootGroup = snapshot.rootGroup
                unlockedMeta = snapshot.meta
                self.openTimeSHA512 = newSHA512
                saveConflict = nil
                saveError = nil
                refreshDatabaseReference()
                populateCredentialStoreIfNeeded(root: snapshot.rootGroup)

                guard let grown = self.draft, grown.pendingEdits != snapshot.pendingEdits else {
                    self.draft = nil
                    return
                }
                // A replaced-but-pristine draft (edits discarded mid-save) has
                // nothing to write; keep it rather than clearing state the user
                // just chose.
                guard grown.isDirty else { return }
                snapshot = grown
            case .conflict(let remoteSHA512, let remoteData):
                saveConflict = SaveConflict(
                    remoteSHA512: remoteSHA512,
                    remoteData: remoteData
                )
                return
            }
        }
    }

    /// Re-encrypts the unlocked database under a new master key (password
    /// and/or key file) while preserving cipher and KDF cost settings.
    ///
    /// `newKeyFileBookmarkData`/`newKeyFileFilename` describe the database's
    /// key-file association after the change — pass the current values to keep
    /// an existing key file, nil to remove it. A conflict with concurrent
    /// changes aborts cleanly (`RekeyError.conflict`) with the file and the
    /// session untouched.
    func changeMasterKey(
        newPassword: String?,
        newKeyFileData: Data?,
        newKeyFileBookmarkData: Data?,
        newKeyFileFilename: String?
    ) async throws {
        guard case .unlocked = state, let compositeKey, let openTimeSHA512 else {
            throw RekeyError.sessionUnavailable
        }
        guard isReadOnly == false else {
            throw RekeyError.databaseIsReadOnly
        }
        guard isSaving == false else {
            throw RekeyError.saveInProgress
        }
        guard draft == nil || draft?.isDirty == false else {
            throw RekeyError.unsavedChanges
        }
        guard newPassword?.isEmpty == false || newKeyFileData != nil else {
            throw RekeyError.missingKeyComponent
        }
        // Pending AutoFill upload markers hold ciphertext under the old key;
        // draining them after a rekey would resurrect it on the remote.
        if databaseReference.isCloudBacked, pendingUploadMarkerCheck(databaseReference) {
            throw RekeyError.pendingUploadsExist
        }

        let newCompositeKey = try KDBXCrypto.compositeKey(
            password: newPassword,
            keyFileData: newKeyFileData
        )
        let workingDraft = try makeWorkingDraft()

        let expectedLockCycleID = lockCycleID

        isSaving = true
        saveError = nil
        defer {
            isSaving = false
        }

        let saveResult: SaveResult
        do {
            switch databaseReference.source {
            case .local:
                saveResult = try await localSaveOperation(
                    workingDraft,
                    databaseReference,
                    compositeKey,
                    openTimeSHA512,
                    nil,
                    newCompositeKey
                )
            case .cloud:
                saveResult = try await cloudSaveOperation(
                    workingDraft,
                    databaseReference,
                    compositeKey,
                    openTimeSHA512,
                    nil,
                    databaseReference.expectedCloudRevision,
                    newCompositeKey
                )
            }
        } catch SaveError.rekeyAppliedRemotely {
            // The upload landed, so the cloud file already requires the new
            // key even though the local apply failed. Point keychain and
            // association at the key the remote now needs — the stale local
            // cache reconciles through the normal sync-down path.
            refreshStoredCompositeKeyAfterRekey(newCompositeKey)
            persistKeyFileAssociation(
                bookmarkData: newKeyFileBookmarkData,
                filename: newKeyFileFilename
            )
            throw SaveError.rekeyAppliedRemotely
        }

        switch saveResult {
        case .saved(let newSHA512):
            // Keychain and reference reflect the on-disk file, so they update
            // even if the session locked mid-flight; the in-memory secrets must
            // not resurrect behind the lock screen.
            refreshStoredCompositeKeyAfterRekey(newCompositeKey)
            persistKeyFileAssociation(
                bookmarkData: newKeyFileBookmarkData,
                filename: newKeyFileFilename
            )
            if expectedLockCycleID == lockCycleID {
                self.compositeKey = newCompositeKey
                self.openTimeSHA512 = newSHA512
                // Edits can land while the rekey save is in flight (the sheet
                // is dismissible); their own save() no-ops on `isSaving`, so
                // flush them here under the new key. The task starts after
                // this function's defer resets `isSaving`.
                if draft?.isDirty == true {
                    Task { await self.saveHandlingError() }
                }
            }
        case .conflict:
            throw RekeyError.conflict
        }
    }

    private func refreshStoredCompositeKeyAfterRekey(_ newCompositeKey: SymmetricKey) {
        guard storedKeyPresenceCheck(databaseReference) else { return }

        do {
            try storedKeyStoreOperation(newCompositeKey, databaseReference)

            if let legacyFilename = databaseReference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
                DatabaseListStore.clearLegacyKeychainFilename(for: databaseReference.id)
            }
        } catch {
            // A stale stored key would break biometric unlock outright; drop it
            // so unlock falls back to the new password. The legacy entry must
            // go too — `retrieveStoredCompositeKey` falls back to it otherwise.
            storedKeyDeleteOperation(databaseReference)
            if let legacyFilename = databaseReference.legacyKeychainFilename {
                KeychainService.deleteLegacyCompositeKey(forFilename: legacyFilename)
                DatabaseListStore.clearLegacyKeychainFilename(for: databaseReference.id)
            }
        }
    }

    private func persistKeyFileAssociation(bookmarkData: Data?, filename: String?) {
        var updated = DatabaseListStore.databases.first(where: { $0.id == databaseReference.id }) ?? databaseReference
        updated.keyFileBookmarkData = bookmarkData
        updated.keyFileFilename = filename
        // The drainer refuses to push markers older than this: they hold
        // ciphertext under the old key and would revert the rekeyed remote.
        updated.lastMasterKeyChangeAt = nowProvider()
        DatabaseListStore.update(updated)
        refreshDatabaseReference()
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

    /// Reconciles the file that caused the conflict into the current draft and
    /// saves the combined result, record by record (`KDBXMerger`).
    ///
    /// The write is gated on the bytes the conflict reported, not the
    /// session's open-time state: those are the bytes this merge read and
    /// folded in, so they are what it may replace. If the file moved again
    /// since the conflict was captured the gate trips and the conflict
    /// re-surfaces with the fresher content — one attempt per invocation, so
    /// the loop only ever advances when the user asks it to.
    ///
    /// Nothing here is destructive on failure: the draft, the conflict, and
    /// the fallback options all survive every early return.
    func mergeAndSave() async throws {
        if isReadOnly {
            throw SaveError.databaseIsReadOnly
        }

        guard case .unlocked = state,
              isSaving == false,
              let conflict = saveConflict,
              let compositeKey,
              let sessionKey,
              let openTimeSHA512
        else {
            mergeFailure = .sessionUnavailable
            return
        }

        // The draft's tree is the local side, so unsaved edits take part in the
        // merge rather than being written over it.
        let localDraft = try makeWorkingDraft()
        // The pool the session opened. KeeForge never adds pool entries, so it
        // is still the pool of the local side's attachments; the merger only
        // compares it against the remote's.
        let localBinaryPoolFields = binaryPool?.rawFields ?? []
        let expectedLockCycleID = lockCycleID

        isSaving = true
        saveError = nil
        mergeFailure = nil
        mergeSummaryMessage = nil
        defer {
            isSaving = false
        }

        let merged: KDBXMerger.Merged
        do {
            merged = try await Self.mergeRemoteOffMain(
                remoteData: conflict.remoteData,
                compositeKey: compositeKey,
                sessionKey: sessionKey,
                localRootGroup: localDraft.rootGroup,
                localMeta: localDraft.meta,
                localBinaryPoolFields: localBinaryPoolFields
            )
        } catch let failure as DatabaseMergeFailure {
            mergeFailure = failure
            return
        }

        // Locked while the merge ran: the merged tree holds session secrets and
        // must not resurrect behind the lock screen.
        guard expectedLockCycleID == lockCycleID else { return }

        let mergedDraft = DatabaseDraft(
            rootGroup: merged.rootGroup,
            meta: merged.meta,
            sessionKey: sessionKey
        )

        // A merge that adds nothing still has to write: the remote holding no
        // new records says nothing about the user's unsaved edits, which are
        // the reason this save was attempted at all. Only the confirmation
        // wording changes.
        let saveResult: SaveResult
        switch databaseReference.source {
        case .local:
            saveResult = try await localSaveOperation(
                mergedDraft,
                databaseReference,
                compositeKey,
                openTimeSHA512,
                conflict.remoteSHA512,
                nil
            )
        case .cloud:
            saveResult = try await cloudSaveOperation(
                mergedDraft,
                databaseReference,
                compositeKey,
                openTimeSHA512,
                conflict.remoteSHA512,
                databaseReference.expectedCloudRevision,
                nil
            )
        }

        guard expectedLockCycleID == lockCycleID else { return }

        switch saveResult {
        case .saved(let newSHA512):
            rootGroup = mergedDraft.rootGroup
            unlockedMeta = mergedDraft.meta
            self.openTimeSHA512 = newSHA512
            saveConflict = nil
            saveError = nil
            draft = draftReplayingEditsArriving(after: localDraft, onto: mergedDraft)
            refreshDatabaseReference()
            populateCredentialStoreIfNeeded(root: mergedDraft.rootGroup)
            mergeSummaryMessage = Self.mergeSummaryMessage(for: merged.summary)
        case .conflict(let remoteSHA512, let remoteData):
            // Strictly different bytes from the conflict just merged — the gate
            // accepted those — so this is a value change the alert observes.
            saveConflict = SaveConflict(remoteSHA512: remoteSHA512, remoteData: remoteData)
        }
    }

    func dismissMergeFailure() {
        mergeFailure = nil
    }

    func acknowledgeMergeSummary() {
        mergeSummaryMessage = nil
    }

    /// Parses the conflicting file and merges it into the local side, all off
    /// the main actor. Both sides share the live session key, so protected
    /// values graft across without a decrypt/reseal cycle.
    nonisolated private static func mergeRemoteOffMain(
        remoteData: Data,
        compositeKey: SymmetricKey,
        sessionKey: SymmetricKey,
        localRootGroup: KPGroup,
        localMeta: KPMeta,
        localBinaryPoolFields: [Data]
    ) async throws -> KDBXMerger.Merged {
        try await Task.detached(priority: .userInitiated) {
            let remote: (rootGroup: KPGroup, meta: KPMeta, header: KDBXParser.Header)
            do {
                remote = try KDBXParser.parseWithMetaAndHeader(
                    data: remoteData,
                    compositeKey: compositeKey,
                    sessionKey: sessionKey,
                    kdfPolicy: .mainApp
                )
            } catch {
                throw DatabaseMergeFailure.remoteUnreadable
            }
            // The writer is KDBX4-only, so a 3.1 remote could not be written
            // back even if it merged cleanly.
            guard remote.header.formatVersion.requiresReadOnlyMode == false else {
                throw DatabaseMergeFailure.remoteUnreadable
            }

            let outcome: KDBXMerger.Outcome
            do {
                outcome = try KDBXMerger.merge(
                    local: KDBXMerger.Side(
                        rootGroup: localRootGroup,
                        meta: localMeta,
                        binaryPoolFields: localBinaryPoolFields
                    ),
                    remote: KDBXMerger.Side(
                        rootGroup: remote.rootGroup,
                        meta: remote.meta,
                        binaryPoolFields: remote.header.innerHeaderBinaryFields
                    ),
                    sessionKey: sessionKey
                )
            } catch {
                // `protectedValueUnreadable` means the two sides were parsed
                // under different keys, which this call site rules out.
                throw DatabaseMergeFailure.sessionUnavailable
            }

            switch outcome {
            case .merged(let merged):
                return merged
            case .declined(let blockers):
                guard blockers.contains(.attachmentPoolDivergence) else {
                    throw DatabaseMergeFailure.sessionUnavailable
                }
                throw DatabaseMergeFailure.attachmentsDiverged
            }
        }.value
    }

    /// The edits that landed while the merge save was in flight, replayed onto
    /// the merged tree.
    ///
    /// Such an edit was applied to the *pre-merge* tree, so its draft cannot be
    /// saved as-is without writing the merge back out of the file; and its own
    /// `save()` no-oped on `isSaving`, so dropping it would lose it silently.
    /// Replaying just the tail leaves the user with exactly those edits
    /// unsaved, which the unsaved-changes banner then shows.
    private func draftReplayingEditsArriving(
        after base: DatabaseDraft,
        onto mergedDraft: DatabaseDraft
    ) -> DatabaseDraft? {
        guard let grown = draft,
              grown.pendingEdits.count > base.pendingEdits.count,
              Array(grown.pendingEdits.prefix(base.pendingEdits.count)) == base.pendingEdits
        else {
            return nil
        }

        var replayed = mergedDraft
        for edit in grown.pendingEdits.dropFirst(base.pendingEdits.count) {
            guard let next = try? replayed.apply(edit) else { return nil }
            replayed = next
        }
        return replayed
    }

    private static func mergeSummaryMessage(for summary: KDBXMerger.Summary) -> String {
        let changeCount = summary.entriesAdded + summary.entriesUpdated + summary.entriesMoved
            + summary.groupsAdded + summary.groupsUpdated + summary.groupsMoved
            + summary.historyItemsAdded + summary.deletionsApplied
            + summary.tombstonesDropped + summary.tombstonesAdded
            + summary.customIconsSpliced

        guard changeCount > 0 else {
            return String(localized: "The other copy had no new changes to add. Your changes were saved.")
        }
        return String(localized: "\(changeCount) changes from the other copy were combined with yours and saved.")
    }

    func reloadDiscardingDraft() async throws {
        guard let compositeKey else {
            throw SaveError.saveContextUnavailable
        }

        saveError = nil
        saveConflict = nil
        mergeFailure = nil
        mergeSummaryMessage = nil
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

        #if os(iOS)
        if SettingsService.lockOnBackground {
            // Scene phase cannot tell an app switch from a device lock, so iOS
            // keeps the pasteboard (#34) and a copy can outlive a screen lock
            // by up to the clipboard-clear timeout.
            lockRequest(preservingClipboard: true)
            return
        }

        backgroundEnteredAt = nowProvider()
        cancelInactivityTimer(clearDeadline: false)
        #else
        // macOS reaches this only from `MacLockMonitor`, which has already
        // applied `SettingsService.macLockPolicy` and whose triggers all mean
        // the user walked away. Locking here is the macOS security guarantee
        // (`KeeForgeMac/README.md`), so it must never depend on
        // `lockOnBackground` — an iOS-only setting the Mac never renders and
        // cannot repair. The clipboard is scrubbed too: macOS has no expiring,
        // device-local copy (`docs/macos-security-notes.md`).
        lockRequest()
        #endif
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
        let compositeKeyForStoreRefresh: SymmetricKey?

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
                        sessionKey: SymmetricKey(size: .bits256),
                        kdfPolicy: .mainApp
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
        let ordered: [KPGroup]
        switch sortOrder {
        case .title:
            ordered = groups.sorted {
                let result = $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                return asc ? result : !result
            }
        case .createdDate:
            ordered = groups.sorted {
                let result = ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast)
                return asc ? result : !result
            }
        case .modifiedDate:
            ordered = groups.sorted {
                let result = ($0.lastModificationTime ?? .distantPast) < ($1.lastModificationTime ?? .distantPast)
                return asc ? result : !result
            }
        }
        return Self.pinningRecycleBinLast(ordered, recycleBinID: currentRootGroup?.recycleBinUUID)
    }

    /// The bin is a fixed landmark rather than one folder among many, so it
    /// keeps the bottom slot no matter which sort order or direction is active —
    /// the placement most KeePass apps use.
    private static func pinningRecycleBinLast(_ groups: [KPGroup], recycleBinID: UUID?) -> [KPGroup] {
        guard let recycleBinID,
              let index = groups.firstIndex(where: { $0.id == recycleBinID }),
              index != groups.count - 1 else {
            return groups
        }
        var pinned = groups
        pinned.append(pinned.remove(at: index))
        return pinned
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
        fieldReferenceResolver = nil
        guard let root = currentRootGroup else {
            entryIndex = [:]
            groupIndex = [:]
            groupEntryCounts = [:]
            searchableEntries = []
            searchableEntryText = [:]
            tagEntryIDs = [:]
            groupInheritedTags = [:]
            entryParentGroupIDs = [:]
            entryFolderPaths = [:]
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
        var nextEntryFolderPaths: [UUID: String] = [:]
        var nextRecycleBinEntryIDs = Set<UUID>()
        var nextRecycleBinGroupIDs = Set<UUID>()
        var nextAutoFillExcludedGroupIDs = Set<UUID>()
        let recycleBinID = root.recycleBinUUID
        let visibleRootID = visibleRootGroupID

        @discardableResult
        func index(
            group: KPGroup,
            includeInSearch: Bool,
            autoFillEnabled: Bool,
            inheritedTags: [String],
            folderPath: [String]
        ) -> Int {
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
                if folderPath.isEmpty == false {
                    nextEntryFolderPaths[entry.id] = folderPath.joined(separator: " / ")
                }
                totalEntryCount += 1
                if includeInSearch {
                    let tags = Self.effectiveTags(for: entry, inheritedGroupTags: accumulatedTags)
                    // A disabled `<EnableSearching>` hides the entry from the
                    // search corpus (KeePass's reading of the flag) as well as
                    // AutoFill; the tag index and browsing deliberately keep
                    // it, and recycle-bin state is never involved.
                    if resolvedAutoFillEnabled {
                        nextSearchableEntries.append(entry)
                        nextSearchableEntryText[entry.id] = Self.searchText(for: entry, tags: tags)
                    }
                    for tag in tags {
                        nextTagEntryIDs[tag, default: []].append(entry.id)
                    }
                } else {
                    nextRecycleBinEntryIDs.insert(entry.id)
                }
            }

            for childGroup in group.groups {
                let childIncludedInSearch = includeInSearch && childGroup.id != recycleBinID
                // Paths start below the visible root, so neither the parser's
                // synthetic wrapper nor the database root's name shows up.
                let childFolderPath = childGroup.id == visibleRootID ? [] : folderPath + [childGroup.name]
                totalEntryCount += index(
                    group: childGroup,
                    includeInSearch: childIncludedInSearch,
                    autoFillEnabled: resolvedAutoFillEnabled,
                    inheritedTags: accumulatedTags,
                    folderPath: childFolderPath
                )
            }

            nextGroupEntryCounts[group.id] = totalEntryCount
            return totalEntryCount
        }

        index(group: root, includeInSearch: true, autoFillEnabled: true, inheritedTags: [], folderPath: [])

        entryIndex = nextEntryIndex
        groupIndex = nextGroupIndex
        groupEntryCounts = nextGroupEntryCounts
        searchableEntries = nextSearchableEntries
        searchableEntryText = nextSearchableEntryText
        tagEntryIDs = nextTagEntryIDs
        groupInheritedTags = nextGroupInheritedTags
        entryParentGroupIDs = nextEntryParentGroupIDs
        entryFolderPaths = nextEntryFolderPaths
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
        // Adopt any heal the store performed since this session's reference
        // snapshot was taken (Documents-vault rebind, bookmark refresh,
        // filename re-derivation), so Try Again resolves the current stored
        // reference instead of failing on the stale one.
        refreshDatabaseReference()
        canRemoveMissingDocumentsFile = false
        state = .unlocking
        draft = nil
        sessionKeyFileData = nil
        openTimeSHA512 = nil
        saveError = nil
        saveConflict = nil
        pendingLockRequest = nil
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
        compositeKey: SymmetricKey,
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
                canRemoveMissingDocumentsFile = false
                state = .error(lockoutFailure(seconds: seconds, diagnostics: diagnostics))
                return
            }
        }

        canRemoveMissingDocumentsFile = evaluateMissingDocumentsFileRemoval(for: failure)
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

    private func persistCompositeKeyForBiometricUnlock(_ compositeKey: SymmetricKey) {
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

    nonisolated static func retrieveStoredCompositeKey(
        for reference: DatabaseReference,
        context: LAContext
    ) throws -> SymmetricKey {
        do {
            return try KeychainService.retrieveCompositeKey(for: reference.id, context: context)
        } catch {
            guard KeychainService.isItemNotFound(error),
                  let legacyFilename = reference.legacyKeychainFilename else {
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
        compositeKey: SymmetricKey,
        sourceData: Data
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let parsed = try KDBXParser.parseWithMetaAndHeader(
                data: sourceData,
                compositeKey: compositeKey,
                sessionKey: SymmetricKey(size: .bits256),
                kdfPolicy: .mainApp
            )
            return try KDBXWriter.write(
                rootGroup: draft.rootGroup,
                meta: draft.meta,
                compositeKey: compositeKey,
                header: parsed.header,
                sessionKey: draft.writerSessionKey,
                kdfPolicy: .mainApp
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
    /// `createFile` is required to be no-overwrite (`Cloud/CLAUDE.md`) and
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
        compositeKey: SymmetricKey
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
                sessionKey: sessionKey,
                kdfPolicy: .mainApp
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
