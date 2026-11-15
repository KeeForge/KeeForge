import Foundation

struct DatabaseRowStatus: Equatable, Sendable {
    var hasStoredKey: Bool
    var hasAccessIssue: Bool
    var cloudState: CloudRowState?
    var pendingUploadCount: Int = 0
    var pendingUploadConflictCount: Int = 0
    /// Documents-resident reference whose file left the Documents folder
    /// (Finder delete). Distinct from `hasAccessIssue`: the reference is
    /// intact, only its file is gone, and restoring the file heals it.
    var isDocumentsFileMissing: Bool = false
}

struct CloudRowState: Equatable, Sendable {
    var providerName: String
    var isConnected: Bool
    var warningText: String?
    var displayPath: String
    var accountLabel: String
}

struct PendingUploadAlert: Identifiable, Equatable, Sendable {
    enum Kind: Sendable, Equatable {
        case writeScopeRequired
        case notAuthenticated
        case message
        case conflict
    }

    let databaseId: UUID
    let kind: Kind
    let title: String
    let message: String

    var id: String {
        "\(databaseId.uuidString)-\(kind)"
    }
}

@MainActor @Observable
final class DatabaseListViewModel {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private(set) var databases: [DatabaseReference] = []
    private(set) var registryReadError: String?
    private var initializationUnconfirmed = false
    private(set) var rowStatuses: [UUID: DatabaseRowStatus] = [:]
    private(set) var pendingUploadAlert: PendingUploadAlert?
    private(set) var isAutoFillProviderEnabled: Bool?
    /// Nil until the provider is known to be on; the flag is only recorded for
    /// an enabled provider.
    private(set) var autoFillStoreSupportsIncrementalUpdates: Bool?
    private(set) var isAutoFillTipDismissed = AutoFillStatusService.tipDismissed
    private(set) var isMacAppSuggestionDismissed = MacAppSuggestionService.isDismissed
    /// Set when an enable request came back with the provider still off. It has
    /// to be state rather than a one-shot alert: iOS tears the presenting sheet
    /// down together with its own prompt, so anything modal raised at that
    /// moment is dropped before it can appear.
    private(set) var isAutoFillEnableRequestRejected = false
    private var didConsumeInitialLaunchSelection = false
    private let pendingUploadDrainer: PendingUploadDrainer
    typealias KeyFileBookmarkOperation = @Sendable (URL) async throws -> Data
    private let keyFileBookmarkOperation: KeyFileBookmarkOperation
    private let keyFilePreferenceIO: DatabaseListStore.KeyFilePreferenceIO
    private var keyFileRequests: [UUID: KeyFilePreferenceRequest] = [:]

    private final class KeyFilePreferenceRequest: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }


    init(pendingUploadDrainer: PendingUploadDrainer = PendingUploadDrainer(),
        keyFileBookmarkOperation: @escaping KeyFileBookmarkOperation = { url in
            try await Task.detached { try SecurityScopedBookmarkManager.makeBookmarkData(for: url, readOnly: true) }.value
        }, keyFilePreferenceIO: DatabaseListStore.KeyFilePreferenceIO = .init()
    ) {
        self.pendingUploadDrainer = pendingUploadDrainer
        self.keyFileBookmarkOperation = keyFileBookmarkOperation
        self.keyFilePreferenceIO = keyFilePreferenceIO
        switch DatabaseListStore.initializeRegistry() {
        case .initialized, .alreadyPresent: reload()
        case .notPublished(let error): registryReadError = error.localizedDescription
        case .visibleUnconfirmed(let error):
            initializationUnconfirmed = true
            registryReadError = error.localizedDescription
        }
    }

    var pendingUploadsDidChange: ((Set<UUID>) -> Void)?
    var referencesDidChange: (([DatabaseReference]) -> Void)?

    func reload() {
        guard !initializationUnconfirmed else { return }
        do {
            let snapshot = try DatabaseListStore.readDatabasesStrict()
            databases = snapshot
            registryReadError = nil
            refreshRowStatuses()
            referencesDidChange?(databases)
        } catch {
            registryReadError = error.localizedDescription
        }
    }

    func databaseToAutoOpenOnLaunch() -> DatabaseReference? {
        guard didConsumeInitialLaunchSelection == false else { return nil }
        didConsumeInitialLaunchSelection = true
        guard registryReadError == nil else { return nil }
        return databases.first(where: \.isQuickLaunch)
    }

    func addDatabase(from url: URL) throws -> DatabaseReference {
        let reference = try DatabaseListStore.add(url: url)
        reload()
        return reference
    }

    func addCloudDatabase(selection: CloudDatabaseSelection) throws -> DatabaseReference {
        let reference = try DatabaseListStore.addCloud(
            provider: selection.provider,
            accountId: selection.account.id,
            file: selection.file
        )
        reload()
        return reference
    }

    @discardableResult
    func removeDatabase(_ reference: DatabaseReference) async -> DatabaseListStore.RemovalOutcome {
        let removed = await Task.detached { DatabaseListStore.remove(observed: reference) }.value
        reload()
        return removed
    }

    func moveDatabases(from source: IndexSet, to destination: Int) {
        DatabaseListStore.move(from: source, to: destination, observedIDs: databases.map(\.id))
        reload()
    }

    func toggleQuickLaunch(for reference: DatabaseReference) {
        let currentValue = databases.first(where: { $0.id == reference.id })?.isQuickLaunch ?? reference.isQuickLaunch

        DatabaseListStore.setQuickLaunch(!currentValue, for: reference.id, observed: currentValue)
        reload()
    }

    func setNickname(_ nickname: String?, for reference: DatabaseReference) {
        DatabaseListStore.setNickname(nickname, for: reference.id)
        reload()
    }

    func setReadOnly(_ isReadOnly: Bool, for reference: DatabaseReference) {
        DatabaseListStore.setReadOnly(isReadOnly, for: reference)
        reload()
    }

    func setCloudSyncPolicy(_ policy: CloudSyncPolicy, for reference: DatabaseReference) {
        DatabaseListStore.setCloudSyncPolicy(policy, for: reference)
        reload()
    }

    // The application owner supplies session lookup without retaining a view.
    var autoFillEnabledRefreshHandler: ((UUID) -> Void)?

    /// Toggles a database's AutoFill participation (surfaced by the settings
    /// UI in slice 05 of the selectable-AutoFill epic). Unlike the other flag
    /// setters this delegates to `DatabaseListStore.setAutoFillEnabled` rather
    /// than the generic `update`, because the store owns the disable
    /// consequences: targeted removal of exactly that database's credential
    /// identities and reassigning the active AutoFill pointer when the active
    /// database is disabled. Enabling is lazy in the store; when the toggled
    /// database is the currently unlocked session, the application-installed
    /// `autoFillEnabledRefreshHandler` republishes its identities immediately.
    @discardableResult
    func setAutoFillEnabled(_ isEnabled: Bool, for reference: DatabaseReference) async -> DatabaseListStore.AutoFillPreferenceOutcome {
        let outcome = await Task.detached { DatabaseListStore.setAutoFillEnabled(isEnabled, for: reference) }.value
        reload()
        if isEnabled && outcome == .saved {
            autoFillEnabledRefreshHandler?(reference.id)
        }
        return outcome
    }

    func isChangingKeyFile(for id: UUID) -> Bool { keyFileRequests[id] != nil }

    func cancelKeyFilePreference(for id: UUID? = nil) {
        if let id { keyFileRequests.removeValue(forKey: id)?.cancel() }
        else {
            for request in keyFileRequests.values { request.cancel() }
            keyFileRequests.removeAll()
        }
    }

    func setKeyFile(url: URL?, for reference: DatabaseReference) async throws {
        let observed = databases.first { $0.id == reference.id } ?? reference
        let request = KeyFilePreferenceRequest()
        keyFileRequests[reference.id]?.cancel()
        keyFileRequests[reference.id] = request
        defer {
            reload()
            if keyFileRequests[reference.id]?.id == request.id { keyFileRequests.removeValue(forKey: reference.id) }
        }
        let token = observed.isCloudBacked ? nil : try await Task.detached { try DatabaseListStore.prepareKeyFilePreference(for: observed) }.value
        let bookmark: Data?
        if let url { bookmark = try await keyFileBookmarkOperation(url) } else { bookmark = nil }
        guard !Task.isCancelled, !request.isCancelled, keyFileRequests[reference.id]?.id == request.id else { throw CancellationError() }
        let desired = PendingLocalSaveStore.KeyFilePreference(bookmarkData: bookmark, filename: url?.lastPathComponent)
        let io = keyFilePreferenceIO
        let outcome = await withTaskCancellationHandler {
            await Task.detached {
                if let token {
                    return DatabaseListStore.publishKeyFilePreference(token, desired: desired, io: io, canPublish: { !request.isCancelled })
                }
                return DatabaseListStore.publishRegistryKeyFilePreference(for: observed, desired: desired,
                    io: io.registry, canPublish: { !request.isCancelled })
            }.value
        } onCancel: { request.cancel() }
        guard !Task.isCancelled, !request.isCancelled, keyFileRequests[reference.id]?.id == request.id else { throw CancellationError() }
        guard outcome == .saved else { throw DatabaseListStore.KeyFilePreferenceError(outcome: outcome) }
    }

    func refreshBookmarks() {
        DatabaseListStore.refreshBookmarks()
        reload()
    }

    func status(for reference: DatabaseReference) -> DatabaseRowStatus {
        rowStatuses[reference.id] ?? .init(hasStoredKey: false, hasAccessIssue: false, cloudState: nil)
    }

    func cloudState(for reference: DatabaseReference) -> CloudRowState? {
        status(for: reference).cloudState
    }

    func hasPendingUploads(for reference: DatabaseReference) -> Bool {
        status(for: reference).pendingUploadCount > 0
    }

    func pendingUploadCount(for reference: DatabaseReference) -> Int {
        status(for: reference).pendingUploadCount
    }

    func hasPendingUploadConflicts(for reference: DatabaseReference) -> Bool {
        status(for: reference).pendingUploadConflictCount > 0
    }

    static func lastOpenedDescription(
        for reference: DatabaseReference,
        showsUsageStats: Bool = SettingsService.showDatabaseUsageStats
    ) -> String? {
        guard showsUsageStats else { return nil }
        guard let lastOpenedAt = reference.lastOpenedAt else { return nil }
        let relative = Self.relativeDateFormatter.localizedString(for: lastOpenedAt, relativeTo: .now)
        return String(localized: "Last opened \(relative)")
    }

    func drainPendingUploadsOnAppActive() async {
        let outcome = await pendingUploadDrainer.drainAll()
        reload()
        pendingUploadsDidChange?(outcome.drainedDatabaseIDs.union(outcome.conflictDatabaseIDs).union(outcome.skippedDatabaseIDs))
    }

    /// The one push behind every Push Pending Changes. The list shows what went
    /// wrong itself unless `presentsAlert` is off, as for a Mac database
    /// window, which shows the returned alert in its own window.
    @discardableResult
    func pushPendingChanges(for reference: DatabaseReference, presentsAlert: Bool = true) async -> PendingUploadAlert? {
        let outcome = await pendingUploadDrainer.drain(databaseId: reference.id)
        reload()
        pendingUploadsDidChange?(outcome.drainedDatabaseIDs.union(outcome.conflictDatabaseIDs).union(outcome.skippedDatabaseIDs))
        let alert = Self.alert(for: outcome, preferredDatabaseId: reference.id)
        if presentsAlert, let alert { pendingUploadAlert = alert }
        return alert
    }

    /// User-confirmed resolution for the orange conflict badge: backs up the
    /// stranded AutoFill payload (when its bytes still exist) and drops the
    /// conflicted markers. See `CloudSyncCoordinator.discardConflictedPendingUploads`.
    func discardConflictedPendingUploads(for reference: DatabaseReference) async {
        _ = await CloudSyncCoordinator.discardConflictedPendingUploads(for: reference)
        reload()
    }

    func dismissPendingUploadAlert() {
        pendingUploadAlert = nil
    }

    // MARK: - AutoFill enablement tip

    var shouldShowAutoFillTip: Bool {
        !databases.isEmpty
            && isAutoFillProviderEnabled == false
            && !isAutoFillTipDismissed
            && !AutoFillStatusService.isTipSuppressedForUITesting
    }

    /// A store without incremental updates holds one database's identities
    /// (`CredentialIdentityStoreManager.populate`), so suggestions cannot span
    /// the selected databases.
    var isAutoFillLimitedToOneDatabase: Bool {
        autoFillStoreSupportsIncrementalUpdates == false
            && databases.count(where: \.autoFillEnabled) > 1
    }

    func refreshAutoFillStatus() async {
        let isEnabled = await AutoFillStatusService.isAutoFillEnabled()
        isAutoFillProviderEnabled = isEnabled
        if isEnabled {
            isAutoFillEnableRequestRejected = false
            autoFillStoreSupportsIncrementalUpdates = await AutoFillStatusService.supportsIncrementalUpdates()
        } else {
            autoFillStoreSupportsIncrementalUpdates = nil
        }
    }

    func requestEnableAutoFill() async {
        if await AutoFillStatusService.requestEnableAutoFill() {
            isAutoFillProviderEnabled = true
            isAutoFillEnableRequestRejected = false
            autoFillStoreSupportsIncrementalUpdates = await AutoFillStatusService.supportsIncrementalUpdates()
        } else {
            // The prompt closed without authorizing KeeForge. Confirm that
            // against the real provider state before recording it — the result
            // describes the prompt, not the store.
            await refreshAutoFillStatus()
            isAutoFillEnableRequestRejected = isAutoFillProviderEnabled != true
        }
    }

    func dismissAutoFillTip() {
        AutoFillStatusService.tipDismissed = true
        isAutoFillTipDismissed = true
    }

    // MARK: - Native Mac app suggestion

    /// Unlike the AutoFill tip this does not wait for a database: someone
    /// starting out on a Mac is better off starting in the native app.
    var shouldShowMacAppSuggestion: Bool {
        MacAppSuggestionService.isSuggestionAvailable && !isMacAppSuggestionDismissed
    }

    func dismissMacAppSuggestion() {
        MacAppSuggestionService.isDismissed = true
        isMacAppSuggestionDismissed = true
    }

    // MARK: - Private

    private func refreshRowStatuses() {
        var updatedStatuses: [UUID: DatabaseRowStatus] = [:]
        let pendingMarkers = PendingUploadQueue.listMarkers()
        let pendingCounts = Dictionary(
            pendingMarkers.map { ($0.marker.databaseId, 1) },
            uniquingKeysWith: +
        )
        let pendingConflictCounts = Dictionary(
            pendingMarkers.compactMap { storedMarker in
                storedMarker.marker.isConflicted ? (storedMarker.marker.databaseId, 1) : nil
            },
            uniquingKeysWith: +
        )

        for reference in databases {
            QuickUnlockKeychain.expireIfDue(reference)
            let hasStoredKey = KeychainService.hasStoredKey(
                for: reference.id,
                legacyFilename: reference.legacyKeychainFilename
            )
            let pendingUploadCount = pendingCounts[reference.id] ?? 0
            let pendingUploadConflictCount = pendingConflictCounts[reference.id] ?? 0

            if let metadata = reference.cloudSyncMetadata {
                let isConnected = CloudAccountStore.isConnected(
                    provider: metadata.provider,
                    accountId: metadata.accountId
                )
                let accountLabel = CloudAccountStore.account(
                    provider: metadata.provider,
                    accountId: metadata.accountId
                )?.displayName ?? metadata.accountId
                let provider = metadata.providerKind

                updatedStatuses[reference.id] = DatabaseRowStatus(
                    hasStoredKey: hasStoredKey,
                    hasAccessIssue: DatabaseListStore.cachedDatabaseURL(for: reference) == nil && !isConnected,
                    cloudState: CloudRowState(
                        providerName: provider?.displayName ?? metadata.provider.capitalized,
                        isConnected: isConnected,
                        warningText: metadata.warningText(isAuthenticated: isConnected),
                        displayPath: metadata.displayPath,
                        accountLabel: accountLabel
                    ),
                    pendingUploadCount: pendingUploadCount,
                    pendingUploadConflictCount: pendingUploadConflictCount
                )
            } else {
                // Do not resolve or probe local bookmarks while building the
                // database list. File-provider URLs (especially an offline SMB
                // share) can block synchronously and freeze the app at launch.
                // The bounded open path reports the actual access error.
                // Documents-resident references are the exception: the missing
                // check is a pure own-container status probe — no file
                // provider, no writes, no heal (healing happens on the
                // locate paths: unlock, save, and the Documents scan).
                updatedStatuses[reference.id] = DatabaseRowStatus(
                    hasStoredKey: hasStoredKey,
                    hasAccessIssue: reference.bookmarkData == nil,
                    cloudState: nil,
                    pendingUploadCount: pendingUploadCount,
                    pendingUploadConflictCount: pendingUploadConflictCount,
                    isDocumentsFileMissing: DatabaseListStore.isDocumentsFileMissing(for: reference)
                )
            }
        }

        rowStatuses = updatedStatuses
    }

    private static func alert(
        for outcome: PendingUploadDrainer.DrainOutcome,
        preferredDatabaseId: UUID
    ) -> PendingUploadAlert? {
        guard let issue = outcome.userIssue else {
            // A conflicted push leaves the marker in place without a user
            // issue; an explicit push still owes the user an explanation.
            let conflictIDs = outcome.conflictDatabaseIDs
            let conflictedId = conflictIDs.contains(preferredDatabaseId)
                ? preferredDatabaseId
                : conflictIDs.min(by: { $0.uuidString < $1.uuidString })
            guard let conflictedId else { return nil }
            return PendingUploadAlert(
                databaseId: conflictedId,
                kind: .conflict,
                title: String(localized: "Pending Upload Conflict"),
                message: String(localized: "A change saved through AutoFill couldn’t be uploaded because the copy of this database in the cloud changed since. Open the database to merge the change into it. You can also export a copy to merge it in another KeePass app, or discard the pending upload. KeeForge keeps a backup of the discarded change on this device.")
            )
        }

        let alert: PendingUploadAlert
        switch issue.kind {
        case .writeScopeRequired:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .writeScopeRequired,
                title: String(localized: "Reconnect Cloud Account"),
                message: issue.message
            )
        case .notAuthenticated:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .notAuthenticated,
                title: String(localized: "Reconnect Cloud Account"),
                message: issue.message
            )
        case .message:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .message,
                title: String(localized: "Couldn't Push Pending Changes"),
                message: issue.message
            )
        }
        return alert
    }

}

@MainActor @Observable
final class PendingLocalRecoveryViewModel {
    private let databaseID: UUID
    private var reference: DatabaseReference?
    private var refreshID = UUID()
    private(set) var targetNeedsRecovery = false
    private(set) var snapshot: PendingLocalSaveStore.RecoverySnapshot?
    private var loadError: String?
    private var actionError: String?
    var errorMessage: String? { actionError ?? loadError }

    init(databaseID: UUID, reference: DatabaseReference? = nil) { self.databaseID = databaseID; self.reference = reference }

    func refresh(reference updatedReference: DatabaseReference? = nil) async {
        let request = UUID()
        refreshID = request
        if let updatedReference { reference = updatedReference }
        let id = databaseID
        do {
            let loaded = try await Task.detached { try PendingLocalSaveStore.recovery(for: id) }.value
            guard request == refreshID, !Task.isCancelled else { return }
            snapshot = loaded
            let targetMismatch: Bool
            if let reference { targetMismatch = await LocalDatabaseSaver.keyTargetNeedsRecovery(for: reference, snapshot: loaded) }
            else { targetMismatch = false }
            guard request == refreshID, !Task.isCancelled else { return }
            targetNeedsRecovery = targetMismatch
            loadError = loaded.ownerUnavailable ? PendingLocalSaveStore.OwnershipError.recoveryRequired.localizedDescription : nil
        } catch { if request == refreshID { loadError = error.localizedDescription } }
    }

    func becameActive() async { await refresh() }

    func retry() async {
        actionError = nil
        await refresh()
    }

    func confirmInstalledKeyChange(reference: DatabaseReference, snapshot: PendingLocalSaveStore.RecoverySnapshot) async {
        if let intent = snapshot.preferenceIntent {
            let outcome = await Task.detached { DatabaseListStore.recoverKeyFilePreference(intent) }.value
            actionError = outcome == .saved ? nil : DatabaseListStore.KeyFilePreferenceError(outcome: outcome).localizedDescription
            await refresh()
            return
        }
        do {
            let outcome = try await Task.detached { try LocalDatabaseSaver.confirmInstalledKeyChange(for: reference, snapshot: snapshot) }.value
            switch outcome {
            case .resolved: actionError = nil
            case .resolvedVisibleWithoutConfirmedDurability: actionError = RecoveryRecordWarning().localizedDescription
            case .retainedForRecovery: actionError = PendingLocalSaveStore.OwnershipError.recoveryRequired.localizedDescription
            }
        } catch { actionError = error.localizedDescription }
        await refresh()
    }

    static func discardMessage(for snapshot: PendingLocalSaveStore.RecoverySnapshot, abandonKeyRecord: Bool) -> String {
        if snapshot.preferenceIntent != nil {
            return String(localized: "Abandoning this key-file preference recovery disables local writes. It does not change the database master key. Keep any snapshots and unsaved edits you need, then remove and add the database again.")
        } else if snapshot.admission?.purpose == .ordinarySave, snapshot.admission?.knownTarget != nil,
                  snapshot.entries.isEmpty, snapshot.keyEvidence?.pending == nil, !abandonKeyRecord, !snapshot.ownerUnavailable {
            return String(localized: "The file contains this change, but its durability or recovery record is unconfirmed. You can make a new explicit save from this version without discarding recovery. Discarding the record does not undo the file change or discard your open draft.")
        } else if snapshot.admission?.purpose == .ordinarySave, snapshot.keyEvidence?.pending == nil, !abandonKeyRecord, !snapshot.ownerUnavailable {
            return String(localized: "This local save has an unresolved outcome. Export the database and any unsaved changes before discarding this recovery record. Discarding does not undo a replacement and deletes only the snapshots listed here; later snapshots and your open draft are kept.")
        } else if abandonKeyRecord || snapshot.ownerUnavailable || snapshot.admission?.purpose.isMasterKeyChange == true || snapshot.keyEvidence?.pending != nil {
            return String(localized: "Discarding this recovery record disables local writes. It does not undo a saved master-key change. Export any snapshots and unsaved edits you need first, then remove and add the database again using the correct master key. Changes not saved elsewhere will be lost.")
        } else {
            return String(localized: "This permanently deletes the selected AutoFill snapshots and their recovery record. Changes not saved elsewhere will be lost. New snapshots added after this confirmation was opened are kept.")
        }
    }

    func discard(_ confirmed: PendingLocalSaveStore.RecoverySnapshot, abandonKeyRecord: Bool = false) async {
        do {
            let outcome = try await Task.detached { try PendingLocalSaveStore.discard(confirmed, abandonKeyRecord: abandonKeyRecord) }.value
            switch outcome {
            case .resolved:
                actionError = nil
                if !abandonKeyRecord, let reference {
                    let retirement = await Task.detached { LocalDatabaseSaver.retireSettledKeyWitness(for: reference) }.value
                    if retirement != .resolved { actionError = RecoveryRecordWarning().localizedDescription }
                }
            case .resolvedVisibleWithoutConfirmedDurability: actionError = RecoveryRecordWarning().localizedDescription
            case .retainedForRecovery: actionError = PendingLocalSaveStore.OwnershipError.recoveryRequired.localizedDescription
            }
        } catch { actionError = error.localizedDescription }
        await refresh()
    }
}
