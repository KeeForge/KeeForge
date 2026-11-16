#if os(macOS)
import Foundation
import Observation

@MainActor @Observable
final class MacDatabaseSettingsModel {
    enum Tab: CaseIterable {
        case general, security, sync, autoFill, backups
        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .security: String(localized: "Security")
            case .sync: String(localized: "Sync")
            case .autoFill: String(localized: "AutoFill")
            case .backups: String(localized: "Backups")
            }
        }
        /// The DatabaseSettingsTabs board's glyphs; General and Security match the Settings window's.
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .security: "lock.shield"
            case .sync: "arrow.triangle.2.circlepath"
            case .autoFill: "ellipsis.rectangle"
            case .backups: "archivebox"
            }
        }
    }
    /// The Sync tab's Status row: the status card's own rules, worded for a settings row.
    struct SyncStatus: Equatable {
        enum Tone: Equatable { case healthy, neutral, warning }
        var text: String
        var tone: Tone
        /// The status card's action, offered only where a database window can carry it out.
        var action: MacDatabaseStatus.Action?
        var isActionEnabled = true
    }

    let reference: DatabaseReference
    let session: DatabaseViewModel?
    /// Set by a database window: its status card's status, and that card's actions.
    @ObservationIgnored var windowStatus: (@MainActor () -> MacDatabaseStatus)?
    @ObservationIgnored var performStatusAction: (@MainActor (MacDatabaseStatus.Action) -> Void)?
    let list: DatabaseListViewModel
    var selection = Tab.general
    var nickname: String
    var fileInfo: DatabaseFileInfo?
    var backups: [DatabaseExportService.Backup] = []
    var isLoading = true
    private var loadRevision = 0
    private var loadedHash: Data?
    private var hasLoadedFacts = false
    private let loadFileInfo: @Sendable (DatabaseReference) async -> DatabaseFileInfo?

    init(reference: DatabaseReference, session: DatabaseViewModel? = nil, list: DatabaseListViewModel? = nil,
         loadFileInfo: @escaping @Sendable (DatabaseReference) async -> DatabaseFileInfo? = { await DatabaseFileInfoLoader.load(for: $0) }) {
        self.reference = reference
        self.session = session
        self.list = list ?? DatabaseListViewModel()
        self.loadFileInfo = loadFileInfo
        nickname = reference.nickname ?? ""
        if list == nil {
            self.list.autoFillEnabledRefreshHandler = { [weak session] id in
                guard let session, session.databaseReference.id == id else { return }
                session.populateCredentialStoreIfUnlocked()
            }
        }
    }

    var current: DatabaseReference { list.databases.first { $0.id == reference.id } ?? session?.databaseReference ?? reference }
    var tabs: [Tab] {
        Tab.allCases.filter { $0 != .sync || current.cloudSyncMetadata?.providerKind == .webDAV || current.cloudSyncMetadata?.providerKind == .ftp }
    }
    var hasDestination: Bool { session?.state == .unlocked && session?.autoFillDestinationGroup != nil }
    var fixedReadOnly: Bool {
        session?.isFormatReadOnly == true || fileInfo?.summary?.formatVersion.requiresReadOnlyMode == true ||
        session?.sessionUsesHardwareKey == true || current.hardwareKey != nil
    }
    var isReadOnly: Bool { fixedReadOnly || current.isReadOnly || session?.isReadOnly == true }
    var canChangeSecurity: Bool { session?.state == .unlocked && !isReadOnly && session?.isSaving == false && !isLoading && fileInfo?.summary != nil }
    var facts: String {
        SettingsSummaryText.joined([fileInfo?.summary?.formatDisplayName,
            fileInfo?.fileSizeBytes?.formatted(.byteCount(style: .file)),
            fileInfo?.modifiedAt.map { String(localized: "Modified \($0.formatted(date: .abbreviated, time: .shortened))") }])
    }
    var history: String {
        SettingsSummaryText.joined([
            String(localized: "Added \(current.addedAt.formatted(date: .abbreviated, time: .omitted))"),
            current.lastOpenedAt.map { String(localized: "Last opened \($0.formatted(.relative(presentation: .named)))") }
        ])
    }
    var cachedCopyCaption: String { String(localized: "Values reflect the locally cached copy of this database.") }
    var masterKeySummary: String {
        guard let composition = session?.masterKeyComposition else { return String(localized: "Unavailable") }
        switch (composition.hasPassword, composition.hasKeyFile) {
        case (true, true): return String(localized: "Password and key file")
        case (true, false): return String(localized: "Password")
        case (false, true): return String(localized: "Key file")
        case (false, false): return String(localized: "Unavailable")
        }
    }
    var masterKeyChangedText: String? {
        current.lastMasterKeyChangeAt.map { String(localized: "Changed \($0.formatted(.relative(presentation: .named)))") }
    }
    var readOnlyCaption: String {
        if session?.isFormatReadOnly == true || fileInfo?.summary?.formatVersion.requiresReadOnlyMode == true {
            return String(localized: "Legacy KDBX 3.1 databases can be opened, but KeeForge intentionally keeps them read-only.")
        }
        if session?.sessionUsesHardwareKey == true || current.hardwareKey != nil {
            return String(localized: "Databases unlocked with a YubiKey open read-only for now. Saving them is not supported yet.")
        }
        return String(localized: "You can still open this database, but create, edit, and delete actions stay blocked until you turn editing back on.")
    }
    func refreshFactsIfNeeded() async {
        guard !hasLoadedFacts || loadedHash != session?.openTimeSHA512 else { return }
        await reloadFacts()
    }
    func reloadFacts() async {
        isLoading = true
        loadRevision += 1
        let revision = loadRevision
        let hash = session?.openTimeSHA512
        list.reload()
        let info = await loadFileInfo(current)
        guard !Task.isCancelled, revision == loadRevision else { return }
        loadedHash = hash
        hasLoadedFacts = true
        fileInfo = info
        backups = DatabaseExportService.backups(for: current)
        isLoading = false
    }
    func commitNickname() {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        list.reload()
        guard let stored = list.databases.first(where: { $0.id == reference.id }), stored.nickname != value else { return }
        if let session { session.setNickname(value); list.reload() }
        else { list.setNickname(value, for: current) }
    }
    func setReadOnly(_ value: Bool) {
        guard !fixedReadOnly, !isLoading else { return }
        if let session { session.setReadOnly(value); list.reload() }
        else { list.setReadOnly(value, for: current) }
    }
    func setSyncOnOpen(_ enabled: Bool) {
        let policy: CloudSyncPolicy = enabled ? .onOpen : .manual
        if let session { session.setCloudSyncPolicy(policy); list.reload() }
        else { list.setCloudSyncPolicy(policy, for: current) }
    }
    var syncStatus: SyncStatus {
        let status = windowStatus?() ?? MacDatabaseStatus(listSyncState)
        let healthy = String(localized: "Healthy")
        var result: SyncStatus
        switch status.line.dot {
        case .warning: result = SyncStatus(text: status.line.state ?? healthy, tone: .warning)
        case .neutral: result = SyncStatus(text: status.line.state ?? healthy, tone: .neutral)
        case .synced, nil: result = SyncStatus(text: healthy, tone: .healthy)
        }
        if isReadOnly { result.text += MacDatabaseStatus.separator + String(localized: "Read-only") }
        if performStatusAction != nil, let action = status.action {
            result.action = action
            result.isActionEnabled = status.isActionEnabled
        }
        return result
    }

    /// What the Databases window knows without an open session: the account, pending uploads and the cached copy's warning.
    private var listSyncState: MacDatabaseStatus.State {
        var state = MacDatabaseStatus.State()
        let reference = current
        state.name = reference.displayName
        state.storage = .cloud(provider: reference.cloudProviderKind?.displayName ?? String(localized: "cloud"))
        state.pendingUploads = MacPendingUploads.list(list).counts(reference.id)
        if let cloud = list.cloudState(for: reference) {
            if !cloud.isConnected { state.cachedCopy = .disconnected }
            else if let warning = cloud.warningText { state.cachedCopy = .failed(warning) }
        }
        state.lastSyncedAt = reference.cloudSyncMetadata?.lastSyncedAt
        state.isReadOnly = isReadOnly
        return state
    }

    var isSyncing: Bool { session?.isSyncingCloud == true }
    var canSyncNow: Bool { session?.canSyncCloudNow == true }
    /// Why Sync Now is unavailable, or what the last sync did.
    var syncNowNote: String? {
        guard let session, session.state == .unlocked else { return String(localized: "Unlock this database to sync it.") }
        if let outcome = session.cloudSyncOutcome { return outcome.message }
        if session.isDirty || session.hasUnsavedEditor { return String(localized: "Save your changes before syncing.") }
        return nil
    }

    func setAutoFillEnabled(_ enabled: Bool) { list.setAutoFillEnabled(enabled, for: current) }
    func syncNow() async { await session?.syncCloudNow(); list.reload() }
}
#endif
