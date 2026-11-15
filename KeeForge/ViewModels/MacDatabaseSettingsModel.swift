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
    }
    let reference: DatabaseReference
    let session: DatabaseViewModel?
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
        guard current.nickname != value else { return }
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
    func setAutoFillEnabled(_ enabled: Bool) { list.setAutoFillEnabled(enabled, for: current) }
    func syncNow() async { await session?.syncCloudNow(); list.reload() }
}
#endif
