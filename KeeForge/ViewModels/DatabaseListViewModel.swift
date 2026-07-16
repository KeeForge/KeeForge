import Foundation

struct DatabaseRowStatus: Equatable, Sendable {
    var hasStoredKey: Bool
    var hasAccessIssue: Bool
    var cloudState: CloudRowState?
    var pendingUploadCount: Int = 0
    var pendingUploadConflictCount: Int = 0
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
    private(set) var rowStatuses: [UUID: DatabaseRowStatus] = [:]
    private(set) var pendingUploadAlert: PendingUploadAlert?
    private(set) var isAutoFillProviderEnabled: Bool?
    private(set) var isAutoFillTipDismissed = AutoFillStatusService.tipDismissed
    private var didConsumeInitialLaunchSelection = false
    private let pendingUploadDrainer: PendingUploadDrainer

    init(pendingUploadDrainer: PendingUploadDrainer = PendingUploadDrainer()) {
        self.pendingUploadDrainer = pendingUploadDrainer
        reload()
    }

    func reload() {
        databases = DatabaseListStore.databases
        refreshRowStatuses()
    }

    func databaseToAutoOpenOnLaunch() -> DatabaseReference? {
        guard didConsumeInitialLaunchSelection == false else { return nil }
        didConsumeInitialLaunchSelection = true
        guard databases.count == 1 else { return nil }
        guard let reference = databases.first, reference.isQuickLaunch else { return nil }
        return reference
    }

    func addDatabase(from url: URL) throws -> DatabaseReference {
        let reference = try DatabaseListStore.add(url: url)
        reload()
        return reference
    }

    func addCloudDatabase(selection: CloudDatabaseSelection) -> DatabaseReference {
        let reference = DatabaseListStore.addCloud(
            provider: selection.provider,
            accountId: selection.account.id,
            file: selection.file
        )
        reload()
        return reference
    }

    func removeDatabase(_ reference: DatabaseReference) {
        DatabaseListStore.remove(id: reference.id)
        reload()
    }

    func moveDatabases(from source: IndexSet, to destination: Int) {
        DatabaseListStore.move(from: source, to: destination)
        reload()
    }

    func toggleQuickLaunch(for reference: DatabaseReference) {
        let currentValue = databases.first(where: { $0.id == reference.id })?.isQuickLaunch ?? reference.isQuickLaunch

        for database in databases where database.id != reference.id && database.isQuickLaunch {
            var updatedDatabase = database
            updatedDatabase.isQuickLaunch = false
            DatabaseListStore.update(updatedDatabase)
        }

        update(reference) { updatedReference in
            updatedReference.isQuickLaunch = !currentValue
        }
    }

    func setNickname(_ nickname: String?, for reference: DatabaseReference) {
        update(reference) { updatedReference in
            updatedReference.nickname = nickname
        }
    }

    func setReadOnly(_ isReadOnly: Bool, for reference: DatabaseReference) {
        update(reference) { updatedReference in
            updatedReference.isReadOnly = isReadOnly
        }
    }

    func setKeyFile(url: URL?, for reference: DatabaseReference) throws {
        try update(reference) { updatedReference in
            if let url {
                updatedReference.keyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
                updatedReference.keyFileFilename = url.lastPathComponent
            } else {
                updatedReference.keyFileBookmarkData = nil
                updatedReference.keyFileFilename = nil
            }
        }
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

    func lastOpenedDescription(
        for reference: DatabaseReference,
        showsUsageStats: Bool = SettingsService.showDatabaseUsageStats
    ) -> String? {
        guard showsUsageStats else { return nil }
        guard let lastOpenedAt = reference.lastOpenedAt else { return nil }
        let relative = Self.relativeDateFormatter.localizedString(for: lastOpenedAt, relativeTo: .now)
        return "Last opened \(relative)"
    }

    func detailSubtitle(for reference: DatabaseReference) -> String? {
        if reference.showsFilenameSubtitle {
            return reference.filename
        }
        return nil
    }

    func drainPendingUploadsOnAppActive() async {
        let outcome = await pendingUploadDrainer.drainAll()
        applyDrainOutcome(outcome, surfaceAlerts: false)
    }

    func pushPendingChanges(for reference: DatabaseReference) async {
        let outcome = await pendingUploadDrainer.drain(databaseId: reference.id)
        applyDrainOutcome(outcome, surfaceAlerts: true)
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

    func refreshAutoFillStatus() async {
        isAutoFillProviderEnabled = await AutoFillStatusService.isAutoFillEnabled()
    }

    func requestEnableAutoFill() async {
        // nil means the iOS 17 deep-link path; the scene-active re-check
        // picks up the result when the user returns from Settings.
        if await AutoFillStatusService.requestEnableAutoFill() == true {
            isAutoFillProviderEnabled = true
        }
    }

    func dismissAutoFillTip() {
        AutoFillStatusService.tipDismissed = true
        isAutoFillTipDismissed = true
    }

    // MARK: - Private

    private func update(_ reference: DatabaseReference, mutate: (inout DatabaseReference) throws -> Void) rethrows {
        guard var updatedReference = databases.first(where: { $0.id == reference.id }) else { return }
        try mutate(&updatedReference)
        DatabaseListStore.update(updatedReference)
        reload()
    }

    private func refreshRowStatuses() {
        var updatedStatuses: [UUID: DatabaseRowStatus] = [:]
        let pendingMarkers = PendingUploadQueue.listMarkers()
        let pendingCounts = Dictionary(
            pendingMarkers.map { ($0.marker.databaseId, 1) },
            uniquingKeysWith: +
        )
        let pendingConflictCounts = Dictionary(
            pendingMarkers.compactMap { storedMarker in
                storedMarker.marker.lastSyncError == nil ? nil : (storedMarker.marker.databaseId, 1)
            },
            uniquingKeysWith: +
        )

        for reference in databases {
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
                updatedStatuses[reference.id] = DatabaseRowStatus(
                    hasStoredKey: hasStoredKey,
                    hasAccessIssue: reference.bookmarkData == nil,
                    cloudState: nil,
                    pendingUploadCount: pendingUploadCount,
                    pendingUploadConflictCount: pendingUploadConflictCount
                )
            }
        }

        rowStatuses = updatedStatuses
        databases = DatabaseListStore.databases
    }

    private func applyDrainOutcome(_ outcome: PendingUploadDrainer.DrainOutcome, surfaceAlerts: Bool) {
        reload()

        guard surfaceAlerts, let issue = outcome.userIssue else { return }

        let alert: PendingUploadAlert
        switch issue.kind {
        case .writeScopeRequired:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .writeScopeRequired,
                title: "Reconnect Cloud Account",
                message: issue.message
            )
        case .notAuthenticated:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .notAuthenticated,
                title: "Reconnect Cloud Account",
                message: issue.message
            )
        case .message:
            alert = PendingUploadAlert(
                databaseId: issue.databaseId,
                kind: .message,
                title: "Couldn't Push Pending Changes",
                message: issue.message
            )
        }

        pendingUploadAlert = alert
    }

}
