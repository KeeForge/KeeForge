#if os(macOS)
import Foundation

/// AutoFill uploads waiting for one database. The database list owns the
/// markers and the push, so a window reads and pushes them through this.
struct MacPendingUploads {
    struct Counts: Equatable {
        var waiting = 0
        var conflicts = 0
    }

    var counts: @MainActor (UUID) -> Counts
    /// What went wrong, for the window that asked to show.
    var push: @MainActor (UUID) async -> PendingUploadAlert?

    static let none = MacPendingUploads(counts: { _ in Counts() }, push: { _ in nil })
}

/// What a Mac database window says about its database: the sidebar status
/// card (and the detail toolbar's status while the sidebar is hidden), and the
/// notices above the entry list. It never carries a secret.
struct MacDatabaseStatus: Equatable {
    /// The dot before the status line. A local database in its normal state has none.
    enum Dot: Equatable {
        case synced
        case neutral
        case warning
    }

    enum Action: Equatable {
        case retrySave
        case resolveConflict
        case reconnect(provider: String)
        case pushPendingUploads

        var title: String {
            switch self {
            case .retrySave: String(localized: "Retry Save")
            case .resolveConflict: String(localized: "Resolve…")
            case .reconnect(let provider): String(localized: "Reconnect \(provider)")
            case .pushPendingUploads: String(localized: "Push Pending Changes")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .retrySave: "database.unsaved-indicator"
            case .resolveConflict: "save-conflict.resolve"
            case .reconnect: "sidebar.status-card.reconnect"
            case .pushPendingUploads: "sidebar.status-card.push-pending"
            }
        }
    }

    /// The storage, then the state; the state is emphasized when it is a warning.
    struct Line: Equatable {
        var storage: String?
        var state: String?
        var dot: Dot?

        var text: String {
            [storage, state].compactMap(\.self).joined(separator: MacDatabaseStatus.separator)
        }

        /// The detail toolbar has room for the state alone.
        var shortText: String {
            state ?? text
        }
    }

    struct Notice: Equatable, Identifiable {
        enum Kind: String {
            case reconnect
            case uploadConflict
            case cloud
            case syncResult
        }

        enum Action: Equatable {
            case reconnect(provider: String)
            case mergePendingUploads
            case dismissSyncResult

            var title: String {
                switch self {
                case .reconnect(let provider): String(localized: "Reconnect \(provider)")
                case .mergePendingUploads: String(localized: "Merge Changes")
                case .dismissSyncResult: String(localized: "Dismiss")
                }
            }
        }

        let kind: Kind
        let text: String
        var action: Action?
        var isWarning = false
        var isActionEnabled = true

        var id: Kind { kind }

        var accessibilityIdentifier: String {
            switch kind {
            case .reconnect: "cloud-reauth-banner"
            case .uploadConflict: "pending-upload-banner"
            case .cloud: "cloud-sync-notice"
            case .syncResult: "cloud-sync-result-notice"
            }
        }

        var actionAccessibilityIdentifier: String {
            switch kind {
            case .reconnect: "cloud-reauth-banner.reconnect"
            case .uploadConflict: "pending-upload-banner.merge"
            case .cloud: "cloud-sync-notice.action"
            case .syncResult: "cloud-sync-result-notice.dismiss"
            }
        }
    }

    /// The session facts the card and notices read.
    struct State: Equatable {
        enum Storage: Equatable {
            case local(filename: String)
            case cloud(provider: String)
        }

        /// How the open (or the last Sync Now) fell back to the cached copy.
        enum CachedCopy: Equatable {
            case offline
            case disconnected
            case failed(String)
        }

        enum SyncResult: Equatable {
            case failed
            case waits(String)
        }

        var name = ""
        var storage = Storage.local(filename: "")
        var isReadOnly = false
        var isSaving = false
        var isDirty = false
        var hasSaveConflict = false
        var needsReconnect = false
        var isReconnectInFlight = false
        var hasPendingUploadConflict = false
        var pendingUploads = MacPendingUploads.Counts()
        var isSyncing = false
        var cachedCopy: CachedCopy?
        var isRefreshPending = false
        var syncResult: SyncResult?
        var lastSyncedAt: Date?
        var canSyncNow = false
        var canLock = false
        var canShowSettings = false

        /// The session's flag or the list's live count, whichever learned of the conflict first.
        var hasUploadConflict: Bool {
            hasPendingUploadConflict || (pendingUploads.conflicts > 0 && isReadOnly == false)
        }

        init() {}

        @MainActor
        init(session: DatabaseViewModel, presentation: MacWorkspacePresentation) {
            _ = presentation.statusClockTick
            let reference = session.databaseReference
            name = session.databaseDisplayName
            if reference.isCloudBacked {
                storage = .cloud(provider: reference.cloudProviderKind?.displayName ?? String(localized: "cloud"))
                pendingUploads = presentation.pendingUploads.counts(reference.id)
                isSyncing = session.isSyncingCloud
                cachedCopy = session.cloudSyncBannerText.map { text in
                    switch text {
                    case CloudSyncResolution.offlineCachedBannerMessage: .offline
                    case CloudSyncResolution.disconnectedCachedBannerMessage: .disconnected
                    default: .failed(text)
                    }
                }
                isRefreshPending = session.isCloudRefreshPending
                syncResult = switch session.cloudSyncOutcome {
                case .failed: .failed
                case let outcome? where outcome == .updateWaitsForSave || outcome == .updateWaitsForUnlock:
                    .waits(outcome.message)
                default: nil
                }
                lastSyncedAt = reference.cloudSyncMetadata?.lastSyncedAt
            } else {
                storage = .local(filename: session.databaseFilename)
            }
            isReadOnly = session.isReadOnly
            isSaving = session.isSaving
            isDirty = session.isDirty
            hasSaveConflict = session.saveConflict != nil
            needsReconnect = session.saveError?.isWriteScopeRequired == true
            isReconnectInFlight = presentation.isCloudReconnectInFlight
            hasPendingUploadConflict = session.hasPendingUploadConflict
            let commands = MacWorkspaceCommands(session: session, presentation: presentation)
            canSyncNow = commands.canSyncNow
            canShowSettings = commands.canShowDatabaseSettings
            canLock = DatabaseCommands(session: session).canLock
        }
    }

    static let separator = " · "

    let name: String
    let isReadOnly: Bool
    let line: Line
    let action: Action?
    let isActionEnabled: Bool
    /// A database on this Mac has nothing to sync, so it has no Sync Now.
    let offersSyncNow: Bool
    let canSyncNow: Bool
    let canLock: Bool
    let canShowSettings: Bool
    let notices: [Notice]

    init(_ state: State, now: Date = .now) {
        name = state.name
        isReadOnly = state.isReadOnly
        let (line, action) = Self.line(for: state, now: now)
        self.line = line
        self.action = action
        if case .reconnect = action {
            isActionEnabled = state.isReconnectInFlight == false
        } else {
            isActionEnabled = action != nil
        }
        if case .cloud = state.storage { offersSyncNow = true } else { offersSyncNow = false }
        canSyncNow = state.canSyncNow && state.isSaving == false
        canLock = state.canLock && state.isSaving == false
        canShowSettings = state.canShowSettings && state.isSaving == false
        notices = Self.notices(for: state)
    }

    @MainActor
    static func make(session: DatabaseViewModel, presentation: MacWorkspacePresentation, now: Date = .now) -> MacDatabaseStatus {
        MacDatabaseStatus(State(session: session, presentation: presentation), now: now)
    }

    // MARK: - Rules

    private static func line(for state: State, now: Date) -> (Line, Action?) {
        let storage: String
        var provider: String?
        switch state.storage {
        case .local(let filename): storage = filename
        case .cloud(let name):
            storage = name
            provider = name
        }
        func warning(_ text: String, prefixed: Bool = true) -> Line {
            Line(storage: prefixed ? storage : nil, state: text, dot: .warning)
        }

        if state.isSaving {
            return (Line(storage: storage, state: String(localized: "Saving…"), dot: .neutral), nil)
        }
        if state.hasSaveConflict {
            return (warning(String(localized: "Save conflict")), .resolveConflict)
        }
        if state.needsReconnect, let provider {
            return (warning(String(localized: "Reconnect needed")), .reconnect(provider: provider))
        }
        if state.isDirty {
            return (warning(String(localized: "Changes not saved"), prefixed: false), .retrySave)
        }
        guard provider != nil else {
            return (Line(storage: storage, state: String(localized: "On This Mac")), nil)
        }
        if state.hasUploadConflict {
            let count = max(state.pendingUploads.conflicts, 1)
            return (warning(String(localized: "\(count) pending upload conflicts")), nil)
        }
        if state.pendingUploads.waiting > 0 {
            let count = state.pendingUploads.waiting
            return (warning(String(localized: "\(count) changes waiting to upload")), .pushPendingUploads)
        }
        if state.isSyncing {
            return (Line(storage: storage, state: String(localized: "Syncing…"), dot: .neutral), nil)
        }
        let synced = state.lastSyncedAt.map { syncedText(at: $0, now: now) }
        switch state.cachedCopy {
        case .offline:
            let text = [String(localized: "Offline"), synced].compactMap(\.self).joined(separator: separator)
            return (Line(storage: storage, state: text, dot: .neutral), nil)
        case .disconnected:
            return (warning(String(localized: "Reconnect needed")), nil)
        case .failed:
            return (warning(String(localized: "Sync failed")), nil)
        case nil:
            break
        }
        if state.syncResult == .failed {
            return (warning(String(localized: "Sync failed")), nil)
        }
        guard let synced else { return (Line(storage: storage, dot: .neutral), nil) }
        return (Line(storage: storage, state: synced, dot: state.isRefreshPending ? .neutral : .synced), nil)
    }

    static func syncedText(at date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "Synced just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Synced \(relative)")
    }

    private static func notices(for state: State) -> [Notice] {
        guard case .cloud(let provider) = state.storage else { return [] }
        var notices: [Notice] = []
        if state.needsReconnect {
            notices.append(Notice(kind: .reconnect, text: String(localized: "Reconnect \(provider) to save changes."),
                                  action: .reconnect(provider: provider), isWarning: true,
                                  isActionEnabled: state.isReconnectInFlight == false))
        }
        if state.hasUploadConflict, state.isSaving == false {
            notices.append(Notice(kind: .uploadConflict, text: String(
                localized: "A change saved through AutoFill couldn’t be uploaded because the cloud copy changed. Merge it into this database to upload it."
            ), action: .mergePendingUploads, isWarning: true))
        }
        switch state.cachedCopy {
        case .offline:
            notices.append(Notice(kind: .cloud, text: CloudSyncResolution.offlineCachedBannerMessage))
        case .disconnected:
            notices.append(Notice(kind: .cloud, text: CloudSyncResolution.disconnectedCachedBannerMessage, isWarning: true))
        case .failed(let text):
            notices.append(Notice(kind: .cloud, text: text, isWarning: true))
        case nil:
            if state.isRefreshPending {
                notices.append(Notice(kind: .cloud, text: String(localized: "Opened without checking \(provider) for changes.")))
            }
        }
        if case .waits(let text) = state.syncResult {
            notices.append(Notice(kind: .syncResult, text: text, action: .dismissSyncResult))
        }
        return notices
    }
}
#endif
