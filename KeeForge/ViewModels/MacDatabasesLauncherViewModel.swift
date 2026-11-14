#if os(macOS)
import Foundation
import Observation

/// What the Databases window offers. It lists and manages references and asks
/// the app to open or front a database's window; it never holds a session.
@MainActor @Observable
final class MacDatabasesLauncherViewModel {
    enum OpenAction: Equatable {
        case open
        case front
    }

    enum EmptyState: Equatable {
        /// Nothing has been added yet.
        case firstRun
        /// Every saved database uses a provider this Mac cannot reach.
        case noneAvailable

        var title: String { String(localized: "No Databases") }

        var message: String {
            switch self {
            case .firstRun: String(localized: "Create a database, open a .kdbx file or connect to a server to get started.")
            case .noneAvailable: String(localized: "None of your databases can be opened on this Mac.")
            }
        }
    }

    /// One database row: where it lives and what state it is in. Never a secret.
    struct Row: Equatable, Identifiable {
        enum Storage: Equatable {
            case thisMac
            case server
        }

        /// The line under the subtitle: a problem in orange, otherwise when it was last opened.
        enum Detail: Equatable {
            case problem(String)
            case lastOpened(String)

            var text: String {
                switch self {
                case .problem(let text), .lastOpened(let text): text
                }
            }
        }

        let id: UUID
        let title: String
        /// "Personal.kdbx · WebDAV", "archive.kdbx · On This Mac".
        let subtitle: String
        let storage: Storage
        let detail: Detail?
        /// Its window is open and unlocked; every other database shows as locked.
        let isUnlocked: Bool
        let isQuickLaunch: Bool
        let isReadOnly: Bool
        /// A key saved for Touch ID.
        let offersTouchID: Bool
    }

    /// The row menu, in order. Open comes first; Remove is last.
    enum RowAction: Equatable {
        case open
        case rename
        case setKeyFile
        case changeKeyFile
        case clearKeyFile
        case quickLaunch(isOn: Bool)
        case pushPendingChanges
        case discardPendingUpload
        case readOnly(isOn: Bool)
        case exportCopy
        case details
        case remove

        var title: String {
            switch self {
            case .open: String(localized: "Open")
            case .rename: String(localized: "Rename")
            case .setKeyFile: String(localized: "Set Key File")
            case .changeKeyFile: String(localized: "Change Key File")
            case .clearKeyFile: String(localized: "Clear Key File")
            case .quickLaunch: String(localized: "Quick Launch")
            case .pushPendingChanges: String(localized: "Push pending changes")
            case .discardPendingUpload: String(localized: "Discard pending upload")
            case .readOnly: String(localized: "Read-only")
            case .exportCopy: DatabaseExportLabels.currentCopy
            case .details: String(localized: "Database Details")
            case .remove: String(localized: "Remove")
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .open: "database-row.open-action"
            case .rename: "database-row.rename"
            case .setKeyFile, .changeKeyFile: "database-row.key-file"
            case .clearKeyFile: "database-row.clear-key-file"
            case .quickLaunch: "database-row.quick-launch-toggle"
            case .pushPendingChanges: "database-row.push-pending-action"
            case .discardPendingUpload: "database-row.discard-pending-action"
            case .readOnly: "database-row.read-only-toggle"
            case .exportCopy: "database-row.export-copy-action"
            case .details: "database-row.details"
            case .remove: "database-row.remove"
            }
        }
    }

    /// The SwiftUI sheet the window shows; one at a time.
    enum Sheet: Identifiable, Equatable {
        case newDatabase
        case connect(CloudProviderKind)
        case details(UUID)

        var id: String {
            switch self {
            case .newDatabase: "new-database"
            case .connect(let provider): "connect-\(provider.rawValue)"
            case .details(let databaseID): "details-\(databaseID.uuidString)"
            }
        }
    }

    var selectedDatabaseID: UUID?
    var whatsNewRelease: WhatsNewRelease?
    var isChoosingEnrollmentDestination = false
    var sheet: Sheet?
    /// File ▸ Connect to Server… with several server types offers them first.
    var isChoosingServer = false
    /// Waiting for the user to confirm Remove.
    var pendingRemoval: DatabaseReference?
    /// A removal refused because the database's window still holds unsaved work.
    var refusedRemoval: DatabaseReference?
    var renameTarget: DatabaseReference?
    var keyFileTarget: DatabaseReference?
    var pendingUploadDiscardTarget: DatabaseReference?
    var exportRequest: DatabaseExportRequest?
    var selectionAlert: DocumentPickerService.SelectionAlert?

    @ObservationIgnored private let references: @MainActor () -> [DatabaseReference]
    @ObservationIgnored var status: @MainActor (DatabaseReference) -> DatabaseRowStatus = { _ in
        DatabaseRowStatus(hasStoredKey: false, hasAccessIssue: false, cloudState: nil)
    }
    @ObservationIgnored var lastOpenedDescription: @MainActor (DatabaseReference) -> String? = { _ in nil }
    @ObservationIgnored var hasWindow: @MainActor (UUID) -> Bool = { _ in false }
    @ObservationIgnored var isUnlocked: @MainActor (UUID) -> Bool = { _ in false }
    @ObservationIgnored var openDatabase: @MainActor (DatabaseReference) -> Void = { _ in }
    @ObservationIgnored var openCreatedDatabase: @MainActor (CreatedDatabase) -> Void = { _ in }
    @ObservationIgnored var hasUnsavedWork: @MainActor (UUID) -> Bool = { _ in false }
    @ObservationIgnored var removeDatabase: @MainActor (DatabaseReference) -> Void = { _ in }
    @ObservationIgnored var chooseEnrollmentDestinationHandler: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var cancelEnrollmentDestinationHandler: @MainActor () -> Void = {}
    /// The list's mutations: quick launch, read-only, key file, nickname, pending uploads.
    @ObservationIgnored weak var list: DatabaseListViewModel?

    init(references: @escaping @MainActor () -> [DatabaseReference]) {
        self.references = references
    }

    static func isAvailable(_ reference: DatabaseReference) -> Bool {
        switch reference.source {
        case .local: true
        case .cloud(let metadata): metadata.providerKind.map(isServerProvider) == true
        }
    }

    /// Dropbox and OneDrive are never Mac destinations, even if a build were to report them available.
    static func isServerProvider(_ provider: CloudProviderKind) -> Bool {
        (provider == .webDAV || provider == .ftp) && provider.isAvailableOnCurrentPlatform
    }

    var databases: [DatabaseReference] { references().filter(Self.isAvailable) }

    var connectProviders: [CloudProviderKind] {
        CloudProviderRegistry.availableProviders.filter(Self.isServerProvider)
    }

    var emptyState: EmptyState? {
        let all = references()
        if all.isEmpty { return .firstRun }
        return all.contains(where: Self.isAvailable) ? nil : .noneAvailable
    }

    // MARK: - Rows

    var rows: [Row] {
        databases.map { reference in
            Self.row(for: reference, status: status(reference), isUnlocked: isUnlocked(reference.id),
                lastOpened: lastOpenedDescription(reference))
        }
    }

    static func row(for reference: DatabaseReference, status: DatabaseRowStatus, isUnlocked: Bool,
                    lastOpened: String?) -> Row {
        let location = reference.cloudProviderKind?.displayName ?? String(localized: "On This Mac")
        let summary = DatabaseRowStatusSummary(isReadOnly: reference.isReadOnly, isQuickLaunch: reference.isQuickLaunch,
            status: status)
        let detail = summary.notices.first.map { Row.Detail.problem($0.text) } ?? lastOpened.map(Row.Detail.lastOpened)
        return Row(
            id: reference.id,
            title: reference.displayName,
            subtitle: [reference.filename, location].joined(separator: MacDatabaseStatus.separator),
            storage: reference.isCloudBacked ? .server : .thisMac,
            detail: detail,
            isUnlocked: isUnlocked,
            isQuickLaunch: reference.isQuickLaunch,
            isReadOnly: reference.isReadOnly,
            offersTouchID: status.hasStoredKey
        )
    }

    func rowActions(for reference: DatabaseReference) -> [RowAction] {
        guard let current = databases.first(where: { $0.id == reference.id }) else { return [] }
        let status = status(current)
        var actions: [RowAction] = [.open, .rename]
        actions += current.keyFileFilename == nil ? [.setKeyFile] : [.changeKeyFile, .clearKeyFile]
        actions.append(.quickLaunch(isOn: current.isQuickLaunch))
        if status.pendingUploadCount > 0 { actions.append(.pushPendingChanges) }
        if status.pendingUploadConflictCount > 0 { actions.append(.discardPendingUpload) }
        actions += [.readOnly(isOn: current.isReadOnly), .exportCopy, .details, .remove]
        return actions
    }

    func perform(_ action: RowAction, on reference: DatabaseReference) {
        guard let current = databases.first(where: { $0.id == reference.id }) else { return }
        switch action {
        case .open: open(current)
        case .rename: renameTarget = current
        case .setKeyFile, .changeKeyFile: keyFileTarget = current
        case .clearKeyFile: try? list?.setKeyFile(url: nil, for: current)
        case .quickLaunch: list?.toggleQuickLaunch(for: current)
        case .pushPendingChanges:
            let list = list
            Task { await list?.pushPendingChanges(for: current) }
        case .discardPendingUpload: pendingUploadDiscardTarget = current
        case .readOnly: list?.setReadOnly(!current.isReadOnly, for: current)
        case .exportCopy: exportRequest = .currentCopy(current)
        case .details: sheet = .details(current.id)
        case .remove: beginRemoval(current)
        }
    }

    // MARK: - Opening

    func openAction(for reference: DatabaseReference) -> OpenAction? {
        guard Self.isAvailable(reference) else { return nil }
        return hasWindow(reference.id) ? .front : .open
    }

    var selectedDatabase: DatabaseReference? {
        databases.first { $0.id == selectedDatabaseID }
    }

    func open(_ reference: DatabaseReference) {
        guard let current = databases.first(where: { $0.id == reference.id }), openAction(for: current) != nil else { return }
        selectedDatabaseID = current.id
        openDatabase(current)
    }

    /// Return and double-click: opens or fronts the selected row and nothing else.
    func openSelection() {
        guard let selectedDatabase else { return }
        open(selectedDatabase)
    }

    func didCreate(_ database: CreatedDatabase) {
        openCreatedDatabase(database)
    }

    func requestNewDatabase() {
        sheet = .newDatabase
    }

    // MARK: - Removal

    /// Removal retires the database's session unconditionally, so it waits
    /// until the window has saved or closed: nothing unsaved is discarded unasked.
    /// False shows the refusal instead of the confirmation.
    func requestRemoval(_ reference: DatabaseReference) -> Bool {
        guard !hasUnsavedWork(reference.id) else {
            refusedRemoval = reference
            return false
        }
        return true
    }

    /// The confirmation, or the refusal while that database has unsaved work.
    func beginRemoval(_ reference: DatabaseReference) {
        guard requestRemoval(reference) else { return }
        pendingRemoval = reference
    }

    var canRemoveSelection: Bool { selectedDatabase != nil }

    func removeSelection() {
        guard let selectedDatabase else { return }
        beginRemoval(selectedDatabase)
    }

    func confirmRemoval() {
        guard let pendingRemoval else { return }
        self.pendingRemoval = nil
        remove(pendingRemoval)
    }

    /// Checked again on confirmation: the window may have gained unsaved work meanwhile.
    func remove(_ reference: DatabaseReference) {
        guard requestRemoval(reference) else { return }
        if selectedDatabaseID == reference.id { selectedDatabaseID = nil }
        removeDatabase(reference)
    }

    // MARK: - Servers

    var canConnect: Bool { connectProviders.isEmpty == false }

    /// The caption under Connect to Server…: the server types it offers.
    var connectCaption: String {
        connectProviders.map(\.displayName).joined(separator: ", ")
    }

    /// Without a provider (File ▸ Connect to Server…), the only server type
    /// goes straight to its sign-in; several are offered first.
    func requestConnect(_ provider: CloudProviderKind? = nil) {
        let providers = connectProviders
        if let provider {
            guard providers.contains(provider) else { return }
            isChoosingServer = false
            sheet = .connect(provider)
        } else if providers.count == 1, let only = providers.first {
            sheet = .connect(only)
        } else if providers.isEmpty == false {
            isChoosingServer = true
        }
    }

    // MARK: - Enrollment

    var enrollmentCandidates: [DatabaseReference] { databases }

    func chooseEnrollmentDestination(_ databaseID: UUID) {
        guard isChoosingEnrollmentDestination, databases.contains(where: { $0.id == databaseID }) else { return }
        isChoosingEnrollmentDestination = false
        chooseEnrollmentDestinationHandler(databaseID)
    }

    func cancelEnrollmentDestination() {
        guard isChoosingEnrollmentDestination else { return }
        isChoosingEnrollmentDestination = false
        cancelEnrollmentDestinationHandler()
    }
}
#endif
